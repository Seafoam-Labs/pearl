const std = @import("std");
const u = @import("widgets.zig");
const c = u.c;
const shared = @import("appearance_client");
pub const Mode = @import("../platform/preferences.zig").Preferences.Theme;
pub const Colors = @import("colors.zig").Colors;
const RGB = @import("colors.zig").RGB;

pub fn rgb(hex: []const u8) !RGB {
    if (hex.len != 7 or hex[0] != '#') return error.InvalidColor;
    var result: RGB = undefined;
    for (&result, 0..) |*value, i| value.* = @as(f64, @floatFromInt(try std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16))) / 255;
    return result;
}

pub fn colors(s: shared.Snapshot) !Colors {
    const primary = try rgb(s.palette.primary);
    const text = try rgb(s.palette.text);
    const secondary = try rgb(s.palette.secondary);
    var result: Colors = .{ .native = s.mode == .gtk, .text = text };
    // The palette has one semantic accent. Vary it toward legible foreground
    // colors; graph dashes additionally distinguish overlapping series.
    for (&result.series, 0..) |*series, i| {
        const weight = @as(f64, @floatFromInt(i)) / 7;
        for (series, 0..) |*value, channel| value.* = primary[channel] * (1 - weight) + (if (i % 2 == 0) text[channel] else secondary[channel]) * weight;
    }
    return result;
}

pub fn render(a: std.mem.Allocator, s: shared.Snapshot) ![:0]u8 {
    try shared.theme.validate(s.palette);
    const base = if (s.mode == .gtk) try a.dupeSentinel(u8, "", 0) else try shared.theme.scopedCss(a, @embedFile("theme_style"), "pearl", s.palette);
    defer a.free(base);
    const tokens = try shared.style.tokenCss(a, s.style_tokens, s.reduced_motion);
    defer a.free(tokens);
    var components = try std.fmt.allocPrint(a, "{s}\n{s}", .{ tokens, s.style_css });
    defer a.free(components);
    // Map Pearl's bounded component grammar to Dome's existing widget classes.
    inline for (.{ .{ ".pearl-root", ".dome-root" }, .{ ".pearl-card-title", ".title" }, .{ ".pearl-card", ".card" }, .{ ".settings-card", ".card" }, .{ ".pearl-compact", ".compact" } }) |pair| {
        const next = try std.mem.replaceOwned(u8, a, components, pair[0], pair[1]);
        a.free(components);
        components = next;
    }
    const resolved = try shared.theme.scopedCss(a, components, "pearl", s.palette);
    defer a.free(resolved);
    const font = try std.json.Stringify.valueAlloc(a, if (s.font.len > 0) s.font else "Sans", .{});
    defer a.free(font);
    return std.fmt.allocPrintSentinel(a, "{s}\n{s}\n.dome-root.pearl {{ font-family: {s}; font-size: {d}pt; }}\n{s}", .{ base, resolved, font, s.font_size, if (s.reduced_motion) ".dome-root.pearl * { transition-duration: 0ms; animation-duration: 0ms; }" else "" }, 0);
}

pub const Appearance = struct {
    mode: ?Mode = null,
    subscription: ?*shared.Subscription = null,
    provider: ?*c.GtkCssProvider = null,
    native_provider: ?*c.GtkCssProvider = null,
    palette: Colors = .{},
    revision: ?u64 = null,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,

    pub fn setMode(self: *Appearance, mode: Mode) void {
        if (self.mode == mode) return;
        self.clear();
        self.mode = mode;
        self.palette = .{};
        if (mode == .light or mode == .dark) self.palette = .{
            .native = false,
            .text = rgb(if (mode == .light) shared.theme.light.text else shared.theme.dark.text) catch unreachable,
            .series = if (mode == .light) Colors.light else Colors.dark,
        };
        if (mode == .follow_pearl) self.subscription = shared.Subscription.start(self, received) catch null;
    }
    fn received(context: *anyopaque, snapshot: shared.Snapshot) void {
        const self: *Appearance = @ptrCast(@alignCast(context));
        self.apply(snapshot) catch |err| std.log.scoped(.config).warn("event=appearance-rejected error={s}", .{@errorName(err)});
    }
    pub fn apply(self: *Appearance, snapshot: shared.Snapshot) !void {
        if (self.mode != .follow_pearl) return;
        const css = try render(u.a, snapshot);
        defer u.a.free(css);
        const palette = try colors(snapshot);
        const name = try u.a.dupeSentinel(u8, snapshot.gtk_name, 0);
        defer u.a.free(name);
        if (self.provider == null) {
            self.provider = c.gtk_css_provider_new().?;
            c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(self.provider.?), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            self.native_provider = c.gtk_css_provider_new().?;
            c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(self.native_provider.?), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION - 2);
        }
        if (snapshot.mode == .gtk and name.len > 0) c.gtk_css_provider_load_named(self.native_provider, name, if (snapshot.variant == .dark) "dark" else null) else c.gtk_css_provider_load_from_string(self.native_provider, "");
        c.gtk_css_provider_load_from_string(self.provider, css);
        self.palette = palette;
        self.revision = snapshot.revision;
        self.changed(self.context);
    }
    pub fn styleWindow(self: *const Appearance, window: u.W, compact: bool) void {
        for ([_][*:0]const u8{ "light", "dark", "pearl", "compact" }) |name| c.gtk_widget_remove_css_class(window, name);
        if (self.mode) |mode| switch (mode) {
            .light => u.class(window, "light"),
            .dark => u.class(window, "dark"),
            .follow_pearl => if (self.revision != null) {
                u.class(window, "pearl");
            },
            .native_gtk => {},
        };
        if (compact) u.class(window, "compact");
    }
    fn clear(self: *Appearance) void {
        if (self.subscription) |subscription| subscription.stop();
        self.subscription = null;
        for ([_]?*c.GtkCssProvider{ self.provider, self.native_provider }) |item| if (item) |provider| {
            c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), @ptrCast(provider));
            c.g_object_unref(provider);
        };
        self.provider = null;
        self.native_provider = null;
        self.revision = null;
    }
    pub fn deinit(self: *Appearance) void {
        self.clear();
    }
};

test "committed colors and styles map to Dome without retaining snapshot slices" {
    const a = std.testing.allocator;
    var s: shared.Snapshot = .{ .palette = shared.theme.light, .variant = .light, .font = "Sans", .font_size = 16, .style_tokens = .{ .card_radius = 18 }, .reduced_motion = true };
    const css = try render(a, s);
    defer a.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".dome-root.pearl { background: #fdf7ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "border-radius: 18px") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "font-size: 16pt") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "transition-duration: 0ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "$scope") == null);
    const resolved = try colors(s);
    try std.testing.expectEqual(try rgb(s.palette.primary), resolved.series[0]);
    try std.testing.expect(!std.mem.eql(f64, &resolved.series[0], &resolved.series[1]));
    s.mode = .gtk;
    const native = try render(a, s);
    defer a.free(native);
    try std.testing.expect(std.mem.indexOf(u8, native, "background:") == null);
    try std.testing.expect((try colors(s)).native);
    s.palette.primary = "bad";
    try std.testing.expectError(error.InvalidPalette, render(a, s));
}
