//! Schema-1 values. Strings are borrowed from the owning decoded frame or model.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Kind = enum { output, workspace, window, seat, keyboard, keyboard_device, session };
// Aqueous widens outer_geometry to i64 before adding compositor borders.
pub const Rect = struct { x: i64, y: i64, width: i64, height: i64 };
pub const Output = struct {
    id: []const u8,
    name: []const u8,
    bounds: Rect,
    usable_bounds: Rect,
    scale: f64,
    transform: []const u8,
    active_workspace: ?[]const u8,
    enabled: bool,
    powered: bool,
};
pub const Workspace = struct {
    id: []const u8,
    output: []const u8,
    name: []const u8,
    number: u32,
    active: bool,
    urgent: bool,
};
pub const Icon = struct { revision: []const u8, name: ?[]const u8, has_pixels: bool };
pub const Window = struct {
    id: []const u8,
    backend: enum { xdg, xwayland },
    app_id: ?[]const u8,
    class: ?[]const u8,
    title: ?[]const u8,
    workspace: ?[]const u8,
    output: ?[]const u8,
    geometry: Rect,
    outer_geometry: Rect,
    layout: []const u8,
    focused: bool,
    visible: bool,
    floating: bool,
    minimized: bool,
    maximized: bool,
    fullscreen: bool,
    skip_taskbar: bool,
    skip_switcher: bool,
    always_above: bool,
    always_below: bool,
    snapped: bool,
    fixed_position: bool,
    can_minimize: bool,
    can_maximize: bool,
    can_activate: bool,
    icon: ?Icon = null,
    tag: ?[]const u8 = null,
    description: ?[]const u8 = null,
};
pub const FocusKind = enum { window, shell_surface, layer_surface, override_redirect, lock_surface, none };
pub const Seat = struct {
    id: []const u8,
    output: ?[]const u8,
    window: ?[]const u8,
    keyboard: ?[]const u8,
    focus_kind: FocusKind,
};
pub const Keyboard = struct { id: []const u8, seat: []const u8, layouts: []const []const u8, index: u32 };
pub const KeyboardDevice = struct { id: []const u8, name: ?[]const u8, seat: []const u8, group: ?[]const u8, virtual: bool };
pub const Session = struct { id: []const u8, locked: bool, default_seat: ?[]const u8, overview_output: ?[]const u8, overview_window: ?[]const u8 };
pub const Entity = union(Kind) {
    output: Output,
    workspace: Workspace,
    window: Window,
    seat: Seat,
    keyboard: Keyboard,
    keyboard_device: KeyboardDevice,
    session: Session,

    pub fn id(self: Entity) []const u8 {
        return switch (self) {
            inline else => |value| value.id,
        };
    }

    pub fn parse(allocator: Allocator, value: std.json.Value) !Entity {
        const kind = try read(Kind, allocator, try field(value, "kind"));
        const entity: Entity = switch (kind) {
            inline else => |tag| @unionInit(Entity, @tagName(tag), try read(@FieldType(Entity, @tagName(tag)), allocator, value)),
        };
        try entity.validate();
        return entity;
    }

    pub fn validate(entity: Entity) !void {
        if (entity.id().len == 0) return error.InvalidIdentity;
        switch (entity) {
            .output => |v| if (!std.math.isFinite(v.scale) or v.scale <= 0) return error.InvalidRange,
            .workspace => |v| if (v.number == 0 or v.output.len == 0) return error.InvalidRange,
            .window => |v| if (v.icon) |icon| {
                try decimal(icon.revision);
                if (icon.name) |name| if (name.len > 1024) return error.InvalidRange;
            },
            .keyboard => |v| {
                if (v.seat.len == 0) return error.InvalidIdentity;
                if ((v.layouts.len == 0 and v.index != 0) or (v.layouts.len > 0 and v.index >= v.layouts.len)) return error.InvalidRange;
            },
            .keyboard_device => |v| if (v.seat.len == 0) return error.InvalidIdentity,
            .session => |v| if (!std.mem.eql(u8, v.id, "session")) return error.InvalidIdentity,
            else => {},
        }
    }

    pub fn jsonStringify(self: Entity, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        try writer.objectField("kind");
        try writer.write(@tagName(std.meta.activeTag(self)));
        switch (self) {
            inline else => |value| inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |f| {
                try writer.objectField(f.name);
                try writer.write(@field(value, f.name));
            },
        }
        try writer.endObject();
    }

    pub fn encodedBytes(self: Entity) usize {
        var buffer: [256]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&buffer);
        std.json.Stringify.value(self, .{}, &discarding.writer) catch unreachable;
        return @intCast(discarding.fullCount());
    }
};

pub const Key = struct {
    kind: Kind,
    id: []const u8,
    pub fn parse(text: []const u8) !Key {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidIdentity;
        if (colon + 1 == text.len) return error.InvalidIdentity;
        return .{ .kind = std.meta.stringToEnum(Kind, text[0..colon]) orelse return error.InvalidIdentity, .id = text[colon + 1 ..] };
    }
};

/// Decimal wire identifiers remain exact strings, including leading zeroes.
/// Twenty digits is the local bound for the compositor's u64 counters; no float conversion.
pub fn decimal(value: []const u8) !void {
    if (value.len == 0 or value.len > 20) return error.InvalidDecimal;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidDecimal;
    _ = std.fmt.parseInt(u64, value, 10) catch return error.InvalidDecimal;
}

pub fn sessionToken(value: []const u8) !void {
    if (value.len != 32) return error.InvalidSession;
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidSession;
}

pub fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidType;
    return value.object.get(name) orelse error.MissingField;
}

/// Strict JSON typing (std.json's generic reader also accepts quoted numbers).
/// Unknown object fields are additive extensions; required nullable fields must exist.
pub fn read(comptime T: type, allocator: Allocator, value: std.json.Value) anyerror!T {
    switch (@typeInfo(T)) {
        .bool => return if (value == .bool) value.bool else error.InvalidType,
        .int => return if (value == .integer) std.math.cast(T, value.integer) orelse error.InvalidRange else error.InvalidType,
        .float => return switch (value) {
            .integer => |v| @floatFromInt(v),
            .float => |v| @floatCast(v),
            else => error.InvalidType,
        },
        .@"enum" => return if (value == .string) std.meta.stringToEnum(T, value.string) orelse error.InvalidEnum else error.InvalidType,
        .optional => |info| return if (value == .null) null else try read(info.child, allocator, value),
        .array => |info| {
            if (value != .array or value.array.items.len != info.len) return error.InvalidRange;
            var result: T = undefined;
            for (&result, value.array.items) |*out, item| out.* = try read(info.child, allocator, item);
            return result;
        },
        .pointer => |info| {
            if (info.child == u8) return if (value == .string) value.string else error.InvalidType;
            if (value != .array) return error.InvalidType;
            const result = try allocator.alloc(info.child, value.array.items.len);
            for (result, value.array.items) |*out, item| out.* = try read(info.child, allocator, item);
            return result;
        },
        .@"struct" => |info| {
            if (value != .object) return error.InvalidType;
            var result: T = undefined;
            inline for (info.fields) |f| {
                if (value.object.get(f.name)) |item| {
                    @field(result, f.name) = try read(f.type, allocator, item);
                } else if (f.defaultValue()) |default| {
                    @field(result, f.name) = default;
                } else return error.MissingField;
            }
            return result;
        },
        else => @compileError("Unsupported wire type " ++ @typeName(T)),
    }
}

/// Recursively copy only typed data, never retaining a frame's arena or unknown fields.
pub fn clone(comptime T: type, allocator: Allocator, value: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |info| {
            const result = try allocator.alloc(info.child, value.len);
            for (result, value) |*out, item| out.* = try clone(info.child, allocator, item);
            return result;
        },
        .optional => |info| return if (value) |v| try clone(info.child, allocator, v) else null,
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |f| @field(result, f.name) = try clone(f.type, allocator, @field(value, f.name));
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |v, tag| @unionInit(T, @tagName(tag), try clone(@TypeOf(v), allocator, v)),
        },
        else => return value,
    }
}

pub fn ownedBytes(value: anytype) usize {
    const T = @TypeOf(value);
    return @sizeOf(T) + switch (@typeInfo(T)) {
        .pointer => blk: {
            var size: usize = 0;
            for (value) |item| size += ownedBytes(item);
            break :blk size;
        },
        .optional => if (value) |v| ownedBytes(v) - @sizeOf(@TypeOf(v)) else 0,
        .@"struct" => |info| blk: {
            var size: usize = 0;
            inline for (info.fields) |f| size += ownedBytes(@field(value, f.name)) - @sizeOf(f.type);
            break :blk size;
        },
        .@"union" => switch (value) {
            inline else => |v| ownedBytes(v) - @sizeOf(@TypeOf(v)),
        },
        else => 0,
    };
}

test "fixed protocol arrays enforce length and element types" {
    const a = std.testing.allocator;
    const valid = try std.json.parseFromSlice(std.json.Value, a, "[1,2]", .{});
    defer valid.deinit();
    try std.testing.expectEqual([2]u8{ 1, 2 }, try read([2]u8, a, valid.value));
    try std.testing.expectError(error.InvalidRange, read([3]u8, a, valid.value));
    const invalid = try std.json.parseFromSlice(std.json.Value, a, "[1,\"2\"]", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidType, read([2]u8, a, invalid.value));
}
