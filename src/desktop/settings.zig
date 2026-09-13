//! Drafts belong to the service, so closing a popup or receiving an external edit
//! never discards them. Apply uses the revision captured when editing began.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const glib = @import("glib2");
const Service = @import("../config/service.zig").Service;
const model = @import("../config/preferences.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    service: *Service,
    host: *gtk.Box,
    arena: std.heap.ArenaAllocator,
    base: model.Preferences = .{},
    revision: u64 = 0,
    filling: bool = true,
    mode: *gtk.DropDown,
    variant: *gtk.DropDown,
    source: *gtk.DropDown,
    fit: *gtk.DropDown,
    density: *gtk.DropDown,
    edge: *gtk.DropDown,
    placement: *gtk.DropDown,
    entries: [7]*gtk.Entry,
    font_size: *gtk.SpinButton,
    bar_size: *gtk.SpinButton,
    motion: *gtk.CheckButton,
    outside: *gtk.CheckButton,
    raw: *gtk.TextBuffer,
    message: *gtk.Label,
    apply_button: *gtk.Button,
    last_probe: [48]u8 = @splat(0),
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
        self.* = .{ .service = service, .host = host, .arena = std.heap.ArenaAllocator.init(a), .mode = dropdown(appearance, "Theme", &.{ "Material · static", "Material · dynamic", "GTK theme" }), .variant = dropdown(appearance, "Color variant", &.{ "Dark", "Light" }), .source = dropdown(appearance, "Dynamic colors from", &.{ "Seed color", "Wallpaper" }), .fit = undefined, .density = undefined, .edge = undefined, .placement = undefined, .entries = undefined, .font_size = undefined, .bar_size = undefined, .motion = undefined, .outside = undefined, .raw = undefined, .message = undefined, .apply_button = undefined };
        const hints = w.label("GTK theme: leave the name empty to follow the system. Installed themes must support GTK4. Dynamic colors use optional matugen 4.x.", "pearl-secondary");
        appearance.append(hints.as(gtk.Widget));
        self.entries[0] = entry(appearance, "GTK theme name", "System default");
        self.entries[1] = entry(appearance, "Seed color", "#6750a4");
        self.entries[2] = entry(appearance, "Wallpaper image", "Absolute PNG or JPEG path");
        self.fit = dropdown(appearance, "Wallpaper fit", &.{ "Material gradient", "Solid color", "Cover", "Contain" });
        self.entries[3] = entry(appearance, "Background color", "#141218");
        self.entries[4] = entry(appearance, "Font family", "System default / Material fallback");
        self.font_size = spin(appearance, "Font size", 10, 24);
        self.density = dropdown(appearance, "Density", &.{ "Comfortable", "Compact" });
        self.motion = gtk.CheckButton.newWithLabel("Reduce motion");
        appearance.append(self.motion.as(gtk.Widget));
        bar.append(w.label("Default layout for every output. Connector overrides are available in Advanced.", "pearl-secondary").as(gtk.Widget));
        self.entries[5] = entry(bar, "Left widgets", "launcher,workspaces,title");
        self.entries[6] = entry(bar, "Right widgets", "media,tray,audio,network,battery,notifications,keyboard,control");
        bar.append(w.label("The center group, per-output layouts and export templates can be edited in Advanced. Widget names are comma-separated; launcher is required.", "pearl-secondary").as(gtk.Widget));
        self.edge = dropdown(bar, "Bar edge", &.{ "Top", "Right", "Bottom", "Left" });
        self.bar_size = spin(bar, "Bar minimum size", 32, 160);
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
        self.apply_button = gtk.Button.newWithLabel("Apply & save");
        self.apply_button.as(gtk.Widget).addCssClass("pearl-primary");
        actions.append(self.apply_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(discard, *View, discarded, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.apply_button, *View, applied, self, .{});
        for (self.entries) |e| _ = gtk.Editable.signals.changed.connect(e.as(gtk.Editable), *View, edited, self, .{});
        for ([_]*gtk.DropDown{ self.mode, self.variant, self.source, self.fit, self.density, self.edge, self.placement }) |d| _ = object.Object.signals.notify.connect(d.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        for ([_]*gtk.SpinButton{ self.font_size, self.bar_size }) |s| _ = gtk.SpinButton.signals.value_changed.connect(s, *View, spun, self, .{});
        for ([_]*gtk.CheckButton{ self.motion, self.outside }) |c| _ = gtk.CheckButton.signals.toggled.connect(c, *View, toggled, self, .{});
        _ = gtk.TextBuffer.signals.changed.connect(self.raw, *View, rawEdited, self, .{});
        _ = gtk.Notebook.signals.switch_page.connect(notebook,*View,switched,self,.{});
        self.fill();
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        // Disconnect through parent destruction before freeing callback data.
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        self.arena.deinit();
        a.destroy(self);
    }
    fn fill(self: *View) void {
        self.filling = true;
        defer self.filling = false;
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        const json = self.service.draft orelse (std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{ .whitespace = .indent_2 }) catch "{}");
        self.base = model.parse(alloc, json) catch self.service.prefs();
        self.revision = if (self.service.draft != null) self.service.draft_revision else self.service.revision;
        const p = self.base;
        for (self.entries, [_][]const u8{ p.theme.gtk_name, p.theme.seed, p.wallpaper.path, p.wallpaper.color, p.font, p.bar.groups.left, p.bar.groups.right }) |e, value| e.as(gtk.Editable).setText(alloc.dupeZ(u8, value) catch "");
        self.mode.setSelected(@intFromEnum(p.theme.mode));
        self.variant.setSelected(@intFromEnum(p.theme.variant));
        self.source.setSelected(@intFromEnum(p.theme.source));
        self.fit.setSelected(@intFromEnum(p.wallpaper.mode));
        self.density.setSelected(@intFromEnum(p.density));
        self.edge.setSelected(@intFromEnum(p.bar.edge));
        self.placement.setSelected(@intFromEnum(p.popup.placement));
        self.font_size.setValue(@floatFromInt(p.font_size));
        self.bar_size.setValue(@floatFromInt(p.bar.size));
        self.motion.setActive(@intFromBool(p.reduced_motion));
        self.outside.setActive(@intFromBool(p.popup.dismiss_outside));
        self.raw.setText(alloc.dupeZ(u8, json) catch "{}", @intCast(json.len));
    }
    fn saveForm(self: *View) void {
        if (self.filling) return;
        var p = self.base;
        p.theme.mode = @enumFromInt(self.mode.getSelected());
        p.theme.variant = @enumFromInt(self.variant.getSelected());
        p.theme.source = @enumFromInt(self.source.getSelected());
        p.wallpaper.mode = @enumFromInt(self.fit.getSelected());
        p.density = @enumFromInt(self.density.getSelected());
        p.bar.edge = @enumFromInt(self.edge.getSelected());
        p.popup.placement = @enumFromInt(self.placement.getSelected());
        p.theme.gtk_name = text(self.entries[0]);
        p.theme.seed = text(self.entries[1]);
        p.wallpaper.path = text(self.entries[2]);
        p.wallpaper.color = text(self.entries[3]);
        p.font = text(self.entries[4]);
        p.bar.groups.left = text(self.entries[5]);
        p.bar.groups.right = text(self.entries[6]);
        p.font_size = @intCast(self.font_size.getValueAsInt());
        p.bar.size = @intCast(self.bar_size.getValueAsInt());
        p.reduced_motion = self.motion.getActive() != 0;
        p.popup.dismiss_outside = self.outside.getActive() != 0;
        const json = std.json.Stringify.valueAlloc(a, p, .{ .whitespace = .indent_2 }) catch return;
        defer a.free(json);
        self.service.keepDraft(json, self.revision);
        const z = a.dupeZ(u8, json) catch return;
        defer a.free(z);
        self.filling = true;
        self.raw.setText(z, @intCast(json.len));
        self.filling = false;
        self.update();
    }
    pub fn update(self: *View) void {
        if (self.service.draft == null and self.revision != self.service.revision) self.fill();
        const busy = self.service.job != null or self.service.pending_reload;
        const conflict = self.service.draft != null and self.revision != self.service.revision;
        self.apply_button.as(gtk.Widget).setSensitive(@intFromBool(!busy and !conflict and self.service.draft != null));
        var buffer: [256]u8 = undefined;
        const message = if (busy) "Preparing settings…" else if (conflict) "Settings changed externally. Your draft is retained. Copy it from Advanced before discarding or merging the external change." else if (self.service.err) |err| std.fmt.bufPrintZ(&buffer, "Could not apply: {s}. Your draft and working appearance are retained.", .{@errorName(err)}) catch "Could not apply settings." else if (self.service.export_error) |err| std.fmt.bufPrintZ(&buffer, "Settings saved. Export needs attention: {s}", .{@errorName(err)}) catch "Export failed." else if (self.service.draft != null) "Unsaved draft" else "Settings are up to date.";
        self.message.setText(message);
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
        self.service.keepDraft(std.mem.span(json), self.revision);
        self.update();
    }
    fn switched(_: *gtk.Notebook, _: *gtk.Widget, page_number: c_uint, self: *View) callconv(.c) void {
        if (page_number == 2) return;
        if (self.service.draft) |json| {
            var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit();
            if (model.parse(arena.allocator(),json)) |_| self.fill() else |_| self.message.setText("Advanced JSON is invalid. Correct it before using the form.");
        }
    }
    fn applied(_: *gtk.Button, self: *View) callconv(.c) void {
        const json = self.service.draft orelse return;
        self.service.apply(json, self.revision) catch |err| {
            self.service.err = err;
            self.update();
        };
    }
    fn discarded(_: *gtk.Button, self: *View) callconv(.c) void {
        self.service.discardDraft();
        self.fill();
        self.update();
    }
    pub fn probe(self: *View, window: *gtk.Window) void {
        const focused = window.getFocus() orelse return;
        var name: []const u8 = "settings-other";
        for (self.entries, [_][]const u8{ "settings-gtk-name", "settings-seed", "settings-wallpaper", "settings-color", "settings-font", "settings-left", "settings-right" }) |e, n| if (focused == e.as(gtk.Widget) or focused.isAncestor(e.as(gtk.Widget)) != 0) {
            name = n;
        };
        if (focused == self.apply_button.as(gtk.Widget)) name = "settings-apply";
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
