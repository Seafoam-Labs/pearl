//! Typed observer for the verified, committed appearance shared by external Pearl UI.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const gdk = @import("gdk4");
const Client = @import("../settings/client.zig").Client;
const Identity = @import("../settings/identity.zig").Identity;
pub const Snapshot = @import("../settings/appearance.zig").Snapshot;
const a = std.heap.c_allocator;
pub const Observer = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, Snapshot, [3]f64, [:0]const u8, [:0]const u8) void,
    native_css: ?*gtk.CssProvider = null,
    client: Client,
    identity: ?Identity = null,
    display: [:0]u8,
    retry: c_uint = 0,
    fn native(context: *anyopaque) void {
        const self: *Observer = @ptrCast(@alignCast(context));
        self.client.nativeChanged(self.identity.?.session);
    }
    fn event(context: *anyopaque, value: @import("../settings/client.zig").Event) void {
        const self: *Observer = @ptrCast(@alignCast(context));
        switch (value) {
            .connected => |snapshot| if (snapshot) |s| self.apply(s) catch {},
            .failed => if (self.retry == 0) {
                self.retry = glib.timeoutAdd(3000, retryTick, self);
            },
            else => {},
        }
    }
    fn retryTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Observer = @ptrCast(@alignCast(data.?));
        self.retry = 0;
        self.client.begin();
        return 0;
    }

    fn env(name: [:0]const u8) [:0]const u8 {
        return if (glib.getenv(name)) |v| std.mem.span(v) else "";
    }
    pub fn apply(self: *Observer, s: Snapshot) !void {
        if (self.native_css == null) {
            self.native_css = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, self.native_css.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION - 2);
        }
        if (s.mode == .gtk and s.gtk_name.len > 0) {
            const name = try a.dupeZ(u8, s.gtk_name);
            defer a.free(name);
            self.native_css.?.loadNamed(name, if (s.variant == .dark) "dark" else null);
        } else self.native_css.?.loadFromString("");
        var rgb: [3]f64 = undefined;
        for (&rgb, 0..) |*v, i| v.* = @as(f64, @floatFromInt(try std.fmt.parseInt(u8, s.palette.primary[1 + i * 2 ..][0..2], 16))) / 255;
        const font = try std.fmt.allocPrintSentinel(a, "{s} {d}", .{ if (s.font.len > 0) s.font else "Sans", s.font_size }, 0);
        defer a.free(font);
        const base = try @import("../theme/theme.zig").scopedCss(a, @embedFile("portal_style"), "pearl-dark", s.palette);
        defer a.free(base);
        const tokens = try @import("../theme/style.zig").tokenCss(a, s.style_tokens, s.reduced_motion);
        defer a.free(tokens);
        const resolved = try @import("../theme/theme.zig").scopedCss(a, tokens, "pearl-dark", s.palette);
        defer a.free(resolved);
        const custom = try @import("../theme/theme.zig").scopedCss(a, s.style_css, "pearl-dark", s.palette);
        defer a.free(custom);
        const css = try std.fmt.allocPrintSentinel(a, "{s}\n{s}\n{s}", .{ base, resolved, custom }, 0);
        defer a.free(css);
        self.changed(self.context, s, rgb, font, css);
    }
    pub fn start(context: *anyopaque, changed: @FieldType(Observer, "changed")) !*Observer {
        const display = try @import("../cli/protocol.zig").displayPath(a, env("XDG_RUNTIME_DIR"), env("WAYLAND_DISPLAY"));
        errdefer a.free(display);
        const self = try a.create(Observer);
        self.* = .{ .context = context, .changed = changed, .display = display, .client = .{ .context = self, .notify = Observer.event, .runtime = env("XDG_RUNTIME_DIR"), .display = display, .aqueous_path = env("AQUEOUS_SOCKET") } };
        self.client.init();
        self.apply(.{}) catch {};
        self.identity = Identity.init(gdk.Display.getDefault().?, self, Observer.native) catch null;
        if (self.identity) |*identity| identity.start();
        self.client.begin();
        return self;
    }
    pub fn stop(self: *Observer) void {
        if (self.retry != 0) _ = glib.Source.remove(self.retry);
        if (self.identity) |*identity| identity.deinit();
        self.client.deinit();
        if (self.native_css) |provider| {
            if (gdk.Display.getDefault()) |display| gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
            provider.unref();
        }
        a.free(self.display);
        a.destroy(self);
    }
};
