//! Session-bus transfer progress for batch operations. One notification per
//! batch, updated through replaces_id; the x-pearl-progress hint draws a bar in
//! Pearl and degrades to text elsewhere. All D-Bus work stays on the main
//! thread; the worker only touches the engine's atomics. Without a notification
//! owner every entry point is inert and the operation itself is unaffected.
const std = @import("std");
const u = @import("../ui.zig");
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const a = u.a;
const log = std.log.scoped(.platform);
const name = "org.freedesktop.Notifications";
const path = "/org/freedesktop/Notifications";
const app_id = "org.aqueous.Phyto";
/// Progress updates coalesce to at most one every 500 ms; phase transitions
/// (start, conflict pause, final result) always send immediately.
const throttle_us: i64 = 500_000;

const Snapshot = struct {
    summary: [:0]u8,
    body: [:0]u8,
    progress: ?f64,
    final: bool,
    fn deinit(self: *Snapshot) void {
        a.free(self.summary);
        a.free(self.body);
    }
    fn copy(summary: []const u8, body: []const u8, progress: ?f64, final: bool) Snapshot {
        return .{
            .summary = a.dupeSentinel(u8, summary, 0) catch unreachable,
            .body = a.dupeSentinel(u8, body, 0) catch unreachable,
            .progress = progress,
            .final = final,
        };
    }
    fn eql(x: Snapshot, y: Snapshot) bool {
        return x.final == y.final and x.progress == y.progress and
            std.mem.eql(u8, x.summary, y.summary) and std.mem.eql(u8, x.body, y.body);
    }
};

const Call = struct {
    self: *Reporter,
    epoch: u64,
    batch: u64,
    replaces: u32,
    final: bool,
};

pub const Reporter = struct {
    context: *anyopaque,
    action: *const fn (*anyopaque, u32, []const u8) void,
    started: bool = false,
    conn: ?*gio.DBusConnection = null,
    watch: c_uint = 0,
    subs: [2]c_uint = .{ 0, 0 },
    available: bool = false,
    supports_progress: bool = false,
    caps_pending: bool = false,
    /// Notification id of the running batch; 0 until the first Notify replies.
    id: u32 = 0,
    inflight: bool = false,
    active: bool = false,
    /// The user dismissed the progress card: stop updating, keep transferring.
    detached: bool = false,
    epoch: u64 = 0,
    batch: u64 = 0,
    latest: ?Snapshot = null,
    sent: ?Snapshot = null,
    last_send: i64 = 0,

    pub fn init(context: *anyopaque, action: *const fn (*anyopaque, u32, []const u8) void) Reporter {
        return .{ .context = context, .action = action };
    }
    pub fn deinit(self: *Reporter) void {
        if (self.watch != 0) gio.busUnwatchName(self.watch);
        self.watch = 0;
        self.dropConnection();
        if (self.latest) |*s| s.deinit();
        if (self.sent) |*s| s.deinit();
        self.latest = null;
        self.sent = null;
    }
    fn dropConnection(self: *Reporter) void {
        if (self.conn) |c| {
            for (self.subs) |s| if (s != 0) c.signalUnsubscribe(s);
            c.unref();
        }
        self.conn = null;
        self.subs = .{ 0, 0 };
    }
    fn ensure(self: *Reporter) void {
        if (self.started) return;
        self.started = true;
        self.watch = gio.busWatchName(.session, name, .{}, appeared, vanished, self, null);
    }
    fn appeared(conn: *gio.DBusConnection, _: [*:0]const u8, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        if (self.conn) |old| {
            if (old != conn) self.dropConnection();
        }
        if (self.conn == null) {
            conn.ref();
            self.conn = conn;
            self.subs[0] = conn.signalSubscribe(name, name, "ActionInvoked", path, null, .{}, signal, self, null);
            self.subs[1] = conn.signalSubscribe(name, name, "NotificationClosed", path, null, .{}, signal, self, null);
        }
        // A restarted daemon invalidates in-flight replies and the old id.
        self.epoch += 1;
        self.available = true;
        self.id = 0;
        self.inflight = false;
        self.probeCaps();
        if (self.active and !self.detached) self.trySend(true, false);
    }
    fn vanished(_: *gio.DBusConnection, _: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        self.available = false;
        self.epoch += 1;
        self.id = 0;
        self.inflight = false;
        // Keep the connection until a new owner appears; a straggler reply can
        // still finish against it, and the epoch guard discards the result.
    }
    fn probeCaps(self: *Reporter) void {
        if (self.caps_pending) return;
        const c = self.conn orelse return;
        self.caps_pending = true;
        const t = glib.VariantType.new("(as)");
        defer t.free();
        c.call(name, path, name, "GetCapabilities", null, t, .{ .no_auto_start = true }, 2000, null, capsDone, self);
    }
    fn capsDone(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        self.caps_pending = false;
        // Finish against the connection that made the call: a straggler reply
        // must not touch a replacement connection after a daemon restart.
        const c: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const value = c.callFinish(result, &err) orelse {
            if (err) |e| e.free();
            self.trySend(false, false);
            return;
        };
        defer value.unref();
        const arr = value.getChildValue(0);
        defer arr.unref();
        const before = self.supports_progress;
        for (0..arr.nChildren()) |i| {
            const child = arr.getChildValue(i);
            defer child.unref();
            if (std.mem.eql(u8, std.mem.span(child.getString(null)), "x-pearl-progress")) self.supports_progress = true;
        }
        // A start Notify may have gone out before the probe answered; let the
        // next send carry the hint even when the snapshot itself is unchanged.
        if (!before and self.supports_progress) {
            if (self.sent) |*s| s.deinit();
            self.sent = null;
        }
        self.trySend(false, false);
    }
    fn setLatest(self: *Reporter, summary: []const u8, body: []const u8, progress: ?f64, final: bool) void {
        if (self.latest) |*s| s.deinit();
        self.latest = Snapshot.copy(summary, body, progress, final);
    }
    pub fn begin(self: *Reporter, summary: []const u8, body: []const u8, progress: ?f64) void {
        self.ensure();
        self.batch += 1;
        self.active = true;
        self.detached = false;
        self.id = 0;
        self.last_send = 0;
        if (self.sent) |*s| s.deinit();
        self.sent = null;
        self.setLatest(summary, body, progress, false);
        self.trySend(true, false);
    }
    pub fn update(self: *Reporter, summary: []const u8, body: []const u8, progress: ?f64, force: bool) void {
        if (!self.active or self.detached) return;
        self.setLatest(summary, body, progress, false);
        self.trySend(force, true);
    }
    pub fn complete(self: *Reporter, summary: []const u8, body: []const u8) void {
        if (!self.active) return;
        // A dismissed card stays dismissed: no final notification either.
        if (self.detached or !self.available or self.conn == null) {
            self.reset();
            return;
        }
        self.setLatest(summary, body, null, true);
        self.trySend(true, false);
    }
    fn reset(self: *Reporter) void {
        self.active = false;
        self.id = 0;
        if (self.latest) |*s| s.deinit();
        if (self.sent) |*s| s.deinit();
        self.latest = null;
        self.sent = null;
    }
    fn trySend(self: *Reporter, force: bool, throttled: bool) void {
        if (!self.available or self.conn == null or self.inflight or self.detached) return;
        // Defer the first send until the capability probe answers so the hint is
        // present from the very first card; capsDone flushes the pending snapshot.
        if (self.caps_pending) return;
        const snap = self.latest orelse return;
        const now = glib.getMonotonicTime();
        if (!force) {
            if (self.sent) |s| if (Snapshot.eql(s, snap)) return;
            // Periodic ticks are throttled; a post-reply flush is not, or a fast
            // batch's final replacement would be suppressed with no tick to retry.
            if (throttled and self.last_send != 0 and now - self.last_send < throttle_us) return;
        }
        if (self.sent) |*s| s.deinit();
        self.sent = Snapshot.copy(snap.summary, snap.body, snap.progress, snap.final);
        const call = a.create(Call) catch unreachable;
        call.* = .{ .self = self, .epoch = self.epoch, .batch = self.batch, .replaces = self.id, .final = snap.final };
        const params = buildParams(snap, self.id, self.supports_progress);
        _ = params.refSink();
        defer params.unref();
        const t = glib.VariantType.new("(u)");
        defer t.free();
        self.inflight = true;
        self.conn.?.call(name, path, name, "Notify", params, t, .{ .no_auto_start = true }, 3000, null, notifyDone, call);
    }
    fn notifyDone(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const call: *Call = @ptrCast(@alignCast(data.?));
        defer a.destroy(call);
        const self = call.self;
        const c: *gio.DBusConnection = @ptrCast(@alignCast(source.?));
        var err: ?*glib.Error = null;
        const value = c.callFinish(result, &err);
        defer if (value) |v| v.unref();
        defer if (err) |e| e.free();
        // Only the current epoch's reply owns the in-flight slot: a restart may
        // already have sent a replacement call on the new owner.
        if (call.epoch == self.epoch) self.inflight = false;
        if (call.epoch != self.epoch or call.batch != self.batch) {
            self.trySend(false, false);
            return;
        }
        if (value) |v| {
            const idv = v.getChildValue(0);
            defer idv.unref();
            if (call.replaces == 0) self.id = idv.getUint32();
            self.last_send = glib.getMonotonicTime();
            if (call.final) {
                self.reset();
                return;
            }
        } else {
            // Rejected or lost: re-announce from scratch on the next change.
            self.id = 0;
            if (call.final) {
                self.reset();
                return;
            }
        }
        self.trySend(false, false);
    }
    fn signal(_: *gio.DBusConnection, _: ?[*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, member: [*:0]const u8, params: *glib.Variant, data: ?*anyopaque) callconv(.c) void {
        const self: *Reporter = @ptrCast(@alignCast(data.?));
        const m = std.mem.span(member);
        if (std.mem.eql(u8, m, "ActionInvoked")) {
            if (!std.mem.eql(u8, std.mem.span(params.getTypeString()), "(us)")) return;
            const idv = params.getChildValue(0);
            defer idv.unref();
            const id = idv.getUint32();
            if (id == 0 or id != self.id) return;
            const kv = params.getChildValue(1);
            defer kv.unref();
            self.action(self.context, id, std.mem.span(kv.getString(null)));
        } else if (std.mem.eql(u8, m, "NotificationClosed")) {
            if (!std.mem.eql(u8, std.mem.span(params.getTypeString()), "(uu)")) return;
            const idv = params.getChildValue(0);
            defer idv.unref();
            const id = idv.getUint32();
            if (id == 0 or id != self.id) return;
            // Dismissing the progress card detaches updates, not the transfer.
            self.detached = true;
            log.debug("event=transfer-notification-detached id={d}", .{id});
        }
    }
};

fn buildParams(snap: Snapshot, replaces: u32, supports_progress: bool) *glib.Variant {
    var hints: [3]*glib.Variant = undefined;
    var hn: usize = 0;
    hints[hn] = glib.Variant.newDictEntry(glib.Variant.newString("desktop-entry"), glib.Variant.newVariant(glib.Variant.newString(app_id)));
    hn += 1;
    if (!snap.final) {
        hints[hn] = glib.Variant.newDictEntry(glib.Variant.newString("resident"), glib.Variant.newVariant(glib.Variant.newBoolean(1)));
        hn += 1;
    }
    if (supports_progress) if (snap.progress) |value| {
        hints[hn] = glib.Variant.newDictEntry(glib.Variant.newString("x-pearl-progress"), glib.Variant.newVariant(glib.Variant.newDouble(value)));
        hn += 1;
    };
    const ht = glib.VariantType.new("{sv}");
    defer ht.free();
    const hints_arr = glib.Variant.newArray(ht, &hints, hn);
    const at = glib.VariantType.new("s");
    defer at.free();
    const actions_arr = if (snap.final)
        glib.Variant.newArray(at, &[_]*glib.Variant{ glib.Variant.newString("default"), glib.Variant.newString("") }, 2)
    else
        glib.Variant.newArray(at, &[_]*glib.Variant{
            glib.Variant.newString("cancel"),
            glib.Variant.newString(@import("i18n").dtr("phyto", "Cancel")),
            glib.Variant.newString("default"),
            glib.Variant.newString(""),
        }, 4);
    const args = [_]*glib.Variant{
        glib.Variant.newString("Phyto"),
        glib.Variant.newUint32(replaces),
        glib.Variant.newString(app_id),
        glib.Variant.newString(snap.summary.ptr),
        glib.Variant.newString(snap.body.ptr),
        actions_arr,
        hints_arr,
        glib.Variant.newInt32(if (snap.final) -1 else 0),
    };
    return glib.Variant.newTuple(&args, args.len);
}
