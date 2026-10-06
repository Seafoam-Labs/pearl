//! Ordinary isolated GTK author preview. No preferences or app destinations.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Preview = struct {
    app: *gtk.Application,
    path: [:0]const u8,
    watch: bool,
    light: bool,
    provider: *gtk.CssProvider,
    status: ?*gtk.Label = null,
    monitor: ?*gio.FileMonitor = null,
    timer: c_uint = 0,
    fn refresh(self: *Preview) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var d: @import("palette_model.zig").Diagnostic = .{};
        const file = @import("palette_file.zig").inspect(alloc, self.path, null, &d) catch |err| {
            self.status.?.setText(std.fmt.allocPrintSentinel(alloc, "{s}: {s} ({s}). Keeping the last valid preview.", .{ d.path, d.code, @errorName(err) }, 0) catch return);
            return;
        };
        const palette = if (self.light) file.document.light else file.document.dark;
        const template = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ @embedFile("settings_base_style"), @import("palette_resolver.zig").shellCss(alloc, file.document, self.light) catch return }) catch return;
        self.provider.loadFromString(@import("theme.zig").scopedCss(alloc, template, "pearl-author-preview", palette) catch return);
        self.status.?.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}{s} · Preview only", .{ file.name, if (self.light) "Light" else "Dark", if (self.watch) " · watching saved edits" else "" }, 0) catch return);
    }
    fn toggled(_: *gtk.Button, self: *Preview) callconv(.c) void {
        self.light = !self.light;
        self.refresh();
    }
    fn elapsed(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Preview = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.refresh();
        return 0;
    }
    fn changed(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, _: gio.FileMonitorEvent, self: *Preview) callconv(.c) void {
        const basename = file.getBasename();
        defer if (basename) |name| glib.free(name);
        const next = if (other) |f| f.getBasename() else null;
        defer if (next) |name| glib.free(name);
        const target = std.fs.path.basename(self.path);
        if ((basename != null and std.mem.eql(u8, std.mem.span(basename.?), target)) or (next != null and std.mem.eql(u8, std.mem.span(next.?), target))) {
            if (self.timer != 0) _ = glib.Source.remove(self.timer);
            self.timer = glib.timeoutAdd(200, elapsed, self);
        }
    }
    fn activate(_: *gio.Application, self: *Preview) callconv(.c) void {
        const window = gtk.ApplicationWindow.new(self.app);
        window.as(gtk.Window).setTitle("Pearl palette preview");
        window.as(gtk.Window).setDefaultSize(520, 420);
        const root = w.column(16);
        root.as(gtk.Widget).addCssClass("pearl-root");
        root.as(gtk.Widget).addCssClass("pearl-author-preview");
        {
            const widget = root.as(gtk.Widget);
            widget.setMarginTop(20);
            widget.setMarginBottom(20);
            widget.setMarginStart(20);
            widget.setMarginEnd(20);
        }
        self.status = w.label("", "pearl-secondary");
        root.append(self.status.?.as(gtk.Widget));
        const toggle = w.wrappingButton("Switch dark / light");
        root.append(toggle.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(toggle, *Preview, toggled, self, .{});
        const card = w.card();
        card.append(w.label("Palette sample", "pearl-card-title").as(gtk.Widget));
        card.append(w.label("Body text and secondary text", "pearl-secondary").as(gtk.Widget));
        const accent = w.wrappingButton("Accent button");
        accent.as(gtk.Widget).addCssClass("pearl-primary");
        card.append(accent.as(gtk.Widget));
        const disabled = w.wrappingButton("Disabled button");
        disabled.as(gtk.Widget).setSensitive(0);
        card.append(disabled.as(gtk.Widget));
        const input = gtk.Entry.new();
        input.setPlaceholderText("Focus this entry");
        card.append(input.as(gtk.Widget));
        card.append(w.label("Example error message", "pearl-error").as(gtk.Widget));
        root.append(card.as(gtk.Widget));
        window.as(gtk.Window).setChild(root.as(gtk.Widget));
        gtk.StyleContext.addProviderForDisplay(gdk.Display.getDefault().?, self.provider.as(gtk.StyleProvider), 602);
        self.refresh();
        if (self.watch) {
            const dirname = a.dupeZ(u8, std.fs.path.dirname(self.path) orelse ".") catch return;
            defer a.free(dirname);
            const dir = gio.File.newForPath(dirname);
            defer dir.unref();
            self.monitor = dir.monitorDirectory(.{ .watch_moves = true }, null, null);
            if (self.monitor) |monitor| {
                _ = gio.FileMonitor.signals.changed.connect(monitor, *Preview, changed, self, .{});
            } else self.status.?.setText("Watch unavailable; reopen the preview after saving.");
        }
        window.as(gtk.Window).present();
    }
};
pub fn run(path: [:0]const u8, watch: bool, light: bool) !void {
    if (gtk.initCheck() == 0) return error.DisplayUnavailable;
    const app = gtk.Application.new("org.aqueous.Pearl.PalettePreview", .{ .non_unique = true });
    defer app.unref();
    var preview: Preview = .{ .app = app, .path = path, .watch = watch, .light = light, .provider = gtk.CssProvider.new() };
    defer preview.provider.unref();
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), *Preview, Preview.activate, &preview, .{});
    _ = app.as(gio.Application).run(0, null);
    if (preview.timer != 0) _ = glib.Source.remove(preview.timer);
    if (preview.monitor) |monitor| {
        _ = monitor.cancel();
        monitor.unref();
    }
    gtk.StyleContext.removeProviderForDisplay(gdk.Display.getDefault().?, preview.provider.as(gtk.StyleProvider));
}
