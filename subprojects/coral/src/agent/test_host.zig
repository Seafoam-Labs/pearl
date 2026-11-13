//! Reusable GTK-free test host for the agent backend test roots.
//!
//! File operations target disposable temp directories supplied by the test.
//! Terminals spawn real `sh -c` subprocesses so cancellation can be exercised
//! against a live process. Counters let tests assert that denied tools produce
//! NO side effect. A log buffer lets tests assert secrets never leak.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const host = @import("host.zig");

pub const FakeHost = struct {
    allocator: Allocator,
    io: Io,
    read_count: usize = 0,
    write_count: usize = 0,
    spawn_count: usize = 0,
    kill_count: usize = 0,
    search_count: usize = 0,
    logs: std.ArrayList([]u8) = .empty,
    terminals: std.AutoHashMap(u64, *Terminal) = undefined,
    next_handle: u64 = 1,
    terminals_initialized: bool = false,

    const Terminal = struct {
        child: std.process.Child,
        stdout: Io.File,
        output: ?[]u8 = null,
        exit_code: ?i32 = null,
        done: bool = false,
        killed: bool = false,
    };

    pub fn init(allocator: Allocator, io: Io) FakeHost {
        return .{
            .allocator = allocator,
            .io = io,
            .terminals = std.AutoHashMap(u64, *Terminal).init(allocator),
            .terminals_initialized = true,
        };
    }

    pub fn deinit(self: *FakeHost) void {
        var it = self.terminals.valueIterator();
        while (it.next()) |term| {
            if (!term.*.done) term.*.child.kill(self.io);
            if (term.*.output) |o| self.allocator.free(o);
            self.allocator.destroy(term.*);
        }
        self.terminals.deinit();
        for (self.logs.items) |l| self.allocator.free(l);
        self.logs.deinit(self.allocator);
    }

    pub fn asHost(self: *FakeHost) host.Host {
        return .{
            .ctx = self,
            .readFile = readFile,
            .listDir = listDir,
            .search = search,
            .writeFile = writeFile,
            .terminalSpawn = terminalSpawn,
            .terminalWait = terminalWait,
            .terminalKill = terminalKill,
            .gitDiff = gitDiff,
            .diagnostics = diagnostics,
            .log = log,
        };
    }

    pub fn loggedContains(self: *const FakeHost, needle: []const u8) bool {
        for (self.logs.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) return true;
        }
        return false;
    }

    fn readFile(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        self.read_count += 1;
        return Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(4 * 1024 * 1024));
    }

    fn writeFile(ctx: ?*anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        self.write_count += 1;
        // Ensure parent directory exists.
        if (std.fs.path.dirname(path)) |parent| {
            Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        }
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = content });
    }

    fn listDir(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]host.DirEntry {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        var dir = try Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var list: std.ArrayList(host.DirEntry) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const kind: host.DirEntry.Kind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            };
            try list.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = kind });
        }
        return list.toOwnedSlice(allocator);
    }

    fn search(ctx: ?*anyopaque, allocator: Allocator, root: []const u8, pattern: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        self.search_count += 1;
        var dir = try Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true });
        defer dir.close(self.io);
        var out: std.ArrayList(u8) = .empty;
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.basename, pattern) != null) {
                try out.print(allocator, "{s}\n", .{entry.path});
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn terminalSpawn(ctx: ?*anyopaque, command: []const u8, cwd: ?[]const u8) anyerror!host.TerminalHandle {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        self.spawn_count += 1;
        var cwd_opt: std.process.Child.Cwd = .inherit;
        if (cwd) |c| cwd_opt = .{ .path = c };
        const child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .cwd = cwd_opt,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const term = try self.allocator.create(Terminal);
        term.* = .{ .child = child, .stdout = child.stdout.? };
        const handle = self.next_handle;
        self.next_handle += 1;
        try self.terminals.put(handle, term);
        return handle;
    }

    fn terminalWait(ctx: ?*anyopaque, handle: host.TerminalHandle, timeout_ms: u32) anyerror!host.TerminalResult {
        _ = timeout_ms;
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        const term = self.terminals.get(handle) orelse return error.UnknownTerminal;
        if (!term.done) {
            var buf: [4096]u8 = undefined;
            var reader = term.stdout.reader(self.io, &buf);
            term.output = reader.interface.allocRemaining(self.allocator, .limited(4 * 1024 * 1024)) catch |err| blk: {
                if (err == error.StreamTooLong) break :blk try self.allocator.dupe(u8, "");
                return err;
            };
            const term_result = if (!term.killed) term.child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 } else std.process.Child.Term{ .unknown = 0 };
            term.exit_code = switch (term_result) {
                .exited => |code| @as(i32, code),
                else => null,
            };
            term.done = true;
        }
        return .{
            .exit_code = term.exit_code,
            .output = try self.allocator.dupe(u8, term.output orelse ""),
            .cancelled = term.killed,
        };
    }

    fn terminalKill(ctx: ?*anyopaque, handle: host.TerminalHandle) void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        self.kill_count += 1;
        const term = self.terminals.get(handle) orelse return;
        term.killed = true;
        if (!term.done) term.child.kill(self.io);
    }

    fn gitDiff(ctx: ?*anyopaque, allocator: Allocator, root: []const u8) anyerror![]u8 {
        _ = ctx;
        _ = root;
        return allocator.dupe(u8, "diff --git a/x b/x\n");
    }

    fn diagnostics(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 {
        _ = ctx;
        _ = path;
        return allocator.dupe(u8, "no diagnostics");
    }

    fn log(ctx: ?*anyopaque, level: host.LogLevel, message: []const u8) void {
        const self: *FakeHost = @ptrCast(@alignCast(ctx.?));
        const line = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ @tagName(level), message }) catch return;
        self.logs.append(self.allocator, line) catch self.allocator.free(line);
    }
};

/// Resolve the absolute path of a fixture relative to the project root (cwd).
pub fn fixturePath(allocator: Allocator, io: Io, name: []const u8) ![:0]u8 {
    const rel = try std.fs.path.join(allocator, &.{ "tests", "fixtures", name });
    defer allocator.free(rel);
    return Io.Dir.cwd().realPathFileAlloc(io, rel, allocator);
}

test "FakeHost reads and writes within a temp dir" {
    const a = std.testing.allocator;
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var fh = FakeHost.init(a, io);
    defer fh.deinit();
    const h = fh.asHost();
    const path = try std.fs.path.join(a, &.{ root, "hello.txt" });
    defer a.free(path);
    try h.writeFile.?(h.ctx, path, "hi");
    const content = try h.readFile.?(h.ctx, a, path);
    defer a.free(content);
    try std.testing.expectEqualStrings("hi", content);
    try std.testing.expectEqual(@as(usize, 1), fh.write_count);
}
