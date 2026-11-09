//! Headless tests; import recovery.zig with the existing pearl_app_c module.
const std = @import("std");
const c = @import("pearl_app_c");
const recovery = @import("recovery.zig");
const fs = @import("recovery_fs.zig");
const model = @import("recovery_model.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const bytesEqual = std.testing.expectEqualStrings;

const sample: model.Snapshot = .{
    .documents = &.{
        .{ .id = 7, .path = "/work/日本語\xff.txt", .text = "\xef\xbb\xbf雪😀\r\n\x00\xff", .bom = true, .newline = .crlf, .revision = 42, .saved_etag = "old-etag" },
        .{ .id = 8, .text = "untitled\nΔ", .revision = 9 },
    },
    .groups = &.{ .{ .path = "root", .split = .horizontal }, .{ .path = "root/0", .active_view = 10 }, .{ .path = "root/1", .active_view = 11 } },
    .views = &.{ .{ .id = 10, .document_id = 7, .group_path = "root/0", .anchor = 3, .cursor = 6 }, .{ .id = 11, .document_id = 8, .group_path = "root/1", .scroll_line = 12 } },
    .active_group = "root/1",
};
const newer: model.Snapshot = .{ .documents = &.{.{ .id = 8, .text = "new checkpoint" }} };

const Home = struct {
    path: [*:0]u8,
    fn init() !Home {
        return .{ .path = c.g_dir_make_tmp("coral-recovery-XXXXXX", null) orelse return error.TempDirectory };
    }
    fn state(self: Home) []const u8 {
        return std.mem.span(self.path);
    }
    fn deinit(self: Home) void {
        const root = std.fmt.allocPrintSentinel(a, "{s}/coral/recovery", .{self.state()}, 0) catch unreachable;
        defer a.free(root);
        const coral = std.fmt.allocPrintSentinel(a, "{s}/coral", .{self.state()}, 0) catch unreachable;
        defer a.free(coral);
        std.debug.assert(c.g_rmdir(root) == 0);
        std.debug.assert(c.g_rmdir(coral) == 0);
        std.debug.assert(c.g_rmdir(self.path) == 0);
        c.g_free(self.path);
    }
};
fn discard(journal: *fs.Journal) void {
    journal.discard(.user_approved) catch @panic("test journal cleanup failed");
    journal.release();
}
fn expectSample(value: model.Snapshot) !void {
    try equal(@as(usize, 2), value.documents.len);
    for (sample.documents, value.documents) |want, got| {
        try equal(want.id, got.id);
        try bytesEqual(want.text, got.text);
        try equal(want.dirty, got.dirty);
        try equal(want.bom, got.bom);
        try equal(want.newline, got.newline);
        try equal(want.revision, got.revision);
        if (want.path) |path| try bytesEqual(path, got.path.?) else try expect(got.path == null);
        if (want.saved_etag) |etag| try bytesEqual(etag, got.saved_etag.?) else try expect(got.saved_etag == null);
    }
    try bytesEqual("root/1", value.active_group.?);
    try equal(@as(u64, 6), value.views[0].cursor);
    try equal(@as(u64, 12), value.views[1].scroll_line);
    try equal(@as(?u64, 11), value.groups[2].active_view);
}

test "versioned bounded manifest preserves dirty and untitled exact Unicode and binary bytes" {
    const encoded = try model.encode(a, sample);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try expectSample(decoded.value);
    const owned = try model.OwnedSnapshot.create(sample);
    defer owned.deinit();
    try expectSample(owned.value);
    try expect(owned.value.documents[0].text.ptr != sample.documents[0].text.ptr);
}

test "checksum and unknown schema reject without partial recovery" {
    const encoded = try model.encode(a, sample);
    defer a.free(encoded);
    encoded[encoded.len - 3] ^= 1;
    try std.testing.expectError(error.CorruptManifest, model.decode(encoded));
    encoded["CORAL-RECOVERY ".len] = '9';
    try std.testing.expectError(error.UnsupportedVersion, model.decode(encoded));
    try std.testing.expectError(error.CorruptManifest, model.decode("not a journal"));
}

test "bounds, traversal, native paths and dangling selections reject explicitly" {
    const huge = try a.alloc(u8, model.limits.document_bytes + 1);
    defer a.free(huge);
    try std.testing.expectError(error.TooLarge, model.OwnedSnapshot.create(.{ .documents = &.{.{ .id = 1, .text = huge }} }));
    for ([_][]const u8{ "file:///tmp/file", "../file", "/tmp/../file", "/tmp/./file", "/tmp/a\x00b" }) |path| {
        try std.testing.expectError(error.InvalidPath, model.nativePath(path));
    }
    for ([_][]const u8{ "../x", "/absolute", "s-../../../../../../../../../../etc/x", "s-00000000000000000000000000000000/0" }) |path| {
        try std.testing.expectError(error.InvalidSessionId, fs.SessionId.parse(path));
    }
    try std.testing.expectError(error.InvalidSnapshot, model.validate(.{
        .documents = &.{.{ .id = 1, .text = "" }},
        .groups = &.{.{ .path = "root" }},
        .views = &.{.{ .id = 1, .document_id = 1, .group_path = "root", .cursor = 1 }},
    }));
    try std.testing.expectError(error.InvalidSnapshot, model.validate(.{ .documents = &.{ .{ .id = 1, .text = "" }, .{ .id = 1, .text = "" } } }));
}

test "two active sessions excluded, stale claims exclusive, release retains, discard isolated" {
    const home = try Home.init();
    defer home.deinit();
    var first = try fs.Journal.create(home.state());
    var second = try fs.Journal.create(home.state());
    defer discard(&second);
    try expect(!std.mem.eql(u8, first.id.name(), second.id.name()));
    try equal(fs.Checkpoint.durable, try first.checkpoint(sample));
    try equal(fs.Checkpoint.durable, try second.checkpoint(newer));
    const active = try fs.discover(home.state());
    defer active.deinit();
    try equal(@as(usize, 0), active.entries.len);
    try std.testing.expectError(error.ActiveSession, fs.Journal.claim(home.state(), first.id));
    const id = first.id;
    first.release();
    const stale = try fs.discover(home.state());
    defer stale.deinit();
    try equal(@as(usize, 1), stale.entries.len);
    var claim = try fs.Journal.claim(home.state(), id);
    try std.testing.expectError(error.ActiveSession, fs.Journal.claim(home.state(), id));
    const loaded = try claim.load();
    defer loaded.deinit();
    try expectSample(loaded.value);
    claim.release(); // dismissal must preserve it
    claim = try fs.Journal.claim(home.state(), id);
    discard(&claim);
    const other = try second.load();
    defer other.deinit();
    try bytesEqual("new checkpoint", other.value.documents[0].text);
}

test "failed writes preserve last committed snapshot, rename commit reports uncertain durability" {
    const home = try Home.init();
    defer home.deinit();
    var journal = try fs.Journal.create(home.state());
    defer discard(&journal);
    _ = try journal.checkpoint(sample);
    for ([_]fs.Fault{ .during_write, .before_rename }) |fault| {
        try std.testing.expectError(error.InjectedFailure, journal.checkpointWithHooks(newer, .{ .fault = fault }));
        const loaded = try journal.load();
        defer loaded.deinit();
        try expectSample(loaded.value);
    }
    try equal(fs.Checkpoint.durability_uncertain, try journal.checkpointWithHooks(newer, .{ .fault = .after_rename }));
    const loaded = try journal.load();
    defer loaded.deinit();
    try bytesEqual("new checkpoint", loaded.value.documents[0].text);
}

test "manifest symlink and hardlink refused; temp symlink cannot write outside session" {
    const home = try Home.init();
    defer home.deinit();
    var journal = try fs.Journal.create(home.state());
    defer discard(&journal);
    const outside = try std.fmt.allocPrintSentinel(a, "{s}/outside", .{home.state()}, 0);
    defer a.free(outside);
    defer _ = c.g_unlink(outside);
    try expect(c.g_file_set_contents(outside, "sentinel", 8, null) != 0);
    try expect(std.c.symlinkat(outside, journal.dir, "pending") == 0);
    _ = try journal.checkpoint(sample);
    const fd = std.c.open(outside, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer fs.close(fd);
    var buffer: [8]u8 = undefined;
    try equal(@as(isize, 8), std.c.read(fd, &buffer, 8));
    try bytesEqual("sentinel", &buffer);
    try expect(std.c.unlinkat(journal.dir, "manifest", 0) == 0);
    try expect(std.c.symlinkat(outside, journal.dir, "manifest") == 0);
    try std.testing.expectError(error.UnsafeFile, journal.load());
    try expect(std.c.unlinkat(journal.dir, "manifest", 0) == 0);
    _ = try journal.checkpoint(sample);
    try expect(std.c.linkat(journal.dir, "manifest", journal.dir, "extra", 0) == 0);
    try std.testing.expectError(error.UnsafeFile, journal.load());
    try std.testing.expectError(error.UnexpectedEntry, journal.discard(.user_approved));
    try expect(std.c.unlinkat(journal.dir, "extra", 0) == 0);
}

test "unsafe root/session entries and symlinked state ancestors are never followed" {
    const home = try Home.init();
    defer home.deinit();
    var journal = try fs.Journal.create(home.state());
    defer discard(&journal);
    const alias = try std.fmt.allocPrintSentinel(a, "{s}/alias", .{home.state()}, 0);
    defer a.free(alias);
    defer _ = c.g_unlink(alias);
    try expect(c.symlink(home.path, alias) == 0);
    try std.testing.expectError(error.UnsafeDirectory, fs.openRoot(alias));
    const id = try fs.SessionId.parse("s-0000000000000000000000000000000000");
    const name = try a.dupeSentinel(u8, id.name(), 0);
    defer a.free(name);
    try expect(std.c.symlinkat(home.path, journal.root, name) == 0);
    defer _ = std.c.unlinkat(journal.root, name, 0);
    const found = try fs.discover(home.state());
    defer found.deinit();
    try equal(@as(usize, 1), found.entries.len);
    try equal(.unsafe, found.entries[0].state);
    try std.testing.expectError(error.UnsafeDirectory, fs.Journal.claim(home.state(), id));
    try expect(std.c.fchmod(journal.dir, 0o755) == 0);
    try std.testing.expectError(error.UnsafeDirectory, fs.Journal.claim(home.state(), journal.id));
    try expect(std.c.fchmod(journal.dir, 0o700) == 0);
}

test "process death during temp write and around rename releases claims and leaves whole snapshots" {
    const home = try Home.init();
    defer home.deinit();
    // Runs before GTask tests: no GLib worker pool has been started at fork.
    for ([_]fs.Fault{ .during_write, .before_rename, .after_rename }) |fault| {
        var journal = try fs.Journal.create(home.state());
        _ = try journal.checkpoint(sample);
        const id = journal.id;
        journal.release();
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = c.alarm(10);
            var claimed = fs.Journal.claim(home.state(), id) catch std.c._exit(74);
            _ = claimed.checkpointWithHooks(newer, .{ .fault = fault, .terminate_process = true }) catch std.c._exit(75);
            std.c._exit(76);
        }
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
        }
        try equal(@as(c_int, 73 << 8), status);
        var claimed = try fs.Journal.claim(home.state(), id);
        defer discard(&claimed);
        const recovered = try claimed.load();
        defer recovered.deinit();
        if (fault == .after_rename) {
            try bytesEqual("new checkpoint", recovered.value.documents[0].text);
        } else {
            try expectSample(recovered.value);
            // A crash leaves pending; the next checkpoint safely replaces it.
            _ = try claimed.checkpoint(newer);
        }
    }
}

test "on-disk corrupt manifest retained, file modes private, oversized manifest rejected" {
    const home = try Home.init();
    defer home.deinit();
    var journal = try fs.Journal.create(home.state());
    defer discard(&journal);
    _ = try journal.checkpoint(sample);
    var stat: c.GStatBuf = undefined;
    try equal(@as(c_int, 0), c.fstat(journal.root, &stat));
    try equal(@as(u32, 0o700), stat.st_mode & 0o7777);
    try equal(@as(c_int, 0), c.fstat(journal.dir, &stat));
    try equal(@as(u32, 0o700), stat.st_mode & 0o7777);
    const fd = std.c.openat(journal.dir, "manifest", .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer fs.close(fd);
    try equal(@as(c_int, 0), c.fstat(fd, &stat));
    try equal(@as(u32, 0o600), stat.st_mode & 0o7777);
    try equal(@as(isize, 1), std.c.write(fd, "X", 1));
    try std.testing.expectError(error.CorruptManifest, journal.load());
    // Failure did not remove the evidence.
    try equal(@as(c_int, 0), c.fstat(fd, &stat));
    try equal(@as(u64, 1), stat.st_nlink);
    try equal(@as(c_int, 0), std.c.ftruncate(fd, model.limits.manifest_bytes + 1));
    try std.testing.expectError(error.TooLarge, journal.load());
}

const Seen = struct {
    calls: usize = 0,
    result: recovery.Result = .coalesced,
    context: *c.GMainContext,
    fn done(data: ?*anyopaque, result: recovery.Result) void {
        const self: *Seen = @ptrCast(@alignCast(data.?));
        std.debug.assert(c.g_main_context_is_owner(self.context) != 0);
        self.calls += 1;
        self.result = result;
    }
    fn wait(self: *Seen) !void {
        const until = c.g_get_monotonic_time() + 10_000_000;
        while (self.calls == 0) {
            _ = c.g_main_context_iteration(self.context, 0);
            if (c.g_get_monotonic_time() > until) return error.CompletionTimeout;
            c.g_usleep(1000);
        }
        try equal(@as(usize, 1), self.calls);
    }
};

test "async checkpoints coalesce, flush on close, callbacks on submitting context, dismissal retains" {
    const home = try Home.init();
    defer home.deinit();
    const context = c.g_main_context_new().?;
    defer c.g_main_context_unref(context);
    c.g_main_context_push_thread_default(context);
    defer c.g_main_context_pop_thread_default(context);
    const store = try recovery.Store.open(.{ .state_home = home.state() });
    const id = store.sessionId();
    var first: Seen = .{ .context = context };
    var skipped: Seen = .{ .context = context };
    var latest: Seen = .{ .context = context };
    var closed: Seen = .{ .context = context };
    try store.saveAsync(try model.OwnedSnapshot.create(sample), &Seen.done, &first);
    try store.saveAsync(try model.OwnedSnapshot.create(sample), &Seen.done, &skipped);
    try store.saveAsync(try model.OwnedSnapshot.create(newer), &Seen.done, &latest);
    try store.closeAsync(.keep, &Seen.done, &closed);
    try equal(@as(usize, 0), first.calls);
    try equal(@as(usize, 0), skipped.calls);
    const refused = try model.OwnedSnapshot.create(sample);
    defer refused.deinit();
    try std.testing.expectError(error.Closing, store.saveAsync(refused, &Seen.done, &skipped));
    try closed.wait();
    store.destroy();
    try first.wait();
    try skipped.wait();
    try latest.wait();
    try equal(.coalesced, std.meta.activeTag(skipped.result));
    try equal(.closed, std.meta.activeTag(closed.result));
    try equal(fs.Checkpoint.durable, latest.result.checkpoint);
    var claim = try fs.Journal.claim(home.state(), id);
    defer discard(&claim);
    const loaded = try claim.load();
    defer loaded.deinit();
    try bytesEqual("new checkpoint", loaded.value.documents[0].text);
}

test "async write failure retains last snapshot and prevents resolved-close deletion" {
    const home = try Home.init();
    defer home.deinit();
    const context = c.g_main_context_new().?;
    defer c.g_main_context_unref(context);
    c.g_main_context_push_thread_default(context);
    defer c.g_main_context_pop_thread_default(context);
    const store = try recovery.Store.open(.{ .state_home = home.state() });
    const id = store.sessionId();
    _ = try store.journal.checkpoint(sample);
    // A directory at the temp name reliably fails unlink even when running root.
    try equal(@as(c_int, 0), std.c.mkdirat(store.journal.dir, "pending", 0o700));
    var saved: Seen = .{ .context = context };
    var closed: Seen = .{ .context = context };
    try store.saveAsync(try model.OwnedSnapshot.create(newer), &Seen.done, &saved);
    try store.closeAsync(.remove_after_resolution, &Seen.done, &closed);
    try closed.wait();
    store.destroy();
    try saved.wait();
    try equal(error.Io, saved.result.failed);
    try equal(error.CheckpointNotDurable, closed.result.failed);
    var claim = try fs.Journal.claim(home.state(), id);
    defer discard(&claim);
    try equal(@as(c_int, 0), std.c.unlinkat(claim.dir, "pending", std.c.AT.REMOVEDIR));
    const loaded = try claim.load();
    defer loaded.deinit();
    try expectSample(loaded.value);
}

test "inclusive aggregate text limit roundtrips; over-limit and record-count overflow reject" {
    const text = try a.alloc(u8, model.limits.document_bytes);
    defer a.free(text);
    @memset(text, 0xff);
    const value: model.Snapshot = .{ .documents = &.{ .{ .id = 1, .text = text }, .{ .id = 2, .text = text } } };
    const encoded = try model.encode(a, value);
    defer a.free(encoded);
    const loaded = try model.decode(encoded);
    defer loaded.deinit();
    try bytesEqual(text, loaded.value.documents[0].text);
    try bytesEqual(text, loaded.value.documents[1].text);
    try std.testing.expectError(error.TooLarge, model.validate(.{ .documents = &.{ .{ .id = 1, .text = text }, .{ .id = 2, .text = text }, .{ .id = 3, .text = "x" } } }));
    const docs: [model.limits.documents + 1]model.Document = @splat(.{ .id = 1, .text = "" });
    try std.testing.expectError(error.TooLarge, model.validate(.{ .documents = &docs }));
}

test "resolved close removes only current journal after pending checkpoint flush" {
    const home = try Home.init();
    defer home.deinit();
    var other = try fs.Journal.create(home.state());
    defer discard(&other);
    const context = c.g_main_context_new().?;
    defer c.g_main_context_unref(context);
    c.g_main_context_push_thread_default(context);
    defer c.g_main_context_pop_thread_default(context);
    const store = try recovery.Store.open(.{ .state_home = home.state() });
    var saved: Seen = .{ .context = context };
    var closed: Seen = .{ .context = context };
    try store.saveAsync(try model.OwnedSnapshot.create(sample), &Seen.done, &saved);
    try store.closeAsync(.remove_after_resolution, &Seen.done, &closed);
    try closed.wait();
    store.destroy();
    try saved.wait();
    try equal(.closed, std.meta.activeTag(closed.result));
    const found = try fs.discover(home.state());
    defer found.deinit();
    try equal(@as(usize, 0), found.entries.len);
    try std.testing.expectError(error.ActiveSession, fs.Journal.claim(home.state(), other.id));
}

fn wireFixture(version: u8, json: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.fmt.allocPrint(a, "CORAL-RECOVERY {d}\n{s}\n{s}", .{ version, hex, json });
}

test "v2 excerpt bounds, presentation selections and horizontal scroll roundtrip" {
    const value: model.Snapshot = .{
        .documents = &.{.{ .id = 1, .text = "prefix α😀z suffix" }},
        .groups = &.{.{ .path = "root/0", .active_view = 2 }},
        .views = &.{.{ .id = 2, .document_id = 1, .group_path = "root/0", .excerpt_start = 7, .excerpt_end = 14, .anchor = 6, .cursor = 2, .scroll_x = 123.5, .scroll_line = 8 }},
    };
    const encoded = try model.encode(a, value);
    defer a.free(encoded);
    try expect(std.mem.startsWith(u8, encoded, "CORAL-RECOVERY 2\n"));
    const loaded = try model.decode(encoded);
    defer loaded.deinit();
    const view = loaded.value.views[0];
    try equal(@as(?u64, 7), view.excerpt_start);
    try equal(@as(?u64, 14), view.excerpt_end);
    try equal(@as(f64, 123.5), view.scroll_x);
    try bytesEqual("α😀z", try model.presentationText(loaded.value.documents[0].text, view));
    try @import("recovery_offsets.zig").validateRestore(loaded.value);
}

test "strict v1 compatibility defaults missing v2 fields without accepting unknown fields" {
    const json = "{\"documents\":[{\"id\":1,\"path\":null,\"text\":\"YWJj\",\"dirty\":true,\"bom\":false,\"newline\":\"lf\",\"revision\":0,\"saved_etag\":null}],\"groups\":[{\"path\":\"root\"}],\"views\":[{\"id\":1,\"document_id\":1,\"group_path\":\"root\",\"anchor\":2,\"cursor\":1}],\"active_group\":\"root\"}";
    const bytes = try wireFixture(1, json);
    defer a.free(bytes);
    const loaded = try model.decode(bytes);
    defer loaded.deinit();
    try bytesEqual("abc", loaded.value.documents[0].text);
    try equal(@as(f64, 0), loaded.value.views[0].scroll_x);
    try expect(loaded.value.views[0].excerpt_start == null);
    try equal(@as(u64, 2), loaded.value.views[0].anchor);
    const extra = try std.mem.replaceOwned(u8, a, json, "\"anchor\":2", "\"scroll_x\":4,\"anchor\":2");
    defer a.free(extra);
    const invalid = try wireFixture(1, extra);
    defer a.free(invalid);
    try std.testing.expectError(error.CorruptManifest, model.decode(invalid));
    const future = try wireFixture(9, json);
    defer a.free(future);
    try std.testing.expectError(error.UnsupportedVersion, model.decode(future));
}

test "invalid excerpt and horizontal scroll metadata cannot be restored or serialized" {
    var view: model.View = .{ .id = 1, .document_id = 1, .group_path = "root", .excerpt_start = 0, .excerpt_end = 2 };
    const value: model.Snapshot = .{ .documents = &.{.{ .id = 1, .text = "αz" }}, .groups = &.{.{ .path = "root" }}, .views = @as([*]model.View, @ptrCast(&view))[0..1] };
    try model.validate(value);
    view.excerpt_end = null;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.excerpt_start = null;
    view.excerpt_end = 2;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.excerpt_start = 1;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.excerpt_start = 3;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.excerpt_start = 0;
    view.excerpt_end = 4;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.excerpt_end = 2;
    view.cursor = 3;
    try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    view.cursor = 1;
    try std.testing.expectError(error.InvalidSnapshot, @import("recovery_offsets.zig").validateRestore(value));
    view.cursor = 0;
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64), 1e30 }) |bad| {
        view.scroll_x = bad;
        try std.testing.expectError(error.InvalidSnapshot, model.validate(value));
    }
}

test "empty cleanup never deletes manifest, pending, unknown entries or symlinks" {
    const home = try Home.init();
    defer home.deinit();
    var empty = try fs.Journal.create(home.state());
    try std.testing.expectError(error.ActiveSession, fs.Journal.claim(home.state(), empty.id));
    const id = empty.id;
    empty.release();
    var claim = try fs.Journal.claim(home.state(), id);
    try expect(try claim.removeIfEmpty());
    claim.release();
    for ([_][*:0]const u8{ "manifest", "pending", "unknown" }) |name| {
        var journal = try fs.Journal.create(home.state());
        const fd = std.c.openat(journal.dir, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
        try expect(fd >= 0);
        fs.close(fd);
        try expect(!try journal.removeIfEmpty());
        if (std.mem.eql(u8, std.mem.span(name), "manifest")) try std.testing.expectError(error.CorruptManifest, journal.load());
        try equal(@as(c_int, 0), std.c.unlinkat(journal.dir, name, 0));
        try equal(@as(c_int, 0), std.c.symlinkat("/does-not-exist", journal.dir, name));
        try expect(!try journal.removeIfEmpty());
        try equal(@as(c_int, 0), std.c.unlinkat(journal.dir, name, 0));
        try expect(try journal.removeIfEmpty());
        journal.release();
    }
}

test "keep-close removes only an empty owned session even after rejected capture" {
    const home = try Home.init();
    defer home.deinit();
    const context = c.g_main_context_new().?;
    defer c.g_main_context_unref(context);
    c.g_main_context_push_thread_default(context);
    defer c.g_main_context_pop_thread_default(context);
    const store = try recovery.Store.open(.{ .state_home = home.state() });
    var other = try fs.Journal.create(home.state());
    defer discard(&other);
    _ = try other.checkpoint(sample);
    store.last_checkpoint_ok = false;
    var closed: Seen = .{ .context = context };
    try store.closeAsync(.keep, &Seen.done, &closed);
    try closed.wait();
    try equal(.closed, std.meta.activeTag(closed.result));
    store.destroy();
    const candidates = try fs.discover(home.state());
    defer candidates.deinit();
    try equal(@as(usize, 0), candidates.entries.len);
    const retained = try other.load();
    defer retained.deinit();
    try expectSample(retained.value);
}
