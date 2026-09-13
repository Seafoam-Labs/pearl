//! Fixed-capacity in-session history; presentation and protocol lifetime are separate.
const std = @import("std");
const Text = @import("policy.zig").Text;
pub const Action = struct { key: Text(96) = .{}, label: Text(160) = .{} };
pub const Record = struct {
    id: u32 = 0,
    serial: u64 = 0,
    active: bool = false,
    transient: bool = false,
    resident: bool = false,
    owner: Text(256) = .{},
    app: Text(160) = .{},
    summary: Text(256) = .{},
    body: Text(2048) = .{},
    icon: Text(160) = .{},
    actions: [8]Action = @splat(.{}),
    action_count: usize = 0,
    urgency: u8 = 1,
    deadline: i64 = 0,
    toast_until: i64 = 0,
};
pub const Model = struct {
    records: [64]Record = @splat(.{}),
    next_id: u32 = 0,
    serial: u64 = 0,
    dnd: bool = false,
    locked: bool = false,
    pub fn find(self: *Model, id: u32) ?*Record {
        if (id == 0) return null;
        for (&self.records) |*r| if (r.id == id) return r;
        return null;
    }
    pub fn add(self: *Model, input: Record, replaces: u32, timeout: i32, now: i64) !*Record {
        var slot: ?*Record = null;
        if (self.find(replaces)) |r| {
            if (r.active and std.mem.eql(u8, r.owner.slice(), input.owner.slice())) slot = r;
        }
        if (slot == null) {
            var oldest: ?*Record = null;
            for (&self.records) |*r| {
                if (r.id == 0) {
                    oldest = r;
                    break;
                }
                if (!r.active and (oldest == null or r.serial < oldest.?.serial)) oldest = r;
            }
            slot = oldest orelse return error.Limit;
        }
        const replacing = slot.?.active;
        var id = slot.?.id;
        if (!replacing) {
            var attempts: usize = 0;
            while (attempts <= self.records.len) : (attempts += 1) {
                self.next_id +%= 1;
                if (self.next_id == 0) self.next_id = 1;
                if (self.find(self.next_id) == null) break;
            }
            id = self.next_id;
        }
        self.serial += 1;
        slot.?.* = input;
        const r = slot.?;
        r.id = id;
        r.serial = self.serial;
        r.active = true;
        const ms: i64 = if (timeout < 0) (if (r.urgency == 2) 0 else 5000) else timeout;
        r.deadline = if (ms == 0) 0 else now + ms * 1000;
        r.toast_until = if (self.dnd or self.locked) 0 else now + @min(if (ms == 0) 8000 else ms, 8000) * 1000;
        return r;
    }
    pub fn close(self: *Model, id: u32) bool {
        const r = self.find(id) orelse return false;
        if (!r.active) return false;
        r.active = false;
        r.deadline = 0;
        r.toast_until = 0;
        if (r.transient) r.* = .{};
        self.serial += 1;
        return true;
    }
    pub fn suppress(self: *Model) void {
        for (&self.records) |*r| r.toast_until = 0;
        self.serial += 1;
    }
    pub fn clearHistory(self: *Model) void {
        for (&self.records) |*r| if (!r.active) {
            r.* = .{};
        };
        self.serial += 1;
    }
};
/// Plain labels only. Remove terminal/control and bidi override characters.
pub fn sanitize(comptime n: usize, value: []const u8) Text(n) {
    var out: Text(n) = .{};
    var i: usize = 0;
    while (i < value.len) {
        const size = std.unicode.utf8ByteSequenceLength(value[i]) catch {
            i += 1;
            continue;
        };
        if (i + size > value.len) break;
        const cp = std.unicode.utf8Decode(value[i..][0..size]) catch {
            i += 1;
            continue;
        };
        const allowed = cp == 10 or cp == 9 or (cp >= 32 and !(cp >= 0x7f and cp <= 0x9f) and !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2066 and cp <= 0x2069));
        if (allowed) {
            if (out.len + size > n) break;
            @memcpy(out.bytes[out.len..][0..size], value[i..][0..size]);
            out.len += size;
        }
        i += size;
    }
    return out;
}
test "replacement, sender isolation, ID wrap, DND and bounded history" {
    const t = std.testing;
    var m: Model = .{};
    var r: Record = .{};
    r.owner.set(":1.7");
    const id = (try m.add(r, 0, -1, 100)).id;
    try t.expectEqual(id, (try m.add(r, id, 0, 100)).id);
    r.owner.set(":1.8");
    try t.expect(id != (try m.add(r, id, 0, 100)).id);
    m.dnd = true;
    try t.expectEqual(@as(i64, 0), (try m.add(r, 0, 50, 100)).toast_until);
    m.next_id = std.math.maxInt(u32);
    try t.expect((try m.add(r, 0, 0, 100)).id != 0);
    for (0..60) |_| _ = try m.add(r, 0, 0, 100);
    try t.expectError(error.Limit, m.add(r, 0, 0, 100));
    try t.expect(m.close(id));
    _ = try m.add(r, 0, 0, 100);
    try t.expectEqualStrings("hi <b>字</b>", sanitize(40, "hi \x1b<b>字</b>\xe2\x80\xae").slice());
}

test "expiration is separate from toast timeout and lock suppresses replay" {
    const t = std.testing;
    var m: Model = .{};
    const persistent = try m.add(.{ .urgency = 2 }, 0, -1, 1000);
    try t.expectEqual(@as(i64, 0), persistent.deadline);
    try t.expectEqual(@as(i64, 8001000), persistent.toast_until);
    m.locked = true;
    m.suppress();
    const timed = try m.add(.{}, 0, 200, 1000);
    try t.expectEqual(@as(i64, 201000), timed.deadline);
    try t.expectEqual(@as(i64, 0), timed.toast_until);
    m.locked = false;
    try t.expectEqual(@as(i64, 0), persistent.toast_until);
    const transient = try m.add(.{ .transient = true }, 0, 0, 1000);
    const id = transient.id;
    try t.expect(m.close(id));
    try t.expect(m.find(id) == null);
}
