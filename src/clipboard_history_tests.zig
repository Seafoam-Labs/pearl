//! Real file/restart checks under disposable /tmp state roots, never GLib's user state.
const std = @import("std");
const service = @import("services/clipboard.zig");
const history = @import("services/clipboard_history.zig");
const file_io = @import("config/io.zig");
const t = std.testing;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;

const Files = struct {
    root: [:0]u8,
    directory: [:0]u8,
    path: [:0]u8,
    fn init() !Files {
        const root = try t.allocator.dupeSentinel(u8, "/tmp/pearl-json-test-XXXXXX", 0);
        errdefer t.allocator.free(root);
        if (mkdtemp(root) == null) return error.TestDirectory;
        errdefer std.Io.Dir.cwd().deleteTree(t.io, root) catch {};
        const directory = try std.fmt.allocPrintSentinel(t.allocator, "{s}/pearl", .{root}, 0);
        errdefer t.allocator.free(directory);
        return .{ .root = root, .directory = directory, .path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/clipboard.json", .{directory}, 0) };
    }
    fn deinit(self: *Files) void {
        std.Io.Dir.cwd().deleteTree(t.io, self.root) catch @panic("isolated clipboard test cleanup failed");
        t.allocator.free(self.path);
        t.allocator.free(self.directory);
        t.allocator.free(self.root);
    }
    fn start(self: *Files, seconds: i64) service.Clipboard {
        var result: service.Clipboard = .{ .display = undefined, .context = self, .changed = noop, .test_time = seconds, .test_state_home = self.root };
        result.setLocked(false);
        return result;
    }
    fn restart(self: *Files, clipboard: *service.Clipboard, seconds: i64) void {
        clipboard.device = null;
        clipboard.stop();
        clipboard.* = self.start(seconds);
    }
    fn write(self: *Files, bytes: []const u8) !void {
        try file_io.mkdir(self.directory);
        try file_io.atomic(self.path, bytes, false);
    }
    fn read(self: *Files) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(t.io, self.path, t.allocator, .limited(history.file_limit));
    }
    fn stat(path: [:0]const u8) !std.os.linux.Statx {
        var result: std.os.linux.Statx = undefined;
        if (std.os.linux.statx(std.os.linux.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true, .INO = true, .SIZE = true }, &result) != 0) return error.TestStat;
        return result;
    }
    fn noop(_: *anyopaque) void {}
};

fn expectUsable(clipboard: *service.Clipboard) !void {
    clipboard.device = @ptrFromInt(1); // queried only; never dispatched
    defer clipboard.device = null;
    try t.expect(clipboard.accessible());
}

test "missing storage first save atomic replacement and real text PNG restart" {
    var files = try Files.init();
    defer files.deinit();
    var clipboard = files.start(100);
    defer clipboard.stop();
    try t.expectEqual(@as(usize, 0), clipboard.len);
    try t.expect(clipboard.persistence_error == null);
    try expectUsable(&clipboard);
    try clipboard.add(.text, "older");
    const first = try Files.stat(files.path);
    try t.expectEqual(@as(u16, 0o600), first.mode & 0o7777);
    try t.expectEqual(std.c.getuid(), first.uid);
    try t.expectEqual(@as(u16, 0o700), (try Files.stat(files.directory)).mode & 0o7777);
    try clipboard.add(.text, "newer"); // equal timestamp: array order must survive
    const replaced = try Files.stat(files.path);
    try t.expect(first.ino != replaced.ino);
    const png = try @import("testing/clipboard.zig").image(0x123456ff);
    defer std.heap.c_allocator.free(png);
    try clipboard.add(.png, png);
    try t.expectEqual(replaced.ino, (try Files.stat(files.path)).ino);
    try t.expectEqual(@as(usize, 3), clipboard.len);
    files.restart(&clipboard, 200);
    try t.expectEqual(@as(usize, 2), clipboard.len);
    try t.expectEqualStrings("newer", clipboard.rows[0].bytes);
    try t.expectEqualStrings("older", clipboard.rows[1].bytes);
    try t.expectEqual(@as(i64, 100), clipboard.rows[0].last_used);
    try t.expect(clipboard.source == null and clipboard.owned == null);
    const bytes = try files.read();
    defer t.allocator.free(bytes);
    const decoded = try std.json.parseFromSlice(std.json.Value, t.allocator, bytes, .{});
    defer decoded.deinit();
    for (decoded.value.array.items) |item| try t.expectEqual(@as(usize, 2), item.object.count());
}

test "Delete Clear and already-empty failed Clear retry survive restart" {
    var files = try Files.init();
    defer files.deinit();
    var clipboard = files.start(100);
    defer clipboard.stop();
    try clipboard.add(.text, "keep");
    try clipboard.add(.text, "delete");
    try clipboard.delete(clipboard.rows[0].id);
    files.restart(&clipboard, 200);
    try t.expectEqual(@as(usize, 1), clipboard.len);
    try t.expectEqualStrings("keep", clipboard.rows[0].bytes);
    try t.expectEqual(@as(c_int, 0), std.c.chmod(files.directory, 0o500));
    try t.expectError(error.SaveFailed, clipboard.clear());
    try t.expect(clipboard.len == 0 and clipboard.dirty and clipboard.removal_failed);
    try t.expectEqual(@as(c_int, 0), std.c.chmod(files.directory, 0o700));
    try clipboard.clear();
    try t.expect(!clipboard.dirty and clipboard.persistence_error == null and !clipboard.removal_failed);
    files.restart(&clipboard, 300);
    try t.expectEqual(@as(usize, 0), clipboard.len);
    const bytes = try files.read();
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("[]", bytes);
}

test "failed deletion may return on restart and save failure keeps collection usable" {
    var files = try Files.init();
    defer files.deinit();
    var clipboard = files.start(100);
    defer clipboard.stop();
    try clipboard.add(.text, "saved before failure");
    const id = clipboard.rows[0].id;
    try t.expectEqual(@as(c_int, 0), std.c.chmod(files.directory, 0o500));
    try clipboard.add(.text, "memory only");
    try expectUsable(&clipboard);
    try t.expect(clipboard.dirty and clipboard.persistence_error != null);
    try t.expectError(error.SaveFailed, clipboard.delete(id));
    try t.expectEqual(@as(usize, 1), clipboard.len);
    try t.expectEqual(@as(c_int, 0), std.c.chmod(files.directory, 0o700));
    files.restart(&clipboard, 200);
    try t.expectEqual(@as(usize, 1), clipboard.len);
    try t.expectEqualStrings("saved before failure", clipboard.rows[0].bytes);
}

test "post-rename failure reports unconfirmed persistence even when disk changed" {
    var files = try Files.init();
    defer files.deinit();
    var clipboard = files.start(100);
    defer clipboard.stop();
    try clipboard.add(.text, "old snapshot");
    clipboard.test_save = struct {
        fn save(value: *service.Clipboard) !void {
            const paths: *Files = @ptrCast(@alignCast(value.context));
            const temporary = try std.fmt.allocPrintSentinel(t.allocator, "{s}.post-rename", .{paths.path}, 0);
            defer t.allocator.free(temporary);
            const json = try history.encode(t.allocator, value.rows[0..value.len]);
            defer t.allocator.free(json);
            try file_io.atomic(temporary, json, false);
            if (std.c.rename(temporary, paths.path) != 0) return error.TestRename;
            // Simulate the directory-sync failure after publishing, before
            // confirmation. Only this disposable test snapshot is affected.
            return error.InjectedDirectorySyncFailure;
        }
    }.save;
    try t.expectError(error.SaveFailed, clipboard.clear());
    try t.expect(clipboard.len == 0 and clipboard.dirty and clipboard.removal_failed);
    const bytes = try files.read();
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("[]", bytes); // failed does not mean unchanged
    clipboard.test_save = null;
    try clipboard.clear();
    try t.expect(!clipboard.dirty and clipboard.persistence_error == null);
}

test "corrupt and oversized JSON stay untouched and never disable collection" {
    var files = try Files.init();
    defer files.deinit();
    try files.write("{broken");
    var clipboard = files.start(100);
    defer clipboard.stop();
    try t.expect(clipboard.persistence_error != null and !clipboard.dirty and clipboard.len == 0);
    try expectUsable(&clipboard);
    const bytes = try files.read();
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("{broken", bytes);
    const fd = std.c.open(files.path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.TestFile;
    defer _ = std.c.close(fd);
    try t.expectEqual(@as(c_int, 0), std.c.ftruncate(fd, @intCast(history.file_limit + 1)));
    files.restart(&clipboard, 200);
    try t.expect(clipboard.persistence_error != null and clipboard.len == 0);
    try expectUsable(&clipboard);
    try t.expectEqual(@as(u64, history.file_limit + 1), (try Files.stat(files.path)).size);
}

test "small bounded file reads allocate for observed size and honor allocation failure" {
    var files = try Files.init();
    defer files.deinit();
    try files.write("[]");
    var buffer: [1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&buffer);
    const read = try file_io.read(bounded.allocator(), files.path, history.file_limit, null);
    try t.expectEqualStrings("[]", read.bytes);
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, file_io.read(failing.allocator(), files.path, history.file_limit, null));
}

test "unsafe directory file symlink FIFO and hardlink storage is rejected" {
    for (0..7) |mode| {
        var files = try Files.init();
        defer files.deinit();
        try files.write("[]");
        const other = try std.fmt.allocPrintSentinel(t.allocator, "{s}/other", .{files.root}, 0);
        defer t.allocator.free(other);
        switch (mode) {
            0 => try t.expectEqual(@as(c_int, 0), std.c.chmod(files.directory, 0o755)),
            1 => try t.expectEqual(@as(c_int, 0), std.c.chmod(files.path, 0o644)),
            2, 3, 4 => {
                try t.expectEqual(@as(c_int, 0), std.c.unlink(files.path));
                if (mode == 2) {
                    try file_io.atomic(other, "unrelated", false);
                    try t.expectEqual(@as(c_int, 0), std.c.symlink(other, files.path));
                } else if (mode == 3) {
                    try file_io.mkdir(files.path);
                } else try t.expectEqual(@as(usize, 0), std.os.linux.mknodat(std.os.linux.AT.FDCWD, files.path, std.c.S.IFIFO | 0o600, 0));
            },
            5 => try t.expectEqual(@as(c_int, 0), std.c.link(files.path, other)),
            6 => {
                try t.expectEqual(@as(c_int, 0), std.c.rename(files.directory, other));
                try t.expectEqual(@as(c_int, 0), std.c.symlink(other, files.directory));
            },
            else => unreachable,
        }
        var clipboard = files.start(100);
        defer clipboard.stop();
        try t.expect(clipboard.persistence_error != null and clipboard.persistence_error.? == error.Unsafe and clipboard.len == 0);
        try clipboard.add(.text, "still usable in memory");
        try t.expect(clipboard.dirty and clipboard.persistence_error != null and clipboard.persistence_error.? == error.Unsafe);
        try expectUsable(&clipboard);
    }
}

test "foreign-owned history is rejected when ownership changes are available" {
    var files = try Files.init();
    defer files.deinit();
    try files.write("[]");
    const fd = std.c.open(files.path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.TestFile;
    defer _ = std.c.close(fd);
    if (std.c.fchown(fd, std.c.getuid() + 1, @bitCast(@as(i32, -1))) != 0) return error.SkipZigTest;
    defer _ = std.c.fchown(fd, std.c.getuid(), @bitCast(@as(i32, -1)));
    var clipboard = files.start(100);
    defer clipboard.stop();
    try t.expect(clipboard.persistence_error != null and clipboard.persistence_error.? == error.Unsafe and clipboard.len == 0);
}
