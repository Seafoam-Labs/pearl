const std = @import("std");
const c = @cImport({ @cInclude("plugin.h"); });
var count: u32 = 0;
pub export fn abort() callconv(.c) noreturn { @trap(); }
pub export fn exports_pearl_plugin_guest_handle_event(event: *c.exports_pearl_plugin_guest_event_t, err: *c.plugin_string_t) callconv(.c) bool {
    if (event.kind == c.PEARL_PLUGIN_TYPES_EVENT_KIND_CLICK) count +%= 1;
    var buffer: [64]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buffer, "Zig clicks: {d}", .{count}) catch unreachable;
    var node = std.mem.zeroes(c.pearl_plugin_types_node_t);
    node.id = 1; node.kind = c.PEARL_PLUGIN_TYPES_NODE_KIND_BUTTON;
    c.plugin_string_set(&node.text, label.ptr);
    var scene = c.pearl_plugin_host_scene_t{ .nodes = .{ .ptr = @ptrCast(&node), .len = 1 } };
    return c.pearl_plugin_host_publish(&scene, err);
}
