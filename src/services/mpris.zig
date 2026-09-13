//! MPRIS players are keyed by well-known name AND a monotonically increasing owner generation.
const std = @import("std");
const transport = @import("session_bus.zig");
const db = transport.db;
const glib = db.glib;
const path = "/org/mpris/MediaPlayer2";
const iface = "org.mpris.MediaPlayer2.Player";
pub const Player = struct {
    name: db.Text(256) = .{},
    owner: db.Text(256) = .{},
    generation: u64 = 0,
    title: db.Text(512) = .{},
    artist: db.Text(512) = .{},
    identity: db.Text(512) = .{},
    art_url: db.Text(512) = .{},
    track: db.Text(512) = .{},
    playback: db.Text(32) = .{},
    length: i64 = 0,
    position: i64 = 0,
    sampled: i64 = 0,
    rate: f64 = 1,
    control: bool = false,
    play: bool = false,
    pause: bool = false,
    next: bool = false,
    previous: bool = false,
    seek: bool = false,
    dirty: bool = false,
    loading: bool = false,
    ready: bool = false,
    busy: bool = false,
    pub fn progress(self: *const Player) i64 {
        const elapsed = if (std.mem.eql(u8, self.playback.slice(), "Playing")) glib.getMonotonicTime() - self.sampled else 0;
        const scaled: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(std.math.maxInt(i64) / 2)), @as(f64, @floatFromInt(@max(0, elapsed))) * self.rate));
        return @min(if (self.length > 0) self.length else std.math.maxInt(i64), self.position +| scaled);
    }
};
pub const Action = enum { select, play_pause, play, pause, stop, next, previous, seek };
pub const Media = struct {
    bus: *transport.Bus,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    players: [8]Player = @splat(.{}),
    generation: u64 = 0,
    selected: u64 = 0,
    revision: u64 = 0,
    art: @import("artwork.zig").Art = .{},
    viewers: usize = 0,
    timer: c_uint = 0,
    err: ?[]const u8 = null,
    pub fn start(self: *Media) void {
        self.art.app = self.bus.app;
        self.art.context = self;
        self.art.changed = artChanged;
        self.bus.call(self, 0, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", null, "(as)", listed) catch {};
    }
    pub fn stop(self: *Media) void {
        self.art.want("");
        self.err = null;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        self.players = @splat(.{});
        self.selected = 0;
        self.notify();
    }
    fn artChanged(data: *anyopaque) void {
        const self: *Media = @ptrCast(@alignCast(data));
        self.revision += 1;
        self.changed(self.context);
    }
    pub fn view(self: *Media, show: bool) void {
        if (show) self.viewers += 1 else self.viewers -|= 1;
        self.updateArt();
    }
    fn updateArt(self: *Media) void {
        const p = if (self.viewers > 0) self.current() else null;
        self.art.want(if (p) |player| player.art_url.slice() else "");
    }
    fn notify(self: *Media) void {
        self.updateArt();
        self.revision += 1;
        self.changed(self.context);
    }
    fn listed(data: *anyopaque, _: u64, value: ?*glib.Variant) void {
        const self: *Media = @ptrCast(@alignCast(data));
        const v = value orelse return;
        const names = v.getChildValue(0);
        defer names.unref();
        for (0..@min(names.nChildren(), 2048)) |i| {
            const n = transport.childText(256, names, i);
            self.add(n.z());
        }
    }
    fn add(self: *Media, name: [:0]const u8) void {
        if (!std.mem.startsWith(u8, name, "org.mpris.MediaPlayer2.") or name.len > 255) return;
        for (&self.players) |*p| if (std.mem.eql(u8, p.name.slice(), name)) return;
        for (&self.players) |*p| if (p.name.len == 0) {
            self.generation += 1;
            p.* = .{ .generation = self.generation };
            p.name.set(name);
            transport.resolve(self.bus, self, p.generation, p.name.z(), resolved) catch {
                p.* = .{};
            };
            return;
        };
    }
    pub fn find(self: *Media, generation: u64) ?*Player {
        if (generation == 0) return null;
        for (&self.players) |*p| if (p.generation == generation and p.name.len != 0) return p;
        return null;
    }
    pub fn current(self: *Media) ?*Player {
        if (self.find(self.selected)) |p| if (p.ready) return p;
        for (&self.players) |*p| if (p.ready) {
            self.selected = p.generation;
            return p;
        };
        return null;
    }
    fn resolved(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Media = @ptrCast(@alignCast(data));
        const p = self.find(token) orelse return;
        const v = value orelse {
            p.* = .{};
            self.notify();
            return;
        };
        p.owner = transport.childText(256, v, 0);
        p.dirty = true;
        self.arm();
        transport.getAll(self.bus, self, token, p.owner.z(), path, "org.mpris.MediaPlayer2", rootDone) catch {};
    }
    fn rootDone(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Media = @ptrCast(@alignCast(data));
        const p = self.find(token) orelse return;
        if (value) |v| {
            const props = v.getChildValue(0);
            defer props.unref();
            p.identity = db.string(props, "Identity", "s");
            self.notify();
        }
    }
    pub fn ownerChanged(self: *Media, name: [:0]const u8, new: []const u8) void {
        for (&self.players) |*p| if (std.mem.eql(u8, p.name.slice(), name)) {
            self.err = null;
            p.* = .{};
            self.notify();
        };
        if (new.len != 0) self.add(name);
    }
    pub fn signal(self: *Media, sender: []const u8, object_path: []const u8, interface: []const u8, member: []const u8, params: *glib.Variant) void {
        if (!std.mem.eql(u8, object_path, path)) return;
        for (&self.players) |*p| if (p.owner.len != 0 and std.mem.eql(u8, p.owner.slice(), sender)) {
            if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Properties") and std.mem.eql(u8, member, "PropertiesChanged") and db.is(params, "(sa{sv}as)")) {
                const target = transport.childText(128, params, 0);
                if (std.mem.eql(u8, target.slice(), iface)) {
                    p.dirty = true;
                    self.arm();
                }
            } else if (std.mem.eql(u8, interface, iface) and std.mem.eql(u8, member, "Seeked") and db.is(params, "(x)")) {
                const v = params.getChildValue(0);
                defer v.unref();
                p.position = @max(0, v.getInt64());
                p.sampled = glib.getMonotonicTime();
                self.notify();
            }
        };
    }
    fn arm(self: *Media) void {
        if (self.timer == 0) self.timer = glib.timeoutAdd(100, tick, self);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Media = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        for (&self.players) |*p| if (p.dirty and !p.loading and p.owner.len != 0) {
            p.dirty = false;
            p.loading = true;
            transport.getAll(self.bus, self, p.generation, p.owner.z(), path, iface, properties) catch {
                p.loading = false;
            };
        };
        return 0;
    }
    fn properties(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Media = @ptrCast(@alignCast(data));
        const p = self.find(token) orelse return;
        p.loading = false;
        const v = value orelse {
            p.ready = false;
            self.notify();
            return;
        };
        if (v.getSize() > 512 * 1024) {
            p.ready = false;
            self.notify();
            return;
        }
        const props = v.getChildValue(0);
        defer props.unref();
        const status = db.string(props, "PlaybackStatus", "s");
        p.playback.set(status.slice());
        p.control = db.boolean(props, "CanControl");
        p.play = db.boolean(props, "CanPlay");
        p.pause = db.boolean(props, "CanPause");
        p.next = db.boolean(props, "CanGoNext");
        p.previous = db.boolean(props, "CanGoPrevious");
        p.seek = db.boolean(props, "CanSeek");
        p.title = .{};
        p.artist = .{};
        p.track = .{};
        p.art_url = .{};
        p.length = 0;
        if (db.lookup(props, "Metadata", "a{sv}")) |metadata| {
            defer metadata.unref();
            p.title = db.string(metadata, "xesam:title", "s");
            p.track = db.string(metadata, "mpris:trackid", "o");
            p.art_url = db.string(metadata, "mpris:artUrl", "s");
            if (db.lookup(metadata, "xesam:artist", "as")) |artists| {
                defer artists.unref();
                if (artists.nChildren() != 0) p.artist = transport.childText(512, artists, 0);
            }
            if (db.lookup(metadata, "mpris:length", "x")) |length| {
                defer length.unref();
                p.length = @max(0, length.getInt64());
            }
        }
        // Missing/invalidated properties must clear old capabilities and metadata.
        p.position = 0;
        if (db.lookup(props, "Position", "x")) |pos| {
            defer pos.unref();
            p.position = @max(0, pos.getInt64());
        }
        p.rate = 1;
        if (db.lookup(props, "Rate", "d")) |rate| {
            defer rate.unref();
            const r = rate.getDouble();
            if (std.math.isFinite(r) and r >= 0 and r <= 100) p.rate = r;
        }
        p.sampled = glib.getMonotonicTime();
        p.ready = true;
        self.notify();
        if (p.dirty) self.arm();
    }
    pub fn act(self: *Media, generation: u64, action: Action, position: i64) !void {
        const p = self.find(generation) orelse return error.InvalidValue;
        if (!p.ready) return error.Unavailable;
        if (action == .select) {
            self.selected = generation;
            self.notify();
            return;
        }
        if (p.busy) return error.Busy;
        if (!p.control) return error.Unsupported;
        const playing = std.mem.eql(u8, p.playback.slice(), "Playing");
        const allowed = switch (action) {
            .play_pause => if (playing) p.pause else p.play,
            .play => p.play,
            .pause => p.pause,
            .next => p.next,
            .previous => p.previous,
            .seek => p.seek and p.track.len > 0 and p.length > 0 and position >= 0 and position <= p.length,
            .stop => true,
            .select => unreachable,
        };
        if (!allowed) return error.Unsupported;
        const method: [:0]const u8 = switch (action) {
            .play_pause => "PlayPause",
            .play => "Play",
            .pause => "Pause",
            .stop => "Stop",
            .next => "Next",
            .previous => "Previous",
            .seek => "SetPosition",
            .select => unreachable,
        };
        try self.bus.call(self, generation, p.owner.z(), path, iface, method, if (action == .seek) db.tuple(&.{ db.path(p.track.z()), glib.Variant.newInt64(position) }) else null, "()", acted);
        p.busy = true;
        self.err = null;
        self.notify();
    }
    fn acted(data: *anyopaque, token: u64, value: ?*glib.Variant) void {
        const self: *Media = @ptrCast(@alignCast(data));
        const p = self.find(token) orelse return;
        p.busy = false;
        self.err = if (value == null) "The player did not accept the action." else null;
        p.dirty = true;
        self.arm();
        self.notify();
    }
};
