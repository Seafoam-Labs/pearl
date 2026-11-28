//! GTK-owned ext-data-control with synchronous, best-effort text persistence.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const ext = @import("wayland").client.ext;
const wl = @import("wayland").client.wl;
const pixbuf = @import("gdkpixbuf2");
pub const policy = @import("clipboard_policy.zig");
const history = @import("clipboard_history.zig");
const file_io = @import("../config/io.zig");
const frame = @import("../cli/frame.zig");
const i18n = @import("i18n");
const log = std.log.scoped(.services);
const a = std.heap.c_allocator;
pub const Entry = struct { id: u64, kind: policy.Kind, bytes: []u8, last_used: i64 };
const Offer = struct { proxy: *ext.DataControlOfferV1, mime: ?[:0]const u8 = null, mime_text: [32:0]u8 = @splat(0), kind: policy.Kind = .text, sensitive: bool = false };
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
        if (accept and !owner.locked) owner.acceptSelection(self.kind, self.bytes.items) catch {
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
    rows: [policy.entries_limit]Entry = undefined,
    len: usize = 0,
    total_bytes: usize = 0,
    next_id: u64 = 1,
    revision: u64 = 0,
    instance: [32]u8 = @splat(0),
    history_loaded: bool = false,
    dirty: bool = false,
    persistence_error: ?anyerror = null,
    removal_failed: bool = false,
    stopping: bool = false,
    history_accessing: bool = false,
    test_time: if (@import("builtin").is_test) ?i64 else void = if (@import("builtin").is_test) null else {},
    test_save: if (@import("builtin").is_test) ?*const fn (*Clipboard) anyerror!void else void = if (@import("builtin").is_test) null else {},
    test_state_home: if (@import("builtin").is_test) ?[]const u8 else void = if (@import("builtin").is_test) null else {},
    read: ?*Transfer = null,
    writes: [4]?*Transfer = @splat(null),
    skip_selection: bool = true,
    locked: bool = true,
    ambiguous: bool = false,
    message: [:0]const u8 = "Clipboard history paused",
    pub fn start(self: *Clipboard) !void {
        var nonce: [16]u8 = undefined;
        var used: usize = 0;
        while (used < nonce.len) {
            const n = std.c.getrandom(nonce[used..].ptr, nonce.len - used, 0);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return error.Unavailable;
            used += @intCast(n);
        }
        self.instance = std.fmt.bytesToHex(nonce, .lower);
        var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
        std.posix.sigaction(.PIPE, &action, null);
        const display = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.Unavailable;
        const connection: *wl.Display = @ptrCast(display.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Clipboard, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Clipboard) void {
        self.stopping = true;
        self.setLocked(true);
        self.revoke();
        self.dropDevice();
        if (self.seat) |s| s.release();
        if (self.manager) |m| m.destroy();
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        // Runtime teardown never calls the user's persistent Clear operation.
        while (self.len != 0) self.remove(self.len - 1);
        self.offers.deinit(a);
    }
    pub fn setLocked(self: *Clipboard, locked: bool) void {
        const closed = locked or self.stopping;
        if (self.locked == closed) return;
        self.locked = closed;
        if (closed) {
            // Transfer completion can notify observers during suspension.
            // The final notification follows the message update below.
            self.suspendCollection();
        } else {
            if (!self.history_loaded) {
                self.history_loaded = true;
                self.loadHistory() catch |err| {
                    self.persistence_error = err;
                    log.warn("event=clipboard-history-load error={s}", .{@errorName(err)});
                };
            }
            _ = self.pruneExpired(self.now());
            _ = self.saveIfNeeded();
            self.connect();
        }
        self.message = self.baseline();
        self.changed(self.context);
    }
    fn baseline(self: *const Clipboard) [:0]const u8 {
        if (self.locked or self.stopping) return i18n.dtr("pearl", "Clipboard history is hidden while paused");
        if (self.removal_failed) return i18n.dtr("pearl", "Removed for this session; saving was not confirmed. Entries may return after restart.");
        if (self.persistence_error != null) return i18n.dtr("pearl", "Clipboard persistence failed; saving was not confirmed");
        return i18n.dtr("pearl", "Text history can be restored for seven days; images stay in this session");
    }
    pub fn accessible(self: *const Clipboard) bool {
        return self.available();
    }
    fn available(self: *const Clipboard) bool {
        return !self.locked and !self.stopping and !self.ambiguous and self.device != null;
    }
    pub fn entries(self: *Clipboard) []const Entry {
        self.maintainHistory();
        return if (self.accessible()) self.rows[0..self.len] else &.{};
    }
    fn now(self: *const Clipboard) i64 {
        if (@import("builtin").is_test) if (self.test_time) |seconds| return seconds;
        return @max(0, @divFloor(glib.getRealTime(), 1_000_000));
    }
    fn maintainHistory(self: *Clipboard) void {
        if (!self.accessible() or self.history_accessing) return;
        self.history_accessing = true;
        defer self.history_accessing = false;
        if (self.pruneExpired(self.now())) {
            _ = self.saveIfNeeded();
            self.message = self.baseline();
            self.changed(self.context);
        }
    }
    fn pruneExpired(self: *Clipboard, seconds: i64) bool {
        var changed = false;
        var index = self.len;
        while (index > 0) {
            index -= 1;
            if (history.expired(self.rows[index].last_used, seconds)) {
                self.remove(index);
                changed = true;
            }
        }
        return changed;
    }
    fn historyPath(self: *const Clipboard, alloc: std.mem.Allocator) ![:0]u8 {
        const state_home = if (@import("builtin").is_test) self.test_state_home orelse std.mem.span(glib.getUserStateDir()) else std.mem.span(glib.getUserStateDir());
        return std.fmt.allocPrintSentinel(alloc, "{s}/pearl/clipboard.json", .{state_home}, 0);
    }
    // The configured state root is trusted. Refuse symlink/non-private Pearl
    // directories and non-private, linked or special destination files. This is
    // not an isolation boundary against hostile processes running as this UID.
    fn privatePath(path: [:0]const u8, directory: bool) !bool {
        var stat: std.os.linux.Statx = undefined;
        const result = std.os.linux.statx(std.os.linux.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true }, &stat);
        if (std.os.linux.errno(result) == .NOENT) return false;
        if (result != 0 or !stat.mask.TYPE or !stat.mask.MODE or !stat.mask.UID or !stat.mask.NLINK) return error.Unsafe;
        const kind: u16 = if (directory) std.c.S.IFDIR else std.c.S.IFREG;
        const mode: u16 = if (directory) 0o700 else 0o600;
        if (stat.mode & std.c.S.IFMT != kind or stat.mode & 0o7777 != mode or stat.uid != std.c.getuid() or (!directory and stat.nlink != 1)) return error.Unsafe;
        return true;
    }
    fn loadHistory(self: *Clipboard) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const path = try self.historyPath(alloc);
        const directory = try alloc.dupeSentinel(u8, std.fs.path.dirname(path).?, 0);
        if (!try privatePath(directory, true) or !try privatePath(path, false)) return;
        const disk = try file_io.read(alloc, path, history.file_limit, null);
        defer std.crypto.secureZero(u8, @constCast(disk.bytes));
        if (disk.missing) return;
        const decoded = try history.decode(alloc, disk.bytes, self.now());
        var loaded: [policy.entries_limit]Entry = undefined;
        var count: usize = 0;
        errdefer for (loaded[0..count]) |entry| wipe(entry.bytes);
        for (decoded.entries) |saved| {
            loaded[count] = .{ .id = self.next_id + count, .kind = .text, .bytes = try a.dupe(u8, saved.text), .last_used = saved.last_used };
            count += 1;
        }
        @memcpy(self.rows[0..count], loaded[0..count]);
        self.len = count;
        self.next_id += count;
        for (self.rows[0..count]) |entry| self.total_bytes += entry.bytes.len;
        self.dirty = decoded.changed;
        self.revision +|= 1;
    }
    fn writeHistory(self: *Clipboard) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const path = try self.historyPath(alloc);
        const directory = try alloc.dupeSentinel(u8, std.fs.path.dirname(path).?, 0);
        if (!try privatePath(directory, true)) {
            try file_io.mkdir(directory);
            if (!try privatePath(directory, true)) return error.Unsafe;
        }
        _ = try privatePath(path, false);
        const json = try history.encode(alloc, self.rows[0..self.len]);
        defer std.crypto.secureZero(u8, json);
        try file_io.atomic(path, json, false);
    }
    fn saveIfNeeded(self: *Clipboard) bool {
        if (!self.dirty) return true;
        const result = if (@import("builtin").is_test) (if (self.test_save) |save| save(self) else self.writeHistory()) else self.writeHistory();
        result catch |err| {
            self.persistence_error = err;
            log.warn("event=clipboard-history-save error={s}", .{@errorName(err)});
            return false;
        };
        self.dirty = false;
        self.persistence_error = null;
        self.removal_failed = false;
        return true;
    }
    pub fn resetMessage(self: *Clipboard) void {
        self.maintainHistory();
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
    fn remove(self: *Clipboard, index: usize) void {
        const entry = self.rows[index];
        self.dirty = self.dirty or entry.kind == .text;
        self.total_bytes -= entry.bytes.len;
        self.len -= 1;
        std.mem.copyForwards(Entry, self.rows[index..self.len], self.rows[index + 1 .. self.len + 1]);
        wipe(entry.bytes);
        self.revision +|= 1;
    }
    /// Suspension preserves text and its dirty state. Callers notify after all
    /// ownership/device changes; this loop neither saves nor invokes callbacks.
    fn discardImages(self: *Clipboard) void {
        var index = self.len;
        while (index > 0) {
            index -= 1;
            if (self.rows[index].kind == .png) self.remove(index);
        }
    }
    fn promote(self: *Clipboard, index: usize, seconds: i64) void {
        var entry = self.rows[index];
        self.dirty = self.dirty or (entry.kind == .text and (entry.last_used != seconds or index != 0));
        entry.last_used = seconds;
        std.mem.copyBackwards(Entry, self.rows[1 .. index + 1], self.rows[0..index]);
        self.rows[0] = entry;
        self.revision +|= 1;
    }
    // A failed save may have renamed the new file already. Memory is still
    // authoritative in this process; failed removals may return after restart.
    fn finishRemoval(self: *Clipboard, success: [:0]const u8) !void {
        const saved = self.saveIfNeeded();
        if (!saved) self.removal_failed = true;
        self.message = if (saved) success else self.baseline();
        self.changed(self.context);
        if (!saved) return error.SaveFailed;
    }
    pub fn clear(self: *Clipboard) !void {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        self.revoke();
        self.history_loaded = true;
        while (self.len != 0) self.remove(self.len - 1);
        self.dirty = true; // Explicit Clear retries even if memory is empty.
        try self.finishRemoval("Clipboard history cleared");
    }
    pub fn delete(self: *Clipboard, id: u64) !void {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        _ = self.pruneExpired(self.now());
        for (self.rows[0..self.len], 0..) |entry, index| if (entry.id == id) {
            self.remove(index);
            try self.finishRemoval("Clipboard entry removed");
            return;
        };
        _ = self.saveIfNeeded();
        self.message = self.baseline();
        self.changed(self.context);
        return error.Stale;
    }
    pub fn add(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        const front = if (self.len != 0) self.rows[0].id else 0;
        const previous = if (self.persistence_error == null) @as(?[:0]const u8, self.message) else null;
        const id = try self.retainEntry(kind, input);
        // Keep transient feedback when an external duplicate is already first.
        self.finishCopy(if (id == front) previous else "Clipboard history updated");
    }
    fn acceptSelection(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        // An active source still owns the selection. Its identical offer is
        // our publication echo; cancellation releases owned before an external
        // copy is accepted, so a real recopy still promotes and refreshes.
        if (self.source != null) if (self.owned) |owned| {
            if (owned.kind == kind and std.mem.eql(u8, owned.bytes, input)) return;
        };
        try self.add(kind, input);
    }
    pub fn copyText(self: *Clipboard, input: []const u8) !void {
        try self.copyValue(.text, input);
    }
    pub fn copyPng(self: *Clipboard, input: []const u8) !void {
        try self.copyValue(.png, input);
    }
    fn retainEntry(self: *Clipboard, kind: policy.Kind, input: []const u8) !u64 {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        const bytes = if (kind == .png) try sanitize(input) else try a.dupe(u8, input);
        return self.retainOwned(kind, bytes);
    }
    /// Consumes the allocation, including on failure. Metadata stays fixed-size.
    fn retainOwned(self: *Clipboard, kind: policy.Kind, bytes: []u8) !u64 {
        errdefer wipe(bytes);
        if (!policy.valid(kind, bytes)) return error.InvalidPayload;
        const next = std.math.add(u64, self.next_id, 1) catch return error.CounterExhausted;
        const seconds = self.now();
        _ = self.pruneExpired(seconds);
        for (self.rows[0..self.len], 0..) |entry, index| if (entry.kind == kind and std.mem.eql(u8, entry.bytes, bytes)) {
            wipe(bytes);
            self.promote(index, seconds);
            return entry.id;
        };
        while (self.len >= policy.entries_limit or bytes.len > policy.total_limit - self.total_bytes) self.remove(self.len - 1);
        std.mem.copyBackwards(Entry, self.rows[1 .. self.len + 1], self.rows[0..self.len]);
        self.rows[0] = .{ .id = self.next_id, .kind = kind, .bytes = bytes, .last_used = seconds };
        self.len += 1;
        self.total_bytes += bytes.len;
        self.next_id = next;
        self.revision +|= 1;
        self.dirty = self.dirty or kind == .text;
        return next - 1;
    }
    fn finishCopy(self: *Clipboard, success: ?[:0]const u8) void {
        _ = self.saveIfNeeded();
        self.message = if (self.persistence_error == null) success orelse self.baseline() else self.baseline();
        self.changed(self.context);
    }
    pub fn select(self: *Clipboard, id: u64) !void {
        if (!self.available()) return if (self.locked or self.stopping or self.ambiguous) error.Locked else error.Unavailable;
        const seconds = self.now();
        const pruned = self.pruneExpired(seconds);
        var copied = false;
        defer if (pruned or copied) self.finishCopy(if (copied) "Copied — paste in the destination application" else null);
        for (self.rows[0..self.len], 0..) |entry, index| if (entry.id == id) {
            const bytes = try a.dupe(u8, entry.bytes);
            errdefer wipe(bytes);
            const source = try self.manager.?.createDataSource();
            self.publish(source, .{ .id = entry.id, .kind = entry.kind, .bytes = bytes, .last_used = entry.last_used });
            self.promote(index, seconds);
            copied = true;
            return;
        };
        return error.Stale;
    }
    fn copyValue(self: *Clipboard, kind: policy.Kind, input: []const u8) !void {
        if (!self.available()) return if (self.locked or self.stopping or self.ambiguous) error.Locked else error.Unavailable;
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        // Reserve the owned paste bytes and Wayland source before changing the
        // history. No fallible work remains between retention and publication.
        const bytes = if (kind == .png) try sanitize(input) else try a.dupe(u8, input);
        errdefer wipe(bytes);
        const source = try self.manager.?.createDataSource();
        errdefer source.destroy();
        const id = try self.retainOwned(kind, try a.dupe(u8, bytes));
        self.publish(source, .{ .id = id, .kind = kind, .bytes = bytes, .last_used = self.now() });
        self.finishCopy("Copied — paste in the destination application");
    }
    fn publish(self: *Clipboard, source: *ext.DataControlSourceV1, entry: Entry) void {
        source.setListener(*Clipboard, sourceEvent, self);
        source.offer(mime(entry.kind));
        self.device.?.setSelection(source);
        if (self.source) |old| old.destroy();
        if (self.owned) |old| wipe(old.bytes);
        self.source = source;
        self.owned = entry;
        self.display.flush();
    }
    fn mime(kind: policy.Kind) [:0]const u8 {
        return if (kind == .text) "text/plain;charset=utf-8" else "image/png";
    }
    fn connect(self: *Clipboard) void {
        if (self.locked or self.stopping or self.ambiguous or self.device != null or self.manager == null or self.seat == null) return;
        self.skip_selection = true;
        self.device = self.manager.?.getDataDevice(self.seat.?) catch return;
        self.device.?.setListener(*Clipboard, deviceEvent, self);
        self.display.flush();
    }
    // Privacy suspension discards images as well as ordinary device resources.
    fn suspendCollection(self: *Clipboard) void {
        self.revoke();
        self.dropDevice();
        self.discardImages();
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
                        self.suspendCollection();
                    } else {
                        self.seat = self.registry.?.bind(g.name, wl.Seat, 5) catch return;
                        self.seat_id = g.name;
                        self.seat.?.setListener(*Clipboard, seatEvent, self);
                    }
                }
                self.connect();
            },
            .global_remove => |g| if (g.name == self.manager_id or g.name == self.seat_id) {
                self.suspendCollection();
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
                o.* = .{ .proxy = ev.id };
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
                self.suspendCollection();
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
        if (std.c.fcntl(fds[0], std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0) return error.Pipe;
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
                if (std.c.fcntl(ev.fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) < 0) return;
                for (&self.writes) |*slot| if (slot.* == null) {
                    const t = a.create(Transfer) catch return;
                    t.* = .{ .owner = self, .fd = ev.fd, .kind = e.kind, .write = true };
                    t.bytes.appendSlice(a, e.bytes) catch {
                        a.destroy(t);
                        return;
                    };
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
    pub const Page = struct {
        offset: u16 = 0,
        limit: u8 = 20,
        revision: ?u64 = null,
        instance: ?[]const u8 = null,
        request_id: []const u8 = "18446744073709551615",
    };
    pub fn pageStatus(self: *Clipboard, alloc: std.mem.Allocator, page: Page) ![]const u8 {
        if (page.offset > policy.entries_limit or page.limit == 0 or page.limit > 20) return error.InvalidRequest;
        self.maintainHistory();
        const visible = self.accessible();
        if (visible) {
            try self.checkInstance(page.instance);
            if (page.revision) |revision| if (revision != self.revision) return error.StaleRevision;
        }
        const Item = struct { id: u64, kind: policy.Kind, bytes: usize, preview: []const u8, last_copy: i64 };
        var items: [20]Item = undefined;
        var previews: [20]?[:0]u8 = @splat(null);
        defer for (previews) |preview| if (preview) |text| {
            std.crypto.secureZero(u8, text);
            alloc.free(text);
        };
        const rows = if (visible) self.rows[0..self.len] else &.{};
        const offset = @min(page.offset, rows.len);
        var count: usize = 0;
        for (rows[offset..@min(rows.len, offset + page.limit)]) |entry| {
            const preview = if (entry.kind == .text) blk: {
                const text = try policy.preview(alloc, entry.bytes);
                previews[count] = text;
                break :blk text;
            } else "PNG image";
            items[count] = .{ .id = entry.id, .kind = entry.kind, .bytes = entry.bytes.len, .preview = preview, .last_copy = entry.last_used };
            count += 1;
        }
        while (true) {
            const more = offset + count < rows.len;
            const result = try std.json.Stringify.valueAlloc(alloc, .{
                .available = visible,
                .locked = !visible,
                .persistent = self.history_loaded and self.persistence_error == null,
                .persistent_kinds = [_][]const u8{"text"},
                .entries_limit = policy.entries_limit,
                .retention_days = @divExact(policy.retention_seconds, 86400),
                .pending = visible and self.read != null,
                .dirty = visible and self.dirty,
                .persistence_error = if (visible) (if (self.persistence_error) |err| @errorName(err) else null) else null,
                .message = if (visible) self.message else self.baseline(),
                .total = if (visible) @as(?usize, rows.len) else null,
                .offset = if (visible) @as(?u16, page.offset) else null,
                .limit = if (visible) @as(?u8, page.limit) else null,
                .returned = if (visible) @as(?usize, count) else null,
                .has_more = more,
                .next_offset = if (more) @as(?usize, offset + count) else null,
                .revision = if (visible) @as(?u64, self.revision) else null,
                .instance = if (visible) @as(?[]const u8, &self.instance) else null,
                .entries = items[0..count],
            }, .{});
            if (frame.successLength(page.request_id, result) <= frame.max_frame) return result;
            std.crypto.secureZero(u8, result);
            alloc.free(result);
            if (count <= 1) return error.ResponseTooLarge;
            count -= 1;
        }
    }
    pub fn checkInstance(self: *Clipboard, instance: ?[]const u8) !void {
        if (self.locked or self.stopping or self.ambiguous) return error.Locked;
        if (instance) |value| if (!std.mem.eql(u8, value, &self.instance)) return error.StaleInstance;
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

test "own selection echo does not save or refresh but external recopy does" {
    const Fixture = @import("../testing/clipboard.zig").Fixture;
    const Capture = struct {
        fn finish(clipboard: *Clipboard) !void {
            var fds: [2]c_int = undefined;
            if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.TestPipe;
            defer _ = std.c.close(fds[1]);
            const transfer = try a.create(Transfer);
            transfer.* = .{ .owner = clipboard, .fd = fds[0], .kind = .text };
            try transfer.bytes.appendSlice(a, "same text");
            clipboard.read = transfer;
            transfer.finish(true);
        }
    };
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const id = try f.copy("same text", 100);
    f.clipboard.source = @ptrFromInt(1); // identity only, never dispatched
    defer f.clipboard.source = null;
    f.clipboard.owned = .{ .id = id, .kind = .text, .bytes = try a.dupe(u8, "same text"), .last_used = 100 };
    const writes = f.writes;
    f.clipboard.test_time = 200;
    try Capture.finish(&f.clipboard);
    try std.testing.expectEqual(writes, f.writes);
    try std.testing.expectEqual(@as(i64, 100), f.clipboard.rows[0].last_used);
    // Cancellation precedes an external owner's offer; even identical text is
    // a genuine copy and must refresh retention.
    f.clipboard.source = null;
    Clipboard.wipe(f.clipboard.owned.?.bytes);
    f.clipboard.owned = null;
    try Capture.finish(&f.clipboard);
    try std.testing.expectEqual(writes + 1, f.writes);
    try std.testing.expectEqual(id, f.clipboard.rows[0].id);
    try std.testing.expectEqual(@as(i64, 200), f.clipboard.rows[0].last_used);
}

test "PNG selection metadata and lifecycle callbacks preserve text without saves" {
    const fixture = @import("../testing/clipboard.zig");
    const Observer = struct {
        clipboard: *Clipboard,
        hidden: bool = false,
        fn changed(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.hidden = self.clipboard.entries().len == 0;
        }
    };
    for (0..4) |mode| {
        var pair: [2]c_int = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0, &pair) != 0) return error.TestSocket;
        defer _ = std.c.close(pair[1]);
        const connection = try wl.Display.connectToFd(pair[0]);
        defer connection.disconnect();
        const registry = try connection.getRegistry();
        defer @as(*wl.Proxy, @ptrCast(registry)).destroy();
        var f: fixture.Fixture = undefined;
        f.init();
        defer f.deinit();
        // Client proxies marshal only into this disposable socket pair. No
        // server, display environment or installed compositor is contacted.
        f.clipboard.manager = try registry.bind(8, ext.DataControlManagerV1, 1);
        f.clipboard.manager_id = 8;
        f.clipboard.seat = try registry.bind(9, wl.Seat, 5);
        f.clipboard.seat_id = 9;
        registry.setListener(*Clipboard, Clipboard.registryEvent, &f.clipboard);
        f.clipboard.device = try f.clipboard.manager.?.getDataDevice(f.clipboard.seat.?);
        f.clipboard.device.?.setListener(*Clipboard, Clipboard.deviceEvent, &f.clipboard);
        try std.testing.expect(f.clipboard.accessible());
        _ = try f.copy("older text", 100);
        _ = try f.copy("newer text", 200);
        const retained = f.clipboard.rows[0..2].*;
        const png = try fixture.image(0x765432ff);
        defer a.free(png);
        try f.clipboard.add(.png, png);
        const image = f.clipboard.rows[0];
        f.clipboard.owned = .{ .id = image.id, .kind = .png, .bytes = try a.dupe(u8, image.bytes), .last_used = image.last_used };
        const writes = f.writes;
        f.clipboard.promote(0, 250); // selection's timestamp/promotion operation
        f.clipboard.finishCopy(null);
        try std.testing.expectEqual(writes, f.writes);
        const revision = f.clipboard.revision;
        const notifications = f.notifications;
        var observer: Observer = .{ .clipboard = &f.clipboard };
        f.context = &observer;
        f.on_change = Observer.changed;
        f.clipboard.test_time = 300;
        if (mode == 0) {
            var event = [_]u32{ registry.getId(), 28 << 16, 10, 8, 0, 0, 5 };
            @memcpy(std.mem.asBytes(&event)[16..24], "wl_seat\x00");
            try std.testing.expectEqual(@as(isize, 28), std.c.write(pair[1], std.mem.asBytes(&event), 28));
            try std.testing.expectEqual(std.posix.E.SUCCESS, connection.dispatch());
            try std.testing.expect(f.clipboard.ambiguous);
        } else if (mode == 3) {
            const event = [_]u32{ f.clipboard.device.?.getId(), (8 << 16) | 2 };
            try std.testing.expectEqual(@as(isize, 8), std.c.write(pair[1], std.mem.asBytes(&event), 8));
            try std.testing.expectEqual(std.posix.E.SUCCESS, connection.dispatch());
            try std.testing.expect(f.clipboard.device == null);
        } else {
            const event = [_]u32{ registry.getId(), (12 << 16) | 1, if (mode == 1) 9 else 8 };
            try std.testing.expectEqual(@as(isize, 12), std.c.write(pair[1], std.mem.asBytes(&event), 12));
            try std.testing.expectEqual(std.posix.E.SUCCESS, connection.dispatch());
        }
        try std.testing.expect(!f.clipboard.locked and !f.clipboard.accessible() and observer.hidden);
        try std.testing.expect(f.clipboard.device == null and f.clipboard.owned == null);
        try std.testing.expectEqual(@as(usize, 2), f.clipboard.len);
        // Compare text order, IDs, kinds and timestamps together.
        try std.testing.expectEqualDeep(retained, f.clipboard.rows[0..2].*);
        try std.testing.expectEqual(retained[0].bytes.len + retained[1].bytes.len, f.clipboard.total_bytes);
        try std.testing.expectEqual(revision + 1, f.clipboard.revision);
        try std.testing.expectEqual(notifications + 1, f.notifications);
        try std.testing.expectEqual(writes, f.writes);
        try std.testing.expect(!f.clipboard.dirty and f.clipboard.persistence_error == null);
    }
}
