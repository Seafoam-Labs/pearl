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
const DisplayInfo = extern struct {
    marker: [4]u8,
    dispno: c_int,
    path: extern struct { io_mode: c_uint, path: extern union { i2c_busno: c_int, hiddev_devno: c_int } },
    usb_bus: c_int,
    usb_device: c_int,
    mfg_id: [4]u8,
    model_name: [14]u8,
    sn: [14]u8,
    product_code: u16,
    edid_bytes: [128]u8,
    vcp_version: extern struct { major: u8, minor: u8 },
    dref: Handle,
};
const DisplayInfoList = extern struct { ct: c_int, info: [4]DisplayInfo };
var displays: DisplayInfoList = undefined;
fn file(id: usize, suffix: []const u8, mode: [*:0]const u8) ?*anyopaque {
    const root = getenv("PEARL_TEST_DDC") orelse return null;
    var buf: [1024]u8 = undefined;
    const path = std.mem.printSentinel(&buf, "{s}/{d}{s}", .{ std.mem.span(root), id, suffix }, 0) catch return null;
    return fopen(path, mode);
}
fn number(id: usize, suffix: []const u8) ?u16 {
    const f = file(id, suffix, "r") orelse return null;
    defer _ = fclose(f);
    var buf: [32]u8 = undefined;
    const n = fread(&buf, 1, buf.len, f);
    return std.fmt.parseInt(u16, std.mem.trim(u8, buf[0..n], "\n "), 10) catch null;
}
fn record(operation: []const u8, id: usize) void {
    const f = file(0, ".calls", "a") orelse return;
    defer _ = fclose(f);
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} {d}\n", .{ operation, id }) catch return;
    _ = fwrite(line.ptr, 1, line.len, f);
}
// Deliberately do not export the crashing EDID identifier lookup API.
export fn ddca_get_display_info_list2(_: bool, out: **DisplayInfoList) c_int {
    record("enumerate", 0);
    if (number(0, ".fail") == 1) return -3001;
    displays = std.mem.zeroes(DisplayInfoList);
    for ([_]u8{ 3, 2, 1 }) |id| {
        if (number(id, "") == null) continue;
        const index: usize = @intCast(displays.ct);
        var info = &displays.info[index];
        info.marker = "DDIN".*;
        info.dispno = id;
        info.edid_bytes[0] = id;
        info.dref = @ptrFromInt(id);
        displays.ct += 1;
        if (number(id, ".duplicate") == 1) {
            displays.info[@intCast(displays.ct)] = info.*;
            displays.ct += 1;
        }
    }
    out.* = &displays;
    return 0;
}
export fn ddca_free_display_info_list(_: *DisplayInfoList) void {}
export fn ddca_open_display2(ref: Handle, _: bool, out: *Handle) c_int {
    record("open", @intFromPtr(ref));
    if (number(@intFromPtr(ref), ".deny") == 1) return -13;
    if (number(@intFromPtr(ref), "") == null) return -3001;
    out.* = ref;
    return 0;
}
export fn ddca_close_display(handle: Handle) c_int {
    record("close", @intFromPtr(handle));
    return 0;
}
export fn ddca_redetect_displays() c_int {
    record("redetect", 0);
    return 0;
}
export fn ddca_set_fout(_: Handle) void {}
export fn ddca_set_ferr(_: Handle) void {}
export fn ddca_get_non_table_vcp_value(handle: Handle, feature: u8, out: *Value) c_int {
    record("read", @intFromPtr(handle));
    if (number(@intFromPtr(handle), ".read-delay")) |delay| _ = usleep(@as(c_uint, delay) * 1000);
    if (feature != 0x10) return -3001;
    const value = number(@intFromPtr(handle), "") orelse return -3001;
    out.* = .{ .mh = 0, .ml = 100, .sh = @intCast(value >> 8), .sl = @intCast(value & 255) };
    return 0;
}
export fn ddca_set_non_table_vcp_value(handle: Handle, feature: u8, hi: u8, lo: u8) c_int {
    record("write", @intFromPtr(handle));
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
