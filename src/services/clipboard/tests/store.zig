const std = @import("std");
const t = std.testing;
const storage = @import("../store.zig");
const codec = @import("../codec.zig");
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

const first: codec.Snapshot = .{ .records = &.{.{ .bytes = "synthetic first", .last_copy = 10, .sequence = 1 }}, .floor = 20 };
const second: codec.Snapshot = .{ .records = &.{.{ .bytes = "synthetic replacement", .last_copy = 30, .sequence = 2 }}, .floor = 40 };
const orphan = "history.tmp.0123456789abcdef0123456789abcdef";

const Fixture = struct {
    root: [:0]u8,
    path: [:0]u8,
    fn init() !Fixture {
        const root = try t.allocator.dupeSentinel(u8, "/tmp/pearl-history-test-XXXXXX", 0);
        errdefer t.allocator.free(root);
        if (mkdtemp(root) == null) return error.TestDirectory;
        errdefer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
        return .{ .root = root, .path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl/clipboard", .{root}, 0) };
    }
    fn deinit(self: *Fixture) void {
        std.Io.Dir.cwd().deleteTree(t.io, self.root) catch @panic("temporary test directory cleanup failed");
        t.allocator.free(self.path);
        t.allocator.free(self.root);
    }
    fn open(self: *const Fixture) !storage.Store {
        return storage.Store.open(t.allocator, self.path);
    }
};

fn writeLeaf(dir: c_int, name: [:0]const u8, bytes: []const u8, mode: c_uint) !void {
    const fd = std.c.openat(dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, mode);
    if (fd < 0) return error.TestFile;
    defer _ = std.c.close(fd);
    if (std.c.fchmod(fd, mode) != 0) return error.TestFile;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.TestFile;
        offset += @intCast(n);
    }
}

fn readLeaf(dir: c_int, name: [:0]const u8) ![]u8 {
    const fd = std.c.openat(dir, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.TestFile;
    defer _ = std.c.close(fd);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(t.allocator);
    var bytes: [512]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &bytes, bytes.len);
        if (n < 0) return error.TestFile;
        if (n == 0) break;
        try result.appendSlice(t.allocator, bytes[0..@intCast(n)]);
    }
    return result.toOwnedSlice(t.allocator);
}

fn expectLoaded(store: *storage.Store, expected: codec.Snapshot) !void {
    var loaded = (try store.read()).?;
    defer loaded.deinit();
    try t.expectEqual(expected.floor, loaded.floor);
    for (expected.records, loaded.snapshot().records) |a, b| {
        try t.expectEqualStrings(a.bytes, b.bytes);
        try t.expectEqual(a.last_copy, b.last_copy);
        try t.expectEqual(a.sequence, b.sequence);
    }
}

test "store resolves XDG and HOME paths without consulting the real environment" {
    const xdg = try storage.resolveDirectory(t.allocator, "/private/state/./", "/ignored");
    defer t.allocator.free(xdg);
    try t.expectEqualStrings("/private/state/pearl/clipboard", xdg);
    for ([_]?[]const u8{ null, "", "relative" }) |value| {
        const home = try storage.resolveDirectory(t.allocator, value, "/private/home");
        defer t.allocator.free(home);
        try t.expectEqualStrings("/private/home/.local/state/pearl/clipboard", home);
    }
    for ([_][]const u8{ "/bad/../state", "/bad//state", "/bad\x00state" }) |bad| {
        try t.expectError(error.InvalidPath, storage.resolveDirectory(t.allocator, bad, "/valid/home"));
    }
    try t.expectError(error.InvalidPath, storage.resolveDirectory(t.allocator, null, "relative"));
}

test "store first startup missing first save and restart-style reload" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var store = try fixture.open();
        defer store.close();
        try t.expect((try store.read()) == null);
        try t.expectEqual(storage.State.missing, store.state);
        try store.write(first);
    }
    var reopened = try fixture.open();
    defer reopened.close();
    try expectLoaded(&reopened, first);
}

test "store replaces a complete snapshot and persists individual deletion projection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    try store.write(second);
    try expectLoaded(&store, second);
}

test "store empty snapshot and explicit remove durably remove the saved file" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    try store.write(.{ .records = &.{}, .floor = 20 });
    try t.expect((try store.read()) == null);
    try store.write(second);
    try store.remove();
    try store.remove();
    try t.expect((try store.read()) == null);
}

test "store establishes exact private directory file and stable lock permissions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var st: std.os.linux.Statx = undefined;
    try t.expectEqual(@as(usize, 0), std.os.linux.statx(store.directoryFd(), "", std.os.linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &st));
    try t.expectEqual(@as(u16, 0o700), st.mode & 0o7777);
    try t.expectEqual(std.c.getuid(), st.uid);
    try t.expectEqual(@as(usize, 0), std.os.linux.statx(store.directoryFd(), "history.bin", 0, .{ .MODE = true }, &st));
    try t.expectEqual(@as(u16, 0o600), st.mode & 0o7777);
    try store.remove();
    try t.expectEqual(@as(usize, 0), std.os.linux.statx(store.directoryFd(), "writer.lock", 0, .{ .MODE = true, .NLINK = true }, &st));
    try t.expectEqual(@as(u16, 0o600), st.mode & 0o7777);
    try t.expectEqual(@as(u32, 1), st.nlink);
}

test "store rejects unsafe existing directory permissions without repairing them" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var store = try fixture.open();
        defer store.close();
        try t.expectEqual(@as(c_int, 0), std.c.fchmod(store.directoryFd(), 0o755));
    }
    try t.expectError(error.Unsafe, fixture.open());
}

test "store rejects file permissions hard links and symlinks" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    const dir = store.directoryFd();
    try writeLeaf(dir, "history.bin", "synthetic", 0o644);
    try t.expectError(error.Unsafe, store.read());
    try t.expectError(error.Unsafe, store.remove());
    try t.expectEqual(@as(c_int, 0), std.c.unlinkat(dir, "history.bin", 0));
    try writeLeaf(dir, "history.bin", "synthetic", 0o600);
    try t.expectEqual(@as(c_int, 0), std.c.linkat(dir, "history.bin", dir, "other-link", 0));
    try t.expectError(error.Unsafe, store.read());
    try t.expectError(error.Unsafe, store.remove());
    try t.expectEqual(@as(c_int, 0), std.c.unlinkat(dir, "history.bin", 0));
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("other-link", dir, "history.bin"));
    try t.expectError(error.Unsafe, store.read());
    try t.expectError(error.Unsafe, store.remove());
}

test "store rejects a symlink in any directory component" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const link = try std.fmt.allocPrintSentinel(t.allocator, "{s}/redirect", .{fixture.root}, 0);
    defer t.allocator.free(link);
    try t.expectEqual(@as(c_int, 0), std.c.symlink(fixture.root, link));
    const path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl/clipboard", .{link}, 0);
    defer t.allocator.free(path);
    try t.expectError(error.Unsafe, storage.Store.open(t.allocator, path));
}

test "store concurrent writer is rejected until the first writer closes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var store = try fixture.open();
        defer store.close();
        try t.expectError(error.Busy, fixture.open());
    }
    var reopened = try fixture.open();
    defer reopened.close();
}

test "store corrupted history is preserved and cannot be overwritten automatically" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    const dir = store.directoryFd();
    try writeLeaf(dir, "history.bin", "synthetic corrupted saved data", 0o600);
    try t.expectError(error.Corrupt, store.read());
    try t.expectEqual(storage.State.corrupt, store.state);
    try t.expectError(error.Corrupt, store.write(first));
    const bytes = try readLeaf(dir, "history.bin");
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("synthetic corrupted saved data", bytes);
    try store.remove();
    try t.expect((try store.read()) == null);
}

test "store corrupt Clear refuses changed permissions symlinks and replacement history" {
    for (0..3) |variant| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var store = try fixture.open();
        defer store.close();
        const dir = store.directoryFd();
        try writeLeaf(dir, "history.bin", "synthetic rejected history", 0o600);
        try writeLeaf(dir, "unrelated", "synthetic unrelated text", 0o600);
        try t.expectError(error.Corrupt, store.read());
        if (variant == 0) {
            try writeLeaf(dir, "history.bin", "synthetic rejected history", 0o644);
        } else {
            try t.expectEqual(@as(c_int, 0), std.c.unlinkat(dir, "history.bin", 0));
            if (variant == 1) {
                try t.expectEqual(@as(c_int, 0), std.c.symlinkat("unrelated", dir, "history.bin"));
            } else try writeLeaf(dir, "history.bin", "synthetic replacement history", 0o600);
        }
        try t.expectError(if (variant == 2) error.Conflict else error.Unsafe, store.remove());
        var st: std.os.linux.Statx = undefined;
        try t.expectEqual(std.posix.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(dir, "history.bin", std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)));
        if (variant == 1) try t.expectEqual(@as(u16, std.c.S.IFLNK), st.mode & std.c.S.IFMT);
        const bytes = try readLeaf(dir, if (variant == 1) "unrelated" else "history.bin");
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(if (variant == 0) "synthetic rejected history" else if (variant == 1) "synthetic unrelated text" else "synthetic replacement history", bytes);
    }
}

test "store unsupported saved version is preserved" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try writeLeaf(store.directoryFd(), "history.bin", "PEARLCH\x00\x02\x00", 0o600);
    try t.expectError(error.Unsupported, store.read());
    try t.expectError(error.Unsupported, store.write(first));
    const bytes = try readLeaf(store.directoryFd(), "history.bin");
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("PEARLCH\x00\x02\x00", bytes);
}

test "store never restores an interrupted temporary snapshot and clear removes owned temps" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try writeLeaf(store.directoryFd(), orphan, "synthetic incomplete temporary", 0o600);
    try t.expect((try store.read()) == null);
    try store.write(first);
    try expectLoaded(&store, first);
    try store.remove();
    var st: std.os.linux.Statx = undefined;
    try t.expect(std.os.linux.statx(store.directoryFd(), orphan, 0, .{ .TYPE = true }, &st) != 0);
}

test "store nonempty removal cleans orphan plaintext and preserves unrelated files" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    _ = try store.read();
    try store.write(first);
    const dir = store.directoryFd();
    const another = "history.tmp.fedcba9876543210fedcba9876543210";
    try writeLeaf(dir, orphan, "synthetic deleted plaintext", 0o600);
    try writeLeaf(dir, another, "synthetic older plaintext", 0o600);
    try writeLeaf(dir, "unrelated", "keep unrelated", 0o600);
    try writeLeaf(dir, "history.tmp.invalid", "keep invalid temp name", 0o600);
    try store.writeRemoval(second);
    try expectLoaded(&store, second);
    for ([_][:0]const u8{ orphan, another }) |name| {
        var st: std.os.linux.Statx = undefined;
        try t.expectEqual(std.posix.E.NOENT, std.os.linux.errno(std.os.linux.statx(dir, name, 0, .{ .TYPE = true }, &st)));
    }
    for ([_][:0]const u8{ "unrelated", "history.tmp.invalid" }, [_][]const u8{ "keep unrelated", "keep invalid temp name" }) |name, expected| {
        const bytes = try readLeaf(dir, name);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
}

const Failure = struct {
    phase: storage.Phase,
    calls: usize = 0,
    pass: usize = 0,
    fn check(context: ?*anyopaque, phase: storage.Phase) error{InjectedFailure}!void {
        const self: *Failure = @ptrCast(@alignCast(context.?));
        if (phase == self.phase) {
            self.calls += 1;
            if (self.calls <= self.pass) return;
            return error.InjectedFailure;
        }
    }
    fn hooks(self: *Failure) storage.Hooks {
        return .{ .context = self, .before = check };
    }
};

test "store injected write sync and publication failures preserve the previous snapshot" {
    for ([_]storage.Phase{ .write, .file_sync, .publish }) |phase| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var store = try fixture.open();
        defer store.close();
        try t.expect((try store.read()) == null);
        try store.write(first);
        var failure: Failure = .{ .phase = phase };
        store.hooks = failure.hooks();
        const expected = switch (phase) {
            .write => error.WriteFailed,
            .file_sync => error.SyncFailed,
            else => error.PublishFailed,
        };
        try t.expectError(expected, store.write(second));
        try t.expectEqual(@as(usize, 1), failure.calls);
        store.hooks = .{};
        try expectLoaded(&store, first);
    }
}

test "store post-publication sync failure is uncertain and fences subsequent writes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var failure: Failure = .{ .phase = .directory_sync };
    store.hooks = failure.hooks();
    try t.expectError(error.Uncertain, store.write(second));
    try t.expectEqual(storage.State.uncertain, store.state);
    store.hooks = .{};
    try t.expectError(error.NeedsLoad, store.write(first));
    try expectLoaded(&store, second);
}

test "store never reports durable removal when directory sync fails even if missing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var failure: Failure = .{ .phase = .directory_sync };
    store.hooks = failure.hooks();
    try t.expectError(error.Uncertain, store.remove());
    try t.expectError(error.SyncFailed, store.remove());
    store.hooks = .{};
    try store.remove();
    try t.expect((try store.read()) == null);
}

test "store refuses blind writes before validated load and detects external replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expectError(error.NeedsLoad, store.write(first));
    try t.expect((try store.read()) == null);
    try writeLeaf(store.directoryFd(), "history.bin", "unexpected", 0o600);
    try t.expectError(error.Conflict, store.write(first));
    const bytes = try readLeaf(store.directoryFd(), "history.bin");
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("unexpected", bytes);
}

test "store restrictive process umask still creates exact private objects" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const previous = std.c.umask(0o777);
    defer _ = std.c.umask(previous);
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    try expectLoaded(&store, first);
}

test "store independent file lock rejects another cooperating writer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var store = try fixture.open();
        store.close();
    }
    const dir = std.c.open(fixture.path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    try t.expect(dir >= 0);
    defer _ = std.c.close(dir);
    const file = std.c.openat(dir, "writer.lock", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(c_uint, 0));
    try t.expect(file >= 0);
    defer _ = std.c.close(file);
    try t.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.flock(file, 2 | 4)));
    try t.expectError(error.Busy, fixture.open());
}

test "store validates an existing lock inode permissions and links" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    {
        var store = try fixture.open();
        store.close();
    }
    const dir = std.c.open(fixture.path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    try t.expect(dir >= 0);
    defer _ = std.c.close(dir);
    try writeLeaf(dir, "writer.lock", "", 0o644);
    try t.expectError(error.Unsafe, fixture.open());
    try writeLeaf(dir, "writer.lock", "", 0o600);
    try t.expectEqual(@as(c_int, 0), std.c.linkat(dir, "writer.lock", dir, "extra-lock-link", 0));
    try t.expectError(error.Unsafe, fixture.open());
    try t.expectEqual(@as(c_int, 0), std.c.unlinkat(dir, "writer.lock", 0));
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("extra-lock-link", dir, "writer.lock"));
    try t.expectError(error.Unsafe, fixture.open());
}

test "store partial temporary write failure cleans up and preserves authoritative data" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var failure: Failure = .{ .phase = .write, .pass = 1 };
    store.hooks = failure.hooks();
    try t.expectError(error.WriteFailed, store.write(second));
    try t.expectEqual(@as(usize, 2), failure.calls);
    try t.expect(!store.cleanup_failed);
    store.hooks = .{};
    try expectLoaded(&store, first);
}

test "store failed unlink preserves saved data and post-unlink failure is uncertain" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var failure: Failure = .{ .phase = .remove };
    store.hooks = failure.hooks();
    try t.expectError(error.RemoveFailed, store.remove());
    store.hooks = .{};
    try expectLoaded(&store, first);
    failure = .{ .phase = .after_remove };
    store.hooks = failure.hooks();
    try t.expectError(error.Uncertain, store.remove());
    store.hooks = .{};
    try t.expect((try store.read()) == null);
}

test "store clear preserves unrelated files and refuses unsafe exact-pattern temporaries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    const dir = store.directoryFd();
    try writeLeaf(dir, "unrelated", "preserve unrelated", 0o600);
    try writeLeaf(dir, "history.tmp.invalid", "preserve unrelated temp name", 0o600);
    try writeLeaf(dir, orphan, "unsafe temporary", 0o644);
    try t.expectError(error.UnsafeTemporary, store.remove());
    const bytes = try readLeaf(dir, orphan);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("unsafe temporary", bytes);
    try writeLeaf(dir, orphan, "safe temporary", 0o600);
    try store.remove();
    const unrelated = try readLeaf(dir, "history.tmp.invalid");
    defer t.allocator.free(unrelated);
    try t.expectEqualStrings("preserve unrelated temp name", unrelated);
}

const MoveDirectory = struct {
    phase: storage.Phase,
    from: [:0]const u8,
    to: [:0]const u8,
    fn check(context: ?*anyopaque, phase: storage.Phase) error{InjectedFailure}!void {
        const self: *MoveDirectory = @ptrCast(@alignCast(context.?));
        if (phase == self.phase and std.c.rename(self.from, self.to) != 0) return error.InjectedFailure;
    }
};

test "store ancestor replacement before and after publication cannot earn false success" {
    for ([_]storage.Phase{ .publish, .after_publish }) |phase| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        var store = try fixture.open();
        defer store.close();
        try t.expect((try store.read()) == null);
        try store.write(first);
        const moved = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl/moved", .{fixture.root}, 0);
        defer t.allocator.free(moved);
        var movement: MoveDirectory = .{ .phase = phase, .from = fixture.path, .to = moved };
        store.hooks = .{ .context = &movement, .before = MoveDirectory.check };
        try t.expectError(if (phase == .publish) error.Conflict else error.Uncertain, store.write(second));
        store.hooks = .{};
        try t.expectEqual(@as(c_int, 0), std.c.rename(moved, fixture.path));
        try expectLoaded(&store, if (phase == .publish) first else second);
    }
}

test "store read allocation failure leaves saved bytes intact and can be revalidated" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = try fixture.open();
    defer store.close();
    try t.expect((try store.read()) == null);
    try store.write(first);
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    store.allocator = failing.allocator();
    try t.expectError(error.OutOfMemory, store.read());
    store.allocator = t.allocator;
    try expectLoaded(&store, first);
}
