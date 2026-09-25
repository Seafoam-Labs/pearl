//! Typed IPC actions. Revalidate against authoritative state at enqueue and dispatch.
const std = @import("std");
const codec = @import("codec.zig");
const Model = @import("reducer.zig").Model;
const e = @import("entities.zig");
pub const Target = struct { id: []const u8 };
pub const Activate = struct { id: []const u8, seat: ?[]const u8 = null };
pub const Toggle = struct { id: []const u8, value: bool };
pub const Keyboard = struct { seat: ?[]const u8 = null, group: ?[]const u8 = null };
pub const Switcher = struct { output: []const u8, workspace: ?[]const u8 = null, scope: ?enum { all } = null, seat: ?[]const u8 = null, reduced_motion: bool = false };
pub const Action = union(enum) {
    switcher_next: Switcher,
    switcher_previous: Switcher,
    switcher_dismiss: Switcher,
    window_activate: Activate,
    window_close: Target,
    window_minimized: Toggle,
    window_maximized: Toggle,
    window_fullscreen: Toggle,
    window_move_workspace: struct { id: []const u8, workspace: []const u8 },
    window_move_output: struct { id: []const u8, output: []const u8 },
    workspace_activate: Activate,
    workspace_rename: struct { id: []const u8, name: []const u8 },
    keyboard_set: struct { seat: ?[]const u8 = null, group: ?[]const u8 = null, index: u32 },
    keyboard_next: Keyboard,
    overview_show: struct { output: []const u8 },
    overview_hide: void,
    overview_toggle: struct { output: []const u8 },
    session_exit: void,
    session_reload: void,

    pub fn acceptsDeferred(self: Action) bool {
        return self == .window_close or self == .session_exit;
    }
    pub fn params(self: Action, a: std.mem.Allocator) ![]u8 {
        return switch (self) {
            inline else => |fields, tag| blk: {
                const name: []const u8 = switch (tag) {
                    .window_move_workspace, .window_move_output => "window.move",
                    else => comptime name: {
                        var value: [@tagName(tag).len]u8 = @tagName(tag).*;
                        for (&value) |*c| if (c.* == '_') {
                            c.* = '.';
                            break;
                        };
                        const result = value;
                        break :name &result;
                    },
                };
                break :blk try std.json.Stringify.valueAlloc(a, .{ .action = name, .fields = if (@TypeOf(fields) == void) struct {}{} else fields }, .{ .emit_null_optional_fields = false });
            },
        };
    }
};

fn strings(value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => if (T == []const u8) {
            if (value.len > 1024 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.Invalid;
        },
        .optional => if (value) |v| try strings(v),
        .@"struct" => inline for (@typeInfo(T).@"struct".fields) |f| try strings(@field(value, f.name)),
        else => {},
    }
}
fn output(model: *const Model, id: []const u8) !void {
    const o = model.get(.output, id) orelse return error.NotFound;
    if (!o.enabled or !o.powered) return error.Unavailable;
}
fn workspace(model: *const Model, id: []const u8) !void {
    const w = model.get(.workspace, id) orelse return error.NotFound;
    try output(model, w.output);
}
fn focusFor(model: *const Model, seat: ?[]const u8) !Model.Focus {
    return model.focus(seat) catch |err| switch (err) {
        error.UnknownSeat => error.NotFound,
        else => err,
    };
}
fn keyboard(model: *const Model, seat: ?[]const u8, group: ?[]const u8, index: ?u32) !void {
    const focus = try focusFor(model, seat);
    const k = if (group) |id| model.get(.keyboard, id) orelse return error.NotFound else focus.keyboard orelse return error.Unavailable;
    if (!std.mem.eql(u8, k.seat, focus.seat.id)) return error.NotFound;
    if (k.layouts.len == 0) return error.Unavailable;
    if (index) |i| if (i >= k.layouts.len) return error.Invalid;
}
pub fn validate(action: Action, model: *const Model, caps: codec.Capabilities) !void {
    if (!model.ready) return error.Unavailable;
    if ((model.get(.session, "session") orelse return error.Unavailable).locked) return error.Locked;
    if (!caps.commands) return error.Unsupported;
    switch (action) {
        inline else => |fields| try strings(fields),
    }
    switch (action) {
        .window_activate, .window_close, .window_minimized, .window_maximized, .window_fullscreen, .window_move_workspace, .window_move_output => {
            const id = switch (action) {
                inline else => |v| if (@TypeOf(v) != void and @hasField(@TypeOf(v), "id")) v.id else unreachable,
            };
            const w = model.get(.window, id) orelse return error.NotFound;
            switch (action) {
                .window_activate => |v| {
                    if (!w.can_activate) return error.Unsupported;
                    _ = try focusFor(model, v.seat);
                    if (w.output) |o| try output(model, o);
                },
                .window_minimized => |v| if (v.value != w.minimized and !w.can_minimize) return error.Unsupported,
                .window_maximized => |v| if (v.value != w.maximized and !w.can_maximize) return error.Unsupported,
                .window_move_workspace => |v| try workspace(model, v.workspace),
                .window_move_output => |v| try output(model, v.output),
                else => {},
            }
        },
        .workspace_activate => |v| {
            try workspace(model, v.id);
            _ = try focusFor(model, v.seat);
        },
        .workspace_rename => |v| {
            _ = model.get(.workspace, v.id) orelse return error.NotFound;
            if (std.mem.indexOfAny(u8, v.name, "\r\n") != null) return error.Invalid;
        },
        .keyboard_set => |v| {
            if (!caps.keyboard) return error.Unsupported;
            try keyboard(model, v.seat, v.group, v.index);
        },
        .keyboard_next => |v| {
            if (!caps.keyboard) return error.Unsupported;
            try keyboard(model, v.seat, v.group, null);
        },
        inline .switcher_next, .switcher_previous, .switcher_dismiss => |v| {
            if (v.scope != null) {
                if (!caps.global_window_switcher_v1) return error.Unsupported;
                if (v.workspace != null) return error.Invalid;
            } else {
                if (!caps.workspace_switcher_v1) return error.Unsupported;
                const active = model.activeWorkspace(v.output) orelse return error.Unavailable;
                if (!std.mem.eql(u8, active.id, v.workspace orelse return error.Invalid)) return error.Unavailable;
            }
            try output(model, v.output);
            _ = try focusFor(model, v.seat);
        },
        inline .overview_show, .overview_toggle => |v| {
            if (!caps.overview) return error.Unsupported;
            try output(model, v.output);
        },
        .overview_hide => if (!caps.overview) return error.Unsupported,
        .session_reload => if (!caps.config_reload) return error.Unsupported,
        .session_exit => {},
    }
}
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    action: Action,
    ticket: u64,
    pub fn init(a: std.mem.Allocator, action: Action, ticket: u64) !Owned {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const copy = switch (action) {
            inline else => |v, tag| @unionInit(Action, @tagName(tag), try e.clone(@TypeOf(v), arena.allocator(), v)),
        };
        return .{ .arena = arena, .action = copy, .ticket = ticket };
    }
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
