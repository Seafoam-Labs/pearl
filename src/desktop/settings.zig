//! Drafts belong to the service, so closing a popup or receiving an external edit
//! never discards them. Apply uses the revision captured when editing began.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const glib = @import("glib2");
const gio = @import("gio2");
const layer = @import("gtk4layershell1");
const Service = @import("../config/service.zig").Service;
const model = @import("../config/preferences.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    service: *Service,
    host: *gtk.Box,
    forms: [3]*gtk.Box,
    idle_spins: [4]*gtk.SpinButton = undefined,
    arena: std.heap.ArenaAllocator,
    base: model.Preferences = .{},
    revision: u64 = 0,
    draft_serial: u64 = 0,
    local_error: ?anyerror = null,
    filling: bool = true,
    mode: *gtk.DropDown,
    variant: *gtk.DropDown,
    source: *gtk.DropDown,
    fit: *gtk.DropDown,
    density: *gtk.DropDown,
    edge: *gtk.DropDown,
    placement: *gtk.DropDown,
    entries: [5]*gtk.Entry,
    wallpaper_button: *gtk.Button = undefined,
    wallpaper_picker: ?*gtk.FileChooserDialog = null,
    font_size: *gtk.SpinButton,
    bar_size: *gtk.SpinButton,
    islands: *gtk.CheckButton = undefined,
    dock_enabled: *gtk.CheckButton = undefined,
    dock_edge: *gtk.DropDown = undefined,
    dock_mode: *gtk.DropDown = undefined,
    dock_size: *gtk.SpinButton = undefined,
    dock_margin: *gtk.SpinButton = undefined,
    motion: *gtk.CheckButton,
    outside: *gtk.CheckButton,
    raw: *gtk.TextBuffer,
    message: *gtk.Label,
    qt_status: *gtk.Label = undefined,
    apply_button: *gtk.Button,
    merge_button: *gtk.Button = undefined,
    last_probe: [48]u8 = @splat(0),
    greeter_sync: *@import("../settings/greeter_sync.zig").View = undefined,
    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        const title = w.label("Pearl settings", "pearl-title");
        host.append(title.as(gtk.Widget));
        const notebook = gtk.Notebook.new();
        notebook.as(gtk.Widget).setVexpand(1);
        host.append(notebook.as(gtk.Widget));
        const appearance = page(notebook, "Appearance");
        const bar = page(notebook, "Bar & behavior");
        const advanced = page(notebook, "Advanced");
        const session = page(notebook, "Session");
        self.* = .{ .service = service, .host = host, .forms = .{ appearance, bar, session }, .arena = std.heap.ArenaAllocator.init(a), .mode = dropdown(appearance, "Theme", &.{ "Material · static", "Material · dynamic", "GTK theme", "Community package" }), .variant = dropdown(appearance, "Color variant", &.{ "Dark", "Light" }), .source = dropdown(appearance, "Dynamic colors from", &.{ "Seed color", "Wallpaper" }), .fit = undefined, .density = undefined, .edge = undefined, .placement = undefined, .entries = undefined, .font_size = undefined, .bar_size = undefined, .motion = undefined, .outside = undefined, .raw = undefined, .message = undefined, .apply_button = undefined };
        session.append(w.label("Pearl's native lock screen uses your shell theme. Zero disables an automatic timeout. Suspend must follow the lock timeout; Pearl waits for verified lock acquisition.", "pearl-secondary").as(gtk.Widget));
        for ([_][:0]const u8{ "AC · lock after seconds", "AC · suspend after seconds", "Battery · lock after seconds", "Battery · suspend after seconds" }, 0..) |label, i| {
            self.idle_spins[i] = spin(session, label, 0, 86400);
            _ = gtk.SpinButton.signals.value_changed.connect(self.idle_spins[i], *View, spun, self, .{});
        }
        const hints = w.label("GTK theme: leave the name empty to follow the system. Installed themes must support GTK4. Dynamic colors use optional matugen 4.x.", "pearl-secondary");
        appearance.append(hints.as(gtk.Widget));
        self.entries[0] = entry(appearance, "GTK theme name", "System default");
        self.entries[1] = entry(appearance, "Seed color", "#6750a4");
        const wallpaper_row = w.row(8);
        self.entries[2] = gtk.Entry.new();
        self.entries[2].setMaxLength(1024);
        self.entries[2].setPlaceholderText("No image selected");
        self.entries[2].as(gtk.Widget).setHexpand(1);
        w.name(self.entries[2].as(gtk.Widget), "Wallpaper image");
        wallpaper_row.append(self.entries[2].as(gtk.Widget));
        self.wallpaper_button = gtk.Button.newWithLabel("Choose image…");
        wallpaper_row.append(self.wallpaper_button.as(gtk.Widget));
        appearance.append(w.section(w.label("Wallpaper image", null), null, wallpaper_row.as(gtk.Widget)).as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.wallpaper_button, *View, chooseWallpaper, self, .{});
        self.fit = dropdown(appearance, "Wallpaper fit", &.{ "Material gradient", "Solid color", "Cover", "Contain" });
        self.entries[3] = entry(appearance, "Background color", "#141218");
        self.entries[4] = entry(appearance, "Font family", "System default / Material fallback");
        self.font_size = spin(appearance, "Font size", 10, 24);
        self.density = dropdown(appearance, "Density", &.{ "Comfortable", "Compact" });
        self.motion = gtk.CheckButton.newWithLabel("Reduce motion");
        appearance.append(self.motion.as(gtk.Widget));
        self.qt_status = w.label("", "pearl-secondary");
        appearance.append(self.qt_status.as(gtk.Widget));
        const qt_settings = gtk.Button.newWithLabel("Open Qt appearance settings…");
        appearance.append(qt_settings.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(qt_settings, *View, openQtSettings, self, .{});
        self.greeter_sync = try @import("../settings/greeter_sync.zig").View.create(appearance, self, syncPreferences, false);
        bar.append(w.label("Default layout for every output. Connector overrides are available in Advanced.", "pearl-secondary").as(gtk.Widget));
        const bar_editor = gtk.Button.newWithLabel("Bar opacity and widgets…");
        bar.append(bar_editor.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(bar_editor, *View, openBarSettings, self, .{});
        self.edge = dropdown(bar, "Bar edge", &.{ "Top", "Right", "Bottom", "Left" });
        self.bar_size = spin(bar, "Bar minimum size", 32, 160);
        self.islands = gtk.CheckButton.newWithLabel("Separate rounded bar islands");
        bar.append(self.islands.as(gtk.Widget));
        self.dock_enabled = gtk.CheckButton.newWithLabel("Show applications dock");
        bar.append(self.dock_enabled.as(gtk.Widget));
        self.dock_edge = dropdown(bar, "Dock edge (moves opposite if shared with bar)", &.{ "Top", "Right", "Bottom", "Left" });
        self.dock_mode = dropdown(bar, "Dock visibility", &.{ "Always", "Hide when a window overlaps", "Auto-hide" });
        self.dock_size = spin(bar, "Dock icon size", 24, 64);
        self.dock_margin = spin(bar, "Dock distance from edge", 4, 32);
        bar.append(w.label("Pin applications using their dock action menu. Per-output dock overrides and pinned desktop IDs are available in Advanced.", "pearl-secondary").as(gtk.Widget));
        self.placement = dropdown(bar, "Popup placement", &.{ "Follow bar edge", "Centered" });
        self.outside = gtk.CheckButton.newWithLabel("Dismiss popups when clicking outside");
        bar.append(self.outside.as(gtk.Widget));
        advanced.append(w.label("Full preferences JSON. This includes connector overrides, center widgets, popup limits and opt-in exports. Apply validates every field. Export files are owned under pearl/exports; edited files are protected and the first replacement is backed up.", "pearl-secondary").as(gtk.Widget));
        const raw_view = gtk.TextView.new();
        raw_view.setMonospace(1);
        raw_view.setWrapMode(.word_char);
        raw_view.as(gtk.Widget).setVexpand(1);
        raw_view.as(gtk.Widget).setSizeRequest(-1, 340);
        advanced.append(raw_view.as(gtk.Widget));
        self.raw = raw_view.getBuffer();
        w.name(raw_view.as(gtk.Widget), "Full preferences JSON");
        self.message = w.label("", "pearl-secondary");
        host.append(self.message.as(gtk.Widget));
        const actions = w.row(12);
        host.append(actions.as(gtk.Widget));
        const discard = gtk.Button.newWithLabel("Discard draft");
        actions.append(discard.as(gtk.Widget));
        self.merge_button = gtk.Button.newWithLabel("Merge external changes");
        actions.append(self.merge_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.merge_button, *View, merged, self, .{});
        self.apply_button = gtk.Button.newWithLabel("Apply & save");
        self.apply_button.as(gtk.Widget).addCssClass("pearl-primary");
        actions.append(self.apply_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(discard, *View, discarded, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.apply_button, *View, applied, self, .{});
        for (self.entries) |e| _ = gtk.Editable.signals.changed.connect(e.as(gtk.Editable), *View, edited, self, .{});
        for ([_]*gtk.DropDown{ self.mode, self.variant, self.source, self.fit, self.density, self.edge, self.placement, self.dock_edge, self.dock_mode }) |d| _ = object.Object.signals.notify.connect(d.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        for ([_]*gtk.SpinButton{ self.font_size, self.bar_size, self.dock_size, self.dock_margin }) |s| _ = gtk.SpinButton.signals.value_changed.connect(s, *View, spun, self, .{});
        for ([_]*gtk.CheckButton{ self.motion, self.outside, self.islands, self.dock_enabled }) |c| _ = gtk.CheckButton.signals.toggled.connect(c, *View, toggled, self, .{});
        _ = gtk.TextBuffer.signals.insert_text.connect(self.raw, *View, inserting, self, .{});
        _ = gtk.TextBuffer.signals.changed.connect(self.raw, *View, rawEdited, self, .{});
        _ = gtk.Notebook.signals.switch_page.connect(notebook, *View, switched, self, .{});
        self.fill();
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.filling = true;
        self.greeter_sync.destroy();
        self.closeWallpaperPicker();
        // Disconnect through parent destruction before freeing callback data.
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        self.arena.deinit();
        a.destroy(self);
    }
    fn syncPreferences(context: *anyopaque, alloc: std.mem.Allocator) !model.Preferences {
        const self: *View = @ptrCast(@alignCast(context));
        if (self.local_error != null or self.service.job != null) return error.Unavailable;
        const bytes = self.service.draft.text orelse try std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{});
        return model.parse(alloc, bytes);
    }
    fn closeWallpaperPicker(self: *View) void {
        const picker = self.wallpaper_picker orelse return;
        self.wallpaper_picker = null;
        const window = picker.as(gtk.Window);
        if (window.getTransientFor()) |parent| layer.setKeyboardMode(parent, .exclusive);
        window.destroy();
        window.unref();
    }
    fn chooseWallpaper(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.wallpaper_picker) |picker| {
            picker.as(gtk.Window).present();
            return;
        }
        const root = self.host.as(gtk.Widget).getRoot() orelse return;
        const parent = object.ext.cast(gtk.Window, root) orelse return;
        // A regular native dialog would sit below Pearl's overlay and lose
        // keyboard input to it. Own the chooser window so it can use layer-shell.
        const picker = object.ext.newInstance(gtk.FileChooserDialog, .{ .title = "Choose wallpaper image", .action = gtk.FileChooserAction.open, .use_header_bar = @as(c_int, 0) });
        self.wallpaper_picker = picker;
        const window = picker.as(gtk.Window);
        _ = window.ref();
        window.setTransientFor(parent);
        window.setModal(1);
        window.setDefaultSize(680, 520);
        layer.initForWindow(window);
        layer.setNamespace(window, "pearl:wallpaper-picker");
        layer.setMonitor(window, layer.getMonitor(parent));
        layer.setLayer(window, .overlay);
        layer.setKeyboardMode(parent, .none);
        layer.setKeyboardMode(window, .exclusive);
        const dialog = picker.as(gtk.Dialog);
        _ = dialog.addButton("_Cancel", @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton("_Select", @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.accept));
        const chooser = picker.as(gtk.FileChooser);
        const filter = gtk.FileFilter.new();
        filter.setName("PNG and JPEG images");
        filter.addMimeType("image/png");
        filter.addMimeType("image/jpeg");
        chooser.addFilter(filter);
        const current = self.entries[2].as(gtk.Editable).getText();
        if (current[0] == '/') {
            const file = gio.File.newForPath(current);
            defer file.unref();
            _ = chooser.setFile(file, null);
        }
        _ = gtk.Dialog.signals.response.connect(dialog, *View, wallpaperChosen, self, .{});
        window.present();
    }
    fn wallpaperChosen(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        defer self.closeWallpaperPicker();
        if (response != @intFromEnum(gtk.ResponseType.accept)) return;
        const chooser = object.ext.cast(gtk.FileChooser, dialog).?;
        const file = chooser.getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse {
            self.message.setText("Choose an image stored on this computer.");
            return;
        };
        defer glib.free(path);
        if (std.mem.span(path).len > 1024 or !std.unicode.utf8ValidateSlice(std.mem.span(path))) {
            self.message.setText("The image path must be valid UTF-8 and at most 1024 bytes.");
            return;
        }
        self.filling = true;
        self.entries[2].as(gtk.Editable).setText(path);
        const cover = @intFromEnum(@as(model.Wallpaper, .{ .mode = .cover }).mode);
        self.fit.setSelected(cover);
        self.filling = false;
        self.saveForm();
    }
    fn fill(self: *View) void {
        self.filling = true;
        defer self.filling = false;
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const json = self.service.draft.text orelse (std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{ .whitespace = .indent_2 }) catch "{}");
        var valid = true;
        self.base = model.parse(alloc, json) catch blk: {
            valid = false;
            break :blk (model.parse(alloc, std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{}) catch "{}") catch .{});
        };
        for (self.forms) |form| form.as(gtk.Widget).setSensitive(@intFromBool(valid));
        self.revision = if (self.service.draft.text != null) self.service.draft.base_revision else self.service.revision;
        self.draft_serial = self.service.draft.revision;
        const p = self.base;
        for (self.entries, [_][]const u8{ p.theme.gtk_name, p.theme.seed, p.wallpaper.path, p.wallpaper.color, p.font }) |e, value| e.as(gtk.Editable).setText(alloc.dupeZ(u8, value) catch "");
        self.mode.setSelected(switch (p.theme.mode) {
            .static => 0,
            .dynamic => 1,
            .gtk => 2,
            .package => 3,
        });
        self.variant.setSelected(@intFromEnum(p.theme.variant));
        self.source.setSelected(@intFromEnum(p.theme.source));
        self.fit.setSelected(@intFromEnum(p.wallpaper.mode));
        self.density.setSelected(@intFromEnum(p.density));
        self.islands.setActive(@intFromBool(p.bar.islands));
        self.dock_enabled.setActive(@intFromBool(p.dock.enabled));
        self.dock_edge.setSelected(@intFromEnum(p.dock.edge));
        self.dock_mode.setSelected(@intFromEnum(p.dock.mode));
        self.dock_size.setValue(@floatFromInt(p.dock.icon_size));
        self.dock_margin.setValue(@floatFromInt(p.dock.margin));
        self.edge.setSelected(@intFromEnum(p.bar.edge));
        self.placement.setSelected(@intFromEnum(p.popup.placement));
        for (self.idle_spins, [_]u32{ p.idle.ac.lock_seconds, p.idle.ac.suspend_seconds, p.idle.battery.lock_seconds, p.idle.battery.suspend_seconds }) |control, value| control.setValue(@floatFromInt(value));
        self.font_size.setValue(@floatFromInt(p.font_size));
        self.bar_size.setValue(@floatFromInt(p.bar.size));
        self.motion.setActive(@intFromBool(p.reduced_motion));
        self.outside.setActive(@intFromBool(p.popup.dismiss_outside));
        self.raw.setText(alloc.dupeZ(u8, json) catch "{}", @intCast(json.len));
    }
    fn saveForm(self: *View) void {
        if (self.filling) return;
        var p = self.base;
        p.theme.mode = switch (self.mode.getSelected()) {
            1 => .dynamic,
            2 => .gtk,
            3 => .package,
            else => .static,
        };
        p.theme.variant = @enumFromInt(self.variant.getSelected());
        p.theme.source = @enumFromInt(self.source.getSelected());
        p.wallpaper.mode = @enumFromInt(self.fit.getSelected());
        p.density = @enumFromInt(self.density.getSelected());
        p.bar.islands = self.islands.getActive() != 0;
        p.dock = .{ .enabled = self.dock_enabled.getActive() != 0, .edge = @enumFromInt(self.dock_edge.getSelected()), .mode = @enumFromInt(self.dock_mode.getSelected()), .icon_size = @intCast(self.dock_size.getValueAsInt()), .margin = @intCast(self.dock_margin.getValueAsInt()) };
        p.bar.edge = @enumFromInt(self.edge.getSelected());
        p.popup.placement = @enumFromInt(self.placement.getSelected());
        p.theme.gtk_name = text(self.entries[0]);
        p.theme.seed = text(self.entries[1]);
        p.wallpaper.path = text(self.entries[2]);
        p.wallpaper.color = text(self.entries[3]);
        p.font = text(self.entries[4]);
        p.idle.ac = .{ .lock_seconds = @intCast(self.idle_spins[0].getValueAsInt()), .suspend_seconds = @intCast(self.idle_spins[1].getValueAsInt()) };
        p.idle.battery = .{ .lock_seconds = @intCast(self.idle_spins[2].getValueAsInt()), .suspend_seconds = @intCast(self.idle_spins[3].getValueAsInt()) };
        p.font_size = @intCast(self.font_size.getValueAsInt());
        p.bar.size = @intCast(self.bar_size.getValueAsInt());
        p.reduced_motion = self.motion.getActive() != 0;
        p.popup.dismiss_outside = self.outside.getActive() != 0;
        const json = std.json.Stringify.valueAlloc(a, p, .{ .whitespace = .indent_2 }) catch return;
        defer a.free(json);
        if (!self.retain(json)) return;
        const z = a.dupeZ(u8, json) catch return;
        defer a.free(z);
        self.filling = true;
        self.raw.setText(z, @intCast(json.len));
        self.filling = false;
        self.update();
    }
    fn retain(self: *View, json: []const u8) bool {
        self.filling = true;
        defer self.filling = false;
        self.draft_serial = self.service.keepDraft(json, self.draft_serial, self.revision) catch |err| {
            self.local_error = err;
            self.message.setText("Could not retain this edit. The shared draft has not been overwritten; reopen settings to load it.");
            return false;
        };
        self.local_error = null;
        return true;
    }
    pub fn update(self: *View) void {
        if (self.filling) return;
        if (self.draft_serial != self.service.draft.revision or (self.service.draft.text == null and self.revision != self.service.revision)) self.fill();
        const busy = self.service.job != null or self.service.pending_reload;
        const conflict = self.service.draft.text != null and self.revision != self.service.revision;
        self.merge_button.as(gtk.Widget).setVisible(@intFromBool(conflict));
        self.merge_button.as(gtk.Widget).setSensitive(@intFromBool(!busy and conflict));
        self.apply_button.as(gtk.Widget).setSensitive(@intFromBool(!busy and !conflict and self.local_error == null and self.service.draft.text != null));
        var buffer: [256]u8 = undefined;
        const message = if (busy) "Preparing settings…" else if (conflict) "Settings changed externally. Your draft is retained. Merge independent edits, or review conflicting fields in Advanced." else if (self.service.err) |err| std.fmt.bufPrintZ(&buffer, "Could not apply: {s}. Your draft and working appearance are retained.", .{@errorName(err)}) catch "Could not apply settings." else if (self.service.export_error) |err| std.fmt.bufPrintZ(&buffer, "Settings saved. Export needs attention: {s}", .{@errorName(err)}) catch "Export failed." else if (self.service.draft.text != null) "Unsaved draft" else "Settings are up to date.";
        self.message.setText(message);
        var qt_buffer: [256]u8 = undefined;
        const status = self.service.qt_status;
        self.qt_status.setText(std.fmt.bufPrintZ(&qt_buffer, "Qt 5: {s} · Qt 6: {s}{s}", .{ @tagName(status.qt5.state), @tagName(status.qt6.state), if (status.restart_session) " · Sign out to update the session environment" else "" }) catch "Qt appearance status unavailable");
    }
    fn openBarSettings(_: *gtk.Button, self: *View) callconv(.c) void {
        const context = self.host.as(gtk.Widget).getDisplay().getAppLaunchContext();
        defer context.unref();
        @import("../settings/launch.zig").open(.{ .page = .bar }, context.as(gio.AppLaunchContext), null) catch {
            self.message.setText("Could not open Pearl Settings. Bar preferences remain available in Advanced.");
        };
    }
    fn openQtSettings(_: *gtk.Button, self: *View) callconv(.c) void {
        const display = self.host.as(gtk.Widget).getDisplay();
        const context = display.getAppLaunchContext();
        defer context.unref();
        @import("../settings/launch.zig").open(.{ .page = .appearance }, context.as(gio.AppLaunchContext), null) catch {
            self.message.setText("Could not open Pearl Settings. Qt preferences remain available in Advanced.");
        };
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
    fn toggled(_: *gtk.CheckButton, self: *View) callconv(.c) void {
        self.saveForm();
    }
    fn inserting(buffer: *gtk.TextBuffer, _: *gtk.TextIter, _: [*:0]u8, length: c_int, self: *View) callconv(.c) void {
        if (self.filling) return;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        buffer.getBounds(&start, &end);
        const old = buffer.getText(&start, &end, 1);
        defer glib.free(old);
        if (length < 0 or std.mem.span(old).len + @as(usize, @intCast(length)) > model.max_bytes) {
            object.signalStopEmissionByName(buffer.as(object.Object), "insert-text");
            self.message.setText("Draft is limited to 64 KiB. The insertion was rejected; existing text is retained.");
        }
    }
    fn rawEdited(_: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (self.filling) return;
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        self.raw.getBounds(&start, &end);
        const json = self.raw.getText(&start, &end, 1);
        defer glib.free(json);
        if (std.mem.span(json).len > model.max_bytes) {
            self.message.setText("Draft exceeds 64 KiB. Reduce its size before applying.");
            return;
        }
        if (!self.retain(std.mem.span(json))) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const valid = if (model.parse(arena.allocator(), std.mem.span(json))) |_| true else |_| false;
        for (self.forms) |form| form.as(gtk.Widget).setSensitive(@intFromBool(valid));
        self.update();
    }
    fn switched(_: *gtk.Notebook, _: *gtk.Widget, page_number: c_uint, self: *View) callconv(.c) void {
        if (self.filling or page_number == 2) return;
        if (self.service.draft.text) |json| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            if (model.parse(arena.allocator(), json)) |_| self.fill() else |_| self.message.setText("Advanced JSON is invalid. Correct it before using the form.");
        }
    }
    fn applied(_: *gtk.Button, self: *View) callconv(.c) void {
        const json = self.service.draft.text orelse return;
        _ = json;
        self.service.applyDraft(self.draft_serial, self.revision) catch |err| {
            self.service.err = err;
            self.update();
        };
    }
    fn merged(_: *gtk.Button, self: *View) callconv(.c) void {
        self.filling = true;
        defer self.filling = false;
        self.service.mergeDraft(self.draft_serial) catch |err| {
            self.message.setText(if (err == error.MergeConflict) "The same field changed in both versions. Draft retained; review Advanced before discarding or resolving it." else "Cannot merge this draft. Correct its JSON and try again.");
            return;
        };
        self.fill();
        self.update();
    }
    fn discarded(_: *gtk.Button, self: *View) callconv(.c) void {
        self.filling = true;
        self.service.discardDraft(self.draft_serial) catch {
            self.filling = false;
            self.message.setText("The shared draft changed. Reopen settings before discarding it.");
            return;
        };
        self.filling = false;
        self.local_error = null;
        self.fill();
        self.update();
    }
    pub fn probe(self: *View, window: *gtk.Window) void {
        const focused = window.getFocus() orelse return;
        var name: []const u8 = "settings-other";
        for (self.entries, [_][]const u8{ "settings-gtk-name", "settings-seed", "settings-wallpaper", "settings-color", "settings-font" }) |e, n| if (focused == e.as(gtk.Widget) or focused.isAncestor(e.as(gtk.Widget)) != 0) {
            name = n;
        };
        if (focused == self.apply_button.as(gtk.Widget)) name = "settings-apply";
        if (focused == self.wallpaper_button.as(gtk.Widget)) name = "settings-wallpaper-choose";
        if (focused == self.greeter_sync.button.as(gtk.Widget)) name = "settings-greeter-sync";
        if (focused == self.merge_button.as(gtk.Widget)) name = "settings-merge";
        const prior = std.mem.sliceTo(&self.last_probe, 0);
        if (!std.mem.eql(u8, prior, name)) {
            @memset(&self.last_probe, 0);
            @memcpy(self.last_probe[0..name.len], name);
            std.log.info("event=session-focus target={s}", .{name});
        }
    }
};
fn text(entry_widget: *gtk.Entry) []const u8 {
    return std.mem.span(entry_widget.as(gtk.Editable).getText());
}
fn page(notebook: *gtk.Notebook, title: [*:0]const u8) *gtk.Box {
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    const box = w.column(14);
    box.as(gtk.Widget).setMarginTop(16);
    box.as(gtk.Widget).setMarginBottom(16);
    box.as(gtk.Widget).setMarginStart(12);
    box.as(gtk.Widget).setMarginEnd(12);
    scroll.setChild(box.as(gtk.Widget));
    _ = notebook.appendPage(scroll.as(gtk.Widget), gtk.Label.new(title).as(gtk.Widget));
    return box;
}
fn entry(box: *gtk.Box, title: [*:0]const u8, placeholder: [*:0]const u8) *gtk.Entry {
    const e = gtk.Entry.new();
    e.setMaxLength(1024);
    e.setPlaceholderText(placeholder);
    w.name(e.as(gtk.Widget), title);
    box.append(w.section(w.label(title, null), null, e.as(gtk.Widget)).as(gtk.Widget));
    return e;
}
fn dropdown(box: *gtk.Box, title: [*:0]const u8, choices: []const [*:0]const u8) *gtk.DropDown {
    var strings: [16]?[*:0]const u8 = @splat(null);
    for (choices, 0..) |choice, i| strings[i] = choice;
    const d = gtk.DropDown.newFromStrings(@ptrCast(&strings));
    w.name(d.as(gtk.Widget), title);
    box.append(w.section(w.label(title, null), null, d.as(gtk.Widget)).as(gtk.Widget));
    return d;
}
fn spin(box: *gtk.Box, title: [*:0]const u8, min: f64, max: f64) *gtk.SpinButton {
    const s = gtk.SpinButton.newWithRange(min, max, 1);
    w.name(s.as(gtk.Widget), title);
    box.append(w.section(w.label(title, null), null, s.as(gtk.Widget)).as(gtk.Widget));
    return s;
}
