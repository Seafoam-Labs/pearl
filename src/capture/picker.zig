const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gdkwayland = @import("gdkwayland4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const appearance = @import("../ui/appearance_observer.zig");
const input = @import("sources.zig");
const options = @import("build_options");
const a = std.heap.c_allocator;
const State = struct {
    app: *gtk.Application,
    sources: *input.Sources,
    window: ?*gtk.Window = null,
    list: ?*gtk.ListBox = null,
    share: ?*gtk.Button = null,
    css: ?*gtk.CssProvider = null,
    observer: ?*appearance.Observer = null,
    parent: std.os.linux.pid_t,
    timer: c_uint = 0,
    test_timer: c_uint = 0,
    complete: bool = false,
    failure: bool = false,

    fn alive(data: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(data.?));
        var fd: std.c.pollfd = .{ .fd = 1, .events = 0, .revents = 0 };
        _ = std.c.poll(@ptrCast(&fd), 1, 0);
        if (std.os.linux.getppid() != self.parent or fd.revents & (std.c.POLL.ERR | std.c.POLL.HUP) != 0) {
            self.timer = 0;
            self.failure = true;
            self.finish(false);
            return 0;
        }
        return 1;
    }
    fn finish(self: *State, accept: bool) void {
        if (self.complete) return;
        self.complete = true;
        if (accept) {
            const row = self.list.?.getSelectedRow() orelse {
                self.complete = false;
                return;
            };
            const index = row.getIndex();
            if (index < 0 or index >= self.sources.lines.items.len) {
                self.failure = true;
            } else {
                // Only this path writes stdout. The backend drains it while we write.
                const line = self.sources.lines.items[@intCast(index)];
                write(line) catch {
                    self.failure = true;
                };
                if (!self.failure) write("\n") catch {
                    self.failure = true;
                };
            }
        }
        self.window.?.destroy();
    }
    fn write(bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(1, bytes.ptr + offset, bytes.len - offset);
            if (n <= 0) return error.OutputFailed;
            offset += @intCast(n);
        }
    }
    fn choose(_: *gtk.Button, self: *State) callconv(.c) void {
        self.finish(true);
    }
    fn cancel(_: *gtk.Button, self: *State) callconv(.c) void {
        self.finish(false);
    }
    fn closed(_: *gtk.Window, self: *State) callconv(.c) c_int {
        self.finish(false);
        return 1;
    }
    fn selected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *State) callconv(.c) void {
        self.share.?.as(gtk.Widget).setSensitive(@intFromBool(row != null));
    }
    fn key(_: *gtk.EventControllerKey, symbol: c_uint, _: c_uint, _: gdk.ModifierType, self: *State) callconv(.c) c_int {
        if (symbol != 0xff1b) return 0;
        self.finish(false);
        return 1;
    }
    fn changed(context: *anyopaque, s: appearance.Snapshot, _: [3]f64, font: [:0]const u8, css: [:0]const u8) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.complete) return;
        self.css.?.loadFromString(css);
        const widget = self.window.?.as(gtk.Widget);
        if (s.mode == .gtk) widget.removeCssClass("pearl-dark") else widget.addCssClass("pearl-dark");
        gtk.Settings.getDefault().?.as(object.Object).set("gtk-font-name", font.ptr, "gtk-enable-animations", @as(c_int, @intFromBool(!s.reduced_motion)), @as(?*anyopaque, null));
    }
    fn testAction(data: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(data.?));
        self.test_timer = 0;
        if (options.test_hooks) {
            if (glib.getenv("PEARL_CAPTURE_TEST_SELECT")) |text| {
                const index = std.fmt.parseInt(c_int, std.mem.span(text), 10) catch -1;
                if (index >= 0 and index < self.sources.lines.items.len) self.list.?.selectRow(self.list.?.getRowAtIndex(index));
            }
            if (glib.getenv("PEARL_CAPTURE_TEST_ACTION")) |action| {
                if (std.mem.eql(u8, std.mem.span(action), "share")) self.finish(true) else if (std.mem.eql(u8, std.mem.span(action), "cancel")) self.finish(false);
            }
        }
        return 0;
    }
    fn activate(_: *gio.Application, self: *State) callconv(.c) void {
        const window = gtk.ApplicationWindow.new(self.app).as(gtk.Window);
        self.window = window;
        window.setTitle(@import("i18n").dtr("pearl-files", "Share a source"));
        window.setDefaultSize(520, 360);
        const widget = window.as(gtk.Widget);
        widget.addCssClass("pearl-root");
        widget.addCssClass("pearl-dark");
        widget.addCssClass("pearl-capture-picker");
        const outer = gtk.Box.new(.vertical, 16);
        const content = outer.as(gtk.Widget);
        content.setMarginTop(24);
        content.setMarginBottom(24);
        content.setMarginStart(24);
        content.setMarginEnd(24);
        window.setChild(content);
        const title = gtk.Label.new(@import("i18n").dtr("pearl-files", "Share a source"));
        title.setXalign(0);
        title.as(gtk.Widget).addCssClass("capture-title");
        outer.append(title.as(gtk.Widget));
        const subtitle = gtk.Label.new(@import("i18n").dtr("pearl-files", "Choose the source you want to share."));
        subtitle.setXalign(0);
        subtitle.setWrap(1);
        subtitle.as(gtk.Widget).addCssClass("dim-label");
        outer.append(subtitle.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setMinContentHeight(100);
        const list = gtk.ListBox.new();
        self.list = list;
        list.setSelectionMode(.single);
        list.setActivateOnSingleClick(0);
        list.as(gtk.Widget).addCssClass("capture-sources");
        for (self.sources.lines.items) |line| {
            const row = gtk.ListBoxRow.new();
            row.as(gtk.Widget).addCssClass("capture-source");
            const label = gtk.Label.new(line.ptr);
            label.setXalign(0);
            label.setEllipsize(.end);
            label.setMaxWidthChars(60);
            label.as(gtk.Widget).setTooltipText(line.ptr);
            row.setChild(label.as(gtk.Widget));
            list.append(row.as(gtk.Widget));
        }
        list.unselectAll();
        scroll.setChild(list.as(gtk.Widget));
        outer.append(scroll.as(gtk.Widget));
        const buttons = gtk.Box.new(.horizontal, 12);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel_button = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-files", "Cancel"));
        const share = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-files", "Share source"));
        self.share = share;
        share.as(gtk.Widget).addCssClass("suggested-action");
        share.as(gtk.Widget).setSensitive(0);
        buttons.append(cancel_button.as(gtk.Widget));
        buttons.append(share.as(gtk.Widget));
        outer.append(buttons.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(cancel_button, *State, cancel, self, .{});
        _ = gtk.Button.signals.clicked.connect(share, *State, choose, self, .{});
        _ = gtk.ListBox.signals.row_selected.connect(list, *State, selected, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *State, closed, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *State, key, self, .{});
        widget.addController(keys.as(gtk.EventController));
        self.css = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(widget.getDisplay(), self.css.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        self.observer = appearance.Observer.start(self, changed) catch null;
        if (options.test_hooks) if (glib.getenv("PEARL_CAPTURE_TEST_LIGHT") != null) if (self.observer) |observer| {
            observer.apply(.{ .variant = .light, .palette = @import("../theme/theme.zig").light }) catch {};
        };
        if (options.test_hooks) if (glib.getenv("PEARL_CAPTURE_TEST_VIEW")) |view| {
            const mode = std.mem.span(view);
            if (std.mem.eql(u8, mode, "narrow")) window.setDefaultSize(320, 420);
            if (std.mem.eql(u8, mode, "rtl")) {
                gtk.Widget.setDefaultDirection(.rtl);
                if (self.observer) |observer| observer.apply(.{ .font_size = 22, .reduced_motion = true }) catch {};
            }
            if (std.mem.eql(u8, mode, "gtk")) if (self.observer) |observer| {
                observer.apply(.{ .mode = .gtk, .gtk_name = "Adwaita" }) catch {};
            };
        };
        window.setFocus(cancel_button.as(gtk.Widget));
        // The backend supplies context per request, separately from source labels.
        window.as(gtk.Widget).realize();
        if (window.as(gtk.Native).getSurface()) |surface| {
            if (object.ext.cast(gdkwayland.WaylandToplevel, surface)) |toplevel| {
                if (glib.getenv("AQUEOUS_PORTAL_PARENT_WINDOW")) |parent| {
                    const value = std.mem.span(parent);
                    if (value.len > 8 and value.len <= 4096 and std.mem.startsWith(u8, value, "wayland:")) {
                        if (toplevel.setTransientForExported(parent + 8) != 0) window.setModal(1);
                    }
                }
                if (glib.getenv("XDG_ACTIVATION_TOKEN")) |token| {
                    if (std.mem.span(token).len <= 4096) toplevel.as(gdk.Toplevel).setStartupId(token);
                }
            }
        }
        window.present();
        _ = cancel_button.as(gtk.Widget).grabFocus();
        list.unselectAll();
        self.timer = glib.timeoutAdd(100, alive, self);
        if (options.test_hooks) self.test_timer = glib.timeoutAdd(300, testAction, self);
    }
};
pub fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--identity")) {
            if (options.test_hooks) return error.TestBuildNotInstallable;
            try State.write(if (options.git_variant) "org.aqueous.Pearl.Git.CapturePicker\n" else "org.aqueous.Pearl.CapturePicker\n");
            return;
        }
        return error.UnknownArgument;
    }
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.stdin().readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (n > input.limit - buffer.items.len) return error.SourceListTooLarge;
        try buffer.appendSlice(a, chunk[0..n]);
    }
    var sources = try input.Sources.parse(a, buffer.items);
    defer sources.deinit();
    if (sources.lines.items.len == 0) return;
    gdk.setAllowedBackends("wayland");
    if (gtk.initCheck() == 0) return error.WaylandUnavailable;
    gtk.Widget.setDefaultDirection(if (@import("i18n").rtl()) .rtl else .ltr);
    const app = gtk.Application.new(if (options.git_variant) "org.aqueous.Pearl.Git.CapturePicker" else "org.aqueous.Pearl.CapturePicker", .{ .non_unique = true });
    defer app.unref();
    var self: State = .{ .app = app, .sources = &sources, .parent = std.os.linux.getppid() };
    defer {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        if (self.test_timer != 0) _ = glib.Source.remove(self.test_timer);
        if (self.observer) |observer| observer.stop();
        if (self.css) |css| {
            gtk.StyleContext.removeProviderForDisplay(gdk.Display.getDefault().?, css.as(gtk.StyleProvider));
            css.unref();
        }
    }
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), *State, State.activate, &self, .{});
    if (app.as(gio.Application).run(0, null) != 0 or self.failure) return error.PickerFailed;
}
