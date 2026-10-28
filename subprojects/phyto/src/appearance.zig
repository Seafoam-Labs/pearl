//! Follows Pearl's committed appearance; manual modes keep Phyto's own palette.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gdk = @import("gdk4");
const client = @import("appearance_client");
const log = std.log.scoped(.config);
pub const Mode = @import("platform/preferences.zig").Theme;

pub const Appearance = struct {
    mode: ?Mode = null,
    subscription: ?*client.Subscription = null,
    provider: ?*gtk.CssProvider = null,
    native_provider: ?*gtk.CssProvider = null,
    gtk_name: [:0]const u8 = "",
    font: []const u8 = "",
    font_size: u8 = 14,
    reduced_motion: bool = false,
    snapshot_gtk: bool = false,
    variant: enum { dark, light } = .dark,
    palette: client.theme.Palette = client.theme.dark,
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
        if (self.gtk_name.len > 0) u.a.free(self.gtk_name);
        if (self.font.len > 0) u.a.free(self.font);
        self.gtk_name = name;
        self.font = font;
        self.font_size = snapshot.font_size;
        self.reduced_motion = snapshot.reduced_motion;
        self.snapshot_gtk = snapshot.mode == .gtk;
        self.variant = if (snapshot.variant == .light) .light else .dark;
        self.palette = snapshot.palette;
        self.revision = snapshot.revision;
        self.paint();
        self.changed(self.context);
    }
    fn followsGtk(self: *const Appearance) bool {
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
        const motion: []const u8 = if (self.reduced_motion) try std.fmt.allocPrint(a, ".phyto-root.{s} * {{ transition-duration: 0ms; animation-duration: 0ms; }}", .{scope}) else "";
        defer if (self.reduced_motion) a.free(motion);
        return std.fmt.allocPrintSentinel(a, "{s}\n.phyto-root.{s} {{ font-family: {s}; font-size: {d}pt; }}\n{s}", .{ base, scope, font, self.font_size, motion }, 0);
    }
    fn paint(self: *Appearance) void {
        const display = gdk.Display.getDefault() orelse return;
        if (self.provider == null) {
            self.provider = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(display, self.provider.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            self.native_provider = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(display, self.native_provider.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION - 2);
        }
        const css = self.sheet(u.a) catch |err| {
            log.warn("event=appearance-render-failed error={s}", .{@errorName(err)});
            return;
        };
        defer u.a.free(css);
        self.provider.?.loadFromString(css);
        if (self.followsGtk() and self.gtk_name.len > 0) self.native_provider.?.loadNamed(self.gtk_name, if (self.variant == .dark) "dark" else null) else self.native_provider.?.loadFromString("");
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
        if (gdk.Display.getDefault()) |display| for ([_]?*gtk.CssProvider{ self.provider, self.native_provider }) |item| if (item) |provider| {
            gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
            provider.unref();
        };
        self.provider = null;
        self.native_provider = null;
        if (self.gtk_name.len > 0) u.a.free(self.gtk_name);
        if (self.font.len > 0) u.a.free(self.font);
        self.gtk_name = "";
        self.font = "";
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

var instance: ?Appearance = null;
pub fn init(context: *anyopaque, changed: *const fn (*anyopaque) void) void {
    instance = .{ .context = context, .changed = changed };
}
pub fn current() *Appearance {
    return &instance.?;
}
pub fn themeClass() [:0]const u8 {
    return if (instance) |*self| self.themeClass() else "dark";
}
pub fn modeTag() []const u8 {
    return if (instance) |*self| @tagName(self.mode orelse .follow_pearl) else "follow_pearl";
}
pub fn subscribed() bool {
    return if (instance) |*self| self.subscription != null else false;
}
pub fn revision() ?u64 {
    return if (instance) |*self| self.revision else null;
}
pub fn isNative() bool {
    return std.mem.eql(u8, themeClass(), "native");
}
pub fn accent() [3]f64 {
    return if (instance) |*self| self.accent() else .{ 0, 0, 0 };
}
pub fn foreground() [3]f64 {
    return if (instance) |*self| self.foreground() else .{ 0, 0, 0 };
}

test "committed palette, font and motion render into the phyto sheet" {
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
    try std.testing.expect(std.mem.indexOf(u8, css, ".phyto-root.dark") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, light, ".phyto-root.light") != null);
    try std.testing.expect(std.mem.indexOf(u8, light, "#6750a4") != null);
    try std.testing.expect(std.mem.indexOf(u8, light, "font-size:") == null or std.mem.indexOf(u8, light, "16pt") == null);
    self.mode = .follow_pearl;
    self.revision = 1;
    self.palette.primary = "bad";
    try std.testing.expectError(error.InvalidPalette, self.sheet(a));
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
}
