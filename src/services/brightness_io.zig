//! Worker-only hardware discovery and DDC/CI. libddcutil is an optional runtime dependency.
//! Uses public display-info records, opaque handles and the four-byte VCP value record.
//! Reference: https://github.com/rockowitz/ddcutil/tree/master/src/public
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const model = @import("brightness_model.zig");
const policy = @import("policy.zig");
const Device = model.Device;
const Text = model.Text;
extern "c" fn dlopen([*:0]const u8, c_int) ?*anyopaque;
extern "c" fn dlsym(*anyopaque, [*:0]const u8) ?*anyopaque;
const Handle = ?*anyopaque;
const Value = extern struct { mh: u8, ml: u8, sh: u8, sl: u8 };
// DDCA_Display_Info (also used by get_display_info_list2, not Display_Info2).
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
const DisplayInfoList = extern struct { ct: c_int, info: [0]DisplayInfo };
const Api = struct {
    ddca_get_display_info_list2: *const fn (bool, *?*DisplayInfoList) callconv(.c) c_int,
    ddca_free_display_info_list: *const fn (*DisplayInfoList) callconv(.c) void,
    ddca_open_display2: *const fn (Handle, bool, *Handle) callconv(.c) c_int,
    ddca_close_display: *const fn (Handle) callconv(.c) c_int,
    ddca_get_non_table_vcp_value: *const fn (Handle, u8, *Value) callconv(.c) c_int,
    ddca_set_non_table_vcp_value: *const fn (Handle, u8, u8, u8) callconv(.c) c_int,
    ddca_redetect_displays: *const fn () callconv(.c) c_int,
    ddca_set_fout: *const fn (Handle) callconv(.c) void,
    ddca_set_ferr: *const fn (Handle) callconv(.c) void,
};
// All calls (including re-detection) are serialized across worker tasks. Never
// unload libddcutil: it owns process-lifetime state and may own internal threads.
var mutex: glib.Mutex = std.mem.zeroes(glib.Mutex);
var attempted = false;
var library: ?Api = null;
fn api() ?*const Api {
    if (!attempted) {
        attempted = true;
        const lib = dlopen("libddcutil.so.5", 2) orelse dlopen("libddcutil.so.4", 2) orelse return null;
        var next: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(next, field.name) = @ptrCast(dlsym(lib, field.name ++ "\x00") orelse return null);
        }
        library = next;
    }
    if (library) |*lib| {
        lib.ddca_set_fout(null);
        lib.ddca_set_ferr(null);
        return lib;
    }
    return null;
}
fn read(path: [:0]const u8, buffer: []u8) ?[]u8 {
    var bytes: [*]u8 = undefined;
    var len: usize = 0;
    if (glib.fileGetContents(path, &bytes, &len, null) == 0) return null;
    defer glib.free(bytes);
    if (len > buffer.len) return null;
    @memcpy(buffer[0..len], bytes[0..len]);
    return buffer[0..len];
}
fn number(path: [:0]const u8) ?u32 {
    var buf: [32]u8 = undefined;
    return std.fmt.parseInt(u32, std.mem.trim(u8, read(path, &buf) orelse return null, " \n\t"), 10) catch null;
}
const readName: *const fn (*glib.Dir) callconv(.c) ?[*:0]const u8 = @ptrCast(&glib.Dir.readName);
pub fn scan(backlight_root: [:0]const u8, drm_root: [:0]const u8, cancel: *gio.Cancellable) model.List {
    var result: model.List = .{};
    if (glib.Dir.open(backlight_root, 0, null)) |dir| {
        defer dir.close();
        var visited: usize = 0;
        while (readName(dir)) |raw_name| {
            visited += 1;
            if (visited > 64) break;
            if (result.len == model.capacity or cancel.isCancelled() != 0) break;
            const name = std.mem.span(raw_name);
            if (!policy.deviceName(name)) continue;
            var path: [768]u8 = undefined;
            const max = number(std.fmt.bufPrintZ(&path, "{s}/{s}/max_brightness", .{ backlight_root, name }) catch continue) orelse continue;
            const value = number(std.fmt.bufPrintZ(&path, "{s}/{s}/brightness", .{ backlight_root, name }) catch continue) orelse continue;
            if (max == 0 or max > std.math.maxInt(i32) or value > max) continue;
            var d: Device = .{ .backend = .backlight, .maximum = max, .value = value };
            d.id.set(name);
            d.name.set(name);
            result.add(d);
        }
    }
    const backlights = result.len;
    // Tests overriding only the backlight root must never discover host monitors.
    if (drm_root.len == 0) {
        sort(&result);
        return result;
    }
    const dir = glib.Dir.open(drm_root, 0, null) orelse {
        sort(&result);
        return result;
    };
    defer dir.close();
    var internal_count: usize = 0;
    var internal: Text(128) = .{};
    var visited: usize = 0;
    while (readName(dir)) |raw_name| {
        visited += 1;
        if (visited > 256) break;
        if (result.len == model.capacity or cancel.isCancelled() != 0) break;
        const name = std.mem.span(raw_name);
        const dash = std.mem.indexOfScalar(u8, name, '-') orelse continue;
        if (!std.mem.startsWith(u8, name, "card") or !policy.deviceName(name)) continue;
        var path: [768]u8 = undefined;
        var content: [32768]u8 = undefined;
        const status = read(std.fmt.bufPrintZ(&path, "{s}/{s}/status", .{ drm_root, name }) catch continue, &content) orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, status, "\n"), "connected")) continue;
        const output = name[dash + 1 ..];
        if (std.mem.startsWith(u8, output, "eDP-") or std.mem.startsWith(u8, output, "LVDS-")) {
            internal_count += 1;
            internal.set(output);
            if (backlights == 1) continue;
        }
        var d: Device = .{ .reason = "Brightness control is unavailable for this display." };
        d.connector.set(name);
        d.output.set(output);
        d.name.set(output);
        if (read(std.fmt.bufPrintZ(&path, "{s}/{s}/edid", .{ drm_root, name }) catch continue, &content)) |edid| {
            if (edid.len >= 128) {
                @memcpy(&d.edid, edid[0..128]);
                d.backend = .ddc;
                // EDID monitor-name descriptor, bounded and free of controls.
                for ([_]usize{ 54, 72, 90, 108 }) |offset| {
                    if (std.mem.eql(u8, edid[offset..][0..4], &.{ 0, 0, 0, 0xfc })) {
                        const label = std.mem.trim(u8, edid[offset + 5 ..][0..13], " \n\x00");
                        var valid = label.len > 0;
                        for (label) |byte| if (byte < 32 or byte > 126) {
                            valid = false;
                        };
                        if (valid) d.name.set(label);
                    }
                }
            }
        }
        var ident: [128]u8 = undefined;
        d.id.set(std.fmt.bufPrint(&ident, "ddc:{s}:{x}", .{ name, std.hash.Wyhash.hash(0, &d.edid) }) catch continue);
        result.add(d);
    }
    if (backlights == 1 and internal_count == 1) {
        result.items[0].output = internal;
    }
    if (result.len == backlights) {
        sort(&result);
        return result;
    }
    mutex.lock();
    defer mutex.unlock();
    const lib = api();
    if (lib) |l| _ = l.ddca_redetect_displays();
    for (result.slice()[backlights..]) |*d| {
        if (cancel.isCancelled() != 0) break;
        if (d.backend != .ddc) continue;
        var duplicate = false;
        for (result.slice()[backlights..]) |*other| if (other != d and std.mem.eql(u8, &other.edid, &d.edid)) {
            duplicate = true;
        };
        if (duplicate) {
            d.reason = "Display identity is ambiguous; brightness control is disabled.";
            continue;
        }
        const l = lib orelse {
            d.reason = "Install ddcutil to enable external display brightness.";
            continue;
        };
        d.reason = access(l, d, null);
    }
    sort(&result);
    return result;
}
fn sort(result: *model.List) void {
    result.unmapAmbiguousOutputs();
    std.mem.sort(Device, result.slice(), {}, struct {
        fn less(_: void, x: Device, y: Device) bool {
            return std.mem.order(u8, x.id.slice(), y.id.slice()) == .lt;
        }
    }.less);
}
fn access(lib: *const Api, device: *Device, wanted: ?u8) ?[]const u8 {
    // Match the full base EDID ourselves. The identifier -> reference path in
    // some libddcutil releases leaves the selector's EDID length at zero and
    // aborts inside ddc_test_display_ref_by_selector.
    var list: ?*DisplayInfoList = null;
    if (lib.ddca_get_display_info_list2(true, &list) != 0) return "Cannot enumerate external displays.";
    const displays = list orelse return "Cannot enumerate external displays.";
    defer lib.ddca_free_display_info_list(displays);
    if (displays.ct < 0 or displays.ct > 256) return "Cannot enumerate external displays.";
    const info: [*]const DisplayInfo = @ptrCast(&displays.info);
    var ref: Handle = null;
    var matched = false;
    for (info[0..@intCast(displays.ct)]) |display| {
        if (!std.mem.eql(u8, &display.edid_bytes, &device.edid)) continue;
        if (matched) return "Display identity is ambiguous; brightness control is disabled.";
        matched = true;
        ref = display.dref;
    }
    if (ref == null) return "Display is asleep, disconnected, or DDC/CI is unavailable.";
    var handle: Handle = null;
    const opened = lib.ddca_open_display2(ref, false, &handle);
    if (opened != 0) return if (opened == -13 or opened == -1) "Display access denied. Check I²C device permissions." else "Display is busy or unavailable. Try again.";
    defer _ = lib.ddca_close_display(handle);
    var value: Value = undefined;
    if (lib.ddca_get_non_table_vcp_value(handle, 0x10, &value) != 0) return "Display did not report brightness. Check DDC/CI in its menu.";
    device.maximum = @as(u32, value.mh) * 256 + value.ml;
    device.value = @as(u32, value.sh) * 256 + value.sl;
    if (device.maximum == 0 or device.value > device.maximum) {
        device.maximum = 0;
        return "Display returned an invalid brightness range.";
    }
    if (wanted) |percent| {
        const raw_value = device.raw(percent) catch return "Invalid brightness value.";
        if (lib.ddca_set_non_table_vcp_value(handle, 0x10, @intCast(raw_value >> 8), @intCast(raw_value & 255)) != 0) return "Display did not accept brightness. Try again.";
        if (lib.ddca_get_non_table_vcp_value(handle, 0x10, &value) != 0) return "Brightness was sent but could not be confirmed.";
        device.value = @as(u32, value.sh) * 256 + value.sl;
        if (device.value > device.maximum) return "Display returned an invalid brightness value.";
    }
    return null;
}
pub fn writeDdc(device: *Device, percent: u8, drm_root: [:0]const u8, cancel: *gio.Cancellable) ?[]const u8 {
    // Re-discover before every write. A replaced monitor must never inherit a queued request.
    var fresh = scan("/nonexistent/pearl-backlight", drm_root, cancel);
    const target = fresh.find(device.id.slice()) orelse return "Display disconnected before brightness could be applied.";
    if (target.reason) |reason| return reason;
    if (cancel.isCancelled() != 0) return "Brightness request canceled.";
    mutex.lock();
    defer mutex.unlock();
    const lib = api() orelse return "External brightness support is unavailable.";
    device.maximum = target.maximum;
    device.value = target.value;
    return access(lib, device, percent);
}
