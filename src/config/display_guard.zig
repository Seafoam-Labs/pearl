//! Independent display lease process, using generated wlr-output-management.
//! It owns the baseline until Keep. Parent death closes stdin and triggers rollback.
//! Rollback only restores unchanged candidate heads and uses the latest serial,
//! preserving other heads and rejecting a racing compositor configuration.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const m = @import("aqueous_model.zig");
const a = std.heap.c_allocator;
const Mode = struct { proxy: *zwlr.OutputModeV1, width: i32 = 0, height: i32 = 0, refresh: i32 = 0, alive: bool = true };
const State = struct { enabled: bool = false, mode: ?*zwlr.OutputModeV1 = null, x: i32 = 0, y: i32 = 0, transform: @FieldType(@FieldType(zwlr.OutputHeadV1.Event, "transform"), "transform") = .normal, scale: wl.Fixed = wl.Fixed.fromDouble(1), adaptive: zwlr.OutputHeadV1.AdaptiveSyncState = .disabled };
const Head = struct { proxy: *zwlr.OutputHeadV1, name: []const u8 = "", current: State = .{}, baseline: State = .{}, candidate: State = .{}, alive: bool = true, touched: bool = false, modes: std.ArrayList(*Mode) = .empty };
const Guard = struct {
    display: *wl.Display,
    manager: ?*zwlr.OutputManagerV1 = null,
    heads: std.ArrayList(*Head) = .empty,
    serial: ?u32 = null,
    epoch: u64 = 0,
    ended: bool = false,
    abort: bool = false,
    keep: bool = false,
    reply: enum { pending, succeeded, failed, cancelled } = .pending,
    fn registry(reg: *wl.Registry, event: wl.Registry.Event, self: *Guard) void {
        if (event == .global and std.mem.eql(u8, std.mem.span(event.global.interface), "zwlr_output_manager_v1") and event.global.version >= 4) {
            self.manager = reg.bind(event.global.name, zwlr.OutputManagerV1, 4) catch {
                self.ended = true;
                return;
            };
            self.manager.?.setListener(*Guard, managerEvent, self);
        }
    }
    fn managerEvent(_: *zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event, self: *Guard) void {
        switch (event) {
            .head => |v| {
                if (self.heads.items.len >= 64) {
                    self.ended = true;
                    return;
                }
                const head = a.create(Head) catch {
                    self.ended = true;
                    return;
                };
                head.* = .{ .proxy = v.head };
                self.heads.append(a, head) catch {
                    self.ended = true;
                    return;
                };
                v.head.setListener(*Head, headEvent, head);
            },
            .done => |v| {
                self.serial = v.serial;
                self.epoch += 1;
            },
            .finished => self.ended = true,
        }
    }
    fn headEvent(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, h: *Head) void {
        switch (event) {
            .name => |v| h.name = a.dupe(u8, std.mem.span(v.name)) catch "",
            .enabled => |v| h.current.enabled = v.enabled != 0,
            .current_mode => |v| h.current.mode = v.mode,
            .position => |v| {
                h.current.x = v.x;
                h.current.y = v.y;
            },
            .transform => |v| h.current.transform = v.transform,
            .scale => |v| h.current.scale = v.scale,
            .adaptive_sync => |v| h.current.adaptive = v.state,
            .finished => h.alive = false,
            .mode => |v| {
                if (h.modes.items.len >= 512) {
                    h.alive = false;
                    return;
                }
                const mode = a.create(Mode) catch {
                    h.alive = false;
                    return;
                };
                mode.* = .{ .proxy = v.mode };
                h.modes.append(a, mode) catch {
                    h.alive = false;
                    return;
                };
                v.mode.setListener(*Mode, modeEvent, mode);
            },
            else => {},
        }
    }
    fn modeEvent(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, mode: *Mode) void {
        switch (event) {
            .size => |v| {
                mode.width = v.width;
                mode.height = v.height;
            },
            .refresh => |v| mode.refresh = v.refresh,
            .finished => mode.alive = false,
            else => {},
        }
    }
    fn configurationEvent(_: *zwlr.OutputConfigurationV1, event: zwlr.OutputConfigurationV1.Event, self: *Guard) void {
        self.reply = switch (event) {
            .succeeded => .succeeded,
            .failed => .failed,
            .cancelled => .cancelled,
        };
    }
    fn pump(self: *Guard, deadline: i64, control: bool) !void {
        if (self.ended) return error.DisplayServiceLost;
        if (glib.getMonotonicTime() >= deadline) return error.DisplayTimedOut;
        while (!self.display.prepareRead()) if (self.display.dispatchPending() != .SUCCESS) return error.DisplayServiceLost;
        var prepared = true;
        defer if (prepared) self.display.cancelRead();
        const flushed = self.display.flush();
        if (flushed != .SUCCESS and flushed != .AGAIN) return error.DisplayServiceLost;
        var fds = [_]std.c.pollfd{
            .{ .fd = self.display.getFd(), .events = std.c.POLL.IN | (if (flushed == .AGAIN) @as(i16, std.c.POLL.OUT) else 0), .revents = 0 },
            .{ .fd = if (control and !self.abort) 0 else -1, .events = std.c.POLL.IN, .revents = 0 },
        };
        const rc = std.c.poll(&fds, fds.len, 50);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) return;
            return error.DisplayServiceLost;
        }
        if (fds[1].revents != 0) {
            var c: [16]u8 = undefined;
            const n = std.c.read(0, &c, c.len);
            if (n <= 0) self.abort = true else for (c[0..@intCast(n)]) |ch| {
                if (ch == 'K') self.keep = true else self.abort = true;
            }
        }
        if (fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0) return error.DisplayServiceLost;
        if (fds[0].revents & std.c.POLL.IN != 0) {
            prepared = false;
            if (self.display.readEvents() != .SUCCESS) return error.DisplayServiceLost;
        } else {
            self.display.cancelRead();
            prepared = false;
        }
        if (self.display.dispatchPending() != .SUCCESS) return error.DisplayServiceLost;
    }
    fn configure(self: *Guard, restore: bool, test_only: bool) !void {
        const config = try (self.manager orelse return error.DisplayPreviewUnavailable).createConfiguration(self.serial orelse return error.DisplayPreviewUnavailable);
        defer config.destroy();
        config.setListener(*Guard, configurationEvent, self);
        self.reply = .pending;
        for (self.heads.items) |h| {
            if (!h.alive) continue;
            var state = h.current;
            if (h.touched) {
                if (!restore) state = h.candidate else if (std.meta.eql(h.current, h.candidate)) state = h.baseline;
            }
            if (!state.enabled) {
                config.disableHead(h.proxy);
                continue;
            }
            const mode = state.mode orelse return error.CustomDisplayModeUnsupported;
            var alive = false;
            for (h.modes.items) |v| if (v.proxy == mode and v.alive) {
                alive = true;
                break;
            };
            if (!alive) return error.DisplayModeGone;
            const change = try config.enableHead(h.proxy);
            defer change.destroy();
            change.setMode(mode);
            change.setPosition(state.x, state.y);
            change.setTransform(state.transform);
            change.setScale(state.scale);
            change.setAdaptiveSync(state.adaptive);
        }
        if (test_only) config.@"test"() else config.apply();
        const deadline = glib.getMonotonicTime() + 3000000;
        while (self.reply == .pending) try self.pump(deadline, !restore);
        if (self.reply != .succeeded) return error.DisplayConfigurationRejected;
        // Drain the corresponding done batch before comparing current state.
        const sync = try self.display.sync();
        var done = false;
        sync.setListener(*bool, synced, &done);
        while (!done) try self.pump(deadline, !restore);
    }
    fn synced(callback: *wl.Callback, _: wl.Callback.Event, done: *bool) void {
        callback.destroy();
        done.* = true;
    }
    fn matches(self: *Guard) bool {
        for (self.heads.items) |h| if (h.touched and (!h.alive or !std.meta.eql(h.current, h.candidate))) return false;
        return true;
    }
    fn prepare(self: *Guard, changes: []const m.Value) !void {
        if (changes.len == 0 or changes.len > 64) return error.DisplayChangesRequired;
        for (self.heads.items) |h| {
            h.baseline = h.current;
            h.candidate = h.current;
        }
        for (changes) |change| {
            var found: ?*Head = null;
            for (self.heads.items) |h| if (h.alive and std.mem.eql(u8, h.name, m.str(m.get(change, "name")))) {
                found = h;
                break;
            };
            const h = found orelse return error.DisplayDisconnected;
            if (h.touched or !h.current.enabled) return error.DisplayChangesUnsupported;
            h.touched = true;
            // Mirroring has no representation in wlr-output-management v4.
            if (m.str(m.get(change, "mirror_of")).len > 0) return error.MirrorPreviewUnsupported;
            h.candidate.x = @intCast(m.get(change, "x").integer);
            h.candidate.y = @intCast(m.get(change, "y").integer);
            const transform = m.str(m.get(change, "transform"));
            const transforms = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };
            var matched = false;
            for (transforms, 0..) |name, index| if (std.mem.eql(u8, name, transform)) {
                h.candidate.transform = @enumFromInt(index);
                matched = true;
                break;
            };
            if (!matched) return error.InvalidDisplayTransform;
            const scale = m.get(change, "scale");
            if (scale != .null) h.candidate.scale = wl.Fixed.fromDouble(switch (scale) {
                .integer => @floatFromInt(scale.integer),
                .float => scale.float,
                else => return error.InvalidDisplayScale,
            });
            const mode_text = m.str(m.get(change, "mode"));
            if (mode_text.len > 0) {
                var parts = std.mem.tokenizeAny(u8, mode_text, "x@");
                const width = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidDisplayMode, 10);
                const height = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidDisplayMode, 10);
                const refresh: ?f64 = if (parts.next()) |v| try std.fmt.parseFloat(f64, v) else null;
                h.candidate.mode = null;
                for (h.modes.items) |mode| if (mode.alive and mode.width == width and mode.height == height and (refresh == null or @abs(@as(f64, @floatFromInt(mode.refresh)) - refresh.? * 1000) < 2)) {
                    h.candidate.mode = mode.proxy;
                    break;
                };
                if (h.candidate.mode == null) return error.UnadvertisedDisplayMode;
            }
        }
    }
};
fn write(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.ParentGone;
        offset += @intCast(n);
    }
}
fn execute(alloc: std.mem.Allocator, commit_started: *bool) !void {
    // Request is an anonymous descriptor, separate from the interactive control pipe.
    const bytes = try alloc.alloc(u8, m.max_request + 1);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(3, bytes[used..].ptr, bytes.len - used);
        if (n < 0) return error.RequestReadFailed;
        if (n == 0) break;
        used += @intCast(n);
    }
    _ = std.c.close(3);
    const envelope = try m.parse(alloc, bytes[0..used], m.max_request);
    const request = m.get(envelope, "request");
    const helper = try alloc.dupeZ(u8, m.str(m.get(envelope, "helper")));
    const encoded = try std.json.Stringify.valueAlloc(alloc, request, .{});
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    const validation = try @import("helper_process.zig").run(alloc, &.{ helper, "validate", "--shell", "none", "--request", "-" }, encoded, cancel, 35000);
    const candidate = try m.parse(alloc, validation.stdout, m.max_response);
    try m.snapshot(candidate);
    if (!validation.success) return error.HelperRejected;
    for ([_][]const u8{ "monitors", "live_outputs" }) |key| for (m.list(m.get(candidate, key))) |head| {
        if (m.str(m.get(head, "mirror_of")).len != 0) return error.MirrorPreviewUnsupported;
    };
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    var guard: Guard = .{ .display = display };
    const registry = try display.getRegistry();
    registry.setListener(*Guard, Guard.registry, &guard);
    const deadline = glib.getMonotonicTime() + 3000000;
    while (guard.serial == null) try guard.pump(deadline, true);
    try guard.prepare(m.list(m.get(request, "monitor_changes")));
    if (guard.abort) return error.ParentGone;
    const serial = guard.serial;
    try guard.configure(false, true);
    if (guard.serial != serial or guard.abort) return error.DisplayChanged;
    // From this point every failure attempts rollback, including loss of the parent.
    var protected = true;
    defer if (protected) guard.configure(true, false) catch |err| {
        std.log.err("event=display-rollback error={s}", .{@errorName(err)});
    };
    try guard.configure(false, false);
    if (!guard.matches()) return error.DisplayChanged;
    const epoch = guard.epoch;
    try write("PREVIEW\n");
    const expires = glib.getMonotonicTime() + 15000000;
    while (!guard.keep and !guard.abort and guard.epoch == epoch and glib.getMonotonicTime() < expires) guard.pump(expires, true) catch |err| {
        if (err == error.DisplayTimedOut) break;
        return err;
    };
    if (!guard.keep or guard.abort or guard.epoch != epoch or !guard.matches()) {
        const invalidated = guard.epoch != epoch or !guard.matches();
        try guard.configure(true, false);
        protected = false;
        try write(if (invalidated) "{\"ok\":true,\"preview\":\"invalidated\"}\n" else "{\"ok\":true,\"preview\":\"reverted\"}\n");
        return;
    }
    // Revalidate the retained generation after Keep, before any canonical write.
    const checked = try @import("helper_process.zig").run(alloc, &.{ helper, "validate", "--shell", "none", "--request", "-" }, encoded, cancel, 35000);
    try m.check(try m.parse(alloc, checked.stdout, m.max_response));
    // Refresh Wayland state that arrived while validating, and reject hotplug.
    const sync = try display.sync();
    var done = false;
    sync.setListener(*bool, Guard.synced, &done);
    const sync_deadline = glib.getMonotonicTime() + 3000000;
    while (!done) try guard.pump(sync_deadline, true);
    if (!guard.matches() or guard.epoch != epoch or guard.abort) return error.DisplayChanged;
    commit_started.* = true;
    const applied = try @import("helper_process.zig").run(alloc, &.{ helper, "apply", "--shell", "none", "--request", "-", "--report-reload", "true" }, encoded, cancel, 35000);
    const saved = try m.parse(alloc, applied.stdout, m.max_response);
    try m.snapshot(saved);
    if (!applied.success or !m.equal(m.get(candidate, "raw_files"), m.get(saved, "raw_files"))) return error.SaveUncertain;
    protected = false; // Keep authorized persistence; a reload failure is reported separately.
    try write(try std.json.Stringify.valueAlloc(alloc, .{ .ok = true, .preview = "kept", .result = saved, .reload = m.reloadReport(applied.stderr) }, .{}));
}
pub fn main() void {
    // stdout may disappear when Pearl crashes. Ignore SIGPIPE so rollback runs.
    var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
    _ = std.c.sigaction(std.c.SIG.PIPE, &action, null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var commit_started = false;
    execute(arena.allocator(), &commit_started) catch |err| {
        const json = std.json.Stringify.valueAlloc(arena.allocator(), .{ .ok = false, .preview = "failed", .err = @errorName(err), .save_uncertain = commit_started }, .{}) catch return;
        write(json) catch {};
    };
}
