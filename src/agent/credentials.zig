//! libsecret is the native Secret Service integration boundary. Keys never
//! enter preferences, subprocess arguments, prompts or diagnostics.
const std = @import("std");
// Stable libsecret 0.21 ABI; use existing GLib/GIO bindings rather than
// retranslating GLib's declaration macros with Zig's C frontend.
const c = struct {
    const GError = @import("glib2").Error;
    const SecretSchemaAttribute = extern struct { name: ?[*:0]const u8, type: c_int };
    const SecretSchema = extern struct {
        name: [*:0]const u8,
        flags: c_int,
        attributes: [32]SecretSchemaAttribute,
        reserved: c_int = 0,
        reserved1: ?*anyopaque = null,
        reserved2: ?*anyopaque = null,
        reserved3: ?*anyopaque = null,
        reserved4: ?*anyopaque = null,
        reserved5: ?*anyopaque = null,
        reserved6: ?*anyopaque = null,
        reserved7: ?*anyopaque = null,
    };
    const SECRET_SCHEMA_ATTRIBUTE_STRING = 0;
    const SECRET_SCHEMA_NONE = 0;
    const SECRET_COLLECTION_SESSION: [*:0]const u8 = "session";
    const SECRET_COLLECTION_DEFAULT: [*:0]const u8 = "default";
    extern fn secret_password_lookup_sync(*const SecretSchema, ?*anyopaque, *?*GError, ...) ?[*:0]u8;
    extern fn secret_password_store_sync(*const SecretSchema, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*anyopaque, *?*GError, ...) c_int;
    extern fn secret_password_clear_sync(*const SecretSchema, ?*anyopaque, *?*GError, ...) c_int;
    extern fn secret_password_free(?[*:0]u8) void;
    fn g_error_free(err: *GError) void {
        err.free();
    }
};
const schema: c.SecretSchema = .{
    .name = "org.aqueous.Pearl.Assistant",
    .flags = c.SECRET_SCHEMA_NONE,
    .attributes = blk: {
        var attrs: [32]c.SecretSchemaAttribute = @splat(.{ .name = null, .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING });
        attrs[0] = .{ .name = "provider", .type = c.SECRET_SCHEMA_ATTRIBUTE_STRING };
        break :blk attrs;
    },
};
pub fn lookup(a: std.mem.Allocator, id: []const u8) ![]const u8 {
    const key = try a.dupeZ(u8, id);
    defer a.free(key);
    var err: ?*c.GError = null;
    const value = c.secret_password_lookup_sync(&schema, null, &err, @as([*:0]const u8, "provider"), key.ptr, @as(?*anyopaque, null));
    defer if (err) |e| c.g_error_free(e);
    if (value == null) return if (err != null) error.SecretServiceUnavailable else error.SearchCredentialRequired;
    defer c.secret_password_free(value);
    return a.dupe(u8, std.mem.span(value.?));
}
pub fn store(id: []const u8, secret: []const u8, session_only: bool) !void {
    const a = std.heap.c_allocator;
    if (secret.len == 0 or secret.len > 1024 or std.mem.indexOfAny(u8, secret, "\r\n\x00") != null) return error.InvalidCredential;
    const key = try a.dupeZ(u8, id);
    defer a.free(key);
    const value = try a.dupeZ(u8, secret);
    defer {
        std.crypto.secureZero(u8, value);
        a.free(value);
    }
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    if (c.secret_password_store_sync(&schema, if (session_only) c.SECRET_COLLECTION_SESSION else c.SECRET_COLLECTION_DEFAULT, "Pearl search provider", value.ptr, null, &err, @as([*:0]const u8, "provider"), key.ptr, @as(?*anyopaque, null)) == 0) return error.SecretServiceUnavailable;
}
pub fn remove(id: []const u8) !void {
    const a = std.heap.c_allocator;
    const key = try a.dupeZ(u8, id);
    defer a.free(key);
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    _ = c.secret_password_clear_sync(&schema, null, &err, @as([*:0]const u8, "provider"), key.ptr, @as(?*anyopaque, null));
    if (err != null) return error.SecretServiceUnavailable;
}
