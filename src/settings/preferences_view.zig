//! Appearance and Advanced presentation for the normal application host.
//! Form extraction preserves every other Pearl preference; only Editor retains
//! drafts. Wallpaper preview/chooser never changes committed appearance.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const model = @import("../config/preferences.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    editor: *Editor,
    window: *gtk.Window,
    host: *gtk.Box,
    raw_view: *gtk.TextView,
    raw: *gtk.TextBuffer,
    raw_insert_signal: c_ulong = 0,
    raw_changed_signal: c_ulong = 0,
    arena: std.heap.ArenaAllocator,
    prefs: model.Preferences = .{},
    shown: ?[:0]u8 = null,
    filling: bool = false,
    editing_form: bool = false,
    raw_invalid: bool = false,
    mode: *gtk.DropDown,
    variant: *gtk.DropDown,
    source: *gtk.DropDown,
    fit: *gtk.DropDown,
    density: *gtk.DropDown,
    entries: [5]*gtk.Entry,
    font_size: *gtk.SpinButton,
    motion: *gtk.Switch,
    picture: *gtk.Picture,
    preview_note: *gtk.Label,
    preview_css: *gtk.CssProvider,
    preview_key: ?[]u8 = null,
    preview_idle: c_uint = 0,
    preview: ?*Preview = null,
    preview_ready: bool = false,
    choose: *gtk.Button,
    picker: ?*gtk.FileChooserDialog = null,
    message: *gtk.Label,
    mode_hint: *gtk.Label,
    german: bool,

    pub fn create(window: *gtk.Window, host: *gtk.Box, editor: *Editor, german: bool) !*View {
        const self = try a.create(View);
        const appearance = card(host);
        const mode = dropdown(appearance, if (german) "Design" else "Theme", &.{ "Material · static", "Material · dynamic", "GTK theme" });
        const variant = dropdown(appearance, if (german) "Farbvariante" else "Color variant", &.{ "Dark", "Light" });
        const source = dropdown(appearance, if (german) "Dynamische Farben aus" else "Dynamic colors from", &.{ "Seed color", "Wallpaper" });
        const gtk_name = entry(appearance, if (german) "GTK-Designname" else "GTK theme name", 96);
        gtk_name.setPlaceholderText(if (german) "Systemvorgabe" else "System default");
        const seed = entry(appearance, if (german) "Ausgangsfarbe" else "Seed color", 7);
        seed.setPlaceholderText("#6750a4");
        const hint = w.label(if (german) "Dynamische Farben benötigen matugen 4.x. Ein leerer GTK-Name folgt dem System." else "Dynamic colors need matugen 4.x. An empty GTK theme name follows the system.", "pearl-secondary");
        appearance.append(hint.as(gtk.Widget));
        const wallpaper = card(host);
        const picture = gtk.Picture.new();
        picture.setCanShrink(1);
        picture.setContentFit(.cover);
        picture.as(gtk.Widget).setSizeRequest(-1, 100);
        picture.as(gtk.Widget).addCssClass("settings-draft-preview");
        w.name(picture.as(gtk.Widget), if (german) "Hintergrundvorschau" else "Wallpaper draft preview");
        wallpaper.append(picture.as(gtk.Widget));
        const preview_note = w.label("", "pearl-secondary");
        wallpaper.append(preview_note.as(gtk.Widget));
        const path = entry(wallpaper, if (german) "Hintergrundbild" else "Wallpaper image", 1024);
        path.setPlaceholderText(if (german) "Kein Bild ausgewählt" else "No image selected");
        const choose = w.wrappingButton(if (german) "Bild auswählen…" else "Choose image…");
        choose.as(gtk.Widget).setHalign(.end);
        choose.as(gtk.Widget).setMarginEnd(20);
        choose.as(gtk.Widget).setMarginBottom(12);
        wallpaper.append(choose.as(gtk.Widget));
        const fit = dropdown(wallpaper, if (german) "Hintergrundmodus" else "Wallpaper fit", &.{ "Material gradient", "Solid color", "Cover", "Contain" });
        const color = entry(wallpaper, if (german) "Hintergrundfarbe" else "Background color", 7);
        const typography = card(host);
        const font = entry(typography, if (german) "Schriftfamilie" else "Font family", 96);
        font.setPlaceholderText(if (german) "Systemvorgabe" else "System default");
        const font_size = gtk.SpinButton.newWithRange(10, 24, 1);
        row(typography, if (german) "Schriftgröße" else "Font size", font_size.as(gtk.Widget));
        const density = dropdown(typography, if (german) "Abstände" else "Density", &.{ "Comfortable", "Compact" });
        const motion = gtk.Switch.new();
        row(typography, if (german) "Bewegungen reduzieren" else "Reduced motion", motion.as(gtk.Widget));
        const message = w.label("", "pearl-secondary");
        host.append(message.as(gtk.Widget));
        const raw_view = gtk.TextView.new();
        raw_view.setMonospace(1);
        raw_view.setWrapMode(.word_char);
        raw_view.setTopMargin(12);
        raw_view.setBottomMargin(20);
        raw_view.setLeftMargin(24);
        raw_view.setRightMargin(24);
        w.name(raw_view.as(gtk.Widget), if (german) "Vollständige Pearl-Einstellungen als JSON" else "Full Pearl preferences JSON");
        // The caller installs raw_view directly in Advanced's sole viewport.
        self.* = .{ .editor = editor, .window = window, .host = host, .raw_view = raw_view, .raw = raw_view.getBuffer(), .arena = .init(a), .mode = mode, .variant = variant, .source = source, .fit = fit, .density = density, .entries = .{ gtk_name, seed, path, color, font }, .font_size = font_size, .motion = motion, .picture = picture, .preview_note = preview_note, .preview_css = gtk.CssProvider.new(), .choose = choose, .message = message, .mode_hint = hint, .german = german };
        gtk.StyleContext.addProviderForDisplay(window.as(gtk.Widget).getDisplay(), self.preview_css.as(gtk.StyleProvider), 602);
        for (self.entries) |control| _ = gtk.Editable.signals.changed.connect(control.as(gtk.Editable), *View, edited, self, .{});
        for ([_]*gtk.DropDown{ mode, variant, source, fit, density }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(font_size, *View, spun, self, .{});
        _ = object.Object.signals.notify.connect(motion.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(choose, *View, chooseWallpaper, self, .{});
        self.raw_insert_signal = gtk.TextBuffer.signals.insert_text.connect(self.raw, *View, inserting, self, .{});
        self.raw_changed_signal = gtk.TextBuffer.signals.changed.connect(self.raw, *View, rawEdited, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.filling = true;
        self.closePicker();
        if (self.preview_idle != 0) _ = glib.Source.remove(self.preview_idle);
        self.cancelPreview();
        gtk.StyleContext.removeProviderForDisplay(self.window.as(gtk.Widget).getDisplay(), self.preview_css.as(gtk.StyleProvider));
        self.preview_css.unref();
        if (self.shown) |s| a.free(s);
        if (self.preview_key) |s| a.free(s);
        self.arena.deinit();
        // Widget destruction disconnects callbacks before this struct is freed.
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        // raw_view remains owned by the window until its destruction; disconnect
        // its buffer callbacks explicitly because the host destroys us first.
        object.signalHandlerDisconnect(self.raw.as(object.Object), self.raw_insert_signal);
        object.signalHandlerDisconnect(self.raw.as(object.Object), self.raw_changed_signal);
        a.destroy(self);
    }
    fn t(self: *View, en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
        return if (self.german) de else en;
    }
    pub fn update(self: *View) void {
        const text_ = self.editor.text();
        const changed = self.shown == null or !std.mem.eql(u8, self.shown.?, text_);
        if (changed and !self.filling) {
            const copy = a.dupeZ(u8, text_) catch return;
            if (self.shown) |old| a.free(old);
            self.shown = copy;
            self.filling = true;
            defer self.filling = false;
            self.raw.setText(copy, @intCast(copy.len));
            var arena = std.heap.ArenaAllocator.init(a);
            const parsed = model.parse(arena.allocator(), text_) catch null;
            if (parsed) |prefs| {
                self.arena.deinit();
                self.arena = arena;
                self.prefs = prefs;
                self.raw_invalid = false;
                if (!self.editing_form) self.fill(prefs);
            } else {
                arena.deinit();
                if (!self.editing_form) self.raw_invalid = true;
            }
            self.queuePreview();
        }
        const editable = self.editor.editable();
        self.host.as(gtk.Widget).setSensitive(@intFromBool(editable and !self.raw_invalid));
        self.raw_view.setEditable(@intFromBool(self.editor.online and self.editor.ready and !self.editor.state.locked and self.editor.download == .none));
        self.raw_view.as(gtk.Widget).setSensitive(@intFromBool(self.editor.ready));
        self.source.as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 1));
        self.entries[0].as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 2));
        self.entries[1].as(gtk.Widget).setSensitive(@intFromBool(self.mode.getSelected() == 1 and self.source.getSelected() == 0));
        showRow(self.source.as(gtk.Widget), self.mode.getSelected() == 1);
        showRow(self.entries[0].as(gtk.Widget), self.mode.getSelected() == 2);
        showRow(self.entries[1].as(gtk.Widget), self.mode.getSelected() == 1 and self.source.getSelected() == 0);
        self.mode_hint.as(gtk.Widget).setVisible(@intFromBool(self.mode.getSelected() != 0));
        self.mode_hint.setText(if (self.mode.getSelected() == 2) self.t("An empty GTK theme name follows the system.", "Ein leerer GTK-Name folgt dem System.") else self.t("Dynamic colors need matugen 4.x.", "Dynamische Farben benötigen matugen 4.x."));
        self.message.setText(if (self.raw_invalid) self.t("Advanced JSON is invalid. Correct it there to use these controls.", "Das JSON ist ungültig. Korrigiere es unter Erweitert, um diese Regler zu nutzen.") else "");
    }
    fn fill(self: *View, prefs: model.Preferences) void {
        self.mode.setSelected(@intFromEnum(prefs.theme.mode));
        self.variant.setSelected(@intFromEnum(prefs.theme.variant));
        self.source.setSelected(@intFromEnum(prefs.theme.source));
        self.fit.setSelected(@intFromEnum(prefs.wallpaper.mode));
        self.density.setSelected(@intFromEnum(prefs.density));
        for (self.entries, [_][]const u8{ prefs.theme.gtk_name, prefs.theme.seed, prefs.wallpaper.path, prefs.wallpaper.color, prefs.font }) |control, value| control.as(gtk.Editable).setText(self.arena.allocator().dupeZ(u8, value) catch "");
        self.font_size.setValue(@floatFromInt(prefs.font_size));
        self.motion.setActive(@intFromBool(prefs.reduced_motion));
    }
    fn saveForm(self: *View) void {
        if (self.filling or !self.editor.editable()) return;
        var prefs = self.prefs;
        prefs.theme.mode = @enumFromInt(self.mode.getSelected());
        prefs.theme.variant = @enumFromInt(self.variant.getSelected());
        prefs.theme.source = @enumFromInt(self.source.getSelected());
        prefs.theme.gtk_name = text(self.entries[0]);
        prefs.theme.seed = text(self.entries[1]);
        prefs.wallpaper = .{ .mode = @enumFromInt(self.fit.getSelected()), .path = text(self.entries[2]), .color = text(self.entries[3]) };
        prefs.font = text(self.entries[4]);
        prefs.font_size = @intCast(self.font_size.getValueAsInt());
        prefs.density = @enumFromInt(self.density.getSelected());
        prefs.reduced_motion = self.motion.getActive() != 0;
        const json = std.json.Stringify.valueAlloc(a, prefs, .{ .whitespace = .indent_2 }) catch {
            self.rejectForm();
            return;
        };
        defer a.free(json);
        self.editing_form = true;
        defer self.editing_form = false;
        self.editor.edit(json) catch {
            self.rejectForm();
        };
    }
    fn rejectForm(self: *View) void {
        self.filling = true;
        self.fill(self.prefs);
        self.filling = false;
        self.editor.error_code.set("OutOfMemory");
        self.editor.notify(self.editor.context, .changed);
    }
    fn edited(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn spun(_: *gtk.SpinButton, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn inserting(buffer: *gtk.TextBuffer, _: *gtk.TextIter, _: [*:0]u8, length: c_int, self: *View) callconv(.c) void {
        if (self.filling) return;
        const bytes = rawText(buffer);
        defer glib.free(bytes);
        if (length < 0 or std.mem.span(bytes).len + @as(usize, @intCast(length)) > model.max_bytes) {
            object.signalStopEmissionByName(buffer.as(object.Object), "insert-text");
            self.editor.error_code.set("DocumentTooLarge");
            self.editor.notify(self.editor.context, .changed);
        }
    }
    fn rawEdited(buffer: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (self.filling) return;
        const bytes = rawText(buffer);
        defer glib.free(bytes);
        // Avoid resetting the buffer/selection during its own changed signal.
        self.filling = true;
        self.editor.edit(std.mem.span(bytes)) catch |err| {
            // Reject visibly: never leave GTK text that the coordinator cannot
            // flush on close. An explicit byte count permits the borrowed slice.
            const previous = self.editor.text();
            buffer.setText(@ptrCast(previous.ptr), @intCast(previous.len));
            self.filling = false;
            self.editor.error_code.set(@errorName(err));
            self.editor.notify(self.editor.context, .changed);
            return;
        };
        self.filling = false;
        if (self.shown) |old| a.free(old);
        self.shown = a.dupeZ(u8, std.mem.span(bytes)) catch null;
        var arena = std.heap.ArenaAllocator.init(a);
        const prefs = model.parse(arena.allocator(), std.mem.span(bytes)) catch null;
        if (prefs) |value| {
            self.arena.deinit();
            self.arena = arena;
            self.prefs = value;
            self.filling = true;
            self.fill(value);
            self.filling = false;
            self.raw_invalid = false;
            self.queuePreview();
        } else {
            arena.deinit();
            self.raw_invalid = true;
        }
        self.update();
    }
    pub fn closePicker(self: *View) void {
        if (self.picker) |picker| {
            self.picker = null;
            picker.as(gtk.Window).destroy();
            picker.unref();
        }
    }
    fn chooseWallpaper(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        if (self.picker) |picker| {
            picker.as(gtk.Window).present();
            return;
        }
        const picker = object.ext.newInstance(gtk.FileChooserDialog, .{ .title = self.t("Choose wallpaper image", "Hintergrundbild auswählen"), .action = gtk.FileChooserAction.open, .use_header_bar = @as(c_int, 1) });
        self.picker = picker;
        _ = picker.ref();
        const window = picker.as(gtk.Window);
        window.setTransientFor(self.window);
        window.setModal(1);
        window.setDefaultSize(680, 520);
        const dialog = picker.as(gtk.Dialog);
        _ = dialog.addButton(self.t("_Cancel", "_Abbrechen"), @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton(self.t("_Select", "_Auswählen"), @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.accept));
        const filter = gtk.FileFilter.new();
        filter.setName("PNG and JPEG images");
        filter.addMimeType("image/png");
        filter.addMimeType("image/jpeg");
        picker.as(gtk.FileChooser).addFilter(filter);
        const current = self.entries[2].as(gtk.Editable).getText();
        if (current[0] == '/') {
            const file = gio.File.newForPath(current);
            defer file.unref();
            _ = picker.as(gtk.FileChooser).setFile(file, null);
        }
        _ = gtk.Dialog.signals.response.connect(dialog, *View, wallpaperChosen, self, .{});
        window.present();
    }
    fn wallpaperChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer self.closePicker();
        if (response != @intFromEnum(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = object.ext.cast(gtk.FileChooser, dialog).?.getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse {
            self.message.setText(self.t("Choose an image stored on this computer.", "Wähle ein lokal gespeichertes Bild."));
            return;
        };
        defer glib.free(path);
        if (std.mem.span(path).len > 1024 or !std.unicode.utf8ValidateSlice(std.mem.span(path))) {
            self.message.setText(self.t("The image path is too long or is not valid UTF-8.", "Der Bildpfad ist zu lang oder kein gültiges UTF-8."));
            return;
        }
        self.filling = true;
        self.entries[2].as(gtk.Editable).setText(path);
        self.fit.setSelected(@intFromEnum(@as(model.Wallpaper, .{ .mode = .cover }).mode));
        self.filling = false;
        self.saveForm();
    }
    fn cancelPreview(self: *View) void {
        if (self.preview) |preview| {
            self.preview = null;
            preview.owner = null;
            preview.cancel.cancel();
        }
    }
    fn queuePreview(self: *View) void {
        if (self.preview_idle == 0) self.preview_idle = glib.timeoutAdd(150, refreshPreview, self);
    }
    fn refreshPreview(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.preview_idle = 0;
        const path = text(self.entries[2]);
        const mode = self.fit.getSelected();
        const color = text(self.entries[3]);
        const key = std.fmt.allocPrint(a, "{d}:{s}:{s}", .{ mode, color, path }) catch return 0;
        if (self.preview_key) |old| if (std.mem.eql(u8, old, key)) {
            a.free(key);
            return 0;
        };
        if (self.preview_key) |old| a.free(old);
        self.preview_key = key;
        self.cancelPreview();
        self.preview_ready = false;
        self.picture.setPaintable(null);
        self.picture.setContentFit(if (mode == 3) .contain else .cover);
        const css = std.fmt.allocPrintSentinel(a, ".settings-window .settings-draft-preview {{ background: {s}; }}", .{if (mode == 0) "linear-gradient(155deg, #211a2b, #9576b5)" else if (model.hex(color)) color else "#141218"}, 0) catch return 0;
        defer a.free(css);
        self.preview_css.loadFromString(css);
        self.preview_note.setText(self.t("Draft preview · Changes take effect after Apply & save.", "Entwurfsvorschau · Änderungen werden erst beim Anwenden wirksam."));
        if (mode < 2 or path.len == 0 or path[0] != '/') return 0;
        const z = a.dupeZ(u8, path) catch return 0;
        defer a.free(z);
        const preview = a.create(Preview) catch return 0;
        preview.* = .{ .owner = self, .file = gio.File.newForPath(z), .cancel = gio.Cancellable.new() };
        self.preview = preview;
        preview.file.readAsync(0, preview.cancel, Preview.opened, preview);
        return 0;
    }
};
const Preview = struct {
    owner: ?*View,
    file: *gio.File,
    cancel: *gio.Cancellable,
    stream: ?*gio.InputStream = null,
    fn destroy(self: *Preview) void {
        if (self.stream) |stream| {
            _ = stream.close(null, null);
            stream.unref();
        }
        self.file.unref();
        self.cancel.unref();
        a.destroy(self);
    }
    fn failed(self: *Preview) void {
        if (self.owner) |owner| {
            owner.preview = null;
            owner.preview_note.setText(owner.t("Could not preview this image. Apply will validate the file.", "Keine Bildvorschau möglich. Beim Anwenden wird die Datei geprüft."));
        }
        self.destroy();
    }
    fn opened(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Preview = @ptrCast(@alignCast(data.?));
        const stream = self.file.readFinish(result, null) orelse {
            self.failed();
            return;
        };
        self.stream = stream.as(gio.InputStream);
        if (self.owner == null) {
            self.destroy();
            return;
        }
        pixbuf.Pixbuf.newFromStreamAtScaleAsync(self.stream.?, 720, 200, 1, self.cancel, decoded, self);
    }
    fn decoded(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Preview = @ptrCast(@alignCast(data.?));
        const image = pixbuf.Pixbuf.newFromStreamFinish(result, null) orelse {
            self.failed();
            return;
        };
        defer image.unref();
        if (self.owner) |owner| {
            const texture = gdk.Texture.newForPixbuf(image);
            defer texture.unref();
            owner.picture.setPaintable(texture.as(gdk.Paintable));
            owner.preview_ready = true;
            owner.preview = null;
        }
        self.destroy();
    }
};
fn rawText(buffer: *gtk.TextBuffer) [*:0]u8 {
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    return buffer.getText(&start, &end, 1);
}
fn text(entry_: *gtk.Entry) []const u8 {
    return std.mem.span(entry_.as(gtk.Editable).getText());
}
fn card(host: *gtk.Box) *gtk.Box {
    const box = w.column(0);
    box.as(gtk.Widget).addCssClass("settings-card");
    host.append(box.as(gtk.Widget));
    return box;
}
fn row(host: *gtk.Box, title: [:0]const u8, control: *gtk.Widget) void {
    const box = gtk.FlowBox.new();
    box.setSelectionMode(.none);
    box.setHomogeneous(0);
    box.setMinChildrenPerLine(1);
    box.setMaxChildrenPerLine(2);
    box.setColumnSpacing(16);
    box.setRowSpacing(8);
    box.as(gtk.Widget).addCssClass("settings-form-row");
    const label = w.label(title, "settings-row-title");
    box.insert(label.as(gtk.Widget), -1);
    control.setHalign(.end);
    control.setValign(.center);
    w.name(control, title);
    box.insert(control, -1);
    host.append(box.as(gtk.Widget));
}
fn showRow(control: *gtk.Widget, visible: bool) void {
    // Every form control is wrapped by a FlowBoxChild in its own form row.
    control.getParent().?.getParent().?.setVisible(@intFromBool(visible));
}
fn entry(host: *gtk.Box, title: [:0]const u8, max: c_int) *gtk.Entry {
    const control = gtk.Entry.new();
    control.setMaxLength(max);
    control.as(gtk.Editable).setWidthChars(16);
    control.as(gtk.Editable).setMaxWidthChars(24);
    row(host, title, control.as(gtk.Widget));
    return control;
}
fn dropdown(host: *gtk.Box, title: [:0]const u8, choices: []const [*:0]const u8) *gtk.DropDown {
    var strings: [8]?[*:0]const u8 = @splat(null);
    for (choices, 0..) |choice, i| strings[i] = choice;
    const control = gtk.DropDown.newFromStrings(@ptrCast(&strings));
    row(host, title, control.as(gtk.Widget));
    return control;
}
