//! Staged scheduler selection; only Apply submits a runtime mutation.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const object = @import("gobject2");
const m = @import("../services/sched_ext_model.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Section = struct {
    expander: *gtk.Expander,
    body: *gtk.Box,
    summary: *gtk.Label,
    fn create(host: *gtk.Box, title: [:0]const u8) Section {
        const expander = gtk.Expander.new(null);
        expander.as(gtk.Widget).addCssClass("settings-card");
        expander.as(gtk.Widget).addCssClass("system-section");
        const heading = w.column(5);
        heading.as(gtk.Widget).addCssClass("system-section-heading");
        heading.append(w.label(title, "pearl-section-title").as(gtk.Widget));
        const summary = w.label("", "pearl-secondary");
        heading.append(summary.as(gtk.Widget));
        expander.setLabelWidget(heading.as(gtk.Widget));
        w.name(expander.as(gtk.Widget), title);
        const body = w.column(12);
        body.as(gtk.Widget).addCssClass("system-section-body");
        expander.setChild(body.as(gtk.Widget));
        host.append(expander.as(gtk.Widget));
        return .{ .expander = expander, .body = body, .summary = summary };
    }
};
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
    signal_ids: [4]c_ulong = @splat(0),
    mode_signal_ids: [5]c_ulong = @splat(0),
    keys: *gtk.EventControllerKey,
    key_signal: c_ulong = 0,
    scheduler: *gtk.DropDown,
    mode: *gtk.FlowBox,
    mode_buttons: [5]*gtk.CheckButton,
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
    stop_feedback: *gtk.Label,
    badge: *gtk.Label,
    observation: *gtk.Label,
    missing: *gtk.Label,
    details_section: Section,
    boot_section: Section,
    last_action: m.Action = .refresh,
    restore_focus: ?*gtk.Widget = null,
    announced: ?[64]u8 = null,
    pub fn create(host: *gtk.Box, editor: *Editor, german: bool) !*View {
        const self = try a.create(View);
        host.as(gtk.Widget).addCssClass("system-view");
        host.setSpacing(16);
        const status = card(host);
        const status_flow = w.flow(2);
        status_flow.setHomogeneous(0);
        status.append(status_flow.as(gtk.Widget));
        const status_text = w.column(8);
        status_text.append(w.label(if (german) "Aktuell aktiv" else "Currently running", "pearl-secondary").as(gtk.Widget));
        const current = w.label(if (german) "Status wird geprüft…" else "Checking status…", "system-current");
        current.setMaxWidthChars(28);
        current.setSelectable(1);
        status_text.append(current.as(gtk.Widget));
        const detail = w.label("", "pearl-secondary");
        detail.setMaxWidthChars(32);
        status_text.append(detail.as(gtk.Widget));
        const badge = w.label(if (german) "Prüfen…" else "Checking…", "system-badge");
        badge.as(gtk.Widget).setHalign(.start);
        status_text.append(badge.as(gtk.Widget));
        status_flow.insert(status_text.as(gtk.Widget), -1);
        const status_actions = w.column(12);
        status_actions.as(gtk.Widget).setValign(.center);
        const refresh = w.wrappingButton(if (german) "Aktualisieren" else "Refresh");
        refresh.as(gtk.Widget).addCssClass("settings-value");
        refresh.as(gtk.Widget).setHalign(.end);
        status_actions.append(refresh.as(gtk.Widget));
        const stop = w.wrappingButton(if (german) "Kernel-Standard verwenden" else "Use kernel default");
        stop.as(gtk.Widget).addCssClass("settings-value");
        stop.as(gtk.Widget).setHalign(.end);
        status_actions.append(stop.as(gtk.Widget));
        status_flow.insert(status_actions.as(gtk.Widget), -1);
        const observation = w.label("", "pearl-secondary");
        status.append(observation.as(gtk.Widget));
        const summary = w.label("", "pearl-secondary");
        status.append(summary.as(gtk.Widget));
        const stop_feedback = w.label("", "pearl-secondary");
        status.append(stop_feedback.as(gtk.Widget));
        const selection_card = card(host);
        const selection_heading = w.flow(2);
        selection_heading.setHomogeneous(0);
        selection_heading.insert(w.label(if (german) "CPU-Scheduler" else "CPU scheduler", "pearl-section-title").as(gtk.Widget), -1);
        const selection = w.label("", "pearl-secondary");
        selection.setMaxWidthChars(30);
        selection.setXalign(1);
        selection_heading.insert(selection.as(gtk.Widget), -1);
        selection_card.append(selection_heading.as(gtk.Widget));
        const scheduler = dropdown(selection_card, "Scheduler");
        @import("assistant_layout.zig").wrapChoice(scheduler);
        const installed = w.label("", "pearl-secondary");
        selection_card.append(installed.as(gtk.Widget));
        selection_card.append(w.label(if (german) "Modus" else "Mode", "pearl-secondary").as(gtk.Widget));
        const mode = w.flow(3);
        var mode_buttons: [5]*gtk.CheckButton = undefined;
        for (std.enums.values(m.Mode), 0..) |value, i| {
            const check = gtk.CheckButton.new();
            if (i > 0) check.setGroup(mode_buttons[0]);
            check.as(gtk.Widget).addCssClass("system-mode");
            const label = w.label(modeTitle(value, german), "settings-row-title");
            label.setMaxWidthChars(16);
            check.setChild(label.as(gtk.Widget));
            w.name(check.as(gtk.Widget), modeTitle(value, german));
            mode.insert(check.as(gtk.Widget), -1);
            mode_buttons[i] = check;
        }
        selection_card.append(mode.as(gtk.Widget));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        mode.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const mode_note = w.label("", "pearl-secondary");
        selection_card.append(mode_note.as(gtk.Widget));
        const apply_row = w.flow(2);
        apply_row.setHomogeneous(0);
        const consequence = w.label(if (german) "Gilt sofort für alle Anwendungen. Startvorgaben bleiben unverändert." else "Applies now to all applications. Boot settings stay unchanged.", "pearl-secondary");
        consequence.setMaxWidthChars(48);
        consequence.as(gtk.Widget).setValign(.center);
        apply_row.insert(consequence.as(gtk.Widget), -1);
        const apply = w.wrappingButton(if (german) "Scheduler anwenden" else "Apply scheduler");
        apply.as(gtk.Widget).addCssClass("pearl-primary");
        apply.as(gtk.Widget).setHalign(.end);
        apply_row.insert(apply.as(gtk.Widget), -1);
        selection_card.append(apply_row.as(gtk.Widget));
        const feedback = w.label("", "pearl-secondary");
        selection_card.append(feedback.as(gtk.Widget));
        const details_section = Section.create(host, if (german) "Scheduler-Details" else "Scheduler details");
        details_section.body.append(w.label(if (german) "Aufgelöste Argumente des ausgewählten Modus" else "Selected mode arguments", "settings-row-title").as(gtk.Widget));
        const arguments = w.label("", "monospace");
        arguments.setSelectable(1);
        details_section.body.append(arguments.as(gtk.Widget));
        details_section.body.append(w.label(if (german) "Schreibgeschützt. Der Loader übergibt diese Argumente beim Anwenden." else "Read-only. The loader supplies these arguments when you apply the mode.", "pearl-secondary").as(gtk.Widget));
        const missing = w.label("", "pearl-secondary");
        missing.setSelectable(1);
        details_section.body.append(missing.as(gtk.Widget));
        const boot_section = Section.create(host, if (german) "Startkonfiguration" else "Startup configuration");
        const boot = w.label("", "pearl-secondary");
        boot.setSelectable(1);
        boot_section.body.append(boot.as(gtk.Widget));
        boot_section.body.append(w.label(if (german) "Schreibgeschützt. Von scx_loader verwaltet. Laufzeitänderungen ändern diese Startvorgaben nicht." else "Read-only. Managed by scx_loader configuration. Runtime actions do not change these boot defaults.", "pearl-secondary").as(gtk.Widget));
        self.* = .{ .host = host, .editor = editor, .german = german, .scheduler = scheduler, .mode = mode, .mode_buttons = mode_buttons, .keys = keys, .apply = apply, .stop = stop, .refresh = refresh, .summary = summary, .current = current, .detail = detail, .selection = selection, .mode_note = mode_note, .arguments = arguments, .installed = installed, .boot = boot, .feedback = feedback, .stop_feedback = stop_feedback, .badge = badge, .observation = observation, .missing = missing, .details_section = details_section, .boot_section = boot_section };
        self.signal_ids = .{
            object.Object.signals.notify.connect(scheduler.as(object.Object), *View, changed, self, .{ .detail = "selected" }),
            gtk.Button.signals.clicked.connect(apply, *View, applyClicked, self, .{}),
            gtk.Button.signals.clicked.connect(stop, *View, stopClicked, self, .{}),
            gtk.Button.signals.clicked.connect(refresh, *View, refreshClicked, self, .{}),
        };
        for (mode_buttons, &self.mode_signal_ids) |check, *id| id.* = gtk.CheckButton.signals.toggled.connect(check, *View, modeChanged, self, .{});
        self.key_signal = gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, keyPressed, self, .{});
        w.name(scheduler.as(gtk.Widget), "Scheduler");
        w.name(mode.as(gtk.Widget), if (german) "Modus" else "Mode");
        self.block(self.t("Loading scheduler configuration…", "Scheduler-Konfiguration wird geladen…"));
        return self;
    }
    pub fn destroy(self: *View) void {
        const objects = [_]*object.Object{ self.scheduler.as(object.Object), self.apply.as(object.Object), self.stop.as(object.Object), self.refresh.as(object.Object) };
        for (objects, self.signal_ids) |obj, id| object.signalHandlerDisconnect(obj, id);
        for (self.mode_buttons, self.mode_signal_ids) |check, id| object.signalHandlerDisconnect(check.as(object.Object), id);
        object.signalHandlerDisconnect(self.keys.as(object.Object), self.key_signal);
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
        if (std.mem.eql(u8, std.mem.span(label.getText()), value)) return;
        label.setText(self.render_arena.allocator().dupeZ(u8, value) catch return);
    }
    fn block(self: *View, reason: [:0]const u8) void {
        self.restore_focus = null;
        for ([_]*gtk.Widget{ self.scheduler.as(gtk.Widget), self.mode.as(gtk.Widget), self.apply.as(gtk.Widget), self.stop.as(gtk.Widget), self.refresh.as(gtk.Widget) }) |widget| widget.setSensitive(0);
        self.text(self.badge, self.t("Unavailable", "Nicht verfügbar"));
        self.text(self.observation, self.t("Last observed state · Refresh when connected", "Zuletzt beobachteter Status · Nach Verbindung aktualisieren"));
        self.text(self.summary, reason);
        self.summary.as(gtk.Widget).setVisible(1);
        self.shown = null;
    }
    fn rememberCommandFocus(self: *View) void {
        if (self.restore_focus != null) return;
        const root = self.host.as(gtk.Widget).getRoot() orelse return;
        const focus = root.getFocus() orelse return;
        for ([_]*gtk.Widget{ self.apply.as(gtk.Widget), self.stop.as(gtk.Widget), self.refresh.as(gtk.Widget) }) |widget| if (focus == widget or focus.isAncestor(widget) != 0) {
            self.restore_focus = widget;
            return;
        };
    }
    pub fn update(self: *View) void {
        if (self.editor.target.page != .system or !self.editor.online or !self.editor.ready or self.editor.suspended or self.editor.state.locked) {
            self.block(if (!self.editor.online) self.t("Disconnected. Reconnect to check scheduler status.", "Verbindung getrennt. Für den Scheduler-Status erneut verbinden.") else if (self.editor.state.locked or self.editor.suspended) self.t("Scheduler controls are unavailable while the session is locked or suspended.", "Scheduler-Steuerung ist bei gesperrter oder angehaltener Sitzung nicht verfügbar.") else self.t("Waiting for scheduler status…", "Warten auf Scheduler-Status…"));
            return;
        }
        if (self.editor.needs_snapshot) {
            // Snapshot invalidation accompanies every background status poll.
            // Gate commands while fetching fresh authority, but keep local-only
            // choices focused and open. Backend generations still reject races.
            self.rememberCommandFocus();
            self.apply.as(gtk.Widget).setSensitive(0);
            self.stop.as(gtk.Widget).setSensitive(0);
            self.refresh.as(gtk.Widget).setSensitive(0);
            self.text(self.observation, self.t("Last observed state · Checking for updates…", "Zuletzt beobachteter Status · Aktualisierung läuft…"));
            return;
        }
        const bytes = self.editor.live orelse {
            self.block(self.t("Waiting for scheduler status…", "Warten auf Scheduler-Status…"));
            return;
        };
        const hash = @import("editor_protocol.zig").digest(bytes);
        if (self.shown) |old| if (std.mem.eql(u8, &hash, &old)) {
            self.render();
            return;
        };
        var arena = std.heap.ArenaAllocator.init(a);
        const page = std.json.parseFromSliceLeaky(struct { sched_ext: ?m.Snapshot = null }, arena.allocator(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            arena.deinit();
            self.block(self.t("Scheduler status could not be read.", "Scheduler-Status konnte nicht gelesen werden."));
            return;
        };
        const snapshot = page.sched_ext orelse {
            arena.deinit();
            self.block(self.t("Scheduler management is unavailable in this Pearl backend.", "Die Scheduler-Verwaltung ist in diesem Pearl-Backend nicht verfügbar."));
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
        const scheduler = self.snapshot.catalog.find(self.selected.slice());
        // Keep widgets and handlers stable across snapshots. Hide the FlowBox
        // wrapper too, otherwise an absent mode leaves a blank grid cell.
        for (self.mode_buttons, std.enums.values(m.Mode)) |check, value| {
            const visible = if (scheduler) |s| s.arguments(value) != null else false;
            check.as(gtk.Widget).getParent().?.setVisible(@intFromBool(visible));
            check.setActive(@intFromBool(visible and value == self.selected_mode));
        }
    }
    fn modeLabel(self: *View, mode: m.Mode) [:0]const u8 {
        return modeTitle(mode, self.german);
    }
    fn render(self: *View) void {
        _ = self.render_arena.reset(.retain_capacity);
        const snapshot = self.snapshot;
        var own_pending = self.editor.live_command != null;
        for (self.editor.live_receipts) |receipt| if (receipt != null) {
            own_pending = true;
            break;
        };
        const pending = snapshot.pending or own_pending;
        const root = self.host.as(gtk.Widget).getRoot();
        if (pending) self.rememberCommandFocus();
        self.text(self.summary, snapshot.summary);
        self.summary.as(gtk.Widget).setVisible(@intFromBool(!snapshot.available));
        const consistent = m.consistent(snapshot.status, snapshot.kernel);
        self.text(self.badge, if (pending) self.t("Checking…", "Prüfen…") else if (!consistent) self.t("Unavailable", "Nicht verfügbar") else if (snapshot.status.kind == .running) self.t("Running", "Aktiv") else self.t("Kernel default", "Kernel-Standard"));
        self.text(self.observation, if (pending) self.t("Last observed state · Checking for updates…", "Zuletzt beobachteter Status · Aktualisierung läuft…") else self.t("Observed runtime · Independent of the selection below", "Beobachtete Laufzeit · Unabhängig von der Auswahl unten"));
        self.text(self.current, switch (snapshot.status.kind) {
            .unknown => self.t("Status unavailable", "Status nicht verfügbar"),
            .stopped => if (snapshot.kernel == .disabled) self.t("Kernel default", "Kernel-Standard") else self.t("External or unknown scheduler", "Externer oder unbekannter Scheduler"),
            .running => snapshot.status.scheduler orelse "",
        });
        self.text(self.detail, if (snapshot.status.kind == .stopped and snapshot.kernel == .disabled) self.t("No sched-ext scheduler is active.", "Kein sched-ext-Scheduler ist aktiv.") else snapshot.status.detail);
        const scheduler = self.snapshot.catalog.find(self.selected.slice());
        const args = if (scheduler) |s| s.arguments(self.selected_mode) else null;
        const same = if (scheduler) |s| m.matches(snapshot.status, snapshot.kernel, s, self.selected_mode) else false;
        const selected_available = scheduler != null and scheduler.?.installed and args != null;
        self.text(self.selection, if (pending) self.t("Updating scheduler…", "Scheduler wird aktualisiert…") else if (!selected_available) self.t("Selection unavailable · Choose an installed scheduler and mode", "Auswahl nicht verfügbar · Installierten Scheduler und Modus wählen") else if (same) self.t("Currently applied", "Aktuell angewendet") else self.t("Not applied", "Nicht angewendet"));
        var unavailable: std.ArrayList([]const u8) = .empty;
        for (snapshot.catalog.schedulers) |s| if (!s.installed) unavailable.append(self.render_arena.allocator(), s.name) catch {};
        self.text(self.installed, self.format("{d} installed schedulers", "{d} installierte Scheduler", .{self.names.len}));
        self.text(self.details_section.summary, if (unavailable.items.len > 0) self.format("{d} installed · {d} missing executables", "{d} installiert · {d} fehlende Programme", .{ self.names.len, unavailable.items.len }) else self.format("{d} installed · Selected mode arguments", "{d} installiert · Argumente des ausgewählten Modus", .{self.names.len}));
        self.text(self.missing, if (unavailable.items.len > 0) self.format("Missing executables: {s}. Refresh after installing outside Pearl.", "Fehlende Programme: {s}. Nach externer Installation aktualisieren.", .{std.mem.join(self.render_arena.allocator(), ", ", unavailable.items) catch ""}) else self.t("All catalog executables were found.", "Alle Programme des Katalogs wurden gefunden."));
        self.text(self.mode_note, if (args) |values| if (values.len > 0) self.t("Uses the configured arguments for this mode.", "Verwendet die konfigurierten Argumente dieses Modus.") else if (self.selected_mode == .auto) self.t("Uses scheduler defaults.", "Verwendet Scheduler-Standardwerte.") else self.t("No distinct arguments are configured for this mode. Uses scheduler defaults.", "Keine eigenen Argumente für diesen Modus konfiguriert. Verwendet Scheduler-Standardwerte.") else self.t("Select an available scheduler and mode.", "Verfügbaren Scheduler und Modus auswählen."));
        // JSON preserves argument boundaries, including whitespace and empty strings.
        self.text(self.arguments, if (args) |values| if (values.len == 0) self.t("Uses scheduler defaults", "Verwendet Scheduler-Standardwerte") else std.json.Stringify.valueAlloc(self.render_arena.allocator(), values, .{}) catch "" else "");
        self.text(self.boot, self.format("Configured boot default: {s} · {s}", "Konfigurierter Startstandard: {s} · {s}", .{ snapshot.catalog.default_sched orelse self.t("none", "keiner"), if (snapshot.catalog.default_mode) |mode| self.modeLabel(mode) else self.t("unknown mode", "unbekannter Modus") }));
        self.text(self.boot_section.summary, self.format("{s} · {s} · Read-only", "{s} · {s} · Schreibgeschützt", .{ snapshot.catalog.default_sched orelse self.t("No configured scheduler", "Kein Scheduler konfiguriert"), if (snapshot.catalog.default_mode) |value| self.modeLabel(value) else self.t("Unknown mode", "Unbekannter Modus") }));
        const feedback = if (own_pending) self.t("Waiting for observed runtime confirmation…", "Warten auf Bestätigung des Laufzeitstatus…") else snapshot.feedback;
        self.text(self.feedback, feedback);
        self.text(self.stop_feedback, feedback);
        self.feedback.as(gtk.Widget).setVisible(@intFromBool(feedback.len > 0 and self.last_action != .stop));
        self.stop_feedback.as(gtk.Widget).setVisible(@intFromBool(feedback.len > 0 and self.last_action == .stop));
        // Background polling must not close an open dropdown or remove keyboard
        // focus every three seconds. Local selection cannot mutate the service;
        // all command buttons remain gated by the full pending state.
        self.scheduler.as(gtk.Widget).setSensitive(@intFromBool(!own_pending and self.names.len > 0));
        self.mode.as(gtk.Widget).setSensitive(@intFromBool(!own_pending and scheduler != null and self.modes.len > 0));
        self.apply.as(gtk.Widget).setSensitive(@intFromBool(!pending and snapshot.available and args != null and scheduler != null and scheduler.?.installed and !same));
        self.stop.as(gtk.Widget).setSensitive(@intFromBool(!pending and snapshot.can_stop));
        self.refresh.as(gtk.Widget).setSensitive(@intFromBool(!pending));
        if (!pending) {
            if (self.restore_focus) |widget| if (root) |r| if (r.getFocus() == null and widget.isSensitive() != 0) {
                _ = widget.grabFocus();
            };
            self.restore_focus = null;
            // Announce changed settled evidence, never the generation or each
            // polling transition. GTK labels already expose readable text.
            const message = self.format("{s}. {s}. {s}", "{s}. {s}. {s}", .{ std.mem.span(self.current.getText()), std.mem.span(self.detail.getText()), if (feedback.len > 0) feedback else if (!snapshot.available) snapshot.summary else "" });
            const hash = @import("editor_protocol.zig").digest(message);
            if (self.announced) |old| if (!std.mem.eql(u8, &old, &hash)) {
                self.host.as(gtk.Accessible).announce(self.render_arena.allocator().dupeZ(u8, message) catch return, .medium);
            };
            self.announced = hash;
        }
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
    fn modeChanged(check: *gtk.CheckButton, self: *View) callconv(.c) void {
        if (self.filling or check.getActive() == 0) return;
        for (self.mode_buttons, std.enums.values(m.Mode)) |button, value| if (button == check) {
            self.selected_mode = value;
            break;
        };
        self.render();
    }
    fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *View) callconv(.c) c_int {
        if (modifiers.control_mask or modifiers.alt_mask or modifiers.super_mask or self.modes.len == 0 or self.mode.as(gtk.Widget).isSensitive() == 0) return 0;
        var current: usize = 0;
        for (self.modes, 0..) |value, i| if (value == self.selected_mode) {
            current = i;
            break;
        };
        const index = switch (key) {
            0xff51, 0xff52 => (current + self.modes.len - 1) % self.modes.len,
            0xff53, 0xff54 => (current + 1) % self.modes.len,
            0xff50 => 0,
            0xff57 => self.modes.len - 1,
            else => return 0,
        };
        const button = self.mode_buttons[@intFromEnum(self.modes[index])];
        button.setActive(1);
        _ = button.as(gtk.Widget).grabFocus();
        return 1;
    }
    fn send(self: *View, action: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const apply = std.mem.eql(u8, action, "apply");
        self.last_action = std.meta.stringToEnum(m.Action, action) orelse .refresh;
        const bytes = std.json.Stringify.valueAlloc(alloc, .{ .action = action, .generation = self.snapshot.generation, .scheduler = if (apply) self.selected.slice() else @as(?[]const u8, null), .mode = if (apply) self.selected_mode else @as(?m.Mode, null) }, .{ .emit_null_optional_fields = false }) catch return;
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return;
        self.editor.liveAction(.@"sched-ext.action", value) catch |err| {
            const target = if (self.last_action == .stop) self.stop_feedback else self.feedback;
            self.text(target, @errorName(err));
            target.as(gtk.Widget).setVisible(1);
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
    box.as(gtk.Widget).addCssClass("system-card");
    host.append(box.as(gtk.Widget));
    return box;
}
fn modeTitle(mode: m.Mode, german: bool) [:0]const u8 {
    return switch (mode) {
        .auto => if (german) "Automatisch" else "Auto",
        .gaming => "Gaming",
        .lowlatency => if (german) "Niedrige Latenz" else "Low latency",
        .powersave => if (german) "Energiesparen" else "Power saver",
        .server => "Server",
    };
}
fn dropdown(host: *gtk.Box, title: [:0]const u8) *gtk.DropDown {
    host.append(w.label(title, "pearl-secondary").as(gtk.Widget));
    const control = gtk.DropDown.new(null, null);
    control.as(gtk.Widget).setHexpand(1);
    host.append(control.as(gtk.Widget));
    return control;
}
