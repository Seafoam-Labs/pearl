//! Desktop session services share a connection, never the system bus.
const std = @import("std");
const t = @import("session_bus.zig");
const db = t.db;
const gio = db.gio;
const glib = db.glib;
pub const Session = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    bus: t.Bus = undefined,
    started: bool = false,
    notifications: @import("notifications.zig").Notifications = undefined,
    media: @import("mpris.zig").Media = undefined,
    tray: @import("tray.zig").Tray = undefined,
    pub fn start(self: *Session, filters: ?@import("notification_filter_policy.zig").Config) !void {
        self.bus = .{ .app = self.app, .context = self, .changed = connectionChanged, .signal = signal };
        self.notifications = .{ .bus = &self.bus, .context = self.context, .changed = self.changed };
        self.media = .{ .bus = &self.bus, .context = self.context, .changed = self.changed };
        self.tray = .{ .bus = &self.bus, .context = self.context, .changed = self.changed };
        if (filters) |config| try self.notifications.configure(config);
        self.started = true;
        self.bus.start();
    }
    pub fn stop(self: *Session) void {
        if (!self.started) return;
        self.started = false;
        self.bus.stop();
        self.notifications.deinitFilters();
    }
    fn connectionChanged(data: *anyopaque, connected: bool) void {
        const self: *Session = @ptrCast(@alignCast(data));
        if (connected) {
            self.notifications.start();
            self.media.start();
            self.tray.start();
        } else {
            self.notifications.stop();
            self.media.stop();
            self.tray.stop();
        }
        self.changed(self.context);
    }
    fn signal(_: *gio.DBusConnection, sender: ?[*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, member: [*:0]const u8, params: *glib.Variant, data: ?*anyopaque) callconv(.c) void {
        const self: *Session = @ptrCast(@alignCast(data.?));
        const owner = if (sender) |s| std.mem.span(s) else return;
        if (std.mem.eql(u8, owner, "org.freedesktop.DBus") and std.mem.eql(u8, std.mem.span(iface), "org.freedesktop.DBus") and std.mem.eql(u8, std.mem.span(path), "/org/freedesktop/DBus") and std.mem.eql(u8, std.mem.span(member), "NameOwnerChanged") and db.is(params, "(sss)")) {
            const name = t.childText(256, params, 0);
            const new = t.childText(256, params, 2);
            self.media.ownerChanged(name.z(), new.slice());
            self.tray.ownerChanged(name.z(), new.slice());
        } else {
            self.media.signal(owner, std.mem.span(path), std.mem.span(iface), std.mem.span(member), params);
            self.tray.signal(owner, std.mem.span(path), std.mem.span(iface), std.mem.span(member), params);
        }
    }
    pub fn act(self: *Session, r: @import("../cli/protocol.zig").Request) !void {
        switch (r.command.?) {
            .dnd_on, .dnd_off => self.notifications.setDnd(r.command.? == .dnd_on),
            .clear_history => {
                self.notifications.model.clearHistory();
                self.notifications.update();
            },
            .dismiss => if (!self.notifications.close(r.notification.?, 2)) {
                return error.InvalidValue;
            },
            .invoke => try self.notifications.invoke(r.notification.?, r.text.?),
            .select, .play_pause, .play, .pause, .stop, .next, .previous, .seek => try self.media.act(r.generation.?, std.meta.stringToEnum(@import("mpris.zig").Action, @tagName(r.command.?)).?, r.position orelse 0),
            .tray_activate, .tray_secondary => try self.tray.activate(r.generation.?, r.command.? == .tray_secondary),
            .tray_menu => try self.tray.openMenu(r.generation.?, r.menu_id orelse 0),
            .tray_click => try self.tray.menuClick(r.generation.?, r.revision.?, r.menu_id.?),
        }
    }
    pub fn status(self: *Session, a: std.mem.Allocator, offset: usize) ![]const u8 {
        const N = struct { id: u32, app: []const u8, summary: []const u8, active: bool, toast: bool, actions: usize };
        const P = struct { generation: u64, name: []const u8, title: []const u8, playback: []const u8, ready: bool, busy: bool, position: i64, length: i64, seek: bool };
        const I = struct { generation: u64, registration: []const u8, title: []const u8, ready: bool, image: bool, menu_ready: bool, menu_revision: u64, nodes: usize };
        var notes: std.ArrayList(N) = .empty;
        var players: std.ArrayList(P) = .empty;
        var items: std.ArrayList(I) = .empty;
        var n: usize = 0;
        var active: usize = 0;
        var toasts: usize = 0;
        var pcount: usize = 0;
        var icount: usize = 0;
        for (&self.notifications.model.records) |*r| if (r.id != 0) {
            if (r.active) active += 1;
            if (r.toast_until > 0) toasts += 1;
            if (n >= offset and n < offset + 4) try notes.append(a, .{ .id = r.id, .app = preview(r.app.slice()), .summary = if (self.notifications.model.locked) "" else preview(r.summary.slice()), .active = r.active, .toast = r.toast_until > 0, .actions = r.action_count });
            n += 1;
        };
        for (&self.media.players) |*p| if (p.name.len != 0) {
            if (pcount >= offset and pcount < offset + 4) try players.append(a, .{ .generation = p.generation, .name = p.name.slice(), .title = preview(p.title.slice()), .playback = p.playback.slice(), .ready = p.ready, .busy = p.busy, .position = p.progress(), .length = p.length, .seek = p.seek });
            pcount += 1;
        };
        for (&self.tray.items) |*item| if (item.name.len != 0) {
            if (icount >= offset and icount < offset + 4) try items.append(a, .{ .generation = item.generation, .registration = preview(item.registration.slice()), .title = preview(item.title.slice()), .ready = item.ready, .image = item.image != null, .menu_ready = item.menu_ready, .menu_revision = item.menu_revision, .nodes = item.node_count });
            icount += 1;
        };
        return std.json.Stringify.valueAlloc(a, .{
            .connected = self.bus.conn != null,
            .jobs = self.bus.jobs,
            .notifications = .{ .available = self.notifications.available, .dnd = self.notifications.model.dnd, .locked = self.notifications.model.locked, .count = n, .active = active, .toasts = @min(3, toasts), .records = notes.items },
            .media = .{ .count = pcount, .selected = self.media.selected, .timer = self.media.timer != 0, .views = self.media.viewers, .err = self.media.err, .players = players.items },
            .tray = .{ .watcher = self.tray.watcher, .external = self.tray.external.slice(), .count = icount, .err = self.tray.err, .items = items.items },
            .next_offset = if (offset + 4 < @max(n, @max(pcount, icount))) @as(?usize, offset + 4) else null,
        }, .{});
    }
};
fn preview(value: []const u8) []const u8 {
    var n = @min(96, value.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(value[0..n])) n -= 1;
    return value[0..n];
}
