//! Virtualized launcher. One cancellable ranking job per view; no GTK in workers.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const unix = @import("giounix2");
const glib = @import("glib2");
const object = @import("gobject2");
const apps = @import("apps.zig");
const policy = @import("policy.zig");
const tr = @import("text.zig").tr;
const widgets = @import("../ui/components/widgets.zig");
const Client = @import("../aqueous/client.zig").Client;
const a = std.heap.c_allocator;
const Window = struct { id: [:0]const u8, name: [:0]const u8, detail: [:0]const u8, keywords: [:0]const u8, visible: bool };
const Hit = struct { kind: enum { app, window }, index: usize, score: i32, id: []const u8, name: [:0]const u8, detail: [:0]const u8 };
const Job = struct {
    arena: std.heap.ArenaAllocator,
    catalog: ?*apps.Catalog,
    query: []const u8,
    windows: std.ArrayList(Window) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    generation: u64,
    started: i64,
    recent: []const []const u8,
    session: [32]u8,
    fn destroy(self: *Job) void {
        if (self.catalog) |c| c.release();
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Launcher = struct {
    app: *gio.Application,
    display: *gdk.Display,
    index: *apps.Index,
    client: *Client,
    context: *anyopaque,
    dismiss: *const fn (*anyopaque) void,
    search: *gtk.SearchEntry,
    strings: *gtk.StringList,
    selection: *gtk.SingleSelection,
    list: *gtk.ListView,
    message: *gtk.Label,
    shown: ?*Job = null,
    pending: bool = false,
    waiting: bool = false,
    activate_pending: bool = false,
    dirty: bool = false,
    stopping: bool = false,
    generation: u64 = 0,
    cancel: ?*gio.Cancellable = null,
    count: usize = 0,
    latency_us: i64 = 0,
    request_started: i64 = 0,
    render_started: ?i64 = null,
    clock: ?*gdk.FrameClock = null,
    paint_signal: c_ulong = 0,
    connections: [6]struct { instance: *object.Object, id: c_ulong } = undefined,
    connection_count: usize = 0,
    pub fn observeFrame(self: *Launcher, clock: *gdk.FrameClock) void {
        self.clock = clock;
        _ = clock.ref();
        self.paint_signal = gdk.FrameClock.signals.after_paint.connect(clock, *Launcher, painted, self, .{});
    }
    fn painted(_: *gdk.FrameClock, self: *Launcher) callconv(.c) void {
        if (self.render_started) |start| {
            self.render_started = null;
            self.latency_us = glib.getMonotonicTime() - start;
            std.log.info("event=launcher-painted latency_us={d}", .{self.latency_us});
        }
    }
    fn connect(self: *Launcher, instance: *object.Object, id: c_ulong) void {
        self.connections[self.connection_count] = .{ .instance = instance, .id = id };
        self.connection_count += 1;
    }
    pub fn create(host: *gtk.Box, app: *gio.Application, display: *gdk.Display, index: *apps.Index, client: *Client, context: *anyopaque, dismiss: @FieldType(Launcher, "dismiss")) !*Launcher {
        const self = try a.create(Launcher);
        host.append(widgets.label(tr("Find your next thing", "Was möchtest du als Nächstes tun?"), "pearl-card-title").as(gtk.Widget));
        const search = gtk.SearchEntry.new();
        search.setSearchDelay(0);
        search.setPlaceholderText(tr("Search applications and windows", "Programme und Fenster suchen"));
        search.as(gtk.Widget).setName("launcher-search");
        host.append(search.as(gtk.Widget));
        const strings = gtk.StringList.new(null);
        _ = strings.ref();
        const selection = gtk.SingleSelection.new(strings.as(gio.ListModel));
        _ = selection.ref();
        const factory = gtk.SignalListItemFactory.new();
        const list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        list.setSingleClickActivate(1);
        list.setTabBehavior(.item);
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(list.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        const message = widgets.label(tr("Loading applications…", "Programme werden geladen…"), "pearl-secondary");
        host.append(message.as(gtk.Widget));
        self.* = .{ .app = app, .display = display, .index = index, .client = client, .context = context, .dismiss = dismiss, .search = search, .strings = strings, .selection = selection, .list = list, .message = message };
        self.connect(factory.as(object.Object), gtk.SignalListItemFactory.signals.setup.connect(factory, *Launcher, setup, self, .{}));
        self.connect(factory.as(object.Object), gtk.SignalListItemFactory.signals.bind.connect(factory, *Launcher, bind, self, .{}));
        self.connect(search.as(object.Object), gtk.SearchEntry.signals.search_changed.connect(search, *Launcher, changed, self, .{}));
        self.connect(search.as(object.Object), gtk.SearchEntry.signals.activate.connect(search, *Launcher, entered, self, .{}));
        self.connect(list.as(object.Object), gtk.ListView.signals.activate.connect(list, *Launcher, activated, self, .{}));
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        self.connect(keys.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(keys, *Launcher, key, self, .{}));
        search.as(gtk.Widget).addController(keys.as(gtk.EventController));
        self.refresh();
        return self;
    }
    pub fn destroy(self: *Launcher) void {
        self.stopping = true;
        if (self.clock) |clock| {
            if (object.signalHandlerIsConnected(clock.as(object.Object), self.paint_signal) != 0) object.signalHandlerDisconnect(clock.as(object.Object), self.paint_signal);
            clock.unref();
            self.clock = null;
        }
        for (self.connections[0..self.connection_count]) |connection| {
            if (object.signalHandlerIsConnected(connection.instance, connection.id) != 0) object.signalHandlerDisconnect(connection.instance, connection.id);
        }
        self.connection_count = 0;
        if (self.cancel) |c| c.cancel();
        // The parent destroys widgets immediately after this call. Retained models
        // and job state survive only until the pending callback has drained.
        if (!self.pending) self.free();
    }
    fn free(self: *Launcher) void {
        self.selection.unref();
        self.strings.unref();
        if (self.shown) |j| j.destroy();
        a.destroy(self);
    }
    pub fn refresh(self: *Launcher) void {
        if (self.stopping) return;
        self.generation += 1;
        self.request_started = glib.getMonotonicTime();
        if (self.pending) {
            self.dirty = true;
            return;
        }
        self.begin() catch |err| self.message.setText(if (err == error.Busy) tr("Searching…", "Suche läuft…") else tr("Search is unavailable", "Suche nicht verfügbar"));
    }
    fn begin(self: *Launcher) !void {
        if (self.index.searches >= 2) {
            self.index.search_waiter = true;
            self.waiting = true;
            return error.Busy;
        }
        self.waiting = false;
        const job = try a.create(Job);
        job.* = .{ .arena = std.heap.ArenaAllocator.init(a), .catalog = if (self.index.catalog) |c| c.retain() else null, .query = "", .generation = self.generation, .started = self.request_started, .recent = &.{}, .session = self.client.model.session[0..32].* };
        errdefer job.destroy();
        const alloc = job.arena.allocator();
        const query = std.mem.span(self.search.as(gtk.Editable).getText());
        if (query.len > 512) return error.QueryTooLong;
        job.query = try alloc.dupe(u8, query);
        const recent = try alloc.alloc([]const u8, self.index.recent.items.len);
        for (self.index.recent.items, 0..) |id, i| recent[i] = try alloc.dupe(u8, id);
        job.recent = recent;
        var it = self.client.model.entities.valueIterator();
        while (it.next()) |entity| {
            if (entity.* != .window or !policy.eligible(entity.window)) continue;
            const w = entity.window;
            if (job.windows.items.len >= 4096) break;
            const output = if (w.output) |id| self.client.model.get(.output, id) else null;
            if (output == null or !output.?.enabled or !output.?.powered) continue;
            const workspace = if (w.workspace) |id| self.client.model.get(.workspace, id) else null;
            const app_id = w.app_id orelse w.class orelse "";
            const title = w.title orelse app_id;
            if (title.len > 4096 or app_id.len > 1024) continue;
            const detail = try std.fmt.allocPrintSentinel(alloc, "{s} · {s} · {s} · {s}", .{ app_id, output.?.name, if (workspace) |ws| ws.name else "—", if (w.minimized) tr("Minimized", "Minimiert") else if (w.visible) tr("Visible window", "Sichtbares Fenster") else tr("Other workspace", "Andere Arbeitsfläche") }, 0);
            try job.windows.append(alloc, .{ .id = try alloc.dupeZ(u8, w.id), .name = try alloc.dupeZ(u8, title), .detail = detail, .keywords = try alloc.dupeZ(u8, app_id), .visible = w.visible });
        }
        self.pending = true;
        self.index.searches += 1;
        self.cancel = gio.Cancellable.new();
        self.app.hold();
        const task = gio.Task.new(null, self.cancel, completed, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(rank);
        task.unref();
    }
    fn rank(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        rankJob(job, cancel.?) catch {
            job.hits.clearRetainingCapacity();
        };
        task.returnPointer(job, null);
    }
    fn rankJob(job: *Job, cancel: *gio.Cancellable) !void {
        const alloc = job.arena.allocator();
        const query = try apps.fold(alloc, job.query);
        if (job.catalog) |catalog| for (catalog.entries.items, 0..) |entry, i| {
            if (cancel.isCancelled() != 0) return error.Canceled;
            var recent: i32 = 0;
            for (job.recent, 0..) |id, n| if (std.mem.eql(u8, id, entry.id)) {
                recent = @intCast(32 - n);
                break;
            };
            if (query.len == 0 and entry.action != null) continue;
            const score = policy.score(query, entry.folded, entry.keywords, recent != 0, false, false) orelse continue;
            try job.hits.append(alloc, .{ .kind = .app, .index = i, .score = score + recent, .id = entry.key, .name = entry.name, .detail = entry.detail });
        };
        for (job.windows.items, 0..) |w, i| {
            if (cancel.isCancelled() != 0) return error.Canceled;
            const score = policy.score(query, try apps.fold(alloc, w.name), try apps.fold(alloc, w.keywords), false, true, w.visible) orelse continue;
            try job.hits.append(alloc, .{ .kind = .window, .index = i, .score = score, .id = w.id, .name = w.name, .detail = w.detail });
        }
        std.mem.sort(Hit, job.hits.items, {}, less);
    }
    fn less(_: void, x: Hit, y: Hit) bool {
        if (x.score != y.score) return x.score > y.score;
        const name_order = std.mem.order(u8, x.name, y.name);
        if (name_order != .eq) return name_order == .lt;
        if (x.kind != y.kind) return x.kind == .window;
        const id_order = std.mem.order(u8, x.id, y.id);
        return if (id_order == .eq) x.index < y.index else id_order == .lt;
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Launcher = @ptrCast(@alignCast(data.?));
        const app = self.app;
        const index = self.index;
        index.searches -= 1;
        defer if (index.search_waiter and !index.stopping) {
            index.search_waiter = false;
            index.changed(index.context);
        };
        const job: *Job = @ptrCast(@alignCast(object.ext.cast(gio.Task, result).?.propagatePointer(null).?));
        self.pending = false;
        self.cancel.?.unref();
        self.cancel = null;
        if (self.stopping) {
            job.destroy();
            self.free();
            app.release();
            return;
        }
        if (job.generation == self.generation and std.mem.eql(u8, &job.session, self.client.model.session)) self.publish(job) else job.destroy();
        if (self.dirty) {
            self.dirty = false;
            self.begin() catch {};
        }
        if (!self.pending and self.activate_pending) {
            self.activate_pending = false;
            self.activate(self.selection.getSelected());
        }
        app.release();
    }
    fn publish(self: *Launcher, job: *Job) void {
        const old = self.shown;
        var selected_id: ?[]const u8 = null;
        var selected_kind: ?@FieldType(Hit, "kind") = null;
        if (old) |j| if (std.mem.eql(u8, j.query, job.query) and self.selection.getSelected() < j.hits.items.len) {
            const h = j.hits.items[self.selection.getSelected()];
            selected_id = h.id;
            selected_kind = h.kind;
        };
        self.shown = job;
        self.count = @min(job.hits.items.len, 200);
        var values: [201:null]?[*:0]const u8 = @splat(null);
        var selected: c_uint = 0;
        for (job.hits.items[0..self.count], 0..) |hit, i| {
            values[i] = hit.name;
            if (selected_id) |id| if (hit.kind == selected_kind.? and std.mem.eql(u8, id, hit.id)) {
                selected = @intCast(i);
            };
        }
        self.strings.splice(0, self.strings.as(gio.ListModel).getNItems(), @ptrCast(&values));
        self.selection.setSelected(selected);
        if (old) |j| j.destroy();
        var buffer: [180]u8 = undefined;
        const message = if (self.count == 0) (if (self.index.pending) tr("Loading applications…", "Programme werden geladen…") else if (self.index.failed) tr("Application discovery unavailable", "Programmsuche nicht verfügbar") else tr("No matches. Try another name.", "Keine Treffer. Versuche einen anderen Namen.")) else std.fmt.bufPrintZ(&buffer, "{d} · {s}", .{ job.hits.items.len, tr("results · ↑ ↓ to choose · Enter to open", "Ergebnisse · ↑ ↓ wählen · Eingabe öffnen") }) catch unreachable;
        const detail = if (job.hits.items.len > self.count) std.fmt.bufPrintZ(&buffer, "{d} / {d} · {s}", .{ self.count, job.hits.items.len, tr("Refine your search for more results", "Suche eingrenzen für weitere Ergebnisse") }) catch unreachable else message;
        self.message.setText(detail);
        self.render_started = job.started;
        std.log.info("event=launcher-results count={d} shown={d} publish_us={d}", .{ job.hits.items.len, self.count, glib.getMonotonicTime() - job.started });
    }
    fn changed(_: *gtk.SearchEntry, self: *Launcher) callconv(.c) void {
        self.refresh();
    }
    fn entered(_: *gtk.SearchEntry, self: *Launcher) callconv(.c) void {
        self.activate(self.selection.getSelected());
    }
    fn activated(_: *gtk.ListView, position: c_uint, self: *Launcher) callconv(.c) void {
        self.activate(position);
    }
    fn key(_: *gtk.EventControllerKey, value: c_uint, _: c_uint, _: gdk.ModifierType, self: *Launcher) callconv(.c) c_int {
        if (value != 0xff54 and value != 0xff52) return 0;
        if (self.count == 0) return 1;
        const old = @min(self.selection.getSelected(), @as(c_uint, @intCast(self.count - 1)));
        const position = if (value == 0xff54) @min(old + 1, @as(c_uint, @intCast(self.count - 1))) else old -| 1;
        self.selection.setSelected(position);
        self.list.scrollTo(position, .{}, null);
        return 1;
    }
    fn activate(self: *Launcher, position: c_uint) void {
        if (self.pending or self.waiting) {
            self.activate_pending = true;
            return;
        }
        self.open(position) catch |err| {
            std.log.info("event=launcher-error error={s}", .{@errorName(err)});
            self.message.setText(tr("Could not open this result. Try again or choose another.", "Öffnen fehlgeschlagen. Versuche es erneut oder wähle einen anderen Eintrag."));
            return;
        };
        self.dismiss(self.context);
    }
    fn open(self: *Launcher, position: c_uint) !void {
        const job = self.shown orelse return error.Unavailable;
        if (job.generation != self.generation or position >= self.count or self.client.availability != .ready or !std.mem.eql(u8, &job.session, self.client.model.session)) return error.StaleResult;
        if (self.client.model.get(.session, "session").?.locked) return error.Locked;
        const hit = job.hits.items[position];
        if (hit.kind == .window) {
            const w = self.client.model.get(.window, hit.id) orelse return error.StaleResult;
            if (!policy.eligible(w.*)) return error.StaleResult;
            _ = try self.client.enqueue(.{ .window_activate = .{ .id = hit.id } });
            return;
        }
        const entry = job.catalog.?.entries.items[hit.index];
        // Re-read by desktop ID: removed/hidden entries must not launch from an old result.
        const desktop = unix.DesktopAppInfo.new(entry.id) orelse return error.StaleResult;
        defer desktop.unref();
        if (desktop.as(gio.AppInfo).shouldShow() == 0) return error.StaleResult;
        const context = self.display.getAppLaunchContext();
        defer context.unref();
        context.setTimestamp(0);
        if (entry.action) |action| {
            var found = false;
            const actions: [*:null]const ?[*:0]const u8 = @ptrCast(desktop.listActions());
            var i: usize = 0;
            while (actions[i]) |v| : (i += 1) if (std.mem.eql(u8, action, std.mem.span(v))) {
                found = true;
                break;
            };
            if (!found) return error.StaleResult;
            desktop.launchAction(action, context.as(gio.AppLaunchContext));
        } else {
            var err: ?*glib.Error = null;
            defer if (err) |e| e.free();
            if (desktop.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) == 0) return error.LaunchFailed;
        }
        self.index.remember(entry.id);
        std.log.info("event=application-launch accepted=true action={}", .{entry.action != null});
    }
    fn setup(_: *gtk.SignalListItemFactory, obj: *object.Object, _: *Launcher) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const row = widgets.row(12);
        row.as(gtk.Widget).addCssClass("pearl-launcher-row");
        const icon = gtk.Image.new();
        icon.setPixelSize(28);
        row.append(icon.as(gtk.Widget));
        const labels = widgets.column(2);
        labels.as(gtk.Widget).setHexpand(1);
        for ([_]?[*:0]const u8{ null, "pearl-secondary" }) |class| {
            const label = gtk.Label.new("");
            label.setXalign(0);
            label.setEllipsize(.end);
            label.setMaxWidthChars(48);
            if (class) |v| label.as(gtk.Widget).addCssClass(v);
            labels.append(label.as(gtk.Widget));
        }
        row.append(labels.as(gtk.Widget));
        item.setChild(row.as(gtk.Widget));
    }
    fn bind(_: *gtk.SignalListItemFactory, obj: *object.Object, self: *Launcher) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const job = self.shown orelse return;
        const position = item.getPosition();
        if (position >= self.count) return;
        const hit = job.hits.items[position];
        const row = item.getChild().?;
        const icon = object.ext.cast(gtk.Image, row.getFirstChild().?).?;
        icon.setFromIconName(if (hit.kind == .window) "pearl-window-symbolic" else "pearl-application-x-executable-symbolic");
        if (hit.kind == .app) if (job.catalog.?.entries.items[hit.index].info.getIcon()) |gicon| {
            if (object.ext.cast(gio.ThemedIcon, gicon)) |themed| {
                const names: [*:null]const ?[*:0]const u8 = @ptrCast(themed.getNames());
                const theme = gtk.IconTheme.getForDisplay(self.display);
                var i: usize = 0;
                while (names[i]) |name| : (i += 1) if (theme.hasIcon(name) != 0) {
                    icon.setFromIconName(name);
                    break;
                };
            } else icon.setFromGicon(gicon);
        };
        const labels = row.getLastChild().?;
        object.ext.cast(gtk.Label, labels.getFirstChild().?).?.setText(hit.name);
        object.ext.cast(gtk.Label, labels.getLastChild().?).?.setText(hit.detail);
        item.setAccessibleLabel(hit.name);
        item.setAccessibleDescription(hit.detail);
        row.setTooltipText(hit.detail);
    }
};
