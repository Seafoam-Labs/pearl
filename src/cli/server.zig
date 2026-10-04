//! Same-UID, session/display-scoped control service. Eight bounded clients.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const wire = @import("../aqueous/transport.zig");
const protocol = @import("protocol.zig");
const report = @import("report.zig");
const startup = @import("../core/startup.zig");
const logging = @import("../core/logging.zig");
const files = @import("../config/io.zig");
const helper = @import("../config/helper_process.zig");
const a = std.heap.c_allocator;
const log = std.log.scoped(.cli);
pub const Server = struct {
    path: [:0]u8,
    display: [:0]u8,
    session: [32]u8,
    socket: ?*gio.Socket = null,
    source: ?*glib.Source = null,
    lock: ?std.os.linux.fd_t = null,
    owns_path: bool = false,
    slots: [8]Slot = undefined,
    initialized: bool = false,
    context: *anyopaque,
    handle: *const fn (*anyopaque, protocol.Request, std.mem.Allocator) anyerror![]const u8,
    quit: *const fn (*anyopaque) void,
    quit_source: c_uint = 0,
    pub fn init(runtime: []const u8, session: []const u8, display: []const u8, context: *anyopaque, handle: @FieldType(Server, "handle"), quit: @FieldType(Server, "quit")) !Server {
        const path = try protocol.endpoint(a, runtime, session);
        errdefer a.free(path);
        const name = try protocol.displayPath(a, runtime, display);
        return .{ .path = path, .display = name, .session = session[0..32].*, .context = context, .handle = handle, .quit = quit };
    }
    pub fn start(self: *Server) !void {
        for (&self.slots) |*slot| {
            slot.* = .{ .owner = self, .wire = undefined };
            slot.wire = wire.Transport.init(slot, slotEvent);
            slot.wire.framer.limit = protocol.max_frame;
        }
        self.initialized = true;
        const parent = std.fs.path.dirname(self.path).?;
        const base = std.fs.path.dirname(parent).?;
        try privateDirectory(base);
        try privateDirectory(parent);
        const lockpath = try std.fmt.allocPrintSentinel(a, "{s}/instance.lock", .{parent}, 0);
        defer a.free(lockpath);
        const fd = std.os.linux.open(lockpath, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        if (std.os.linux.errno(fd) != .SUCCESS) return error.LockFile;
        self.lock = @intCast(fd);
        if (std.os.linux.errno(std.os.linux.flock(self.lock.?, 2 | 4)) != .SUCCESS) return error.AlreadyRunning;
        // Only the lock owner may remove the previous instance's stale socket.
        const file = gio.File.newForPath(self.path);
        defer file.unref();
        var err: ?*glib.Error = null;
        defer if (err) |v| v.free();
        if (file.queryInfo("standard::type,unix::uid,unix::mode", .{ .nofollow_symlinks = true }, null, &err)) |info| {
            defer info.unref();
            if (info.getAttributeUint32("unix::uid") != std.os.linux.getuid() or info.getAttributeUint32("unix::mode") & 0o170000 != 0o140000) return error.UnsafeEndpoint;
            if (file.delete(null, &err) == 0) return error.UnsafeEndpoint;
        } else if (err.?.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_found)) == 0) return error.UnsafeEndpoint;
        if (err) |v| {
            v.free();
            err = null;
        }
        const socket = gio.Socket.new(.unix, .stream, .default, &err) orelse return error.Socket;
        self.socket = socket;
        socket.setBlocking(0);
        const address = gio.UnixSocketAddress.new(self.path);
        defer address.unref();
        if (socket.bind(address.as(gio.SocketAddress), 0, &err) == 0) return error.Bind;
        self.owns_path = true;
        if (socket.listen(&err) == 0) return error.Listen;
        self.source = socket.createSource(.{ .in = true }, null);
        self.source.?.setCallback(@ptrCast(&accept), self, null);
        _ = self.source.?.attach(null);
    }
    pub fn deinit(self: *Server) void {
        if (self.quit_source != 0) _ = glib.Source.remove(self.quit_source);
        if (self.source) |s| {
            s.destroy();
            s.unref();
        }
        if (self.initialized) for (&self.slots) |*slot| {
            slot.close();
            slot.wire.deinit();
        };
        if (self.socket) |s| {
            _ = s.close(null);
            s.unref();
        }
        if (self.owns_path) {
            const file = gio.File.newForPath(self.path);
            defer file.unref();
            _ = file.delete(null, null);
        }
        // Keep the lock inode in place so a new process cannot lock a different inode.
        if (self.lock) |fd| _ = std.os.linux.close(fd);
        a.free(self.path);
        a.free(self.display);
    }
    fn accept(socket: *gio.Socket, _: glib.IOCondition, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(context.?));
        for (0..8) |_| {
            const connection = socket.accept(null, null) orelse break;
            const target: ?*Slot = blk: {
                for (&self.slots) |*slot| if (!slot.active) break :blk slot;
                break :blk null;
            };
            if (target) |slot| {
                slot.wire.adopt(connection) catch continue;
                slot.active = true;
                slot.responding = false;
                slot.deadline = glib.timeoutAdd(5000, expired, slot);
            } else {
                _ = connection.close(null);
                connection.unref();
            }
        }
        return 1;
    }
    fn slotEvent(context: *anyopaque, event: wire.Event) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        switch (event) {
            .connected => {},
            .sent => {
                const quit = slot.quit_after_reply;
                slot.close();
                if (quit and slot.owner.quit_source == 0) slot.owner.quit_source = glib.idleAdd(quitIdle, slot.owner);
            },
            .failed => slot.close(),
            .frame => |bytes| {
                if (slot.responding) {
                    slot.close();
                    return;
                }
                slot.responding = true;
                slot.reply(bytes) catch {
                    slot.close();
                };
            },
        }
    }
    fn expired(context: ?*anyopaque) callconv(.c) c_int {
        const slot: *Slot = @ptrCast(@alignCast(context.?));
        slot.deadline = 0;
        slot.close();
        return 0;
    }
    fn quitIdle(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(context.?));
        self.quit_source = 0;
        self.quit(self.context);
        return 0;
    }
};
const Slot = struct {
    owner: *Server,
    wire: wire.Transport,
    active: bool = false,
    responding: bool = false,
    deadline: c_uint = 0,
    quit_after_reply: bool = false,
    fn close(self: *Slot) void {
        self.wire.close();
        self.active = false;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.quit_after_reply = false;
    }
    fn reply(self: *Slot, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const request = protocol.parse(alloc, bytes) catch |err| {
            try self.failure(alloc, "0", if (err == error.Version) error.Version else error.InvalidRequest);
            return;
        };
        if (!std.mem.eql(u8, request.session, &self.owner.session)) {
            try self.failure(alloc, request.id, error.StaleSession);
            return;
        }
        if (!std.mem.eql(u8, request.display, self.owner.display)) {
            try self.failure(alloc, request.id, error.DisplayMismatch);
            return;
        }
        // The report answers with the artifact path; everything else goes to
        // the desktop handler.
        const result = blk: {
            if (request.op == .report) break :blk writeReport(self.owner, request, alloc);
            break :blk self.owner.handle(self.owner.context, request, alloc);
        } catch |err| {
            try self.failure(alloc, request.id, switch (err) {
                error.OutputColorEligibilityUnavailable, error.SessionInactive, error.ClockUnavailable, error.Stale, error.InvalidRegion, error.InvalidPayload, error.InvalidPath, error.SaveFailed, error.Unavailable, error.OutputUnavailable, error.Locked, error.AmbiguousSeat, error.EdgeOccupied, error.InvalidSize, error.InvalidGroups, error.InvalidValue, error.Conflict, error.Busy, error.Unsupported, error.StaleConfirmation, error.NoConfirmation, error.InhibitorUnavailable, error.LockFailed, error.LockerMissing, error.SettingsNotInstalled, error.SettingsLaunchFailed => err,
                else => if (request.op == .preferences_apply and err != error.OutOfMemory) err else error.Internal,
            });
            return;
        };
        const frame = try std.fmt.allocPrint(alloc, "{{\"pearl\":1,\"id\":\"{s}\",\"ok\":true,\"result\":{s}}}\n", .{ request.id, result });
        if (frame.len - 1 > protocol.max_frame) {
            try self.failure(alloc, request.id, error.ResponseTooLarge);
            return;
        }
        try self.wire.send(frame);
        self.quit_after_reply = request.op == .quit;
    }
    fn failure(self: *Slot, alloc: std.mem.Allocator, id: []const u8, err: anyerror) !void {
        const payload = try std.json.Stringify.valueAlloc(alloc, .{ .pearl = 1, .id = id, .ok = false, .err = .{ .code = @errorName(err) } }, .{});
        try self.wire.send(try std.fmt.allocPrint(alloc, "{s}\n", .{payload}));
    }
};
pub fn privateDirectory(path: []const u8) !void {
    const name = try a.dupeZ(u8, path);
    defer a.free(name);
    if (glib.mkdirWithParents(name, 0o700) != 0) return error.RuntimeDirectory;
    const file = gio.File.newForPath(name);
    defer file.unref();
    var err: ?*glib.Error = null;
    defer if (err) |v| v.free();
    const info = file.queryInfo("standard::type,unix::uid,unix::mode", .{ .nofollow_symlinks = true }, null, &err) orelse return error.RuntimeDirectory;
    defer info.unref();
    if (info.getFileType() != .directory or info.getAttributeUint32("unix::uid") != std.os.linux.getuid() or info.getAttributeUint32("unix::mode") & 0o077 != 0) return error.UnsafeRuntimeDirectory;
}

fn envValue(name: [*:0]const u8) []const u8 {
    return if (glib.getenv(name)) |value| std.mem.span(value) else "";
}

/// Writes the support artifact and answers with its path. Every source except
/// the file itself is best effort: a degraded section carries a marker line
/// instead of failing the report.
fn writeReport(owner: *Server, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
    errdefer |err| log.err("event=report-failed error={s}", .{@errorName(err)});
    var status_request = request;
    status_request.op = .status;
    // A failed or oversized probe degrades to a marker object naming the Zig
    // error instead of discarding the section, so the reason rides along in the
    // report's own journal excerpt. The bound is the same 8192-byte frame a
    // plain `pearlctl status` reply must satisfy.
    const status = blk: {
        const raw = owner.handle(owner.context, status_request, alloc) catch |err| {
            log.err("event=report-status-unavailable error={s}", .{@errorName(err)});
            break :blk report.degradedStatus(alloc, err) catch "{\"unavailable\":true}";
        };
        if (raw.len > protocol.max_frame) {
            log.err("event=report-status-unavailable error=ResponseTooLarge", .{});
            break :blk report.degradedStatus(alloc, error.ResponseTooLarge) catch "{\"unavailable\":true}";
        }
        break :blk raw;
    };
    const environment = environmentCheck();
    const seconds_raw = std.Io.Clock.real.now(std.Options.debug_io).toSeconds();
    var name_storage: [32]u8 = undefined;
    var out: std.Io.Writer.Allocating = .init(alloc);
    report.write(&out.writer, .{
        .argv = commandLine(alloc),
        .version = @import("../version.zig").string,
        .log_level = logging.levelName(logging.runtime_level),
        .log_scopes = try logging.scopeList(alloc, logging.runtime_scopes),
        .environment = environment.text,
        .environment_exit = environment.exit,
        .status = try report.redactSession(alloc, status),
        .journal = journalExcerpt(alloc),
    }) catch return error.SaveFailed;
    const directory = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl", .{std.mem.span(glib.getUserStateDir())}, 0);
    privateDirectory(directory) catch return error.SaveFailed;
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ directory, report.name(if (seconds_raw > 0) @intCast(seconds_raw) else 0, &name_storage) }, 0);
    files.atomic(path, out.written(), false) catch return error.SaveFailed;
    evictReports(alloc, directory);
    // Only the filename reaches the journal: the full state path exposes home
    // and deployment details to a stream other tools read, and the IPC reply
    // already returns the path to the requesting terminal.
    log.info("event=report-written name={s}", .{std.fs.path.basename(path)});
    return std.json.Stringify.valueAlloc(alloc, .{ .path = path }, .{});
}

/// Same contract as `pearl --check-environment` in the server's environment:
/// valid, or the actionable diagnostic with the usage/environment exit code.
fn environmentCheck() struct { text: []const u8, exit: u8 } {
    startup.validate(.session, .{ .desktop = envValue("XDG_CURRENT_DESKTOP"), .runtime = envValue("XDG_RUNTIME_DIR"), .display = envValue("WAYLAND_DISPLAY"), .endpoint = envValue("AQUEOUS_SOCKET") }) catch |err| {
        return .{ .text = startup.diagnostic(err), .exit = 2 };
    };
    return .{ .text = "Aqueous session environment is valid.", .exit = 0 };
}

/// Best effort read of a small procfs pseudo-file into caller storage.
fn procText(path: [*:0]const u8, storage: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, storage.ptr, storage.len);
    if (n <= 0) return null;
    return storage[0..@intCast(n)];
}

fn commandLine(alloc: std.mem.Allocator) []const u8 {
    var storage: [4096]u8 = undefined;
    const raw = procText("/proc/self/cmdline", &storage) orelse return "";
    const text = alloc.dupe(u8, raw) catch return "";
    for (text) |*byte| {
        if (byte.* == 0) byte.* = ' ';
    }
    return std.mem.trimEnd(u8, text, " ");
}

/// One journalctl invocation plus the exact command line to show for it, so the
/// report header always reproduces the excerpt below it.
const JournalQuery = struct { argv: []const [:0]const u8, command: []const u8 };

const journal_lines = "500";
/// Shared across attempts: `pearlctl` answers with a five second deadline, and
/// the report must stay inside it however many streams it walks.
const journal_budget_us = 2_000_000;

fn journalQuery(alloc: std.mem.Allocator, specifier: []const u8, value: []const u8) ?JournalQuery {
    const match = std.fmt.allocPrintSentinel(alloc, "{s}{s}", .{ specifier, value }, 0) catch return null;
    const argv = alloc.alloc([:0]const u8, 6) catch return null;
    argv[0] = "journalctl";
    argv[1] = "--user";
    argv[2] = match;
    argv[3] = "-n";
    argv[4] = journal_lines;
    argv[5] = "--no-pager";
    // Quoted so the header stays a command that reproduces the excerpt when the
    // executable path holds a space (an `_EXE=` match can, a unit name cannot).
    const quoted = std.mem.indexOfScalar(u8, match, ' ') != null;
    const command = std.fmt.allocPrint(alloc, "journalctl --user {s}{s}{s} -n {s} --no-pager", .{ if (quoted) "\"" else "", match, if (quoted) "\"" else "", journal_lines }) catch return null;
    return .{ .argv = argv, .command = command };
}

fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// journalctl prints a sentinel rather than nothing when a query matches no
/// entry; echoing it would put a line in the report that reads like an entry.
fn journalEntries(text: []const u8) []const u8 {
    return if (std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "-- No entries --")) "" else text;
}

/// The user journal only, never the system journal: no privilege escalation for
/// a support artifact. The stream is resolved from this process rather than
/// assumed from a unit name, because the shell's log lines are in whichever unit
/// started it: Aqueous's integration units own the stream and are not named
/// `pearl.service`, while a shell started from a terminal or a nested session is
/// in a scope that must not be mined for its other output. A unit query that
/// matches nothing falls through to the executable-scoped one; the header always
/// names a stream that was actually looked in.
fn journalExcerpt(alloc: std.mem.Allocator) report.Journal {
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var queries: [2]JournalQuery = undefined;
    var count: usize = 0;
    var storage: [4096]u8 = undefined;
    if (procText("/proc/self/cgroup", &storage)) |text| {
        if (report.unitFromCgroup(text)) |unit| {
            if (journalQuery(alloc, "--unit=", unit)) |query| {
                queries[count] = query;
                count += 1;
            }
        }
    }
    var link: [4096]u8 = undefined;
    const size = std.c.readlink("/proc/self/exe", &link, link.len);
    if (size > 0) {
        if (journalQuery(alloc, "_EXE=", link[0..@intCast(size)])) |query| {
            queries[count] = query;
            count += 1;
        }
    }
    if (count == 0) return .{ .command = "journalctl --user", .text = "", .unavailable = "this process' journal stream is not resolvable" };
    const started = glib.getMonotonicTime();
    var reason: []const u8 = "";
    for (queries[0..count]) |query| {
        const left = started + journal_budget_us - glib.getMonotonicTime();
        if (left <= 0) {
            if (reason.len == 0) reason = "journal budget exhausted";
            break;
        }
        const result = helper.run(alloc, query.argv, null, cancel, @divTrunc(left, 1000)) catch |err| {
            if (reason.len == 0) reason = @errorName(err);
            continue;
        };
        if (!result.success) {
            if (reason.len == 0) reason = if (result.stderr.len > 0) firstLine(result.stderr) else "journalctl exited unsuccessfully";
            continue;
        }
        const text = journalEntries(result.stdout);
        if (text.len == 0) continue;
        return .{ .command = query.command, .text = text };
    }
    // Nothing matched, so the header keeps the primary stream: a reader sees
    // where Pearl looked, and a query that never answered is told apart from one
    // that came back empty.
    const unavailable: ?[]const u8 = if (reason.len > 0) reason else null;
    return .{ .command = queries[0].command, .text = "", .unavailable = unavailable };
}

/// Retention runs after a successful write and never fails the report.
fn evictReports(alloc: std.mem.Allocator, directory: [:0]const u8) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |entry| alloc.free(entry);
        names.deinit(alloc);
    }
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        names.append(alloc, alloc.dupe(u8, entry.name) catch break) catch break;
    }
    const doomed = report.evictList(alloc, names.items) catch return;
    defer alloc.free(doomed);
    for (doomed) |entry| dir.deleteFile(io, entry) catch {};
}
