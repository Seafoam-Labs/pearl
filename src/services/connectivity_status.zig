//! Explicit diagnostic allowlist: never serialize an agent invocation or prompt contents.
const std = @import("std");
const Network = @import("network.zig").Network;
const Bluetooth = @import("bluetooth.zig").Bluetooth;
const Item = struct { kind: enum { network_device, access_point, saved, adapter, bluetooth_device }, path: []const u8, label: []const u8, device: []const u8 = "", state: u32 = 0, device_type: u32 = 0, security: []const u8 = "", strength: u8 = 0, paired: bool = false, trusted: bool = false, connected: bool = false, powered: bool = false };
fn preview(text: []const u8) []const u8 {
    var end = @min(96, text.len);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}
pub fn encode(a: std.mem.Allocator, n: *Network, b: *Bluetooth, offset: u16) ![]const u8 {
    var all: std.ArrayList(Item) = .empty;
    defer all.deinit(a);
    for (n.devices[0..n.device_count]) |*dev| try all.append(a, .{ .kind = .network_device, .path = dev.path.slice(), .label = preview(dev.name.slice()), .state = dev.state, .device_type = dev.kind, .connected = dev.state == 100 });
    for (n.aps[0..n.ap_count]) |*ap| try all.append(a, .{ .kind = .access_point, .path = ap.path.slice(), .label = preview(ap.label.slice()), .device = ap.device.slice(), .security = @tagName(ap.security), .strength = ap.strength });
    for (n.saved[0..n.saved_count]) |*saved| try all.append(a, .{ .kind = .saved, .path = saved.path.slice(), .label = preview(saved.label.slice()), .device = saved.device.slice(), .security = @tagName(saved.security) });
    for (b.adapters[0..b.adapter_count]) |*adapter| try all.append(a, .{ .kind = .adapter, .path = adapter.path.slice(), .label = preview(adapter.label.slice()), .powered = adapter.powered });
    for (b.devices[0..b.device_count]) |*dev| try all.append(a, .{ .kind = .bluetooth_device, .path = dev.path.slice(), .label = preview(dev.label.slice()), .device = dev.adapter.slice(), .paired = dev.paired, .trusted = dev.trusted, .connected = dev.connected });
    const first = @min(offset, all.items.len);
    const end = @min(first + 4, all.items.len);
    return std.json.Stringify.valueAlloc(a, .{
        .network = .{ .available = n.peer.snapshot != null, .generation = n.peer.epoch, .registered = n.registered, .enabled = n.enabled, .hardware_enabled = n.hardware_enabled, .connectivity = n.connectivity, .pending = n.pending, .activation_waiting = n.activation_waiting, .cancelled = n.cancelled, .prompt = n.prompt != null, .prompt_serial = n.prompt_serial, .scan_pending = n.scan_pending, .settings_loading = n.settings_loading, .truncated = n.truncated, .err = n.err orelse n.peer.err },
        .bluetooth = .{ .available = b.peer.snapshot != null, .generation = b.peer.epoch, .registered = b.registered, .pending = b.pending, .cancelling = b.cancelling, .prompt = b.prompt_kind, .prompt_serial = b.prompt_serial, .discovering = b.discovering, .discovery_pending = b.discovery_waiting, .truncated = b.truncated, .err = b.err orelse b.peer.err },
        .items = all.items[first..end],
        .count = all.items.len,
        .next_offset = if (end < all.items.len) @as(?usize, end) else null,
    }, .{});
}
