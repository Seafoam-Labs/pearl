//! Main-thread display identities and confirmed brightness. No hardware handles escape I/O.
const std = @import("std");
const policy = @import("policy.zig");
const feedback = @import("brightness_feedback.zig");
pub const Text = policy.Text;
pub const capacity = 32;
pub const Backend = enum { backlight, ddc, unavailable };
pub const Device = struct {
    id: Text(128) = .{},
    name: Text(128) = .{},
    output: Text(128) = .{},
    connector: Text(128) = .{},
    edid: [128]u8 = @splat(0),
    backend: Backend = .unavailable,
    maximum: u32 = 0,
    value: u32 = 0,
    reason: ?[]const u8 = null,
    generation: u64 = 0,
    wanted: ?u8 = null,
    pending: bool = false,
    requested: ?u8 = null,
    powered: bool = true,
    write_error: ?[]const u8 = null,
    dim_restore: ?u8 = null,
    dim_restoring: bool = false,
    observed: feedback.Observer = .{},
    pub fn percent(self: Device) u8 {
        return if (self.maximum == 0) 0 else @intCast(@min(100, (@as(u64, self.value) * 100 + self.maximum / 2) / self.maximum));
    }
    pub fn raw(self: Device, percent_value: u8) !u32 {
        if (self.backend == .backlight) return policy.brightness(percent_value, self.maximum);
        if (percent_value > 100 or self.maximum == 0 or self.maximum > 65535) return error.InvalidValue;
        return @intCast((@as(u64, self.maximum) * percent_value + 50) / 100);
    }
    pub fn snapshot(self: Device) feedback.Brightness {
        return .{ .name = self.id, .percent = self.percent() };
    }
};
pub const List = struct {
    items: [capacity]Device = @splat(.{}),
    len: usize = 0,
    pub fn add(self: *List, d: Device) void {
        if (self.len == capacity) return;
        self.items[self.len] = d;
        self.len += 1;
    }
    pub fn slice(self: *List) []Device {
        return self.items[0..self.len];
    }
    pub fn find(self: *List, id: []const u8) ?*Device {
        for (self.slice()) |*d| if (std.mem.eql(u8, d.id.slice(), id)) return d;
        return null;
    }
    /// A connector name duplicated across GPUs must never identify a write target.
    pub fn resolve(self: *List, name: []const u8) ?*Device {
        if (self.find(name)) |d| return d;
        var found: ?*Device = null;
        for (self.slice()) |*d| if (d.output.len != 0 and std.mem.eql(u8, d.output.slice(), name)) {
            if (found != null) return null;
            found = d;
        };
        return found;
    }
    /// DRM connector names can repeat on different GPUs. Keep hardware devices
    /// addressable by ID, but do not associate either with a guessed wl_output.
    pub fn unmapAmbiguousOutputs(self: *List) void {
        var ambiguous: [capacity]bool = @splat(false);
        for (self.slice(), 0..) |d, i| {
            if (d.output.len == 0) continue;
            for (self.slice(), 0..) |other, j| {
                if (i != j and std.mem.eql(u8, d.output.slice(), other.output.slice())) ambiguous[i] = true;
            }
        }
        for (self.slice(), 0..) |*d, i| if (ambiguous[i]) {
            d.output = .{};
            if (d.backend == .ddc) {
                var label: [128]u8 = undefined;
                d.name.set(std.fmt.bufPrint(&label, "{s} ({s})", .{ d.name.slice(), d.connector.slice() }) catch d.connector.slice());
            }
        };
    }
};

test "brightness targets refuse ambiguous connectors and retain independent intent" {
    var list: List = .{};
    var d: Device = .{ .backend = .ddc, .maximum = 255, .value = 128 };
    d.id.set("ddc:card0-DP-1:abc");
    d.output.set("DP-1");
    list.add(d);
    d.id.set("ddc:card1-DP-1:def");
    list.add(d);
    try std.testing.expect(list.resolve("DP-1") == null);
    list.items[0].wanted = 30;
    list.items[1].wanted = 70;
    try std.testing.expectEqual(@as(?u8, 30), list.resolve("ddc:card0-DP-1:abc").?.wanted);
    try std.testing.expectEqual(@as(u32, 128), try d.raw(50));
    try std.testing.expectEqual(@as(u32, 0), try d.raw(0));
    d.backend = .backlight;
    try std.testing.expectEqual(@as(u32, 1), try d.raw(0));
    try std.testing.expectError(error.InvalidValue, d.raw(101));
    list.unmapAmbiguousOutputs();
    try std.testing.expectEqual(@as(usize, 0), list.items[0].output.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[1].output.len);
    try std.testing.expect(list.find("ddc:card0-DP-1:abc") != null);
}
