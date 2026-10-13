//! Observe committed shell appearance for the portal settings and dialogs.
const gtk = @import("gtk4");
const appearance = @import("../ui/appearance_observer.zig");
const portal_appearance = @import("settings.zig").portal_appearance;
var observer: ?*appearance.Observer = null;
var context: u8 = 0;
fn changed(_: *anyopaque, s: appearance.Snapshot, rgb: [3]f64, font: [:0]const u8, css: [:0]const u8) void {
    @import("file_chooser").pearl_file_appearance(@intFromBool(s.mode == .gtk));
    portal_appearance(if (s.variant == .dark) 1 else 2, rgb[0], rgb[1], rgb[2], @intFromBool(s.reduced_motion), font, css);
}
pub fn start() void {
    if (observer != null or gtk.initCheck() == 0) return;
    observer = appearance.Observer.start(&context, changed) catch null;
}
pub fn stop() void {
    if (observer) |self| self.stop();
    observer = null;
}
