const std = @import("std");
const tx = @import("index_transaction.zig");
const t = std.testing;
const c = @import("index_transaction_os.zig");
const Fixture = struct {
    root: [:0]u8,
    gitdir: [:0]u8,
    fd: c_int,
    cancel: tx.Cancel = .init(false),

    fn init() !Fixture {
        var template = "/tmp/coral-index-test-XXXXXX".* ++ [_]u8{0};
        if (c.mkdtemp(&template) == null) return error.FixtureFailed;
        errdefer _ = c.rmdir(&template);
        const root = try t.allocator.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        errdefer t.allocator.free(root);
        const gitdir = try std.fmt.allocPrintSentinel(t.allocator, "{s}/.git", .{root}, 0);
        errdefer t.allocator.free(gitdir);
        const fd = c.open(root, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        var f = Fixture{ .root = root, .gitdir = gitdir, .fd = fd };
        errdefer {
            removeChildren(fd);
            _ = c.close(fd);
        }
        try f.git(&.{ "init", "-q", "--initial-branch=main" });
        try f.git(&.{ "config", "user.name", "Coral fixture" });
        try f.git(&.{ "config", "user.email", "coral-fixture@invalid" });
        return f;
    }
    fn deinit(f: *Fixture) void {
        removeChildren(f.fd);
        _ = c.close(f.fd);
        _ = c.rmdir(f.root);
        t.allocator.free(f.gitdir);
        t.allocator.free(f.root);
    }
    fn output(f: *Fixture, args: []const []const u8) ![]const u8 {
        var cancel = tx.Cancel.init(false);
        const result = try tx.runGit(t.allocator, f.root, null, null, null, null, &cancel, args, "", tx.max_index_bytes, false);
        return result.bytes;
    }
    fn git(f: *Fixture, args: []const []const u8) !void {
        const bytes = try f.output(args);
        t.allocator.free(bytes);
    }
    fn write(f: *Fixture, name: [:0]const u8, bytes: []const u8) !void {
        const fd = c.openat(f.fd, name, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.FixtureFailed;
        defer _ = c.close(fd);
        if (c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.FixtureFailed;
    }
    fn read(f: *Fixture, name: [:0]const u8) ![]u8 {
        const fd = c.openat(f.fd, name, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        defer _ = c.close(fd);
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(t.allocator);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = c.read(fd, &buffer, buffer.len);
            if (n < 0) return error.FixtureFailed;
            if (n == 0) break;
            try bytes.appendSlice(t.allocator, buffer[0..@intCast(n)]);
        }
        return bytes.toOwnedSlice(t.allocator);
    }
    fn expectFile(f: *Fixture, name: [:0]const u8, expected: []const u8) !void {
        const bytes = try f.read(name);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn expectGit(f: *Fixture, args: []const []const u8, expected: []const u8) !void {
        const bytes = try f.output(args);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn baseline(f: *Fixture) !void {
        try f.write("selected", "head\n");
        try f.write("other", "other head\n");
        try f.git(&.{ "add", "--", "selected", "other" });
        // Fixture-only commit, explicit identity/config and no editor/signing/hooks.
        try f.git(&.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "-m", "fixture baseline" });
    }
    fn request(f: *Fixture, path: []const u8, action: tx.Action) tx.Request {
        return .{ .root = f.root, .gitdir = f.gitdir, .commondir = f.gitdir, .path = path, .action = action };
    }
    fn prepare(f: *Fixture, path: []const u8, action: tx.Action) !tx.Prepared {
        return tx.prepare(t.allocator, f.request(path, action), &f.cancel);
    }
    fn mtime(f: *Fixture, name: [:0]const u8, sec: i64, nsec: u32) !void {
        const fd = c.openat(f.fd, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        defer _ = c.close(fd);
        const times = [2]c.Timespec{ .{ .sec = 0, .nsec = c.UTIME_OMIT }, .{ .sec = sec, .nsec = nsec } };
        try t.expectEqual(@as(c_int, 0), c.futimens(fd, &times));
    }
    fn noLock(f: *Fixture) !void {
        var st: c.struct_stat = undefined;
        try t.expect(c.fstatat(f.fd, ".git/index.lock", &st, c.AT_SYMLINK_NOFOLLOW) != 0);
    }
};
fn removeChildren(fd: c_int) void {
    const dir = c.fdopendir(c.dup(fd)) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = c.openat(fd, name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (child >= 0) {
            removeChildren(child);
            _ = c.close(child);
            _ = c.unlinkat(fd, name, c.AT_REMOVEDIR);
        } else _ = c.unlinkat(fd, name, 0);
    }
}

test "stage and unstage preserve unrelated staging and all disk bytes; prepare is read-only" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "reviewed disk\n");
    try f.write("other", "other staged\n");
    try f.git(&.{ "add", "--", "other" });
    try f.write("other", "other unstaged\n");
    const index = try f.read(".git/index");
    defer t.allocator.free(index);
    const objects = try f.output(&.{ "count-objects", "-v" });
    defer t.allocator.free(objects);
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    try t.expectEqualStrings("head\n", p.before);
    try t.expectEqualStrings("reviewed disk\n", p.after);
    try t.expect(p.before_exists and p.after_exists);
    try f.expectFile(".git/index", index);
    try f.expectGit(&.{ "count-objects", "-v" }, objects);
    const outcome = try tx.apply(&p, &f.cancel);
    try t.expect(outcome.committed and !outcome.durability_uncertain);
    try t.expectError(error.AlreadyApplied, tx.apply(&p, &f.cancel));
    try f.expectGit(&.{ "show", ":selected" }, "reviewed disk\n");
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.expectFile("selected", "reviewed disk\n");
    try f.expectFile("other", "other unstaged\n");
    var undo = try f.prepare("selected", .unstage);
    defer undo.deinit();
    try t.expectEqualStrings("reviewed disk\n", undo.before);
    try t.expectEqualStrings("head\n", undo.after);
    try t.expect((try tx.apply(&undo, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.expectFile("selected", "reviewed disk\n");
    try f.noLock();
}

test "unborn new file, literal odd path, stage deletion and unstage new file" {
    var f = try Fixture.init();
    defer f.deinit();
    const path = ":(glob)new\nfile";
    try f.write(path, "new\n");
    var p = try f.prepare(path, .stage);
    defer p.deinit();
    try t.expect(!p.before_exists and p.after_exists);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    var undo = try f.prepare(path, .unstage);
    defer undo.deinit();
    try t.expect(undo.before_exists and !undo.after_exists);
    try t.expect((try tx.apply(&undo, &f.cancel)).committed);
    try f.expectGit(&.{ "ls-files", "-z" }, "");
    try f.baseline();
    try t.expectEqual(@as(c_int, 0), c.unlinkat(f.fd, "selected", 0));
    var deletion = try f.prepare("selected", .stage);
    defer deletion.deinit();
    try t.expect(deletion.before_exists and !deletion.after_exists);
    try t.expect((try tx.apply(&deletion, &f.cancel)).committed);
    try f.expectGit(&.{ "ls-files", "--", "selected" }, "");
    var restore = try f.prepare("selected", .unstage);
    defer restore.deinit();
    try t.expect(!restore.before_exists and restore.after_exists);
    try t.expect((try tx.apply(&restore, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
    var st: c.struct_stat = undefined;
    try t.expect(c.fstatat(f.fd, "selected", &st, c.AT_SYMLINK_NOFOLLOW) != 0);
    try f.noLock();
}

test "foreign index lock remains, cancellation before prepare/apply leaves index unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "disk\n");
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    try f.write(".git/index.lock", "foreign lock");
    try t.expectError(error.IndexLocked, tx.apply(&p, &f.cancel));
    try f.expectFile(".git/index.lock", "foreign lock");
    _ = c.unlinkat(f.fd, ".git/index.lock", 0);
    var q = try f.prepare("selected", .stage);
    defer q.deinit();
    f.cancel.store(true, .release);
    try t.expectError(error.Cancelled, tx.apply(&q, &f.cancel));
    try t.expectError(error.Cancelled, f.prepare("selected", .stage));
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
    try f.noLock();
}

test "same-byte file, index and HEAD replacements invalidate approval" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "disk\n");
    for ([_][:0]const u8{ "selected", ".git/index", ".git/HEAD", ".git/refs/heads/main" }) |name| {
        var p = try f.prepare("selected", .stage);
        defer p.deinit();
        const original = try f.read(name);
        defer t.allocator.free(original);
        try f.write("replacement", original);
        try t.expectEqual(@as(c_int, 0), c.renameat(f.fd, "replacement", f.fd, name));
        try t.expectError(error.StaleSnapshot, tx.apply(&p, &f.cancel));
        try f.noLock();
    }
    var changed = try f.prepare("selected", .stage);
    defer changed.deinit();
    try f.write("other", "unrelated changed index\n");
    try f.git(&.{ "add", "--", "other" });
    try t.expectError(error.StaleSnapshot, tx.apply(&changed, &f.cancel));
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
    try f.expectGit(&.{ "show", ":other" }, "unrelated changed index\n");
    try f.noLock();
}

test "refuse symlink FIFO binary nonUTF8 conversion and sparse/extended index" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try t.expectEqual(@as(c_int, 0), c.symlinkat("selected", f.fd, "link"));
    try t.expectError(error.UnsafeFile, f.prepare("link", .stage));
    try t.expectEqual(@as(c_int, 0), c.mkfifoat(f.fd, "fifo", 0o600));
    try t.expectError(error.UnsafeFile, f.prepare("fifo", .stage));
    try f.write("binary", "a\x00b");
    try t.expectError(error.Binary, f.prepare("binary", .stage));
    try f.write("invalid", "\xff");
    try t.expectError(error.NonUtf8, f.prepare("invalid", .stage));
    for ([_][]const u8{ "selected filter=evil\n", "selected text\n", "selected eol=lf\n", "selected ident\n", "selected working-tree-encoding=UTF-8\n", "selected crlf\n", "selected filter=unset\n", "selected filter=unspecified\n", "selected -filter\n" }) |attr| {
        try f.write(".gitattributes", attr);
        try t.expectError(error.ConversionUnsupported, f.prepare("selected", .stage));
    }
    _ = c.unlinkat(f.fd, ".gitattributes", 0);
    try f.git(&.{ "config", "core.autocrlf", "true" });
    try t.expectError(error.ConversionUnsupported, f.prepare("selected", .stage));
    try f.git(&.{ "config", "core.autocrlf", "false" });
    try f.git(&.{ "config", "core.sparseCheckout", "true" });
    try t.expectError(error.UnsupportedIndex, f.prepare("selected", .stage));
    try f.git(&.{ "config", "core.sparseCheckout", "false" });
    try f.git(&.{ "update-index", "--skip-worktree", "selected" });
    try t.expectError(error.UnsupportedIndex, f.prepare("selected", .stage));
    try f.git(&.{ "update-index", "--no-skip-worktree", "selected" });
    try f.git(&.{ "update-index", "--assume-unchanged", "selected" });
    try t.expectError(error.UnsupportedIndex, f.prepare("selected", .stage));
    try f.git(&.{ "update-index", "--no-assume-unchanged", "selected" });
    const oversized = try t.allocator.alloc(u8, tx.max_file_bytes + 1);
    defer t.allocator.free(oversized);
    @memset(oversized, 'a');
    try f.write("large", oversized);
    try t.expectError(error.TooLarge, f.prepare("large", .stage));
    try f.git(&.{ "update-index", "--split-index" });
    try t.expectError(error.UnsupportedIndex, f.prepare("selected", .stage));
    try f.noLock();
}

test "mode review honors core.filemode and unstage restores HEAD mode" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try t.expectEqual(@as(c_int, 0), c.fchmodat(f.fd, "selected", 0o755, 0));
    var executable = try f.prepare("selected", .stage);
    defer executable.deinit();
    try t.expectEqual(@as(u32, 0o100644), executable.before_mode);
    try t.expectEqual(@as(u32, 0o100755), executable.after_mode);
    try t.expect((try tx.apply(&executable, &f.cancel)).committed);
    try f.git(&.{ "config", "core.filemode", "false" });
    try t.expectEqual(@as(c_int, 0), c.fchmodat(f.fd, "selected", 0o644, 0));
    var ignored = try f.prepare("selected", .stage);
    defer ignored.deinit();
    try t.expectEqual(@as(u32, 0o100755), ignored.after_mode);
    try t.expect((try tx.apply(&ignored, &f.cancel)).committed);
    var undo = try f.prepare("selected", .unstage);
    defer undo.deinit();
    try t.expectEqual(@as(u32, 0o100644), undo.after_mode);
    try t.expect((try tx.apply(&undo, &f.cancel)).committed);
}

const Fault = struct {
    fixture: *Fixture,
    kind: enum { cancel, disk, foreign_lock },
    fn run(context: ?*anyopaque) void {
        const fault: *Fault = @ptrCast(@alignCast(context.?));
        switch (fault.kind) {
            .cancel => fault.fixture.cancel.store(true, .release),
            .disk => fault.fixture.write("selected", "changed after object write\n") catch @panic("fixture write"),
            .foreign_lock => {
                if (c.unlinkat(fault.fixture.fd, ".git/index.lock", 0) != 0) @panic("fixture unlink");
                fault.fixture.write(".git/index.lock", "replacement lock") catch @panic("fixture write");
            },
        }
    }
};

test "final recheck cancels, detects late file changes and preserves a replaced lock" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    for ([_]@FieldType(Fault, "kind"){ .cancel, .disk, .foreign_lock }) |kind| {
        f.cancel.store(false, .release);
        try f.write("selected", "reviewed disk\n");
        var p = try f.prepare("selected", .stage);
        defer p.deinit();
        var fault = Fault{ .fixture = &f, .kind = kind };
        const hooks = tx.TestHooks{ .context = &fault, .before_final_recheck = Fault.run };
        p.state.hooks = &hooks;
        const expected = switch (kind) {
            .cancel => error.Cancelled,
            .disk => error.StaleSnapshot,
            .foreign_lock => error.LockReplaced,
        };
        try t.expectError(expected, tx.apply(&p, &f.cancel));
        try f.expectGit(&.{ "show", ":selected" }, "head\n");
        if (kind == .foreign_lock) {
            try f.expectFile(".git/index.lock", "replacement lock");
            _ = c.unlinkat(f.fd, ".git/index.lock", 0);
        }
        try f.noLock();
    }
}

test "publication stays committed on late cancellation and directory fsync failure" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "approved bytes\n");
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    var fault = Fault{ .fixture = &f, .kind = .cancel };
    const hooks = tx.TestHooks{ .context = &fault, .after_publish = Fault.run, .fail_directory_sync = true };
    p.state.hooks = &hooks;
    const outcome = try tx.apply(&p, &f.cancel);
    try t.expect(outcome.committed and outcome.durability_uncertain);
    try t.expect(f.cancel.load(.acquire));
    try f.expectGit(&.{ "show", ":selected" }, "approved bytes\n");
    try f.expectFile("selected", "approved bytes\n");
    try f.noLock();
}

test "repository binding replacement cannot redirect publication" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "disk\n");
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    try t.expectEqual(@as(c_int, 0), c.renameat(f.fd, ".git", f.fd, ".git-original"));
    defer _ = c.renameat(f.fd, ".git-original", f.fd, ".git");
    try t.expectEqual(@as(c_int, 0), c.mkdirat(f.fd, ".git", 0o700));
    defer _ = c.unlinkat(f.fd, ".git", c.AT_REMOVEDIR);
    try t.expectError(error.StaleSnapshot, tx.apply(&p, &f.cancel));
    var st: c.struct_stat = undefined;
    try t.expect(c.fstatat(f.fd, ".git-original/index.lock", &st, c.AT_SYMLINK_NOFOLLOW) != 0);
    try f.noLock();
}

test "linked worktree uses its own index and revalidates the gitdir file" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const linked = try std.fmt.allocPrint(t.allocator, "{s}/linked", .{f.root});
    defer t.allocator.free(linked);
    // No checkout: only fixture metadata is created, disk files are written below.
    try f.git(&.{ "worktree", "add", "--detach", "--no-checkout", linked, "HEAD" });
    try f.write("linked/selected", "linked disk\n");
    const discovery = try tx.runGit(t.allocator, linked, null, null, null, null, &f.cancel, &.{ "rev-parse", "--absolute-git-dir" }, "", 4096, false);
    defer t.allocator.free(discovery.bytes);
    const gitdir = std.mem.trimEnd(u8, discovery.bytes, "\n");
    const request = tx.Request{ .root = linked, .gitdir = gitdir, .commondir = f.gitdir, .path = "selected", .action = .stage };
    const parent_index = try f.read(".git/index");
    defer t.allocator.free(parent_index);
    var p = try tx.prepare(t.allocator, request, &f.cancel);
    defer p.deinit();
    try t.expect(!p.before_exists);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectFile(".git/index", parent_index);
    var unstage_request = request;
    unstage_request.action = .unstage;
    var undo = try tx.prepare(t.allocator, unstage_request, &f.cancel);
    defer undo.deinit();
    try t.expectEqualStrings("linked disk\n", undo.before);
    try t.expectEqualStrings("head\n", undo.after);
    try t.expect((try tx.apply(&undo, &f.cancel)).committed);
    try f.expectFile("linked/selected", "linked disk\n");
    var stale = try tx.prepare(t.allocator, request, &f.cancel);
    defer stale.deinit();
    const gitfile = try f.read("linked/.git");
    defer t.allocator.free(gitfile);
    try f.write("replacement", gitfile);
    try t.expectEqual(@as(c_int, 0), c.renameat(f.fd, "replacement", f.fd, "linked/.git"));
    try t.expectError(error.StaleSnapshot, tx.apply(&stale, &f.cancel));
    try f.expectFile(".git/index", parent_index);
}

test "HEAD oid changes, effective external attributes and absent file creation invalidate approval" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "disk\n");
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    const commit = try f.output(&.{ "-c", "commit.gpgsign=false", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "fixture second" });
    defer t.allocator.free(commit);
    try f.git(&.{ "update-ref", "HEAD", std.mem.trimEnd(u8, commit, "\n") });
    try t.expectError(error.StaleSnapshot, tx.apply(&p, &f.cancel));
    try f.write("attributes", "selected filter=external\n");
    const attr_path = try std.fmt.allocPrint(t.allocator, "{s}/attributes", .{f.root});
    defer t.allocator.free(attr_path);
    try f.git(&.{ "config", "core.attributesFile", attr_path });
    try t.expectError(error.ConversionUnsupported, f.prepare("selected", .stage));
    try f.git(&.{ "config", "--unset", "core.attributesFile" });
    _ = c.unlinkat(f.fd, "selected", 0);
    var deletion = try f.prepare("selected", .stage);
    defer deletion.deinit();
    try f.write("selected", "head\n");
    try t.expectError(error.StaleSnapshot, tx.apply(&deletion, &f.cancel));
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
    try f.noLock();
}

test "conflicts and target submodules or staged symlinks fail closed" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const commit = try f.output(&.{ "rev-parse", "HEAD" });
    defer t.allocator.free(commit);
    const gitlink = try std.fmt.allocPrint(t.allocator, "160000,{s},module", .{std.mem.trimEnd(u8, commit, "\n")});
    defer t.allocator.free(gitlink);
    try f.git(&.{ "update-index", "--add", "--cacheinfo", gitlink });
    try t.expectError(error.UnsupportedEntry, f.prepare("module", .stage));
    try t.expectEqual(@as(c_int, 0), c.symlinkat("selected", f.fd, "link"));
    try f.git(&.{ "add", "--", "link" });
    _ = c.unlinkat(f.fd, "link", 0);
    try f.write("link", "regular disk now\n");
    try t.expectError(error.UnsupportedEntry, f.prepare("link", .stage));
    const oid = try f.output(&.{ "rev-parse", "HEAD:selected" });
    defer t.allocator.free(oid);
    const zeros: [40]u8 = @splat('0');
    const input = try std.fmt.allocPrint(t.allocator, "0 {s}\tselected\x00100644 {s} 1\tselected\x00", .{ &zeros, std.mem.trimEnd(u8, oid, "\n") });
    defer t.allocator.free(input);
    const update = try tx.runGit(t.allocator, f.root, null, null, null, null, &f.cancel, &.{ "update-index", "-z", "--index-info" }, input, 1024, false);
    defer t.allocator.free(update.bytes);
    try t.expectError(error.Conflict, f.prepare("selected", .unstage));
    try f.noLock();
}

test "deinit closes retained descriptors and removes exactly the private scratch directory" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("new", "new bytes\n");
    var p = try f.prepare("new", .stage);
    const temp = p.state.temp.?;
    const name = try std.fmt.allocPrintSentinel(t.allocator, "/tmp/{s}", .{temp.name}, 0);
    defer t.allocator.free(name);
    const temp_fd = temp.fd;
    const root_fd = p.state.root.fd;
    p.deinit();
    var st: c.struct_stat = undefined;
    try t.expect(c.fstat(temp_fd, &st) != 0);
    try t.expect(c.fstat(root_fd, &st) != 0);
    try t.expect(c.fstatat(c.AT_FDCWD, name, &st, c.AT_SYMLINK_NOFOLLOW) != 0);
    try f.expectFile("new", "new bytes\n");
    try f.noLock();
}

test "maximum bounded input preserves UTF8 and CRLF bytes exactly through the transport" {
    var f = try Fixture.init();
    defer f.deinit();
    const bytes = try t.allocator.alloc(u8, tx.max_file_bytes);
    defer t.allocator.free(bytes);
    @memset(bytes, 'a');
    @memcpy(bytes[0..4], "\xf0\x9f\x8c\x8a");
    @memcpy(bytes[bytes.len - 2 ..], "\r\n");
    try f.write("maximum", bytes);
    var p = try f.prepare("maximum", .stage);
    defer p.deinit();
    try t.expectEqualSlices(u8, bytes, p.after);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":maximum" }, bytes);
    try f.expectFile("maximum", bytes);
    var undo = try f.prepare("maximum", .unstage);
    defer undo.deinit();
    try t.expectEqualSlices(u8, bytes, undo.before);
    try t.expect(!undo.after_exists);
}

test "racy-clean unrelated same-size timestamp-preserved edits remain visible" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.git(&.{ "config", "core.trustctime", "false" });
    try f.mtime("other", 1700000000, 100000000);
    try f.git(&.{ "update-index", "--refresh" });
    // Force a racy entry deterministically, without sleeps or clock granularity
    // assumptions: its cached mtime equals the index's own mtime.
    try f.mtime(".git/index", 1700000000, 100000000);
    try f.write("other", "OTHER head\n");
    try f.mtime("other", 1700000000, 100000000);
    try f.write("selected", "selected stage\n");
    try f.expectGit(&.{ "diff-files", "--name-only", "--", "other" }, "other\n");
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    var scratch: c.struct_stat = undefined;
    try t.expectEqual(@as(c_int, 0), c.fstatat(p.state.temp.?.fd, "index", &scratch, c.AT_SYMLINK_NOFOLLOW));
    try t.expectEqual(@as(i64, 1700000000), scratch.st_mtim.tv_sec);
    try t.expectEqual(@as(u32, 100000000), scratch.st_mtim.tv_nsec);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "diff-files", "--name-only", "--", "other" }, "other\n");
    try f.expectGit(&.{ "show", ":other" }, "other head\n");
    try f.expectFile("other", "OTHER head\n");
    var undo = try f.prepare("selected", .unstage);
    defer undo.deinit();
    try t.expect((try tx.apply(&undo, &f.cancel)).committed);
    try f.expectGit(&.{ "diff-files", "--name-only", "--", "other" }, "other\n");
    try f.expectGit(&.{ "show", ":other" }, "other head\n");
    try f.noLock();
}

const SyncTrace = struct {
    steps: [3]tx.ObjectSyncStep = undefined,
    count: usize = 0,
    published_after_syncs: bool = false,

    fn record(context: ?*anyopaque, step: tx.ObjectSyncStep) void {
        const self: *SyncTrace = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.count < self.steps.len);
        self.steps[self.count] = step;
        self.count += 1;
    }
    fn published(context: ?*anyopaque) void {
        const self: *SyncTrace = @ptrCast(@alignCast(context.?));
        self.published_after_syncs = self.count == 3;
    }
};

fn loosePath(f: *Fixture, bytes: []const u8) ![:0]u8 {
    const result = try tx.runGit(t.allocator, f.root, null, null, null, null, &f.cancel, &.{ "hash-object", "--no-filters", "--stdin" }, bytes, 1024, false);
    defer t.allocator.free(result.bytes);
    const oid = std.mem.trimEnd(u8, result.bytes, "\n");
    return std.fmt.allocPrintSentinel(t.allocator, ".git/objects/{s}/{s}", .{ oid[0..2], oid[2..] }, 0);
}

test "object durability syncs new and reused loose blobs before publishing independent of Git config" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.git(&.{ "config", "core.fsync", "none" });
    try f.git(&.{ "config", "core.fsyncObjectFiles", "false" });
    for ([_][]const u8{ "new durable blob\n", "head\n" }, 0..) |bytes, i| {
        const path = try loosePath(&f, bytes);
        defer t.allocator.free(path);
        var before: c.struct_stat = undefined;
        const existed = c.fstatat(f.fd, path, &before, c.AT_SYMLINK_NOFOLLOW) == 0;
        try t.expectEqual(i == 1, existed);
        try f.write("selected", bytes);
        var p = try f.prepare("selected", .stage);
        defer p.deinit();
        var trace: SyncTrace = .{};
        const hooks = tx.TestHooks{ .context = &trace, .after_object_sync = SyncTrace.record, .after_publish = SyncTrace.published };
        p.state.hooks = &hooks;
        const result = try tx.apply(&p, &f.cancel);
        try t.expect(result.committed and !result.durability_uncertain);
        try t.expect(trace.published_after_syncs);
        try t.expectEqualSlices(tx.ObjectSyncStep, &.{ .file, .prefix, .objects }, trace.steps[0..trace.count]);
        var after: c.struct_stat = undefined;
        try t.expectEqual(@as(c_int, 0), c.fstatat(f.fd, path, &after, c.AT_SYMLINK_NOFOLLOW));
        if (existed) try t.expectEqual(before.st_ino, after.st_ino);
        try f.expectGit(&.{ "show", ":selected" }, bytes);
        try f.noLock();
    }
}

test "each object durability failure aborts before publication for new and reused blobs" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.git(&.{ "config", "core.fsync", "none" });
    const original = try f.read(".git/index");
    defer t.allocator.free(original);
    for ([_]bool{ false, true }) |reuse| {
        for ([_]tx.ObjectSyncStep{ .file, .prefix, .objects }, 0..) |step, position| {
            const bytes = try std.fmt.allocPrint(t.allocator, "new unsynced {s}\n", .{@tagName(step)});
            defer t.allocator.free(bytes);
            const disk = if (reuse) "head\n" else bytes;
            const path = try loosePath(&f, disk);
            defer t.allocator.free(path);
            var st: c.struct_stat = undefined;
            try t.expectEqual(reuse, c.fstatat(f.fd, path, &st, c.AT_SYMLINK_NOFOLLOW) == 0);
            try f.write("selected", disk);
            var p = try f.prepare("selected", .stage);
            defer p.deinit();
            var trace: SyncTrace = .{};
            const hooks = tx.TestHooks{ .context = &trace, .fail_object_sync = step, .after_object_sync = SyncTrace.record, .after_publish = SyncTrace.published };
            p.state.hooks = &hooks;
            try t.expectError(error.ObjectSyncFailed, tx.apply(&p, &f.cancel));
            try t.expectEqual(position, trace.count);
            try t.expect(!trace.published_after_syncs);
            try f.expectFile(".git/index", original);
            try f.expectFile("selected", disk);
            try f.noLock();
        }
    }
}

test "packed-only selected objects fail closed when loose object durability cannot be established" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.git(&.{ "repack", "-ad" });
    try f.git(&.{"prune-packed"});
    const path = try loosePath(&f, "head\n");
    defer t.allocator.free(path);
    var st: c.struct_stat = undefined;
    try t.expect(c.fstatat(f.fd, path, &st, c.AT_SYMLINK_NOFOLLOW) != 0);
    const original = try f.read(".git/index");
    defer t.allocator.free(original);
    var p = try f.prepare("selected", .stage);
    defer p.deinit();
    try t.expectError(error.ObjectDurabilityUnavailable, tx.apply(&p, &f.cancel));
    try f.expectFile(".git/index", original);
    try f.noLock();
}

test "first lock stat failure cleans the owned lock but never a replacement" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    try f.write("selected", "reviewed disk\n");
    const original = try f.read(".git/index");
    defer t.allocator.free(original);
    for ([_]bool{ false, true }) |replace| {
        var p = try f.prepare("selected", .stage);
        defer p.deinit();
        var fault = Fault{ .fixture = &f, .kind = .foreign_lock };
        const hooks = tx.TestHooks{
            .context = &fault,
            .before_initial_lock_stat = if (replace) Fault.run else null,
            .fail_initial_lock_stat = true,
        };
        p.state.hooks = &hooks;
        try t.expectError(error.ReadFailed, tx.apply(&p, &f.cancel));
        try f.expectFile(".git/index", original);
        if (replace) {
            try f.expectFile(".git/index.lock", "replacement lock");
            try t.expectEqual(@as(c_int, 0), c.unlinkat(f.fd, ".git/index.lock", 0));
        }
        try f.noLock();
    }
}

test "replacement refs never substitute bytes for the captured index or HEAD object" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.baseline();
    const original = try f.output(&.{ "rev-parse", "HEAD:selected" });
    defer t.allocator.free(original);
    const replacement = try tx.runGit(t.allocator, f.root, null, null, null, null, &f.cancel, &.{ "hash-object", "-w", "--no-filters", "--stdin" }, "substitute blob\n", 1024, false);
    defer t.allocator.free(replacement.bytes);
    try f.git(&.{ "replace", std.mem.trimEnd(u8, original, "\n"), std.mem.trimEnd(u8, replacement.bytes, "\n") });
    var p = try f.prepare("selected", .unstage);
    defer p.deinit();
    try t.expectEqualStrings("head\n", p.before);
    try t.expectEqualStrings("head\n", p.after);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "head\n");
}
