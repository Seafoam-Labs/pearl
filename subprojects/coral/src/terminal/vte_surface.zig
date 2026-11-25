//! The workspace terminal uses GTK4 VTE for input, grid layout and emulation.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const v = @import("vte_abi.zig");
const View = @import("vte_view.zig").View;
const Pty = @import("pty.zig").Pty;
const Palette = @import("appearance_client").theme.Palette;

extern "c" fn vte_terminal_set_font(*v.Object, *c.PangoFontDescription) void;
extern "c" fn vte_terminal_set_input_enabled(*v.Object, c_int) void;
extern "c" fn vte_terminal_set_color_foreground(*v.Object, *const c.GdkRGBA) void;
extern "c" fn vte_terminal_set_color_background(*v.Object, *const c.GdkRGBA) void;
extern "c" fn vte_terminal_set_color_cursor(*v.Object, ?*const c.GdkRGBA) void;
extern "c" fn vte_terminal_get_window_title(*v.Object) ?[*:0]const u8;

pub const Surface = struct {
    view: View,
    widget: u.W,

    pub fn init() Surface {
        const view = View.init();
        vte_terminal_set_input_enabled(view.widget, 0);
        return .{ .view = view, .widget = u.cast(c.GtkWidget, view.widget) };
    }
    pub fn start(self: *Surface, handle: *const Pty) !void {
        try self.view.attach(handle);
        vte_terminal_set_input_enabled(self.view.widget, 1);
    }
    pub fn disableInput(self: *Surface) void {
        vte_terminal_set_input_enabled(self.view.widget, 0);
    }
    pub fn focus(self: *Surface) void {
        _ = c.gtk_widget_grab_focus(self.widget);
    }
    pub fn grid(self: *Surface) [2]c_long {
        return .{ v.vte_terminal_get_column_count(self.view.widget), v.vte_terminal_get_row_count(self.view.widget) };
    }
    pub fn title(self: *Surface) []const u8 {
        return if (vte_terminal_get_window_title(self.view.widget)) |title_| std.mem.span(title_) else "Terminal";
    }
    pub fn setFont(self: *Surface, family: [:0]const u8, size: c_int) void {
        const desc = c.pango_font_description_new().?;
        defer c.pango_font_description_free(desc);
        c.pango_font_description_set_family(desc, family);
        c.pango_font_description_set_absolute_size(desc, @floatFromInt(size * c.PANGO_SCALE));
        vte_terminal_set_font(self.view.widget, desc);
    }
    pub fn setColors(self: *Surface, palette: Palette, native: bool) void {
        var fg = color(palette.text);
        var bg = color(palette.low);
        const cursor = color(palette.primary);
        if (native) {
            const context = c.gtk_widget_get_style_context(self.widget);
            c.gtk_widget_get_color(self.widget, &fg);
            _ = c.gtk_style_context_lookup_color(context, "theme_bg_color", &bg);
        }
        vte_terminal_set_color_foreground(self.view.widget, &fg);
        vte_terminal_set_color_background(self.view.widget, &bg);
        vte_terminal_set_color_cursor(self.view.widget, if (native) null else &cursor);
    }
    pub fn deinit(self: *Surface) void {
        self.view.deinit();
    }
};
fn color(hex: []const u8) c.GdkRGBA {
    const terminated = u.z(hex);
    defer u.a.free(terminated);
    var result: c.GdkRGBA = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 };
    _ = c.gdk_rgba_parse(&result, terminated);
    return result;
}
