//! Watches one file that may not exist yet, nor its directory: the
//! administrator's catalog lives in /etc/scx, which a fresh system does not
//! have until the first `scxcli catalog save` makes it, and scx may be
//! installed after Pearl starts. A GFileMonitor on a path whose directory is
//! missing is made all the same but never reports anything, so this watches
//! the deepest directory that exists, for the next component of the path,
//! and moves down when that appears (or up when it goes). It calls back on
//! any change that may concern the file, including a directory on its path
//! appearing, since the file may have been written into it before the
//! watch moved there.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const log = std.log.scoped(.services);

pub const Watch = struct {
    /// The file watched, absolute.
    path: [256]u8 = undefined,
    path_len: usize = 0,
    /// How much of `path` is the directory watched now.
    dir_len: usize = 0,
    monitor: ?*gio.FileMonitor = null,
    signal: c_ulong = 0,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,

    pub fn start(self: *Watch, path: []const u8) void {
        self.stop();
        if (path.len == 0 or path[0] != '/' or path.len >= self.path.len) return log.warn("event=catalog-watch path={s} result=invalid", .{path});
        @memcpy(self.path[0..path.len], path);
        self.path_len = path.len;
        self.arm();
    }

    pub fn stop(self: *Watch) void {
        if (self.monitor) |m| {
            object.signalHandlerDisconnect(m.as(object.Object), self.signal);
            _ = m.cancel();
            m.unref();
        }
        self.monitor = null;
    }

    pub fn target(self: *const Watch) []const u8 {
        return self.path[0..self.path_len];
    }

    /// The directory watched now, for tests and logs.
    pub fn watched(self: *const Watch) []const u8 {
        return if (self.dir_len == 0) "/" else self.path[0..self.dir_len];
    }

    /// The path component the watched directory is watched for.
    fn child(self: *const Watch) []const u8 {
        const rest = self.path[self.dir_len + 1 .. self.path_len];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
    }

    /// Watch the deepest existing directory on the file's path.
    fn arm(self: *Watch) void {
        self.stop();
        var buffer: [256:0]u8 = undefined;
        // From the file's own directory upwards.
        var len = std.mem.lastIndexOfScalar(u8, self.target(), '/') orelse return;
        while (true) {
            const dir: [:0]const u8 = if (len == 0) "/" else blk: {
                @memcpy(buffer[0..len], self.path[0..len]);
                buffer[len] = 0;
                break :blk buffer[0..len :0];
            };
            if (glib.fileTest(dir, .{ .is_dir = true }) != 0) {
                const file = gio.File.newForPath(dir);
                defer file.unref();
                var err: ?*glib.Error = null;
                const monitor = file.monitorDirectory(.{ .watch_moves = true }, null, &err) orelse {
                    defer if (err) |e| e.free();
                    return log.warn("event=catalog-watch dir={s} result=unavailable", .{dir});
                };
                self.dir_len = len;
                self.monitor = monitor;
                self.signal = gio.FileMonitor.signals.changed.connect(monitor, *Watch, event, self, .{});
                return;
            }
            if (len == 0) return;
            len = std.mem.lastIndexOfScalar(u8, self.path[0..len], '/') orelse return;
        }
    }

    fn event(monitor: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, kind: gio.FileMonitorEvent, self: *Watch) callconv(.c) void {
        _ = monitor;
        const name = self.child();
        const last = self.dir_len + 1 + name.len == self.path_len;
        // The directory watched went away: watch further up.
        const itself = kind == .deleted or kind == .moved_out or kind == .renamed;
        if (itself and isDir(file, self.watched())) {
            self.arm();
            return self.changed(self.context);
        }
        if (!(named(file, name) or (other != null and named(other.?, name)))) return;
        if (!last) {
            // A directory on the way appeared or went: move the watch.
            self.arm();
        }
        self.changed(self.context);
    }

    fn named(file: *gio.File, name: []const u8) bool {
        const base = file.getBasename() orelse return false;
        defer glib.free(base);
        return std.mem.eql(u8, std.mem.span(base), name);
    }

    fn isDir(file: *gio.File, dir: []const u8) bool {
        const path = file.getPath() orelse return false;
        defer glib.free(path);
        return std.mem.eql(u8, std.mem.span(path), dir);
    }
};

const t = std.testing;

const Counter = struct {
    calls: usize = 0,
    fn bump(data: *anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(data));
        self.calls += 1;
    }
};

/// Run the main loop until the callback ran `at_least` times or a second
/// has passed.
fn settle(counter: *Counter, at_least: usize) void {
    var waited: usize = 0;
    while (waited < 1000) : (waited += 10) {
        while (glib.MainContext.iteration(null, 0) != 0) {}
        if (counter.calls >= at_least) {
            // Let the rest of the burst arrive.
            var rest: usize = 0;
            while (rest < 100) : (rest += 10) {
                while (glib.MainContext.iteration(null, 0) != 0) {}
                glib.usleep(10_000);
            }
            return;
        }
        glib.usleep(10_000);
    }
}

fn join(buffer: []u8, a: []const u8, b: []const u8) [:0]const u8 {
    return std.mem.printSentinel(buffer, "{s}/{s}", .{ a, b }, 0) catch unreachable;
}

/// Write a file as scxcli does: a scratch file renamed over the name.
fn save(dir: []const u8, name: []const u8, bytes: []const u8) !void {
    var scratch: [512]u8 = undefined;
    var final: [512]u8 = undefined;
    const temp = std.mem.printSentinel(&scratch, "{s}/.{s}.tmp", .{ dir, name }, 0) catch unreachable;
    if (glib.fileSetContents(temp, bytes.ptr, @intCast(bytes.len), null) == 0) return error.WriteFailed;
    if (std.c.rename(temp, join(&final, dir, name)) != 0) return error.RenameFailed;
}

test "a catalog created later in a directory that did not exist is noticed" {
    const root_ptr = glib.Dir.makeTmp("pearl-catalog-watch-XXXXXX", null) orelse return error.SkipZigTest;
    defer glib.free(root_ptr);
    const root = std.mem.span(root_ptr);
    var b1: [512]u8 = undefined;
    var b2: [512]u8 = undefined;
    var b3: [512]u8 = undefined;
    // root/etc exists, root/etc/scx does not: a fresh system.
    const etc = join(&b1, root, "etc");
    try t.expectEqual(@as(c_int, 0), std.c.mkdir(etc, 0o755));
    const scx = join(&b2, etc, "scx");
    const catalog = join(&b3, scx, "catalog.json");
    var counter: Counter = .{};
    var watch: Watch = .{ .context = &counter, .changed = Counter.bump };
    defer watch.stop();
    watch.start(catalog);
    try t.expectEqualStrings(etc, watch.watched());

    // `scxcli catalog save` makes the directory, then the file.
    try t.expectEqual(@as(c_int, 0), std.c.mkdir(scx, 0o755));
    settle(&counter, 1);
    try t.expect(counter.calls >= 1);
    try t.expectEqualStrings(scx, watch.watched());
    const before = counter.calls;
    try save(scx, "catalog.json", "{}");
    settle(&counter, before + 1);
    try t.expect(counter.calls > before);

    // Later saves are noticed too, and other files in the directory are not.
    const again = counter.calls;
    try save(scx, "catalog.json", "{\"version\":2}");
    settle(&counter, again + 1);
    try t.expect(counter.calls > again);
    const quiet = counter.calls;
    try save(scx, "layers.json", "{}");
    settle(&counter, quiet + 1);
    try t.expectEqual(quiet, counter.calls);

    // `catalog reset` and the directory going: the watch moves back up and
    // still sees the directory come back.
    _ = std.c.unlink(catalog);
    var b4: [512]u8 = undefined;
    _ = std.c.unlink(join(&b4, scx, "layers.json"));
    try t.expectEqual(@as(c_int, 0), std.c.rmdir(scx));
    settle(&counter, quiet + 2);
    try t.expectEqualStrings(etc, watch.watched());
    const gone = counter.calls;
    try t.expectEqual(@as(c_int, 0), std.c.mkdir(scx, 0o755));
    settle(&counter, gone + 1);
    try t.expect(counter.calls > gone);
    try t.expectEqualStrings(scx, watch.watched());

    _ = std.c.rmdir(scx);
    _ = std.c.rmdir(etc);
    _ = std.c.rmdir(root_ptr);
}

test "a file whose directory exists from the start is watched there" {
    const root_ptr = glib.Dir.makeTmp("pearl-catalog-watch-XXXXXX", null) orelse return error.SkipZigTest;
    defer glib.free(root_ptr);
    const root = std.mem.span(root_ptr);
    var b1: [512]u8 = undefined;
    const file = join(&b1, root, "catalog.json");
    var counter: Counter = .{};
    var watch: Watch = .{ .context = &counter, .changed = Counter.bump };
    defer watch.stop();
    watch.start(file);
    try t.expectEqualStrings(root, watch.watched());
    try save(root, "catalog.json", "{}");
    settle(&counter, 1);
    try t.expect(counter.calls >= 1);
    _ = std.c.unlink(file);
    _ = std.c.rmdir(root_ptr);
}
