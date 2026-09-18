//! Shared presentation values for live-service pages. The backend retains policy.
const std = @import("std");
const p = @import("editor_protocol.zig");
pub const Op = @FieldType(@import("protocol.zig").Request, "op");
pub const Control = struct {
    id: []const u8,
    label: []const u8,
    op: Op,
    params: []const u8,
    enabled: bool = true,
    kind: enum { button, number, choice } = .button,
    field: []const u8 = "",
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 100,
    choices: []const Choice = &.{},
};
pub const Choice = struct { label: []const u8, value: []const u8 };
pub const Row = struct { id: []const u8, title: []const u8, detail: []const u8 = "", controls: []const Control = &.{} };
pub const Prompt = struct { service: enum { network, bluetooth }, serial: p.Number, kind: []const u8, title: []const u8, challenge: []const u8 = "", secret: bool, editable: bool = true };
pub const Plugin = struct { view: []const u8, operation: []const u8, id: []const u8, action: enum { retry, preview } };
pub const PluginInfo = struct { installed: bool = true, id: []const u8, name: []const u8, version: []const u8, digest: []const u8, capabilities: @import("../plugins/model.zig").Grants, settings: []const @import("../plugins/model.zig").Schema, status: []const u8, input_activity: []const u8 = "unsupported", error_code: ?[]const u8 = null };
pub const PluginPage = struct { summary: []const u8, plugins: []const PluginInfo = &.{}, next_offset: ?[]const u8 = null };
pub const Page = struct { plugins: []const PluginInfo = &.{}, summary: []const u8, pending: bool = false, truncated: bool = false, rows: []const Row, offset: p.Number, next_offset: ?p.Number = null, prompt: ?Prompt = null };
pub const List = struct { view: []const u8, list: enum { items }, revision: []const u8, offset: []const u8 };
pub const Audio = struct { view: []const u8, operation: []const u8, generation: []const u8, device: u32, kind: @import("../services/policy.zig").Kind, volume: ?u8 = null, mute: ?bool = null, make_default: ?bool = null, target: ?u32 = null };
pub const Brightness = struct { view: []const u8, operation: []const u8, generation: []const u8, percent: u8 };
pub const Profile = struct { view: []const u8, operation: []const u8, generation: []const u8, profile: []const u8 };
pub const Network = struct { view: []const u8, operation: []const u8, generation: []const u8, path: []const u8, action: enum { scan, connect, connect_saved, disconnect, enable, disable, cancel } };
pub const Bluetooth = struct { view: []const u8, operation: []const u8, generation: []const u8, path: []const u8, action: enum { pair, connect, disconnect, trust, untrust, power_on, power_off, discover, stop_discovery, cancel } };
pub const Answer = struct { view: []const u8, operation: []const u8, service: enum { network, bluetooth }, prompt: []const u8, accept: bool, text: ?[]const u8 = null };
pub const NetworkEditor = struct { view: []const u8, operation: []const u8 };
pub const Notifications = struct { view: []const u8, operation: []const u8, action: enum { dnd_on, dnd_off, clear_history, dismiss, invoke }, notification: ?u32 = null, serial: ?[]const u8 = null, key: ?[]const u8 = null };
pub const Lifecycle = struct { view: []const u8, operation: []const u8, action: enum { lock, @"suspend", hibernate, logout, confirm, cancel, inhibit, uninhibit }, confirmation: ?[]const u8 = null };
pub const Power = struct { view: []const u8, operation: []const u8, reboot: bool, confirmation: ?[]const u8 = null };
pub const Media = struct { view: []const u8, operation: []const u8, generation: []const u8, action: enum { select, play_pause, play, pause, stop, next, previous, seek }, position: ?i64 = null };
pub const Layout = struct { view: []const u8, operation: []const u8, output: []const u8, generation: []const u8, layout: ?[]const u8 = null };
pub fn button(a: std.mem.Allocator, id: []const u8, label: []const u8, op: Op, params: anytype, enabled: bool) !Control {
    return .{ .id = id, .label = label, .op = op, .params = try std.json.Stringify.valueAlloc(a, params, .{ .emit_null_optional_fields = false }), .enabled = enabled };
}

test "plugin page wire snapshot accepts decimal offsets and omitted optional errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try std.json.Stringify.valueAlloc(alloc, Page{ .summary = "installed", .rows = &.{}, .offset = p.num(0), .plugins = &.{.{ .id = "demo", .name = "Demo", .version = "1", .digest = "hash", .capabilities = .{}, .settings = &.{}, .status = "disabled" }} }, .{ .emit_null_optional_fields = false });
    const snapshot = try std.json.parseFromSliceLeaky(PluginPage, alloc, bytes, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), snapshot.plugins.len);
    try std.testing.expect(snapshot.plugins[0].error_code == null);
}
