//! ext-data-control, dispatched by GTK. No primary history, disk storage or synthetic paste.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const ext = @import("wayland").client.ext;
const wl = @import("wayland").client.wl;
const pixbuf = @import("gdkpixbuf2");
pub const policy = @import("clipboard_policy.zig");
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
            if (n < 0 and std.c._errno().* == @intFromEnum(std.posix.E.AGAIN)) return 1;
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
            if (n < 0 and std.c._errno().* == @intFromEnum(std.posix.E.AGAIN)) return 1;
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
    entries: std.ArrayList(Entry) = .empty,
    read: ?*Transfer = null,
    writes: [4]?*Transfer = @splat(null),
    next_id: u64 = 1,
    skip_selection: bool = true,
    locked: bool = true,
    ambiguous: bool = false,
    message: [:0]const u8 = "Clipboard history paused",
    pub fn start(self: *Clipboard) !void {
        var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
        std.posix.sigaction(.PIPE, &action, null);
        const display = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.Unavailable;
        const connection: *wl.Display = @ptrCast(display.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Clipboard, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Clipboard) void {
        self.setLocked(true);
        self.clear();
        self.dropDevice();
        if (self.seat) |s| s.release();
        if (self.manager) |m| m.destroy();
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        self.entries.deinit(a);
        self.offers.deinit(a);
    }
    pub fn setLocked(self: *Clipboard, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        if (locked) {
            self.clear();
            self.dropDevice();
            self.message = "Clipboard history paused";
        } else {
            self.message = "History stays in memory; sensitive selections are excluded";
            self.connect();
        }
        self.changed(self.context);
    }
    pub fn clear(self: *Clipboard) void {
        if (self.read) |r| r.finish(false);
        for (self.writes) |w| if (w) |t| t.finish(false);
        if (self.source) |s| {
            if (self.device) |d| d.setSelection(null);
            s.destroy();
        }
        self.source = null;
        if (self.owned) |e| wipe(e.bytes);
        self.owned = null;
        for (self.entries.items) |e| wipe(e.bytes);
        self.entries.clearRetainingCapacity();
        self.message = "Clipboard history cleared";
        self.changed(self.context);
    }
    fn wipe(bytes: []u8) void {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    pub fn delete(self: *Clipboard, id: u64) !void {
        for (self.entries.items, 0..) |e, i| if (e.id == id) {
            wipe(e.bytes);
            _ = self.entries.orderedRemove(i);
            self.message = "Clipboard entry removed";
            self.changed(self.context);
            return;
        };
        return error.Stale;
    }
    pub fn add(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        if (self.locked) return error.Locked;
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        const bytes = if (kind == .png) try sanitize(input) else try a.dupe(u8, input);
        errdefer wipe(bytes);
        if (bytes.len > policy.image_limit) return error.InvalidPayload;
        for (self.entries.items) |e| if (e.kind == kind and std.mem.eql(u8, e.bytes, bytes)) {
            wipe(bytes);
            return;
        };
        var total: usize = bytes.len;
        for (self.entries.items) |e| total += e.bytes.len;
        while (self.entries.items.len > 0 and (total > policy.total_limit or self.entries.items.len >= policy.entries_limit)) {
            const old = self.entries.pop().?;
            total -= old.bytes.len;
            wipe(old.bytes);
        }
        try self.entries.insert(a, 0, .{ .id = self.next_id, .kind = kind, .bytes = bytes });
        self.next_id += 1;
        self.message = "Clipboard history updated";
        self.changed(self.context);
    }
    pub fn select(self: *Clipboard, id: u64) !void {
        if (self.locked) return error.Locked;
        const device = self.device orelse return error.Unavailable;
        for (self.entries.items) |e| if (e.id == id) {
            const bytes = try a.dupe(u8, e.bytes);
            errdefer wipe(bytes);
            const source = try self.manager.?.createDataSource();
            source.setListener(*Clipboard, sourceEvent, self);
            source.offer(mime(e.kind));
            if (self.source) |s| s.destroy();
            if (self.owned) |old| wipe(old.bytes);
            self.source = source;
            self.owned = .{ .id = e.id, .bytes = bytes, .kind = e.kind };
            device.setSelection(source);
            self.display.flush();
            self.message = "Copied — paste in the destination application";
            self.changed(self.context);
            return;
        };
        return error.Stale;
    }
    fn mime(kind: policy.Kind) [:0]const u8 {
        return if (kind == .text) "text/plain;charset=utf-8" else "image/png";
    }
    fn connect(self: *Clipboard) void {
        if (self.locked or self.ambiguous or self.device != null or self.manager == null or self.seat == null) return;
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
                        self.clear();
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
                self.clear();
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
        if (std.mem.eql(u8, value, "x-kde-passwordManagerHint") or std.mem.eql(u8, value, "application/x-keepassxc") or std.mem.eql(u8, value, "application/x-pearl-private")) offer.sensitive = true;
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
                    if (event == .selection and !skip and !self.locked and !o.sensitive and o.mime != null) self.receive(o) catch {};
                    o.proxy.destroy();
                    a.destroy(o);
                    _ = self.offers.orderedRemove(i);
                    break;
                };
            },
            .finished => {
                self.clear();
                self.dropDevice();
                self.message = "Clipboard device unavailable";
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
                if (self.locked or source != self.source or !std.mem.eql(u8, std.mem.span(ev.mime_type), mime(e.kind))) return;
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
        const Item = struct { id: u64, kind: policy.Kind, bytes: usize, preview: []const u8 };
        var items: std.ArrayList(Item) = .empty;
        if (!self.locked) for (self.entries.items) |e| {
            const text = if (e.kind == .text) try policy.preview(alloc, e.bytes) else "PNG image";
            try items.append(alloc, .{ .id = e.id, .kind = e.kind, .bytes = e.bytes.len, .preview = text });
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .available = self.device != null, .locked = self.locked, .persistent = false, .pending = self.read != null, .message = self.message, .entries = items.items }, .{});
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
