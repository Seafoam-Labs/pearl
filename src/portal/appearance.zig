//! C ABI adapter; appearance observation and CSS generation are shared Zig code.
const gtk = @import("gtk4");
const appearance = @import("../ui/appearance_observer.zig");
extern fn portal_appearance(c_uint, f64, f64, f64, c_int, [*:0]const u8, [*:0]const u8) void;
var observer: ?*appearance.Observer = null;
var context: u8 = 0;
fn changed(_: *anyopaque, s: appearance.Snapshot, rgb: [3]f64, font: [:0]const u8, css: [:0]const u8) void {
    @import("file_chooser").pearl_file_appearance(@intFromBool(s.mode == .gtk));
    portal_appearance(if (s.variant == .dark) 1 else 2, rgb[0], rgb[1], rgb[2], @intFromBool(s.reduced_motion), font, css);
}
export fn pearl_portal_appearance_start() void {
    if (observer != null or gtk.initCheck() == 0) return;
    observer = appearance.Observer.start(&context, changed) catch null;
}
export fn pearl_portal_appearance_stop() void {
    if (observer) |self| self.stop();
    observer = null;
}
