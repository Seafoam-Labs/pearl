//! Synthetic clipboard service: no display connection, selection or disk writes.
const std = @import("std");
const service = @import("../services/clipboard.zig");
const session = @import("../services/clipboard/session.zig");
const codec = @import("../services/clipboard/codec.zig");
const store = @import("../services/clipboard/store.zig");
const t = std.testing;

pub fn at(seconds: i64) session.clock.Sample {
    return .{ .wall_seconds = seconds, .boottime_ns = @as(u64, @intCast(seconds)) * 1_000_000_000 };
}

pub const Fixture = struct {
    clipboard: service.Clipboard,
    backend: Backend = .{},
    notifications: usize = 0,
    preview_visible: bool = true,
    read_on_change: bool = false,
    observed_len: usize = 0,
    on_change: ?*const fn (*anyopaque) void = null,
    context: ?*anyopaque = null,

    pub fn init(self: *Fixture) !void {
        self.* = .{
            .clipboard = .{
                .display = undefined, // no test calls Wayland or publishes a value
                .device = @ptrFromInt(1),
                .context = self,
                .changed = changed,
                .locked = false,
                .test_time = at(100),
            },
        };
        self.clipboard.session = try session.Session.init(t.allocator, t.io, "/unused-test-backend", .{});
        const s = &self.clipboard.session.?;
        errdefer {
            s.beginShutdown();
            s.deinit();
        }
        s.worker = try session.worker.Worker.startWithBackend(t.allocator, t.io, .{ .context = &self.backend, .load = Backend.load, .persist = Backend.persist, .close = Backend.close });
        _ = s.worker.?.waitReady();
        s.now = try s.clock_state.start(at(100), 100);
        s.ready = true;
        s.setLocked(false);
    }
    pub fn deinit(self: *Fixture) void {
        self.backend.release();
        const s = &self.clipboard.session.?;
        s.beginShutdown();
        s.worker.?.join();
        s.deinit();
    }
    pub fn copy(self: *Fixture, bytes: []const u8, seconds: i64) !u64 {
        const s = &self.clipboard.session.?;
        const id = try s.accept(.text, bytes, at(seconds));
        _ = s.worker.?.waitIdle();
        _ = try s.updateWorker(null);
        self.clipboard.test_time = at(seconds);
        return id;
    }
    pub fn blockRemoval(self: *Fixture) !void {
        // One held active write and one required pending barrier. No sleeps or
        // scheduler races are used to produce Busy admission.
        self.backend.hold = true;
        const s = &self.clipboard.session.?;
        const seconds = @max(s.now, 200);
        _ = try s.accept(.text, "held write", at(seconds));
        self.backend.wait();
        var rows: [session.history.entries_limit]codec.Record = undefined;
        for (s.model.entries(), 0..) |entry, i| rows[i] = .{ .bytes = entry.bytes, .last_copy = entry.last_copy, .sequence = entry.sequence };
        const snapshot = try session.worker.OwnedSnapshot.create(t.allocator, .{ .records = rows[0..s.model.len], .floor = seconds });
        errdefer snapshot.deinit();
        _ = try s.worker.?.requestRemoval(.delete, s.save_revision + 1, snapshot);
        s.save_revision += 1;
    }
    fn changed(context: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.notifications += 1;
        if (!self.clipboard.accessible()) self.preview_visible = false;
        if (self.on_change) |notify| notify(self.context.?);
        if (self.read_on_change) self.observed_len = self.clipboard.entries().len;
    }
};

const Backend = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    hold: bool = false,
    entered: bool = false,
    fn load(_: *anyopaque) store.Error!session.worker.Key {
        return @splat(0);
    }
    fn persist(context: *anyopaque, _: codec.Snapshot, _: session.worker.Operation) store.Error!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        if (self.hold) {
            self.entered = true;
            self.condition.broadcast(t.io);
            while (self.hold) self.condition.waitUncancelable(t.io, &self.mutex);
        }
    }
    fn close(_: *anyopaque) void {}
    fn wait(self: *Backend) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        while (!self.entered) self.condition.waitUncancelable(t.io, &self.mutex);
    }
    fn release(self: *Backend) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.hold = false;
        self.condition.broadcast(t.io);
    }
};
