//! Headless Linux tests; run through ../language_approval_tests.zig with -lc.
//! Fork fixtures must run outside an application's worker pool. All writes are
//! confined to private /tmp fixtures; no workspace or real user state is used.
const std = @import("std");
const api = @import("approvals.zig");
const Fixture = @import("../workspace/manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn alarm(seconds: c_uint) c_uint;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
const header = "CORAL-LANGUAGE-APPROVALS 1\n";
const trailer_bytes = 71;
const row_bytes = 67;

fn key(n: u32) api.Key {
    var result: api.Key = @splat(0);
    std.mem.writeInt(u32, result[0..4], n, .little);
    return result;
}

const Harness = struct {
    fixture: Fixture,
    home: api.Home,
    store: [:0]u8,
    dir: [:0]u8,

    fn init() !Harness {
        var f = try Fixture.init();
        errdefer f.deinit();
        try f.mkdir("state");
        try f.mkdir("state/coral");
        try f.mkdir("state/coral/language");
        const state = try f.path("state");
        defer a.free(state);
        var home = try api.Home.init(a, state);
        errdefer home.deinit();
        const store = try f.path("state/coral/language/store");
        errdefer a.free(store);
        return .{ .fixture = f, .home = home, .store = store, .dir = try f.path("state/coral/language") };
    }

    fn deinit(self: *Harness) void {
        for ([_][]const u8{ "store", "pending", "uncertain" }) |name| {
            const p = self.pathName(name) catch unreachable;
            defer a.free(p);
            _ = std.c.unlink(p);
        }
        self.home.deinit();
        a.free(self.store);
        a.free(self.dir);
        self.fixture.deinit();
    }

    fn pathName(self: *const Harness, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.dir, name }, 0);
    }

    fn overwrite(self: *const Harness, bytes: []const u8) !void {
        const fd = std.c.open(self.store, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        try writeAll(fd, bytes);
    }

    fn contents(self: *const Harness) ![]u8 {
        const fd = std.c.open(self.store, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        var bytes: [20000]u8 = undefined;
        var offset: usize = 0;
        while (true) {
            const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try expect(n >= 0);
            if (n == 0) break;
            offset += @intCast(n);
            try expect(offset < bytes.len);
        }
        return a.dupe(u8, bytes[0..offset]);
    }

    fn rejected(self: *const Harness, err: anyerror) !void {
        try expectError(err, api.read(a, &self.home));
        try expectError(err, api.approve(a, &self.home, key(55)));
        try expectError(err, api.setPaused(a, &self.home, key(55), true));
        try expectError(err, api.setPaused(a, &self.home, key(55), false));
    }
};

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Write;
        offset += @intCast(n);
    }
}

fn readAll(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Read;
        offset += @intCast(n);
    }
}

fn chmod(path: [:0]const u8, mode: std.c.mode_t) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.fchmod(fd, mode));
}

fn wait(pid: c_int) !void {
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
    }
    try equal(@as(c_int, 0), status);
}

fn checksum(bytes: []u8) void {
    const end = bytes.len - trailer_bytes;
    var digest: api.Key = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..end], &digest, .{});
    @memcpy(bytes[end..][0..7], "SHA256 ");
    bytes[end + 7 ..][0..64].* = std.fmt.bytesToHex(digest, .lower);
    bytes[bytes.len - 1] = '\n';
}

fn schema(approved: usize, paused: usize) ![]u8 {
    const bytes = try a.alloc(u8, header.len + (approved + paused) * row_bytes + trailer_bytes);
    @memcpy(bytes[0..header.len], header);
    for (0..approved + paused) |i| {
        const offset = header.len + i * row_bytes;
        bytes[offset] = if (i < approved) 'A' else 'P';
        bytes[offset + 1] = ' ';
        bytes[offset + 2 ..][0..64].* = std.fmt.bytesToHex(key(@intCast(i)), .lower);
        bytes[offset + 66] = '\n';
    }
    checksum(bytes);
    return bytes;
}

test "missing is empty and read does not create directories; fresh store is private" {
    var h = try Harness.init();
    defer h.deinit();
    try equal(@as(c_int, 0), std.c.rmdir(h.dir));
    const coral = try h.fixture.path("state/coral");
    defer a.free(coral);
    try equal(@as(c_int, 0), std.c.rmdir(coral));
    const empty = try api.read(a, &h.home);
    try equal(@as(usize, 0), empty.approved_len);
    try equal(@as(usize, 0), empty.paused_len);
    try api.setPaused(a, &h.home, key(1), false);
    try expect(std.c.open(coral, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }) < 0);
    try api.approve(a, &h.home, key(1));
    const snapshot = try api.read(a, &h.home);
    try expect(snapshot.isApproved(key(1)));
    // read validates 0600/0700, owner and nlink on the freshly created objects.
    try expect(!snapshot.isPaused(key(1)));
    const trust = try h.fixture.path("state/coral/trust");
    defer a.free(trust);
    try expect(std.c.open(trust, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }) < 0);
}

test "approval and pause are independent and idempotent; stale snapshots cannot overwrite" {
    var h = try Harness.init();
    defer h.deinit();
    const stale = try api.read(a, &h.home);
    try api.setPaused(a, &h.home, key(1), true);
    var snapshot = try api.read(a, &h.home);
    try expect(snapshot.isPaused(key(1)));
    try expect(!snapshot.isApproved(key(1)));
    try api.approve(a, &h.home, key(1));
    try api.approve(a, &h.home, key(1));
    try api.approve(a, &h.home, key(2));
    try api.setPaused(a, &h.home, key(2), true);
    try api.setPaused(a, &h.home, key(2), true);
    try api.setPaused(a, &h.home, key(1), false);
    try api.setPaused(a, &h.home, key(1), false);
    snapshot = try api.read(a, &h.home);
    try equal(@as(usize, 2), snapshot.approved_len);
    try equal(@as(usize, 1), snapshot.paused_len);
    try expect(snapshot.isApproved(key(1)) and snapshot.isApproved(key(2)));
    try expect(!snapshot.isPaused(key(1)) and snapshot.isPaused(key(2)));
    try expect(!stale.isApproved(key(1)) and !stale.isPaused(key(2)));
    var reopened = try api.Home.init(a, h.home.path);
    defer reopened.deinit();
    try equal(snapshot, try api.read(a, &reopened));
}

test "both 128-key capacities reject overflow without eviction or unrelated changes" {
    var h = try Harness.init();
    defer h.deinit();
    for (0..128) |i| {
        try api.approve(a, &h.home, key(@intCast(i)));
        try api.setPaused(a, &h.home, key(@intCast(i)), true);
    }
    const before = try h.contents();
    defer a.free(before);
    try expectError(error.StoreFull, api.approve(a, &h.home, key(128)));
    try expectError(error.StoreFull, api.setPaused(a, &h.home, key(128), true));
    const after = try h.contents();
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try api.approve(a, &h.home, key(0));
    try api.setPaused(a, &h.home, key(0), true);
    try api.setPaused(a, &h.home, key(0), false);
    try api.setPaused(a, &h.home, key(128), true);
    const snapshot = try api.read(a, &h.home);
    try equal(@as(usize, 128), snapshot.approved_len);
    try equal(@as(usize, 128), snapshot.paused_len);
    for (0..128) |i| try expect(snapshot.isApproved(key(@intCast(i))));
    for (1..129) |i| try expect(snapshot.isPaused(key(@intCast(i))));
    try expect(!snapshot.isPaused(key(0)));
}

test "corrupt empty truncated checksum version and trailing bytes fail closed and remain intact" {
    var h = try Harness.init();
    defer h.deinit();
    const valid = try schema(1, 1);
    defer a.free(valid);
    for ([_][]const u8{ "", "{\"approved\":true}", valid[0 .. valid.len - 1], valid[0..header.len] }) |bytes| {
        try h.overwrite(bytes);
        try h.rejected(error.CorruptStore);
        const after = try h.contents();
        defer a.free(after);
        try std.testing.expectEqualSlices(u8, bytes, after);
    }
    valid[header.len + 2] ^= 1;
    try h.overwrite(valid);
    try h.rejected(error.CorruptStore);
    valid[header.len + 2] ^= 1;
    valid[header.len - 2] = '2';
    checksum(valid);
    try h.overwrite(valid);
    try h.rejected(error.CorruptStore);
    const appended = try std.mem.concat(a, u8, &.{ valid, "\n" });
    defer a.free(appended);
    try h.overwrite(appended);
    try h.rejected(error.CorruptStore);
}

test "valid checksums cannot disguise duplicate nonhex path domain ordering or over-cap records" {
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try schema(2, 1);
    defer a.free(bytes);
    for (0..7) |case| {
        const changed = try a.dupe(u8, bytes);
        defer a.free(changed);
        switch (case) {
            0 => @memcpy(changed[header.len + row_bytes ..][0..row_bytes], changed[header.len..][0..row_bytes]),
            1 => changed[header.len + 2] = 'G',
            2 => changed[header.len + 2] = '/',
            3 => changed[header.len] = 'X',
            4 => changed[header.len] = 'P',
            5 => changed[header.len + 1] = '\t',
            6 => changed[header.len + 66] = 0,
            else => unreachable,
        }
        checksum(changed);
        try h.overwrite(changed);
        try h.rejected(error.CorruptStore);
    }
    for ([_][2]usize{ .{ 129, 0 }, .{ 0, 129 } }) |counts| {
        const overflow = try schema(counts[0], counts[1]);
        defer a.free(overflow);
        try h.overwrite(overflow);
        try h.rejected(error.CorruptStore);
    }
    const huge = try a.alloc(u8, 18000);
    defer a.free(huge);
    @memset(huge, 'x');
    try h.overwrite(huge);
    try h.rejected(error.TooLarge);
}

test "unsafe file modes hardlinks symlinks FIFOs and directories reject without blocking" {
    var h = try Harness.init();
    defer h.deinit();
    try api.approve(a, &h.home, key(1));
    for ([_]std.c.mode_t{ 0o644, 0o660, 0o400, 0o1600, 0o700 }) |mode| {
        try chmod(h.store, mode);
        try h.rejected(error.UnsafeFile);
        try chmod(h.store, 0o600);
    }
    const alias = try h.fixture.path("hardlink");
    defer a.free(alias);
    try equal(@as(c_int, 0), std.c.link(h.store, alias));
    try h.rejected(error.UnsafeFile);
    try equal(@as(c_int, 0), std.c.unlink(alias));
    try h.fixture.write("outside", "untouched");
    const outside = try h.fixture.path("outside");
    defer a.free(outside);
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.symlink(outside, h.store));
    try h.rejected(error.UnsafeFile);
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.symlink("absent-target", h.store));
    try h.rejected(error.UnsafeFile);
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), mkfifo(h.store, 0o600));
    try h.rejected(error.UnsafeFile);
    try equal(@as(c_int, 0), std.c.unlink(h.store));
    try equal(@as(c_int, 0), std.c.mkdir(h.store, 0o700));
    try h.rejected(error.UnsafeFile);
    try equal(@as(c_int, 0), std.c.rmdir(h.store));
    const fd = std.c.open(outside, .{ .ACCMODE = .RDONLY });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    var content: [9]u8 = undefined;
    try readAll(fd, &content);
    try std.testing.expectEqualStrings("untouched", &content);
}

test "state directory ownership modes and every symlink component are checked" {
    var h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{ "state", "state/coral", "state/coral/language" }) |name| {
        const path = try h.fixture.path(name);
        defer a.free(path);
        try chmod(path, 0o777);
        try h.rejected(error.UnsafeDirectory);
        try chmod(path, 0o700);
        const retired = try h.fixture.path("retired");
        defer a.free(retired);
        try equal(@as(c_int, 0), std.c.rename(path, retired));
        try equal(@as(c_int, 0), std.c.symlink(retired, path));
        try h.rejected(error.UnsafeDirectory);
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), std.c.rename(retired, path));
    }
    try chmod(h.fixture.base, 0o777);
    try h.rejected(error.UnsafeDirectory);
    try chmod(h.fixture.base, 0o700);
    for ([_][]const u8{ "state/coral", "state/coral/language" }) |name| {
        const path = try h.fixture.path(name);
        defer a.free(path);
        try chmod(path, 0o755);
        try h.rejected(error.UnsafeDirectory);
        try chmod(path, 0o700);
    }
}

test "missing state home and invalid absolute paths are errors, never empty success" {
    var h = try Harness.init();
    defer h.deinit();
    const missing = try h.fixture.path("missing");
    defer a.free(missing);
    var home = try api.Home.init(a, missing);
    defer home.deinit();
    try expectError(error.MissingStateHome, api.read(a, &home));
    try expectError(error.MissingStateHome, api.approve(a, &home, key(1)));
    for ([_][]const u8{ "", "relative", "/tmp/../state", "/tmp/./state", "/tmp//state", "/tmp/state/", "/tmp/nul\x00tail" }) |path| {
        try expectError(error.InvalidPath, api.Home.init(a, path));
        const forged: api.Home = .{ .allocator = a, .path = path };
        try expectError(error.InvalidPath, api.read(a, &forged));
    }
}

test "durability marker of any type fails closed even without a store" {
    var h = try Harness.init();
    defer h.deinit();
    const marker = try h.pathName("uncertain");
    defer a.free(marker);
    for (0..4) |kind| {
        switch (kind) {
            0 => {
                const fd = std.c.open(marker, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
                try expect(fd >= 0);
                _ = std.c.close(fd);
            },
            1 => try equal(@as(c_int, 0), std.c.symlink("missing", marker)),
            2 => try equal(@as(c_int, 0), mkfifo(marker, 0o600)),
            3 => try equal(@as(c_int, 0), std.c.mkdir(marker, 0o700)),
            else => unreachable,
        }
        try h.rejected(error.DurabilityUncertain);
        try equal(@as(c_int, 0), if (kind == 3) std.c.rmdir(marker) else std.c.unlink(marker));
    }
    try api.approve(a, &h.home, key(1));
    try equal(@as(c_int, 0), std.c.symlink("missing", marker));
    try h.rejected(error.DurabilityUncertain);
}

test "abandoned pending is never promoted and pending symlink targets are untouched" {
    var h = try Harness.init();
    defer h.deinit();
    const bytes = try schema(1, 0);
    defer a.free(bytes);
    try h.fixture.write("outside", bytes);
    const outside = try h.fixture.path("outside");
    defer a.free(outside);
    const pending = try h.pathName("pending");
    defer a.free(pending);
    try equal(@as(c_int, 0), std.c.symlink(outside, pending));
    try expect(!(try api.read(a, &h.home)).isApproved(key(0)));
    try api.approve(a, &h.home, key(1));
    const snapshot = try api.read(a, &h.home);
    try expect(snapshot.isApproved(key(1)) and !snapshot.isApproved(key(0)));
    const fd = std.c.open(outside, .{ .ACCMODE = .RDONLY });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    const content = try a.alloc(u8, bytes.len);
    defer a.free(content);
    try readAll(fd, content);
    try std.testing.expectEqualSlices(u8, bytes, content);
}

test "process exit leaves old state before publication and fails closed throughout uncertain publication" {
    // Construct the protocol's restart images without exposing production fault
    // hooks. _exit deliberately skips close, unlock and temporary-file cleanup.
    for (0..4) |stage| {
        var h = try Harness.init();
        defer h.deinit();
        try api.approve(a, &h.home, key(1));
        try api.setPaused(a, &h.home, key(1), true);
        const next = try schema(2, 0);
        defer a.free(next);
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(5);
            const dir = std.c.open(h.dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
            if (dir < 0 or std.c.flock(dir, std.c.LOCK.EX | std.c.LOCK.NB) != 0) std.c._exit(1);
            const pending = std.c.openat(dir, "pending", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
            if (pending < 0) std.c._exit(2);
            writeAll(pending, if (stage == 0) next[0 .. next.len / 2] else next) catch std.c._exit(3);
            if (stage == 0) std.c._exit(0);
            if (std.c.fsync(pending) != 0) std.c._exit(4);
            const marker = std.c.openat(dir, "uncertain", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
            if (marker < 0 or std.c.fsync(marker) != 0 or std.c.fsync(dir) != 0) std.c._exit(5);
            if (stage == 1) std.c._exit(0);
            if (std.c.renameat(dir, "pending", dir, "store") != 0) std.c._exit(6);
            if (stage == 2) std.c._exit(0);
            if (std.c.fsync(dir) != 0) std.c._exit(7);
            std.c._exit(0);
        }
        try wait(pid);
        if (stage != 0) {
            try h.rejected(error.DurabilityUncertain);
        } else {
            const old = try api.read(a, &h.home);
            try expect(old.isApproved(key(1)) and old.isPaused(key(1)));
            try expect(!old.isApproved(key(0)));
            try api.approve(a, &h.home, key(9));
            const merged = try api.read(a, &h.home);
            try expect(merged.isApproved(key(1)) and merged.isApproved(key(9)) and merged.isPaused(key(1)));
            try expect(!merged.isApproved(key(0)));
        }
    }
}

test "cross-process shared and exclusive locks are nonblocking and survive store rename" {
    var h = try Harness.init();
    defer h.deinit();
    try api.approve(a, &h.home, key(1));
    const fd = std.c.open(h.dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    for ([_]c_int{ std.c.LOCK.EX, std.c.LOCK.SH }) |kind| {
        try equal(@as(c_int, 0), std.c.flock(fd, kind | std.c.LOCK.NB));
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(5);
            _ = std.c.close(fd);
            if (kind == std.c.LOCK.EX) {
                expectError(error.Busy, api.read(a, &h.home)) catch std.c._exit(1);
            } else {
                _ = api.read(a, &h.home) catch std.c._exit(2);
            }
            expectError(error.Busy, api.approve(a, &h.home, key(2))) catch std.c._exit(3);
            expectError(error.Busy, api.setPaused(a, &h.home, key(2), true)) catch std.c._exit(4);
            expectError(error.Busy, api.setPaused(a, &h.home, key(2), false)) catch std.c._exit(5);
            std.c._exit(0);
        }
        try wait(pid);
        try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.UN));
        try api.approve(a, &h.home, key(3)); // publishes a new store inode
    }
}

fn retryApprove(home: *const api.Home, k: api.Key) !void {
    for (0..2000) |_| {
        api.approve(a, home, k) catch |err| {
            if (err != error.Busy) return err;
            _ = usleep(1000);
            continue;
        };
        return;
    }
    return error.RetryLimit;
}

fn retryPause(home: *const api.Home, k: api.Key, paused: bool) !void {
    for (0..2000) |_| {
        api.setPaused(a, home, k, paused) catch |err| {
            if (err != error.Busy) return err;
            _ = usleep(1000);
            continue;
        };
        return;
    }
    return error.RetryLimit;
}

test "simultaneous process grants pauses and unpauses merge latest state, not stale reads" {
    var h = try Harness.init();
    defer h.deinit();
    try api.setPaused(a, &h.home, key(0), true);
    var ready: [2]c_int = undefined;
    var go: [2]c_int = undefined;
    try equal(@as(c_int, 0), std.c.pipe(&ready));
    defer {
        _ = std.c.close(ready[0]);
        _ = std.c.close(ready[1]);
    }
    try equal(@as(c_int, 0), std.c.pipe(&go));
    defer {
        _ = std.c.close(go[0]);
        _ = std.c.close(go[1]);
    }
    var pids: [6]c_int = undefined;
    var count: usize = 0;
    var reaped: usize = 0;
    defer for (pids[reaped..count]) |pid| {
        wait(pid) catch {};
    };
    for (&pids, 0..) |*slot, i| {
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(15);
            _ = std.c.close(ready[0]);
            _ = std.c.close(go[1]);
            const stale = api.read(a, &h.home) catch std.c._exit(1);
            if (!stale.isPaused(key(0)) or stale.isApproved(key(999))) std.c._exit(2);
            writeAll(ready[1], "r") catch std.c._exit(3);
            var token: [1]u8 = undefined;
            readAll(go[0], &token) catch std.c._exit(4);
            const k = key(@intCast(i + 1));
            retryApprove(&h.home, k) catch std.c._exit(5);
            retryPause(&h.home, k, true) catch std.c._exit(6);
            retryPause(&h.home, key(0), false) catch std.c._exit(7);
            std.c._exit(0);
        }
        slot.* = pid;
        count += 1;
    }
    // Do not keep an artificial writer alive if a child fails before readiness.
    _ = std.c.close(ready[1]);
    ready[1] = -1;
    _ = std.c.close(go[0]);
    go[0] = -1;
    var tokens: [6]u8 = undefined;
    try readAll(ready[0], &tokens);
    try api.approve(a, &h.home, key(999));
    try api.setPaused(a, &h.home, key(999), true);
    try writeAll(go[1], "gggggg");
    for (pids) |pid| {
        // Count even a failed child's wait so cleanup never waits twice.
        reaped += 1;
        try wait(pid);
    }
    const snapshot = try api.read(a, &h.home);
    try equal(@as(usize, 7), snapshot.approved_len);
    try equal(@as(usize, 7), snapshot.paused_len);
    for (1..7) |i| {
        try expect(snapshot.isApproved(key(@intCast(i))));
        try expect(snapshot.isPaused(key(@intCast(i))));
    }
    try expect(snapshot.isApproved(key(999)) and snapshot.isPaused(key(999)));
    try expect(!snapshot.isPaused(key(0)));
}

test "normal HOME fallback store works with cwd HOME or root outside configured workspace" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir(".local");
    try f.mkdir(".local/state");
    try f.mkdir(".local/state/coral");
    try f.mkdir(".local/state/coral/language");
    try f.mkdir("project");
    const project = try f.path("project");
    defer a.free(project);
    const store = try f.path(".local/state/coral/language/store");
    defer a.free(store);
    defer _ = std.c.unlink(store);
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(5);
        if (setenv("HOME", f.base, 1) != 0 or unsetenv("XDG_STATE_HOME") != 0) std.c._exit(1);
        var home = api.Home.init(a, null) catch std.c._exit(2);
        for ([_][:0]const u8{ f.base, "/" }, 0..) |cwd, i| {
            if (std.c.chdir(cwd) != 0) std.c._exit(3);
            api.validateLocation(&home, &.{project}, null) catch std.c._exit(4);
            _ = api.read(a, &home) catch std.c._exit(5);
            const k = key(@intCast(i + 1));
            api.approve(a, &home, k) catch std.c._exit(6);
            api.setPaused(a, &home, k, true) catch std.c._exit(7);
            const paused = api.read(a, &home) catch std.c._exit(8);
            if (!paused.isApproved(k) or !paused.isPaused(k)) std.c._exit(9);
            api.setPaused(a, &home, k, false) catch std.c._exit(10);
            const resumed = api.read(a, &home) catch std.c._exit(11);
            if (!resumed.isApproved(k) or resumed.isPaused(k)) std.c._exit(12);
        }
        home.deinit();
        std.c._exit(0);
    }
    try wait(pid);
}

test "pure location guard rejects actual roots and manifest base containing language target" {
    var h = try Harness.init();
    defer h.deinit();
    const coral = try h.fixture.path("state/coral");
    defer a.free(coral);
    const other = try h.fixture.path("unrelated-project");
    defer a.free(other);
    // Includes state-home ancestors, the state home itself, and the actual
    // language directory: coral/trust's sibling check cannot cover the last one.
    for ([_][]const u8{ "/", h.fixture.base, h.home.path, coral, h.dir }) |root| {
        try expectError(error.StateInsideWorkspace, api.validateLocation(&h.home, &.{ other, root }, null));
        try expectError(error.StateInsideWorkspace, api.validateLocation(&h.home, &.{other}, root));
    }
    const sibling = try std.fmt.allocPrint(a, "{s}-other", .{h.dir});
    defer a.free(sibling);
    const nested = try std.fmt.allocPrint(a, "{s}/project", .{h.dir});
    defer a.free(nested);
    const trust = try h.fixture.path("state/coral/trust");
    defer a.free(trust);
    try api.validateLocation(&h.home, &.{ sibling, nested, trust }, other);
    try api.validateLocation(&h.home, &.{}, null);
    // Nonexistent configured paths above were checked without filesystem I/O;
    // neither a successful nor rejected pure check creates the store.
    try expect(std.c.open(h.store, .{ .ACCMODE = .RDONLY }) < 0);
    var root_home = try api.Home.init(a, "/");
    defer root_home.deinit();
    try expectError(error.StateInsideWorkspace, api.validateLocation(&root_home, &.{"/coral/language"}, null));
    try api.validateLocation(&root_home, &.{"/coral/language-other"}, null);
}

test "location guard rejects noncanonical input rather than normalizing aliases" {
    var h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{ "", "relative", "/tmp/../state", "/tmp/./state", "/tmp//state", "/tmp/state/", "/tmp/nul\x00tail" }) |path| {
        try expectError(error.InvalidPath, api.validateLocation(&h.home, &.{path}, null));
        try expectError(error.InvalidPath, api.validateLocation(&h.home, &.{}, path));
        const forged: api.Home = .{ .allocator = a, .path = path };
        try expectError(error.InvalidPath, api.validateLocation(&forged, &.{}, null));
    }
}

test "Home snapshots user environment once and uses only absolute XDG or HOME fallback" {
    var h = try Harness.init();
    defer h.deinit();
    const state = try h.fixture.path("state");
    defer a.free(state);
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(5);
        if (setenv("XDG_STATE_HOME", state, 1) != 0) std.c._exit(1);
        var captured = api.Home.init(a, null) catch std.c._exit(2);
        if (setenv("XDG_STATE_HOME", "relative", 1) != 0) std.c._exit(3);
        expectError(error.InvalidPath, api.Home.init(a, null)) catch std.c._exit(4);
        api.approve(a, &captured, key(9)) catch std.c._exit(5);
        captured.deinit();
        if (setenv("XDG_STATE_HOME", "", 1) != 0 or setenv("HOME", h.fixture.base, 1) != 0) std.c._exit(6);
        var fallback = api.Home.init(a, null) catch std.c._exit(7);
        const expected = std.fmt.allocPrint(a, "{s}/.local/state", .{h.fixture.base}) catch std.c._exit(8);
        if (!std.mem.eql(u8, fallback.path, expected)) std.c._exit(9);
        a.free(expected);
        fallback.deinit();
        if (unsetenv("XDG_STATE_HOME") != 0 or unsetenv("HOME") != 0) std.c._exit(10);
        expectError(error.MissingStateHome, api.Home.init(a, null)) catch std.c._exit(11);
        std.c._exit(0);
    }
    try wait(pid);
    try expect((try api.read(a, &h.home)).isApproved(key(9)));
}

test "allocation failure never resets or overwrites existing state" {
    var h = try Harness.init();
    defer h.deinit();
    try api.approve(a, &h.home, key(1));
    var buffer: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    try expectError(error.OutOfMemory, api.read(fixed.allocator(), &h.home));
    try expectError(error.OutOfMemory, api.approve(fixed.allocator(), &h.home, key(2)));
    try expectError(error.OutOfMemory, api.setPaused(fixed.allocator(), &h.home, key(1), true));
    // Enough memory to load the old store, but not to encode the merged one.
    const encoded = try h.contents();
    defer a.free(encoded);
    var encode_limited = std.heap.FixedBufferAllocator.init(encoded);
    try expectError(error.OutOfMemory, api.approve(encode_limited.allocator(), &h.home, key(2)));
    const snapshot = try api.read(a, &h.home);
    try expect(snapshot.isApproved(key(1)) and !snapshot.isApproved(key(2)));
    try expect(!snapshot.isPaused(key(1)));
}
