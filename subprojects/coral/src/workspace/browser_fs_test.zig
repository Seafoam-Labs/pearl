const std = @import("std");
const fs = @import("browser_fs.zig");
const ignore = @import("ignore.zig");
const c = @import("pearl_app_c");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;

fn has(page: fs.Page, name: []const u8) bool {
    for (page.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}
fn touch(fd: c_int, name: [*:0]const u8) !void {
    const file = std.c.openat(fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (file < 0) return error.Fixture;
    _ = std.c.close(file);
}
fn rootFd(f: *Fixture) !c_int {
    const fd = std.c.open(f.base, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return error.Fixture;
    return fd;
}

// Deliberately does not retain test fixture paths or returned pages. The 100k
// bitmap is test evidence, not browser memory. 64 KiB is enough for each page of
// this no-ignore directory, regardless of the total number of entries.
test "100000 stable children page exactly once with bounded allocations" {
    var f = try Fixture.init();
    defer f.deinit();
    const fd = try rootFd(&f);
    defer _ = std.c.close(fd);
    const total = 100_000;
    var created: usize = 0;
    defer {
        for (0..created) |i| {
            var buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0) catch unreachable;
            std.debug.assert(std.c.unlinkat(fd, name, 0) == 0);
        }
    }
    for (0..total) |i| {
        var buffer: [32]u8 = undefined;
        try touch(fd, try std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0));
        created += 1;
    }
    const seen = try a.alloc(bool, total);
    defer a.free(seen);
    @memset(seen, false);
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var continuation: ?fs.Continuation = null;
    var count: usize = 0;
    var pages: usize = 0;
    while (true) {
        var memory: [64 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&memory);
        var page = try fs.scanPage(fixed.allocator(), f.base, "", &.{}, continuation, cancel);
        defer page.deinit();
        try std.testing.expectEqual(fs.Status.ready, page.status);
        try std.testing.expect(page.entries.len <= fs.page_limit);
        try std.testing.expect(page.processed <= fs.record_limit);
        if (continuation) |previous| try std.testing.expectEqualSlices(u8, &previous.generation, &page.generation);
        for (page.entries) |entry| {
            const index = try std.fmt.parseInt(usize, entry.name, 10);
            try std.testing.expect(index < total and !seen[index]);
            seen[index] = true;
            count += 1;
        }
        pages += 1;
        if (page.complete) {
            try std.testing.expect(page.continuation == null);
            break;
        }
        continuation = page.continuation.?;
        try std.testing.expect(pages <= total / fs.page_limit + 2);
    }
    try std.testing.expectEqual(@as(usize, total), count);
    for (seen) |present| try std.testing.expect(present);
}

test "root and nested ignores precedence negation pruning Unicode and final excludes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(".gitignore", "*.log\n!keep.log\nblocked/\n!blocked/rescue\n/root-only\nparent/*\n!parent/open/\n");
    try f.write("drop.log", "");
    try f.write("keep.log", "");
    try f.write("root-only", "");
    try f.mkdir(".git");
    try f.mkdir("blocked");
    // Must never read this: ignored parents cannot be reopened by nested rules.
    try f.fifo("blocked/.gitignore");
    try f.mkdir("parent");
    try f.mkdir("parent/shut");
    try f.mkdir("parent/open");
    try f.write("parent/open/keep.log", "");
    try f.mkdir("二");
    try f.write("二/.gitignore", "!*.log\nkeep.log\n/local\n!.git\n");
    try f.write("二/drop.log", "");
    try f.write("二/keep.log", "");
    try f.write("二/café.zig", "");
    try f.write("二/root-only", "");
    try f.write("二/local", "");
    try f.write("二/.git", "gitdir: elsewhere");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var top = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer top.deinit();
    try std.testing.expect(has(top, "keep.log"));
    for ([_][]const u8{ "drop.log", "root-only", "blocked", ".git" }) |name| try std.testing.expect(!has(top, name));
    var nested = try fs.scanPage(a, f.base, "二", &.{}, null, cancel);
    defer nested.deinit();
    for ([_][]const u8{ "drop.log", "root-only", "café.zig" }) |name| try std.testing.expect(has(nested, name));
    for ([_][]const u8{ "keep.log", "local", ".git" }) |name| try std.testing.expect(!has(nested, name));
    var excluded = try fs.scanPage(a, f.base, "二", &.{"二/*.log"}, null, cancel);
    defer excluded.deinit();
    try std.testing.expect(!has(excluded, "drop.log"));
    var pruned = try fs.scanPage(a, f.base, "blocked/nonexistent/deep/root", &.{}, null, cancel);
    defer pruned.deinit();
    try std.testing.expectEqual(fs.Status.ignored, pruned.status);
    try std.testing.expect(pruned.complete and pruned.entries.len == 0);
    var parent = try fs.scanPage(a, f.base, "parent", &.{}, null, cancel);
    defer parent.deinit();
    try std.testing.expect(has(parent, "open") and !has(parent, "shut"));
    var reopened = try fs.scanPage(a, f.base, "parent/open", &.{}, null, cancel);
    defer reopened.deinit();
    try std.testing.expect(has(reopened, "keep.log"));
    var final = try fs.scanPage(a, f.base, "parent/open", &.{"parent/"}, null, cancel);
    defer final.deinit();
    try std.testing.expectEqual(fs.Status.ignored, final.status);
}

test "ignore symlink FIFO directory unreadable and size failures are visible" {
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write("rules", "*\n");
        try f.symlink("rules", ".gitignore");
        try std.testing.expectError(error.IgnoreUnavailable, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        try f.fifo(".gitignore");
        try std.testing.expectError(error.IgnoreNotRegular, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        try f.mkdir(".gitignore");
        try std.testing.expectError(error.IgnoreNotRegular, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        const bytes = try a.alloc(u8, ignore.limits.file_bytes + 1);
        defer a.free(bytes);
        @memset(bytes, '#');
        try f.write(".gitignore", bytes);
        try std.testing.expectError(error.IgnoreTooLarge, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    }
    if (std.c.geteuid() != 0) {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write(".gitignore", "*");
        const path = try f.path(".gitignore");
        defer a.free(path);
        try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0));
        defer _ = std.c.chmod(path, 0o600);
        try std.testing.expectError(error.IgnoreUnavailable, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    }
}

test "symlink traversal and final special files blocked; invalid names stay disabled" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("dir");
    try f.write("file", "");
    try f.symlink("dir", "link");
    try f.symlink("file", "file-link");
    try f.fifo("fifo");
    try f.write("bad-\xff", "");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var page = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer page.deinit();
    for (page.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "link") or std.mem.eql(u8, entry.name, "file-link") or std.mem.eql(u8, entry.name, "fifo") or std.mem.eql(u8, entry.name, "[unsupported filename encoding]")) try std.testing.expectEqual(fs.Kind.blocked, entry.kind);
    }
    try std.testing.expect(has(page, "[unsupported filename encoding]"));
    try std.testing.expectError(error.UnavailableOrSymlink, fs.scanPage(a, f.base, "link", &.{}, null, cancel));
    const linked_root = try f.path("link");
    defer a.free(linked_root);
    try std.testing.expectError(error.UnavailableOrSymlink, fs.scanPage(a, linked_root, "", &.{}, null, cancel));
    try fs.checkFile(f.base, "file");
    for ([_][]const u8{ "file-link", "fifo", "dir" }) |name| try std.testing.expectError(error.NotRegularFile, fs.checkFile(f.base, name));
    try std.testing.expectError(error.OutsideRoot, fs.checkFile(f.base, "../file"));
}

fn cancelDuringRead(_: c_int, processed: usize, cancel: *c.GCancellable) void {
    if (processed == 10) c.g_cancellable_cancel(cancel);
}
fn mutateDuringRead(fd: c_int, processed: usize, _: *c.GCancellable) void {
    if (processed == 10) touch(fd, "during-page") catch @panic("fixture mutation failed");
}

test "skipping ignored records is paginated cancellable and retryable" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(".gitignore", "*\n");
    const fd = try rootFd(&f);
    defer _ = std.c.close(fd);
    var created: usize = 0;
    defer for (0..created) |i| {
        var buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0) catch unreachable;
        std.debug.assert(std.c.unlinkat(fd, name, 0) == 0);
    };
    for (0..5000) |i| {
        var buffer: [32]u8 = undefined;
        try touch(fd, try std.fmt.bufPrintSentinel(&buffer, "{d}", .{i}, 0));
        created += 1;
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var first = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer first.deinit();
    try std.testing.expect(!first.complete and first.entries.len == 0 and first.processed == fs.record_limit);
    fs.TestHooks.after_record = cancelDuringRead;
    defer fs.TestHooks.after_record = null;
    try std.testing.expectError(error.Cancelled, fs.scanPage(a, f.base, "", &.{}, first.continuation, cancel));
    fs.TestHooks.after_record = null;
    c.g_cancellable_reset(cancel);
    var last = try fs.scanPage(a, f.base, "", &.{}, first.continuation, cancel);
    defer last.deinit();
    try std.testing.expect(last.complete and last.entries.len == 0);
    c.g_cancellable_cancel(cancel);
    try std.testing.expectError(error.Cancelled, fs.scanPage(a, f.base, "", &.{}, null, cancel));
}

test "mutations between and during pages reset rather than append partial results" {
    var f = try Fixture.init();
    defer f.deinit();
    for (0..300) |i| {
        var buffer: [32]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&buffer, "{d}", .{i}), "");
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var first = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer first.deinit();
    try std.testing.expect(!first.complete);
    try f.write("added", "");
    var stale = try fs.scanPage(a, f.base, "", &.{}, first.continuation, cancel);
    defer stale.deinit();
    try std.testing.expectEqual(fs.Status.reset_required, stale.status);
    try std.testing.expect(stale.entries.len == 0 and stale.continuation == null and !stale.complete);
    var fresh = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer fresh.deinit();
    var policy_changed = try fs.scanPage(a, f.base, "", &.{"no-match"}, fresh.continuation, cancel);
    defer policy_changed.deinit();
    try std.testing.expectEqual(fs.Status.reset_required, policy_changed.status);
    fs.TestHooks.after_record = mutateDuringRead;
    defer fs.TestHooks.after_record = null;
    const fd = try rootFd(&f);
    defer _ = std.c.close(fd);
    defer _ = std.c.unlinkat(fd, "during-page", 0);
    var during = try fs.scanPage(a, f.base, "", &.{}, fresh.continuation, cancel);
    defer during.deinit();
    try std.testing.expectEqual(fs.Status.reset_required, during.status);
    try std.testing.expectEqual(@as(usize, 0), during.entries.len);
}

test "ancestor ignore content edits invalidate a nested directory cookie" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(".gitignore", "#one\n");
    try f.mkdir("nested");
    for (0..300) |i| {
        var buffer: [32]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&buffer, "nested/{d}", .{i}), "");
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var first = try fs.scanPage(a, f.base, "nested", &.{}, null, cancel);
    defer first.deinit();
    const path = try f.path(".gitignore");
    defer a.free(path);
    // Same length overwrite, not a directory entry creation/removal.
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .NOFOLLOW = true, .CLOEXEC = true });
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(isize, 5), std.c.write(fd, "#two\n", 5));
    var next = try fs.scanPage(a, f.base, "nested", &.{}, first.continuation, cancel);
    defer next.deinit();
    try std.testing.expectEqual(fs.Status.reset_required, next.status);
}

fn cancelIgnoreRead(cancel: *c.GCancellable) void {
    c.g_cancellable_cancel(cancel);
}

test "ignore reads can be cancelled without returning a permissive listing" {
    var f = try Fixture.init();
    defer f.deinit();
    const content: [8192]u8 = @splat('#');
    try f.write(".gitignore", &content);
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const io = @import("ignore_fs.zig");
    io.TestHooks.after_read = cancelIgnoreRead;
    defer io.TestHooks.after_read = null;
    try std.testing.expectError(error.Cancelled, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    io.TestHooks.after_read = null;
    c.g_cancellable_reset(cancel);
    var page = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer page.deinit();
    try std.testing.expect(has(page, ".gitignore") and page.complete);
}

test "directory pathname replacement invalidates its identity and cookie" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("old");
    try f.mkdir("replacement");
    for (0..300) |i| {
        var buffer: [32]u8 = undefined;
        try f.write(try std.fmt.bufPrint(&buffer, "old/{d}", .{i}), "");
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var first = try fs.scanPage(a, f.base, "old", &.{}, null, cancel);
    defer first.deinit();
    const old = try f.path("old");
    defer a.free(old);
    const replacement = try f.path("replacement");
    defer a.free(replacement);
    const saved = try f.path("saved");
    defer a.free(saved);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(old, saved));
    defer std.debug.assert(std.c.rename(saved, old) == 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(replacement, old));
    defer std.debug.assert(std.c.rename(old, replacement) == 0);
    var next = try fs.scanPage(a, f.base, "old", &.{}, first.continuation, cancel);
    defer next.deinit();
    try std.testing.expectEqual(fs.Status.reset_required, next.status);
}

test "relative depth path and explicit exclude limits fail before traversal" {
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var deep: [2 * (ignore.limits.depth + 1) - 1]u8 = undefined;
    for (&deep, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'a' else '/';
    try std.testing.expectError(error.IgnoreTooLarge, fs.scanPage(a, "/", &deep, &.{}, null, cancel));
    const patterns: [ignore.limits.excludes + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.TooLarge, fs.scanPage(a, "/", "", &patterns, null, cancel));
    try std.testing.expectError(error.OutsideRoot, fs.scanPage(a, "/", "a/../b", &.{}, null, cancel));
}

fn expectWorkBound(page: fs.Page) !void {
    try std.testing.expect(page.work.match_steps <= ignore.limits.page_match_steps);
    try std.testing.expect(page.work.policy_match_steps <= ignore.limits.policy_match_steps);
    try std.testing.expect(page.work.policy_bytes <= ignore.limits.policy_read_bytes);
    try std.testing.expect(page.work.policy_files <= ignore.limits.policy_files);
}

fn overwrite(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.Fixture;
    defer _ = std.c.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.Fixture;
        at += @intCast(n);
    }
}

test "4096 long names and a legal 64KiB adversarial ignore file yield bounded lossless pages" {
    var f = try Fixture.init();
    defer f.deinit();
    var source: [ignore.limits.file_bytes]u8 = undefined;
    // Exactly the reported case: 2048 copies of '*' + 30 '?' + newline.
    for (0..ignore.limits.rules) |i| {
        const line = source[i * 32 ..][0..32];
        @memset(line, '?');
        line[0] = '*';
        line[31] = '\n';
    }
    try f.write(".gitignore", &source);
    try f.write("keep", "");
    for (0..4096) |i| {
        var name: [128]u8 = @splat('a');
        _ = try std.fmt.bufPrint(name[0..4], "{d:0>4}", .{i});
        try f.write(&name, "");
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const ignore_path = try f.path(".gitignore");
    defer a.free(ignore_path);
    // The second pass uses negation plus eight later nonmatching rules to make
    // VISIBLE candidates expensive too. It forces mid-match cookie rollback
    // before the 256-entry cap and verifies each of 4096 names exactly once.
    for (0..2) |pass| {
        if (pass == 1) {
            for (0..ignore.limits.rules) |i| {
                const line = source[i * 32 ..][0..32];
                @memset(line, '?');
                line[31] = '\n';
                if (i < ignore.limits.rules - 8) {
                    line[0] = '!';
                    line[1] = '*';
                } else {
                    line[0] = '*';
                    line[30] = 'z';
                }
            }
            try overwrite(ignore_path, &source);
        }
        var seen: [4096]bool = @splat(false);
        var saw_keep = false;
        var saw_ignore = false;
        var saw_work_boundary = false;
        var token: ?fs.Continuation = null;
        var pages: usize = 0;
        var processed: usize = 0;
        while (true) {
            var page = try fs.scanPage(a, f.base, "", &.{}, token, cancel);
            defer page.deinit();
            try std.testing.expectEqual(fs.Status.ready, page.status);
            try expectWorkBound(page);
            try std.testing.expectEqual(@as(usize, 2 * source.len), page.work.policy_bytes);
            try std.testing.expectEqual(@as(usize, 2), page.work.policy_files);
            for (page.entries) |entry| {
                if (std.mem.eql(u8, entry.name, "keep")) {
                    try std.testing.expect(!saw_keep);
                    saw_keep = true;
                } else if (std.mem.eql(u8, entry.name, ".gitignore")) {
                    try std.testing.expect(!saw_ignore);
                    saw_ignore = true;
                } else {
                    try std.testing.expectEqual(@as(usize, 1), pass);
                    const index = try std.fmt.parseInt(usize, entry.name[0..4], 10);
                    try std.testing.expect(!seen[index]);
                    seen[index] = true;
                }
            }
            pages += 1;
            processed += page.processed;
            if (page.complete) break;
            try std.testing.expect(page.processed > 0);
            if (page.entries.len < fs.page_limit and page.processed < fs.record_limit) saw_work_boundary = true;
            if (token) |previous| try std.testing.expect(previous.cookie != page.continuation.?.cookie);
            token = page.continuation.?;
            try std.testing.expect(pages < 40);
        }
        try std.testing.expect(saw_keep and saw_ignore and saw_work_boundary);
        // Counts committed records, not abandoned candidates: dot, dot-dot,
        // .gitignore, keep, and every long filename, even when all are ignored.
        try std.testing.expectEqual(@as(usize, 4100), processed);
        for (seen) |present| try std.testing.expectEqual(pass == 1, present);
    }
}

test "a single over-budget filename fails explicitly rather than endless empty pages" {
    var f = try Fixture.init();
    defer f.deinit();
    var source: [ignore.limits.file_bytes]u8 = @splat('?');
    for (0..64) |i| {
        source[i * 1024] = '*';
        source[i * 1024 + 1022] = 'z';
        source[i * 1024 + 1023] = '\n';
    }
    try f.write(".gitignore", &source);
    const name: [255]u8 = @splat('a');
    try f.write(&name, "");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var token: ?fs.Continuation = null;
    for (0..3) |_| {
        var page = fs.scanPage(a, f.base, "", &.{}, token, cancel) catch |err| {
            try std.testing.expectEqual(error.MatchBudgetExceeded, err);
            return;
        };
        defer page.deinit();
        try expectWorkBound(page);
        try std.testing.expect(!page.complete and page.continuation != null and page.processed > 0);
        try std.testing.expect(!has(page, &name));
        token = page.continuation;
    }
    return error.ExpectedSingleMatchLimit;
}

test "ancestor matching budget spans both policy walks rather than resetting per parent" {
    var f = try Fixture.init();
    defer f.deinit();
    var source: [24 * 1024]u8 = @splat('?');
    for (0..24) |i| {
        source[i * 1024] = '*';
        source[i * 1024 + 1022] = 'z';
        source[i * 1024 + 1023] = '\n';
    }
    try f.write(".gitignore", &source);
    const parent: [128]u8 = @splat('a');
    try f.mkdir(&parent);
    const nested = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, parent });
    defer a.free(nested);
    try f.mkdir(nested);
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    try std.testing.expectError(error.PolicyBudgetExceeded, fs.scanPage(a, f.base, nested, &.{}, null, cancel));
}

var matcher_polls: usize = 0;
fn cancelInsideMatch(cancel: *c.GCancellable) void {
    matcher_polls += 1;
    if (matcher_polls == 3) c.g_cancellable_cancel(cancel);
}
fn armMatchCancellation(_: c_int, _: usize, _: *c.GCancellable) void {
    // Arm only AFTER the initial policy read/parse, so cancellation necessarily
    // happens inside classification of a directory entry, not while loading it.
    @import("ignore_fs.zig").TestHooks.before_cancel_check = cancelInsideMatch;
}

test "GCancellable interrupts expensive entry matching and the input cookie stays reusable" {
    var f = try Fixture.init();
    defer f.deinit();
    var source: [8 * 1024]u8 = @splat('?');
    for (0..8) |i| {
        source[i * 1024] = '*';
        source[i * 1024 + 1022] = 'z';
        source[i * 1024 + 1023] = '\n';
    }
    try f.write(".gitignore", &source);
    const name: [128]u8 = @splat('a');
    try f.write(&name, "");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    matcher_polls = 0;
    fs.TestHooks.after_record = armMatchCancellation;
    const io = @import("ignore_fs.zig");
    defer fs.TestHooks.after_record = null;
    defer io.TestHooks.before_cancel_check = null;
    try std.testing.expectError(error.Cancelled, fs.scanPage(a, f.base, "", &.{}, null, cancel));
    try std.testing.expectEqual(@as(usize, 3), matcher_polls);
    fs.TestHooks.after_record = null;
    io.TestHooks.before_cancel_check = null;
    c.g_cancellable_reset(cancel);
    var retry = try fs.scanPage(a, f.base, "", &.{}, null, cancel);
    defer retry.deinit();
    try std.testing.expect(retry.complete and has(retry, &name) and has(retry, ".gitignore"));
    try expectWorkBound(retry);
}

var counted_reads: usize = 0;
fn countRead(_: *c.GCancellable) void {
    counted_reads += 1;
}

test "aggregate ignore source cap is checked before allocating or reading another file" {
    var f = try Fixture.init();
    defer f.deinit();
    const source: [ignore.limits.file_bytes]u8 = @splat('#');
    try f.write(".gitignore", &source);
    for ([_][]const u8{ "a", "a/b", "a/b/c", "a/b/c/d" }) |path| {
        try f.mkdir(path);
        const file = try std.fmt.allocPrint(a, "{s}/.gitignore", .{path});
        defer a.free(file);
        try f.write(file, &source);
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const io = @import("ignore_fs.zig");
    counted_reads = 0;
    io.TestHooks.after_read = countRead;
    defer io.TestHooks.after_read = null;
    try std.testing.expectError(error.IgnoreTooLarge, fs.scanPage(a, f.base, "a/b/c/d", &.{}, null, cancel));
    try std.testing.expectEqual(@as(usize, ignore.limits.total_bytes / 4096), counted_reads);
}

fn allocationCase(allocator: std.mem.Allocator, root: []const u8, cancel: *c.GCancellable) !void {
    var page = try fs.scanPage(allocator, root, "nested", &.{"**/hidden"}, null, cancel);
    defer page.deinit();
}
test "paging frees all allocations on failure" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(".gitignore", "*.log\n!keep.log\n");
    try f.mkdir("nested");
    try f.write("nested/.gitignore", "hidden\n");
    try f.write("nested/café", "");
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{ f.base, cancel });
}
