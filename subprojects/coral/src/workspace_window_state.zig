//! Last closed workspace window supplies the defaults for the next launch.
//! Explicit project snapshots can subsequently restore their own dock layout.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const layout = @import("workbench/layout.zig");
const state = @import("workspace_state.zig");

extern fn gtk_window_get_default_size(window: *c.GtkWindow, width: *c_int, height: *c_int) void;
extern fn gtk_window_is_maximized(window: *c.GtkWindow) c_int;
extern fn gtk_window_maximize(window: *c.GtkWindow) void;

pub const Window = struct {
    width: c_int = 1440,
    height: c_int = 900,
    maximized: bool = false,
    dock: layout.State = .{ .agent_visible = true, .terminal_visible = true, .left_size = 245, .right_size = 360, .bottom_size = 155 },
};

pub var initial: Window = .{};

pub fn load() Window {
    const json = state.read("", "window-layout-v1") orelse return .{};
    defer json.deinit();
    const saved = std.json.parseFromValue(Window, u.a, json.value, .{ .ignore_unknown_fields = true }) catch return .{};
    defer saved.deinit();
    const result = saved.value;
    if (result.width < 320 or result.height < 240 or result.width > 16384 or result.height > 16384) return .{};
    layout.validate(result.dock) catch return .{};
    return result;
}

pub fn configure(window: *c.GtkWindow) void {
    var width: c_int = 0;
    var height: c_int = 0;
    gtk_window_get_default_size(window, &width, &height);
    std.log.scoped(.services).debug("Workspace window requests {d}x{d}, maximized={}", .{ width, height, initial.maximized });
    if (initial.maximized) gtk_window_maximize(window);
}

pub fn save(window: *c.GtkWindow, dock: layout.State) !void {
    var result: Window = .{ .dock = dock, .maximized = gtk_window_is_maximized(window) != 0 };
    gtk_window_get_default_size(window, &result.width, &result.height);
    if (result.width < 320 or result.height < 240) return;
    try state.write("", "window-layout-v1", result);
}
