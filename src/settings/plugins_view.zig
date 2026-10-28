//! Plugin management belongs exclusively to the full Settings application.
const std = @import("std");
const gtk = @import("gtk4");
const object = @import("gobject2");
const ui = @import("live_protocol.zig");
const m = @import("../plugins/model.zig");
const prefs = @import("../config/preferences.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const builder = @import("rule_builder.zig");
const a = std.heap.c_allocator;
const Action = enum { approve, bar, retry, preview, reset };
const Row = struct {
    view: *View,
    arena: std.heap.ArenaAllocator,
    card: *gtk.Box,
    details: *gtk.Revealer,
    expand: *gtk.ToggleButton,
    signals: std.ArrayList(struct { value: *object.Object, id: c_ulong }) = .empty,
    permissions_edited: bool = false,
    actions: [5]*gtk.Button = undefined,
    info: ui.PluginInfo,
    status: *gtk.Label,
    diagnostics: *gtk.Label,
    diagnostic_expander: *gtk.ToggleButton,
    diagnostic_details: *gtk.Revealer,
    placement_details: *gtk.Box,
    notice: *gtk.Label,
    config: *gtk.Box,
    attention: bool = false,
    available: bool = true,
    enabled: *gtk.Switch,
    activity: *gtk.Switch,
    overlay: *gtk.Switch,
    mode: *gtk.DropDown,
    output: *gtk.Entry,
    x: *gtk.SpinButton,
    y: *gtk.SpinButton,
    width: *gtk.SpinButton,
    height: *gtk.SpinButton,
    interactive: *gtk.Switch,
    locked: *gtk.Switch,
    fullscreen: *gtk.Switch,
    values: []*gtk.Widget,
    fn track(self: *Row, value: *object.Object, id: c_ulong) void {
        self.signals.append(a, .{ .value = value, .id = id }) catch object.signalHandlerDisconnect(value, id);
    }
    fn destroy(self: *Row) void {
        if (self.view.review_row == self) self.view.closeReview(false);
        for (self.signals.items) |signal| object.signalHandlerDisconnect(signal.value, signal.id);
        self.signals.deinit(a);
        self.view.content.remove(self.card.as(gtk.Widget));
        self.arena.deinit();
        a.destroy(self);
    }
};
const Button = struct { row: *Row, action: Action };
pub const View = struct {
    context: *anyopaque,
    invalidate: *const fn (*anyopaque, @import("../desktop/settings_navigation.zig").Route) void,
    host: *gtk.Box,
    editor: *Editor,
    summary: *gtk.Label,
    content: *gtk.Box,
    rows: std.ArrayList(*Row) = .empty,
    filling: bool = false,
    editing: bool = false,
    refresh: *gtk.Button,
    refresh_signal: c_ulong = 0,
    next: *gtk.Button,
    previous: *gtk.Button,
    next_signal: c_ulong = 0,
    previous_signal: c_ulong = 0,
    search: *gtk.SearchEntry,
    filter: *gtk.DropDown,
    empty: *gtk.Label,
    discovery: *gtk.Label,
    discovery_issue: *gtk.Label,
    search_signal: c_ulong = 0,
    filter_signal: c_ulong = 0,
    next_offset: u64 = 0,
    review: ?*gtk.Dialog = null,
    review_row: ?*Row = null,
    review_activity: ?*gtk.CheckButton = null,
    review_overlay: ?*gtk.CheckButton = null,
    review_error: ?*gtk.Label = null,
    review_controls: std.ArrayList(builder.Control) = .empty,
    pub fn create(host: *gtk.Box, editor: *Editor, context: *anyopaque, invalidate: @FieldType(View, "invalidate")) !*View {
        const self = try a.create(View);
        const hero = w.column(8);
        hero.as(gtk.Widget).addCssClass("settings-card");
        hero.as(gtk.Widget).addCssClass("plugins-hero");
        const hero_layout = w.flow(2);
        hero_layout.setHomogeneous(1);
        const scene = w.column(12);
        scene.as(gtk.Widget).addCssClass("plugins-scene");
        const bar = w.row(12);
        bar.append(w.label(@import("i18n").dtr("pearl", "●  1  2"), "plugins-mini-surface").as(gtk.Widget));
        const timer = w.label(@import("i18n").dtr("pearl", "◷ 00:42"), "plugins-mini-selection");
        timer.as(gtk.Widget).setHexpand(0);
        bar.append(timer.as(gtk.Widget));
        scene.append(bar.as(gtk.Widget));
        const sample = w.column(6);
        sample.as(gtk.Widget).addCssClass("plugins-mini-window");
        sample.as(gtk.Widget).setHalign(.center);
        sample.as(gtk.Widget).setSizeRequest(120, 55);
        sample.append(w.label(@import("i18n").dtr("pearl", "Sample window"), "appearance-mini-title").as(gtk.Widget));
        sample.append(w.label(@import("i18n").dtr("pearl", "Aa     +1"), "plugins-mini-selection").as(gtk.Widget));
        scene.append(sample.as(gtk.Widget));
        const dock = w.label(@import("i18n").dtr("pearl", "▪ ▪ ▪ ▪"), "plugins-mini-surface");
        dock.as(gtk.Widget).setHalign(.center);
        scene.append(dock.as(gtk.Widget));
        hero_layout.insert(scene.as(gtk.Widget), -1);
        const copy = w.column(8);
        copy.as(gtk.Widget).setValign(.center);
        const title = w.label(@import("i18n").dtr("pearl", "At home in your bar. Or out on your desktop."), "pearl-section-title");
        title.setMaxWidthChars(28);
        copy.append(title.as(gtk.Widget));
        const description = w.label(@import("i18n").dtr("pearl", "Enable a widget, choose its place, and give it only the permissions it needs."), "pearl-secondary");
        description.setMaxWidthChars(32);
        copy.append(description.as(gtk.Widget));
        copy.append(w.label(@import("i18n").dtr("pearl", "Illustrative layout · Experimental plugins"), "pearl-secondary").as(gtk.Widget));
        hero_layout.insert(copy.as(gtk.Widget), -1);
        hero.append(hero_layout.as(gtk.Widget));
        host.append(hero.as(gtk.Widget));
        const heading = w.flow(2);
        heading.setHomogeneous(0);
        const labels = w.column(4);
        labels.append(w.label(@import("i18n").dtr("pearl", "Installed plugins"), "pearl-section-title").as(gtk.Widget));
        const summary = w.label(@import("i18n").dtr("pearl", "Discovering plugins…"), "pearl-secondary");
        labels.append(summary.as(gtk.Widget));
        heading.insert(labels.as(gtk.Widget), -1);
        const refresh = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Refresh plugins"));
        refresh.as(gtk.Widget).setHalign(.end);
        refresh.as(gtk.Widget).setValign(.center);
        heading.insert(refresh.as(gtk.Widget), -1);
        host.append(heading.as(gtk.Widget));
        const discovery_issue = w.label("", "pearl-secondary");
        discovery_issue.as(gtk.Widget).addCssClass("pearl-error");
        discovery_issue.as(gtk.Widget).setVisible(0);
        host.append(discovery_issue.as(gtk.Widget));
        const filters = w.flow(2);
        filters.setHomogeneous(0);
        const search = gtk.SearchEntry.new();
        search.setPlaceholderText(@import("i18n").dtr("pearl", "Find a plugin on this page…"));
        search.as(gtk.Editable).setWidthChars(16);
        w.name(search.as(gtk.Widget), @import("i18n").dtr("pearl", "Find a plugin on this page"));
        filters.insert(search.as(gtk.Widget), -1);
        const filter = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ @import("i18n").dtr("pearl", "All on this page"), @import("i18n").dtr("pearl", "Enabled in draft"), @import("i18n").dtr("pearl", "Needs attention") }));
        w.name(filter.as(gtk.Widget), @import("i18n").dtr("pearl", "Filter plugins on this page"));
        filters.insert(filter.as(gtk.Widget), -1);
        host.append(filters.as(gtk.Widget));
        const content = w.column(16);
        host.append(content.as(gtk.Widget));
        const empty = w.label("", "pearl-secondary");
        host.append(empty.as(gtk.Widget));
        const controls = w.flow(2);
        controls.setHomogeneous(0);
        host.append(controls.as(gtk.Widget));
        const previous = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "First page"));
        controls.insert(previous.as(gtk.Widget), -1);
        const next = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Next page"));
        controls.insert(next.as(gtk.Widget), -1);
        const discovery_section = gtk.Expander.new("Plugin discovery");
        discovery_section.as(gtk.Widget).addCssClass("settings-card");
        discovery_section.as(gtk.Widget).addCssClass("plugins-discovery");
        const discovery = w.label("", "pearl-secondary");
        discovery.setSelectable(1);
        discovery_section.setChild(discovery.as(gtk.Widget));
        host.append(discovery_section.as(gtk.Widget));
        host.append(w.label(@import("i18n").dtr("pearl", "Review and approve packages before enabling them. Apply & save saves all Pearl preferences. Refresh, Retry and Preview act immediately using saved settings."), "pearl-secondary").as(gtk.Widget));
        self.* = .{ .context = context, .invalidate = invalidate, .host = host, .editor = editor, .summary = summary, .content = content, .refresh = refresh, .next = next, .previous = previous, .search = search, .filter = filter, .empty = empty, .discovery = discovery, .discovery_issue = discovery_issue };
        self.refresh_signal = gtk.Button.signals.clicked.connect(refresh, *View, refreshPlugins, self, .{});
        self.previous_signal = gtk.Button.signals.clicked.connect(previous, *View, first, self, .{});
        self.next_signal = gtk.Button.signals.clicked.connect(next, *View, more, self, .{});
        self.search_signal = gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *View, searched, self, .{});
        self.filter_signal = object.Object.signals.notify.connect(filter.as(object.Object), *View, filtered, self, .{ .detail = "selected" });
        return self;
    }
    fn refreshPlugins(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.liveAction(.@"plugin.refresh", .{ .object = .empty }) catch |err| self.report(err);
    }
    fn first(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.livePage(0);
    }
    fn more(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.livePage(self.next_offset);
    }
    fn searched(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.filterRows();
    }
    fn filtered(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.filterRows();
    }
    fn filterRows(self: *View) void {
        const query = std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " \t\r\n");
        var count: usize = 0;
        for (self.rows.items) |row| {
            const matches = (std.ascii.findIgnoreCase(row.info.name, query) != null or std.ascii.findIgnoreCase(row.info.id, query) != null) and switch (self.filter.getSelected()) {
                1 => row.enabled.getActive() != 0,
                2 => row.attention,
                else => true,
            };
            row.card.as(gtk.Widget).setVisible(@intFromBool(matches));
            count += @intFromBool(matches);
        }
        self.empty.setText(if (self.rows.items.len == 0) @import("i18n").dtr("pearl", "No plugins on this page. Install a complete package in a plugin folder, then refresh. Use First page to return to the start.") else @import("i18n").dtr("pearl", "No matching plugins on this page. Clear your search or choose another filter or page."));
        self.empty.as(gtk.Widget).setVisible(@intFromBool(count == 0));
    }
    fn clear(self: *View) void {
        self.invalidate(self.context, .plugins);
        for (self.rows.items) |row| row.destroy();
        self.rows.clearRetainingCapacity();
    }
    pub fn destroy(self: *View) void {
        // Host widgets are destroyed immediately after this view by Window.
        object.signalHandlerDisconnect(self.next.as(object.Object), self.next_signal);
        object.signalHandlerDisconnect(self.previous.as(object.Object), self.previous_signal);
        object.signalHandlerDisconnect(self.refresh.as(object.Object), self.refresh_signal);
        object.signalHandlerDisconnect(self.search.as(object.Object), self.search_signal);
        object.signalHandlerDisconnect(self.filter.as(object.Object), self.filter_signal);
        self.closeReview(false);
        self.review_controls.deinit(a);
        self.clear();
        self.rows.deinit(a);
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        if (self.editor.target.page != .plugins or !self.editor.online or self.editor.suspended or self.editor.state.locked or self.editor.recovery) self.closeReview(false);
        if (self.review) |dialog| if (dialog.as(gtk.Window).getTransientFor()) |parent| builder.style(dialog, parent);
        if (self.editing or self.editor.target.page != .plugins) return;
        self.filling = true;
        defer self.filling = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        const page = std.json.parseFromSliceLeaky(ui.PluginPage, alloc, self.editor.live orelse "{}", .{ .ignore_unknown_fields = true }) catch return;
        const issue = page.discovery_issue orelse if (!page.refresh_available) page.summary else "";
        self.discovery_issue.setText(alloc.dupeSentinel(u8, issue, 0) catch "Plugin discovery needs attention");
        self.discovery_issue.as(gtk.Widget).setVisible(@intFromBool(issue.len != 0));
        self.summary.setText(std.fmt.allocPrintSentinel(alloc, "{d} on this page{s}", .{ page.plugins.len, if (page.pending) " · Refreshing…" else "" }, 0) catch return);
        self.discovery.setText(std.fmt.allocPrintSentinel(alloc, "{s}\nMonitoring: {s} · Discovery {s}\n\nUser packages: $XDG_DATA_HOME/pearl/plugins (normally ~/.local/share/pearl/plugins).\nSystem packages: the installation's share/pearl/plugins or share/pearl-git/plugins folder.\n\nInstalled packages refresh automatically. Changed packages need fresh approval and permission review. Discovery does not execute plugins.", .{ page.summary, page.monitoring, page.discovery_revision }, 0) catch return);
        self.refresh.as(gtk.Widget).setSensitive(@intFromBool(page.refresh_available));
        self.next.as(gtk.Widget).setSensitive(@intFromBool(page.next_offset != null));
        self.next_offset = if (page.next_offset) |offset| std.fmt.parseInt(u64, offset, 10) catch 0 else 0;
        self.previous.as(gtk.Widget).setSensitive(@intFromBool(self.editor.live_offset != 0));
        // Each row owns its own storage and signal bindings. Keep widgets and
        // focus for unaffected IDs, even when neighboring packages change.
        var index: usize = 0;
        while (index < self.rows.items.len) {
            const row = self.rows.items[index];
            var keep = false;
            for (page.plugins) |info| if (std.mem.eql(u8, row.info.id, info.id) and std.mem.eql(u8, row.info.digest, info.digest) and std.mem.eql(u8, row.info.path, info.path) and row.info.installed == info.installed) {
                keep = true;
                break;
            };
            if (keep) {
                index += 1;
                continue;
            }
            self.invalidate(self.context, .plugins);
            _ = self.rows.orderedRemove(index);
            row.destroy();
        }
        var previous: ?*gtk.Widget = null;
        for (page.plugins) |info| {
            var found: ?*Row = null;
            for (self.rows.items) |row| if (std.mem.eql(u8, row.info.id, info.id)) {
                found = row;
                break;
            };
            const row = found orelse (self.add(info) catch return);
            if (row.card.as(gtk.Widget).getPrevSibling() != previous) self.content.reorderChildAfter(row.card.as(gtk.Widget), previous);
            previous = row.card.as(gtk.Widget);
        }
        const document = std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{}) catch {
            self.content.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.content.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        const committed = std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.base orelse "{}", .{}) catch prefs.Preferences{};
        for (page.plugins) |info| {
            var found: ?*Row = null;
            for (self.rows.items) |row| if (std.mem.eql(u8, row.info.id, info.id)) {
                found = row;
                break;
            };
            const row = found orelse continue;
            const cfg = document.plugins.find(info.id) orelse m.Config{ .id = info.id };
            const saved = committed.plugins.find(info.id) orelse m.Config{ .id = info.id };
            const approved = info.digest.len != 0 and std.mem.eql(u8, cfg.digest, info.digest);
            const incompatible = schemaError(info, cfg) != null;
            const live_ready = info.installed and info.available and !std.mem.eql(u8, info.status, "unavailable") and !std.mem.eql(u8, info.status, "disabled") and !std.mem.eql(u8, info.status, "suspended");
            row.available = info.available;
            row.attention = !approved or incompatible or info.error_code != null or !info.installed or !info.available;
            const draft_changed = !std.mem.eql(u8, std.json.Stringify.valueAlloc(alloc, cfg, .{}) catch "", std.json.Stringify.valueAlloc(alloc, saved, .{}) catch "");
            // Discard must also discard the permission-review session for a
            // changed fingerprint; saved grants belong to the old package.
            if (!draft_changed) row.permissions_edited = false;
            row.status.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}{s}", .{ statusText(info.status), if (saved.placement.mode == .overlay) "Desktop overlay" else "Bar", if (draft_changed) " · Unsaved changes" else "" }, 0) catch continue);
            row.notice.setText(if (!info.installed) @import("i18n").dtr("pearl", "Package missing. Preferences are retained; you can still disable it.") else if (incompatible) @import("i18n").dtr("pearl", "Settings changed. Review the package and reset incompatible settings.") else if (!info.available) @import("i18n").dtr("pearl", "Package unavailable. See diagnostics before trying again.") else if (!approved) @import("i18n").dtr("pearl", "Review permissions and approve this package before enabling it.") else if (info.error_code) |err| std.fmt.allocPrintSentinel(alloc, "Needs attention: {s}", .{err}, 0) catch "Plugin needs attention" else "");
            row.notice.as(gtk.Widget).setVisible(@intFromBool(row.attention));
            var paths: std.ArrayList([]const u8) = .empty;
            for (info.sources) |source| paths.append(alloc, source.path) catch continue;
            const sources = std.mem.join(alloc, "\n", paths.items) catch "";
            row.diagnostics.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}\nSource: {s} · {s} · {d} shadowed/conflicting\nCandidates: {s}\nInput activity: {s}\nPackage fingerprint: {s}\nDraft approval: {s}\n{s}", .{ info.status, info.error_code orelse "No runtime error", info.source, info.path, info.shadowed, sources, info.input_activity, info.digest, cfg.digest, if (approved) "Current package approved in draft" else "Review permissions and approve this package" }, 0) catch continue);
            for (row.actions) |button| button.as(gtk.Widget).setSensitive(@intFromBool(info.installed and info.available));
            row.actions[@backingInt(Action.retry)].as(gtk.Widget).setSensitive(@intFromBool(live_ready));
            row.actions[@backingInt(Action.preview)].as(gtk.Widget).setSensitive(@intFromBool(live_ready and std.mem.eql(u8, info.status, "active")));
            row.enabled.as(gtk.Widget).setSensitive(@intFromBool((info.installed and info.available and approved and !incompatible) or cfg.enabled));
            row.config.as(gtk.Widget).setSensitive(@intFromBool(info.installed and info.available));
            if (self.review_row == row and !info.available) self.closeReview(false);
            row.enabled.setActive(@intFromBool(cfg.enabled));
            const reviewed = row.permissions_edited or std.mem.eql(u8, cfg.digest, info.digest);
            row.activity.setActive(@intFromBool(reviewed and info.capabilities.input_activity and cfg.grants.input_activity));
            row.overlay.setActive(@intFromBool(reviewed and info.capabilities.overlay and cfg.grants.overlay));
            row.mode.setSelected(if (cfg.placement.mode == .bar) 0 else 1);
            row.placement_details.as(gtk.Widget).setVisible(@intFromBool(cfg.placement.mode == .overlay));
            setEntry(row.output, cfg.placement.output, alloc);
            row.x.setValue(@floatFromInt(cfg.placement.x));
            row.y.setValue(@floatFromInt(cfg.placement.y));
            row.width.setValue(@floatFromInt(cfg.placement.width));
            row.height.setValue(@floatFromInt(cfg.placement.height));
            row.interactive.setActive(@intFromBool(cfg.placement.interactive));
            row.locked.setActive(@intFromBool(cfg.placement.locked));
            row.fullscreen.setActive(@intFromBool(cfg.placement.hide_fullscreen));
            for (info.settings, row.values) |spec, entry| {
                var value = spec.default;
                for (cfg.settings) |setting| if (std.mem.eql(u8, setting.key, spec.key)) {
                    value = setting.value;
                    break;
                };
                switch (spec.kind) {
                    .text => setEntry(object.ext.cast(gtk.Entry, entry).?, value, alloc),
                    .number => object.ext.cast(gtk.SpinButton, entry).?.setValue(std.fmt.parseFloat(f64, value) catch @floatFromInt(spec.min)),
                    .toggle => object.ext.cast(gtk.Switch, entry).?.setActive(@intFromBool(std.mem.eql(u8, value, "true"))),
                }
            }
        }
        self.filterRows();
    }
    fn statusText(status: []const u8) [:0]const u8 {
        const names = .{ .{ "active", "Running" }, .{ "disabled", "Disabled" }, .{ "failed", "Stopped unexpectedly" }, .{ "suspended", "Suspended" }, .{ "missing", "Package missing" }, .{ "unavailable", "Unavailable" } };
        inline for (names) |pair| if (std.mem.eql(u8, status, pair[0])) return pair[1];
        return "Waiting for runtime";
    }
    fn setEntry(entry: *gtk.Entry, text: []const u8, alloc: std.mem.Allocator) void {
        if (!std.mem.eql(u8, std.mem.span(entry.as(gtk.Editable).getText()), text)) entry.as(gtk.Editable).setText(alloc.dupeSentinel(u8, text, 0) catch return);
    }
    fn add(self: *View, source: ui.PluginInfo) !*Row {
        const row = try a.create(Row);
        errdefer a.destroy(row);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const info = try std.json.parseFromSliceLeaky(ui.PluginInfo, alloc, try std.json.Stringify.valueAlloc(alloc, source, .{}), .{ .allocate = .alloc_always });
        const card = w.column(0);
        card.as(gtk.Widget).addCssClass("settings-card");
        card.as(gtk.Widget).addCssClass("plugins-card");
        self.content.append(card.as(gtk.Widget));
        errdefer self.content.remove(card.as(gtk.Widget));
        const header = w.row(14);
        header.as(gtk.Widget).addCssClass("plugins-card-header");
        header.append(w.icon("pearl-application-x-executable-symbolic").as(gtk.Widget));
        const labels = w.column(4);
        labels.as(gtk.Widget).setHexpand(1);
        labels.append(w.label(try alloc.dupeSentinel(u8, info.name, 0), "pearl-section-title").as(gtk.Widget));
        labels.append(w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ info.id, info.version }, 0), "pearl-secondary").as(gtk.Widget));
        header.append(labels.as(gtk.Widget));
        const enabled = gtk.Switch.new();
        enabled.as(gtk.Widget).setValign(.center);
        w.name(enabled.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Enable {s}", .{info.name}, 0));
        header.append(enabled.as(gtk.Widget));
        card.append(header.as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        card.append(status.as(gtk.Widget));
        const notice = w.label("", "pearl-secondary");
        card.append(notice.as(gtk.Widget));
        const config = w.column(0);
        const placement = w.column(0);
        config.append(placement.as(gtk.Widget));
        placement.as(gtk.Widget).setVisible(@intFromBool(info.capabilities.overlay));
        const details = gtk.Revealer.new();
        details.setChild(config.as(gtk.Widget));
        const expand = gtk.ToggleButton.newWithLabel("Settings and placement");
        config.as(gtk.Widget).setSensitive(@intFromBool(info.installed));
        expand.as(gtk.Widget).addCssClass("plugins-expand");
        const mode = gtk.DropDown.newFromStrings(@ptrCast(&[_:null]?[*:0]const u8{ @import("i18n").dtr("pearl", "Bar"), @import("i18n").dtr("pearl", "Desktop overlay") }));
        field(placement, @import("i18n").dtr("pearl", "Placement"), mode.as(gtk.Widget));
        const overlay = toggle(placement, @import("i18n").dtr("pearl", "Allow desktop overlay"));
        const placement_details = w.column(0);
        placement.append(placement_details.as(gtk.Widget));
        const diagnostic_expander = gtk.ToggleButton.newWithLabel("Package details and diagnostics");
        diagnostic_expander.as(gtk.Widget).addCssClass("plugins-expand");
        const diagnostic_details = gtk.Revealer.new();
        diagnostic_details.as(gtk.Widget).addCssClass("plugins-diagnostics");
        const diagnostics = w.label("", "pearl-secondary");
        diagnostics.setSelectable(1);
        diagnostic_details.setChild(diagnostics.as(gtk.Widget));
        const activity_group = w.column(0);
        activity_group.as(gtk.Widget).setVisible(@intFromBool(info.capabilities.input_activity));
        config.append(activity_group.as(gtk.Widget));
        row.* = .{ .arena = arena, .card = card, .details = details, .expand = expand, .view = self, .info = info, .status = status, .diagnostics = diagnostics, .diagnostic_expander = diagnostic_expander, .diagnostic_details = diagnostic_details, .placement_details = placement_details, .notice = notice, .config = config, .enabled = enabled, .activity = toggle(activity_group, @import("i18n").dtr("pearl", "Allow keyboard and mouse activity")), .overlay = overlay, .mode = mode, .output = makeEntry(placement_details, @import("i18n").dtr("pearl", "Display (empty: first output)")), .x = number(placement_details, @import("i18n").dtr("pearl", "Horizontal position"), 0, 65535), .y = number(placement_details, @import("i18n").dtr("pearl", "Vertical position"), 0, 65535), .width = number(placement_details, @import("i18n").dtr("pearl", "Width"), 16, 512), .height = number(placement_details, @import("i18n").dtr("pearl", "Height"), 16, 512), .interactive = toggle(placement_details, @import("i18n").dtr("pearl", "Accept clicks (off: click through)")), .locked = toggle(placement_details, @import("i18n").dtr("pearl", "Lock placement")), .fullscreen = toggle(placement_details, @import("i18n").dtr("pearl", "Hide over fullscreen windows")), .values = try alloc.alloc(*gtk.Widget, info.settings.len) };
        row.output.setMaxLength(128);
        activity_group.append(w.label(@import("i18n").dtr("pearl", "Coarse activity only. No keys, text or pointer positions are exposed."), "pearl-secondary").as(gtk.Widget));
        if (!info.capabilities.overlay) config.append(w.label(@import("i18n").dtr("pearl", "Placement: Bar"), "pearl-secondary").as(gtk.Widget));
        errdefer {
            for (row.signals.items) |signal| object.signalHandlerDisconnect(signal.value, signal.id);
            row.signals.deinit(a);
        }
        card.append(expand.as(gtk.Widget));
        card.append(details.as(gtk.Widget));
        row.track(expand.as(object.Object), gtk.ToggleButton.signals.toggled.connect(expand, *Row, expanded, row, .{}));
        row.track(diagnostic_expander.as(object.Object), gtk.ToggleButton.signals.toggled.connect(diagnostic_expander, *Row, diagnosticsExpanded, row, .{}));
        row.activity.as(gtk.Widget).setSensitive(@intFromBool(info.capabilities.input_activity));
        row.overlay.as(gtk.Widget).setSensitive(@intFromBool(info.capabilities.overlay));
        inline for (.{ "enabled", "activity", "overlay", "interactive", "locked", "fullscreen" }) |name| row.track(@field(row, name).as(object.Object), object.Object.signals.notify.connect(@field(row, name).as(object.Object), *Row, changed, row, .{ .detail = "active" }));
        row.track(row.mode.as(object.Object), object.Object.signals.notify.connect(row.mode.as(object.Object), *Row, modeChanged, row, .{ .detail = "selected" }));
        inline for (.{ "x", "y", "width", "height" }) |name| row.track(@field(row, name).as(object.Object), gtk.SpinButton.signals.value_changed.connect(@field(row, name), *Row, spun, row, .{}));
        row.track(row.output.as(gtk.Editable).as(object.Object), gtk.Editable.signals.changed.connect(row.output.as(gtk.Editable), *Row, edited, row, .{}));
        for (info.settings, row.values) |spec, *value| {
            const label = try alloc.dupeSentinel(u8, spec.label, 0);
            value.* = switch (spec.kind) {
                .text => blk: {
                    const widget = makeEntry(config, label);
                    row.track(widget.as(gtk.Editable).as(object.Object), gtk.Editable.signals.changed.connect(widget.as(gtk.Editable), *Row, edited, row, .{}));
                    break :blk widget.as(gtk.Widget);
                },
                .number => blk: {
                    const widget = number(config, label, @floatFromInt(spec.min), @floatFromInt(spec.max));
                    row.track(widget.as(object.Object), gtk.SpinButton.signals.value_changed.connect(widget, *Row, spun, row, .{}));
                    break :blk widget.as(gtk.Widget);
                },
                .toggle => blk: {
                    const widget = toggle(config, label);
                    row.track(widget.as(object.Object), object.Object.signals.notify.connect(widget.as(object.Object), *Row, changed, row, .{ .detail = "active" }));
                    break :blk widget.as(gtk.Widget);
                },
            };
        }
        const buttons = w.flow(3);
        buttons.setHomogeneous(0);
        buttons.as(gtk.Widget).setMarginStart(16);
        buttons.as(gtk.Widget).setMarginEnd(16);
        buttons.as(gtk.Widget).setMarginBottom(12);
        config.append(buttons.as(gtk.Widget));
        inline for (.{ .{ Action.approve, "Approve package" }, .{ Action.bar, "Add to bar" }, .{ Action.retry, "Retry" }, .{ Action.preview, "Preview" }, .{ Action.reset, "Reset settings" } }, 0..) |pair, index| {
            const button = w.wrappingButton(if (pair[0] == .approve) @import("i18n").dtr("pearl", "Review package") else pair[1]);
            row.actions[index] = button;
            if (pair[0] == .approve) {
                // Review remains visible without expanding the settings.
                button.as(gtk.Widget).setHalign(.start);
                button.as(gtk.Widget).addCssClass("plugins-review");
                card.insertChildAfter(button.as(gtk.Widget), notice.as(gtk.Widget));
            } else buttons.insert(button.as(gtk.Widget), -1);
            button.as(gtk.Widget).setVisible(@intFromBool(pair[0] != .reset or info.settings.len > 0));
            button.as(gtk.Widget).setSensitive(@intFromBool(info.installed));
            const binding = try alloc.create(Button);
            binding.* = .{ .row = row, .action = pair[0] };
            row.track(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *Button, clicked, binding, .{}));
        }
        card.append(diagnostic_expander.as(gtk.Widget));
        card.append(diagnostic_details.as(gtk.Widget));
        try self.rows.append(a, row);
        row.arena = arena;
        return row;
    }
    fn expanded(button: *gtk.ToggleButton, row: *Row) callconv(.c) void {
        row.details.setRevealChild(button.getActive());
    }
    fn diagnosticsExpanded(button: *gtk.ToggleButton, row: *Row) callconv(.c) void {
        row.diagnostic_details.setRevealChild(button.getActive());
    }
    fn field(card: *gtk.Box, title: [:0]const u8, widget: *gtk.Widget) void {
        const box = w.flow(2);
        box.setHomogeneous(0);
        box.as(gtk.Widget).addCssClass("settings-form-row");
        w.name(widget, title);
        box.insert(w.label(title, "settings-row-title").as(gtk.Widget), -1);
        box.insert(widget, -1);
        card.append(box.as(gtk.Widget));
    }
    fn toggle(card: *gtk.Box, title: [:0]const u8) *gtk.Switch {
        const value = gtk.Switch.new();
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn number(card: *gtk.Box, title: [:0]const u8, min: f64, max: f64) *gtk.SpinButton {
        const value = gtk.SpinButton.newWithRange(min, max, 1);
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn makeEntry(card: *gtk.Box, title: [:0]const u8) *gtk.Entry {
        const value = gtk.Entry.new();
        value.setMaxLength(256);
        field(card, title, value.as(gtk.Widget));
        return value;
    }
    fn changed(value: *object.Object, _: *object.ParamSpec, row: *Row) callconv(.c) void {
        if (row.view.filling or row.view.editing) return;
        // Revoking overlay permission returns the plugin to a visible bar placement.
        if (value == row.overlay.as(object.Object) and row.overlay.getActive() == 0 and row.mode.getSelected() == 1) {
            row.view.filling = true;
            row.mode.setSelected(0);
            row.view.filling = false;
        }
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn modeChanged(_: *object.Object, _: *object.ParamSpec, row: *Row) callconv(.c) void {
        if (row.view.filling or row.view.editing) return;
        // Explicitly selecting Desktop overlay also permits that placement.
        row.view.filling = true;
        row.overlay.setActive(@intFromBool(row.mode.getSelected() == 1));
        row.view.filling = false;
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn spun(_: *gtk.SpinButton, row: *Row) callconv(.c) void {
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn edited(_: *gtk.Editable, row: *Row) callconv(.c) void {
        row.view.save(row, null) catch |err| row.view.report(err);
    }
    fn clicked(_: *gtk.Button, binding: *Button) callconv(.c) void {
        if (binding.action == .approve) {
            binding.row.view.openReview(binding.row) catch |err| binding.row.view.report(err);
            return;
        }
        binding.row.view.save(binding.row, binding.action) catch |err| binding.row.view.report(err);
    }
    fn report(self: *View, err: anyerror) void {
        self.summary.setText(@errorName(err));
    }
    fn openReview(self: *View, row: *Row) !void {
        if (!self.editor.editable() or !row.info.installed or !row.available or self.review != null) return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const root = self.host.as(gtk.Widget).getRoot() orelse return;
        const parent = object.ext.cast(gtk.Window, root) orelse return;
        const shell = builder.open(parent, "Review plugin package");
        self.review = shell.dialog;
        self.review_row = row;
        errdefer self.closeReview(false);
        const body = shell.body;
        body.append(w.label(try alloc.dupeSentinel(u8, row.info.name, 0), "pearl-section-title").as(gtk.Widget));
        body.append(w.label(@import("i18n").dtr("pearl", "Approval is for this exact package. Updated packages require a fresh review."), "pearl-secondary").as(gtk.Widget));
        const info = w.label(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}\nSource: {s}\n{s}\n\nPackage fingerprint:\n{s}", .{ row.info.id, row.info.version, row.info.source, row.info.path, row.info.digest }, 0), "pearl-secondary");
        info.setSelectable(1);
        body.append(info.as(gtk.Widget));
        body.append(w.label(@import("i18n").dtr("pearl", "Optional permissions"), "pearl-section-title").as(gtk.Widget));
        self.review_activity = null;
        self.review_overlay = null;
        if (row.info.capabilities.input_activity) {
            const check = gtk.CheckButton.newWithLabel(@import("i18n").dtr("pearl", "Keyboard and mouse activity"));
            check.setActive(row.activity.getActive());
            body.append(check.as(gtk.Widget));
            body.append(w.label(@import("i18n").dtr("pearl", "Receive coarse activity notifications. No typed text, key identities or pointer positions are exposed."), "pearl-secondary").as(gtk.Widget));
            self.review_activity = check;
            try self.review_controls.append(a, .{ .id = "plugins.review.activity", .widget = check.as(gtk.Widget) });
        }
        if (row.info.capabilities.overlay) {
            const check = gtk.CheckButton.newWithLabel(@import("i18n").dtr("pearl", "Desktop overlay"));
            check.setActive(row.overlay.getActive());
            body.append(check.as(gtk.Widget));
            body.append(w.label(@import("i18n").dtr("pearl", "Display the plugin outside the bar. Choose its placement under Settings and placement."), "pearl-secondary").as(gtk.Widget));
            self.review_overlay = check;
            try self.review_controls.append(a, .{ .id = "plugins.review.overlay", .widget = check.as(gtk.Widget) });
        }
        if (!row.info.capabilities.overlay and !row.info.capabilities.input_activity) body.append(w.label(@import("i18n").dtr("pearl", "This plugin requests no optional permissions."), "pearl-secondary").as(gtk.Widget));
        body.append(w.label(@import("i18n").dtr("pearl", "Save this review to the shared draft, then enable the plugin and Apply & save. Review does not enable a newly installed plugin."), "pearl-secondary").as(gtk.Widget));
        const error_label = w.label("", "pearl-secondary");
        body.append(error_label.as(gtk.Widget));
        self.review_error = error_label;
        const cancel = shell.dialog.addButton("Cancel", @backingInt(gtk.ResponseType.cancel));
        const save_button = shell.dialog.addButton("Save review to draft", @backingInt(gtk.ResponseType.accept));
        save_button.addCssClass("suggested-action");
        try self.review_controls.append(a, .{ .id = "plugins.review.cancel", .widget = cancel });
        try self.review_controls.append(a, .{ .id = "plugins.review.save", .widget = save_button });
        _ = gtk.Dialog.signals.response.connect(shell.dialog, *View, reviewResponse, self, .{});
        shell.dialog.as(gtk.Window).present();
    }
    fn closeReview(self: *View, restore_focus: bool) void {
        const row = self.review_row;
        self.review_controls.clearRetainingCapacity();
        self.review_row = null;
        self.review_activity = null;
        self.review_overlay = null;
        self.review_error = null;
        if (self.review) |dialog| {
            self.review = null;
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        if (restore_focus) if (row) |value| {
            _ = value.actions[0].as(gtk.Widget).grabFocus();
        };
    }
    const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
    const DiagnosticControl = struct { field: []const u8, bounds: ?Rect, focused: bool, selected: bool };
    const DiagnosticRow = struct { id: []const u8, visible: bool, expanded: bool, status: []const u8, notice: []const u8 };
    pub const Diagnostic = struct { review: bool, error_text: []const u8, discovery_issue: []const u8, controls: []const DiagnosticControl, rows: []const DiagnosticRow };
    pub fn diagnostic(self: *View, alloc: std.mem.Allocator) !Diagnostic {
        var controls: std.ArrayList(DiagnosticControl) = .empty;
        if (self.review) |dialog| for (self.review_controls.items) |control| {
            var rect: @import("graphene1").Rect = undefined;
            const focus = dialog.as(gtk.Window).getFocus();
            try controls.append(alloc, .{ .field = control.id, .bounds = if (control.widget.computeBounds(dialog.as(gtk.Widget), &rect) != 0) .{ .x = rect.f_origin.f_x, .y = rect.f_origin.f_y, .width = rect.f_size.f_width, .height = rect.f_size.f_height } else null, .focused = if (focus) |f| f == control.widget or f.isAncestor(control.widget) != 0 else false, .selected = if (object.ext.cast(gtk.CheckButton, control.widget)) |check| check.getActive() != 0 else false });
        };
        var rows: std.ArrayList(DiagnosticRow) = .empty;
        for (self.rows.items) |row| try rows.append(alloc, .{ .id = row.info.id, .visible = row.card.as(gtk.Widget).getVisible() != 0, .expanded = row.expand.getActive() != 0, .status = std.mem.span(row.status.getText()), .notice = std.mem.span(row.notice.getText()) });
        return .{ .review = self.review != null, .error_text = if (self.review_error) |label| std.mem.span(label.getText()) else "", .discovery_issue = std.mem.span(self.discovery_issue.getText()), .controls = controls.items, .rows = rows.items };
    }
    fn reviewResponse(_: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        if (response != @backingInt(gtk.ResponseType.accept)) {
            self.closeReview(true);
            return;
        }
        const row = self.review_row orelse return;
        if (!self.editor.editable() or !row.available) {
            if (self.review_error) |label| label.setText(@import("i18n").dtr("pearl", "Settings are updating. Wait for synchronization, then try again."));
            return;
        }
        self.filling = true;
        row.activity.setActive(if (self.review_activity) |check| check.getActive() else 0);
        row.overlay.setActive(if (self.review_overlay) |check| check.getActive() else 0);
        if (row.overlay.getActive() == 0) row.mode.setSelected(0);
        self.filling = false;
        self.save(row, .approve) catch |err| {
            if (self.review_error) |label| label.setText(@errorName(err));
            self.update();
            return;
        };
        self.closeReview(true);
        self.update();
    }
    fn schemaError(info: ui.PluginInfo, cfg: m.Config) ?anyerror {
        if (!info.installed) return null;
        for (cfg.settings) |setting| {
            var found = false;
            for (info.settings) |spec| if (std.mem.eql(u8, spec.key, setting.key)) {
                m.settingValue(spec, setting.value) catch |err| return err;
                found = true;
                break;
            };
            if (!found) return error.UnknownPluginSetting;
        }
        return null;
    }
    fn save(self: *View, row: *Row, action: ?Action) !void {
        if (self.filling or self.editing or !self.editor.editable()) return;
        self.editing = true;
        defer self.editing = false;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const alloc = temp.allocator();
        if (action == .retry or action == .preview) {
            const bytes = try std.json.Stringify.valueAlloc(alloc, .{ .id = row.info.id, .action = if (action == .retry) "retry" else "preview" }, .{});
            try self.editor.liveAction(.@"plugin.action", try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}));
            return;
        }
        var document = try std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
        const previous = document.plugins.find(row.info.id) orelse m.Config{ .id = row.info.id };
        var cfg = previous;
        cfg.enabled = row.enabled.getActive() != 0;
        row.permissions_edited = true;
        const incompatible = schemaError(row.info, cfg) != null;
        if (row.info.installed and !(incompatible and !cfg.enabled and action == null)) {
            if (incompatible and action != .reset) return error.PluginSettingsChangedResetRequired;
            cfg.grants = .{ .input_activity = row.activity.getActive() != 0, .overlay = row.overlay.getActive() != 0 };
            cfg.placement = .{ .mode = if (row.mode.getSelected() == 0) .bar else .overlay, .output = std.mem.span(row.output.as(gtk.Editable).getText()), .x = @intCast(row.x.getValueAsInt()), .y = @intCast(row.y.getValueAsInt()), .width = @intCast(row.width.getValueAsInt()), .height = @intCast(row.height.getValueAsInt()), .interactive = row.interactive.getActive() != 0, .locked = row.locked.getActive() != 0, .hide_fullscreen = row.fullscreen.getActive() != 0 };
            const values = try alloc.alloc(m.Setting, row.values.len);
            for (row.info.settings, row.values, values) |spec, value, *setting| setting.* = .{ .key = spec.key, .value = if (action == .reset) spec.default else switch (spec.kind) {
                .text => std.mem.span(object.ext.cast(gtk.Entry, value).?.as(gtk.Editable).getText()),
                .number => try std.fmt.allocPrint(alloc, "{d}", .{object.ext.cast(gtk.SpinButton, value).?.getValueAsInt()}),
                .toggle => if (object.ext.cast(gtk.Switch, value).?.getActive() != 0) "true" else "false",
            } };
            if (action != .reset) {
                for (cfg.settings) |old| {
                    var found = false;
                    for (row.info.settings) |spec| if (std.mem.eql(u8, old.key, spec.key)) {
                        found = true;
                        break;
                    };
                    if (!found) return error.PluginSettingsChangedResetRequired;
                }
            }
            cfg.settings = values;
            if (action == .approve) cfg.digest = row.info.digest;
        }
        try @import("../plugins/placement.zig").update(alloc, &document, previous, &cfg, action == .bar);
        var entries: std.ArrayList(m.Config) = .empty;
        for (document.plugins.entries) |old| if (!std.mem.eql(u8, old.id, cfg.id)) {
            try entries.append(alloc, old);
        };
        try entries.append(alloc, cfg);
        document.plugins.entries = entries.items;
        try self.editor.edit(try std.json.Stringify.valueAlloc(alloc, document, .{ .whitespace = .indent_2 }));
    }
};
