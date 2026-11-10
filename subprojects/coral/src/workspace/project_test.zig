//! Headless/fork tests. Parent runner rooted at src should import this file;
//! link libc. Do not run fork cases inside the application's GTK worker process.
const std = @import("std");
const fs = @import("project_fs.zig");
const model = @import("session_model.zig");
const explicit = @import("session_fs.zig");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const bytesEqual = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn alarm(seconds: c_uint) c_uint;
extern "c" fn chown(path: [*:0]const u8, owner: std.c.uid_t, group: std.c.gid_t) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite_existing: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
const sample: model.Value = .{
    .snapshot = .{
        .documents = &.{ .{ .id = 7, .path = "/work/\xff.txt", .text = "雪😀\r\n\x00\xff", .bom = true, .newline = .crlf, .revision = 42, .saved_etag = "old-etag" }, .{ .id = 8, .text = "unsaved untitled", .revision = 9 } },
        .groups = &.{.{ .path = "root", .active_view = 10 }},
        .views = &.{.{ .id = 10, .document_id = 7, .group_path = "root", .anchor = 4, .cursor = 0, .excerpt_start = 3, .excerpt_end = 7, .scroll_x = 19.5 }},
        .active_group = "root",
    },
    .workspace = .{ .source = .manifest, .path = "/offline/../\xff.coral", .roots = &.{ .{ .path = "/offline/\xfe", .name = "日本語" }, .{ .path = "/unmounted", .name = "never opened" } } },
};
const empty: model.Value = .{ .snapshot = .{ .documents = &.{} } };
fn changed() model.Value {
    var value = sample;
    value.snapshot = .{ .documents = &.{.{ .id = 1, .text = "new dirty snapshot" }} };
    return value;
}
fn expectValue(wanted: model.Value, actual: model.Value) !void {
    const x = try model.encode(a, wanted);
    defer a.free(x);
    const y = try model.encode(a, actual);
    defer a.free(y);
    try bytesEqual(x, y);
}
const Home = struct {
    fixture: Fixture,
    state: [:0]u8,
    fn init() !Home {
        var f = try Fixture.init();
        errdefer f.deinit();
        try f.mkdir("state");
        return .{ .fixture = f, .state = try f.path("state") };
    }
    fn path(self: *const Home, suffix: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.state, suffix }, 0);
    }
    fn projectPath(self: *const Home, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/coral/projects/{s}", .{ self.state, name }, 0);
    }
    fn snapshotPath(self: *const Home, id: fs.Id) ![:0]u8 {
        return self.projectPath(&try fs.testing.snapshotName(self.state, id));
    }
    fn deinit(self: *Home) void {
        // Test-owned flat directories only, never traverse symlinks recursively.
        for ([_][]const u8{ "coral/projects", "coral/sessions" }) |suffix| {
            const p = self.path(suffix) catch unreachable;
            defer a.free(p);
            const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
            if (fd >= 0) {
                const stream = std.c.fdopendir(fd) orelse unreachable;
                while (std.c.readdir(stream)) |entry| {
                    const name = std.mem.sliceTo(&entry.name, 0);
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                    if (std.c.unlinkat(fd, @ptrCast(name.ptr), 0) != 0) std.debug.assert(std.c.unlinkat(fd, @ptrCast(name.ptr), std.c.AT.REMOVEDIR) == 0);
                }
                _ = std.c.closedir(stream);
                std.debug.assert(std.c.rmdir(p) == 0);
            }
        }
        const coral = self.path("coral") catch unreachable;
        defer a.free(coral);
        _ = std.c.rmdir(coral);
        a.free(self.state);
        self.fixture.deinit();
    }
};
fn overwrite(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        try expect(n > 0);
        offset += @intCast(n);
    }
}
fn read(path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        try expect(n >= 0);
        if (n == 0) return out.toOwnedSlice(a);
        try out.appendSlice(a, buf[0..@intCast(n)]);
        try expect(out.items.len <= model.limits.session_bytes);
    }
}
fn exists(path: [:0]const u8) bool {
    const fd = std.c.open(path, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}
fn wait(pid: c_int, code: c_int) !void {
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
    }
    try equal(code << 8, status);
}
fn expectStored(h: *Home, id: fs.Id, value: model.Value) !void {
    const owned = try fs.load(h.state, id);
    defer owned.deinit();
    try expectValue(value, owned.value);
}
fn expectPreserved(h: *Home, id: fs.Id, err: anyerror) !void {
    try expectError(err, fs.load(h.state, id));
    try expectError(err, fs.save(h.state, id, changed(), true));
    try expectError(err, fs.setReopen(h.state, id, false));
    try expectError(err, fs.forget(h.state, id));
}

test "secure hex IDs, missing directories read-only, invalid IDs and missing state home" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    const other = try fs.newId();
    try expect(!std.mem.eql(u8, &id, &other));
    for (id) |ch| try expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 0), catalog.records.len);
    try expectError(error.NotFound, fs.load(h.state, id));
    try expectError(error.NotFound, fs.setReopen(h.state, id, true));
    try expectError(error.NotFound, fs.forget(h.state, id));
    try expectError(error.Conflict, fs.forgetIfUnchanged(h.state, id, 1));
    const coral = try h.path("coral");
    defer a.free(coral);
    try expect(!exists(coral));
    const missing = try h.path("missing");
    defer a.free(missing);
    try expectError(error.MissingStateHome, fs.save(missing, id, sample, true));
    var missing_catalog = try fs.list(missing);
    defer missing_catalog.deinit();
    try equal(@as(usize, 0), missing_catalog.records.len);
    const invalid: fs.Id = @splat('/');
    try expectError(error.InvalidId, fs.save(h.state, invalid, sample, true));
    try expectError(error.InvalidId, fs.load(h.state, invalid));
    try expectError(error.InvalidId, fs.forget(h.state, invalid));
    try expectError(error.InvalidId, fs.setReopen(h.state, invalid, false));
}

test "owned roundtrip, exact project identity, distinct windows, monotonic latest and startup metadata" {
    var h = try Home.init();
    defer h.deinit();
    const one = try fs.newId();
    const two = try fs.newId();
    const three = try fs.newId();
    try fs.save(h.state, one, sample, true);
    try fs.save(h.state, two, changed(), false);
    var folder = sample;
    folder.workspace.?.source = .folder;
    try fs.save(h.state, three, folder, true);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 3), catalog.records.len);
    try bytesEqual(&three, &catalog.records[0].id);
    try bytesEqual(&two, &catalog.records[1].id);
    try bytesEqual(&one, &catalog.records[2].id);
    try equal(fs.Source.manifest, catalog.records[1].source.?);
    try bytesEqual(sample.workspace.?.path, catalog.records[1].path.?);
    try bytesEqual("日本語", catalog.records[1].label);
    try equal(@as(usize, 2), catalog.records[1].root_count);
    try expect(!catalog.records[1].reopen and catalog.records[2].reopen);
    try expect(catalog.records[0].updated > catalog.records[1].updated);
    try fs.setReopen(h.state, one, false);
    var after = try fs.list(h.state);
    defer after.deinit();
    try equal(catalog.records[2].updated, after.records[2].updated);
    try expect(!after.records[2].reopen);
    try expectStored(&h, one, sample);
    try expectStored(&h, two, changed());
    try expectError(error.IdentityMismatch, fs.save(h.state, one, folder, true));
    var alias = sample;
    alias.workspace.?.path = "/\xff.coral";
    try expectError(error.IdentityMismatch, fs.save(h.state, one, alias, true));
    const alias_id = try fs.newId();
    try fs.save(h.state, alias_id, alias, false);
    try fs.save(h.state, one, changed(), true);
    var latest = try fs.list(h.state);
    defer latest.deinit();
    try bytesEqual(&one, &latest.records[0].id);
    try expect(latest.records[0].updated > catalog.records[0].updated);
    // The earlier owned catalog stays valid after subsequent writes.
    try bytesEqual(sample.workspace.?.path, catalog.records[1].path.?);
}

test "untitled metadata, roots never truncated, immutable IDs and explicit sessions remain independent" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try explicit.save(h.state, sample);
    try fs.save(h.state, id, empty, true);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 1), catalog.records.len);
    try expect(catalog.records[0].source == null and catalog.records[0].path == null);
    try bytesEqual("Untitled", catalog.records[0].label);
    try equal(@as(usize, 0), catalog.records[0].root_count);
    const roots: [model.limits.roots + 1]model.Root = @splat(.{ .path = "/root", .name = "root" });
    var value = sample;
    value.workspace.?.roots = &roots;
    try expectError(error.TooLarge, fs.save(h.state, try fs.newId(), value, false));
    try fs.forget(h.state, id);
    try expectError(error.NotFound, fs.load(h.state, id));
    const saved = try explicit.load(h.state);
    defer saved.deinit();
    try expectValue(sample, saved.value);
}

test "compare and save rejects stale captures, absent collisions and forgotten generations" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.saveIfUnchanged(h.state, id, sample, true, null);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    const generation = catalog.records[0].updated;
    try expectError(error.Conflict, fs.saveIfUnchanged(h.state, id, changed(), false, null));
    try fs.setReopen(h.state, id, false);
    try fs.saveIfUnchanged(h.state, id, changed(), false, generation);
    try expectError(error.Conflict, fs.saveIfUnchanged(h.state, id, sample, true, generation));
    try expectStored(&h, id, changed());
    try fs.forget(h.state, id);
    try expectError(error.Conflict, fs.saveIfUnchanged(h.state, id, sample, true, generation));
    try fs.saveIfUnchanged(h.state, id, sample, true, null);
    var after = try fs.list(h.state);
    defer after.deinit();
    try expect(after.records[0].updated > generation);
}

test "64 sessions and 16 startup windows fail explicitly, membership and forget free capacity" {
    var h = try Home.init();
    defer h.deinit();
    var ids: [fs.limits.sessions]fs.Id = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try fs.newId();
        try fs.save(h.state, id.*, empty, i < fs.limits.startup_windows);
    }
    try expectError(error.TooManySessions, fs.save(h.state, try fs.newId(), empty, false));
    try expectError(error.TooManyStartupWindows, fs.setReopen(h.state, ids[16], true));
    try expectError(error.TooManyStartupWindows, fs.save(h.state, ids[16], empty, true));
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 64), catalog.records.len);
    try fs.setReopen(h.state, ids[0], false);
    try fs.setReopen(h.state, ids[16], true);
    try fs.forget(h.state, ids[1]);
    const replacement = try fs.newId();
    try fs.save(h.state, replacement, sample, true);
    try expectStored(&h, ids[0], empty);
    try expectStored(&h, replacement, sample);
    try expectError(error.NotFound, fs.load(h.state, ids[1]));
}

test "global budget includes publication headroom and indexes, never evicts dirty snapshots" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try equal(@as(usize, 256 * 1024 * 1024), fs.limits.bytes);
    try fs.save(h.state, id, sample, true);
    const old = try model.encode(a, sample);
    defer a.free(old);
    const next = try model.encode(a, changed());
    defer a.free(next);
    const required = 2 * fs.limits.index_bytes + old.len + next.len;
    try expectError(error.ByteBudgetExceeded, fs.saveWithHooks(h.state, id, changed(), true, .{ .byte_budget = required - 1 }));
    try expectStored(&h, id, sample);
    try fs.saveWithHooks(h.state, id, changed(), true, .{ .byte_budget = required });
    try expectStored(&h, id, changed());
}

test "atomic faults preserve old references until index commit and retain immutable predecessor" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    for ([_]fs.Fault{ .during_snapshot, .after_snapshot, .during_index, .before_commit, .after_commit }) |fault| {
        try fs.save(h.state, id, sample, true);
        const old = try h.snapshotPath(id);
        defer a.free(old);
        try expectError(if (fault == .after_commit) error.DurabilityUncertain else error.InjectedFailure, fs.saveWithHooks(h.state, id, changed(), false, .{ .fault = fault }));
        try expect(exists(old));
        try expectStored(&h, id, if (fault == .after_commit) changed() else sample);
        var catalog = try fs.list(h.state);
        defer catalog.deinit();
        try equal(fault != .after_commit, catalog.records[0].reopen);
        try fs.save(h.state, id, changed(), true);
        try expectStored(&h, id, changed());
    }
}

test "process death at each publication stage releases lock, never promotes uncommitted first save" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    for ([_]fs.Fault{ .during_snapshot, .after_snapshot, .during_index, .before_commit, .after_commit }) |fault| {
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(15);
            fs.saveWithHooks(h.state, id, sample, true, .{ .fault = fault, .terminate_process = true }) catch std.c._exit(74);
            std.c._exit(75);
        }
        try wait(pid, 73);
        if (fault == .after_commit) {
            try expectStored(&h, id, sample);
        } else {
            try expectError(error.NotFound, fs.load(h.state, id));
            var catalog = try fs.list(h.state);
            defer catalog.deinit();
            try equal(@as(usize, 0), catalog.records.len);
        }
    }
    // A subsequent writer stabilizes the possibly uncertain index, then cleans.
    try fs.save(h.state, id, changed(), true);
    try expectStored(&h, id, changed());
    for ([_]fs.Fault{ .during_snapshot, .after_snapshot, .during_index, .before_commit, .after_commit }) |fault| {
        try fs.save(h.state, id, sample, true);
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(15);
            fs.saveWithHooks(h.state, id, changed(), true, .{ .fault = fault, .terminate_process = true }) catch std.c._exit(74);
            std.c._exit(75);
        }
        try wait(pid, 73);
        try expectStored(&h, id, if (fault == .after_commit) changed() else sample);
    }
}

test "cross-process nonblocking directory locks protect readers against publication and reclamation" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.path("coral/projects");
    defer a.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    for ([_]c_int{ std.c.LOCK.EX, std.c.LOCK.SH }) |kind| {
        try equal(@as(c_int, 0), std.c.flock(fd, kind | std.c.LOCK.NB));
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(15);
            expectError(error.Busy, fs.save(h.state, id, changed(), false)) catch std.c._exit(81);
            expectError(error.Busy, fs.setReopen(h.state, id, false)) catch std.c._exit(82);
            expectError(error.Busy, fs.forget(h.state, id)) catch std.c._exit(83);
            if (kind == std.c.LOCK.EX) {
                expectError(error.Busy, fs.load(h.state, id)) catch std.c._exit(84);
                expectError(error.Busy, fs.list(h.state)) catch std.c._exit(85);
            } else {
                const owned = fs.load(h.state, id) catch std.c._exit(86);
                owned.deinit();
            }
            std.c._exit(0);
        }
        try wait(pid, 0);
        try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.UN));
    }
    try fs.save(h.state, id, changed(), false);
    try expectStored(&h, id, changed());
}

test "corrupt future truncated and oversized indexes are preserved by every API" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.projectPath("index");
    defer a.free(path);
    const original = try read(path);
    defer a.free(original);
    inline for (.{ .{ "bad index", error.CorruptStore }, .{ "CORAL-PROJECTS 99\nfuture data", error.UnsupportedVersion }, .{ "CORAL-PROJECTS 1\n", error.CorruptStore } }) |case| {
        try overwrite(path, case[0]);
        try expectError(case[1], fs.list(h.state));
        try expectPreserved(&h, id, case[1]);
        const after = try read(path);
        defer a.free(after);
        try bytesEqual(case[0], after);
    }
    try overwrite(path, original);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.ftruncate(fd, fs.limits.index_bytes + 1));
    try expectError(error.TooLarge, fs.list(h.state));
    try expectPreserved(&h, id, error.TooLarge);
}

test "valid checksum index rejects unknown flags, metadata, trailing bytes, counts and duplicate records" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.projectPath("index");
    defer a.free(path);
    const original = try read(path);
    defer a.free(original);
    const entry = fs.testing.index_prefix + 10;
    const source = entry + 32 + 32 + 32 + 8 + 8;
    for ([_]usize{ entry, source, source + 1 }) |offset| {
        const mutated = try a.dupe(u8, original);
        defer a.free(mutated);
        mutated[offset] = 255;
        fs.testing.rechecksum(mutated);
        try overwrite(path, mutated);
        try expectPreserved(&h, id, error.CorruptStore);
    }
    const roots = try a.dupe(u8, original);
    defer a.free(roots);
    roots[source + 2] = 33;
    fs.testing.rechecksum(roots);
    try overwrite(path, roots);
    try expectPreserved(&h, id, error.TooLarge);
    const extra = try std.mem.concat(a, u8, &.{ original, "unknown trailing field" });
    defer a.free(extra);
    fs.testing.rechecksum(extra);
    try overwrite(path, extra);
    try expectPreserved(&h, id, error.CorruptStore);
    const duplicate = try std.mem.concat(a, u8, &.{ original, original[entry..] });
    defer a.free(duplicate);
    std.mem.writeInt(u16, duplicate[fs.testing.index_prefix + 8 ..][0..2], 2, .little);
    fs.testing.rechecksum(duplicate);
    try overwrite(path, duplicate);
    try expectPreserved(&h, id, error.CorruptStore);
    std.mem.writeInt(u16, duplicate[fs.testing.index_prefix + 8 ..][0..2], 65, .little);
    fs.testing.rechecksum(duplicate);
    try overwrite(path, duplicate);
    try expectPreserved(&h, id, error.TooManySessions);
}

test "catalog never reads payloads; corrupt future missing and substituted snapshots cannot be overwritten or forgotten" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.snapshotPath(id);
    defer a.free(path);
    inline for (.{ .{ "broken snapshot", error.CorruptSession }, .{ "CORAL-SESSION 99\nfuture", error.UnsupportedVersion } }) |case| {
        try overwrite(path, case[0]);
        var catalog = try fs.list(h.state);
        defer catalog.deinit();
        try equal(@as(usize, 1), catalog.records.len);
        try expectPreserved(&h, id, case[1]);
        const kept = try read(path);
        defer a.free(kept);
        try bytesEqual(case[0], kept);
    }
    const valid_but_different = try model.encode(a, changed());
    defer a.free(valid_but_different);
    try overwrite(path, valid_but_different);
    try expectPreserved(&h, id, error.CorruptStore);
    try equal(@as(c_int, 0), std.c.unlink(path));
    try expectPreserved(&h, id, error.MissingSnapshot);
}

test "private modes, owner checks, single links and oversized snapshots are required" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const snapshot = try h.snapshotPath(id);
    defer a.free(snapshot);
    const index = try h.projectPath("index");
    defer a.free(index);
    for ([_][:0]const u8{ snapshot, index }) |path| {
        try equal(@as(c_int, 0), std.c.chmod(path, 0o640));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), std.c.chmod(path, 0o600));
        const alias = try h.path("hardlink");
        defer a.free(alias);
        try equal(@as(c_int, 0), std.c.link(path, alias));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), std.c.unlink(alias));
    }
    for ([_][]const u8{ "coral", "coral/projects" }) |suffix| {
        const path = try h.path(suffix);
        defer a.free(path);
        try equal(@as(c_int, 0), std.c.chmod(path, 0o750));
        try expectPreserved(&h, id, error.UnsafeDirectory);
        try equal(@as(c_int, 0), std.c.chmod(path, 0o700));
    }
    try equal(@as(c_int, 0), std.c.chmod(h.state, 0o777));
    try expectPreserved(&h, id, error.UnsafeDirectory);
    try equal(@as(c_int, 0), std.c.chmod(h.state, 0o700));
    // Privileged test runs can additionally exercise a foreign owner.
    if (std.c.geteuid() == 0) {
        try equal(@as(c_int, 0), chown(snapshot, 65534, 65534));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), chown(snapshot, 0, 0));
    }
    const fd = std.c.open(snapshot, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.ftruncate(fd, model.limits.session_bytes + 1));
    try expectPreserved(&h, id, error.TooLarge);
}

test "symlink fifo and directory snapshots or indexes are refused without blocking or following" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    try h.fixture.write("outside", "untouched");
    const target = try h.fixture.path("outside");
    defer a.free(target);
    const snapshot = try h.snapshotPath(id);
    defer a.free(snapshot);
    const index = try h.projectPath("index");
    defer a.free(index);
    for ([_][:0]const u8{ snapshot, index }) |path| {
        const original = try read(path);
        defer a.free(original);
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), std.c.symlink(target, path));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), mkfifo(path, 0o600));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), std.c.unlink(path));
        try equal(@as(c_int, 0), std.c.mkdir(path, 0o700));
        try expectPreserved(&h, id, error.UnsafeFile);
        try equal(@as(c_int, 0), std.c.rmdir(path));
        try overwrite(path, original);
    }
    const kept = try read(target);
    defer a.free(kept);
    try bytesEqual("untouched", kept);
}

test "search-only ancestors, symlinked state and private directories are rejected" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    try equal(@as(c_int, 0), std.c.chmod(h.fixture.base, 0o100));
    defer _ = std.c.chmod(h.fixture.base, 0o700);
    try expectStored(&h, id, sample);
    try fs.save(h.state, id, changed(), true);
    try equal(@as(c_int, 0), std.c.chmod(h.fixture.base, 0o700));
    try h.fixture.symlink(h.state, "alias");
    const alias = try h.fixture.path("alias");
    defer a.free(alias);
    try expectError(error.UnsafeDirectory, fs.list(alias));
    try expectError(error.UnsafeDirectory, fs.save(alias, id, sample, true));
    try h.fixture.mkdir("outside-dir");
    const target = try h.fixture.path("outside-dir");
    defer a.free(target);
    for ([_][]const u8{ "coral/projects", "coral" }) |suffix| {
        const original = try h.path(suffix);
        defer a.free(original);
        const moved = try std.fmt.allocPrintSentinel(a, "{s}.held", .{original}, 0);
        defer a.free(moved);
        try equal(@as(c_int, 0), std.c.renameat(std.c.AT.FDCWD, original, std.c.AT.FDCWD, moved));
        defer _ = std.c.renameat(std.c.AT.FDCWD, moved, std.c.AT.FDCWD, original);
        try equal(@as(c_int, 0), std.c.symlink(target, original));
        defer _ = std.c.unlink(original);
        try expectPreserved(&h, id, error.UnsafeDirectory);
    }
}

test "cleanup preserves unknown unsafe corrupt future and linked orphans; bounded enumeration" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const unknown = try h.projectPath("unknown-evidence");
    defer a.free(unknown);
    try overwrite(unknown, "preserve");
    try expectError(error.UnexpectedEntry, fs.save(h.state, id, changed(), true));
    try expect(exists(unknown));
    try equal(@as(c_int, 0), std.c.unlink(unknown));
    const orphan = try h.projectPath("00000000000000000000000000000000.snap");
    defer a.free(orphan);
    inline for (.{ .{ "corrupt orphan", error.CorruptSession }, .{ "CORAL-SESSION 99\nfuture orphan", error.UnsupportedVersion } }) |case| {
        try overwrite(orphan, case[0]);
        try expectError(case[1], fs.save(h.state, id, changed(), true));
        const kept = try read(orphan);
        defer a.free(kept);
        try bytesEqual(case[0], kept);
        try expectStored(&h, id, sample);
    }
    try equal(@as(c_int, 0), std.c.unlink(orphan));
    const pending = try h.projectPath("snapshot.pending");
    defer a.free(pending);
    for ([_][2][]const u8{ .{ "snapshot.pending", "CORAL-SESSION 99\nfuture scratch" }, .{ "index.pending", "CORAL-PROJECTS 99\nfuture scratch" } }) |case| {
        const path = try h.projectPath(case[0]);
        defer a.free(path);
        try overwrite(path, case[1]);
        try expectError(error.UnsupportedVersion, fs.save(h.state, id, changed(), true));
        const kept = try read(path);
        defer a.free(kept);
        try bytesEqual(case[1], kept);
        try equal(@as(c_int, 0), std.c.unlink(path));
    }
    const current = try h.snapshotPath(id);
    defer a.free(current);
    try equal(@as(c_int, 0), std.c.symlink(current, pending));
    try expectError(error.UnsafeFile, fs.save(h.state, id, changed(), true));
    try expect(exists(pending));
    try equal(@as(c_int, 0), std.c.unlink(pending));
    try equal(@as(c_int, 0), std.c.link(current, orphan));
    try expectError(error.UnsafeFile, fs.save(h.state, id, changed(), true));
    try equal(@as(c_int, 0), std.c.unlink(orphan));
    // Known complete unreferenced sessions are reclaimable; partial scratch too.
    const bytes = try model.encode(a, empty);
    defer a.free(bytes);
    try overwrite(orphan, bytes);
    try overwrite(pending, "incomplete reserved scratch");
    try fs.save(h.state, id, changed(), true);
    try expect(!exists(orphan) and !exists(pending));
    for (0..fs.limits.directory_entries) |i| {
        const name = try std.fmt.allocPrint(a, "unknown-{d}", .{i});
        defer a.free(name);
        const path = try h.projectPath(name);
        defer a.free(path);
        try overwrite(path, "");
    }
    try expectError(error.TooManyStoreFiles, fs.save(h.state, id, sample, true));
    try expectStored(&h, id, changed());
}

test "membership and forget faults commit atomically without changing snapshot recency" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    for ([_]?bool{ false, null }) |membership| {
        for ([_]fs.Fault{ .during_index, .before_commit, .after_commit }) |fault| {
            try fs.save(h.state, id, sample, true);
            const old = try h.snapshotPath(id);
            defer a.free(old);
            var before = try fs.list(h.state);
            defer before.deinit();
            try expectError(if (fault == .after_commit) error.DurabilityUncertain else error.InjectedFailure, fs.testing.membershipWithHooks(h.state, id, membership, .{ .fault = fault }));
            try expect(exists(old));
            var after = try fs.list(h.state);
            defer after.deinit();
            if (membership == null and fault == .after_commit) {
                try equal(@as(usize, 0), after.records.len);
                try expectError(error.NotFound, fs.load(h.state, id));
            } else {
                try equal(before.records[0].updated, after.records[0].updated);
                try equal(fault != .after_commit, after.records[0].reopen);
                try expectStored(&h, id, sample);
            }
        }
    }
}

test "checksum tampering and valid-checksum metadata mismatch preserve the committed payload" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.projectPath("index");
    defer a.free(path);
    const original = try read(path);
    defer a.free(original);
    const modified = try a.dupe(u8, original);
    defer a.free(modified);
    const roots = fs.testing.index_prefix + 10 + 32 + 32 + 32 + 8 + 8 + 2;
    modified[roots] = 3;
    try overwrite(path, modified);
    try expectError(error.CorruptStore, fs.list(h.state));
    try expectPreserved(&h, id, error.CorruptStore);
    fs.testing.rechecksum(modified);
    try overwrite(path, modified);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 3), catalog.records[0].root_count);
    try expectPreserved(&h, id, error.CorruptStore);
    try overwrite(path, original);
    const snapshot = try h.snapshotPath(id);
    defer a.free(snapshot);
    const payload = try read(snapshot);
    defer a.free(payload);
    payload[payload.len - 1] ^= 1;
    try overwrite(snapshot, payload);
    try expectPreserved(&h, id, error.CorruptSession);
}

test "index enforces the real global byte ceiling, startup bound and generation exhaustion" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try h.projectPath("index");
    defer a.free(path);
    const original = try read(path);
    defer a.free(original);
    const start = fs.testing.index_prefix + 10;
    const entry_len = original.len - start;
    const count = 20;
    const forged = try a.alloc(u8, start + count * entry_len);
    defer a.free(forged);
    @memcpy(forged[0..start], original[0..start]);
    std.mem.writeInt(i64, forged[fs.testing.index_prefix..][0..8], count, .little);
    std.mem.writeInt(u16, forged[fs.testing.index_prefix + 8 ..][0..2], count, .little);
    for (0..count) |i| {
        const entry = forged[start + i * entry_len ..][0..entry_len];
        @memcpy(entry, original[start..]);
        @memcpy(entry[0..32], &try fs.newId());
        @memcpy(entry[32..64], &try fs.newId());
        std.mem.writeInt(u64, entry[96..][0..8], model.limits.session_bytes, .little);
        std.mem.writeInt(i64, entry[104..][0..8], @intCast(i + 1), .little);
        entry[113] = 0;
    }
    fs.testing.rechecksum(forged);
    try overwrite(path, forged);
    try expectError(error.ByteBudgetExceeded, fs.list(h.state));
    try expectPreserved(&h, id, error.ByteBudgetExceeded);
    for (0..count) |i| {
        const entry = forged[start + i * entry_len ..][0..entry_len];
        std.mem.writeInt(u64, entry[96..][0..8], 1, .little);
        entry[113] = 1;
    }
    fs.testing.rechecksum(forged);
    try overwrite(path, forged);
    try expectError(error.TooManyStartupWindows, fs.list(h.state));
    try expectPreserved(&h, id, error.TooManyStartupWindows);
    std.mem.writeInt(i64, original[fs.testing.index_prefix..][0..8], std.math.maxInt(i64), .little);
    fs.testing.rechecksum(original);
    try overwrite(path, original);
    try expectError(error.GenerationExhausted, fs.save(h.state, id, changed(), true));
    try expectStored(&h, id, sample);
    try fs.setReopen(h.state, id, false);
    try fs.forget(h.state, id);
}

test "XDG state home and empty-XDG HOME fallback resolve the private projects store" {
    var h = try Home.init();
    defer h.deinit();
    try h.fixture.mkdir(".local");
    try h.fixture.mkdir(".local/state");
    const fallback = try h.fixture.path(".local/state");
    a.free(h.state);
    h.state = fallback;
    const old_xdg = if (getenv("XDG_STATE_HOME")) |p| try a.dupeSentinel(u8, std.mem.span(p), 0) else null;
    defer if (old_xdg) |p| {
        _ = setenv("XDG_STATE_HOME", p, 1);
        a.free(p);
    } else {
        _ = unsetenv("XDG_STATE_HOME");
    };
    const old_home = if (getenv("HOME")) |p| try a.dupeSentinel(u8, std.mem.span(p), 0) else null;
    defer if (old_home) |p| {
        _ = setenv("HOME", p, 1);
        a.free(p);
    } else {
        _ = unsetenv("HOME");
    };
    try equal(@as(c_int, 0), setenv("XDG_STATE_HOME", h.state, 1));
    const id = try fs.newId();
    try fs.save(null, id, sample, true);
    try expectStored(&h, id, sample);
    try equal(@as(c_int, 0), setenv("HOME", h.fixture.base, 1));
    try equal(@as(c_int, 0), setenv("XDG_STATE_HOME", "", 1));
    const owned = try fs.load(null, id);
    defer owned.deinit();
    try expectValue(sample, owned.value);
    try fs.save(null, id, changed(), false);
    try expectStored(&h, id, changed());
    try equal(@as(c_int, 0), setenv("XDG_STATE_HOME", "relative-is-invalid", 1));
    try expectError(error.InvalidPath, fs.list(null));
    // Explicit state_home never consults the environment override.
    try expectStored(&h, id, changed());
}

test "fresh startup clones transfer membership atomically at 16 windows without deleting recents" {
    var h = try Home.init();
    defer h.deinit();
    for (0..fs.limits.startup_windows) |_| try fs.save(h.state, try fs.newId(), sample, true);
    var before = try fs.list(h.state);
    defer before.deinit();
    const from = before.records[0];
    for ([_]fs.Fault{ .during_snapshot, .after_snapshot, .during_index, .before_commit }) |fault| {
        const id = try fs.newId();
        try expectError(error.InjectedFailure, fs.testing.cloneWithHooks(h.state, id, from.id, sample, from.updated, .{ .fault = fault }));
        try expectError(error.NotFound, fs.load(h.state, id));
        var after = try fs.list(h.state);
        defer after.deinit();
        try equal(@as(usize, 16), after.records.len);
        for (after.records) |r| try expect(r.reopen);
    }
    const id = try fs.newId();
    try expectError(error.DurabilityUncertain, fs.testing.cloneWithHooks(h.state, id, from.id, sample, from.updated, .{ .fault = .after_commit }));
    try expectStored(&h, id, sample);
    try expectStored(&h, from.id, sample);
    var after = try fs.list(h.state);
    defer after.deinit();
    try equal(@as(usize, 17), after.records.len);
    try bytesEqual(&id, &after.records[0].id);
    try expect(after.records[0].reopen);
    var startup: usize = 0;
    for (after.records) |r| {
        if (r.reopen) startup += 1;
        if (std.mem.eql(u8, &r.id, &from.id)) {
            try expect(!r.reopen);
            try equal(from.updated, r.updated);
        }
    }
    try equal(@as(usize, 16), startup);
    try expectError(error.Conflict, fs.saveClone(h.state, try fs.newId(), from.id, sample, from.updated));
    try expectError(error.Conflict, fs.saveClone(h.state, id, after.records[0].id, sample, after.records[0].updated));
    try expectError(error.Conflict, fs.saveClone(h.state, try fs.newId(), id, sample, from.updated));
    try expectError(error.IdentityMismatch, fs.saveClone(h.state, try fs.newId(), id, empty, after.records[0].updated));
    try fs.saveClone(h.state, try fs.newId(), id, sample, after.records[0].updated);
}

test "cross-process startup clones reject a previously consumed membership" {
    var h = try Home.init();
    defer h.deinit();
    const from = try fs.newId();
    try fs.save(h.state, from, empty, true);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    const generation = catalog.records[0].updated;
    const first = try fs.newId();
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(15);
        fs.saveClone(h.state, first, from, empty, generation) catch std.c._exit(81);
        std.c._exit(0);
    }
    try wait(pid, 0);
    try expectError(error.Conflict, fs.saveClone(h.state, try fs.newId(), from, empty, generation));
    try expectStored(&h, first, empty);
    try expectStored(&h, from, empty);
}

fn leasePath(h: *Home, id: fs.Id) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/coral/projects/{s}.lease", .{ h.state, id }, 0);
}
fn recordFor(catalog: *const fs.Catalog, id: fs.Id) !fs.Record {
    for (catalog.records) |r| if (std.mem.eql(u8, &r.id, &id)) return r;
    return error.NotFound;
}
fn leaseCount(h: *Home) !usize {
    const path = try h.path("coral/projects");
    defer a.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    try expect(fd >= 0);
    const stream = std.c.fdopendir(fd) orelse {
        _ = std.c.close(fd);
        return error.Io;
    };
    defer _ = std.c.closedir(stream);
    var count: usize = 0;
    while (std.c.readdir(stream)) |entry| {
        if (std.mem.endsWith(u8, std.mem.sliceTo(&entry.name, 0), ".lease")) count += 1;
    }
    return count;
}
fn sendByte(fd: c_int) !void {
    const byte: [1]u8 = .{1};
    while (true) {
        const n = std.c.write(fd, &byte, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        try equal(@as(isize, 1), n);
        return;
    }
}
fn receiveByte(fd: c_int) !void {
    var byte: [1]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &byte, 1);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        try equal(@as(isize, 1), n);
        return;
    }
}

test "lifetime reservation adds no record; leased CAS returns exact generation and never resurrects" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    var lease = try fs.claim(h.state, id);
    defer lease.deinit();
    var before = try fs.list(h.state);
    defer before.deinit();
    try equal(@as(usize, 0), before.records.len);
    try expectError(error.NotFound, fs.load(h.state, id));
    try expectError(error.Busy, fs.claim(h.state, id));
    const generation = try fs.saveLeased(h.state, id, sample, true, null, &lease);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(generation, catalog.records[0].updated);
    try expect(catalog.records[0].live);
    try expectError(error.Busy, fs.save(h.state, id, changed(), true));
    try expectError(error.Busy, fs.saveIfUnchanged(h.state, id, changed(), true, generation));
    try expectError(error.Busy, fs.setReopen(h.state, id, false));
    try expectError(error.Busy, fs.forget(h.state, id));
    try expectError(error.Busy, fs.forgetIfUnchanged(h.state, id, generation));
    try expectError(error.Busy, fs.saveClone(h.state, try fs.newId(), id, sample, generation));
    try expectError(error.Conflict, fs.saveLeased(h.state, id, changed(), true, null, &lease));
    const next = try fs.saveLeased(h.state, id, changed(), true, generation, &lease);
    try expect(next > generation);
    try expectError(error.Conflict, fs.saveLeased(h.state, id, sample, true, generation, &lease));
    try fs.setReopenLeased(h.state, id, false, &lease);
    var after = try fs.list(h.state);
    defer after.deinit();
    try equal(next, after.records[0].updated);
    try expect(after.records[0].live and !after.records[0].reopen);
    lease.deinit();
    var released = try fs.list(h.state);
    defer released.deinit();
    try expect(!released.records[0].live);
    try expectError(error.InvalidLease, fs.saveLeased(h.state, id, sample, true, next, &lease));
    try fs.forgetIfUnchanged(h.state, id, next);
    var reserved_again = try fs.claim(h.state, id);
    defer reserved_again.deinit();
    try expectError(error.Conflict, fs.saveLeased(h.state, id, sample, true, next, &reserved_again));
    try expectError(error.NotFound, fs.load(h.state, id));
}

test "two-process lifetime owner excludes every normal writer, claim, startup clone and atomic forget" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    const generation = catalog.records[0].updated;
    var ready: [2]c_int = undefined;
    var release: [2]c_int = undefined;
    try equal(@as(c_int, 0), pipe(&ready));
    defer {
        _ = std.c.close(ready[0]);
        _ = std.c.close(ready[1]);
    }
    try equal(@as(c_int, 0), pipe(&release));
    defer {
        _ = std.c.close(release[0]);
        _ = std.c.close(release[1]);
    }
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(30);
        _ = std.c.close(ready[0]);
        _ = std.c.close(release[1]);
        var lease = fs.claim(h.state, id) catch std.c._exit(81);
        sendByte(ready[1]) catch std.c._exit(82);
        receiveByte(release[0]) catch std.c._exit(83);
        lease.deinit();
        std.c._exit(0);
    }
    try receiveByte(ready[0]);
    var live = try fs.list(h.state);
    defer live.deinit();
    try expect(live.records[0].live and live.records[0].reopen);
    try expectError(error.Busy, fs.claim(h.state, id));
    try expectError(error.Busy, fs.save(h.state, id, changed(), false));
    try expectError(error.Busy, fs.saveIfUnchanged(h.state, id, changed(), false, generation));
    try expectError(error.Busy, fs.setReopen(h.state, id, false));
    try expectError(error.Busy, fs.forget(h.state, id));
    try expectError(error.Busy, fs.forgetIfUnchanged(h.state, id, generation));
    try expectError(error.Busy, fs.saveClone(h.state, try fs.newId(), id, sample, generation));
    try expectStored(&h, id, sample);
    try sendByte(release[1]);
    try wait(pid, 0);
    var closed = try fs.list(h.state);
    defer closed.deinit();
    try expect(!closed.records[0].live and closed.records[0].reopen);
    try fs.forgetIfUnchanged(h.state, id, generation);
    try expectError(error.NotFound, fs.load(h.state, id));
}

test "atomic forget refuses a newer generation committed by another process" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    var before = try fs.list(h.state);
    defer before.deinit();
    const generation = before.records[0].updated;
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(15);
        var lease = fs.claim(h.state, id) catch std.c._exit(81);
        _ = fs.saveLeased(h.state, id, changed(), true, generation, &lease) catch std.c._exit(82);
        lease.deinit();
        std.c._exit(0);
    }
    try wait(pid, 0);
    try expectError(error.Conflict, fs.forgetIfUnchanged(h.state, id, generation));
    try expectStored(&h, id, changed());
    var after = try fs.list(h.state);
    defer after.deinit();
    try expect(after.records[0].updated > generation and !after.records[0].live);
    try fs.forgetIfUnchanged(h.state, id, after.records[0].updated);
    try expectError(error.Conflict, fs.forgetIfUnchanged(h.state, id, after.records[0].updated));
    try expectError(error.NotFound, fs.load(h.state, id));
}

test "leased clone holds both owners and returns committed generation at startup capacity" {
    var h = try Home.init();
    defer h.deinit();
    const from = try fs.newId();
    try fs.save(h.state, from, sample, true);
    for (1..fs.limits.startup_windows) |_| try fs.save(h.state, try fs.newId(), sample, true);
    var before = try fs.list(h.state);
    defer before.deinit();
    const generation = (try recordFor(&before, from)).updated;
    var from_lease = try fs.claim(h.state, from);
    defer from_lease.deinit();
    const id = try fs.newId();
    var new_lease = try fs.claim(h.state, id);
    defer new_lease.deinit();
    try expectError(error.InvalidLease, fs.saveCloneLeased(h.state, id, from, sample, generation, &from_lease, &new_lease));
    try expectError(error.InvalidLease, fs.saveCloneLeased(h.state, id, from, sample, generation, &new_lease, &new_lease));
    try expectError(error.Conflict, fs.saveCloneLeased(h.state, id, from, sample, generation + 1, &new_lease, &from_lease));
    const result = try fs.saveCloneLeased(h.state, id, from, sample, generation, &new_lease, &from_lease);
    var after = try fs.list(h.state);
    defer after.deinit();
    try equal(@as(usize, 17), after.records.len);
    const old = try recordFor(&after, from);
    const new = try recordFor(&after, id);
    try expect(old.live and !old.reopen and new.live and new.reopen);
    try equal(generation, old.updated);
    try equal(result, new.updated);
    try expect(result > generation);
    try expectError(error.Busy, fs.forget(h.state, from));
    try expectError(error.Busy, fs.forget(h.state, id));
    from_lease.deinit();
    try fs.forgetIfUnchanged(h.state, from, generation);
    try expectStored(&h, id, sample);
    _ = try fs.saveLeased(h.state, id, changed(), true, result, &new_lease);
}

test "claim does not promise catalog capacity; failed leased clone preserves source and reservation" {
    var h = try Home.init();
    defer h.deinit();
    const from = try fs.newId();
    try fs.save(h.state, from, empty, true);
    for (1..fs.limits.sessions) |_| try fs.save(h.state, try fs.newId(), empty, false);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    const generation = (try recordFor(&catalog, from)).updated;
    var old_lease = try fs.claim(h.state, from);
    defer old_lease.deinit();
    const id = try fs.newId();
    var new_lease = try fs.claim(h.state, id);
    defer new_lease.deinit();
    try expectError(error.TooManySessions, fs.saveCloneLeased(h.state, id, from, empty, generation, &new_lease, &old_lease));
    try expectError(error.NotFound, fs.load(h.state, id));
    try expectError(error.Busy, fs.claim(h.state, id));
    var after = try fs.list(h.state);
    defer after.deinit();
    try equal(@as(usize, 64), after.records.len);
    try expect((try recordFor(&after, from)).reopen);
}

test "lease validation binds process, ID, store and current file inode" {
    var h = try Home.init();
    defer h.deinit();
    var other_home = try Home.init();
    defer other_home.deinit();
    const id = try fs.newId();
    const other = try fs.newId();
    var lease = try fs.claim(h.state, id);
    defer lease.deinit();
    const generation = try fs.saveLeased(h.state, id, sample, true, null, &lease);
    try expectError(error.InvalidLease, fs.saveLeased(h.state, other, sample, true, null, &lease));
    try expectError(error.InvalidLease, fs.saveLeased(other_home.state, id, sample, true, null, &lease));
    try expectError(error.InvalidLease, fs.setReopenLeased(h.state, other, false, &lease));
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(15);
        expectError(error.InvalidLease, fs.saveLeased(h.state, id, changed(), true, generation, &lease)) catch std.c._exit(81);
        lease.deinit(); // close only: must not unlock the parent's OFD
        std.c._exit(0);
    }
    try wait(pid, 0);
    try expectError(error.Busy, fs.claim(h.state, id));
    const path = try leasePath(&h, id);
    defer a.free(path);
    const moved = try h.projectPath("held-lease-evidence");
    defer a.free(moved);
    try equal(@as(c_int, 0), std.c.renameat(std.c.AT.FDCWD, path, std.c.AT.FDCWD, moved));
    try overwrite(path, "");
    try expectError(error.InvalidLease, fs.saveLeased(h.state, id, changed(), true, generation, &lease));
    try expectError(error.InvalidLease, fs.setReopenLeased(h.state, id, false, &lease));
    try expectStored(&h, id, sample);
    try equal(@as(c_int, 0), std.c.unlink(path));
    try equal(@as(c_int, 0), std.c.renameat(std.c.AT.FDCWD, moved, std.c.AT.FDCWD, path));
    _ = try fs.saveLeased(h.state, id, changed(), true, generation, &lease);
}

test "bounded lease cleanup preserves live reservations and reclaims abandoned IDs without split locks" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    var held = try fs.claim(h.state, id);
    defer held.deinit();
    for (0..fs.limits.leases * 2) |_| {
        var temporary = try fs.claim(h.state, try fs.newId());
        temporary.deinit();
        try expect((try leaseCount(&h)) <= 2);
    }
    try expectError(error.Busy, fs.claim(h.state, id));
    _ = try fs.saveLeased(h.state, id, sample, true, null, &held);
    const orphan = try fs.newId();
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(15);
        _ = fs.claim(h.state, orphan) catch std.c._exit(81);
        std.c._exit(0); // Process death, without deinit.
    }
    try wait(pid, 0);
    var recovered = try fs.claim(h.state, orphan);
    recovered.deinit();
    try expectError(error.Busy, fs.claim(h.state, id));
    try expect((try leaseCount(&h)) <= 2);
}

test "lease capacity is finite and can be reclaimed after release" {
    var h = try Home.init();
    defer h.deinit();
    var held: [fs.limits.leases]fs.Lease = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |*lease| lease.deinit();
    for (&held) |*lease| {
        lease.* = try fs.claim(h.state, try fs.newId());
        count += 1;
    }
    try expectError(error.TooManyLeases, fs.claim(h.state, try fs.newId()));
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 0), catalog.records.len);
    try equal(@as(usize, fs.limits.leases), try leaseCount(&h));
    held[0].deinit();
    held[0] = try fs.claim(h.state, try fs.newId());
    try equal(@as(usize, fs.limits.leases), try leaseCount(&h));
    try expectError(error.Busy, fs.claim(h.state, held[1].id));
}

test "lease files reject modes hardlinks symlinks fifo directories and unexpected content" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    try fs.save(h.state, id, sample, true);
    const path = try leasePath(&h, id);
    defer a.free(path);
    try equal(@as(c_int, 0), std.c.chmod(path, 0o640));
    try expectError(error.UnsafeFile, fs.claim(h.state, id));
    try expectError(error.UnsafeFile, fs.list(h.state));
    try expectError(error.UnsafeFile, fs.save(h.state, id, changed(), true));
    try equal(@as(c_int, 0), std.c.chmod(path, 0o600));
    const alias = try h.projectPath("lease-alias");
    defer a.free(alias);
    try equal(@as(c_int, 0), std.c.link(path, alias));
    try expectError(error.UnsafeFile, fs.claim(h.state, id));
    try equal(@as(c_int, 0), std.c.unlink(alias));
    try overwrite(path, "unsupported lease content");
    try expectError(error.CorruptStore, fs.claim(h.state, id));
    try expectError(error.CorruptStore, fs.list(h.state));
    try expectError(error.CorruptStore, fs.forget(h.state, id));
    const kept = try read(path);
    defer a.free(kept);
    try bytesEqual("unsupported lease content", kept);
    try equal(@as(c_int, 0), std.c.unlink(path));
    const index = try h.projectPath("index");
    defer a.free(index);
    try equal(@as(c_int, 0), std.c.symlink(index, path));
    try expectError(error.UnsafeFile, fs.claim(h.state, id));
    try expectError(error.UnsafeFile, fs.list(h.state));
    try equal(@as(c_int, 0), std.c.unlink(path));
    try equal(@as(c_int, 0), mkfifo(path, 0o600));
    try expectError(error.UnsafeFile, fs.claim(h.state, id));
    try expectError(error.UnsafeFile, fs.list(h.state));
    try equal(@as(c_int, 0), std.c.unlink(path));
    try equal(@as(c_int, 0), std.c.mkdir(path, 0o700));
    try expectError(error.UnsafeFile, fs.claim(h.state, id));
    try equal(@as(c_int, 0), std.c.rmdir(path));
    try expectStored(&h, id, sample);
}

test "lifetime-holder APIs and atomic forget still preserve unsupported snapshot evidence" {
    var h = try Home.init();
    defer h.deinit();
    const id = try fs.newId();
    var lease = try fs.claim(h.state, id);
    defer lease.deinit();
    const generation = try fs.saveLeased(h.state, id, sample, true, null, &lease);
    const path = try h.snapshotPath(id);
    defer a.free(path);
    const future = "CORAL-SESSION 99\nfuture evidence";
    try overwrite(path, future);
    try expectError(error.UnsupportedVersion, fs.saveLeased(h.state, id, changed(), true, generation, &lease));
    try expectError(error.UnsupportedVersion, fs.setReopenLeased(h.state, id, false, &lease));
    const new_id = try fs.newId();
    var new_lease = try fs.claim(h.state, new_id);
    defer new_lease.deinit();
    try expectError(error.UnsupportedVersion, fs.saveCloneLeased(h.state, new_id, id, sample, generation, &new_lease, &lease));
    lease.deinit();
    try expectError(error.UnsupportedVersion, fs.forgetIfUnchanged(h.state, id, generation));
    const kept = try read(path);
    defer a.free(kept);
    try bytesEqual(future, kept);
    var catalog = try fs.list(h.state);
    defer catalog.deinit();
    try equal(@as(usize, 1), catalog.records.len);
    try expect(!catalog.records[0].live and catalog.records[0].reopen);
}
