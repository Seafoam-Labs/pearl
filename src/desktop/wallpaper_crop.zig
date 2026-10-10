//! Crop editor: place a display-shaped frame over one wallpaper image.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const object = @import("gobject2");
const cairo = @import("cairo1");
const pixbuf = @import("gdkpixbuf2");
const layer = @import("gtk4layershell1");
const native = @import("../platform/wayland/effects.zig");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const crop = @import("../config/crop_policy.zig");
const Service = @import("../config/service.zig").Service;
const a = std.heap.c_allocator;

/// One scroll notch moves the zoom by this factor.
const zoom_step: f32 = 1.15;

/// A surface asking the manager to open the editor for one image.
pub const Request = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, []const u8) void,
};

/// The manager's handle on the one editor it owns.
pub const Owner = struct {
    context: *anyopaque,
    closed: *const fn (*anyopaque) void,
};

const Box = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Window = struct {
    service: *Service,
    dialog: *gtk.Dialog,
    canvas: *gtk.DrawingArea,
    status: *gtk.Label,
    /// The content box; it carries the shell panel surface and the blur target.
    panel: *gtk.Widget,
    image: *pixbuf.Pixbuf,
    texture: *gdk.Texture,
    path: [:0]u8,
    image_width: u32,
    image_height: u32,
    frame: crop.Frame,
    /// Share of the display-shaped frame currently shown, 1 being the whole frame.
    zoom: f32 = 1,
    /// Crop origin as a fraction of the image.
    left: f32 = 0,
    top: f32 = 0,
    grab_x: f32 = 0,
    grab_y: f32 = 0,
    parent: *gtk.Window,
    parent_keyboard: layer.KeyboardMode,
    owner: ?Owner,
    /// Same blur/transparency registration the shell's popups use.
    effects: native.Surface = undefined,
    effects_ready: bool = false,

    /// `display_width` and `display_height` are the output the crop will fill.
    pub fn open(parent: *gtk.Window, service: *Service, effects: *native.Effects, path: []const u8, display_width: i32, display_height: i32, owner: ?Owner) !*Window {
        if (display_width < 1 or display_height < 1) return error.InvalidOutput;
        const owned = try a.dupeZ(u8, path);
        errdefer a.free(owned);
        const image = try load(service, owned);
        errdefer image.unref();
        const wide: u32 = @intCast(@max(0, image.getWidth()));
        const tall: u32 = @intCast(@max(0, image.getHeight()));
        const aspect: f64 = @as(f64, @floatFromInt(display_width)) / @as(f64, @floatFromInt(display_height));
        const framed = crop.frame(wide, tall, aspect) orelse return error.InvalidImage;
        const texture = gdk.Texture.newForPixbuf(image);
        errdefer texture.unref();
        const self = try a.create(Window);
        self.* = .{
            .service = service,
            .dialog = undefined,
            .canvas = undefined,
            .status = undefined,
            .panel = undefined,
            .image = image,
            .texture = texture,
            .path = owned,
            .image_width = wide,
            .image_height = tall,
            .frame = framed,
            .parent = parent,
            .parent_keyboard = layer.getKeyboardMode(parent),
            .owner = owner,
        };
        self.place(crop.find(service.prefs().wallpaper.crops, owned));
        self.build();
        // Registered after the window and its panel exist, because the broker
        // hooks their map and unmap signals.
        self.effects.init(effects, self.dialog.as(gtk.Window), self.panel, true, .full) catch {
            self.destroy();
            return error.EffectsUnavailable;
        };
        self.effects_ready = true;
        return self;
    }

    /// Reuses the decoded wallpaper when the editor opens for the image already
    /// on screen. The live job keeps the uncropped pixbuf, so an existing
    /// placement can be revised from the original.
    fn load(service: *Service, path: [:0]const u8) !*pixbuf.Pixbuf {
        if (service.live) |live| {
            if (live.image) |reused| {
                if (std.mem.eql(u8, live.prefs.wallpaper.path, path)) {
                    _ = reused.ref();
                    return reused;
                }
            }
        }
        return pixbuf.Pixbuf.newFromFile(path.ptr, null) orelse error.InvalidImage;
    }

    /// Starts from a saved placement, or centres the widest frame the display's
    /// aspect ratio allows.
    fn place(self: *Window, saved: ?crop.Crop) void {
        self.zoom = if (saved) |c| @min(1, @max(crop.min_zoom, c.width / self.frame.width)) else 1;
        self.left = if (saved) |c| c.x else (1 - self.frame.width * self.zoom) / 2;
        self.top = if (saved) |c| c.y else (1 - self.frame.height * self.zoom) / 2;
        self.clamp();
    }
    fn clamp(self: *Window) void {
        self.left = @min(@max(self.left, 0), @max(0, 1 - self.frame.width * self.zoom));
        self.top = @min(@max(self.top, 0), @max(0, 1 - self.frame.height * self.zoom));
    }

    /// Where the whole image lands when the picture contains it in the canvas.
    /// GtkPicture's `.contain` and this arithmetic agree, which is what lets the
    /// frame be drawn over the picture without GTK reporting where it went.
    fn fit(self: *const Window, width: f64, height: f64) Box {
        const scale = @min(width / @as(f64, self.image_width), height / @as(f64, self.image_height));
        const drawn_w = @as(f64, self.image_width) * scale;
        const drawn_h = @as(f64, self.image_height) * scale;
        return .{ .x = (width - drawn_w) / 2, .y = (height - drawn_h) / 2, .width = drawn_w, .height = drawn_h };
    }
    fn rect(self: *const Window, box: Box) Box {
        return .{
            .x = box.x + @as(f64, self.left) * box.width,
            .y = box.y + @as(f64, self.top) * box.height,
            .width = @as(f64, self.frame.width * self.zoom) * box.width,
            .height = @as(f64, self.frame.height * self.zoom) * box.height,
        };
    }

    fn build(self: *Window) void {
        const dialog = gtk.Dialog.new();
        self.dialog = dialog;
        const window = dialog.as(gtk.Window);
        // gtk_dialog_new hands back a floating reference; sinking it makes the
        // editor own the window outright, so destroy releases exactly one.
        _ = window.as(object.Object).refSink();
        // A regular native window would sit below Pearl's overlay and lose
        // keyboard input to it, so the editor uses layer-shell like the
        // settings wallpaper chooser does.
        window.as(gtk.Widget).addCssClass("pearl-root");
        window.as(gtk.Widget).addCssClass("pearl-shell");
        window.setTitle(tr("Crop wallpaper", "Hintergrundbild zuschneiden"));
        window.setTransientFor(self.parent);
        window.setModal(1);
        window.setDefaultSize(820, 600);
        layer.initForWindow(window);
        layer.setNamespace(window, "pearl:wallpaper-crop");
        layer.setMonitor(window, layer.getMonitor(self.parent));
        layer.setLayer(window, .overlay);
        layer.setKeyboardMode(self.parent, .none);
        layer.setKeyboardMode(window, .exclusive);

        const content = dialog.getContentArea();
        // The content box is this dialog's panel: it carries the same surface
        // and blur target the shell's popups put on their panel box, so the
        // editor gets the shell's usual translucent background.
        self.panel = content.as(gtk.Widget);
        self.panel.addCssClass("pearl-surface-panel");
        self.panel.addCssClass("pearl-popup-panel");
        self.service.style(window.as(gtk.Widget), self.panel);
        var buffer: [1025:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&buffer, "{s}", .{std.fs.path.basename(self.path)}) catch "wallpaper";
        content.append(w.label(title, "pearl-card-title").as(gtk.Widget));
        content.append(w.label(tr("Drag to place, scroll to zoom. The frame is this display's shape.", "Ziehen zum Platzieren, scrollen zum Zoomen. Der Rahmen hat die Form dieses Bildschirms."), "pearl-secondary").as(gtk.Widget));

        const picture = gtk.Picture.newForPaintable(self.texture.as(gdk.Paintable));
        picture.setCanShrink(1);
        picture.setContentFit(.contain);
        picture.as(gtk.Widget).setHalign(.fill);
        picture.as(gtk.Widget).setValign(.fill);
        const stack = gtk.Overlay.new();
        stack.setChild(picture.as(gtk.Widget));
        const canvas = gtk.DrawingArea.new();
        self.canvas = canvas;
        canvas.setDrawFunc(draw, self, null);
        const drag = gtk.GestureDrag.new();
        _ = gtk.GestureDrag.signals.drag_begin.connect(drag, *Window, dragBegin, self, .{});
        _ = gtk.GestureDrag.signals.drag_update.connect(drag, *Window, dragUpdate, self, .{});
        canvas.as(gtk.Widget).addController(drag.as(gtk.EventController));
        const wheel = gtk.EventControllerScroll.new(gtk.EventControllerScrollFlags.flags_vertical);
        _ = gtk.EventControllerScroll.signals.scroll.connect(wheel, *Window, scrolled, self, .{});
        canvas.as(gtk.Widget).addController(wheel.as(gtk.EventController));
        stack.addOverlay(canvas.as(gtk.Widget));

        // The picture's natural size is the image's, which would size the dialog
        // to the wallpaper. This viewport reports no natural size of its own, so
        // the window's default size decides and the canvas fills it.
        const viewport = gtk.ScrolledWindow.new();
        viewport.setPolicy(.never, .never);
        viewport.setOverlayScrolling(0);
        viewport.setPropagateNaturalWidth(0);
        viewport.setPropagateNaturalHeight(0);
        viewport.as(gtk.Widget).setSizeRequest(320, 240);
        viewport.as(gtk.Widget).setVexpand(1);
        viewport.as(gtk.Widget).setHexpand(1);
        viewport.setChild(stack.as(gtk.Widget));
        content.append(viewport.as(gtk.Widget));

        self.status = w.label("", "pearl-secondary");
        content.append(self.status.as(gtk.Widget));

        // An own footer instead of the dialog's action area: the action area
        // sits outside the content box, so it cannot carry the panel padding
        // or the shell's button styling.
        const footer = w.row(12);
        footer.as(gtk.Widget).setHalign(.end);
        const reset = w.wrappingButton(tr("Reset", "Zurücksetzen"));
        const cancel = w.wrappingButton(tr("Cancel", "Abbrechen"));
        const apply = w.wrappingButton(tr("Apply crop", "Zuschnitt übernehmen"));
        apply.as(gtk.Widget).addCssClass("pearl-primary");
        footer.append(reset.as(gtk.Widget));
        footer.append(cancel.as(gtk.Widget));
        footer.append(apply.as(gtk.Widget));
        content.append(footer.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(reset, *Window, resetClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel, *Window, cancelled, self, .{});
        _ = gtk.Button.signals.clicked.connect(apply, *Window, applied, self, .{});
        // Escape and compositor close arrive as a response, not a button click.
        _ = gtk.Dialog.signals.response.connect(dialog, *Window, closed, self, .{});
        window.present();
    }

    fn resetClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.place(null);
        self.canvas.as(gtk.Widget).queueDraw();
    }
    fn cancelled(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.destroy();
    }
    fn applied(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (self.commit()) self.destroy();
    }
    fn closed(_: *gtk.Dialog, response: c_int, self: *Window) callconv(.c) void {
        if (response == @intFromEnum(gtk.ResponseType.delete_event)) self.destroy();
    }

    fn draw(_: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const wide: f64 = @floatFromInt(width);
        const tall: f64 = @floatFromInt(height);
        const chosen = self.rect(self.fit(wide, tall));
        // What falls outside the frame stays visible but dimmed, so the part
        // being cropped away is still recognisable while placing it.
        cr.setSourceRgba(0, 0, 0, 0.55);
        cr.rectangle(0, 0, wide, chosen.y);
        cr.rectangle(0, chosen.y + chosen.height, wide, tall - (chosen.y + chosen.height));
        cr.rectangle(0, chosen.y, chosen.x, chosen.height);
        cr.rectangle(chosen.x + chosen.width, chosen.y, wide - (chosen.x + chosen.width), chosen.height);
        cr.fill();
        cr.setLineWidth(1);
        cr.setSourceRgba(1, 1, 1, 0.25);
        for ([_]f64{ 1.0 / 3.0, 2.0 / 3.0 }) |third| {
            cr.moveTo(chosen.x + chosen.width * third, chosen.y);
            cr.lineTo(chosen.x + chosen.width * third, chosen.y + chosen.height);
            cr.moveTo(chosen.x, chosen.y + chosen.height * third);
            cr.lineTo(chosen.x + chosen.width, chosen.y + chosen.height * third);
        }
        cr.stroke();
        cr.setLineWidth(2);
        cr.setSourceRgba(1, 1, 1, 0.9);
        cr.rectangle(chosen.x, chosen.y, chosen.width, chosen.height);
        cr.stroke();
    }

    fn dragBegin(_: *gtk.GestureDrag, _: f64, _: f64, self: *Window) callconv(.c) void {
        self.grab_x = self.left;
        self.grab_y = self.top;
    }
    fn dragUpdate(_: *gtk.GestureDrag, offset_x: f64, offset_y: f64, self: *Window) callconv(.c) void {
        const widget = self.canvas.as(gtk.Widget);
        const box = self.fit(@floatFromInt(widget.getWidth()), @floatFromInt(widget.getHeight()));
        if (box.width <= 0 or box.height <= 0) return;
        self.left = self.grab_x + @as(f32, @floatCast(offset_x / box.width));
        self.top = self.grab_y + @as(f32, @floatCast(offset_y / box.height));
        self.clamp();
        widget.queueDraw();
    }
    fn scrolled(_: *gtk.EventControllerScroll, _: f64, delta_y: f64, self: *Window) callconv(.c) c_int {
        if (delta_y == 0) return 0;
        // Zooming keeps the centre of the frame where it is, so the subject
        // being framed does not slide away while scrolling.
        const centre_x = self.left + self.frame.width * self.zoom / 2;
        const centre_y = self.top + self.frame.height * self.zoom / 2;
        self.zoom = @min(1, @max(crop.min_zoom, self.zoom * if (delta_y < 0) zoom_step else 1 / zoom_step));
        self.left = centre_x - self.frame.width * self.zoom / 2;
        self.top = centre_y - self.frame.height * self.zoom / 2;
        self.clamp();
        self.canvas.as(gtk.Widget).queueDraw();
        return 1;
    }

    /// Committing through the preferences service keeps the wallpaper watch,
    /// dynamic colors and every output surface consistent with the edit.
    fn commit(self: *Window) bool {
        const rejected = tr("Could not save the crop. Try again.", "Zuschnitt konnte nicht gespeichert werden. Bitte erneut versuchen.");
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const entry = crop.Crop{
            .path = self.path,
            .x = self.left,
            .y = self.top,
            .width = self.frame.width * self.zoom,
            .height = self.frame.height * self.zoom,
        };
        var prefs = self.service.prefs();
        var saved: std.ArrayList(crop.Crop) = .empty;
        for (prefs.wallpaper.crops) |existing| {
            if (std.mem.eql(u8, existing.path, self.path)) continue;
            saved.append(alloc, existing) catch return self.fail(rejected);
        }
        // A frame covering the whole image is the default, so it is dropped
        // rather than stored; one placement per image keeps the list bounded.
        const whole = entry.width > 1 - 0.001 and entry.height > 1 - 0.001;
        if (!whole) {
            if (saved.items.len >= crop.max) return self.fail(tr("Too many saved crops. Reset one of the others first.", "Zu viele gespeicherte Zuschnitte. Setze zuerst einen anderen zurück."));
            saved.append(alloc, entry) catch return self.fail(rejected);
        }
        prefs.wallpaper.crops = saved.items;
        prefs.validate() catch return self.fail(rejected);
        const json = std.json.Stringify.valueAlloc(alloc, prefs, .{}) catch return self.fail(rejected);
        self.service.apply(json, self.service.revision) catch return self.fail(tr("Could not apply the crop. Try again.", "Zuschnitt konnte nicht angewendet werden. Bitte erneut versuchen."));
        return true;
    }
    fn fail(self: *Window, text: [:0]const u8) bool {
        self.status.setText(text);
        return false;
    }

    /// True when the editor is transient for `window`. A surface that is going
    /// away has to close the editor first: restoring the keyboard mode on a
    /// destroyed parent would be a use after free.
    pub fn parentIs(self: *const Window, window: *gtk.Window) bool {
        return self.parent == window;
    }

    pub fn destroy(self: *Window) void {
        if (self.effects_ready) self.effects.deinit();
        layer.setKeyboardMode(self.parent, self.parent_keyboard);
        const window = self.dialog.as(gtk.Window);
        window.destroy();
        window.unref();
        self.texture.unref();
        self.image.unref();
        a.free(self.path);
        const owner = self.owner;
        a.destroy(self);
        if (owner) |o| o.closed(o.context);
    }
};
