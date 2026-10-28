//! Follows Pearl's committed appearance; manual modes keep Coral's own palette.
//! The editor buffer follows through a generated GtkSourceView style scheme.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const client = @import("appearance_client");
const log = std.log.scoped(.config);

pub const Mode = enum { dark, light, native_gtk, follow_pearl };
pub fn modeFrom(theme: c_int) Mode {
    return switch (theme) {
        1 => .light,
        2 => .native_gtk,
        3 => .follow_pearl,
        else => .dark,
    };
}

pub const Appearance = struct {
    mode: ?Mode = null,
    subscription: ?*client.Subscription = null,
    provider: ?*c.GtkCssProvider = null,
    native_provider: ?*c.GtkCssProvider = null,
    gtk_name: [:0]const u8 = "",
    font: []const u8 = "",
    font_size: u8 = 14,
    reduced_motion: bool = false,
    snapshot_gtk: bool = false,
    variant: enum { dark, light } = .dark,
    palette: client.theme.Palette = client.theme.dark,
    owns_palette: bool = false,
    revision: ?u64 = null,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,

    pub fn setMode(self: *Appearance, mode: Mode) void {
        if (self.mode == mode) return;
        self.clear();
        self.mode = mode;
        self.palette = if (mode == .light) client.theme.light else client.theme.dark;
        if (mode == .follow_pearl) self.subscription = client.Subscription.start(self, received) catch null;
        self.paint();
        self.changed(self.context);
    }
    fn received(context: *anyopaque, snapshot: client.Snapshot) void {
        const self: *Appearance = @ptrCast(@alignCast(context));
        self.apply(snapshot) catch |err| log.warn("event=appearance-rejected error={s}", .{@errorName(err)});
    }
    pub fn apply(self: *Appearance, snapshot: client.Snapshot) !void {
        if (self.mode != .follow_pearl) return;
        try client.theme.validate(snapshot.palette);
        const name = try u.a.dupeSentinel(u8, snapshot.gtk_name, 0);
        const font = try u.a.dupe(u8, snapshot.font);
        const palette = dupePalette(u.a, snapshot.palette);
        if (self.gtk_name.len > 0) u.a.free(self.gtk_name);
        if (self.font.len > 0) u.a.free(self.font);
        if (self.owns_palette) freePalette(u.a, self.palette);
        self.gtk_name = name;
        self.font = font;
        self.palette = palette;
        self.owns_palette = true;
        self.font_size = snapshot.font_size;
        self.reduced_motion = snapshot.reduced_motion;
        self.snapshot_gtk = snapshot.mode == .gtk;
        self.variant = if (snapshot.variant == .light) .light else .dark;
        self.revision = snapshot.revision;
        self.paint();
        self.changed(self.context);
    }
    pub fn followsGtk(self: *const Appearance) bool {
        return self.mode == .follow_pearl and self.revision != null and self.snapshot_gtk;
    }
    pub fn sheet(self: *const Appearance, a: std.mem.Allocator) ![:0]u8 {
        if (self.mode == .native_gtk or self.followsGtk()) return a.dupeSentinel(u8, "", 0);
        const scope = self.themeClass();
        const palette = if (self.mode == .follow_pearl and self.revision != null) self.palette else if (self.mode == .light) client.theme.light else client.theme.dark;
        try client.theme.validate(palette);
        const base = try client.theme.scopedCss(a, @embedFile("theme_style"), scope, palette);
        if (self.mode != .follow_pearl or self.revision == null) return base;
        defer a.free(base);
        const font = try std.json.Stringify.valueAlloc(a, if (self.font.len > 0) self.font else "Sans", .{});
        defer a.free(font);
        const motion: []const u8 = if (self.reduced_motion) try std.fmt.allocPrint(a, ".coral.{s} * {{ transition-duration: 0ms; animation-duration: 0ms; }}", .{scope}) else "";
        defer if (self.reduced_motion) a.free(motion);
        return std.fmt.allocPrintSentinel(a, "{s}\n.coral.{s} {{ font-family: {s}; font-size: {d}pt; }}\n{s}", .{ base, scope, font, self.font_size, motion }, 0);
    }
    fn paint(self: *Appearance) void {
        const display = c.gdk_display_get_default() orelse return;
        if (self.provider == null) {
            self.provider = c.gtk_css_provider_new().?;
            c.gtk_style_context_add_provider_for_display(display, u.cast(c.GtkStyleProvider, self.provider.?), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
            self.native_provider = c.gtk_css_provider_new().?;
            c.gtk_style_context_add_provider_for_display(display, u.cast(c.GtkStyleProvider, self.native_provider.?), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION - 2);
        }
        const css = self.sheet(u.a) catch |err| {
            log.warn("event=appearance-render-failed error={s}", .{@errorName(err)});
            return;
        };
        defer u.a.free(css);
        c.gtk_css_provider_load_from_string(self.provider.?, css);
        if (self.followsGtk() and self.gtk_name.len > 0) c.gtk_css_provider_load_named(self.native_provider.?, self.gtk_name, if (self.variant == .dark) "dark" else null) else c.gtk_css_provider_load_from_string(self.native_provider.?, "");
    }
    pub fn themeClass(self: *const Appearance) [:0]const u8 {
        const mode = self.mode orelse return "dark";
        switch (mode) {
            .native_gtk => return "native",
            .light => return "light",
            .dark => return "dark",
            .follow_pearl => {
                if (self.revision == null) return "dark";
                if (self.snapshot_gtk) return "native";
                return if (self.variant == .dark) "dark" else "light";
            },
        }
    }
    /// Writes a GtkSourceView scheme whose surfaces, text, selection and cursor
    /// follow the committed palette; syntax hues stay stock per variant.
    pub fn ensureScheme(self: *Appearance) [*:0]const u8 {
        const dark = self.variant == .dark;
        const stock: [*:0]const u8 = if (dark) "coral-dark" else "coral-light";
        const xml = schemeXml(u.a, self.palette, dark) catch return stock;
        defer u.a.free(xml);
        const dir = u.fmt("{s}/coral/styles", .{std.mem.span(c.g_get_user_cache_dir())});
        defer u.a.free(dir);
        if (c.g_mkdir_with_parents(dir, 0o700) != 0) return stock;
        const path = u.fmt("{s}/coral-pearl-{s}.xml", .{ dir, if (dark) "dark" else "light" });
        defer u.a.free(path);
        if (c.g_file_set_contents(path, xml, @intCast(xml.len), null) == 0) return stock;
        c.gtk_source_style_scheme_manager_force_rescan(c.gtk_source_style_scheme_manager_get_default());
        return if (dark) "coral-pearl-dark" else "coral-pearl-light";
    }
    pub fn schemeXml(a: std.mem.Allocator, p: client.theme.Palette, dark: bool) ![:0]u8 {
        const Hues = struct { string: []const u8, number: []const u8, type: []const u8 };
        const hues: Hues = if (dark) .{ .string = "#a6d7b5", .number = "#edbca0", .type = "#a7c8fa" } else .{ .string = "#34704c", .number = "#95542e", .type = "#386297" };
        const variant: []const u8 = if (dark) "dark" else "light";
        return std.fmt.allocPrintSentinel(a,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<style-scheme id="coral-pearl-{s}" name="Coral Pearl {s}" version="1.0">
            \\<author>Coral contributors</author>
            \\<style name="text" foreground="{s}" background="{s}"/>
            \\<style name="selection" foreground="{s}" background="{s}55"/>
            \\<style name="line-numbers" foreground="{s}" background="{s}"/>
            \\<style name="current-line" background="{s}"/>
            \\<style name="cursor" foreground="{s}"/>
            \\<style name="def:comment" foreground="{s}"/>
            \\<style name="def:keyword" foreground="{s}"/>
            \\<style name="def:string" foreground="{s}"/>
            \\<style name="def:number" foreground="{s}"/>
            \\<style name="def:type" foreground="{s}"/>
            \\<style name="def:heading" foreground="{s}" bold="true"/>
            \\<style name="def:link-text" foreground="{s}"/>
            \\<style name="def:emphasis" foreground="{s}" italic="true"/>
            \\<style name="def:strong-emphasis" foreground="{s}" bold="true"/>
            \\<style name="search-match" background="{s}" foreground="{s}"/>
            \\</style-scheme>
            \\
        , .{ variant, variant, p.text, p.surface, p.text, p.primary, p.outline, p.surface, p.low, p.primary, p.outline, p.primary, hues.string, hues.number, hues.type, p.primary, hues.type, hues.number, p.primary, p.primary_container, p.on_container }, 0);
    }
    pub fn rgb(hex: []const u8) ![3]f64 {
        if (hex.len != 7 or hex[0] != '#') return error.InvalidColor;
        var result: [3]f64 = undefined;
        for (&result, 0..) |*value, i| value.* = @as(f64, @floatFromInt(try std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16))) / 255;
        return result;
    }
    pub fn accent(self: *const Appearance) [3]f64 {
        return rgb(self.palette.primary) catch .{ 0, 0, 0 };
    }
    pub fn foreground(self: *const Appearance) [3]f64 {
        return rgb(self.palette.text) catch .{ 0, 0, 0 };
    }
    fn clear(self: *Appearance) void {
        if (self.subscription) |subscription| subscription.stop();
        self.subscription = null;
        if (c.gdk_display_get_default()) |display| for ([_]?*c.GtkCssProvider{ self.provider, self.native_provider }) |item| if (item) |provider| {
            c.gtk_style_context_remove_provider_for_display(display, u.cast(c.GtkStyleProvider, provider));
            c.g_object_unref(provider);
        };
        self.provider = null;
        self.native_provider = null;
        if (self.gtk_name.len > 0) u.a.free(self.gtk_name);
        if (self.font.len > 0) u.a.free(self.font);
        self.gtk_name = "";
        self.font = "";
        if (self.owns_palette) freePalette(u.a, self.palette);
        self.palette = client.theme.dark;
        self.owns_palette = false;
        self.font_size = 14;
        self.reduced_motion = false;
        self.snapshot_gtk = false;
        self.variant = .dark;
        self.revision = null;
    }
    pub fn deinit(self: *Appearance) void {
        self.clear();
        self.mode = null;
    }
};

fn dupePalette(alloc: std.mem.Allocator, p: client.theme.Palette) client.theme.Palette {
    var result: client.theme.Palette = undefined;
    inline for (@typeInfo(client.theme.Palette).@"struct".field_names) |field| {
        @field(result, field) = alloc.dupe(u8, @field(p, field)) catch unreachable;
    }
    return result;
}
fn freePalette(alloc: std.mem.Allocator, p: client.theme.Palette) void {
    inline for (@typeInfo(client.theme.Palette).@"struct".field_names) |field| alloc.free(@field(p, field));
}

test "committed palette, font and motion render into the coral sheet" {
    const a = std.testing.allocator;
    var self: Appearance = .{ .context = undefined, .changed = undefined };
    self.mode = .follow_pearl;
    self.revision = 7;
    self.palette = .{ .surface = "#101010", .low = "#181818", .container = "#202020", .high = "#282828", .text = "#eeeeee", .secondary = "#cccccc", .primary = "#00ff00", .on_primary = "#003300", .primary_container = "#004400", .on_container = "#ccffcc", .outline = "#777777", .error_color = "#ff0000", .error_container = "#300000" };
    self.font = "Sans";
    self.font_size = 16;
    self.reduced_motion = true;
    const css = try self.sheet(a);
    defer a.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "window.coral.dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "background: #00ff00") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "font-size: 16pt") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "transition-duration: 0ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "$scope") == null);
    self.snapshot_gtk = true;
    const native = try self.sheet(a);
    defer a.free(native);
    try std.testing.expectEqualStrings("", native);
    self.snapshot_gtk = false;
    self.mode = .light;
    const light = try self.sheet(a);
    defer a.free(light);
    try std.testing.expect(std.mem.indexOf(u8, light, "window.coral.light") != null);
    try std.testing.expect(std.mem.indexOf(u8, light, "#6750a4") != null);
    try std.testing.expect(std.mem.indexOf(u8, light, "16pt") == null);
    self.mode = .follow_pearl;
    self.revision = 1;
    self.palette.primary = "bad";
    try std.testing.expectError(error.InvalidPalette, self.sheet(a));
}

test "generated editor scheme follows palette surfaces and keeps syntax hues" {
    const a = std.testing.allocator;
    const xml = try Appearance.schemeXml(a, client.theme.dark, true);
    defer a.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "id=\"coral-pearl-dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "foreground=\"#e6e0e9\" background=\"#141218\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "background=\"#d0bcff55\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "def:string\" foreground=\"#a6d7b5\"") != null);
    const light = try Appearance.schemeXml(a, client.theme.light, false);
    defer a.free(light);
    try std.testing.expect(std.mem.indexOf(u8, light, "id=\"coral-pearl-light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, light, "def:string\" foreground=\"#34704c\"") != null);
}

test "theme classes follow the committed variant and manual modes" {
    var self: Appearance = .{ .context = undefined, .changed = undefined };
    try std.testing.expectEqualStrings("dark", self.themeClass());
    self.mode = .follow_pearl;
    try std.testing.expectEqualStrings("dark", self.themeClass());
    self.revision = 3;
    try std.testing.expectEqualStrings("dark", self.themeClass());
    self.variant = .light;
    try std.testing.expectEqualStrings("light", self.themeClass());
    self.snapshot_gtk = true;
    try std.testing.expectEqualStrings("native", self.themeClass());
    self.mode = .native_gtk;
    try std.testing.expectEqualStrings("native", self.themeClass());
    self.mode = .light;
    try std.testing.expectEqualStrings("light", self.themeClass());
    self.mode = .dark;
    try std.testing.expectEqualStrings("dark", self.themeClass());
    try std.testing.expectEqual(Mode.follow_pearl, modeFrom(3));
    try std.testing.expectEqual(Mode.native_gtk, modeFrom(2));
    try std.testing.expectEqual(Mode.dark, modeFrom(0));
}
