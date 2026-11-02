const std = @import("std");
const t = std.testing;
const module = @import("../worker.zig");
const codec = @import("../codec.zig");
const storage = @import("../store.zig");
const history = @import("../history.zig");
const Worker = module.Worker;
const Owned = module.OwnedSnapshot;

fn snapshot(text: []const u8) !*Owned {
    return Owned.create(t.allocator, .{ .records = &.{.{ .bytes = text, .last_copy = 10, .sequence = 1 }}, .floor = 20 });
}
fn empty() !*Owned {
    return Owned.create(t.allocator, .{ .records = &.{}, .floor = 20 });
}

// All synchronization is predicate-based; no test sleeps or races the scheduler.
// Fake backend callbacks run only on the dedicated thread. Saved bytes are
// copied into independent fixed storage before the worker releases its input.
const Fake = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    hold: bool = false,
    hold_load: bool = false,
    load_entered: bool = false,
    calls: usize = 0,
    closes: usize = 0,
    saved: [512]u8 = undefined,
    len: usize = 0,
    fail_call: usize = 0,
    failure: storage.Error = error.WriteFailed,
    thread_id: ?std.Thread.Id = null,
    write_thread_id: ?std.Thread.Id = null,
    close_thread_id: ?std.Thread.Id = null,

    fn backend(self: *Fake) module.Backend {
        return .{ .context = self, .load = load, .persist = persist, .close = close };
    }
    fn load(context: *anyopaque) storage.Error!module.Key {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.thread_id = std.Thread.getCurrentId();
        self.load_entered = true;
        self.condition.broadcast(t.io);
        while (self.hold_load) self.condition.waitUncancelable(t.io, &self.mutex);
        return @splat(0);
    }
    fn persist(context: *anyopaque, value: codec.Snapshot, _: module.Operation) storage.Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.write_thread_id = std.Thread.getCurrentId();
        self.calls += 1;
        self.condition.broadcast(t.io);
        while (self.hold) self.condition.waitUncancelable(t.io, &self.mutex);
        if (self.calls == self.fail_call) return self.failure;
        self.len = 0;
        for (value.records) |record| {
            if (record.bytes.len + self.len + 1 > self.saved.len) return error.Failed;
            @memcpy(self.saved[self.len..][0..record.bytes.len], record.bytes);
            self.len += record.bytes.len;
            self.saved[self.len] = '\n';
            self.len += 1;
        }
    }
    fn close(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.close_thread_id = std.Thread.getCurrentId();
        self.closes += 1;
    }
    fn waitCall(self: *Fake, count: usize) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        while (self.calls < count) self.condition.waitUncancelable(t.io, &self.mutex);
    }
    fn release(self: *Fake) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.hold = false;
        self.hold_load = false;
        self.condition.broadcast(t.io);
    }
    fn start(self: *Fake) !*Worker {
        const worker = try Worker.startWithBackend(t.allocator, t.io, self.backend());
        errdefer worker.deinit();
        const status = worker.waitReady();
        try t.expect(status.initialized and status.failure == null);
        return worker;
    }
};

test "worker one save runs load write and close on its dedicated thread" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    try worker.requestSave(1, try snapshot("synthetic first"));
    const status = worker.waitIdle();
    try t.expectEqual(@as(u64, 1), status.durable_revision);
    try t.expectEqual(@as(usize, 1), fake.calls);
    try t.expectEqualStrings("synthetic first\n", fake.saved[0..fake.len]);
    try t.expect(fake.thread_id.? != std.Thread.getCurrentId());
    try t.expectEqual(fake.thread_id, fake.write_thread_id);
    worker.beginShutdown();
    worker.join();
    try t.expect(worker.status().stopped);
    try t.expectEqual(@as(usize, 1), fake.closes);
    try t.expectEqual(fake.thread_id, fake.close_thread_id);
}

test "worker combines rapid updates into the latest one pending snapshot" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    try worker.requestSave(1, try snapshot("active"));
    fake.waitCall(1);
    try worker.requestSave(2, try snapshot("superseded"));
    try worker.requestSave(3, try snapshot("also superseded"));
    try worker.requestSave(4, try snapshot("latest"));
    const pending = worker.status();
    try t.expectEqual(@as(?u64, 1), pending.active_revision);
    try t.expectEqual(@as(?u64, 4), pending.pending_revision);
    try t.expectEqual(@as(u64, 0), pending.durable_revision);
    fake.release();
    try t.expectEqual(@as(u64, 4), worker.waitIdle().durable_revision);
    try t.expectEqual(@as(usize, 2), fake.calls);
    try t.expectEqualStrings("latest\n", fake.saved[0..fake.len]);
}

test "worker unchanged snapshots advance durability without another disk write" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    try worker.requestSave(1, try snapshot("unchanged"));
    _ = worker.waitIdle();
    try worker.requestSave(2, try snapshot("unchanged"));
    try t.expectEqual(@as(u64, 2), worker.waitIdle().durable_revision);
    try t.expectEqual(@as(usize, 1), fake.calls);
    try t.expectEqual(@as(u64, 1), worker.status().write_count);
}

test "worker compares unchanged content in execution order after an intervening save" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    try worker.requestSave(1, try snapshot("original"));
    _ = worker.waitIdle();
    // Returning to old content still needs a write after an intervening value.
    try worker.requestSave(2, try snapshot("different"));
    _ = worker.waitIdle();
    try worker.requestSave(3, try snapshot("original"));
    _ = worker.waitIdle();
    try t.expectEqual(@as(usize, 3), fake.calls);
    try t.expectEqualStrings("original\n", fake.saved[0..fake.len]);
}

test "worker snapshot survives caller mutation and source deallocation" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    const source = try t.allocator.dupe(u8, "immutable across threads");
    const owned = try snapshot(source);
    try worker.requestSave(1, owned);
    fake.waitCall(1);
    @memset(source, 'x');
    t.allocator.free(source);
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqualStrings("immutable across threads\n", fake.saved[0..fake.len]);
}

test "worker text projection excludes PNG while history is cleared independently" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    var model = history.History.init(t.allocator);
    defer model.deinit();
    _ = try model.copy(.text, "saved text", 10);
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, png[16..20], 1, .big);
    std.mem.writeInt(u32, png[20..24], 1, .big);
    _ = try model.copy(.png, &png, 20);
    const projection = try codec.Projection.fromHistory(&model, 30, &.{ 2, 1 });
    try worker.requestSave(1, try Owned.create(t.allocator, projection.snapshot()));
    fake.waitCall(1);
    model.clear();
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqualStrings("saved text\n", fake.saved[0..fake.len]);
}

test "worker deleting during an earlier save preserves its durability barrier" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    try worker.requestSave(1, try snapshot("to delete"));
    fake.waitCall(1);
    const token = try worker.requestRemoval(.delete, 2, try snapshot("remaining"));
    try t.expectEqual(module.ReceiptState.pending, (try worker.receipt(token)).state);
    const later = try snapshot("remaining plus new");
    try t.expectError(error.Busy, worker.requestSave(3, later));
    try t.expectEqual(@as(u64, 2), worker.status().desired_revision);
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
    try worker.requestSave(3, later);
    _ = worker.waitIdle();
    try t.expectEqualStrings("remaining plus new\n", fake.saved[0..fake.len]);
}

test "worker Clear during an earlier save cannot be replaced by ordinary coalescing" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    try worker.requestSave(1, try snapshot("old"));
    fake.waitCall(1);
    try worker.requestSave(2, try snapshot("superseded pending"));
    const token = try worker.requestRemoval(.clear, 3, try empty());
    const rejected = try snapshot("new after clear");
    try t.expectError(error.Busy, worker.requestSave(4, rejected));
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
    try t.expectEqual(@as(usize, 0), fake.len);
    try worker.requestSave(4, rejected);
    _ = worker.waitIdle();
    try t.expectEqualStrings("new after clear\n", fake.saved[0..fake.len]);
    try t.expectEqual(@as(usize, 3), fake.calls);
}

test "worker active removal is running until backend synchronization completes" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    const token = try worker.requestRemoval(.clear, 1, try empty());
    fake.waitCall(1);
    try t.expectEqual(module.ReceiptState.running, (try worker.receipt(token)).state);
    try t.expectEqual(@as(u64, 0), worker.status().durable_revision);
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
}

test "worker expiry and PNG-eviction removals use non-coalescible barriers" {
    for ([_]module.Operation{ .expiry, .eviction }) |operation| {
        var fake: Fake = .{};
        const worker = try fake.start();
        defer worker.deinit();
        try worker.requestSave(1, try snapshot("old text"));
        _ = worker.waitIdle();
        const token = try worker.requestRemoval(operation, 2, try empty());
        _ = worker.waitIdle();
        try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
        try t.expectEqual(@as(usize, 0), fake.len);
    }
}

test "worker backpressure preserves caller ownership and never drops a pending barrier" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    const first = try worker.requestRemoval(.delete, 1, try snapshot("remaining"));
    fake.waitCall(1);
    const second = try worker.requestRemoval(.clear, 2, try empty());
    const rejected = try empty();
    defer rejected.deinit();
    try t.expectError(error.Busy, worker.requestRemoval(.clear, 3, rejected));
    try t.expectEqual(module.ReceiptState.running, (try worker.receipt(first)).state);
    try t.expectEqual(module.ReceiptState.pending, (try worker.receipt(second)).state);
    fake.release();
    _ = worker.waitIdle();
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(first)).state);
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(second)).state);
}

test "worker failed save fences later work and does not advance durable revision" {
    var fake: Fake = .{ .hold = true, .fail_call = 1 };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    try worker.requestSave(1, try snapshot("failed"));
    fake.waitCall(1);
    const cancelled = try worker.requestRemoval(.clear, 2, try empty());
    fake.release();
    const status = worker.waitIdle();
    try t.expectEqual(error.WriteFailed, status.failure.?);
    try t.expectEqual(@as(u64, 0), status.durable_revision);
    try t.expectEqual(module.ReceiptState.cancelled, (try worker.receipt(cancelled)).state);
    const rejected = try snapshot("not retried automatically");
    defer rejected.deinit();
    try t.expectError(error.Fenced, worker.requestSave(3, rejected));
    worker.join();
    try t.expectEqual(@as(usize, 1), fake.calls);
}

test "worker failed and uncertain removal receipts retain their actual outcomes" {
    for ([_]storage.Error{ error.WriteFailed, error.Uncertain }) |failure| {
        var fake: Fake = .{ .fail_call = 1, .failure = failure };
        const worker = try fake.start();
        defer worker.deinit();
        const token = try worker.requestRemoval(.clear, 1, try empty());
        const status = worker.waitIdle();
        const receipt = try worker.receipt(token);
        try t.expectEqual(if (failure == error.Uncertain) module.ReceiptState.uncertain else .failed, receipt.state);
        try t.expectEqual(failure, receipt.failure.?);
        try t.expectEqual(@as(u64, 0), status.durable_revision);
        worker.join();
        try t.expectEqual(failure, worker.status().failure.?);
    }
}

test "worker shutdown drains accepted pending work and rejects new requests" {
    var fake: Fake = .{ .hold = true };
    const worker = try fake.start();
    defer worker.deinit();
    defer fake.release();
    try worker.requestSave(1, try snapshot("active"));
    fake.waitCall(1);
    const token = try worker.requestRemoval(.delete, 2, try snapshot("final accepted"));
    worker.beginShutdown();
    const rejected = try snapshot("too late");
    defer rejected.deinit();
    try t.expectError(error.Closed, worker.requestSave(3, rejected));
    fake.release();
    worker.join();
    try t.expect(worker.status().stopped);
    try t.expectEqual(@as(u64, 2), worker.status().durable_revision);
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
    try t.expectEqualStrings("final accepted\n", fake.saved[0..fake.len]);
    try t.expectEqual(@as(usize, 2), fake.calls);
}

test "worker idle shutdown never publishes a teardown-empty snapshot" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    try worker.requestSave(1, try snapshot("preserved at shutdown"));
    _ = worker.waitIdle();
    worker.beginShutdown();
    worker.beginShutdown();
    worker.join();
    worker.join();
    try t.expectEqual(@as(usize, 1), fake.calls);
    try t.expectEqualStrings("preserved at shutdown\n", fake.saved[0..fake.len]);
}

test "worker startup is asynchronous and can shut down while load is pending" {
    var fake: Fake = .{ .hold_load = true };
    const worker = try Worker.startWithBackend(t.allocator, t.io, fake.backend());
    defer worker.deinit();
    defer fake.release();
    fake.mutex.lockUncancelable(t.io);
    while (!fake.load_entered) fake.condition.waitUncancelable(t.io, &fake.mutex);
    fake.mutex.unlock(t.io);
    try t.expect(!worker.status().initialized);
    const rejected = try snapshot("not loaded");
    defer rejected.deinit();
    try t.expectError(error.NotReady, worker.requestSave(1, rejected));
    worker.beginShutdown();
    fake.release();
    worker.join();
    try t.expectEqual(@as(usize, 0), fake.calls);
    try t.expect(worker.status().stopped);
}

test "worker bounded receipts evict only terminal records and reject stale revisions" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    const first = try worker.requestRemoval(.clear, 1, try empty());
    _ = worker.waitIdle();
    var newest = first;
    for (2..module.receipt_limit + 3) |revision| {
        newest = try worker.requestRemoval(.clear, revision, try empty());
        _ = worker.waitIdle();
    }
    try t.expectError(error.StaleReceipt, worker.receipt(first));
    try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(newest)).state);
    const rejected = try empty();
    defer rejected.deinit();
    try t.expectError(error.StaleRevision, worker.requestSave(1, rejected));
    try t.expectError(error.InvalidClear, worker.requestRemoval(.ordinary, 100, rejected));
}

fn copyFailure(allocator: std.mem.Allocator) !void {
    const owned = try Owned.create(allocator, .{ .records = &.{.{ .bytes = "allocation lifetime", .last_copy = 1, .sequence = 1 }}, .floor = 2 });
    defer owned.deinit();
}
test "worker snapshot preparation releases every failed allocation and rejects PNG input" {
    try t.checkAllAllocationFailures(t.allocator, copyFailure, .{});
    try t.expectError(error.Corrupt, snapshot("\x89PNG\r\n\x1a\n"));
}

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
const Fixture = struct {
    root: [:0]u8,
    path: [:0]u8,
    fn init() !Fixture {
        const root = try t.allocator.dupeSentinel(u8, "/tmp/pearl-worker-test-XXXXXX", 0);
        errdefer t.allocator.free(root);
        if (mkdtemp(root) == null) return error.TestDirectory;
        errdefer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
        return .{ .root = root, .path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl/clipboard", .{root}, 0) };
    }
    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(t.io, self.root) catch @panic("temporary worker test cleanup failed");
        t.allocator.free(self.path);
        t.allocator.free(self.root);
    }
    fn start(self: *Fixture, hooks: storage.Hooks) !*Worker {
        const worker = try Worker.start(t.allocator, t.io, self.path, hooks);
        errdefer worker.deinit();
        const status = worker.waitReady();
        try t.expectEqual(@as(?storage.Error, null), status.failure);
        return worker;
    }
};

test "worker real store reopens saved text after thread exit and avoids rewriting unchanged restart state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        const worker = try fixture.start(.{});
        defer worker.deinit();
        try worker.requestSave(1, try snapshot("saved across restart"));
        _ = worker.waitIdle();
        worker.beginShutdown();
        worker.join();
    }
    {
        var store = try storage.Store.open(t.allocator, fixture.path);
        defer store.close();
        var loaded = (try store.read()).?;
        defer loaded.deinit();
        try t.expectEqualStrings("saved across restart", loaded.snapshot().records[0].bytes);
    }
    const restarted = try fixture.start(.{});
    defer restarted.deinit();
    try restarted.requestSave(1, try snapshot("saved across restart"));
    try t.expectEqual(@as(u64, 0), restarted.waitIdle().write_count);
}

test "worker real store Clear remains absent after shutdown and reopening" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        const worker = try fixture.start(.{});
        defer worker.deinit();
        try worker.requestSave(1, try snapshot("remove durably"));
        _ = worker.waitIdle();
        const token = try worker.requestRemoval(.clear, 2, try empty());
        worker.beginShutdown();
        worker.join();
        try t.expectEqual(module.ReceiptState.durable, (try worker.receipt(token)).state);
    }
    var store = try storage.Store.open(t.allocator, fixture.path);
    defer store.close();
    try t.expect((try store.read()) == null);
}

test "worker nonempty removals clean orphan plaintext and never falsely confirm cleanup failures" {
    const Variant = enum { clean, unsafe_temp, publish_failure, sync_failure };
    for ([_]module.Operation{ .delete, .expiry, .eviction }) |operation| {
        for ([_]Variant{ .clean, .unsafe_temp, .publish_failure, .sync_failure }) |variant| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            const orphan = "history.tmp.0123456789abcdef0123456789abcdef";
            {
                var store = try storage.Store.open(t.allocator, fixture.path);
                defer store.close();
                _ = try store.read();
                const old = try snapshot("synthetic deleted plaintext");
                defer old.deinit();
                try store.write(old.view());
                const fd = std.c.openat(store.directoryFd(), orphan, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
                try t.expect(fd >= 0);
                defer _ = std.c.close(fd);
                const text = "synthetic deleted plaintext";
                try t.expectEqual(@as(isize, text.len), std.c.write(fd, text.ptr, text.len));
                try t.expectEqual(@as(c_int, 0), std.c.fchmod(fd, if (variant == .unsafe_temp) 0o644 else 0o600));
            }
            var fault: RealFault = .{ .phase = if (variant == .publish_failure) .publish else .directory_sync };
            const hooks: storage.Hooks = if (variant == .publish_failure or variant == .sync_failure) fault.hooks() else .{};
            const worker = try fixture.start(hooks);
            defer worker.deinit();
            const token = try worker.requestRemoval(operation, 1, try snapshot("synthetic remaining text"));
            const status = worker.waitIdle();
            const receipt = try worker.receipt(token);
            const expected_state: module.ReceiptState = if (variant == .clean) .durable else if (variant == .publish_failure) .failed else .uncertain;
            try t.expectEqual(expected_state, receipt.state);
            try t.expectEqual(@as(u64, if (variant == .clean) 1 else 0), status.durable_revision);
            if (variant == .clean) {
                try t.expectEqual(@as(?storage.Error, null), receipt.failure);
            } else {
                try t.expectEqual(if (variant == .publish_failure) error.PublishFailed else error.Uncertain, receipt.failure.?);
                try t.expectEqual(receipt.failure, status.failure);
            }
            worker.beginShutdown();
            worker.join();
            var disk = try storage.Store.open(t.allocator, fixture.path);
            defer disk.close();
            var loaded = (try disk.read()).?;
            defer loaded.deinit();
            try t.expectEqualStrings(if (variant == .publish_failure) "synthetic deleted plaintext" else "synthetic remaining text", loaded.snapshot().records[0].bytes);
            var st: std.os.linux.Statx = undefined;
            const result = std.os.linux.statx(disk.directoryFd(), orphan, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st);
            try t.expectEqual(if (variant == .unsafe_temp or variant == .publish_failure) std.posix.E.SUCCESS else .NOENT, std.os.linux.errno(result));
            if (variant == .unsafe_temp) try t.expectEqual(@as(u16, 0o644), st.mode & 0o7777);
        }
    }
}

test "worker concurrent real writer reports Busy asynchronously" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = try fixture.start(.{});
    defer first.deinit();
    const second = try Worker.start(t.allocator, t.io, fixture.path, .{});
    defer second.deinit();
    try t.expectEqual(error.Busy, second.waitReady().failure.?);
    second.join();
    try t.expect(!second.status().accepting);
}

const RealFault = struct {
    phase: storage.Phase,
    thread_id: ?std.Thread.Id = null,
    fn check(context: ?*anyopaque, phase: storage.Phase) error{InjectedFailure}!void {
        const self: *RealFault = @ptrCast(@alignCast(context.?));
        self.thread_id = std.Thread.getCurrentId();
        if (phase == self.phase) return error.InjectedFailure;
    }
    fn hooks(self: *RealFault) storage.Hooks {
        return .{ .context = self, .before = check };
    }
};

test "worker actual store failures preserve prepublication data and report postpublication uncertainty" {
    for ([_]storage.Phase{ .write, .directory_sync }) |phase| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        {
            var store = try storage.Store.open(t.allocator, fixture.path);
            defer store.close();
            try t.expect((try store.read()) == null);
            const old = try snapshot("previous durable");
            defer old.deinit();
            try store.write(old.view());
        }
        var fault: RealFault = .{ .phase = phase };
        {
            const worker = try fixture.start(fault.hooks());
            defer worker.deinit();
            try worker.requestSave(1, try snapshot("candidate"));
            const status = worker.waitIdle();
            try t.expectEqual(if (phase == .write) error.WriteFailed else error.Uncertain, status.failure.?);
            try t.expectEqual(@as(u64, 0), status.durable_revision);
            worker.join();
            try t.expect(fault.thread_id.? != std.Thread.getCurrentId());
        }
        var store = try storage.Store.open(t.allocator, fixture.path);
        defer store.close();
        var loaded = (try store.read()).?;
        defer loaded.deinit();
        try t.expectEqualStrings(if (phase == .write) "previous durable" else "candidate", loaded.snapshot().records[0].bytes);
    }
}

test "worker real Clear synchronization failure never acknowledges durable deletion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        const worker = try fixture.start(.{});
        defer worker.deinit();
        try worker.requestSave(1, try snapshot("delete with uncertain sync"));
        _ = worker.waitIdle();
    }
    var fault: RealFault = .{ .phase = .directory_sync };
    {
        const worker = try fixture.start(fault.hooks());
        defer worker.deinit();
        const token = try worker.requestRemoval(.clear, 1, try empty());
        _ = worker.waitIdle();
        try t.expectEqual(module.ReceiptState.uncertain, (try worker.receipt(token)).state);
        try t.expectEqual(@as(u64, 0), worker.status().durable_revision);
        worker.join();
    }
    var store = try storage.Store.open(t.allocator, fixture.path);
    defer store.close();
    try t.expect((try store.read()) == null);
}

test "worker receipt-counter exhaustion rejects admission without consuming input" {
    var fake: Fake = .{};
    const worker = try fake.start();
    defer worker.deinit();
    // No submissions exist and the worker is idle; use its mailbox lock to
    // inject exhaustion without creating a test data race.
    worker.mutex.lockUncancelable(t.io);
    worker.next_token = std.math.maxInt(u64);
    worker.mutex.unlock(t.io);
    const owned = try empty();
    defer owned.deinit();
    try t.expectError(error.CounterExhausted, worker.requestRemoval(.clear, 1, owned));
    try t.expectEqual(@as(u64, 0), worker.status().desired_revision);
    try t.expectEqual(@as(usize, 0), fake.calls);
}

fn launchFailure(allocator: std.mem.Allocator) !void {
    var fake: Fake = .{};
    const worker = try Worker.startWithBackend(allocator, t.io, fake.backend());
    defer worker.deinit();
    try t.expect(worker.waitReady().initialized);
}

test "worker failed allocation during launch leaves no live thread or ownership" {
    try t.checkAllAllocationFailures(t.allocator, launchFailure, .{});
}
