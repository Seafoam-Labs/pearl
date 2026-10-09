//! Staged scheduler selection; only Apply submits a runtime mutation.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const object = @import("gobject2");
const m = @import("../services/sched_ext_model.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    editor: *Editor,
    host: *gtk.Box,
    german: bool,
    arena: std.heap.ArenaAllocator = .init(a),
    render_arena: std.heap.ArenaAllocator = .init(a),
    snapshot: m.Snapshot = .{},
    names: []const []const u8 = &.{},
    modes: []const m.Mode = &.{},
    selected: @import("../services/policy.zig").Text(128) = .{},
    selected_mode: m.Mode = .auto,
    initialized: bool = false,
    filling: bool = false,
    catalog_digest: ?[64]u8 = null,
    shown: ?[64]u8 = null,
    signal_ids: [5]c_ulong = @splat(0),
    scheduler: *gtk.DropDown,
    mode: *gtk.DropDown,
    apply: *gtk.Button,
    stop: *gtk.Button,
    refresh: *gtk.Button,
    summary: *gtk.Label,
    current: *gtk.Label,
    detail: *gtk.Label,
    selection: *gtk.Label,
    mode_note: *gtk.Label,
    arguments: *gtk.Label,
    installed: *gtk.Label,
    boot: *gtk.Label,
    feedback: *gtk.Label,
    pub fn create(host: *gtk.Box, editor: *Editor, german: bool) !*View {
        const self = try a.create(View);
        const title = w.row(12);
        const heading = w.label(if (german) "CPU-Scheduler" else "CPU scheduler", "settings-section-title");
        heading.as(gtk.Widget).setHexpand(1);
        title.append(heading.as(gtk.Widget));
        const refresh = w.wrappingButton(if (german) "Aktualisieren" else "Refresh");
        title.append(refresh.as(gtk.Widget));
        host.append(title.as(gtk.Widget));
        host.append(w.label(if (german) "Bestimme, wie CPU-Zeit zwischen Anwendungen verteilt wird. Scheduler und Modus auswählen, dann anwenden." else "Choose how CPU time is shared between applications. Select a scheduler and mode, then apply your changes.", "pearl-secondary").as(gtk.Widget));
        const summary = w.label("", "pearl-secondary");
        host.append(summary.as(gtk.Widget));
        const status = card(host);
        status.append(w.label(if (german) "Aktuell aktiv" else "Currently running", "pearl-secondary").as(gtk.Widget));
        const current = w.label("", "settings-section-title");
        status.append(current.as(gtk.Widget));
        const detail = w.label("", "pearl-secondary");
        status.append(detail.as(gtk.Widget));
        const selection_card = card(host);
        const selection = w.label(if (german) "Scheduler-Auswahl" else "Scheduler selection", "settings-section-title");
        selection_card.append(selection.as(gtk.Widget));
        const scheduler = dropdown(selection_card, if (german) "Scheduler" else "Scheduler");
        const installed = w.label("", "pearl-secondary");
        selection_card.append(installed.as(gtk.Widget));
        const mode = dropdown(selection_card, if (german) "Modus" else "Mode");
        const mode_note = w.label("", "pearl-secondary");
        selection_card.append(mode_note.as(gtk.Widget));
        const expander = gtk.Expander.new(if (german) "Aufgelöste Modusargumente" else "Resolved mode arguments");
        const arguments = w.label("", "pearl-secondary");
        arguments.setSelectable(1);
        arguments.as(gtk.Widget).addCssClass("monospace");
        expander.setChild(arguments.as(gtk.Widget));
        selection_card.append(expander.as(gtk.Widget));
        selection_card.append(w.label(if (german) "Gilt für alle Anwendungen auf diesem System." else "Applies to all applications on this system.", "pearl-secondary").as(gtk.Widget));
        const apply = w.wrappingButton(if (german) "Scheduler anwenden" else "Apply scheduler");
        apply.as(gtk.Widget).addCssClass("pearl-primary");
        selection_card.append(apply.as(gtk.Widget));
        const feedback = w.label("", "pearl-secondary");
        selection_card.append(feedback.as(gtk.Widget));
        const kernel = card(host);
        kernel.append(w.label(if (german) "Zur Kernel-Planung zurückkehren" else "Return to kernel scheduling", "settings-section-title").as(gtk.Widget));
        kernel.append(w.label(if (german) "Den von scx_loader verwalteten Scheduler stoppen." else "Stop the scheduler managed by scx_loader.", "pearl-secondary").as(gtk.Widget));
        const stop = w.wrappingButton(if (german) "Kernel-Standard verwenden" else "Use kernel default");
        kernel.append(stop.as(gtk.Widget));
        host.append(w.label(if (german) "Nur Laufzeitänderungen. Der beim Systemstart verwendete Scheduler wird nicht geändert." else "Runtime changes only. Applying a scheduler does not change what starts at boot.", "pearl-secondary").as(gtk.Widget));
        const boot = w.label("", "pearl-secondary");
        host.append(boot.as(gtk.Widget));
        self.* = .{ .host = host, .editor = editor, .german = german, .scheduler = scheduler, .mode = mode, .apply = apply, .stop = stop, .refresh = refresh, .summary = summary, .current = current, .detail = detail, .selection = selection, .mode_note = mode_note, .arguments = arguments, .installed = installed, .boot = boot, .feedback = feedback };
        self.signal_ids = .{
            object.Object.signals.notify.connect(scheduler.as(object.Object), *View, changed, self, .{ .detail = "selected" }),
            object.Object.signals.notify.connect(mode.as(object.Object), *View, modeChanged, self, .{ .detail = "selected" }),
            gtk.Button.signals.clicked.connect(apply, *View, applyClicked, self, .{}),
            gtk.Button.signals.clicked.connect(stop, *View, stopClicked, self, .{}),
            gtk.Button.signals.clicked.connect(refresh, *View, refreshClicked, self, .{}),
        };
        w.name(scheduler.as(gtk.Widget), "Scheduler");
        w.name(mode.as(gtk.Widget), if (german) "Modus" else "Mode");
        self.host.as(gtk.Widget).setSensitive(0);
        return self;
    }
    pub fn destroy(self: *View) void {
        const objects = [_]*object.Object{ self.scheduler.as(object.Object), self.mode.as(object.Object), self.apply.as(object.Object), self.stop.as(object.Object), self.refresh.as(object.Object) };
        for (objects, self.signal_ids) |obj, id| object.signalHandlerDisconnect(obj, id);
        self.arena.deinit();
        self.render_arena.deinit();
        a.destroy(self);
    }
    fn t(self: *View, en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
        return if (self.german) de else en;
    }
    fn format(self: *View, comptime en: []const u8, comptime de: []const u8, args: anytype) []const u8 {
        return if (self.german) std.fmt.allocPrint(self.render_arena.allocator(), de, args) catch "" else std.fmt.allocPrint(self.render_arena.allocator(), en, args) catch "";
    }
    fn text(self: *View, label: *gtk.Label, value: []const u8) void {
        label.setText(self.render_arena.allocator().dupeZ(u8, value) catch return);
    }
    pub fn update(self: *View) void {
        if (self.editor.target.page != .system or !self.editor.online or !self.editor.ready or self.editor.suspended or self.editor.state.locked) {
            self.host.as(gtk.Widget).setSensitive(0);
            self.shown = null;
            return;
        }
        if (self.editor.needs_snapshot) return;
        const bytes = self.editor.live orelse return;
        const hash = @import("editor_protocol.zig").digest(bytes);
        self.host.as(gtk.Widget).setSensitive(1);
        if (self.shown) |old| if (std.mem.eql(u8, &hash, &old)) {
            self.render();
            return;
        };
        var arena = std.heap.ArenaAllocator.init(a);
        const page = std.json.parseFromSliceLeaky(struct { sched_ext: ?m.Snapshot = null }, arena.allocator(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            arena.deinit();
            self.host.as(gtk.Widget).setSensitive(0);
            return;
        };
        const snapshot = page.sched_ext orelse {
            arena.deinit();
            self.summary.setText(self.t("Scheduler management is unavailable in this Pearl backend.", "Die Scheduler-Verwaltung ist in diesem Pearl-Backend nicht verfügbar."));
            self.host.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.filling = true;
        defer self.filling = false;
        self.arena.deinit();
        self.arena = arena;
        self.snapshot = snapshot;
        self.shown = hash;
        const catalog_text = std.json.Stringify.valueAlloc(self.arena.allocator(), snapshot.catalog, .{}) catch return;
        const catalog_hash = @import("editor_protocol.zig").digest(catalog_text);
        const rebuild = self.catalog_digest == null or !std.mem.eql(u8, &catalog_hash, &self.catalog_digest.?);
        self.catalog_digest = catalog_hash;
        var names: std.ArrayList([]const u8) = .empty;
        for (snapshot.catalog.schedulers) |s| if (s.installed) names.append(self.arena.allocator(), s.name) catch return;
        self.names = names.items;
        if (!self.initialized and self.names.len > 0) {
            self.selected.set(snapshot.status.scheduler orelse self.names[0]);
            self.selected_mode = snapshot.status.mode orelse .auto;
            self.initialized = true;
        }
        if (rebuild) {
            const strings = gtk.StringList.new(null);
            defer strings.unref();
            for (self.names) |name| strings.append(self.arena.allocator().dupeZ(u8, name) catch return);
            self.scheduler.setModel(strings.as(gio.ListModel));
            var selected: c_uint = std.math.maxInt(c_uint);
            for (self.names, 0..) |name, i| if (std.mem.eql(u8, name, self.selected.slice())) {
                selected = @intCast(i);
                break;
            };
            self.scheduler.setSelected(selected);
        }
        self.fillModes(rebuild);
        self.render();
    }
    fn fillModes(self: *View, rebuild: bool) void {
        var modes: std.ArrayList(m.Mode) = .empty;
        if (self.snapshot.catalog.find(self.selected.slice())) |s| for (std.enums.values(m.Mode)) |mode| if (s.arguments(mode) != null) {
            modes.append(self.arena.allocator(), mode) catch return;
        };
        self.modes = modes.items;
        if (!rebuild) return;
        const strings = gtk.StringList.new(null);
        defer strings.unref();
        var selected: c_uint = std.math.maxInt(c_uint);
        for (self.modes, 0..) |mode, i| {
            strings.append(self.modeLabel(mode));
            if (mode == self.selected_mode) selected = @intCast(i);
        }
        self.mode.setModel(strings.as(gio.ListModel));
        self.mode.setSelected(selected);
    }
    fn modeLabel(self: *View, mode: m.Mode) [:0]const u8 {
        return switch (mode) {
            .auto => self.t("Auto", "Automatisch"),
            .gaming => "Gaming",
            .lowlatency => self.t("Low latency", "Niedrige Latenz"),
            .powersave => self.t("Power saver", "Energiesparen"),
            .server => "Server",
        };
    }
    fn render(self: *View) void {
        _ = self.render_arena.reset(.retain_capacity);
        const snapshot = self.snapshot;
        const pending = snapshot.pending or self.editor.live_command != null;
        self.text(self.summary, snapshot.summary);
        self.text(self.current, switch (snapshot.status.kind) {
            .unknown => self.t("Status unavailable", "Status nicht verfügbar"),
            .stopped => if (snapshot.kernel == .disabled) self.t("Kernel default", "Kernel-Standard") else self.t("External or unknown scheduler", "Externer oder unbekannter Scheduler"),
            .running => snapshot.status.scheduler orelse "",
        });
        self.text(self.detail, if (snapshot.status.kind == .stopped and snapshot.kernel == .disabled) self.t("No sched-ext scheduler is active.", "Kein sched-ext-Scheduler ist aktiv.") else snapshot.status.detail);
        const scheduler = self.snapshot.catalog.find(self.selected.slice());
        const args = if (scheduler) |s| s.arguments(self.selected_mode) else null;
        const same = if (scheduler) |s| m.matches(snapshot.status, snapshot.kernel, s, self.selected_mode) else false;
        self.selection.setText(if (pending) self.t("Applying or refreshing…", "Anwenden oder Aktualisieren…") else if (same) self.t("Scheduler selection · Currently applied", "Scheduler-Auswahl · Aktuell angewendet") else self.t("Scheduler selection · Not applied", "Scheduler-Auswahl · Nicht angewendet"));
        var unavailable: std.ArrayList([]const u8) = .empty;
        for (snapshot.catalog.schedulers) |s| if (!s.installed) unavailable.append(self.render_arena.allocator(), s.name) catch {};
        self.text(self.installed, if (unavailable.items.len > 0) self.format("{d} installed · Missing executables: {s}", "{d} installiert · Fehlende Programme: {s}", .{ self.names.len, std.mem.join(self.render_arena.allocator(), ", ", unavailable.items) catch "" }) else self.format("{d} installed schedulers", "{d} installierte Scheduler", .{self.names.len}));
        self.mode_note.setText(if (args) |values| if (values.len > 0) self.t("Uses the configured arguments for this mode.", "Verwendet die konfigurierten Argumente dieses Modus.") else if (self.selected_mode == .auto) self.t("Uses scheduler defaults.", "Verwendet Scheduler-Standardwerte.") else self.t("No distinct arguments are configured for this mode. Uses scheduler defaults.", "Keine eigenen Argumente für diesen Modus konfiguriert. Verwendet Scheduler-Standardwerte.") else self.t("Select an available scheduler and mode.", "Verfügbaren Scheduler und Modus auswählen."));
        // JSON preserves argument boundaries, including whitespace and empty strings.
        self.text(self.arguments, if (args) |values| if (values.len == 0) self.t("Uses scheduler defaults", "Verwendet Scheduler-Standardwerte") else std.json.Stringify.valueAlloc(self.render_arena.allocator(), values, .{}) catch "" else "");
        self.text(self.boot, self.format("Configured boot default: {s} · {s}", "Konfigurierter Startstandard: {s} · {s}", .{ snapshot.catalog.default_sched orelse self.t("none", "keiner"), if (snapshot.catalog.default_mode) |mode| self.modeLabel(mode) else self.t("unknown mode", "unbekannter Modus") }));
        self.text(self.feedback, snapshot.feedback);
        self.scheduler.as(gtk.Widget).setSensitive(@intFromBool(!pending and self.names.len > 0));
        self.mode.as(gtk.Widget).setSensitive(@intFromBool(!pending and scheduler != null and self.modes.len > 0));
        self.apply.as(gtk.Widget).setSensitive(@intFromBool(!pending and snapshot.available and args != null and scheduler != null and scheduler.?.installed and !same));
        self.stop.as(gtk.Widget).setSensitive(@intFromBool(!pending and snapshot.can_stop));
        self.refresh.as(gtk.Widget).setSensitive(@intFromBool(!pending));
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        const i = self.scheduler.getSelected();
        if (i >= self.names.len) return;
        self.selected.set(self.names[i]);
        self.selected_mode = .auto;
        self.filling = true;
        self.fillModes(true);
        self.filling = false;
        self.render();
    }
    fn modeChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        const i = self.mode.getSelected();
        if (i >= self.modes.len) return;
        self.selected_mode = self.modes[i];
        self.render();
    }
    fn send(self: *View, action: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const apply = std.mem.eql(u8, action, "apply");
        const bytes = std.json.Stringify.valueAlloc(alloc, .{ .action = action, .generation = self.snapshot.generation, .scheduler = if (apply) self.selected.slice() else @as(?[]const u8, null), .mode = if (apply) self.selected_mode else @as(?m.Mode, null) }, .{ .emit_null_optional_fields = false }) catch return;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return;
        self.editor.liveAction(.@"sched-ext.action", value) catch |err| {
            self.text(self.feedback, @errorName(err));
            return;
        };
        self.render();
    }
    fn applyClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send("apply");
    }
    fn stopClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send("stop");
    }
    fn refreshClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.send("refresh");
    }
};
fn card(host: *gtk.Box) *gtk.Box {
    const box = w.column(12);
    box.as(gtk.Widget).addCssClass("settings-card");
    box.as(gtk.Widget).addCssClass("settings-live-card");
    host.append(box.as(gtk.Widget));
    return box;
}
fn dropdown(host: *gtk.Box, title: [:0]const u8) *gtk.DropDown {
    host.append(w.label(title, "pearl-secondary").as(gtk.Widget));
    const control = gtk.DropDown.new(null, null);
    control.as(gtk.Widget).setHexpand(1);
    host.append(control.as(gtk.Widget));
    return control;
}
