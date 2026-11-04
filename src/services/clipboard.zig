//! ext-data-control on GTK's context; text persistence runs on one owned worker.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const ext = @import("wayland").client.ext;
const wl = @import("wayland").client.wl;
const pixbuf = @import("gdkpixbuf2");
pub const policy = @import("clipboard_policy.zig");
const coordination = @import("clipboard/session.zig");
const storage = @import("clipboard/store.zig");
const history_clock = @import("clipboard/clock.zig");
const presentation = coordination.presentation;
const CompletionWatch = @import("clipboard/completion_watch.zig").Watch;
const i18n = @import("i18n");
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;
pub const Entry = struct { id: u64, kind: policy.Kind, bytes: []u8 };
const Offer = struct { proxy: *ext.DataControlOfferV1, owner: *Clipboard, mime: ?[:0]const u8 = null, mime_text: [32:0]u8 = @splat(0), kind: policy.Kind = .text, sensitive: bool = false };
const Transfer = struct {
    owner: *Clipboard,
    fd: c_int,
    bytes: std.ArrayList(u8) = .empty,
    kind: policy.Kind,
    write: bool = false,
    offset: usize = 0,
    watch: c_uint = 0,
    timeout: c_uint = 0,
    fn finish(self: *Transfer, accept: bool) void {
        const owner = self.owner;
        if (self.watch != 0) _ = glib.Source.remove(self.watch);
        if (self.timeout != 0) _ = glib.Source.remove(self.timeout);
        _ = std.c.close(self.fd);
        if (owner.read == self) owner.read = null;
        for (&owner.writes) |*slot| if (slot.* == self) {
            slot.* = null;
        };
        if (accept and !owner.locked) owner.add(self.kind, self.bytes.items) catch {
            owner.message = "Clipboard payload rejected";
        };
        std.crypto.secureZero(u8, self.bytes.items);
        self.bytes.deinit(a);
        a.destroy(self);
        owner.changed(owner.context);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Transfer = @ptrCast(@alignCast(data.?));
        self.timeout = 0;
        self.owner.message = if (self.write) "Paste transfer timed out" else "Clipboard transfer timed out";
        self.finish(false);
        return 0;
    }
    fn io(_: *glib.IOChannel, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Transfer = @ptrCast(@alignCast(data.?));
        if (self.write) {
            const n = std.c.write(self.fd, self.bytes.items[self.offset..].ptr, @min(65536, self.bytes.items.len - self.offset));
            if (n < 0 and std.c._errno().* == @backingInt(std.posix.E.AGAIN)) return 1;
            if (n > 0) self.offset += @intCast(n);
            if (n <= 0 or self.offset == self.bytes.items.len) {
                self.watch = 0;
                self.finish(false);
                return 0;
            }
        } else {
            var buffer: [65536]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            const n = std.c.read(self.fd, &buffer, buffer.len);
            if (n < 0 and std.c._errno().* == @backingInt(std.posix.E.AGAIN)) return 1;
            if (n <= 0) {
                self.watch = 0;
                self.finish(n == 0);
                return 0;
            }
            const size: usize = @intCast(n);
            const limit: usize = if (self.kind == .text) policy.text_limit else policy.image_limit;
            if (self.bytes.items.len + size > limit) {
                self.owner.message = "Clipboard payload too large";
                self.watch = 0;
                self.finish(false);
                return 0;
            }
            self.bytes.appendSlice(a, buffer[0..size]) catch {
                self.watch = 0;
                self.finish(false);
                return 0;
            };
        }
        return 1;
    }
    fn start(self: *Transfer) void {
        const channel = glib.IOChannel.unixNew(self.fd);
        defer channel.unref();
        self.watch = glib.ioAddWatch(channel, .{ .in = !self.write, .out = self.write, .hup = true, .err = true }, io, self);
        self.timeout = glib.timeoutAdd(5000, expired, self);
    }
};
pub const Clipboard = struct {
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    registry: ?*wl.Registry = null,
    manager: ?*ext.DataControlManagerV1 = null,
    manager_id: u32 = 0,
    seat: ?*wl.Seat = null,
    seat_id: u32 = 0,
    device: ?*ext.DataControlDeviceV1 = null,
    source: ?*ext.DataControlSourceV1 = null,
    owned: ?Entry = null,
    offers: std.ArrayList(*Offer) = .empty,
    session: ?coordination.Session = null,
    io_state: ?std.Io.Threaded = null,
    completion_watch: CompletionWatch = .{},
    drain_context: ?*anyopaque = null,
    on_drained: ?*const fn (*anyopaque) void = null,
    stopping: bool = false,
    last_health: coordination.Health = .loading,
    history_accessing: bool = false,
    // Deterministic samples exist only in unit-test builds.
    test_time: if (@import("builtin").is_test) ?history_clock.Sample else void = if (@import("builtin").is_test) null else {},
    read: ?*Transfer = null,
    writes: [4]?*Transfer = @splat(null),
    skip_selection: bool = true,
    locked: bool = true,
    ambiguous: bool = false,
    message: [:0]const u8 = "Clipboard history paused",
    pub fn start(self: *Clipboard) !void {
        self.io_state = .init(a, .{});
        const xdg = if (glib.getenv("XDG_STATE_HOME")) |value| std.mem.span(value) else null;
        const home = if (glib.getenv("HOME")) |value| std.mem.span(value) else null;
        if (storage.resolveDirectory(a, xdg, home)) |path| {
            defer a.free(path);
            self.session = coordination.Session.init(a, self.io_state.?.io(), path, .{}) catch null;
        } else |_| self.message = "Clipboard storage unavailable";
        var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
        std.posix.sigaction(.PIPE, &action, null);
        const display = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.Unavailable;
        const connection: *wl.Display = @ptrCast(display.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Clipboard, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Clipboard) void {
        self.beginStop();
        std.debug.assert(self.drained());
        // Detach the only callback borrowing self before releasing the worker's
        // descriptor or any main-context state. Pending wakeups own no pointers.
        self.completion_watch.detach();
        self.dropDevice();
        if (self.seat) |s| s.release();
        if (self.manager) |m| m.destroy();
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        if (self.session) |*session| session.deinit();
        self.session = null;
        if (self.io_state) |*io| io.deinit();
        self.io_state = null;
        self.offers.deinit(a);
    }
    pub fn beginStop(self: *Clipboard) void {
        self.stopping = true;
        self.setLocked(true);
        self.revoke();
        self.dropDevice();
        if (self.session) |*session| session.beginShutdown();
    }
    pub fn drained(self: *const Clipboard) bool {
        return if (self.session) |*session| session.stopped() else true;
    }
    pub fn setLocked(self: *Clipboard, locked: bool) void {
        const closed = locked or self.stopping;
        if (self.locked == closed) return;
        self.locked = closed;
        if (self.session) |*session| session.setLocked(closed);
        if (closed) {
            self.revoke();
            self.dropDevice();
        } else {
            self.refresh();
        }
        self.message = self.baseline();
        self.changed(self.context);
    }
    fn baseline(self: *const Clipboard) [:0]const u8 {
        if (self.locked) return i18n.dtr("pearl", "Clipboard history is hidden while paused");
        const session = if (self.session) |*value| value else return i18n.dtr("pearl", "Clipboard storage unavailable");
        return switch (session.feedback()) {
            .paused => i18n.dtr("pearl", "Clipboard history is hidden while paused"),
            .loading => i18n.dtr("pearl", "Loading clipboard history"),
            .save_pending => i18n.dtr("pearl", "Clipboard text captured; saving is pending"),
            .busy => i18n.dtr("pearl", "Clipboard storage is busy. Try again."),
            .failed => i18n.dtr("pearl", "Clipboard persistence failed; saving was not confirmed"),
            .uncertain => i18n.dtr("pearl", "Clipboard save durability is uncertain"),
            .unavailable => i18n.dtr("pearl", "Clipboard storage unavailable"),
            .clock_untrusted => i18n.dtr("pearl", "Clipboard history is hidden because the clock is untrusted"),
            .save_durable => i18n.dtr("pearl", "Clipboard text saved"),
            .enabled => i18n.dtr("pearl", "Text history can be restored; PNG images stay in memory"),
            .removal_pending => i18n.dtr("pearl", "History removal is pending; disk completion is not confirmed"),
            .removal_durable => i18n.dtr("pearl", "History removal saved"),
            .removal_failed => i18n.dtr("pearl", "History removal failed; disk completion was not confirmed"),
            .removal_uncertain => i18n.dtr("pearl", "History removal durability is uncertain"),
        };
    }
    pub fn accessible(self: *const Clipboard) bool {
        return self.available() and !self.session.?.maintenance_busy;
    }
    fn available(self: *const Clipboard) bool {
        return !self.locked and !self.stopping and !self.ambiguous and self.device != null and (if (self.session) |*session| session.available() else false);
    }
    pub fn entries(self: *Clipboard) []const coordination.history.Entry {
        self.maintainHistory();
        return if (self.accessible()) self.session.?.model.entries() else &.{};
    }
    fn maintainHistory(self: *Clipboard) void {
        if (self.locked or self.stopping or self.history_accessing) return;
        if (self.session) |*session| {
            self.history_accessing = true;
            defer self.history_accessing = false;
            const before = self.historyState();
            defer self.historyChanged(before);
            _ = session.accessHistory(self.time() catch return) catch {};
        }
    }
    const HistoryState = struct { revision: u64, accessible: bool, health: coordination.Health };
    fn historyState(self: *const Clipboard) HistoryState {
        const session = &self.session.?;
        return .{ .revision = session.model.generation, .accessible = self.accessible(), .health = session.health() };
    }
    fn historyChanged(self: *Clipboard, before: HistoryState) void {
        const after = self.historyState();
        if (std.meta.eql(before, after)) return;
        self.last_health = after.health;
        self.message = self.baseline();
        // Consumers may synchronously invalidate previews and read entries.
        // Such a read observes this result without attempting maintenance again.
        const accessing = self.history_accessing;
        self.history_accessing = true;
        defer self.history_accessing = accessing;
        self.changed(self.context);
    }
    fn time(self: *Clipboard) !history_clock.Sample {
        if (@import("builtin").is_test) if (self.test_time) |sample| return sample;
        return history_clock.read() catch {
            if (self.session) |*session| session.failClock();
            self.revoke();
            self.dropDevice();
            self.message = self.baseline();
            if (!self.history_accessing) self.changed(self.context);
            return error.ClockUntrusted;
        };
    }
    fn refresh(self: *Clipboard) void {
        if (self.stopping) return;
        if (self.session) |*session| {
            const sample = if (!session.ready and !self.locked and session.worker != null) self.time() catch return else null;
            const changed = session.updateWorker(sample) catch true;
            if (self.completion_watch.source == 0) if (session.worker) |w| {
                self.completion_watch.attach(w.completion.fd, workerCompleted, self);
            };
            const health = session.health();
            if (!session.available()) {
                self.revoke();
                self.dropDevice();
            } else self.connect();
            if (changed or health != self.last_health) {
                self.last_health = health;
                self.message = self.baseline();
                self.changed(self.context);
            }
        }
    }
    fn workerCompleted(_: *glib.IOChannel, _: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        self.session.?.worker.?.completion.drain();
        if (self.stopping) {
            if (self.drained()) if (self.on_drained) |done| {
                const context = self.drain_context.?;
                self.on_drained = null;
                // done may destroy self, including its source and worker.
                self.completion_watch.detach();
                done(context);
                return 0;
            };
            return 1;
        }
        self.refresh();
        return 1;
    }
    /// Copy feedback is transient, but the message is long-lived service state read by
    /// every consumer. Clear it as the panel opens so it never shows a past action.
    pub fn resetMessage(self: *Clipboard) void {
        self.message = self.baseline();
    }
    fn revoke(self: *Clipboard) void {
        if (self.read) |r| r.finish(false);
        for (self.writes) |w| if (w) |t| t.finish(false);
        if (self.source) |s| {
            if (self.device) |d| d.setSelection(null);
            s.destroy();
        }
        self.source = null;
        if (self.owned) |e| wipe(e.bytes);
        self.owned = null;
    }
    fn wipe(bytes: []u8) void {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    pub fn clear(self: *Clipboard) !void {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        const session = if (self.session) |*value| value else return error.Unavailable;
        if (!self.available() and !session.canRecoverClear()) return error.Unavailable;
        session.clear() catch |err| {
            self.message = self.baseline();
            self.changed(self.context);
            return err;
        };
        self.revoke();
        self.message = self.baseline();
        self.changed(self.context);
    }
    pub fn delete(self: *Clipboard, id: u64) !void {
        if (self.locked) return error.Locked;
        if (!self.available()) return error.Unavailable;
        self.session.?.delete(id, try self.time()) catch |err| {
            self.message = self.baseline();
            self.changed(self.context);
            return err;
        };
        self.message = self.baseline();
        self.changed(self.context);
    }
    pub fn add(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        _ = try self.retainEntry(kind, input);
    }
    /// Publish a copied value independently of the producing popup's lifetime.
    pub fn copyText(self: *Clipboard, input: []const u8) !void {
        try self.copyValue(.text, input);
    }
    pub fn copyPng(self: *Clipboard, input: []const u8) !void {
        try self.copyValue(.png, input);
    }
    fn retainEntry(self: *Clipboard, kind: policy.Kind, input: []const u8) !u64 {
        if (self.locked) return error.Locked;
        if (!self.available()) return error.Unavailable;
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        const clean = if (kind == .png) try sanitize(input) else null;
        defer if (clean) |bytes| wipe(bytes);
        const accessing = self.history_accessing;
        self.history_accessing = true;
        defer self.history_accessing = accessing;
        const before = self.historyState();
        errdefer self.historyChanged(before);
        const id = try self.session.?.accept(kind, clean orelse input, try self.time());
        self.message = self.baseline();
        self.changed(self.context);
        return id;
    }
    pub fn select(self: *Clipboard, id: u64) !void {
        if (self.locked) return error.Locked;
        if (!self.available()) return error.Unavailable;
        const accessing = self.history_accessing;
        self.history_accessing = true;
        defer self.history_accessing = accessing;
        const before = self.historyState();
        errdefer self.historyChanged(before);
        var tx = try self.session.?.prepareSelection(id, try self.time());
        defer tx.discard();
        try self.publish(&tx);
    }
    fn copyValue(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        if (self.locked) return error.Locked;
        if (!self.available()) return error.Unavailable;
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        const clean = if (kind == .png) try sanitize(input) else null;
        defer if (clean) |bytes| wipe(bytes);
        const accessing = self.history_accessing;
        self.history_accessing = true;
        defer self.history_accessing = accessing;
        const before = self.historyState();
        errdefer self.historyChanged(before);
        var tx = try self.session.?.prepareCopy(kind, clean orelse input, try self.time());
        defer tx.discard();
        try self.publish(&tx);
    }
    fn publish(self: *Clipboard, tx: *coordination.Transaction) !void {
        const device = self.device orelse return error.Unavailable;
        const entry = tx.entry();
        const bytes = try a.dupe(u8, entry.bytes);
        errdefer wipe(bytes);
        const source = try self.manager.?.createDataSource();
        errdefer source.destroy();
        source.setListener(*Clipboard, sourceEvent, self);
        source.offer(mime(entry.kind));
        // All fallible allocations and worker admission precede publication;
        // there is no yield or further fallible work between commit and queueing.
        try self.session.?.commit(tx);
        device.setSelection(source);
        if (self.source) |old| old.destroy();
        if (self.owned) |old| wipe(old.bytes);
        self.source = source;
        self.owned = .{ .id = entry.id, .bytes = bytes, .kind = entry.kind };
        self.display.flush();
        self.message = "Copied — paste in the destination application";
        self.changed(self.context);
    }
    fn mime(kind: policy.Kind) [:0]const u8 {
        return if (kind == .text) "text/plain;charset=utf-8" else "image/png";
    }
    fn connect(self: *Clipboard) void {
        if (self.locked or self.stopping or self.ambiguous or self.device != null or self.manager == null or self.seat == null or !(if (self.session) |*session| session.available() else false)) return;
        self.skip_selection = true;
        self.device = self.manager.?.getDataDevice(self.seat.?) catch return;
        self.device.?.setListener(*Clipboard, deviceEvent, self);
        self.display.flush();
    }
    fn dropDevice(self: *Clipboard) void {
        if (self.read) |r| r.finish(false);
        if (self.device) |d| d.destroy();
        self.device = null;
        for (self.offers.items) |o| {
            o.proxy.destroy();
            a.destroy(o);
        }
        self.offers.clearRetainingCapacity();
    }
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Clipboard) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "ext_data_control_manager_v1") and self.manager == null) {
                    self.manager = self.registry.?.bind(g.name, ext.DataControlManagerV1, 1) catch return;
                    self.manager_id = g.name;
                }
                if (std.mem.eql(u8, name, "wl_seat") and g.version >= 5) {
                    if (self.seat != null) {
                        self.ambiguous = true;
                        self.revoke();
                        self.dropDevice();
                    } else {
                        self.seat = self.registry.?.bind(g.name, wl.Seat, 5) catch return;
                        self.seat_id = g.name;
                        self.seat.?.setListener(*Clipboard, seatEvent, self);
                    }
                }
                self.connect();
            },
            .global_remove => |g| if (g.name == self.manager_id or g.name == self.seat_id) {
                self.revoke();
                self.dropDevice();
                if (g.name == self.manager_id) {
                    self.manager.?.destroy();
                    self.manager = null;
                }
                if (g.name == self.seat_id) {
                    self.seat.?.release();
                    self.seat = null;
                }
            },
        }
        self.changed(self.context);
    }
    fn seatEvent(_: *wl.Seat, _: wl.Seat.Event, _: *Clipboard) void {}
    fn offerEvent(_: *ext.DataControlOfferV1, event: ext.DataControlOfferV1.Event, offer: *Offer) void {
        const value = std.mem.span(event.offer.mime_type);
        if (policy.sensitiveMime(value)) offer.sensitive = true;
        if (std.mem.eql(u8, value, "image/png")) {
            offer.kind = .png;
            offer.mime = "image/png";
        }
        if (offer.kind == .text) {
            if (std.ascii.eqlIgnoreCase(value, "text/plain;charset=utf-8")) {
                @memcpy(offer.mime_text[0..value.len], value);
                offer.mime_text[value.len] = 0;
                offer.mime = offer.mime_text[0..value.len :0];
            }
            if (offer.mime == null and std.mem.eql(u8, value, "text/plain")) offer.mime = "text/plain";
        }
    }
    fn deviceEvent(_: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, self: *Clipboard) void {
        switch (event) {
            .data_offer => |ev| {
                if (self.offers.items.len >= 8) {
                    ev.id.destroy();
                    return;
                }
                const o = a.create(Offer) catch {
                    ev.id.destroy();
                    return;
                };
                o.* = .{ .proxy = ev.id, .owner = self };
                self.offers.append(a, o) catch {
                    ev.id.destroy();
                    a.destroy(o);
                    return;
                };
                ev.id.setListener(*Offer, offerEvent, o);
            },
            .selection, .primary_selection => {
                const skip = self.skip_selection;
                if (event == .selection) self.skip_selection = false;
                const id = if (event == .selection) event.selection.id else event.primary_selection.id;
                if (event == .selection) {
                    if (self.read) |r| r.finish(false);
                }
                for (self.offers.items, 0..) |o, i| if (o.proxy == id) {
                    if (event == .selection and !skip and self.available() and !o.sensitive and o.mime != null) self.receive(o) catch |err| log.debug("event=clipboard-failed error={s}", .{@errorName(err)});
                    o.proxy.destroy();
                    a.destroy(o);
                    _ = self.offers.orderedRemove(i);
                    break;
                };
            },
            .finished => {
                self.revoke();
                self.dropDevice();
                self.message = "Clipboard device unavailable";
                self.changed(self.context);
            },
        }
    }
    fn receive(self: *Clipboard, offer: *Offer) !void {
        var fds: [2]c_int = undefined;
        if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.Pipe;
        defer _ = std.c.close(fds[1]);
        errdefer _ = std.c.close(fds[0]);
        _ = std.c.fcntl(fds[0], std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        const t = try a.create(Transfer);
        t.* = .{ .owner = self, .fd = fds[0], .kind = offer.kind };
        self.read = t;
        offer.proxy.receive(offer.mime.?, fds[1]);
        self.display.flush();
        t.start();
    }
    fn sourceEvent(source: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, self: *Clipboard) void {
        switch (event) {
            .cancelled => {
                if (source == self.source) {
                    source.destroy();
                    self.source = null;
                    if (self.owned) |e| wipe(e.bytes);
                    self.owned = null;
                }
            },
            .send => |ev| {
                var retained = false;
                defer if (!retained) {
                    _ = std.c.close(ev.fd);
                };
                const e = self.owned orelse return;
                if (!self.available() or source != self.source or !std.mem.eql(u8, std.mem.span(ev.mime_type), mime(e.kind))) return;
                for (&self.writes) |*slot| if (slot.* == null) {
                    const t = a.create(Transfer) catch return;
                    t.* = .{ .owner = self, .fd = ev.fd, .kind = e.kind, .write = true };
                    t.bytes.appendSlice(a, e.bytes) catch {
                        a.destroy(t);
                        return;
                    };
                    _ = std.c.fcntl(ev.fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
                    slot.* = t;
                    retained = true;
                    t.start();
                    return;
                };
            },
        }
    }
    pub fn status(self: *Clipboard, alloc: std.mem.Allocator) ![]const u8 {
        return self.pageStatus(alloc, .{});
    }
    pub fn pageStatus(self: *Clipboard, alloc: std.mem.Allocator, page: presentation.Page) ![]const u8 {
        // Receipt responses can also include a history page while accessible.
        self.maintainHistory();
        if (page.operation != null and (self.locked or self.stopping or self.ambiguous)) return error.Locked;
        if (self.session) |*session| return session.pageStatus(alloc, self.accessible(), self.read != null, self.baseline(), page);
        return presentation.status(alloc, .{ .accessible = false, .health = .unavailable, .instance = "", .message = self.baseline() }, page);
    }
    pub fn checkInstance(self: *Clipboard, instance: ?[]const u8) !void {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        const session = if (self.session) |*value| value else return error.Unavailable;
        try session.checkInstance(instance);
    }
    pub fn removalStatus(self: *Clipboard, alloc: std.mem.Allocator) ![]const u8 {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        const session = if (self.session) |*value| value else return error.Unavailable;
        return session.removalStatus(alloc);
    }
};
pub fn encode(image: *pixbuf.Pixbuf) ![]u8 {
    var bytes: [*]u8 = undefined;
    var size: usize = 0;
    if (image.saveToBufferv(&bytes, &size, "png", null, null, null) == 0) return error.InvalidPayload;
    defer glib.free(bytes);
    return a.dupe(u8, bytes[0..size]);
}
fn sanitize(bytes: []const u8) ![]u8 {
    const filtered = try policy.pngPayload(a, bytes);
    defer {
        std.crypto.secureZero(u8, filtered);
        a.free(filtered);
    }
    const loader = pixbuf.PixbufLoader.newWithType("png", null) orelse return error.InvalidPayload;
    defer loader.unref();
    const written = loader.write(filtered.ptr, filtered.len, null);
    const closed = loader.close(null);
    if (written == 0 or closed == 0) return error.InvalidPayload;
    const image = loader.getPixbuf() orelse return error.InvalidPayload;
    const clean = pixbuf.Pixbuf.newFromData(image.getPixels(), .rgb, image.getHasAlpha(), 8, image.getWidth(), image.getHeight(), image.getRowstride(), null, null);
    defer clean.unref();
    return encode(clean);
}
