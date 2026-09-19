//! Community theme browser; all discovery, downloads and writes belong to backend jobs.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const Editor = @import("editor.zig").Editor;
const cmd = @import("../theme/commands.zig");
const a = std.heap.c_allocator;
const Kind = enum { installed, installed_next, community, next, source_select, source_add, source_remove, source_default, import_archive, cancel, defaults, builtin, inherit_colors, default_style, select, colors, style, preview, preview_draft, install, remove, rollback };
const Action = struct { owner: *View, kind: Kind, index: usize = 0 };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
pub const View = struct {
    editor: *Editor,
    root: *gtk.Box,
    list: *gtk.Box,
    status: *gtk.Label,
    selection: *gtk.Label = undefined,
    search: *gtk.Entry,
    source_id: *gtk.Entry,
    source_name: *gtk.Entry,
    source_url: *gtk.Entry,
    archive_path: *gtk.Entry,
    preview_root: *gtk.Box,
    provider: *gtk.CssProvider,
    arena: std.heap.ArenaAllocator,
    rows: std.heap.ArenaAllocator,
    catalog_data: std.heap.ArenaAllocator = .init(a),
    page_data: std.heap.ArenaAllocator = .init(a),
    navigation_data: std.heap.ArenaAllocator = .init(a),
    sources: []const @import("../theme/repository.zig").Source = &.{},
    catalog_generation: u64 = 0,
    automatic_refresh: bool = false,
    controls: std.ArrayList(Control) = .empty,
    row_controls: std.ArrayList(Control) = .empty,
    entries: []const cmd.Entry = &.{},
    ids: []const []const u8 = &.{},
    next_offset: ?u16 = null,
    releases: []const @import("../theme/repository.zig").Release = &.{},
    revision: []const u8 = "",
    next_url: []const u8 = "",
    current_url: []const u8 = "",
    current_source: []const u8 = "",
    seen: ?[]u8 = null,
    last: @FieldType(cmd.Request, "action") = .catalog,
    initialized: bool = false,
    community: bool = false,
    draft_selection: bool = false,
    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        const root = w.column(10);
        root.as(gtk.Widget).addCssClass("pearl-card");
        host.append(root.as(gtk.Widget));
        const list = w.column(8);
        const status = w.label("", "pearl-secondary");
        self.* = .{ .editor = editor, .root = root, .list = list, .status = status, .search = gtk.Entry.new(), .source_id = gtk.Entry.new(), .source_name = gtk.Entry.new(), .source_url = gtk.Entry.new(), .archive_path = gtk.Entry.new(), .preview_root = w.column(8), .provider = gtk.CssProvider.new(), .arena = .init(a), .rows = .init(a) };
        root.append(w.label("Community themes", "pearl-card-title").as(gtk.Widget));
        self.selection = w.label("", "pearl-secondary");
        root.append(self.selection.as(gtk.Widget));
        root.append(w.label("Download a community theme, choose Use theme, then Apply & save. Preview shows a sample without selecting it. Use colors and Use style let you mix themes.", "pearl-secondary").as(gtk.Widget));
        const actions = w.column(8);
        root.append(actions.as(gtk.Widget));
        try self.button(actions, "Installed", .installed, 0, false);
        try self.button(actions, "Community · refresh", .community, 0, false);
        if (@import("../theme/repository.zig").default_enabled) try self.button(actions, "Add default community repository", .source_default, 0, false);
        try self.button(actions, "Cancel download", .cancel, 0, false);
        try self.button(root, "Use built-in theme", .builtin, 0, false);
        try self.button(root, "Use selected theme defaults", .defaults, 0, false);
        try self.button(root, "Colors · use selected theme", .inherit_colors, 0, false);
        try self.button(root, "Widget style · use Pearl default", .default_style, 0, false);
        try self.button(root, "Preview current draft", .preview_draft, 0, false);
        self.search.setPlaceholderText("Search names or authors");
        w.name(self.search.as(gtk.Widget), "Search community themes");
        root.append(self.search.as(gtk.Widget));
        _ = gtk.Editable.signals.changed.connect(self.search.as(gtk.Editable), *View, searched, self, .{});
        const sources = gtk.Expander.new(null);
        sources.setLabelWidget(w.label("Community repositories and local archives", null).as(gtk.Widget));
        const box = w.column(8);
        sources.setChild(box.as(gtk.Widget));
        root.append(sources.as(gtk.Widget));
        for ([_]*gtk.Entry{ self.source_id, self.source_name, self.source_url, self.archive_path }, [_][:0]const u8{ "Repository ID", "Repository name", "GitHub repository or HTTPS index URL", "Local .tar.gz archive path" }) |control, title| {
            control.setPlaceholderText(title);
            w.name(control.as(gtk.Widget), title);
            box.append(control.as(gtk.Widget));
        }
        const source_actions = w.row(8);
        box.append(source_actions.as(gtk.Widget));
        try self.button(source_actions, "Add repository", .source_add, 0, false);
        try self.button(source_actions, "Remove repository", .source_remove, 0, false);
        try self.button(box, "Import local archive", .import_archive, 0, false);
        root.append(status.as(gtk.Widget));
        root.append(list.as(gtk.Widget));
        self.preview_root.as(gtk.Widget).addCssClass("pearl-root");
        self.preview_root.as(gtk.Widget).addCssClass("pearl-theme-preview");
        self.preview_root.as(gtk.Widget).setVisible(0);
        self.preview_root.append(w.label("Theme preview", "pearl-card-title").as(gtk.Widget));
        const sample = w.column(8);
        sample.as(gtk.Widget).addCssClass("pearl-card");
        sample.append(w.label("Sample card", "pearl-card-title").as(gtk.Widget));
        sample.append(w.wrappingButton("Example button").as(gtk.Widget));
        const disabled = w.wrappingButton("Disabled button");
        disabled.as(gtk.Widget).setSensitive(0);
        sample.append(disabled.as(gtk.Widget));
        self.preview_root.append(sample.as(gtk.Widget));
        root.append(self.preview_root.as(gtk.Widget));
        gtk.StyleContext.addProviderForDisplay(root.as(gtk.Widget).getDisplay(), self.provider.as(gtk.StyleProvider), 602);
        return self;
    }
    fn button(self: *View, host: *gtk.Box, label: [:0]const u8, kind: Kind, index: usize, row: bool) !void {
        const data = try (if (row) self.rows.allocator() else self.arena.allocator()).create(Action);
        data.* = .{ .owner = self, .kind = kind, .index = index };
        const button_ = w.wrappingButton(label);
        const alloc = if (row) self.rows.allocator() else self.arena.allocator();
        try (if (row) &self.row_controls else &self.controls).append(alloc, .{
            .id = try std.fmt.allocPrint(alloc, "themes.{s}.{d}", .{ @tagName(kind), index }),
            .widget = button_.as(gtk.Widget),
        });
        host.append(button_.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(button_, *Action, clicked, data, .{});
    }
    pub fn destroy(self: *View) void {
        gtk.StyleContext.removeProviderForDisplay(self.root.as(gtk.Widget).getDisplay(), self.provider.as(gtk.StyleProvider));
        self.provider.unref();
        if (self.seen) |s| a.free(s);
        self.rows.deinit();
        self.catalog_data.deinit();
        self.page_data.deinit();
        self.navigation_data.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
    fn entry(e: *gtk.Entry) []const u8 {
        return std.mem.span(e.as(gtk.Editable).getText());
    }
    fn send(self: *View, request: cmd.Request) !void {
        try self.editor.themeCommand(request);
        if (self.seen) |bytes| a.free(bytes);
        self.seen = null;
        self.last = request.action;
        self.status.setText("Working…");
    }
    fn clicked(_: *gtk.Button, action: *Action) callconv(.c) void {
        const self = action.owner;
        self.perform(action.kind, action.index) catch |err| self.status.setText(@errorName(err));
    }
    fn perform(self: *View, kind: Kind, index: usize) !void {
        self.automatic_refresh = false;
        switch (kind) {
            .source_default => try self.send(.{ .action = .source_default }),
            .installed => try self.send(.{ .action = .catalog }),
            .installed_next => try self.send(.{ .action = .catalog, .offset = self.next_offset orelse return, .revision = self.revision }),
            .community, .next => {
                const id = if (kind == .next) self.current_source else entry(self.source_id);
                if (id.len == 0) return error.AddOrSelectRepositoryFirst;
                const url = if (kind == .next) self.next_url else "";
                var next_data = std.heap.ArenaAllocator.init(a);
                errdefer next_data.deinit();
                const next_source = try next_data.allocator().dupe(u8, id);
                const next_url = try next_data.allocator().dupe(u8, url);
                try self.send(.{ .action = .refresh, .id = id, .url = url });
                self.navigation_data.deinit();
                self.navigation_data = next_data;
                self.current_source = next_source;
                self.current_url = next_url;
            },
            .source_select => {
                const source = self.sources[index];
                var memory = std.heap.ArenaAllocator.init(a);
                defer memory.deinit();
                self.source_id.as(gtk.Editable).setText(try memory.allocator().dupeZ(u8, source.id));
                self.source_name.as(gtk.Editable).setText(try memory.allocator().dupeZ(u8, source.name));
                self.source_url.as(gtk.Editable).setText(try memory.allocator().dupeZ(u8, source.url));
                try self.perform(.community, 0);
            },
            .source_add => try self.send(.{ .action = .source_add, .id = entry(self.source_id), .name = entry(self.source_name), .url = entry(self.source_url) }),
            .source_remove => try self.send(.{ .action = .source_remove, .id = entry(self.source_id) }),
            .import_archive => try self.send(.{ .action = .import_archive, .path = entry(self.archive_path) }),
            .cancel => self.editor.cancelTheme(),
            .preview_draft => {
                var memory = std.heap.ArenaAllocator.init(a);
                defer memory.deinit();
                const p = try @import("../config/preferences.zig").parse(memory.allocator(), self.editor.text());
                try self.send(.{ .action = .preview_render, .theme = p.theme, .wallpaper = p.wallpaper });
            },
            .install => {
                const r = self.releases[index];
                try self.send(.{ .action = .install, .repository = self.current_source, .url = self.current_url, .id = r.id, .version = r.version, .sha256 = r.sha256 });
            },
            .remove, .rollback => try self.send(.{ .action = if (kind == .remove) .remove else .rollback, .id = self.entries[index].id }),
            .select, .colors, .style, .preview, .defaults, .builtin, .inherit_colors, .default_style => {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const alloc = arena.allocator();
                var p = try @import("../config/preferences.zig").parse(alloc, self.editor.text());
                if (kind == .builtin) {
                    p.theme.mode = .static;
                    p.theme.package_id = "";
                    p.theme.palette_id = "";
                    p.theme.style_id = "";
                    p.theme.catalog_revision = "";
                } else if (kind == .defaults) {
                    p.theme.palette_id = "";
                    p.theme.style_id = "";
                    p.theme.catalog_revision = self.revision;
                } else if (kind == .inherit_colors) {
                    p.theme.palette_id = "";
                    p.theme.mode = if (p.theme.package_id.len > 0) .package else .static;
                    p.theme.catalog_revision = self.revision;
                } else if (kind == .default_style) {
                    p.theme.style_id = "pearl.default";
                    p.theme.catalog_revision = self.revision;
                } else {
                    const e = self.entries[index];
                    p.theme.catalog_revision = self.revision;
                    if (kind == .style) {
                        p.theme.style_id = e.id;
                        if (p.theme.mode == .gtk) p.theme.mode = .static;
                    } else if (kind == .colors) {
                        p.theme.palette_id = e.id;
                        p.theme.mode = .package;
                    } else {
                        // A whole-theme selection replaces separate overrides.
                        // Style-only packages retain the effective color source.
                        if (e.dark or e.light) {
                            p.theme.palette_id = "";
                            p.theme.mode = .package;
                        } else if (p.theme.mode == .package and p.theme.palette_id.len == 0) {
                            p.theme.palette_id = p.theme.package_id;
                        } else if (p.theme.mode == .gtk) p.theme.mode = .static;
                        p.theme.package_id = e.id;
                        p.theme.style_id = "";
                    }
                }
                if (kind == .preview) {
                    try self.send(.{ .action = .preview_render, .theme = p.theme, .wallpaper = p.wallpaper });
                    return;
                }
                p.theme.snapshot_digest = "";
                try self.editor.edit(try std.json.Stringify.valueAlloc(alloc, p, .{ .whitespace = .indent_2 }));
                self.draft_selection = true;
                self.status.setText("Theme selection is in the draft. Use Apply & save to activate it.");
            },
        }
    }
    fn searched(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.render() catch |err| self.status.setText(@errorName(err));
    }
    fn matches(self: *View, name: []const u8, author: []const u8) bool {
        const query = entry(self.search);
        return query.len == 0 or std.ascii.indexOfIgnoreCase(name, query) != null or std.ascii.indexOfIgnoreCase(author, query) != null;
    }
    fn render(self: *View) !void {
        while (self.list.as(gtk.Widget).getFirstChild()) |child| self.list.remove(child);
        self.rows.deinit();
        self.rows = .init(a);
        self.row_controls = .empty;
        const alloc = self.rows.allocator();
        if (self.community) {
            for (self.releases, 0..) |r, i| {
                if (!self.matches(r.name, r.author)) continue;
                const box = w.column(4);
                self.list.append(box.as(gtk.Widget));
                box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s} · {s}", .{ r.name, r.version, r.author }, 0), "pearl-card-title").as(gtk.Widget));
                if (r.description.len > 0) box.append(w.label(try alloc.dupeZ(u8, r.description), "pearl-secondary").as(gtk.Widget));
                box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ r.license, r.source }, 0), "pearl-secondary").as(gtk.Widget));
                if (!r.requires.supported()) box.append(w.label("Requires an unsupported theme API", "pearl-secondary").as(gtk.Widget)) else try self.button(box, "Download / update", .install, i, true);
            }
            if (self.next_url.len > 0) try self.button(self.list, "Next repository page", .next, 0, true);
        } else {
            for (self.sources, 0..) |source, i| try self.button(self.list, try std.fmt.allocPrintSentinel(alloc, "Browse {s}", .{source.name}, 0), .source_select, i, true);
            for (self.entries, 0..) |e, i| {
                if (!self.matches(e.name, e.author)) continue;
                const box = w.column(4);
                self.list.append(box.as(gtk.Widget));
                box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s} · {s}", .{ e.name, e.version, e.author }, 0), "pearl-card-title").as(gtk.Widget));
                if (e.error_code) |code| {
                    box.append(w.label(try alloc.dupeZ(u8, code), "pearl-secondary").as(gtk.Widget));
                    continue;
                }
                box.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s}{s}{s}", .{ if (e.dark) "Dark " else "", if (e.light) "Light " else "", if (e.style) "Widget style" else "Palette" }, 0), "pearl-secondary").as(gtk.Widget));
                const buttons = w.row(4);
                box.append(buttons.as(gtk.Widget));
                try self.button(buttons, "Use theme", .select, i, true);
                if (e.dark or e.light) try self.button(buttons, "Use colors", .colors, i, true);
                if (e.style) try self.button(buttons, "Use style", .style, i, true);
                try self.button(box, "Preview", .preview, i, true);
                const manage = w.row(4);
                box.append(manage.as(gtk.Widget));
                try self.button(manage, "Remove installed package", .remove, i, true);
                try self.button(manage, "Roll back installed version", .rollback, i, true);
            }
            if (self.next_offset != null) try self.button(self.list, "More installed themes", .installed_next, 0, true);
        }
    }
    pub fn update(self: *View) void {
        self.updateSelection();
        defer self.refreshCatalog();
        for ([_][]const Control{ self.controls.items, self.row_controls.items }) |bindings| for (bindings) |binding| {
            const cancel = std.mem.startsWith(u8, binding.id, "themes.cancel.");
            binding.widget.setSensitive(@intFromBool(if (cancel) self.editor.theme_busy else self.editor.editable() and !self.editor.theme_busy));
        };
        if (self.draft_selection and self.editor.local == null and !self.editor.state.dirty and !self.editor.state.busy) {
            self.draft_selection = false;
            self.status.setText("Selection matches saved preferences.");
        }
        if (!self.initialized and self.editor.editable() and self.editor.client.capabilities.community_themes) {
            self.send(.{ .action = .catalog }) catch return;
            self.initialized = true;
        }
        if (self.editor.theme_busy) {
            if (!self.editor.application_command) self.status.setText(self.editor.theme_progress.z());
            return;
        }
        if (self.editor.theme_error.len > 0 and !self.editor.application_command) {
            self.status.setText(self.editor.theme_error.z());
            return;
        }
        const bytes = self.editor.theme_result orelse return;
        if (self.seen) |s| if (std.mem.eql(u8, s, bytes)) return;
        if (self.seen) |s| a.free(s);
        self.seen = a.dupe(u8, bytes) catch return;
        self.consume(bytes) catch |err| {
            self.render() catch {};
            self.status.setText(@errorName(err));
        };
    }
    fn refreshCatalog(self: *View) void {
        if (!self.initialized or self.catalog_generation == self.editor.theme_catalog_generation or self.editor.theme_busy or !self.editor.editable()) return;
        self.send(.{ .action = .catalog }) catch return;
        self.automatic_refresh = true;
        self.catalog_generation = self.editor.theme_catalog_generation;
        self.preview_root.as(gtk.Widget).setVisible(0);
        self.status.setText("Installed themes changed. Preview again before applying changed selections.");
    }
    fn updateSelection(self: *View) void {
        var memory = std.heap.ArenaAllocator.init(a);
        defer memory.deinit();
        const alloc = memory.allocator();
        const preferences = @import("../config/preferences.zig").parse(alloc, self.editor.text()) catch return;
        const p = preferences.theme;
        const colors = if (p.mode != .package) @tagName(p.mode) else if (p.palette_id.len > 0) p.palette_id else p.package_id;
        const style_id = if (p.mode == .gtk) "GTK" else if (p.style_id.len > 0) p.style_id else if (p.package_id.len > 0) p.package_id else "pearl.default";
        var missing = false;
        for ([_][]const u8{ p.package_id, if (p.mode == .package) p.palette_id else "", p.style_id }) |id| {
            if (id.len == 0 or std.mem.eql(u8, id, "pearl.default")) continue;
            var found = false;
            for (self.ids) |item| if (std.mem.eql(u8, item, id)) {
                found = true;
                break;
            };
            if (!found) missing = true;
        }
        self.selection.setText(std.fmt.allocPrintSentinel(alloc, "Colors: {s} · Widget style: {s}{s}", .{ colors, style_id, if (missing) " · Selection unavailable in the installed catalog" else "" }, 0) catch return);
    }
    fn consume(self: *View, bytes: []const u8) !void {
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        switch (self.last) {
            .catalog => {
                _ = self.catalog_data.reset(.free_all);
                self.entries = &.{};
                self.ids = &.{};
                self.next_offset = null;
                self.sources = &.{};
                self.revision = "";
                const alloc = self.catalog_data.allocator();
                const Result = struct { entries: []const cmd.Entry, ids: []const []const u8, next_offset: ?u16, diagnostics: []const @import("../theme/catalog.zig").Diagnostic, diagnostic_count: usize, revision: []const u8, sources: []const @import("../theme/repository.zig").Source };
                const result = try std.json.parseFromSliceLeaky(Result, alloc, bytes, .{ .allocate = .alloc_always });
                self.entries = result.entries;
                self.ids = result.ids;
                self.next_offset = result.next_offset;
                self.sources = result.sources;
                self.revision = result.revision;
                if (!self.automatic_refresh) self.community = false;
                if (result.sources.len > 0 and entry(self.source_id).len == 0) {
                    self.source_id.as(gtk.Editable).setText(try alloc.dupeZ(u8, result.sources[0].id));
                    self.source_name.as(gtk.Editable).setText(try alloc.dupeZ(u8, result.sources[0].name));
                    self.source_url.as(gtk.Editable).setText(try alloc.dupeZ(u8, result.sources[0].url));
                }
                self.status.setText(if (result.diagnostics.len > 0) try std.fmt.allocPrintSentinel(alloc, "Package unavailable: {s} ({s})", .{ result.diagnostics[0].path, result.diagnostics[0].error_code }, 0) else if (result.entries.len == 0) "No themes installed. Choose Community · refresh to browse themes." else "Installed themes. Choose colors and widget style, then Apply & save.");
                try self.render();
                if (self.editor.theme_discovery_degraded) self.status.setText("Automatic discovery is degraded. Use Installed to refresh available themes.");
            },
            .refresh => {
                _ = self.page_data.reset(.free_all);
                self.releases = &.{};
                self.next_url = "";
                const alloc = self.page_data.allocator();
                const page = try std.json.parseFromSliceLeaky(@import("../theme/repository.zig").Page, alloc, bytes, .{ .allocate = .alloc_always });
                self.releases = page.index.releases;
                self.next_url = page.index.next orelse "";
                self.community = true;
                self.status.setText(if (page.offline) "Offline · showing cached repository metadata" else "Community repository · download before selecting a theme");
                try self.render();
            },
            .preview, .preview_render => {
                const alloc = temporary.allocator();
                const resolved = try std.json.parseFromSliceLeaky(@import("../theme/resolve.zig").Resolved, alloc, bytes, .{ .allocate = .alloc_always });
                const theme = @import("../theme/theme.zig");
                const p = resolved.palette orelse theme.dark;
                const tokens = try @import("../theme/style.zig").tokenCss(alloc, resolved.tokens, true);
                const template = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ @embedFile("settings_base_style"), tokens, resolved.css });
                self.provider.loadFromString(try theme.scopedCss(alloc, template, "pearl-theme-preview", p));
                self.preview_root.as(gtk.Widget).setVisible(1);
                self.status.setText(if (resolved.palette == null) "Style preview uses default dark colors; generated colors apply on save." else "Preview only · committed appearance is unchanged. To select a package, choose Use theme, then Apply & save.");
            },
            .install, .import_archive, .remove, .rollback, .source_add, .source_remove, .source_default => try self.send(.{ .action = .catalog }),
            else => self.status.setText("Operation complete."),
        }
    }
};
