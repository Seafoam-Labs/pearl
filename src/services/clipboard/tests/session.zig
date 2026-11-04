const std = @import("std");
const t = std.testing;
const session = @import("../session.zig");
const codec = @import("../codec.zig");
const store = @import("../store.zig");
const model = @import("../history.zig");
const clock = @import("../clock.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

fn at(seconds: i64) clock.Sample {
    return .{ .wall_seconds = seconds, .boottime_ns = @as(u64, @intCast(seconds)) * 1_000_000_000 };
}
const Fixture = struct {
    root: [:0]u8,
    path: [:0]u8,
    fn init() !Fixture {
        const root = try t.allocator.dupeSentinel(u8, "/tmp/pearl-session-test-XXXXXX", 0);
        errdefer t.allocator.free(root);
        if (mkdtemp(root) == null) return error.TestDirectory;
        errdefer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
        return .{ .root = root, .path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl/clipboard", .{root}, 0) };
    }
    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(t.io, self.root) catch @panic("session test cleanup failed");
        t.allocator.free(self.path);
        t.allocator.free(self.root);
    }
    fn start(self: *Fixture, now: clock.Sample) !session.Session {
        return self.startHooks(now, .{});
    }
    fn startHooks(self: *Fixture, now: clock.Sample, hooks: store.Hooks) !session.Session {
        var result = try session.Session.init(t.allocator, t.io, self.path, hooks);
        errdefer close(&result);
        result.setLocked(false);
        _ = try result.updateWorker(now);
        _ = result.worker.?.waitReady();
        _ = try result.updateWorker(now);
        return result;
    }
};
fn close(s: *session.Session) void {
    s.beginShutdown();
    if (s.worker) |worker| worker.join();
    s.deinit();
}
fn settle(s: *session.Session, now: clock.Sample) !void {
    _ = try s.updateWorker(now);
    if (s.worker) |worker| _ = worker.waitIdle();
    _ = try s.updateWorker(now);
}
fn image(size: usize, marker: u8) ![]u8 {
    const bytes = try t.allocator.alloc(u8, size);
    @memset(bytes, marker);
    @memcpy(bytes[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, bytes[16..20], 1, .big);
    std.mem.writeInt(u32, bytes[20..24], 1, .big);
    return bytes;
}

test "session new text requests a save and restores original times after restart" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var s = try fixture.start(at(100));
        defer close(&s);
        _ = try s.accept(.text, "synthetic persistent text", at(100));
        try t.expectEqual(@as(u64, 1), s.worker.?.status().desired_revision);
        try settle(&s, at(100));
        try t.expectEqual(session.Health.durable, s.health());
    }
    var restored = try fixture.start(at(200));
    defer close(&restored);
    try t.expectEqual(@as(usize, 1), restored.entries().len);
    try t.expectEqualStrings("synthetic persistent text", restored.entries()[0].bytes);
    try t.expectEqual(@as(i64, 100), restored.entries()[0].last_copy);
    try t.expectEqual(@as(u64, 1), restored.entries()[0].sequence);
    try t.expectEqual(@as(u64, 0), restored.worker.?.status().write_count);
}

test "session front recopy refreshes persisted timestamp and sequence" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const id = try s.accept(.text, "recopied", at(100));
    try settle(&s, at(100));
    try t.expectEqual(id, try s.accept(.text, "recopied", at(200)));
    try settle(&s, at(200));
    try t.expectEqual(@as(i64, 200), s.entries()[0].last_copy);
    try t.expectEqual(@as(u64, 2), s.entries()[0].sequence);
    try t.expectEqual(@as(u64, 2), s.worker.?.status().desired_revision);
    close(&s);
    s = try fixture.start(at(201));
    try t.expectEqual(@as(i64, 200), s.entries()[0].last_copy);
    try t.expectEqual(@as(u64, 2), s.entries()[0].sequence);
}

test "session lock preserves text and PNG but forbids collection listing selection and removal" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const id = try s.accept(.text, "private while locked", at(100));
    const png = try image(33, 1);
    defer t.allocator.free(png);
    _ = try s.accept(.png, png, at(100));
    try settle(&s, at(100));
    s.setLocked(true);
    try t.expectEqual(@as(usize, 2), s.model.entries().len);
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectError(error.Locked, s.accept(.text, "rejected", at(101)));
    try t.expectError(error.Locked, s.prepareSelection(id, at(101)));
    try t.expectError(error.Locked, s.delete(id, at(101)));
    try t.expectError(error.Locked, s.clear());
    s.setLocked(false);
    _ = try s.updateWorker(at(102));
    try t.expectEqual(@as(usize, 2), s.entries().len);
    try t.expectEqual(@as(i64, 100), s.entries()[1].last_copy);
    try t.expectEqual(@as(u64, 1), s.worker.?.status().write_count);
}

test "session startup while locked defers payload loading and never renews restored copies" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var s = try fixture.start(at(100));
        defer close(&s);
        _ = try s.accept(.text, "original lifetime", at(100));
        try settle(&s, at(100));
    }
    var s = try session.Session.init(t.allocator, t.io, fixture.path, .{});
    defer close(&s);
    _ = try s.updateWorker(at(200));
    try t.expect(s.worker == null);
    try t.expectEqual(@as(usize, 0), s.entries().len);
    s.setLocked(false);
    _ = try s.updateWorker(at(200));
    _ = s.worker.?.waitReady();
    // Completion remains readable even when startup wins the race with watch
    // attachment. No history request or periodic tick is needed for handoff.
    var wake = [_]std.c.pollfd{.{ .fd = s.worker.?.completion.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try t.expectEqual(@as(c_int, 1), std.c.poll(&wake, 1, 0));
    s.worker.?.completion.drain();
    s.setLocked(true); // a lock arriving during load withholds its handoff
    _ = try s.updateWorker(at(200));
    try t.expect(!s.ready);
    s.setLocked(false);
    _ = try s.updateWorker(at(200));
    const first_worker = s.worker.?;
    try t.expectEqual(@as(i64, 100), s.entries()[0].last_copy);
    try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
    s.setLocked(true);
    s.setLocked(false);
    _ = try s.updateWorker(null);
    try t.expectEqual(first_worker, s.worker.?);
}

test "session PNG-only changes never write PNG and PNG eviction persists lost text" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    _ = try s.accept(.text, "text to evict", at(100));
    try settle(&s, at(100));
    const png = try image(8 * 1024 * 1024, 1);
    defer t.allocator.free(png);
    _ = try s.accept(.png, png, at(101));
    try settle(&s, at(101));
    try t.expectEqual(@as(u64, 1), s.worker.?.status().write_count);
    png[32] = 2;
    _ = try s.accept(.png, png, at(102));
    try settle(&s, at(102));
    try t.expectEqual(@as(usize, 2), s.entries().len);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
    close(&s);
    s = try fixture.start(at(103));
    try t.expectEqual(@as(usize, 0), s.entries().len);
}
fn moduleReceiptDurable() @import("../worker.zig").ReceiptState {
    return .durable;
}

test "session idle completion and lock transitions do not expire history; access expires at seven days" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    _ = try s.accept(.text, "expires", at(100));
    try settle(&s, at(100));
    s.setLocked(true);
    try settle(&s, at(100 + 604800));
    try t.expectEqual(@as(usize, 1), s.model.entries().len);
    try t.expectEqual(@as(u64, 1), s.worker.?.status().write_count);
    s.setLocked(false);
    _ = try s.accessHistory(at(100 + 604799));
    try t.expectEqual(@as(usize, 1), s.entries().len);
    _ = try s.accessHistory(at(100 + 604800));
    try settle(&s, at(100 + 604800));
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session access batches expired text into one durable barrier and idle reads cause no writes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    for ([_][]const u8{ "one", "two", "three" }) |text| {
        _ = try s.accept(.text, text, at(100));
        try settle(&s, at(100));
    }
    const writes = s.worker.?.status().write_count;
    const generation = s.model.generation;
    for (0..100) |_| {
        _ = try s.updateWorker(null);
        try t.expect(!try s.accessHistory(at(101)));
    }
    try t.expectEqual(generation, s.model.generation);
    try t.expectEqual(writes, s.worker.?.status().write_count);
    // A distant worker notification is not history activity and leaves time,
    // generation, disk and expired payloads untouched.
    _ = try s.updateWorker(at(100 + 604801));
    try t.expectEqual(@as(i64, 101), s.now);
    try t.expectEqual(@as(usize, 3), s.model.len);
    try t.expect(try s.accessHistory(at(100 + 604801)));
    try settle(&s, at(100 + 604801));
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(writes + 1, s.worker.?.status().write_count);
    try t.expectEqual(session.worker.Operation.expiry, (try s.removal()).operation);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session recopy refreshes retention and expired selections cannot be reused" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const id = try s.accept(.text, "refreshed", at(100));
    try settle(&s, at(100));
    try t.expectEqual(id, try s.accept(.text, "refreshed", at(200)));
    try settle(&s, at(200));
    _ = try s.accessHistory(at(100 + 604800));
    try t.expectEqual(id, s.entries()[0].id);
    try t.expectError(error.Stale, s.prepareSelection(id, at(200 + 604801)));
    try settle(&s, at(200 + 604801));
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session copy and Delete batch lazy expiry into their single removal barrier; Clear skips expiry" {
    for (0..3) |action| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var s = try fixture.start(at(100));
        defer close(&s);
        _ = try s.accept(.text, "expired", at(100));
        try settle(&s, at(100));
        const live = try s.accept(.text, "live", at(200));
        try settle(&s, at(200));
        const revision = s.save_revision;
        switch (action) {
            0 => _ = try s.accept(.text, "new", at(100 + 604800)),
            1 => try s.delete(live, at(100 + 604800)),
            else => try s.clear(),
        }
        try settle(&s, at(100 + 604800));
        try t.expectEqual(revision + 1, s.save_revision);
        try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
        try t.expectEqual(@as(usize, if (action == 0) 2 else 0), s.entries().len);
    }
}

test "session Delete and Clear expose durable receipts instead of immediate promises" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const id = try s.accept(.text, "delete this", at(100));
    try settle(&s, at(100));
    _ = try s.accept(.text, "keep this", at(101));
    try settle(&s, at(101));
    try s.delete(id, at(102));
    try t.expectEqual(@as(usize, 1), s.entries().len);
    try settle(&s, at(102));
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
    try s.clear();
    try settle(&s, at(102));
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
    try t.expectEqual(@as(usize, 0), s.entries().len);
}

test "session prepared selection leaves order and persistence alone until commit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const old = try s.accept(.text, "old", at(100));
    _ = try s.accept(.text, "new", at(101));
    try settle(&s, at(101));
    var candidate = try s.prepareSelection(old, at(102));
    candidate.discard(); // native source allocation failed before commit
    try t.expectEqualStrings("new", s.entries()[0].bytes);
    try t.expectEqual(@as(u64, 2), s.worker.?.status().desired_revision);
    candidate = try s.prepareSelection(old, at(103));
    defer candidate.discard();
    try s.commit(&candidate);
    try t.expectEqual(old, s.entries()[0].id);
    try t.expectEqual(@as(i64, 103), s.entries()[0].last_copy);
}

test "session refuses untrusted saved clock floor and preserves saved bytes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var s = try fixture.start(at(1000));
        defer close(&s);
        _ = try s.accept(.text, "clock protected", at(1000));
        try settle(&s, at(1000));
    }
    var s = try session.Session.init(t.allocator, t.io, fixture.path, .{});
    defer close(&s);
    s.setLocked(false);
    _ = try s.updateWorker(at(699));
    _ = s.worker.?.waitReady();
    try t.expectError(error.ClockUntrusted, s.updateWorker(at(699)));
    try t.expect(!s.canRecoverClear());
    try t.expectError(error.ClockUntrusted, s.clear());
    try t.expectEqual(session.Health.clock_untrusted, s.health());
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
}

test "clock permits inclusive 300-second startup skew and never rewinds runtime age" {
    var c: clock.Clock = .{};
    try t.expectEqual(@as(i64, 1000), try c.start(at(700), 1000));
    try t.expectEqual(@as(i64, 1001), try c.advance(.{ .wall_seconds = 600, .boottime_ns = 701_000_000_000 }));
    try t.expectError(error.ClockUntrusted, c.advance(.{ .wall_seconds = 1000, .boottime_ns = 1 }));
    var invalid: clock.Clock = .{};
    try t.expectError(error.ClockUntrusted, invalid.start(at(699), 1000));
}

test "session concurrent writer stays unavailable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    var other = try session.Session.init(t.allocator, t.io, fixture.path, .{});
    defer close(&other);
    other.setLocked(false);
    _ = try other.updateWorker(at(100));
    _ = other.worker.?.waitReady();
    try t.expectError(error.Busy, other.updateWorker(at(100)));
    try t.expectEqual(@as(usize, 0), other.entries().len);
    try t.expectError(error.Busy, other.accept(.text, "rejected", at(100)));
    try t.expect(!other.canRecoverClear());
    try t.expectError(error.Busy, other.clear());
}

test "session bounded legacy status includes complete frame overhead and redacts locked history" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    for (0..100) |i| {
        var bytes: [120]u8 = @splat('"'); // every preview byte requires JSON escaping
        bytes[119] = @intCast(33 + i % 90);
        bytes[118] = @intCast(33 + i / 90);
        _ = try s.accept(.text, &bytes, at(100));
    }
    try settle(&s, at(100));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const result = try session.legacyStatus(&s, arena.allocator(), true, false, "Ready");
    const frame = try std.fmt.allocPrint(arena.allocator(), "{{\"pearl\":1,\"id\":\"12345678901234567890\",\"ok\":true,\"result\":{s}}}\n", .{result});
    try t.expect(frame.len <= 8192);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), result, .{});
    try t.expectEqual(@as(i64, 100), parsed.object.get("total").?.integer);
    try t.expect(parsed.object.get("entries").?.array.items.len <= 20);
    s.setLocked(true);
    const hidden = try session.legacyStatus(&s, arena.allocator(), true, false, "Paused");
    const h = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), hidden, .{});
    try t.expectEqual(@as(usize, 0), h.object.get("entries").?.array.items.len);
    try t.expectEqual(std.json.Value.null, h.object.get("total").?);
}

test "session sensitive clipboard MIME hints remain excluded" {
    const policy = @import("../../clipboard_policy.zig");
    for ([_][]const u8{ "x-kde-passwordManagerHint", "application/x-keepassxc", "application/x-pearl-private" }) |mime| try t.expect(policy.sensitiveMime(mime));
    try t.expect(!policy.sensitiveMime("text/plain"));
}

test "session startup discards expired records with a durable barrier and fresh runtime IDs" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var s = try fixture.start(at(100));
        defer close(&s);
        s.model.next_id = 900;
        _ = try s.accept(.text, "expired", at(100));
        _ = try s.accept(.text, "still eligible", at(200));
        try settle(&s, at(200));
    }
    var s = try fixture.start(at(100 + model.lifetime_seconds));
    defer close(&s);
    try settle(&s, at(100 + model.lifetime_seconds));
    try t.expectEqual(@as(usize, 1), s.entries().len);
    try t.expect(s.entries()[0].id < 900);
    try t.expectEqualStrings("still eligible", s.entries()[0].bytes);
    try t.expectEqual(@as(i64, 200), s.entries()[0].last_copy);
    try t.expectEqual(@as(u64, 2), s.entries()[0].sequence);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session never rewrites unchanged history or creates an empty shutdown snapshot" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    for (101..110) |now| try settle(&s, at(@intCast(now)));
    try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
    s.beginShutdown();
    s.worker.?.join();
    try t.expectEqual(@as(u64, 0), s.worker.?.status().desired_revision);
    s.deinit();
    var disk = try store.Store.open(t.allocator, fixture.path);
    defer disk.close();
    try t.expect((try disk.read()) == null);
}

test "session abandoned prepared copy cannot commit after locking" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    var tx = try s.prepareCopy(.text, "never admitted", at(100));
    defer tx.discard();
    s.setLocked(true);
    try t.expectError(error.Locked, s.commit(&tx));
    try t.expectEqual(@as(usize, 0), s.model.len);
    try t.expectEqual(@as(u64, 0), s.worker.?.status().desired_revision);
}

test "session snapshot allocation failure aborts a prepared copy without changing live history" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    const id = try s.accept(.text, "retained on allocation failure", at(100));
    try settle(&s, at(100));
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    s.allocator = failing.allocator();
    defer s.allocator = t.allocator;
    try t.expectError(error.OutOfMemory, s.prepareCopy(.text, "aborted candidate", at(101)));
    try t.expectEqual(@as(usize, 1), s.model.len);
    try t.expectEqual(id, s.entries()[0].id);
    try t.expectEqualStrings("retained on allocation failure", s.entries()[0].bytes);
    try t.expectEqual(@as(u64, 1), s.worker.?.status().desired_revision);
}

// Hooks are synchronized predicates, never timer-based. The only filesystem
// paths are Fixture's private synthetic tree; callbacks execute on the worker.
const Hook = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    hold: bool = false,
    entered: bool = false,
    fail: ?store.Phase = null,
    thread: ?std.Thread.Id = null,
    fn hooks(self: *Hook) store.Hooks {
        return .{ .context = self, .before = before };
    }
    fn before(context: ?*anyopaque, phase: store.Phase) error{InjectedFailure}!void {
        const self: *Hook = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.thread = std.Thread.getCurrentId();
        if (phase == .file_sync) {
            self.entered = true;
            self.condition.broadcast(t.io);
            while (self.hold) self.condition.waitUncancelable(t.io, &self.mutex);
        }
        if (self.fail == phase) return error.InjectedFailure;
    }
    fn wait(self: *Hook) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        while (!self.entered) self.condition.waitUncancelable(t.io, &self.mutex);
    }
    fn release(self: *Hook) void {
        self.mutex.lockUncancelable(t.io);
        defer self.mutex.unlock(t.io);
        self.hold = false;
        self.condition.broadcast(t.io);
    }
};

test "session Busy expiry hides all history and retries only on subsequent activity" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var hook: Hook = .{ .hold = true };
    var s = try fixture.startHooks(at(100), hook.hooks());
    defer close(&s);
    defer hook.release();
    const id = try s.accept(.text, "expires while storage busy", at(100));
    hook.wait();
    // Hold one active save and a required pending removal. The latter cannot
    // be superseded by expiry or by an attempted recopy.
    const pending = try session.worker.OwnedSnapshot.create(t.allocator, .{ .records = &.{.{ .bytes = "expires while storage busy", .last_copy = 100, .sequence = 1 }}, .floor = 100 });
    _ = try s.worker.?.requestRemoval(.delete, 2, pending);
    s.save_revision = 2;
    try t.expectError(error.Busy, s.accessHistory(at(100 + 604801)));
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(@as(usize, 1), s.model.len);
    try t.expectError(error.Busy, s.prepareSelection(id, at(100 + 604801)));
    hook.release();
    try settle(&s, at(100 + 604801));
    try t.expectEqual(@as(usize, 1), s.model.len);
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expect(try s.accessHistory(at(100 + 604801)));
    try settle(&s, at(100 + 604801));
    try t.expectEqual(@as(usize, 0), s.model.len);
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session expiry snapshot allocation failure hides expired history until retried" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    _ = try s.accept(.text, "expired allocation failure", at(100));
    try settle(&s, at(100));
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    s.allocator = failing.allocator();
    defer s.allocator = t.allocator;
    try t.expectError(error.OutOfMemory, s.accessHistory(at(100 + 604801)));
    try t.expectEqual(@as(usize, 0), s.entries().len);
    try t.expectEqual(@as(usize, 1), s.model.len);
    s.allocator = t.allocator;
    _ = try s.accessHistory(at(100 + 604801));
    try settle(&s, at(100 + 604801));
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
}

test "session reports write failure and post-publication uncertainty without durable success" {
    for ([_]store.Phase{ .write, .directory_sync }) |phase| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var hook: Hook = .{ .fail = phase };
        var s = try fixture.startHooks(at(100), hook.hooks());
        defer close(&s);
        _ = try s.accept(.text, "synthetic failed write", at(100));
        const status = s.worker.?.waitIdle();
        const expected: store.Error = if (phase == .write) error.WriteFailed else error.Uncertain;
        try t.expectEqual(expected, status.failure.?);
        try t.expectEqual(@as(u64, 0), status.durable_revision);
        try t.expectEqual(if (phase == .write) session.Health.failed else session.Health.uncertain, s.health());
        try t.expectEqual(@as(usize, 0), s.entries().len);
        try t.expectError(expected, s.updateWorker(at(101)));
        try t.expect(hook.thread.? != std.Thread.getCurrentId());
    }
}

test "session failed and uncertain removals return admission and query receipts while unlocked" {
    for ([_]session.worker.Operation{ .delete, .clear }) |operation| {
        for ([_]store.Phase{ .remove, .directory_sync }) |phase| {
            var fixture = try Fixture.init();
            defer fixture.deinit();
            {
                var disk = try store.Store.open(t.allocator, fixture.path);
                defer disk.close();
                _ = try disk.read();
                try disk.write(.{ .records = &.{
                    .{ .bytes = "synthetic to remove", .last_copy = 100, .sequence = 2 },
                    .{ .bytes = "synthetic retained text", .last_copy = 100, .sequence = 1 },
                }, .floor = 100 });
            }
            var hook: Hook = .{ .fail = if (operation == .delete and phase == .remove) .publish else phase };
            var s = try fixture.startHooks(at(100), hook.hooks());
            defer close(&s);
            if (operation == .delete) try s.delete(s.entries()[0].id, at(100)) else try s.clear();
            _ = s.worker.?.waitIdle();
            const receipt = try s.removal();
            try t.expectEqual(operation, receipt.operation);
            try t.expectEqual(if (phase == .remove) session.worker.ReceiptState.failed else session.worker.ReceiptState.uncertain, receipt.state);
            try t.expectEqual(if (phase == .remove) session.presentation.Feedback.removal_failed else session.presentation.Feedback.removal_uncertain, s.feedback());
            const hidden = try s.pageStatus(t.allocator, true, false, "Persistence unavailable", .{});
            defer t.allocator.free(hidden);
            const parsed_status = try std.json.parseFromSlice(std.json.Value, t.allocator, hidden, .{});
            defer parsed_status.deinit();
            try t.expectEqual(std.json.Value.null, parsed_status.value.object.get("removal").?);
            try t.expectEqualStrings(if (phase == .remove) "failed" else "uncertain", parsed_status.value.object.get("persistence").?.string);
            try t.expectError(receipt.failure.?, s.updateWorker(at(101)));
            // Exercise the initial response after the worker has already failed.
            const admitted = try s.removalStatus(t.allocator);
            defer t.allocator.free(admitted);
            const response = try std.json.parseFromSlice(std.json.Value, t.allocator, admitted, .{});
            defer response.deinit();
            try t.expect(response.value.object.get("queued").?.bool);
            try t.expect(!response.value.object.get("durable").?.bool);
            try t.expectEqualStrings(@tagName(receipt.state), response.value.object.get("state").?.string);
            try t.expectEqual(receipt.token, @as(u64, @intCast(response.value.object.get("operation").?.integer)));
            try t.expectEqualStrings(&s.instance, response.value.object.get("instance").?.string);
            const page: session.presentation.Page = .{ .operation = receipt.token, .instance = &s.instance };
            // Device availability is also false once the service fences storage.
            const queried = try s.pageStatus(t.allocator, false, false, "Persistence unavailable", page);
            defer t.allocator.free(queried);
            const result = try std.json.parseFromSlice(std.json.Value, t.allocator, queried, .{});
            defer result.deinit();
            try t.expectEqualStrings(if (phase == .remove) "failed" else "uncertain", result.value.object.get("removal").?.object.get("state").?.string);
            try t.expectEqual(@as(usize, 0), result.value.object.get("entries").?.array.items.len);
            for ([_][]const u8{ "total", "offset", "limit", "returned", "next_offset", "revision", "instance" }) |field| try t.expectEqual(std.json.Value.null, result.value.object.get(field).?);
            try t.expectError(error.InstanceRequired, s.pageStatus(t.allocator, false, false, "", .{ .operation = receipt.token }));
            try t.expectError(error.StaleInstance, s.pageStatus(t.allocator, false, false, "", .{ .operation = receipt.token, .instance = "00000000000000000000000000000000" }));
            try t.expectError(error.StaleOperation, s.pageStatus(t.allocator, false, false, "", .{ .operation = receipt.token + 1, .instance = &s.instance }));
            try t.expectError(error.StaleOperation, s.pageStatus(t.allocator, false, false, "", .{ .operation = 0, .instance = &s.instance }));
            s.setLocked(true);
            try t.expectError(error.Locked, s.pageStatus(t.allocator, false, false, "", page));
            try t.expectError(error.Locked, s.removalStatus(t.allocator));
            s.setLocked(false);
            s.beginShutdown();
            try t.expectError(error.Locked, s.pageStatus(t.allocator, false, false, "", page));
            try t.expectError(error.Locked, s.removalStatus(t.allocator));
            try t.expectEqual(@as(u64, 0), s.worker.?.status().durable_revision);
            try t.expect(!s.accessible());
        }
    }
}

test "session Busy leaves model unchanged and a queued Clear fences resurrection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var hook: Hook = .{ .hold = true };
    var s = try fixture.startHooks(at(100), hook.hooks());
    defer close(&s);
    defer hook.release();
    _ = try s.accept(.text, "active write", at(100));
    hook.wait();
    try t.expectEqual(session.Health.pending, s.health());
    try s.clear();
    try t.expectEqual(session.worker.ReceiptState.pending, (try s.removal()).state);
    const token = (try s.removal()).token;
    try t.expectEqual(session.presentation.Feedback.removal_pending, s.feedback());
    const pending = try s.pageStatus(t.allocator, true, false, "Pending", .{ .operation = token, .instance = &s.instance });
    defer t.allocator.free(pending);
    const pending_json = try std.json.parseFromSlice(std.json.Value, t.allocator, pending, .{});
    defer pending_json.deinit();
    try t.expectEqualStrings("pending", pending_json.value.object.get("removal").?.object.get("state").?.string);
    s.setLocked(true);
    try t.expectError(error.Locked, s.pageStatus(t.allocator, true, false, "Paused", .{ .operation = token, .instance = &s.instance }));
    s.setLocked(false);
    try t.expectError(error.Busy, s.accept(.text, "must not resurrect", at(101)));
    try t.expectEqual(@as(usize, 0), s.model.len);
    try t.expectEqual(@as(u64, 2), s.worker.?.status().desired_revision);
    try t.expectError(error.Busy, s.clear());
    hook.release();
    try settle(&s, at(101));
    try t.expectEqual(moduleReceiptDurable(), (try s.removal()).state);
    try t.expectEqual(session.presentation.Feedback.removal_durable, s.feedback());
    const durable = try s.pageStatus(t.allocator, true, false, "Saved", .{ .operation = token, .instance = &s.instance });
    defer t.allocator.free(durable);
    const durable_json = try std.json.parseFromSlice(std.json.Value, t.allocator, durable, .{});
    defer durable_json.deinit();
    try t.expectEqualStrings("durable", durable_json.value.object.get("removal").?.object.get("state").?.string);
    close(&s);
    s = try fixture.start(at(102));
    try t.expectEqual(@as(usize, 0), s.entries().len);
}

test "session corrupt unsupported and unsafe saved files remain untouched" {
    for (0..3) |variant| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        const original = if (variant == 1) "PEARLCH\x00\x02\x00" else "synthetic corrupt text";
        var fd: c_int = undefined;
        {
            var disk = try store.Store.open(t.allocator, fixture.path);
            defer disk.close();
            fd = std.c.openat(disk.directoryFd(), "history.bin", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
            try t.expect(fd >= 0);
            errdefer _ = std.c.close(fd);
            try t.expectEqual(@as(isize, @intCast(original.len)), std.c.write(fd, original.ptr, original.len));
            try t.expectEqual(@as(c_int, 0), std.c.fchmod(fd, if (variant == 2) 0o644 else 0o600));
        }
        defer _ = std.c.close(fd);
        var s = try session.Session.init(t.allocator, t.io, fixture.path, .{});
        defer close(&s);
        s.setLocked(false);
        _ = try s.updateWorker(at(100));
        const status = s.worker.?.waitReady();
        const expected: store.Error = switch (variant) {
            0 => error.Corrupt,
            1 => error.Unsupported,
            else => error.Unsafe,
        };
        try t.expectEqual(expected, status.failure.?);
        try t.expectError(expected, s.updateWorker(at(100)));
        if (variant == 2) {
            try t.expect(!s.canRecoverClear());
            try t.expectError(error.Unsafe, s.clear());
        } else {
            try t.expect(s.canRecoverClear());
            try t.expect(!s.worker.?.status().stopped);
        }
        try t.expectEqual(session.Health.unavailable, s.health());
        try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
        var bytes: [64]u8 = undefined;
        const count = std.c.pread(fd, &bytes, bytes.len, 0);
        try t.expectEqual(@as(isize, @intCast(original.len)), count);
        try t.expectEqualStrings(original, bytes[0..@intCast(count)]);
    }
}

const recovery_orphan = "history.tmp.0123456789abcdef0123456789abcdef";
fn writeSynthetic(dir: c_int, name: [:0]const u8, text: []const u8) !void {
    const fd = std.c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    try t.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try t.expectEqual(@as(c_int, 0), std.c.fchmod(fd, 0o600));
    try t.expectEqual(@as(isize, @intCast(text.len)), std.c.write(fd, text.ptr, text.len));
}
fn rejectedSession(fixture: *Fixture, unsupported: bool, hooks: store.Hooks) !session.Session {
    {
        var disk = try store.Store.open(t.allocator, fixture.path);
        defer disk.close();
        try writeSynthetic(disk.directoryFd(), "history.bin", if (unsupported) "PEARLCH\x00\x02\x00" else "synthetic corrupt history");
        try writeSynthetic(disk.directoryFd(), recovery_orphan, "synthetic orphan plaintext");
        try writeSynthetic(disk.directoryFd(), "unrelated", "synthetic unrelated text");
    }
    var s = try session.Session.init(t.allocator, t.io, fixture.path, hooks);
    errdefer close(&s);
    s.setLocked(false);
    _ = try s.updateWorker(at(100));
    const status = s.worker.?.waitReady();
    try t.expectEqual(if (unsupported) error.Unsupported else error.Corrupt, status.failure.?);
    try t.expectError(if (unsupported) error.Unsupported else error.Corrupt, s.updateWorker(at(100)));
    return s;
}

test "session explicit corrupt and unsupported Clear retains locks until durable recovery then requires restart" {
    for ([_]bool{ false, true }) |unsupported| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var s = try rejectedSession(&fixture, unsupported, .{});
        defer close(&s);
        const status = s.worker.?.status();
        try t.expect(status.clear_only and !status.initialized and !status.stopped and !status.accepting);
        try t.expectEqual(@as(u64, 0), status.write_count);
        try t.expectError(error.Busy, store.Store.open(t.allocator, fixture.path));
        const ordinary = try session.worker.OwnedSnapshot.create(t.allocator, .{ .records = &.{.{ .bytes = "must not save", .last_copy = 100, .sequence = 1 }}, .floor = 100 });
        defer ordinary.deinit();
        try t.expectError(error.Fenced, s.worker.?.requestSave(1, ordinary));
        try t.expectError(error.Fenced, s.worker.?.requestRemoval(.delete, 1, ordinary));
        // Lock and suspension both close this same session privacy gate.
        s.setLocked(true);
        try t.expect(!s.canRecoverClear());
        try t.expectError(error.Locked, s.clear());
        try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
        s.setLocked(false);
        try s.clear();
        _ = s.worker.?.waitIdle();
        s.worker.?.join();
        const receipt = try s.removal();
        try t.expectEqual(session.worker.ReceiptState.durable, receipt.state);
        try t.expectEqual(@as(?store.Error, null), receipt.failure);
        try t.expect(s.worker.?.status().stopped and !s.canRecoverClear() and !s.accessible());
        const response = try s.removalStatus(t.allocator);
        defer t.allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, response, .{});
        defer parsed.deinit();
        try t.expect(parsed.value.object.get("durable").?.bool);
        const queried = try s.pageStatus(t.allocator, false, false, "Restart Pearl", .{ .operation = receipt.token, .instance = &s.instance });
        defer t.allocator.free(queried);
        const page = try std.json.parseFromSlice(std.json.Value, t.allocator, queried, .{});
        defer page.deinit();
        try t.expectEqualStrings("durable", page.value.object.get("removal").?.object.get("state").?.string);
        try t.expectEqual(@as(usize, 0), page.value.object.get("entries").?.array.items.len);
        {
            var disk = try store.Store.open(t.allocator, fixture.path);
            defer disk.close();
            try t.expect((try disk.read()) == null);
            var st: std.os.linux.Statx = undefined;
            try t.expectEqual(std.posix.E.NOENT, std.os.linux.errno(std.os.linux.statx(disk.directoryFd(), recovery_orphan, 0, .{ .TYPE = true }, &st)));
            try t.expectEqual(std.posix.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(disk.directoryFd(), "unrelated", 0, .{ .TYPE = true }, &st)));
        }
        var reopened = try fixture.start(at(200));
        defer close(&reopened);
        try t.expect(reopened.accessible());
        try t.expectEqual(@as(usize, 0), reopened.entries().len);
    }
}

test "session corrupt recovery failures and uncertainty keep truthful queryable receipts" {
    for ([_]store.Phase{ .remove, .directory_sync }) |phase| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var hook: Hook = .{ .fail = phase };
        var s = try rejectedSession(&fixture, false, hook.hooks());
        defer close(&s);
        try s.clear();
        _ = s.worker.?.waitIdle();
        s.worker.?.join();
        const receipt = try s.removal();
        try t.expectEqual(if (phase == .remove) session.worker.ReceiptState.failed else .uncertain, receipt.state);
        try t.expectEqual(if (phase == .remove) error.RemoveFailed else error.Uncertain, receipt.failure.?);
        try t.expectEqual(@as(u64, 0), s.worker.?.status().durable_revision);
        try t.expect(!s.canRecoverClear());
        try t.expect(hook.thread.? != std.Thread.getCurrentId());
        const queried = try s.pageStatus(t.allocator, false, false, "Recovery failed", .{ .operation = receipt.token, .instance = &s.instance });
        defer t.allocator.free(queried);
        const page = try std.json.parseFromSlice(std.json.Value, t.allocator, queried, .{});
        defer page.deinit();
        try t.expectEqualStrings(@tagName(receipt.state), page.value.object.get("removal").?.object.get("state").?.string);
        const response = try s.removalStatus(t.allocator);
        defer t.allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, response, .{});
        defer parsed.deinit();
        try t.expect(!parsed.value.object.get("durable").?.bool);
        var disk = try store.Store.open(t.allocator, fixture.path);
        defer disk.close();
        if (phase == .remove) try t.expectError(error.Corrupt, disk.read()) else try t.expect((try disk.read()) == null);
    }
}

test "session corrupt recovery remains closed after clock failure or shutdown" {
    for ([_]bool{ false, true }) |clock_failure| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var s = try rejectedSession(&fixture, false, .{});
        defer close(&s);
        if (clock_failure) s.failClock() else s.beginShutdown();
        try t.expect(!s.canRecoverClear());
        try t.expectError(if (clock_failure) error.ClockUntrusted else error.Locked, s.clear());
        s.worker.?.join();
        try t.expectEqual(@as(u64, 0), s.worker.?.status().write_count);
        var disk = try store.Store.open(t.allocator, fixture.path);
        defer disk.close();
        try t.expectError(error.Corrupt, disk.read());
    }
}

test "worker shutdown while restoration is paused releases an unclaimed load" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var s = try fixture.start(at(100));
        defer close(&s);
        _ = try s.accept(.text, "unclaimed restoration", at(100));
        try settle(&s, at(100));
    }
    const w = try session.worker.Worker.startPaused(t.allocator, t.io, fixture.path, .{});
    defer w.deinit();
    try t.expect(w.waitReady().restoring);
    w.beginShutdown();
    w.join();
    try t.expect(w.status().stopped);
    try t.expectEqual(@as(u64, 0), w.status().write_count);
}

test "session pinned pages and operation queries reject old instances without mutation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var s = try fixture.start(at(100));
    defer close(&s);
    _ = try s.accept(.text, "first", at(100));
    try settle(&s, at(100));
    const pinned = s.model.generation;
    const prior_instance = s.instance;
    const first = try s.pageStatus(t.allocator, true, false, "Ready", .{ .revision = pinned, .instance = &prior_instance });
    defer t.allocator.free(first);
    _ = try s.accept(.text, "second", at(101));
    try t.expectError(error.StaleRevision, s.pageStatus(t.allocator, true, false, "Ready", .{ .offset = 20, .revision = pinned, .instance = &prior_instance }));
    try t.expectError(error.InstanceRequired, s.pageStatus(t.allocator, true, false, "Ready", .{ .operation = 1 }));
    try t.expectError(error.StaleOperation, s.pageStatus(t.allocator, true, false, "Ready", .{ .operation = 999, .instance = &s.instance }));
    try settle(&s, at(101));
    close(&s);
    s = try fixture.start(at(102));
    try t.expect(!std.mem.eql(u8, &prior_instance, &s.instance));
    try t.expectError(error.StaleInstance, s.checkInstance(&prior_instance));
    try t.expectError(error.StaleInstance, s.pageStatus(t.allocator, true, false, "Ready", .{ .instance = &prior_instance }));
    try t.expectEqual(@as(usize, 2), s.entries().len);
    try t.expectEqual(@as(u64, 0), s.worker.?.status().desired_revision);
}
