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
    sync_borders: *gtk.Switch = undefined,
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
    slideshow_enabled: *gtk.Switch = undefined,
    slideshow_folder: *gtk.Entry = undefined,
    slideshow_choose: *gtk.Button = undefined,
    slideshow_interval: *gtk.SpinButton = undefined,
    slideshow_order: *gtk.DropDown = undefined,
    slideshow_transition: *gtk.DropDown = undefined,
    slideshow_duration: *gtk.SpinButton = undefined,
    folder_picker: ?*gtk.FileChooserDialog = null,
    message: *gtk.Label,
    mode_hint: *gtk.Label,
    qt_enabled: *gtk.Switch,
    qt5: *gtk.Switch,
    qt6: *gtk.Switch,
    qt_palette: *gtk.DropDown,
    qt_font: *gtk.Switch,
    qt_icon: *gtk.Entry,
    qt_radius: *gtk.SpinButton,
    qt_motion: *gtk.Switch,
    qt_density: *gtk.Switch,
    qt_kde: *gtk.Switch,
    qt_status: *gtk.Label,
    qt_retry: *gtk.Button,
    qt_review: *gtk.Button,
    qt_reapply: *gtk.Button,
    qt_comparison: *gtk.Label,
    night_enabled: *gtk.Switch = undefined,
    night_temperature: *gtk.SpinButton = undefined,
    night_schedule: *gtk.DropDown = undefined,
    night_times: [4]*gtk.SpinButton = undefined,
    night_status: *gtk.Label = undefined,
    night_resume: *gtk.Button = undefined,
    german: bool,
    themes: *@import("themes_view.zig").View = undefined,
    profiles: *@import("profiles_view.zig").View = undefined,
    greeter_sync: *@import("greeter_sync.zig").View = undefined,

    pub fn create(window: *gtk.Window, host: *gtk.Box, editor: *Editor, german: bool) !*View {
        const self = try a.create(View);
        const appearance = card(host);
        const mode = dropdown(appearance, if (german) "Design" else "Theme", &.{ "Material · static", "Material · dynamic", "GTK theme", "Community package" });
        const variant = dropdown(appearance, if (german) "Farbvariante" else "Color variant", &.{ "Dark", "Light" });
        const source = dropdown(appearance, if (german) "Dynamische Farben aus" else "Dynamic colors from", &.{ "Seed color", "Wallpaper" });
        const gtk_name = entry(appearance, if (german) "GTK-Designname" else "GTK theme name", 96);
        gtk_name.setPlaceholderText(if (german) "Systemvorgabe" else "System default");
        const seed = entry(appearance, if (german) "Ausgangsfarbe" else "Seed color", 7);
        seed.setPlaceholderText("#6750a4");
        const hint = w.label(if (german) "Dynamische Farben benötigen matugen 4.x. Ein leerer GTK-Name folgt dem System." else "Dynamic colors need matugen 4.x. An empty GTK theme name follows the system.", "pearl-secondary");
        appearance.append(hint.as(gtk.Widget));
        const sync_borders = toggle(appearance, if (german) "Fensterrahmen folgen dem Pearl-Design" else "Window borders follow Pearl theme");
        appearance.append(w.label(if (german) "Verwendet Material-Farben für aktive, normale und dringende Fenster. Wartet auf ausstehende Aqueous-Änderungen. Ausschalten behält die letzten Farben; im GTK-Modus pausiert die Synchronisierung." else "Uses Material colors for focused, normal, and urgent windows. Waits for pending Aqueous edits. Turning off keeps the last colors; GTK mode pauses synchronization.", "pearl-secondary").as(gtk.Widget));
        const wallpaper = card(host);
        wallpaper.append(w.label(self.t("Wallpaper", "Hintergrundbild"), "settings-row-title").as(gtk.Widget));
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
        // One card owns the whole wallpaper area; the slideshow is a section of it.
        const slideshow = wallpaper;
        const divider = gtk.Separator.new(.horizontal);
        divider.as(gtk.Widget).setMarginTop(16);
        divider.as(gtk.Widget).setMarginBottom(16);
        slideshow.append(divider.as(gtk.Widget));
        slideshow.append(w.label(self.t("Slideshow", "Diashow"), "settings-row-title").as(gtk.Widget));
        slideshow.append(w.label(self.t("Rotates through the images in one folder. Only PNG and JPEG are used. Each change re-runs wallpaper colors when the theme follows the image.", "Wechselt durch die Bilder eines Ordners. Nur PNG und JPEG werden verwendet. Jeder Wechsel berechnet die Bildfarben neu, wenn das Design dem Bild folgt."), "pearl-secondary").as(gtk.Widget));
        self.slideshow_enabled = toggle(slideshow, self.t("Enable slideshow", "Diashow aktivieren"));
        self.slideshow_folder = entry(slideshow, self.t("Image folder", "Bildordner"), 1024);
        self.slideshow_folder.setPlaceholderText(self.t("No folder selected", "Kein Ordner ausgewählt"));
        self.slideshow_choose = w.wrappingButton(self.t("Choose folder…", "Ordner auswählen…"));
        self.slideshow_choose.as(gtk.Widget).setHalign(.end);
        self.slideshow_choose.as(gtk.Widget).setMarginEnd(20);
        self.slideshow_choose.as(gtk.Widget).setMarginBottom(12);
        slideshow.append(self.slideshow_choose.as(gtk.Widget));
        self.slideshow_interval = gtk.SpinButton.newWithRange(10, 86400, 10);
        row(slideshow, self.t("Change every (seconds)", "Wechseln alle (Sekunden)"), self.slideshow_interval.as(gtk.Widget));
        self.slideshow_order = dropdown(slideshow, self.t("Order", "Reihenfolge"), if (german) &.{ "Fortlaufend", "Zufällig" } else &.{ "Sequential", "Random" });
        self.slideshow_transition = dropdown(slideshow, self.t("Transition", "Übergang"), if (german) &.{ "Keiner", "Überblenden", "Schieben", "Drehen", "Überdecken", "Zufällig" } else &.{ "None", "Fade", "Slide", "Rotate", "Cover", "Random" });
        self.slideshow_duration = gtk.SpinButton.newWithRange(100, 5000, 20);
        row(slideshow, self.t("Animation length (ms)", "Animationsdauer (ms)"), self.slideshow_duration.as(gtk.Widget));
        const typography = card(host);
        const font = entry(typography, if (german) "Schriftfamilie" else "Font family", 96);
        font.setPlaceholderText(if (german) "Systemvorgabe" else "System default");
        const font_size = gtk.SpinButton.newWithRange(10, 24, 1);
        row(typography, if (german) "Schriftgröße" else "Font size", font_size.as(gtk.Widget));
        const density = dropdown(typography, if (german) "Abstände" else "Density", &.{ "Comfortable", "Compact" });
        const motion = gtk.Switch.new();
        row(typography, if (german) "Bewegungen reduzieren" else "Reduced motion", motion.as(gtk.Widget));
        const qt_card = card(host);
        qt_card.append(w.label(if (german) "Qt-Anwendungen · QtEngine + Darkly" else "Qt applications · QtEngine + Darkly", "settings-row-title").as(gtk.Widget));
        qt_card.append(w.label(if (german) "QtEngine verwendet eine gemeinsame Konfiguration für Qt 5 und Qt 6. Ausgewählte Prüfungen kontrollieren die installierten Laufzeiten. GTK-Modus verwendet statische Pearl-Farben. Deaktivieren stellt unveränderte frühere Werte wieder her." else "QtEngine shares one configuration across Qt 5 and Qt 6. Selected checks verify the installed runtimes. Changes affect this user account. GTK mode uses Pearl's static colors. Disabling restores previous values that have not been edited elsewhere.", "pearl-secondary").as(gtk.Widget));
        const qt_enabled = toggle(qt_card, if (german) "Qt-Aussehen verwalten" else "Manage Qt appearance");
        const qt5 = toggle(qt_card, if (german) "Qt 5 prüfen" else "Check Qt 5");
        const qt6 = toggle(qt_card, if (german) "Qt 6 prüfen" else "Check Qt 6");
        const qt_palette = dropdown(qt_card, if (german) "Qt-Farben" else "Qt colors", if (german) &.{ "Pearl folgen", "Statisch dunkel", "Statisch hell" } else &.{ "Follow Pearl", "Static dark", "Static light" });
        const qt_font = toggle(qt_card, if (german) "Schrift synchronisieren" else "Synchronize font");
        const qt_icon = entry(qt_card, if (german) "Qt-Symboldesign" else "Qt icon theme", 96);
        qt_icon.setPlaceholderText(if (german) "Vorhandene Einstellung behalten" else "Keep existing setting");
        const qt_radius = gtk.SpinButton.newWithRange(0, 16, 1);
        row(qt_card, if (german) "Eckenradius (0: beibehalten)" else "Corner radius (0: keep existing)", qt_radius.as(gtk.Widget));
        const qt_motion = toggle(qt_card, if (german) "Bewegungen synchronisieren" else "Synchronize reduced motion");
        const qt_density = toggle(qt_card, if (german) "Abstände synchronisieren" else "Synchronize density");
        const qt_kde = toggle(qt_card, if (german) "Darkly-Fokusfarben in KDE synchronisieren" else "Synchronize Darkly focus colors in KDE");
        const qt_status = w.label("", "pearl-secondary");
        qt_status.setSelectable(1);
        qt_card.append(qt_status.as(gtk.Widget));
        const qt_retry = w.wrappingButton(if (german) "Gespeicherte Qt-Einstellungen erneut anwenden" else "Retry saved Qt settings");
        qt_card.append(qt_retry.as(gtk.Widget));
        const qt_review = w.wrappingButton(if (german) "Externe Qt-Änderungen prüfen" else "Review external Qt changes");
        qt_card.append(qt_review.as(gtk.Widget));
        const qt_comparison = w.label("", "pearl-secondary");
        qt_comparison.setSelectable(1);
        qt_card.append(qt_comparison.as(gtk.Widget));
        const qt_reapply = w.wrappingButton(if (german) "Geprüfte Werte durch gespeicherte Qt-Einstellungen ersetzen" else "Replace reviewed values with saved Qt settings");
        qt_card.append(qt_reapply.as(gtk.Widget));
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
        self.* = .{ .editor = editor, .window = window, .host = host, .raw_view = raw_view, .raw = raw_view.getBuffer(), .arena = .init(a), .mode = mode, .variant = variant, .source = source, .fit = fit, .density = density, .entries = .{ gtk_name, seed, path, color, font }, .font_size = font_size, .motion = motion, .picture = picture, .preview_note = preview_note, .preview_css = gtk.CssProvider.new(), .choose = choose, .message = message, .mode_hint = hint, .german = german, .qt_enabled = qt_enabled, .qt5 = qt5, .qt6 = qt6, .qt_palette = qt_palette, .qt_font = qt_font, .qt_icon = qt_icon, .qt_radius = qt_radius, .qt_motion = qt_motion, .qt_density = qt_density, .qt_kde = qt_kde, .qt_status = qt_status, .qt_retry = qt_retry, .qt_review = qt_review, .qt_reapply = qt_reapply, .qt_comparison = qt_comparison };
        const night = card(host);
        night.append(w.label(self.t("Night Light", "Nachtlicht"), "settings-row-title").as(gtk.Widget));
        night.append(w.label(self.t("Warmer screen colors on supported displays. The status below shows which displays can apply your saved schedule.", "Wärmere Farben auf unterstützten Bildschirmen. Der Status unten zeigt, welche Bildschirme den gespeicherten Zeitplan anwenden können."), "pearl-secondary").as(gtk.Widget));
        self.night_enabled = toggle(night, self.t("Enable Night Light", "Nachtlicht aktivieren"));
        self.night_temperature = gtk.SpinButton.newWithRange(2500, 6500, 100);
        row(night, self.t("Color temperature (K) · lower is warmer", "Farbtemperatur (K) · niedriger ist wärmer"), self.night_temperature.as(gtk.Widget));
        self.night_schedule = dropdown(night, self.t("Schedule", "Zeitplan"), if (german) &.{ "Manuell", "Eigene Zeiten" } else &.{ "Manual", "Custom times" });
        for (0..2) |i| {
            const time_row = w.row(4);
            const hour = gtk.SpinButton.newWithRange(0, 23, 1);
            const minute = gtk.SpinButton.newWithRange(0, 59, 1);
            w.name(hour.as(gtk.Widget), if (i == 0) self.t("Start hour", "Startstunde") else self.t("End hour", "Endstunde"));
            w.name(minute.as(gtk.Widget), if (i == 0) self.t("Start minute", "Startminute") else self.t("End minute", "Endminute"));
            time_row.append(hour.as(gtk.Widget));
            time_row.append(w.label(":", null).as(gtk.Widget));
            time_row.append(minute.as(gtk.Widget));
            row(night, if (i == 0) self.t("Start (local time)", "Beginn (Ortszeit)") else self.t("End (local time)", "Ende (Ortszeit)"), time_row.as(gtk.Widget));
            self.night_times[i * 2] = hour;
            self.night_times[i * 2 + 1] = minute;
        }
        self.night_status = w.label("", "pearl-secondary");
        night.append(self.night_status.as(gtk.Widget));
        self.night_resume = w.wrappingButton(self.t("Resume saved policy", "Gespeicherte Einstellungen fortsetzen"));
        night.append(self.night_resume.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.night_resume, *View, resumeNight, self, .{});
        _ = object.Object.signals.notify.connect(self.night_enabled.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(self.night_schedule.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(self.night_temperature, *View, spun, self, .{});
        for (self.night_times) |control| _ = gtk.SpinButton.signals.value_changed.connect(control, *View, spun, self, .{});
        self.themes = try @import("themes_view.zig").View.create(host, editor);
        self.profiles = try @import("profiles_view.zig").View.create(host, editor);
        host.reorderChildAfter(self.themes.root.as(gtk.Widget), appearance.as(gtk.Widget));
        self.greeter_sync = try @import("greeter_sync.zig").View.create(host, self, syncPreferences, german);
        self.sync_borders = sync_borders;
        _ = object.Object.signals.notify.connect(sync_borders.as(object.Object), *View, selected, self, .{ .detail = "active" });
        gtk.StyleContext.addProviderForDisplay(window.as(gtk.Widget).getDisplay(), self.preview_css.as(gtk.StyleProvider), 602);
        _ = gtk.Button.signals.clicked.connect(qt_retry, *View, retryQt, self, .{});
        _ = gtk.Button.signals.clicked.connect(qt_review, *View, reviewQt, self, .{});
        _ = gtk.Button.signals.clicked.connect(qt_reapply, *View, reapplyQt, self, .{});
        for ([_]*gtk.Switch{ qt_enabled, qt5, qt6, qt_font, qt_motion, qt_density, qt_kde }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(qt_palette.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.Editable.signals.changed.connect(qt_icon.as(gtk.Editable), *View, edited, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(qt_radius, *View, spun, self, .{});
        for (self.entries) |control| _ = gtk.Editable.signals.changed.connect(control.as(gtk.Editable), *View, edited, self, .{});
        for ([_]*gtk.DropDown{ mode, variant, source, fit, density }) |control| _ = object.Object.signals.notify.connect(control.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(font_size, *View, spun, self, .{});
        _ = object.Object.signals.notify.connect(motion.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(choose, *View, chooseWallpaper, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.slideshow_choose, *View, chooseFolder, self, .{});
        _ = object.Object.signals.notify.connect(self.slideshow_enabled.as(object.Object), *View, selected, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(self.slideshow_order.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(self.slideshow_transition.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        _ = gtk.SpinButton.signals.value_changed.connect(self.slideshow_interval, *View, spun, self, .{});
        _ = gtk.SpinButton.signals.value_changed.connect(self.slideshow_duration, *View, spun, self, .{});
        _ = gtk.Editable.signals.changed.connect(self.slideshow_folder.as(gtk.Editable), *View, edited, self, .{});
        self.raw_insert_signal = gtk.TextBuffer.signals.insert_text.connect(self.raw, *View, inserting, self, .{});
        self.raw_changed_signal = gtk.TextBuffer.signals.changed.connect(self.raw, *View, rawEdited, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.filling = true;
        self.themes.destroy();
        self.profiles.destroy();
        self.greeter_sync.destroy();
        self.closePicker();
        self.closeFolderPicker();
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
    fn syncPreferences(context: *anyopaque, alloc: std.mem.Allocator) !model.Preferences {
        const self: *View = @ptrCast(@alignCast(context));
        if (!self.editor.editable() or self.raw_invalid) return error.Unavailable;
        return model.parse(alloc, self.editor.text());
    }
    fn t(self: *View, en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
        return if (self.german) de else en;
    }
    pub fn update(self: *View) void {
        self.night_status.setText(self.editor.night_summary.z());
        self.night_resume.as(gtk.Widget).setVisible(@intFromBool(self.editor.night_override));
        self.themes.update();
        self.profiles.update();
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
        self.qt_status.setText(self.editor.qt_summary.z());
        self.qt_comparison.setText(self.editor.qt_review_text.z());
        self.qt_reapply.as(gtk.Widget).setVisible(@intFromBool(self.editor.qt_review_digest.len == 64 and self.editor.qt_review_text.len != 0));
        for (self.night_times) |control| control.as(gtk.Widget).setSensitive(@intFromBool(self.night_schedule.getSelected() == 1));
        const slideshow_on = self.slideshow_enabled.getActive() != 0;
        for ([_]*gtk.Widget{ self.slideshow_folder.as(gtk.Widget), self.slideshow_choose.as(gtk.Widget), self.slideshow_interval.as(gtk.Widget), self.slideshow_order.as(gtk.Widget), self.slideshow_transition.as(gtk.Widget), self.slideshow_duration.as(gtk.Widget) }) |control| control.setSensitive(@intFromBool(slideshow_on));
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
        self.mode_hint.setText(if (self.mode.getSelected() == 2) self.t("An empty GTK theme name follows the system.", "Ein leerer GTK-Name folgt dem System.") else if (self.mode.getSelected() == 3) "Select an installed community theme below." else self.t("Dynamic colors need matugen 4.x.", "Dynamische Farben benötigen matugen 4.x."));
        self.message.setText(if (self.raw_invalid) self.t("Advanced JSON is invalid. Correct it there to use these controls.", "Das JSON ist ungültig. Korrigiere es unter Erweitert, um diese Regler zu nutzen.") else "");
    }
    fn fill(self: *View, prefs: model.Preferences) void {
        self.night_enabled.setActive(@intFromBool(prefs.night_light.enabled));
        self.night_temperature.setValue(@floatFromInt(prefs.night_light.temperature_kelvin));
        self.night_schedule.setSelected(@intFromEnum(prefs.night_light.schedule));
        const night_times = [_]u16{ prefs.night_light.start_minute / 60, prefs.night_light.start_minute % 60, prefs.night_light.end_minute / 60, prefs.night_light.end_minute % 60 };
        for (self.night_times, night_times) |control, number| control.setValue(@floatFromInt(number));
        self.mode.setSelected(switch (prefs.theme.mode) {
            .static => 0,
            .dynamic => 1,
            .gtk => 2,
            .package => 3,
        });
        self.sync_borders.setActive(@intFromBool(prefs.theme.sync_borders));
        self.variant.setSelected(@intFromEnum(prefs.theme.variant));
        self.source.setSelected(@intFromEnum(prefs.theme.source));
        self.fit.setSelected(@intFromEnum(prefs.wallpaper.mode));
        self.slideshow_enabled.setActive(@intFromBool(prefs.wallpaper.slideshow.enabled));
        self.slideshow_folder.as(gtk.Editable).setText(self.arena.allocator().dupeZ(u8, prefs.wallpaper.slideshow.folder) catch "");
        self.slideshow_interval.setValue(@floatFromInt(prefs.wallpaper.slideshow.interval_seconds));
        self.slideshow_order.setSelected(@intFromEnum(prefs.wallpaper.slideshow.order));
        self.slideshow_transition.setSelected(@intFromEnum(prefs.wallpaper.slideshow.transition));
        self.slideshow_duration.setValue(@floatFromInt(prefs.wallpaper.slideshow.transition_ms));
        self.density.setSelected(@intFromEnum(prefs.density));
        for (self.entries, [_][]const u8{ prefs.theme.gtk_name, prefs.theme.seed, prefs.wallpaper.path, prefs.wallpaper.color, prefs.font }) |control, value| control.as(gtk.Editable).setText(self.arena.allocator().dupeZ(u8, value) catch "");
        self.font_size.setValue(@floatFromInt(prefs.font_size));
        self.motion.setActive(@intFromBool(prefs.reduced_motion));
        self.qt_enabled.setActive(@intFromBool(prefs.qt.enabled));
        self.qt5.setActive(@intFromBool(prefs.qt.targets.qt5));
        self.qt6.setActive(@intFromBool(prefs.qt.targets.qt6));
        self.qt_palette.setSelected(@intFromEnum(prefs.qt.palette));
        self.qt_font.setActive(@intFromBool(prefs.qt.sync_font));
        self.qt_icon.as(gtk.Editable).setText(self.arena.allocator().dupeZ(u8, prefs.qt.icon_theme) catch "");
        self.qt_radius.setValue(@floatFromInt(prefs.qt.darkly.corner_radius orelse 0));
        self.qt_motion.setActive(@intFromBool(prefs.qt.darkly.sync_reduced_motion));
        self.qt_kde.setActive(@intFromBool(prefs.qt.darkly.sync_kde_colors));
        self.qt_density.setActive(@intFromBool(prefs.qt.darkly.sync_density));
    }
    fn saveForm(self: *View) void {
        if (self.filling or !self.editor.editable()) return;
        var prefs = self.prefs;
        prefs.night_light = .{
            .enabled = self.night_enabled.getActive() != 0,
            .temperature_kelvin = @intCast(self.night_temperature.getValueAsInt()),
            .schedule = @enumFromInt(self.night_schedule.getSelected()),
            .start_minute = @intCast(self.night_times[0].getValueAsInt() * 60 + self.night_times[1].getValueAsInt()),
            .end_minute = @intCast(self.night_times[2].getValueAsInt() * 60 + self.night_times[3].getValueAsInt()),
        };
        prefs.theme.mode = switch (self.mode.getSelected()) {
            1 => .dynamic,
            2 => .gtk,
            3 => .package,
            else => .static,
        };
        prefs.theme.sync_borders = self.sync_borders.getActive() != 0;
        prefs.theme.variant = @enumFromInt(self.variant.getSelected());
        prefs.theme.source = @enumFromInt(self.source.getSelected());
        prefs.theme.gtk_name = text(self.entries[0]);
        prefs.theme.seed = text(self.entries[1]);
        // A rotating image is only visible in an image fit, so enabling the
        // slideshow moves a gradient or solid fit to cover rather than failing.
        const slideshow_on = self.slideshow_enabled.getActive() != 0;
        const chosen_fit = self.fit.getSelected();
        prefs.wallpaper = .{
            .mode = @enumFromInt(if (slideshow_on and chosen_fit != 2 and chosen_fit != 3) @as(c_uint, 2) else chosen_fit),
            .path = text(self.entries[2]),
            .color = text(self.entries[3]),
            .slideshow = .{
                .enabled = slideshow_on,
                .folder = text(self.slideshow_folder),
                .interval_seconds = @intCast(self.slideshow_interval.getValueAsInt()),
                .order = @enumFromInt(self.slideshow_order.getSelected()),
                .transition = @enumFromInt(self.slideshow_transition.getSelected()),
                .transition_ms = @intCast(self.slideshow_duration.getValueAsInt()),
            },
        };
        prefs.font = text(self.entries[4]);
        prefs.font_size = @intCast(self.font_size.getValueAsInt());
        prefs.density = @enumFromInt(self.density.getSelected());
        prefs.reduced_motion = self.motion.getActive() != 0;
        prefs.qt.enabled = self.qt_enabled.getActive() != 0;
        prefs.qt.targets = .{ .qt5 = self.qt5.getActive() != 0, .qt6 = self.qt6.getActive() != 0 };
        prefs.qt.palette = @enumFromInt(self.qt_palette.getSelected());
        prefs.qt.sync_font = self.qt_font.getActive() != 0;
        prefs.qt.icon_theme = text(self.qt_icon);
        const radius = self.qt_radius.getValueAsInt();
        prefs.qt.darkly.corner_radius = if (radius == 0) null else @intCast(radius);
        prefs.qt.darkly.sync_reduced_motion = self.qt_motion.getActive() != 0;
        prefs.qt.darkly.sync_kde_colors = self.qt_kde.getActive() != 0;
        prefs.qt.darkly.sync_density = self.qt_density.getActive() != 0;
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
    fn resumeNight(_: *gtk.Button, self: *View) callconv(.c) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const params = std.json.Stringify.valueAlloc(alloc, .{ .generation = @import("editor_protocol.zig").num(self.editor.night_generation), .action = "resume" }, .{}) catch return;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, params, .{}) catch return;
        self.editor.liveAction(.@"night-light.action", value) catch |err| {
            self.editor.error_code.set(@errorName(err));
        };
    }
    fn retryQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.retry");
    }
    fn reviewQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.review");
    }
    fn reapplyQt(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.retryQt(.@"qt.reapply");
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
    pub fn closeFolderPicker(self: *View) void {
        if (self.folder_picker) |picker| {
            self.folder_picker = null;
            picker.as(gtk.Window).destroy();
            picker.unref();
        }
    }
    fn chooseFolder(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        if (self.folder_picker) |picker| {
            picker.as(gtk.Window).present();
            return;
        }
        const picker = object.ext.newInstance(gtk.FileChooserDialog, .{ .title = self.t("Choose wallpaper folder", "Hintergrundbild-Ordner auswählen"), .action = gtk.FileChooserAction.select_folder, .use_header_bar = @as(c_int, 1) });
        self.folder_picker = picker;
        _ = picker.ref();
        const window = picker.as(gtk.Window);
        window.setTransientFor(self.window);
        window.setModal(1);
        window.setDefaultSize(680, 520);
        const dialog = picker.as(gtk.Dialog);
        _ = dialog.addButton(self.t("_Cancel", "_Abbrechen"), @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton(self.t("_Select", "_Auswählen"), @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.accept));
        const current = self.slideshow_folder.as(gtk.Editable).getText();
        if (current[0] == '/') {
            const file = gio.File.newForPath(current);
            defer file.unref();
            _ = picker.as(gtk.FileChooser).setFile(file, null);
        }
        _ = gtk.Dialog.signals.response.connect(dialog, *View, folderChosen, self, .{});
        window.present();
    }
    fn folderChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer self.closeFolderPicker();
        if (response != @intFromEnum(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = object.ext.cast(gtk.FileChooser, dialog).?.getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse {
            self.message.setText(self.t("Choose a folder stored on this computer.", "Wähle einen lokal gespeicherten Ordner."));
            return;
        };
        defer glib.free(path);
        const folder = std.mem.span(path);
        if (folder.len > 1024 or !std.unicode.utf8ValidateSlice(folder)) {
            self.message.setText(self.t("The folder path is too long or is not valid UTF-8.", "Der Ordnerpfad ist zu lang oder kein gültiges UTF-8."));
            return;
        }
        self.filling = true;
        self.slideshow_folder.as(gtk.Editable).setText(path);
        // Validation needs an image fit and an initial image once the slideshow runs.
        if (self.fit.getSelected() != 2 and self.fit.getSelected() != 3) self.fit.setSelected(@intFromEnum(@as(model.Wallpaper, .{ .mode = .cover }).mode));
        if (self.entries[2].as(gtk.Editable).getText()[0] != '/') {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            if (@import("../config/slideshow.zig").firstImage(arena.allocator(), folder)) |first| self.entries[2].as(gtk.Editable).setText(first.ptr);
        }
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

fn toggle(host: *gtk.Box, title: [:0]const u8) *gtk.Switch {
    const control = gtk.Switch.new();
    row(host, title, control.as(gtk.Widget));
    return control;
}
