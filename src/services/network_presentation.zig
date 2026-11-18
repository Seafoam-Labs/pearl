//! Bounded, non-secret presentation contract shared by both network surfaces.
const std = @import("std");
const policy = @import("connectivity_policy.zig");
pub const Status = enum { loading, unavailable, unknown, offline, portal, limited, online };
pub const Radio = enum { absent, blocked, off, on };
pub const Section = enum { connected, nearby, ethernet, saved };
pub const State = enum { connected, disconnected, unavailable, available, saved, out_of_range, connecting };
pub const Action = enum { none, connect, connect_saved, disconnect, editor, scan, enable, disable, cancel, settings, profiles };
pub const Device = struct { path: []const u8, name: []const u8, wireless: bool, ready: bool };
pub const Row = struct {
    key: []const u8,
    title: []const u8,
    path: []const u8,
    device: usize,
    section: Section,
    state: State,
    security: policy.Security = .open,
    strength: u8 = 0,
    action: Action = .none,
    enabled: bool = false,
    profiles: u8 = 0,
};
pub const Snapshot = struct {
    generation: []const u8,
    status: Status,
    radio: Radio,
    radio_enabled: bool,
    pending: bool,
    owned: bool,
    scanning: bool,
    scan_wait: bool,
    scan_wait_ms: u32 = 0,
    truncated: bool,
    error_message: []const u8 = "",
    devices: []const Device,
    rows: []const Row,
};

pub fn status(available: bool, snapshot_ready: bool, connectivity: u32) Status {
    if (!available) return .unavailable;
    if (!snapshot_ready) return .loading;
    return switch (connectivity) {
        1 => .offline,
        2 => .portal,
        3 => .limited,
        4 => .online,
        else => .unknown,
    };
}
pub fn signal(strength: u8) enum { strong, good, weak } {
    return if (strength >= 70) .strong else if (strength >= 40) .good else .weak;
}
/// Bar glyph for the link in use: wireless while Wi-Fi carries the primary
/// connection, wired for Ethernet, and offline when nothing is activated.
/// With several links up, NetworkManager's PrimaryConnection decides; without
/// one, a wired link wins the way NM's default routing prefers it.
pub fn icon(n: anytype) [:0]const u8 {
    if (n.peer.snapshot == null) return "pearl-network-offline-symbolic";
    var wired = false;
    var wireless = false;
    for (n.devices[0..n.device_count]) |*dev| {
        if (dev.state != 100) continue;
        if (n.primary.len != 0 and same(dev.active.slice(), n.primary.slice())) return if (dev.kind == 2) "pearl-network-wireless-symbolic" else "pearl-network-wired-symbolic";
        if (dev.kind == 2) wireless = true else wired = true;
    }
    if (wired) return "pearl-network-wired-symbolic";
    if (wireless) return "pearl-network-wireless-symbolic";
    return "pearl-network-offline-symbolic";
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn text(value: []const u8) []const u8 {
    // Connection IDs are arbitrary user text. Never send control characters to
    // labels (or let JSON escaping multiply the bounded presentation budget).
    for (value) |byte| if (byte < 32 or byte == 127) return "Unnamed connection";
    var end = @min(value.len, 128);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) : (end -= 1) {}
    return value[0..end];
}
pub fn sameGroup(left: anytype, right: anytype) bool {
    if (left.len == 0 or right.len == 0) return same(left.path.slice(), right.path.slice());
    return same(left.device.slice(), right.device.slice()) and left.security == right.security and same(left.ssid[0..left.len], right.ssid[0..right.len]);
}
pub fn matches(saved: anytype, ap: anytype) bool {
    return saved.loaded and saved.wireless and saved.ssid_len != 0 and saved.security == ap.security and
        same(saved.device.slice(), ap.device.slice()) and same(saved.ssid[0..saved.ssid_len], ap.ssid[0..ap.len]);
}
fn key(alloc: std.mem.Allocator, section: Section, path: []const u8, ssid: []const u8, security: policy.Security) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&.{@backingInt(section)});
    hash.update(path);
    hash.update(&.{0});
    hash.update(ssid);
    hash.update(&.{@backingInt(security)});
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.allocPrint(alloc, "{s}:{s}", .{ @tagName(section), std.fmt.bytesToHex(digest, .lower) });
}
fn deviceIndex(n: anytype, path: []const u8) ?usize {
    for (n.devices[0..n.device_count], 0..) |*dev, i| if (same(dev.path.slice(), path)) return i;
    return null;
}
fn ready(n: anytype, index: usize) bool {
    const dev = n.devices[index];
    return n.peer.snapshot != null and n.peer.owner.len != 0 and dev.state >= 30 and (dev.kind != 2 or (n.enabled and n.hardware_enabled));
}

/// The service owns identities and mutations. This projection never reads secrets.
/// An entire bounded snapshot avoids stitching networks from different revisions.
pub fn build(alloc: std.mem.Allocator, n: anytype, owner: anytype, now: i64) !Snapshot {
    var devices: std.ArrayList(Device) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    const available = n.peer.owner.len != 0 and n.peer.snapshot != null;
    var wireless: usize = 0;
    if (available) for (n.devices[0..n.device_count], 0..) |*dev, i| {
        try devices.append(alloc, .{ .path = dev.path.slice(), .name = text(dev.name.slice()), .wireless = dev.kind == 2, .ready = ready(n, i) });
        if (dev.kind == 2) wireless += 1;
        if (dev.kind == 2 and dev.state != 100) continue;
        var title: []const u8 = if (dev.kind == 1) "Ethernet" else text(dev.name.slice());
        var security: policy.Security = .open;
        var strength: u8 = 0;
        if (dev.kind == 2) for (n.aps[0..n.ap_count]) |*ap| {
            if (same(ap.path.slice(), dev.ap.slice())) {
                title = text(ap.label.slice());
                security = ap.security;
                strength = ap.strength;
                break;
            }
        };
        var action: Action = if (dev.state == 100) .disconnect else .editor;
        var path = dev.path.slice();
        if (dev.kind == 1 and dev.state != 100) {
            var compatible: usize = 0;
            for (n.saved[0..n.saved_count]) |*saved| if (saved.loaded and saved.security != .advanced and same(saved.device.slice(), dev.path.slice())) {
                compatible += 1;
                path = saved.path.slice();
            };
            if (compatible == 1) action = .connect_saved else path = dev.path.slice();
        }
        const section: Section = if (dev.kind == 2) .connected else .ethernet;
        try rows.append(alloc, .{ .key = try key(alloc, section, dev.path.slice(), "", .open), .title = title, .path = path, .device = i, .section = section, .state = if (dev.state == 100) .connected else if (dev.state < 30) .unavailable else .disconnected, .security = security, .strength = strength, .action = action, .enabled = !n.pending and (action == .editor or ready(n, i)) });
    };
    if (available and n.enabled and n.hardware_enabled) for (n.aps[0..n.ap_count], 0..) |*ap, index| {
        var earlier = false;
        for (n.aps[0..index]) |*other| if (sameGroup(ap, other)) {
            earlier = true;
            break;
        };
        if (earlier) continue;
        const di = deviceIndex(n, ap.device.slice()) orelse continue;
        const dev = n.devices[di];
        var representative = ap;
        var connected = false;
        for (n.aps[0..n.ap_count]) |*other| if (sameGroup(ap, other)) {
            if (dev.state == 100 and same(dev.ap.slice(), other.path.slice())) connected = true;
            if (other.strength > representative.strength) representative = other;
        };
        if (n.pending) for (n.aps[0..n.ap_count]) |*other| if (sameGroup(ap, other) and same(n.selected_ap.slice(), other.path.slice())) {
            representative = other;
            break;
        };
        if (connected) continue;
        var count: u8 = 0;
        var path = representative.path.slice();
        for (n.saved[0..n.saved_count]) |*saved| if (matches(saved, representative)) {
            count += 1;
            path = saved.path.slice();
        };
        const pending = n.pending and same(n.device.slice(), dev.path.slice()) and (same(n.selected_ap.slice(), representative.path.slice()) or (count == 1 and same(n.selected_profile.slice(), path)));
        const action: Action = if (ap.security == .advanced) .editor else if (count > 1) .profiles else if (count == 1) .connect_saved else .connect;
        if (count != 1) path = representative.path.slice();
        try rows.append(alloc, .{ .key = try key(alloc, .nearby, if (ap.len == 0) ap.path.slice() else ap.device.slice(), ap.ssid[0..ap.len], ap.security), .title = text(ap.label.slice()), .path = path, .device = di, .section = .nearby, .state = if (pending) .connecting else .available, .security = ap.security, .strength = representative.strength, .action = action, .enabled = !n.pending and (action == .editor or ready(n, di)), .profiles = count });
    };
    if (available) for (n.saved[0..n.saved_count]) |*saved| {
        const di = deviceIndex(n, saved.device.slice());
        var state: State = .saved;
        if (saved.loaded and saved.wireless and saved.ssid_len != 0 and n.enabled and n.hardware_enabled) {
            // An absent AP is not proof of range without scan-completion evidence.
            state = .saved;
            for (n.aps[0..n.ap_count]) |*ap| if (matches(saved, ap)) {
                state = .available;
                break;
            };
        }
        if (di) |i| if (n.devices[i].state == 100 and same(n.devices[i].profile.slice(), saved.path.slice())) {
            state = .connected;
        };
        try rows.append(alloc, .{ .key = try key(alloc, .saved, saved.path.slice(), "", .open), .title = if (saved.label.len != 0) text(saved.label.slice()) else "Saved connection", .path = saved.path.slice(), .device = di orelse 8, .section = .saved, .state = state, .security = saved.security, .action = if (saved.security == .advanced) .editor else .connect_saved, .enabled = saved.loaded and !n.pending and state != .connected and (saved.security == .advanced or (if (di) |i| ready(n, i) else false)) });
    };
    std.mem.sort(Row, rows.items, {}, struct {
        fn less(_: void, left: Row, right: Row) bool {
            if (left.section != right.section) return @backingInt(left.section) < @backingInt(right.section);
            if (left.section == .nearby and left.strength != right.strength) return left.strength > right.strength;
            if (!same(left.title, right.title)) return std.mem.lessThan(u8, left.title, right.title);
            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.less);
    return .{ .generation = try std.fmt.allocPrint(alloc, "{d}", .{n.peer.epoch}), .status = status(n.peer.owner.len != 0, n.peer.snapshot != null, n.connectivity), .radio = if (wireless == 0) .absent else if (!n.hardware_enabled) .blocked else if (!n.enabled) .off else .on, .radio_enabled = available and wireless > 0 and n.hardware_enabled and !n.pending, .pending = n.pending, .owned = n.operation_owner != null and n.operation_owner == owner, .scanning = n.scan_pending, .scan_wait = n.scan_last != 0 and now - n.scan_last < 15_000_000, .scan_wait_ms = if (n.scan_last == 0) 0 else @intCast(@divTrunc(@max(0, 15_000_000 - (now - n.scan_last)), 1000)), .truncated = n.truncated, .error_message = n.err orelse n.peer.err orelse "", .devices = devices.items, .rows = rows.items };
}

const Fixture = struct {
    const T = @import("policy.zig").Text;
    const Dev = struct { path: T(512) = .{}, name: T(512) = .{}, ap: T(512) = .{}, profile: T(512) = .{}, active: T(512) = .{}, state: u32 = 30, kind: u32 = 2 };
    const AP = struct { path: T(512) = .{}, label: T(128) = .{}, device: T(512) = .{}, len: usize = 1, ssid: [32]u8 = @splat(0), security: policy.Security = .psk, strength: u8 = 80 };
    const Saved = struct { path: T(512) = .{}, label: T(512) = .{}, device: T(512) = .{}, wireless: bool = true, loaded: bool = true, ssid_len: usize = 1, ssid: [32]u8 = @splat(0), security: policy.Security = .psk };
    peer: struct { owner: T(512) = .{}, snapshot: ?u8 = 1, epoch: u64 = 2, err: ?[]const u8 = null } = .{},
    devices: [8]Dev = @splat(.{}),
    device_count: usize = 1,
    aps: [64]AP = @splat(.{}),
    ap_count: usize = 2,
    saved: [32]Saved = @splat(.{}),
    saved_count: usize = 0,
    pending: bool = false,
    enabled: bool = true,
    hardware_enabled: bool = true,
    device: T(512) = .{},
    selected_ap: T(512) = .{},
    selected_profile: T(512) = .{},
    operation_owner: ?u64 = null,
    scan_pending: bool = false,
    scan_last: i64 = 0,
    connectivity: u32 = 4,
    primary: T(512) = .{},
    truncated: bool = false,
    err: ?[]const u8 = null,
    fn init() Fixture {
        var f: Fixture = .{};
        f.peer.owner.set(":1.42");
        f.devices[0].path.set("/dev/1");
        f.devices[0].name.set("wlan0");
        for (f.aps[0..2], 0..) |*ap, i| {
            ap.device = f.devices[0].path;
            ap.path.set(if (i == 0) "/ap/1" else "/ap/2");
            ap.label.set("Home");
        }
        f.aps[1].strength = 95;
        f.saved[0].device = f.devices[0].path;
        f.saved[0].path.set("/profile/1");
        f.saved[0].label.set("Different profile label");
        return f;
    }
};
test "representatives saved profiles and pending identities are deliberate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var f = Fixture.init();
    var result = try build(alloc, &f, @as(?u64, 1), 20_000_000);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("/ap/2", result.rows[0].path);
    const original_key = result.rows[0].key;
    f.pending = true;
    f.device = f.devices[0].path;
    f.selected_ap = f.aps[0].path;
    f.operation_owner = 1;
    result = try build(alloc, &f, @as(?u64, 2), 20_000_000);
    try std.testing.expect(!result.owned and !result.rows[0].enabled);
    try std.testing.expectEqual(State.connecting, result.rows[0].state);
    try std.testing.expectEqualStrings("/ap/1", result.rows[0].path);
    try std.testing.expectEqualStrings(original_key, result.rows[0].key);
    f.pending = false;
    f.saved_count = 1;
    result = try build(alloc, &f, @as(?u64, 1), 20_000_000);
    try std.testing.expectEqual(Action.connect_saved, result.rows[0].action);
    try std.testing.expectEqualStrings("/profile/1", result.rows[0].path);
    f.saved[1] = f.saved[0];
    f.saved[1].path.set("/profile/2");
    f.saved_count = 2;
    result = try build(alloc, &f, @as(?u64, 1), 20_000_000);
    try std.testing.expectEqual(Action.profiles, result.rows[0].action);
    f.saved[0].security = .open;
    f.saved[1].ssid[0] = 3;
    result = try build(alloc, &f, @as(?u64, 1), 20_000_000);
    try std.testing.expectEqual(Action.connect, result.rows[0].action);
    f.devices[0].state = 100;
    f.devices[0].ap = f.aps[0].path;
    result = try build(alloc, &f, @as(?u64, 1), 20_000_000);
    for (result.rows) |row| try std.testing.expect(row.section != .nearby);
}
test "wired internet survives radio off and stale daemon data is hidden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Fixture.init();
    f.enabled = false;
    f.device_count = 2;
    f.devices[1].kind = 1;
    f.devices[1].state = 100;
    f.devices[1].path.set("/dev/2");
    var result = try build(arena.allocator(), &f, @as(?u64, 1), 0);
    try std.testing.expectEqual(Status.online, result.status);
    try std.testing.expectEqual(Radio.off, result.radio);
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(Section.ethernet, result.rows[0].section);
    try std.testing.expect(result.rows[0].enabled);
    f.peer.owner = .{};
    f.peer.snapshot = null;
    result = try build(arena.allocator(), &f, @as(?u64, 1), 0);
    try std.testing.expectEqual(Status.unavailable, result.status);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expect(!result.radio_enabled);
}
test "maximum network projection fits a bounded frontend frame with fallback budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = Fixture.init();
    f.device_count = 8;
    f.ap_count = 64;
    f.saved_count = 32;
    var path = @as([512]u8, @splat('a'));
    path[0] = '/';
    const name = @as([128]u8, @splat('"'));
    for (&f.devices, 0..) |*dev, i| {
        path[511] = @intCast('a' + i);
        dev.path.set(&path);
        dev.name.set(&name);
        dev.state = 100;
    }
    for (&f.aps, 0..) |*ap, i| {
        path[511] = @intCast('A' + i % 26);
        ap.path.set(&path);
        ap.device = f.devices[i % 8].path;
        ap.label.set(&name);
        ap.ssid[0] = @intCast(i);
    }
    for (&f.saved, 0..) |*saved, i| {
        path[511] = @intCast('A' + i % 26);
        saved.path.set(&path);
        saved.label.set(&name);
        saved.device = f.devices[i % 8].path;
        saved.ssid[0] = @intCast(i + 64);
    }
    const result = try build(arena.allocator(), &f, @as(?u64, 1), 0);
    try std.testing.expectEqual(@as(usize, 104), result.rows.len);
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), result, .{});
    // Leave 96 KiB for the 16 legacy rows and page envelope.
    try std.testing.expect(encoded.len < 160 * 1024);
}

test "internet status is independent of radio and signal" {
    try std.testing.expectEqual(Status.online, status(true, true, 4));
    try std.testing.expectEqual(Status.portal, status(true, true, 2));
    try std.testing.expectEqual(Status.limited, status(true, true, 3));
    try std.testing.expectEqual(Status.unknown, status(true, true, 0));
    try std.testing.expectEqual(Status.loading, status(true, false, 4));
    try std.testing.expectEqual(Status.unavailable, status(false, false, 4));
}
test "groups preserve raw SSID security and adapter identity" {
    const Text = @import("policy.zig").Text;
    const AP = struct { path: Text(512) = .{}, device: Text(512) = .{}, ssid: [32]u8 = @splat(0), len: usize = 2, security: policy.Security = .psk };
    var one: AP = .{};
    one.device.set("/dev/1");
    one.path.set("/ap/1");
    one.ssid[0..2].* = .{ 0xff, 0 };
    var two = one;
    two.path.set("/ap/2");
    try std.testing.expect(sameGroup(one, two));
    two.security = .open;
    try std.testing.expect(!sameGroup(one, two));
    two = one;
    two.device.set("/dev/2");
    try std.testing.expect(!sameGroup(one, two));
    one.len = 0;
    two = one;
    two.path.set("/ap/2");
    try std.testing.expect(!sameGroup(one, two));
}
test "bar glyph follows the primary connection and never invents a link" {
    var f = Fixture.init();
    f.devices[0].active.set("/active/1");
    // Wi-Fi alone activated keeps the wireless glyph.
    f.devices[0].state = 100;
    try std.testing.expectEqualStrings("pearl-network-wireless-symbolic", icon(&f));
    // Ethernet alone activated shows wired, not Wi-Fi.
    f.devices[0].state = 30;
    f.device_count = 2;
    f.devices[1].kind = 1;
    f.devices[1].state = 100;
    f.devices[1].path.set("/dev/2");
    f.devices[1].active.set("/active/2");
    try std.testing.expectEqualStrings("pearl-network-wired-symbolic", icon(&f));
    // Both links up: the primary connection decides which one is in use.
    f.devices[0].state = 100;
    f.primary.set("/active/2");
    try std.testing.expectEqualStrings("pearl-network-wired-symbolic", icon(&f));
    f.primary.set("/active/1");
    try std.testing.expectEqualStrings("pearl-network-wireless-symbolic", icon(&f));
    // A primary path outside the tracked devices falls back to the links up.
    f.primary.set("/active/vpn");
    try std.testing.expectEqualStrings("pearl-network-wired-symbolic", icon(&f));
    // No primary reported: wired wins, matching NM's routing preference.
    f.primary = .{};
    try std.testing.expectEqualStrings("pearl-network-wired-symbolic", icon(&f));
    // Nothing activated is offline, radio on or off.
    f.devices[0].state = 30;
    f.devices[1].state = 30;
    try std.testing.expectEqualStrings("pearl-network-offline-symbolic", icon(&f));
    f.enabled = false;
    try std.testing.expectEqualStrings("pearl-network-offline-symbolic", icon(&f));
    // A vanished daemon is offline, never a stale link glyph.
    f.peer.snapshot = null;
    try std.testing.expectEqualStrings("pearl-network-offline-symbolic", icon(&f));
}
/// Every glyph the policy can select, all registered in pearl.gresource.xml.
/// An unregistered name renders as a broken image rather than an error, so a
/// rename here must be matched in the manifest.
const shipped_icons = [_][:0]const u8{
    "pearl-network-wired-symbolic",
    "pearl-network-wireless-symbolic",
    "pearl-network-offline-symbolic",
};

test "every network icon the policy selects is a shipped, reachable glyph" {
    var reachable = @as([shipped_icons.len]bool, @splat(false));
    var f = Fixture.init();
    f.device_count = 2;
    f.devices[1].kind = 1;
    f.devices[1].path.set("/dev/2");
    f.devices[0].active.set("/active/1");
    f.devices[1].active.set("/active/2");
    // Sweep daemon presence, link kinds, activation and primary identities.
    var present: u8 = 0;
    while (present <= 1) : (present += 1) {
        f.peer.snapshot = if (present == 0) null else 1;
        var kind: u32 = 1;
        while (kind <= 2) : (kind += 1) {
            f.devices[0].kind = kind;
            var state0: u32 = 30;
            while (state0 <= 100) : (state0 += 70) {
                f.devices[0].state = state0;
                var state1: u32 = 30;
                while (state1 <= 100) : (state1 += 70) {
                    f.devices[1].state = state1;
                    for ([_][]const u8{ "", "/active/1", "/active/2", "/active/other" }) |primary| {
                        f.primary = .{};
                        f.primary.set(primary);
                        const symbol = icon(&f);
                        const index = for (shipped_icons, 0..) |name, i| {
                            if (std.mem.eql(u8, name, symbol)) break i;
                        } else {
                            std.debug.print("unregistered network icon: {s}\n", .{symbol});
                            return error.TestUnexpectedResult;
                        };
                        reachable[index] = true;
                    }
                }
            }
        }
    }
    // A glyph no state can select means the policy or the asset set drifted.
    for (shipped_icons, 0..) |name, i| {
        try std.testing.expect(reachable[i]);
        _ = name;
    }
}
