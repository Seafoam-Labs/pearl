//! File authoring UI. Only backend theme jobs read/write author files.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const gio = @import("gio2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const model = @import("../theme/palette_model.zig");
const cmd = @import("../theme/commands.zig");
const a = std.heap.c_allocator;
const Kind = enum { create, duplicate, save, discard, import_file, open, export_file };
const Action = struct { owner: *View, kind: Kind };
pub const View = struct {
    root: *gtk.Box,
    context: *anyopaque,
    send: *const fn (*anyopaque, cmd.Request) anyerror!void,
    slug: *gtk.Entry,
    title: *gtk.Entry,
    variant: *gtk.DropDown,
    colors: [3]*gtk.Entry,
    buffer: *gtk.TextBuffer,
    status: *gtk.Label,
    details: *gtk.Label,
    provider: *gtk.CssProvider,
    import_path: *gtk.Entry,
    output: *gtk.Entry,
    metadata: *gtk.Entry,
    memory: std.heap.ArenaAllocator = .init(a),
    actions: std.heap.ArenaAllocator = .init(a),
    saved: []const u8 = @import("../theme/palette_file.zig").starter,
    path: []const u8 = "",
    expected: []const u8 = "",
    filling: bool = false,
    controls: std.ArrayList(struct { id: []const u8, widget: *gtk.Widget }) = .empty,
    pub fn create(host: *gtk.Box, context: *anyopaque, send: *const fn (*anyopaque, cmd.Request) anyerror!void) !*View {
        const self = try a.create(View);
        self.* = .{ .root = w.column(10), .context = context, .send = send, .slug = gtk.Entry.new(), .title = gtk.Entry.new(), .variant = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ "Dark", "Light" })), .colors = .{ gtk.Entry.new(), gtk.Entry.new(), gtk.Entry.new() }, .buffer = gtk.TextBuffer.new(null), .status = w.label("Create a palette or choose Edit colors on a local palette.", "pearl-secondary"), .details = w.label("", "pearl-secondary"), .provider = gtk.CssProvider.new(), .import_path = gtk.Entry.new(), .output = gtk.Entry.new(), .metadata = gtk.Entry.new() };
        const expander = gtk.Expander.new("Create and edit palettes");
        expander.setChild(self.root.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        self.root.append(w.label("Save writes this palette file. Saved edits to an active local palette apply live. Select a new palette in the list, then Apply & save.", "pearl-secondary").as(gtk.Widget));
        for ([_]*gtk.Entry{ self.slug, self.title }, [_][:0]const u8{ "Filename (for example meadow)", "Palette display name" }) |entry, label| {
            self.root.append(w.label(label, null).as(gtk.Widget));
            w.name(entry.as(gtk.Widget), label);
            self.root.append(entry.as(gtk.Widget));
        }
        self.slug.as(gtk.Editable).setText("meadow");
        self.title.as(gtk.Editable).setText("Meadow");
        try self.addControl("slug", self.slug.as(gtk.Widget));
        try self.addControl("name", self.title.as(gtk.Widget));
        try self.addControl("expander", expander.getLabelWidget().?);
        const actions = w.row(6);
        self.root.append(actions.as(gtk.Widget));
        try self.button(actions, "Create", .create);
        try self.button(actions, "Duplicate", .duplicate);
        try self.button(actions, "Save palette", .save);
        try self.button(actions, "Discard palette edits", .discard);
        try self.button(actions, "Open file", .open);
        w.name(self.variant.as(gtk.Widget), "Palette variant");
        self.root.append(self.variant.as(gtk.Widget));
        try self.addControl("variant", self.variant.as(gtk.Widget));
        for (self.colors, [_][:0]const u8{ "Background · surface", "Text · on_surface", "Accent · primary" }) |entry, label| {
            self.root.append(w.label(label, null).as(gtk.Widget));
            w.name(entry.as(gtk.Widget), label);
            entry.setPlaceholderText("#RRGGBB");
            self.root.append(entry.as(gtk.Widget));
            _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *View, coreChanged, self, .{});
        }
        const advanced = gtk.Expander.new("Advanced colors and terminal palette · JSON");
        for (self.colors, [_][]const u8{ "surface", "on_surface", "primary" }) |entry_, role| try self.addControl(role, entry_.as(gtk.Widget));
        const editor = gtk.TextView.newWithBuffer(self.buffer);
        editor.setMonospace(1);
        editor.setWrapMode(.word_char);
        w.name(editor.as(gtk.Widget), "Palette JSON");
        try self.addControl("json", editor.as(gtk.Widget));
        const scroller = gtk.ScrolledWindow.new();
        scroller.setMinContentHeight(220);
        scroller.setChild(editor.as(gtk.Widget));
        advanced.setChild(scroller.as(gtk.Widget));
        self.root.append(advanced.as(gtk.Widget));
        self.root.append(self.status.as(gtk.Widget));
        self.root.append(self.details.as(gtk.Widget));
        const sample = w.card();
        sample.as(gtk.Widget).addCssClass("pearl-root");
        sample.as(gtk.Widget).addCssClass("pearl-palette-editor-preview");
        sample.append(w.label("Palette preview", "pearl-card-title").as(gtk.Widget));
        sample.append(w.label("Body text", "pearl-secondary").as(gtk.Widget));
        const accent = w.wrappingButton("Accent button");
        accent.as(gtk.Widget).addCssClass("pearl-primary");
        sample.append(accent.as(gtk.Widget));
        const disabled = w.wrappingButton("Disabled");
        disabled.as(gtk.Widget).setSensitive(0);
        sample.append(disabled.as(gtk.Widget));
        const sample_entry = gtk.Entry.new();
        sample_entry.setPlaceholderText("Focus this entry");
        sample.append(sample_entry.as(gtk.Widget));
        sample.append(w.label("Example error message", "pearl-error").as(gtk.Widget));
        self.root.append(sample.as(gtk.Widget));
        const imports = gtk.Expander.new("Import and export");
        const box = w.column(8);
        imports.setChild(box.as(gtk.Widget));
        self.root.append(imports.as(gtk.Widget));
        for ([_]*gtk.Entry{ self.import_path, self.output, self.metadata }, [_][:0]const u8{ "Palette JSON to import (absolute path)", "New export package directory", "Publication metadata JSON (absolute path)" }) |entry, label| {
            entry.setPlaceholderText(label);
            w.name(entry.as(gtk.Widget), label);
            box.append(entry.as(gtk.Widget));
        }
        try self.button(box, "Import palette", .import_file);
        try self.button(box, "Export package", .export_file);
        gtk.StyleContext.addProviderForDisplay(self.root.as(gtk.Widget).getDisplay(), self.provider.as(gtk.StyleProvider), 602);
        _ = gtk.TextBuffer.signals.changed.connect(self.buffer, *View, jsonChanged, self, .{});
        _ = gtk.Editable.signals.changed.connect(self.title.as(gtk.Editable), *View, coreChanged, self, .{});
        _ = object.Object.signals.notify.connect(self.variant.as(object.Object), *View, variantChanged, self, .{ .detail = "selected" });
        self.setBuffer(self.saved);
        self.fill();
        self.preview();
        return self;
    }
    fn button(self: *View, host: *gtk.Box, label: [:0]const u8, kind: Kind) !void {
        const action = try self.actions.allocator().create(Action);
        action.* = .{ .owner = self, .kind = kind };
        const button_ = w.wrappingButton(label);
        try self.addControl(@tagName(kind), button_.as(gtk.Widget));
        host.append(button_.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(button_, *Action, clicked, action, .{});
    }
    fn addControl(self: *View, id: []const u8, widget: *gtk.Widget) !void {
        const alloc = self.actions.allocator();
        try self.controls.append(alloc, .{ .id = try std.fmt.allocPrint(alloc, "palettes.{s}", .{id}), .widget = widget });
    }
    pub fn destroy(self: *View) void {
        gtk.StyleContext.removeProviderForDisplay(self.root.as(gtk.Widget).getDisplay(), self.provider.as(gtk.StyleProvider));
        self.provider.unref();
        self.buffer.unref();
        self.memory.deinit();
        self.actions.deinit();
        a.destroy(self);
    }
    fn text(self: *View) [*:0]u8 {
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        self.buffer.getBounds(&start, &end);
        return self.buffer.getText(&start, &end, 0);
    }
    fn entryText(control: *gtk.Entry) []const u8 {
        return std.mem.span(control.as(gtk.Editable).getText());
    }
    fn setBuffer(self: *View, bytes: []const u8) void {
        self.filling = true;
        defer self.filling = false;
        const terminated = a.dupeZ(u8, bytes) catch return;
        defer a.free(terminated);
        self.buffer.setText(terminated, @intCast(bytes.len));
    }
    fn fill(self: *View) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const raw = self.text();
        defer glib.free(raw);
        const source = @import("../theme/package_model.zig").parse(model.Source, alloc, std.mem.span(raw), model.max_bytes) catch return;
        var d: model.Diagnostic = .{};
        const normalized = model.parse(alloc, std.mem.span(raw), &d) catch return;
        const selected = if (self.variant.getSelected() == 1) normalized.light orelse normalized.dark.? else normalized.dark orelse normalized.light.?;
        self.filling = true;
        defer self.filling = false;
        self.title.as(gtk.Editable).setText(alloc.dupeZ(u8, source.name) catch return);
        for (self.colors, [_][]const u8{ "surface", "on_surface", "primary" }) |entry_, role| entry_.as(gtk.Editable).setText(alloc.dupeZ(u8, model.get(selected, role)) catch return);
    }
    fn preview(self: *View) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const raw = self.text();
        defer glib.free(raw);
        var d: model.Diagnostic = .{};
        const doc = @import("../theme/palette_resolver.zig").compile(alloc, std.mem.span(raw), &d) catch |err| {
            self.status.setText(std.fmt.allocPrintSentinel(alloc, "{s}: {s} ({s}){s}{s}", .{ d.path, d.code, @errorName(err), if (d.suggested.len > 0) " · Suggested foreground: " else "", d.suggested }, 0) catch return);
            if (d.ratio) |ratio| self.details.setText(std.fmt.allocPrintSentinel(alloc, "Foreground {s} on {s}: {d:.2}:1 contrast; required {d:.1}:1.", .{ d.value, d.background, ratio, d.required orelse 4.5 }, 0) catch return);
            return;
        };
        const palette = if (self.variant.getSelected() == 1) doc.light else doc.dark;
        const template = std.fmt.allocPrint(alloc, "{s}\n{s}\n.pearl-root.$scope.pearl-card {{ background: $surface$; color: $text$; }}", .{ @embedFile("settings_base_style"), @import("../theme/palette_resolver.zig").shellCss(alloc, doc, self.variant.getSelected() == 1) catch return }) catch return;
        self.provider.loadFromString(@import("../theme/theme.zig").scopedCss(alloc, template, "pearl-palette-editor-preview", palette) catch return);
        self.status.setText("Valid palette · preview only until Save palette.");
        const authored = if (self.variant.getSelected() == 1) doc.source.light orelse doc.source.dark.? else doc.source.dark orelse doc.source.light.?;
        self.details.setText(std.fmt.allocPrintSentinel(alloc, "Resolved backgrounds: {s}, {s}, {s} · Text on accent: {s} ({s}) · Secondary text: {s} ({s}){s}", .{ palette.low, palette.container, palette.high, palette.on_primary, if (authored.object.contains("on_primary")) "authored" else "derived", palette.secondary, if (authored.object.contains("on_surface_variant")) "authored" else "derived", if (doc.source.light == null or doc.source.dark == null) " · One variant supplies both modes" else "" }, 0) catch return);
    }
    fn jsonChanged(_: *gtk.TextBuffer, self: *View) callconv(.c) void {
        if (!self.filling) {
            self.fill();
            self.preview();
        }
    }
    fn variantChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (!self.filling) {
            self.fill();
            self.preview();
        }
    }
    fn coreChanged(_: *gtk.Editable, self: *View) callconv(.c) void {
        if (self.filling) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const raw = self.text();
        defer glib.free(raw);
        var source = @import("../theme/package_model.zig").parse(model.Source, alloc, std.mem.span(raw), model.max_bytes) catch return;
        const light = self.variant.getSelected() == 1;
        const selected_colors = if (light) source.light orelse source.dark orelse model.object() else source.dark orelse source.light orelse model.object();
        var colors = std.json.parseFromSliceLeaky(std.json.Value, alloc, std.json.Stringify.valueAlloc(alloc, selected_colors, .{}) catch return, .{}) catch return;
        if (colors != .object) return;
        for ([_][]const u8{ "mSurface", "mOnSurface", "mPrimary" }) |alias| _ = colors.object.swapRemove(alias);
        for (self.colors, [_][]const u8{ "surface", "on_surface", "primary" }) |entry_, role| model.set(alloc, &colors, role, entryText(entry_)) catch return;
        source.name = entryText(self.title);
        if (light) source.light = colors else source.dark = colors;
        self.setBuffer(std.json.Stringify.valueAlloc(alloc, source, .{ .whitespace = .indent_2 }) catch return);
        self.preview();
    }
    fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
        action.owner.perform(action.kind) catch |err| action.owner.status.setText(@errorName(err));
    }
    fn perform(self: *View, kind: Kind) !void {
        const raw = self.text();
        defer glib.free(raw);
        switch (kind) {
            .create, .duplicate => try self.send(self.context, .{ .action = .palette_init, .name = entryText(self.slug), .contents = std.mem.span(raw) }),
            .save => {
                if (self.path.len == 0) return error.CreateOrLoadPaletteFirst;
                const basename = std.fs.path.basename(self.path);
                if (!std.mem.eql(u8, entryText(self.slug), basename[0 .. basename.len - 5])) return error.UseDuplicateForNewFilename;
                try self.send(self.context, .{ .action = .palette_write, .name = entryText(self.slug), .contents = std.mem.span(raw), .expected = self.expected });
            },
            .discard => {
                self.setBuffer(self.saved);
                self.fill();
                self.preview();
            },
            .import_file => try self.send(self.context, .{ .action = .palette_import, .path = entryText(self.import_path), .name = entryText(self.slug) }),
            .export_file => {
                if (self.path.len == 0) return error.CreateOrLoadPaletteFirst;
                try self.send(self.context, .{ .action = .palette_export, .path = self.path, .output = entryText(self.output), .metadata_path = entryText(self.metadata) });
            },
            .open => {
                if (self.path.len == 0) return error.CreateOrLoadPaletteFirst;
                const path = try a.dupeZ(u8, self.path);
                defer a.free(path);
                const file = gio.File.newForPath(path);
                defer file.unref();
                const uri = file.getUri();
                defer glib.free(uri);
                if (gio.AppInfo.launchDefaultForUri(uri, null, null) == 0) return error.FileEditorUnavailable;
            },
        }
    }
    pub fn consume(self: *View, bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{});
        if (value.object.get("valid")) |valid| if (!valid.bool) {
            const d = value.object.get("diagnostic").?;
            self.status.setText(try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ d.object.get("path").?.string, d.object.get("code").?.string }, 0));
            return;
        };
        const source = value.object.get("source") orelse {
            self.status.setText("Package exported.");
            return;
        };
        _ = self.memory.reset(.free_all);
        const retained = self.memory.allocator();
        self.path = try retained.dupe(u8, value.object.get("path").?.string);
        self.expected = try retained.dupe(u8, value.object.get("expected").?.string);
        self.saved = try std.json.Stringify.valueAlloc(retained, source, .{ .whitespace = .indent_2 });
        const basename = std.fs.path.basename(self.path);
        self.slug.as(gtk.Editable).setText(try alloc.dupeZ(u8, basename[0 .. basename.len - 5]));
        self.setBuffer(self.saved);
        self.fill();
        self.preview();
        self.status.setText("Palette file saved or loaded. Select it in the palette list to use it; active local palettes update on Save.");
    }
};
