//! Main-context-only scheduler. Entries own results; listeners pin cache entries.
const std = @import("std");
const u = @import("../ui.zig");
const gio = u.gio;
const glib = u.glib;
const gdk = @import("gdk4");
const policy = @import("../core/preview.zig");
const a = u.a;
const Read = @import("preview_read.zig").Read;
const Providers = @import("preview_providers.zig");
var capabilities: ?Providers.Snapshot = null;
var discovering = false;
var discovery_read: ?*Read = null;
var generation: u64 = 0;
var last_discovery: i64 = 0;
pub var heavy_running: usize = 0;
pub const Listener = struct { data: *anyopaque, ready: *const fn (*anyopaque, *Entry) void };
pub const State = enum { queued, running, ready };
pub const Entry = struct {
    key: [:0]u8,
    uri: [:0]u8,
    seconds: u64,
    usec: u32,
    size: i64,
    edge: u32,
    limit: usize,
    text: bool,
    priority: u8,
    state: State = .queued,
    listeners: std.ArrayList(*Listener) = .empty,
    process: ?*Read = null,
    provider: policy.Provider,
    retry_after: i64 = 0,
    texture: ?*gdk.Texture = null,
    caption: ?[:0]u8 = null,
    kind: policy.Kind = .unavailable,
    cost: usize = 0,
    touched: u64 = 0,
    killed: bool = false,
    fn deinit(self: *Entry) void {
        if (self.texture) |p| p.unref();
        if (self.caption) |s| a.free(s);
        a.free(self.key);
        a.free(self.uri);
        self.listeners.deinit(a);
        a.destroy(self);
    }
};
var entries: std.ArrayList(*Entry) = .empty;
var application: ?*gio.Application = null;
var next_stamp: u64 = 0;
pub var memory: usize = 0;
pub var running: usize = 0;
pub var started: usize = 0;
pub var hits: usize = 0;
pub var max_main_loop_gap_us: i64 = 0;
var heartbeat_id: c_uint = 0;
var last_heartbeat: i64 = 0;
pub var changed: ?*const fn () void = null;
var pump_id: c_uint = 0;
pub fn init(app: *gio.Application) void {
    application = app;
    if (@import("build_options").test_hooks) {
        last_heartbeat = glib.getMonotonicTime();
        heartbeat_id = glib.timeoutAdd(10, heartbeat, null);
    }
}
fn heartbeat(_: ?*anyopaque) callconv(.c) c_int {
    const now = glib.getMonotonicTime();
    if (running > 0) max_main_loop_gap_us = @max(max_main_loop_gap_us, now - last_heartbeat);
    last_heartbeat = now;
    return 1;
}
pub fn deinit() void {
    if (heartbeat_id != 0) {
        _ = glib.Source.remove(heartbeat_id);
        heartbeat_id = 0;
    }
    if (pump_id != 0) {
        _ = glib.Source.remove(pump_id);
        pump_id = 0;
    }
    if (@import("build_options").test_hooks) glib.printerr("PHYTO_PREVIEW_STOP running=%zu entries=%zu\n", running, entries.items.len);
    std.debug.assert(running == 0);
    for (entries.items) |e| {
        std.debug.assert(e.listeners.items.len == 0);
        e.deinit();
    }
    entries.deinit(a);
    entries = .empty;
    memory = 0;
    application = null;
}
pub fn eligible(info: *gio.FileInfo, allow_text: bool) bool {
    if (info.getFileType() != .regular or info.getIsSymlink() != 0) return false;
    if (info.hasAttribute("access::can-read") != 0 and info.getAttributeBoolean("access::can-read") == 0) return false;
    const file = u.file(info);
    if (file.isNative() == 0) return false;
    const mime = std.mem.span(info.getContentType() orelse return false);
    return policy.provider(mime) != .builtin or policy.raster(mime) or (allow_text and policy.textType(mime));
}
pub fn identity(info: *gio.FileInfo, edge: u32, limit: usize, allow_text: bool) [:0]u8 {
    const uri = u.file(info).getUri();
    defer glib.free(uri);
    return u.format("{s}\n{d}:{d}:{d}:{d}:{d}:{d}:{d}:{d}", .{ uri, info.getAttributeUint64("time::modified"), info.getAttributeUint32("time::modified-usec"), info.getSize(), edge, limit, @intFromBool(allow_text), @intFromEnum(policy.provider(std.mem.span(info.getContentType() orelse ""))), generation });
}
fn queuePump() void {
    if (pump_id == 0) pump_id = glib.idleAdd(pump, null);
}
pub fn request(info: *gio.FileInfo, edge: u32, limit: usize, allow_text: bool, priority: u8, listener: *Listener) ?*Entry {
    if (!eligible(info, allow_text)) return null;
    const provider = policy.provider(std.mem.span(info.getContentType() orelse ""));
    if (provider != .builtin and priority == 0 and capabilities != null and !discovering and glib.getMonotonicTime() - last_discovery > 5_000_000) {
        const status = if (provider == .pdf) capabilities.?.pdf else capabilities.?.video;
        if (status != 0) {
            capabilities = null;
            queuePump();
        }
    }
    const key = identity(info, edge, limit, allow_text);
    for (entries.items) |e| if (!e.killed and std.mem.eql(u8, e.key, key)) {
        if (e.kind == .unavailable and e.state == .ready and e.listeners.items.len == 0 and (priority == 0 or glib.getMonotonicTime() >= e.retry_after)) {
            remove(e);
            break;
        }
        a.free(key);
        e.listeners.append(a, listener) catch unreachable;
        e.priority = @min(e.priority, priority);
        next_stamp += 1;
        e.touched = next_stamp;
        if (e.state == .ready) hits += 1;
        return e;
    };
    var queued: usize = 0;
    for (entries.items) |e| if (e.state == .queued) {
        queued += 1;
    };
    if (queued >= policy.max_queue) {
        var dropped = false;
        if (priority < 2) for (entries.items) |e| {
            if (e.state == .queued and e.priority == 2) {
                fail(e, "Preview deferred while another file is being previewed.");
                deliver(e);
                dropped = true;
                break;
            }
        };
        if (!dropped) {
            a.free(key);
            return null;
        }
    }
    _ = makeRoom(0);
    if (entries.items.len >= 512) {
        a.free(key);
        return null;
    }
    const uri = u.file(info).getUri();
    defer glib.free(uri);
    const e = a.create(Entry) catch unreachable;
    next_stamp += 1;
    e.* = .{ .key = key, .uri = a.dupeZ(u8, std.mem.span(uri)) catch unreachable, .seconds = info.getAttributeUint64("time::modified"), .usec = info.getAttributeUint32("time::modified-usec"), .size = info.getSize(), .edge = edge, .limit = limit, .text = allow_text, .priority = priority, .provider = provider, .touched = next_stamp };
    e.listeners.append(a, listener) catch unreachable;
    entries.append(a, e) catch unreachable;
    queuePump();
    return e;
}
pub fn detach(e: *Entry, listener: *Listener) void {
    for (e.listeners.items, 0..) |l, i| if (l == listener) {
        _ = e.listeners.swapRemove(i);
        break;
    };
    if (e.listeners.items.len == 0 and e.state != .ready) {
        if (e.process) |p| {
            e.killed = true;
            p.cancel();
        } else remove(e);
        if (discovery_read) |read| {
            for (entries.items) |other| if (other.provider != .builtin and other.state != .ready) return;
            read.cancel();
        }
    }
}
fn remove(e: *Entry) void {
    for (entries.items, 0..) |entry, i| if (entry == e) {
        _ = entries.swapRemove(i);
        break;
    };
    memory -= e.cost;
    e.deinit();
}
fn makeRoom(cost: usize) bool {
    while (memory + cost > policy.memory_limit or entries.items.len >= 512) {
        var oldest: ?*Entry = null;
        for (entries.items) |e| if (e.state == .ready and e.listeners.items.len == 0 and (oldest == null or e.touched < oldest.?.touched)) {
            oldest = e;
        };
        if (oldest) |e| remove(e) else return false;
    }
    return true;
}
fn pump(_: ?*anyopaque) callconv(.c) c_int {
    pump_id = 0;
    if (capabilities == null and !discovering) {
        for (entries.items) |e| if (e.provider != .builtin and e.state == .queued) {
            const argv = [_:null]?[*:0]const u8{ "/proc/self/exe", "--preview-capabilities" };
            discovery_read = Read.start(&argv, @sizeOf(Providers.Snapshot), 6000, discovered, null);
            if (discovery_read != null) {
                discovering = true;
                application.?.hold();
            } else capabilities = .{};
            break;
        };
    }
    while (running < policy.max_jobs) {
        var best: ?*Entry = null;
        for (entries.items) |e| if (e.state == .queued and (e.provider == .builtin or (capabilities != null and heavy_running == 0)) and (best == null or e.priority < best.?.priority)) {
            best = e;
        };
        const e = best orelse break;
        if (e.provider != .builtin) {
            const code = if (e.provider == .pdf) capabilities.?.pdf else capabilities.?.video;
            const status = std.enums.fromInt(policy.Status, code) orelse .failed;
            if (status != .ok) {
                fail(e, policy.message(status));
                deliver(e);
                continue;
            }
        }
        const edge = u.format("{d}", .{e.edge});
        defer a.free(edge);
        const limit = u.format("{d}", .{e.limit});
        defer a.free(limit);
        const seconds = u.format("{d}", .{e.seconds});
        defer a.free(seconds);
        const usec = u.format("{d}", .{e.usec});
        defer a.free(usec);
        const size = u.format("{d}", .{e.size});
        defer a.free(size);
        // Resolve the parent's executable: /proc/self/exe in the child remains
        // the same binary, including when packaged as phyto-git.
        const argv = [_:null]?[*:0]const u8{ "/proc/self/exe", "--preview-helper", e.uri, edge, limit, if (e.text) "1" else "0", if (e.edge <= 1024) "1" else "0", seconds, usec, size, @tagName(e.provider), if (e.priority == 0) "10000" else "5000" };
        e.process = Read.start(&argv, 16 + policy.max_edge * policy.max_edge * 4, if (e.priority == 0) 10000 else 5000, completed, e);
        if (e.process != null) {
            e.state = .running;
            running += 1;
            if (e.provider != .builtin) heavy_running += 1;
            started += 1;
            application.?.hold();
        } else {
            fail(e, "Could not start the preview decoder.");
            deliver(e);
        }
    }
    return 0;
}
fn discovered(read: *Read, success: bool, _: ?*anyopaque) void {
    defer application.?.release();
    discovering = false;
    discovery_read = null;
    capabilities = .{};
    if (success and read.bytes.items.len == @sizeOf(Providers.Snapshot) and std.mem.eql(u8, read.bytes.items[0..4], "PHP1")) {
        capabilities = std.mem.bytesToValue(Providers.Snapshot, read.bytes.items);
    }
    generation += 1;
    last_discovery = glib.getMonotonicTime();
    queuePump();
    if (changed) |notify| notify();
}
fn fail(e: *Entry, message: []const u8) void {
    e.state = .ready;
    e.retry_after = glib.getMonotonicTime() + 5_000_000;
    e.caption = a.dupeZ(u8, message) catch unreachable;
}
fn deliver(e: *Entry) void {
    if (@import("build_options").test_hooks and e.kind == .unavailable) glib.printerr("PHYTO_PREVIEW_FAILURE %s\n", if (e.caption) |caption| caption.ptr else @as([*:0]const u8, "unknown"));
    for (e.listeners.items) |l| l.ready(l.data, e);
    if (changed) |notify| notify();
}
fn completed(read: *Read, success: bool, data: ?*anyopaque) void {
    const e: *Entry = @ptrCast(@alignCast(data.?));
    defer application.?.release();
    running -= 1;
    if (e.provider != .builtin) heavy_running -= 1;
    e.process = null;
    queuePump();
    if (e.killed or e.listeners.items.len == 0) {
        remove(e);
        return;
    }
    if (!success) {
        fail(e, if (read.timeout) policy.message(.timeout) else "Preview exceeded its limits or the decoder failed.");
        deliver(e);
        return;
    }
    const raw = read.bytes.items;
    const n = raw.len;
    const h = policy.parse(raw[0..n]) catch {
        fail(e, "Decoder returned an invalid preview.");
        deliver(e);
        return;
    };
    if (h.kind == .image and !makeRoom(h.length)) {
        fail(e, "Preview memory limit reached.");
    } else {
        e.state = .ready;
        e.kind = h.kind;
        if (h.kind == .image) {
            const pixels = glib.Bytes.new(raw[16..].ptr, h.length);
            defer pixels.unref();
            e.texture = gdk.MemoryTexture.new(@intCast(h.width), @intCast(h.height), .r8g8b8a8, pixels, @as(usize, h.width) * 4).as(gdk.Texture);
            e.cost = h.length;
            memory += e.cost;
        } else {
            e.retry_after = glib.getMonotonicTime() + 5_000_000;
            e.caption = a.dupeZ(u8, if (h.status != .ok) policy.message(h.status) else raw[16..n]) catch unreachable;
        }
    }
    deliver(e);
}
