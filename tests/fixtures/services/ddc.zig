//! Private libddcutil ABI fixture. Never installed; uses only PEARL_TEST_DDC files.
const std = @import("std");
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(*anyopaque) c_int;
extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern "c" fn usleep(c_uint) c_int;
const Handle = ?*anyopaque;
const Value = extern struct { mh: u8, ml: u8, sh: u8, sl: u8 };
fn file(id: usize, suffix: []const u8, mode: [*:0]const u8) ?*anyopaque {
    const root = getenv("PEARL_TEST_DDC") orelse return null;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{d}{s}", .{ std.mem.span(root), id, suffix }) catch return null;
    return fopen(path, mode);
}
fn number(id: usize, suffix: []const u8) ?u16 {
    const f = file(id, suffix, "r") orelse return null;
    defer _ = fclose(f);
    var buf: [32]u8 = undefined;
    const n = fread(&buf, 1, buf.len, f);
    return std.fmt.parseInt(u16, std.mem.trim(u8, buf[0..n], "\n "), 10) catch null;
}
export fn ddca_create_edid_display_identifier(edid: [*]const u8, out: *Handle) c_int {
    if (edid[0] < 1 or edid[0] > 3) return -3001;
    out.* = @ptrFromInt(edid[0]);
    return 0;
}
export fn ddca_free_display_identifier(_: Handle) c_int {
    return 0;
}
export fn ddca_get_display_ref(id: Handle, out: *Handle) c_int {
    out.* = id;
    return 0;
}
export fn ddca_open_display2(ref: Handle, _: bool, out: *Handle) c_int {
    if (number(@intFromPtr(ref), ".deny") == 1) return -13;
    if (number(@intFromPtr(ref), "") == null) return -3001;
    out.* = ref;
    return 0;
}
export fn ddca_close_display(_: Handle) c_int {
    return 0;
}
export fn ddca_redetect_displays() c_int {
    return 0;
}
export fn ddca_set_fout(_: Handle) void {}
export fn ddca_set_ferr(_: Handle) void {}
export fn ddca_get_non_table_vcp_value(handle: Handle, feature: u8, out: *Value) c_int {
    if (feature != 0x10) return -3001;
    const value = number(@intFromPtr(handle), "") orelse return -3001;
    out.* = .{ .mh = 0, .ml = 100, .sh = @intCast(value >> 8), .sl = @intCast(value & 255) };
    return 0;
}
export fn ddca_set_non_table_vcp_value(handle: Handle, feature: u8, hi: u8, lo: u8) c_int {
    if (feature != 0x10 or hi != 0 or lo > 100) return -3001;
    const id = @intFromPtr(handle);
    if (number(id, ".deny") == 1) return -13;
    _ = usleep(180000);
    const f = file(id, "", "w") orelse return -13;
    defer _ = fclose(f);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{lo}) catch return -3001;
    _ = fwrite(text.ptr, 1, text.len, f);
    return 0;
}
