//! Process-wide asynchronous connection coordinator. GTK stays on its main loop.
const std = @import("std");
const u = @import("../ui.zig");
const c = @import("connections.zig");
const Window = @import("../window.zig").Window;
const a = u.a;
const gio = u.gio;
const glib = u.glib;
const gtk = u.gtk;
const object = u.object;
pub const State = enum { disconnected, queued, connecting, connected, needs_auth, review, failed, unsupported };
pub const Entry = struct { id: [:0]u8, uri: [:0]u8, state: State = .disconnected, detail: [:0]const u8 = "", suppressed: bool = false };
const Intent = struct { owner: *Window, tab: u64, generation: u64 };
const Target = struct { id: [:0]u8, uri: [:0]u8, intent: ?Intent };
const Request = struct {
    manager: *Manager,
    key: [:0]u8,
    file: *gio.File,
    cancel: *gio.Cancellable,
    operation: *gio.MountOperation,
    parent: ?*Window,
    targets: std.ArrayList(Target) = .empty,
    timer: c_uint = 0,
    ticks: u32 = 0,
    background: bool,
    cancelled: bool = false,
    timed_out: bool = false,
    interaction: State = .disconnected,
    disconnect: bool = false,
};
pub var shared: ?*Manager = null;
pub var changed: ?*const fn () void = null;
pub const Manager = struct {
    app: *gtk.Application,
    store: c.Store,
    entries: std.ArrayList(Entry) = .empty,
    requests: std.ArrayList(*Request) = .empty,
    volume_monitor: *gio.VolumeMonitor,
    volume_signals: [3]c_ulong = undefined,
    file_monitor: ?*gio.FileMonitor = null,
    monitor_signal: c_ulong = 0,
    notify_id: c_uint = 0,
    reload_id: c_uint = 0,
    startup_id: c_uint = 0,
    started: bool = false,
    closing: bool = false,
    attempts: usize = 0,

    pub fn init(app: *gtk.Application) *Manager {
        const self = a.create(Manager) catch unreachable;
        const dir = u.format("{s}/phyto", .{glib.getUserConfigDir()});
        defer a.free(dir);
        _ = glib.mkdirWithParents(dir, 0o700);
        const path = u.format("{s}/connections.ini", .{dir});
        defer a.free(path);
        self.* = .{ .app = app, .store = c.Store.init(path), .volume_monitor = gio.VolumeMonitor.get() };
        shared = self;
        const file = gio.File.newForPath(path);
        defer file.unref();
        self.file_monitor = file.monitorFile(.{}, null, null);
        if (self.file_monitor) |m| self.monitor_signal = object.signalConnectData(m.as(object.Object), "changed", @ptrCast(&fileChanged), self, null, .{});
        inline for (.{ "mount-added", "mount-removed", "mount-changed" }, 0..) |name, i| self.volume_signals[i] = object.signalConnectData(self.volume_monitor.as(object.Object), name, @ptrCast(&mountsChanged), self, null, .{});
        self.syncProfiles();
        return self;
    }
    pub fn deinit(self: *Manager) void {
        std.debug.assert(self.requests.items.len == 0);
        self.closing = true;
        inline for (.{ "notify_id", "reload_id", "startup_id" }) |field| if (@field(self, field) != 0) {
            _ = glib.Source.remove(@field(self, field));
        };
        if (self.file_monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.monitor_signal);
            _ = m.cancel();
            m.unref();
        }
        for (self.volume_signals) |id| object.signalHandlerDisconnect(self.volume_monitor.as(object.Object), id);
        self.volume_monitor.unref();
        for (self.entries.items) |e| {
            a.free(e.id);
            a.free(e.uri);
        }
        self.entries.deinit(a);
        self.requests.deinit(a);
        self.store.deinit();
        shared = null;
        a.destroy(self);
    }
    pub fn entry(self: *Manager, id: []const u8) ?*Entry {
        for (self.entries.items) |*e| if (c.eq(e.id, id)) return e;
        return null;
    }
    pub fn syncProfiles(self: *Manager) void {
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            const p = self.store.get(e.id);
            if (p == null or !c.eq(p.?.uri, e.uri)) {
                self.cancel(e.id);
                a.free(e.id);
                a.free(e.uri);
                _ = self.entries.orderedRemove(i);
            }
        }
        for (self.store.profiles.items) |p| if (self.entry(p.id) == null) {
            self.entries.append(a, .{ .id = c.dup(p.id), .uri = c.dup(p.uri) }) catch unreachable;
        };
        self.reconcile();
        self.notify();
    }
    pub fn notify(self: *Manager) void {
        if (!self.closing and self.notify_id == 0) self.notify_id = glib.idleAdd(notifyIdle, self);
    }
    fn notifyIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.notify_id = 0;
        if (changed) |cb| cb();
        return 0;
    }
    fn fileChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, _: gio.FileMonitorEvent, self: *Manager) callconv(.c) void {
        if (self.reload_id == 0) self.reload_id = glib.timeoutAdd(100, reloadIdle, self);
    }
    fn reloadIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.reload_id = 0;
        // Ignore our own atomic-save notifications (and unrelated file events).
        const file = gio.File.newForPath(self.store.path);
        defer file.unref();
        const info = file.queryInfo("etag::value", .{}, null, null);
        defer if (info) |v| v.unref();
        const tag = if (info) |v| v.getAttributeString("etag::value") else null;
        if ((tag == null) != (self.store.etag == null) or (tag != null and !c.eq(std.mem.span(tag.?), std.mem.span(self.store.etag.?)))) {
            self.store.reload();
            self.syncProfiles();
        }
        return 0;
    }
    fn mountsChanged(_: *gio.VolumeMonitor, _: *gio.Mount, self: *Manager) callconv(.c) void {
        self.reconcile();
        self.notify();
    }
    pub fn mounted(self: *Manager, uri: [:0]const u8) ?*gio.Mount {
        const file = gio.File.newForUri(uri);
        defer file.unref();
        const list = g_volume_monitor_get_mounts(self.volume_monitor) orelse return null;
        defer list.free();
        var found: ?*gio.Mount = null;
        var node: ?*glib.List = list;
        while (node) |n| : (node = n.f_next) {
            const mount: *gio.Mount = @ptrCast(@alignCast(n.f_data.?));
            const root = mount.getRoot();
            if (found == null and (file.equal(root) != 0 or file.hasPrefix(root) != 0)) {
                mount.ref();
                found = mount;
            }
            root.unref();
            mount.unref();
        }
        return found;
    }
    pub fn represents(self: *Manager, mount: *gio.Mount) bool {
        const root = mount.getRoot();
        defer root.unref();
        for (self.entries.items) |e| {
            const file = gio.File.newForUri(e.uri);
            defer file.unref();
            if (file.equal(root) != 0 or file.hasPrefix(root) != 0) return true;
        }
        return false;
    }
    fn reconcile(self: *Manager) void {
        for (self.entries.items) |*e| {
            if (e.state == .connecting) continue;
            if (self.mounted(e.uri)) |m| {
                m.unref();
                e.state = .connected;
                e.detail = "";
            } else if (e.state == .connected) e.state = .disconnected;
        }
    }
    pub fn startup(self: *Manager) void {
        if (self.started) return;
        self.started = true;
        for (self.store.profiles.items) |p| if (p.policy == .on_open) {
            if (self.entry(p.id)) |e| if (e.state != .connected) {
                e.state = .queued;
            };
        };
        self.startup_id = glib.idleAdd(startupIdle, self);
    }
    fn startupIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.startup_id = 0;
        self.pump();
        return 0;
    }
    fn pump(self: *Manager) void {
        if (self.closing) return;
        for (self.entries.items) |e| {
            var count: usize = 0;
            for (self.requests.items) |r| if (r.background) {
                count += 1;
            };
            if (count >= 2) break;
            if (e.state == .queued and !e.suppressed) self.connect(e.id, null);
        }
        self.notify();
    }
    pub fn connect(self: *Manager, id: []const u8, owner: ?*Window) void {
        const e = self.entry(id) orelse return;
        if (self.closing) return;
        const intent: ?Intent = if (owner) |w| .{ .owner = w, .tab = w.current().id, .generation = w.current().generation } else null;
        if (self.mounted(e.uri)) |m| {
            m.unref();
            e.state = .connected;
            e.detail = "";
            if (intent) |v| navigate(v, e.uri);
            self.notify();
            return;
        }
        const key = c.mountKey(e.uri);
        for (self.requests.items) |r| if (!r.cancelled and !r.disconnect and c.eq(r.key, key)) {
            a.free(key);
            for (r.targets.items) |*t| if (c.eq(t.id, id) and (t.intent == null or (intent != null and t.intent.?.owner == intent.?.owner and t.intent.?.tab == intent.?.tab))) {
                if (intent != null) t.intent = intent;
                e.state = .connecting;
                self.notify();
                return;
            };
            r.targets.append(a, .{ .id = c.dup(id), .uri = c.dup(e.uri), .intent = intent }) catch unreachable;
            e.state = .connecting;
            self.notify();
            return;
        };
        const r = a.create(Request) catch unreachable;
        r.* = .{ .manager = self, .key = key, .file = gio.File.newForUri(e.uri), .cancel = gio.Cancellable.new(), .operation = if (owner) |w| gtk.MountOperation.new(w.window).as(gio.MountOperation) else gio.MountOperation.new(), .parent = owner, .background = owner == null };
        if (r.background) {
            _ = object.signalConnectData(r.operation.as(object.Object), "ask-password", @ptrCast(&deferPassword), r, null, .{});
            _ = object.signalConnectData(r.operation.as(object.Object), "ask-question", @ptrCast(&deferQuestion), r, null, .{});
        }
        r.targets.append(a, .{ .id = c.dup(id), .uri = c.dup(e.uri), .intent = intent }) catch unreachable;
        self.requests.append(a, r) catch unreachable;
        e.state = .connecting;
        e.detail = "";
        self.app.as(gio.Application).hold();
        r.timer = glib.timeoutAdd(1000, tick, r);
        self.attempts += 1;
        r.file.findEnclosingMountAsync(0, r.cancel, foundMount, r);
        self.notify();
    }
    fn foundMount(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Request = @ptrCast(@alignCast(data.?));
        const m = r.file.findEnclosingMountFinish(result, null);
        if (m) |mount| {
            mount.unref();
            finish(r, null);
            return;
        }
        if (r.cancelled or r.timed_out) {
            finish(r, null);
            return;
        }
        r.file.mountEnclosingVolume(.{}, r.operation, r.cancel, mountedReady, r);
    }
    fn mountedReady(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Request = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        _ = r.file.mountEnclosingVolumeFinish(result, &err);
        defer if (err) |e| e.free();
        finish(r, err);
    }
    fn deferPassword(op: *gio.MountOperation, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: gio.AskPasswordFlags, r: *Request) callconv(.c) void {
        r.interaction = .needs_auth;
        object.signalStopEmissionByName(op.as(object.Object), "ask-password");
        op.reply(.aborted);
    }
    fn deferQuestion(op: *gio.MountOperation, _: [*:0]const u8, _: [*:null]?[*:0]const u8, r: *Request) callconv(.c) void {
        r.interaction = .review;
        object.signalStopEmissionByName(op.as(object.Object), "ask-question");
        // GVfs DAV versions check handled + choice, but ignore aborted when
        // accepting certificates. An unanswered question must be unhandled:
        // aborted can otherwise accept the default (first) choice.
        op.reply(.unhandled);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const r: *Request = @ptrCast(@alignCast(data.?));
        if (!r.background and !r.cancelled and object.ext.cast(gtk.MountOperation, r.operation).?.isShowing() != 0) return 1;
        r.ticks += 1;
        if (r.ticks < 20) return 1;
        r.timer = 0;
        r.timed_out = true;
        r.cancel.cancel();
        return 0;
    }
    fn navigate(intent: Intent, uri: [:0]const u8) void {
        if (intent.owner.closed) return;
        const tab = intent.owner.findTab(intent.tab) orelse return;
        if (tab.generation != intent.generation) return;
        const f = gio.File.newForUri(uri);
        defer f.unref();
        tab.navigate(f, true);
        intent.owner.queueUpdate();
    }
    fn finish(r: *Request, err: ?*glib.Error) void {
        const self = r.manager;
        var state: State = if (r.disconnect or r.cancelled) .disconnected else if (r.timed_out) .failed else .connected;
        var detail: [:0]const u8 = if (r.timed_out) "Connection timed out. Check the network and retry." else "";
        if (!r.cancelled and !r.timed_out) {
            if (r.interaction != .disconnected) {
                state = r.interaction;
                detail = "Click the device to continue securely.";
            } else if (err) |e| {
                if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.already_mounted)) == 0) {
                    state = .failed;
                    detail = "Could not connect. Check the server address, network and access permissions, then retry.";
                    if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_supported)) != 0) {
                        state = .unsupported;
                        detail = "Protocol support is unavailable. Install the appropriate GVfs backend for this connection.";
                    }
                    if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.cancelled)) != 0 or e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.failed_handled)) != 0) {
                        state = .disconnected;
                        detail = "Connection cancelled. The device is still saved.";
                    }
                    if (r.disconnect) detail = "Could not disconnect. The device may be busy; close files and retry.";
                }
            }
        }
        for (r.targets.items) |t| {
            const e = self.entry(t.id) orelse continue;
            if (!c.eq(e.uri, t.uri) or r.cancelled) continue;
            e.state = state;
            e.detail = detail;
            if (t.intent) |intent| {
                if (state == .connected and !r.disconnect) navigate(intent, t.uri) else if (!intent.owner.closed and detail.len != 0) intent.owner.setStatus(detail);
            }
        }
        for (self.requests.items, 0..) |item, i| if (item == r) {
            _ = self.requests.orderedRemove(i);
            break;
        };
        if (r.timer != 0) _ = glib.Source.remove(r.timer);
        r.operation.unref();
        r.cancel.unref();
        r.file.unref();
        a.free(r.key);
        // A click that joined a silent startup request is allowed to prompt now.
        if (r.background and r.interaction != .disconnected and !r.cancelled) for (r.targets.items) |t| if (t.intent) |intent| {
            if (!intent.owner.closed) if (intent.owner.findTab(intent.tab)) |tab| if (tab.generation == intent.generation and intent.owner.current() == tab) self.connect(t.id, intent.owner);
        };
        for (r.targets.items) |t| {
            a.free(t.id);
            a.free(t.uri);
        }
        r.targets.deinit(a);
        a.destroy(r);
        self.reconcile();
        self.pump();
        self.notify();
        self.app.as(gio.Application).release();
    }
    pub fn cancel(self: *Manager, id: []const u8) void {
        for (self.requests.items) |r| {
            var i = r.targets.items.len;
            while (i > 0) {
                i -= 1;
                if (c.eq(r.targets.items[i].id, id)) {
                    const t = r.targets.orderedRemove(i);
                    a.free(t.id);
                    a.free(t.uri);
                }
            }
            if (r.targets.items.len == 0) {
                r.cancelled = true;
                r.cancel.cancel();
            }
        }
        if (self.entry(id)) |e| {
            e.state = .disconnected;
            e.suppressed = true;
            e.detail = "";
        }
        self.notify();
    }
    pub fn disconnect(self: *Manager, id: []const u8, owner: *Window) void {
        const e = self.entry(id) orelse return;
        const mount = self.mounted(e.uri) orelse {
            self.cancel(id);
            return;
        };
        defer mount.unref();
        if (mount.canUnmount() == 0) {
            owner.setStatus("This connection does not support disconnecting.");
            return;
        }
        self.cancel(id);
        const r = a.create(Request) catch unreachable;
        r.* = .{ .manager = self, .key = c.mountKey(e.uri), .file = gio.File.newForUri(e.uri), .cancel = gio.Cancellable.new(), .operation = gtk.MountOperation.new(owner.window).as(gio.MountOperation), .parent = owner, .background = false, .disconnect = true };
        r.targets.append(a, .{ .id = c.dup(id), .uri = c.dup(e.uri), .intent = null }) catch unreachable;
        self.requests.append(a, r) catch unreachable;
        e.state = .connecting;
        e.suppressed = true;
        self.app.as(gio.Application).hold();
        r.timer = glib.timeoutAdd(1000, tick, r);
        mount.unmountWithOperation(.{}, r.operation, r.cancel, unmountedReady, r);
        self.notify();
    }
    fn unmountedReady(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const mount: *gio.Mount = @ptrCast(source.?);
        var err: ?*glib.Error = null;
        _ = mount.unmountWithOperationFinish(result, &err);
        defer if (err) |e| e.free();
        finish(@ptrCast(@alignCast(data.?)), err);
    }
    pub fn closeWindow(self: *Manager, owner: *Window, last: bool) void {
        if (last) self.closing = true;
        for (self.requests.items) |r| {
            for (r.targets.items) |*t| if (t.intent != null and t.intent.?.owner == owner) {
                t.intent = null;
            };
            if (last or r.parent == owner) {
                r.cancelled = true;
                r.cancel.cancel();
                for (r.targets.items) |t| if (self.entry(t.id)) |e| {
                    e.state = .disconnected;
                };
            }
        }
    }
};
pub fn label(state: State) [:0]const u8 {
    return switch (state) {
        .disconnected => "Disconnected",
        .queued => "Waiting to connect…",
        .connecting => "Connecting…",
        .connected => "Connected",
        .needs_auth => "Sign-in required",
        .review => "Review required",
        .failed => "Could not connect",
        .unsupported => "Protocol unavailable",
    };
}
extern "c" fn g_volume_monitor_get_mounts(*gio.VolumeMonitor) ?*glib.List;
