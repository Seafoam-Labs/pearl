//! Application profile draft controls; catalog/render/write authority stays in
//! the backend. Unavailable saved IDs remain selectable and are never replaced.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const profiles = @import("../theme/matugen_profiles.zig");
const a = std.heap.c_allocator;
const Choice = struct { id: []const u8, name: []const u8, application: profiles.Application, origin: []const u8 };
pub const View = struct {
    editor: *@import("editor.zig").Editor,
    root: *gtk.Box,
    enabled: *gtk.Switch,
    source: *gtk.DropDown,
    seed: *gtk.Entry,
    search: *gtk.Entry,
    rows: [5]*gtk.Box,
    modes: [5]*gtk.DropDown,
    pickers: [5]*gtk.DropDown,
    ids: [5][]const []const u8 = @splat(&.{}),
    status: *gtk.Label,
    arena: std.heap.ArenaAllocator = .init(a),
    catalog_arena: std.heap.ArenaAllocator = .init(a),
    choices: std.ArrayList(Choice) = .empty,
    revision: []const u8 = "",
    next: ?u16 = null,
    requested: bool = false,
    generation: u64 = 0,
    seen: ?[]u8 = null,
    seen_serial: u64 = 0,
    fresh: bool = true,
    shown: ?[]u8 = null,
    filling: bool = false,
    review_label: *gtk.Label = undefined,
    install_button: *gtk.Button = undefined,
    review_digest: @import("../services/policy.zig").Text(65) = .{},
    review_revision: u64 = 0,
    review_seen: ?[]u8 = null,
    pub fn create(host: *gtk.Box, editor: *@import("editor.zig").Editor) !*View {
        const self = try a.create(View);
        const root = w.column(8);
        root.as(gtk.Widget).addCssClass("settings-card");
        host.append(root.as(gtk.Widget));
        root.append(w.label("Application themes · Matugen profiles", "pearl-card-title").as(gtk.Widget));
        const enabled = gtk.Switch.new();
        enabled.as(gtk.Widget).setHalign(.start);
        add(root, "Enable application themes", enabled.as(gtk.Widget));
        const source = dropdown(&.{ "Follow Pearl", "Independent seed", "Wallpaper" });
        add(root, "Application colors", source.as(gtk.Widget));
        const seed = gtk.Entry.new();
        seed.setPlaceholderText("#6750a4");
        seed.setMaxLength(7);
        add(root, "Application seed", seed.as(gtk.Widget));
        const search = gtk.Entry.new();
        search.setPlaceholderText("Search applications");
        root.append(search.as(gtk.Widget));
        self.* = .{ .editor = editor, .root = root, .enabled = enabled, .source = source, .seed = seed, .search = search, .rows = undefined, .modes = undefined, .pickers = undefined, .status = w.label("", "pearl-secondary") };
        for (std.enums.values(profiles.Application), 0..) |application, i| {
            const row = w.column(6);
            self.rows[i] = row;
            root.append(row.as(gtk.Widget));
            row.append(w.label(@tagName(application), "settings-row-title").as(gtk.Widget));
            self.modes[i] = dropdown(&.{ "Follow Pearl theme", "Choose profile", "Off" });
            self.pickers[i] = dropdown(&.{"No profile selected"});
            var label: [96]u8 = undefined;
            w.name(self.modes[i].as(gtk.Widget), try std.fmt.bufPrintZ(&label, "{s} theme assignment", .{@tagName(application)}));
            w.name(self.pickers[i].as(gtk.Widget), try std.fmt.bufPrintZ(&label, "{s} application profile", .{@tagName(application)}));
            row.append(self.modes[i].as(gtk.Widget));
            row.append(self.pickers[i].as(gtk.Widget));
            _ = object.Object.signals.notify.connect(self.modes[i].as(object.Object), *View, changed, self, .{ .detail = "selected" });
            _ = object.Object.signals.notify.connect(self.pickers[i].as(object.Object), *View, changed, self, .{ .detail = "selected" });
        }
        root.append(w.label("Zed and Equibop need activation in the application. Fluxer and Steam use the generated CSS. Starship generates a full prompt configuration; review it before installing. Off restores only unchanged Pearl-owned files.", "pearl-secondary").as(gtk.Widget));
        const refresh = w.wrappingButton("Refresh application profiles");
        root.append(refresh.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(refresh, *View, refreshClicked, self, .{});
        const adopt = w.wrappingButton("Use current profile versions on Apply");
        root.append(adopt.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(adopt, *View, adoptClicked, self, .{});
        const retry = w.wrappingButton("Retry committed application themes");
        root.append(retry.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(retry, *View, retryClicked, self, .{});
        const review = w.wrappingButton("Review Starship installation");
        root.append(review.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(review, *View, reviewClicked, self, .{});
        self.review_label = w.label("", "pearl-secondary");
        self.review_label.setSelectable(1);
        self.review_label.setWrap(1);
        root.append(self.review_label.as(gtk.Widget));
        self.install_button = w.wrappingButton("Install reviewed Starship configuration and keep backup");
        self.install_button.as(gtk.Widget).setSensitive(0);
        root.append(self.install_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.install_button, *View, installClicked, self, .{});
        self.status.setWrap(1);
        root.append(self.status.as(gtk.Widget));
        _ = object.Object.signals.notify.connect(enabled.as(object.Object), *View, changed, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(source.as(object.Object), *View, changed, self, .{ .detail = "selected" });
        _ = gtk.Editable.signals.changed.connect(seed.as(gtk.Editable), *View, edited, self, .{});
        _ = gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *View, searched, self, .{});
        return self;
    }
    fn add(root: *gtk.Box, title: [:0]const u8, control: *gtk.Widget) void {
        root.append(w.label(title, "settings-row-title").as(gtk.Widget));
        root.append(control);
        w.name(control, title);
    }
    fn dropdown(choices: []const [*:0]const u8) *gtk.DropDown {
        var strings: [4]?[*:0]const u8 = @splat(null);
        for (choices, 0..) |choice, i| strings[i] = choice;
        return gtk.DropDown.newFromStrings(@ptrCast(&strings));
    }
    pub fn destroy(self: *View) void {
        if (self.review_seen) |v| a.free(v);
        if (self.seen) |v| a.free(v);
        if (self.shown) |v| a.free(v);
        self.arena.deinit();
        self.catalog_arena.deinit();
        a.destroy(self);
    }
    fn refreshClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.requested = false;
        self.update();
    }
    fn retryClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        var buffer: [20]u8 = undefined;
        self.editor.themeCommand(.{ .action = .application_retry, .revision = std.fmt.bufPrint(&buffer, "{d}", .{self.editor.state.revision}) catch unreachable }) catch |err| self.status.setText(@errorName(err));
    }
    fn reviewClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.review_revision = self.editor.state.revision;
        self.review_digest.set("");
        var buffer: [20]u8 = undefined;
        self.editor.themeCommand(.{ .action = .application_review, .revision = std.fmt.bufPrint(&buffer, "{d}", .{self.review_revision}) catch unreachable }) catch |err| self.status.setText(@errorName(err));
    }
    fn installClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.review_digest.len == 0 or self.review_revision != self.editor.state.revision) return;
        var buffer: [20]u8 = undefined;
        self.editor.themeCommand(.{ .action = .application_install, .revision = std.fmt.bufPrint(&buffer, "{d}", .{self.review_revision}) catch unreachable, .id = self.review_digest.slice() }) catch |err| self.status.setText(@errorName(err));
        self.review_digest.set("");
    }
    fn searched(_: *gtk.Editable, self: *View) callconv(.c) void {
        const query = std.mem.span(self.search.as(gtk.Editable).getText());
        for (self.rows, std.enums.values(profiles.Application)) |row, app| row.as(gtk.Widget).setVisible(@intFromBool(query.len == 0 or std.ascii.indexOfIgnoreCase(@tagName(app), query) != null));
    }
    fn adoptClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.edit(true) catch |err| self.status.setText(@errorName(err));
    }
    fn changed(widget: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        var adopt = false;
        for (self.modes, self.pickers) |mode, picker| if (widget == mode.as(object.Object) or widget == picker.as(object.Object)) {
            adopt = true;
        };
        self.edit(adopt) catch |err| self.status.setText(@errorName(err));
    }
    fn edited(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.edit(false) catch |err| self.status.setText(@errorName(err));
    }
    fn edit(self: *View, adopt: bool) !void {
        if (self.filling or !self.editor.editable()) return;
        var memory = std.heap.ArenaAllocator.init(a);
        defer memory.deinit();
        const alloc = memory.allocator();
        var p = try @import("../config/preferences.zig").parse(alloc, self.editor.text());
        p.matugen.enabled = self.enabled.getActive() != 0;
        p.matugen.colors.source = switch (self.source.getSelected()) {
            1 => .seed,
            2 => .wallpaper,
            else => .follow_pearl,
        };
        const seed = std.mem.span(self.seed.as(gtk.Editable).getText());
        if (!@import("../config/preferences.zig").hex(seed)) return;
        p.matugen.colors.seed = seed;
        p.matugen.snapshot_digest = "";
        if (adopt or p.matugen.catalog_revision.len == 0) p.matugen.catalog_revision = self.revision;
        for (std.enums.values(profiles.Application), 0..) |app, i| {
            const old = p.matugen.applications.map.get(@tagName(app)) orelse profiles.Selection{};
            const selected = self.pickers[i].getSelected();
            const id = if (selected < self.ids[i].len and self.ids[i][selected].len > 0) self.ids[i][selected] else old.profile_id;
            const choice: profiles.Selection = .{ .mode = switch (self.modes[i].getSelected()) {
                1 => .profile,
                2 => .off,
                else => .theme,
            }, .profile_id = id };
            self.pickers[i].as(gtk.Widget).setSensitive(@intFromBool(choice.mode == .profile));
            if (choice.mode == .profile and id.len == 0) return error.ProfileSelectionRequired;
            try p.matugen.applications.map.put(alloc, @tagName(app), choice);
        }
        try self.editor.edit(try std.json.Stringify.valueAlloc(alloc, p, .{ .whitespace = .indent_2 }));
    }
    pub fn update(self: *View) void {
        self.root.as(gtk.Widget).setVisible(@intFromBool(self.editor.client.capabilities.application_profiles));
        if (!self.editor.client.capabilities.application_profiles) return;
        if (self.editor.application_review) |bytes| if (self.review_seen == null or !std.mem.eql(u8, self.review_seen.?, bytes)) {
            self.showReview(bytes) catch |err| self.status.setText(@errorName(err));
            if (self.review_seen) |v| a.free(v);
            self.review_seen = a.dupe(u8, bytes) catch null;
        };
        self.install_button.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable() and !self.editor.theme_busy and self.review_digest.len > 0 and self.review_revision == self.editor.state.revision));
        if (self.generation != self.editor.theme_catalog_generation) {
            self.generation = self.editor.theme_catalog_generation;
            self.requested = false;
        }
        if (self.editor.profile_result) |bytes| {
            if (self.seen_serial != self.editor.profile_serial) {
                self.seen_serial = self.editor.profile_serial;
                if (self.fresh) {
                    _ = self.catalog_arena.reset(.free_all);
                    self.choices = .empty;
                    self.revision = "";
                    self.fresh = false;
                }
                self.consume(bytes) catch |err| self.status.setText(@errorName(err));
                if (self.seen) |old| a.free(old);
                self.seen = a.dupe(u8, bytes) catch null;
                if (self.shown) |old| a.free(old);
                self.shown = null;
            }
        }
        if (!self.editor.theme_busy and self.editor.editable() and (!self.requested or self.next != null)) {
            const fresh = !self.requested;
            self.editor.themeCommand(.{ .action = .profiles_catalog, .offset = if (fresh) 0 else self.next orelse 0, .revision = if (fresh) "" else self.revision }) catch return;
            self.fresh = fresh;
            self.next = null;
            self.requested = true;
        }
        const text = self.editor.text();
        if (self.shown == null or !std.mem.eql(u8, self.shown.?, text)) self.fill(text) catch |err| self.status.setText(@errorName(err));
        self.enabled.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        self.status.setText(if (self.editor.application_command and self.editor.theme_error.len > 0) self.editor.theme_error.z() else self.editor.application_summary.z());
    }
    fn showReview(self: *View, bytes: []const u8) !void {
        var memory = std.heap.ArenaAllocator.init(a);
        defer memory.deinit();
        const alloc = memory.allocator();
        const Review = struct { digest: []const u8, current: []const u8, proposed: []const u8, profile: []const u8, destination: []const u8 };
        const result = try std.json.parseFromSliceLeaky(struct { application_review: Review }, alloc, bytes, .{});
        self.review_digest.set(result.application_review.digest);
        self.review_label.setText(try std.fmt.allocPrintSentinel(alloc, "{s}\nCurrent configuration:\n{s}\nProposed configuration:\n{s}", .{ result.application_review.destination, result.application_review.current, result.application_review.proposed }, 0));
    }
    fn consume(self: *View, bytes: []const u8) !void {
        const alloc = self.catalog_arena.allocator();
        const Entry = struct { descriptor: struct { id: []const u8, name: []const u8, application: profiles.Application }, origin: []const u8 };
        const Page = struct { entries: []const Entry, revision: []const u8, next_offset: ?u16 };
        const page = try std.json.parseFromSliceLeaky(Page, alloc, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        if (self.choices.items.len + page.entries.len > 256) return error.ProfileCatalogLimit;
        self.revision = page.revision;
        self.next = page.next_offset;
        for (page.entries) |entry| try self.choices.append(alloc, .{ .id = entry.descriptor.id, .name = entry.descriptor.name, .application = entry.descriptor.application, .origin = entry.origin });
    }
    fn fill(self: *View, text: []const u8) !void {
        self.filling = true;
        defer self.filling = false;
        _ = self.arena.reset(.free_all);
        const alloc = self.arena.allocator();
        const p = try @import("../config/preferences.zig").parse(alloc, text);
        self.enabled.setActive(@intFromBool(p.matugen.enabled));
        self.source.setSelected(switch (p.matugen.colors.source) {
            .follow_pearl => 0,
            .seed => 1,
            .wallpaper => 2,
        });
        self.seed.as(gtk.Editable).setText(try alloc.dupeZ(u8, p.matugen.colors.seed));
        for (std.enums.values(profiles.Application), 0..) |app, i| {
            const choice = p.matugen.applications.map.get(@tagName(app)) orelse profiles.Selection{};
            self.modes[i].setSelected(switch (choice.mode) {
                .theme => 0,
                .profile => 1,
                .off => 2,
            });
            const names = gtk.StringList.new(null);
            defer names.unref();
            var ids: std.ArrayList([]const u8) = .empty;
            try ids.append(alloc, "");
            names.append("No profile selected");
            var index: u32 = 0;
            for (self.choices.items) |profile| if (profile.application == app) {
                if (std.mem.eql(u8, choice.profile_id, profile.id)) index = @intCast(ids.items.len);
                try ids.append(alloc, try alloc.dupe(u8, profile.id));
                names.append(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ profile.name, profile.origin }, 0));
            };
            if (choice.profile_id.len > 0 and index == 0) {
                index = @intCast(ids.items.len);
                try ids.append(alloc, choice.profile_id);
                names.append(try std.fmt.allocPrintSentinel(alloc, "{s} · unavailable", .{choice.profile_id}, 0));
            }
            self.ids[i] = ids.items;
            self.pickers[i].setModel(names.as(@import("gio2").ListModel));
            self.pickers[i].setSelected(index);
            self.pickers[i].as(gtk.Widget).setSensitive(@intFromBool(choice.mode == .profile and self.editor.editable()));
        }
        if (self.shown) |old| a.free(old);
        self.shown = try a.dupe(u8, text);
    }
};
