const std = @import("std");
const glib = @import("glib2");
const worker = @import("services/clipboard/worker.zig");
const Watch = @import("services/clipboard/completion_watch.zig").Watch;
const codec = @import("services/clipboard/codec.zig");
const storage = @import("services/clipboard/store.zig");
const t = std.testing;

const Backend = struct {
    fail: bool = false,
    fn load(_: *anyopaque) storage.Error!worker.Key {
        return @splat(0);
    }
    fn persist(data: *anyopaque, _: codec.Snapshot, _: worker.Operation) storage.Error!void {
        const self: *Backend = @ptrCast(@alignCast(data));
        if (self.fail) return error.WriteFailed;
    }
    fn close(_: *anyopaque) void {}
    fn start(self: *Backend) !*worker.Worker {
        return worker.Worker.startWithBackend(t.allocator, t.io, .{ .context = self, .load = load, .persist = persist, .close = close });
    }
};

const Observer = struct {
    w: *worker.Worker,
    calls: usize = 0,
    status: worker.Status = .{},
    main_thread: std.Thread.Id,
    wrong_thread: bool = false,
    watch: Watch = .{},

    fn attach(self: *Observer) void {
        self.watch.attach(self.w.completion.fd, completed, self);
    }
    fn completed(_: *glib.IOChannel, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Observer = @ptrCast(@alignCast(data.?));
        self.w.completion.drain();
        self.calls += 1;
        self.wrong_thread = self.wrong_thread or self.main_thread != std.Thread.getCurrentId();
        self.status = self.w.status();
        return 1;
    }
};

fn dispatch() void {
    while (glib.MainContext.default().iteration(0) != 0) {}
}
fn snapshot() !*worker.OwnedSnapshot {
    return worker.OwnedSnapshot.create(t.allocator, .{ .records = &.{.{ .bytes = "synthetic text", .last_copy = 100, .sequence = 1 }}, .floor = 100 });
}

test "GLib observes startup saves removals and drained shutdown with no idle dispatch" {
    var backend: Backend = .{};
    const w = try backend.start();
    defer w.deinit();
    var observer: Observer = .{ .w = w, .main_thread = std.Thread.getCurrentId() };
    observer.attach();
    defer observer.watch.detach();
    _ = w.waitReady();
    dispatch();
    try t.expect(observer.status.initialized);
    const calls = observer.calls;
    for (0..100) |_| try t.expectEqual(@as(c_int, 0), glib.MainContext.default().iteration(0));
    try t.expectEqual(calls, observer.calls);
    try w.requestSave(1, try snapshot());
    _ = w.waitIdle();
    dispatch();
    try t.expectEqual(@as(u64, 1), observer.status.durable_revision);
    const token = try w.requestRemoval(.delete, 2, try snapshot());
    _ = w.waitIdle();
    dispatch();
    try t.expectEqual(@as(u64, 2), observer.status.durable_revision);
    try t.expectEqual(worker.ReceiptState.durable, (try w.receipt(token)).state);
    w.beginShutdown();
    w.join();
    dispatch();
    try t.expect(observer.status.stopped);
    try t.expect(!observer.wrong_thread);
}

test "GLib observes worker failure and its terminal removal receipt" {
    var backend: Backend = .{ .fail = true };
    const w = try backend.start();
    defer w.deinit();
    var observer: Observer = .{ .w = w, .main_thread = std.Thread.getCurrentId() };
    observer.attach();
    defer observer.watch.detach();
    _ = w.waitReady();
    dispatch();
    const token = try w.requestRemoval(.delete, 1, try snapshot());
    w.join();
    dispatch();
    try t.expectEqual(error.WriteFailed, observer.status.failure.?);
    try t.expect(observer.status.stopped);
    try t.expectEqual(worker.ReceiptState.failed, (try w.receipt(token)).state);
    try t.expect(!observer.wrong_thread);
}

test "detaching the watch permits freeing its context before queued and late completions" {
    var backend: Backend = .{};
    const w = try backend.start();
    defer w.deinit();
    const observer = try t.allocator.create(Observer);
    observer.* = .{ .w = w, .main_thread = std.Thread.getCurrentId() };
    observer.attach();
    _ = w.waitReady(); // startup notification already queued, not dispatched
    observer.watch.detach();
    t.allocator.destroy(observer);
    try w.requestSave(1, try snapshot()); // completion arrives after context freed
    w.beginShutdown();
    w.join();
    try t.expectEqual(@as(u64, 1), w.status().durable_revision);
    for (0..100) |_| try t.expectEqual(@as(c_int, 0), glib.MainContext.default().iteration(0));
}
