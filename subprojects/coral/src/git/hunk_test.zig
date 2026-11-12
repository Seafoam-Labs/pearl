//! Hunk backend tests. Pure parser/applier cases use no Git; integration cases
//! confine every Git write/fixture commit to a private /tmp repository. No
//! checkout, commit or staging touches any real project.
const std = @import("std");
const tx = @import("index_transaction.zig");
const hunk = @import("hunk.zig");
const c = @import("index_transaction_os.zig");
const t = std.testing;

// ---------------------------------------------------------------------------
// Pure parser / applier
// ---------------------------------------------------------------------------

test "parse two hunks, apply each alone preserves the other region exactly" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch =
        \\diff --git a/f b/f
        \\index 1111111..2222222 100644
        \\--- a/f
        \\+++ b/f
        \\@@ -1,5 +1,5 @@
        \\ a
        \\-b
        \\+B
        \\ c
        \\ d
        \\ e
        \\@@ -8,7 +8,7 @@ g
        \\ h
        \\ i
        \\ j
        \\-k
        \\+K
        \\ l
        \\ m
        \\ n
        \\
    ;
    const parsed = try hunk.parse(a, patch);
    try t.expectEqual(@as(usize, 2), parsed.hunks.len);
    const base = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n";
    const first = try hunk.apply(a, base, parsed.hunks[0], .forward);
    try t.expectEqualStrings("a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n", first);
    const second = try hunk.apply(a, base, parsed.hunks[1], .forward);
    try t.expectEqualStrings("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n", second);
    // Reverse restores the original from the applied result.
    try t.expectEqualStrings(base, try hunk.apply(a, first, parsed.hunks[0], .reverse));
    try t.expectEqualStrings(base, try hunk.apply(a, second, parsed.hunks[1], .reverse));
}

test "digest ignores paths, section heading and count omission but covers body" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one =
        \\diff --git a/real/path b/real/path
        \\--- a/real/path
        \\+++ b/real/path
        \\@@ -1 +1 @@
        \\-x
        \\+y
        \\
    ;
    const two =
        \\diff --git a/tmp/xyz/src b/tmp/xyz/dst
        \\index abc..def 100644
        \\--- a/tmp/xyz/src
        \\+++ b/tmp/xyz/dst
        \\@@ -1,1 +1,1 @@ some heading
        \\-x
        \\+y
        \\
    ;
    const p1 = try hunk.parse(a, one);
    const p2 = try hunk.parse(a, two);
    try t.expectEqualSlices(u8, &hunk.digest(p1.hunks[0]), &hunk.digest(p2.hunks[0]));
    const changed =
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-x
        \\+z
        \\
    ;
    const p3 = try hunk.parse(a, changed);
    try t.expect(!std.mem.eql(u8, &hunk.digest(p1.hunks[0]), &hunk.digest(p3.hunks[0])));
}

test "strict apply refuses stale body, wrong position and out-of-bounds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch =
        \\--- a/f
        \\+++ b/f
        \\@@ -2,3 +2,3 @@
        \\ b
        \\-c
        \\+C
        \\ d
        \\
    ;
    const p = try hunk.parse(a, patch);
    const h = p.hunks[0];
    try t.expectEqualStrings("a\nb\nC\nd\ne\n", try hunk.apply(a, "a\nb\nc\nd\ne\n", h, .forward));
    // Context mismatch (stale body) at the exact position: no fuzz/offset search.
    try t.expectError(error.HunkMismatch, hunk.apply(a, "a\nX\nc\nd\ne\n", h, .forward));
    // Same bytes shifted by one line must NOT match (no offset).
    try t.expectError(error.HunkMismatch, hunk.apply(a, "z\na\nb\nc\nd\ne\n", h, .forward));
    // Too short to contain the old range.
    try t.expectError(error.HunkMismatch, hunk.apply(a, "b\nc\n", h, .forward));
}

test "CRLF bytes are preserved exactly through forward and reverse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The diff body lines carry CR as content; build it explicitly.
    const crlf_patch = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n";
    const p = try hunk.parse(a, crlf_patch);
    const base = "a\r\nb\r\n";
    const out = try hunk.apply(a, base, p.hunks[0], .forward);
    try t.expectEqualStrings("a\r\nB\r\n", out);
    try t.expectEqualStrings(base, try hunk.apply(a, out, p.hunks[0], .reverse));
}

test "no-final-newline markers are honored and required consistently" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+B\n\\ No newline at end of file\n";
    const p = try hunk.parse(a, patch);
    // base has no final LF; result keeps no final LF.
    const out = try hunk.apply(a, "a\nb", p.hunks[0], .forward);
    try t.expectEqualStrings("a\nB", out);
    try t.expectEqualStrings("a\nb", try hunk.apply(a, out, p.hunks[0], .reverse));
    // A base WITH a final LF contradicts the marker: refuse.
    try t.expectError(error.HunkMismatch, hunk.apply(a, "a\nb\n", p.hunks[0], .forward));
    // Removing the final newline marks only the new side.
    const remnl = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n\\ No newline at end of file\n";
    const pr = try hunk.parse(a, remnl);
    try t.expectEqualStrings("a\nB", try hunk.apply(a, "a\nb\n", pr.hunks[0], .forward));
    try t.expectEqualStrings("a\nb\n", try hunk.apply(a, "a\nB", pr.hunks[0], .reverse));
    // Adding a final newline is a -/+ pair on the last line.
    const addnl = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+x\n";
    const pa = try hunk.parse(a, addnl);
    try t.expectEqualStrings("x\n", try hunk.apply(a, "x", pa.hunks[0], .forward));
    try t.expectEqualStrings("x", try hunk.apply(a, "x\n", pa.hunks[0], .reverse));
}

test "pure insertion and deletion at boundaries" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ins =
        \\--- a/f
        \\+++ b/f
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
        \\
    ;
    const pi = try hunk.parse(a, ins);
    try t.expectEqualStrings("a\nb\n", try hunk.apply(a, "", pi.hunks[0], .forward));
    try t.expectEqualStrings("", try hunk.apply(a, "a\nb\n", pi.hunks[0], .reverse));
    const del =
        \\--- a/f
        \\+++ b/f
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
        \\
    ;
    const pd = try hunk.parse(a, del);
    try t.expectEqualStrings("", try hunk.apply(a, "a\nb\n", pd.hunks[0], .forward));
    try t.expectEqualStrings("a\nb\n", try hunk.apply(a, "", pd.hunks[0], .reverse));
    // Appending to a no-LF file is not a pure insertion; strict applier refuses.
    const bad_ins =
        \\--- a/f
        \\+++ b/f
        \\@@ -1,0 +2 @@
        \\+y
        \\
    ;
    const pb = try hunk.parse(a, bad_ins);
    try t.expectError(error.HunkMismatch, hunk.apply(a, "x", pb.hunks[0], .forward));
}

test "parser refuses absent sides, mode/rename/binary, multi-file and bad markers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.AbsentSide, hunk.parse(a, "--- a/f\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n"));
    try t.expectError(error.UnsupportedChange, hunk.parse(a, "--- a/f\n+++ b/f\nold mode 100644\nnew mode 100755\n@@ -1 +1 @@\n-x\n+y\n"));
    try t.expectError(error.UnsupportedChange, hunk.parse(a, "diff --git a/f b/g\nsimilarity index 90%\nrename from f\nrename to g\n--- a/f\n+++ b/g\n@@ -1 +1 @@\n-x\n+y\n"));
    try t.expectError(error.UnsupportedChange, hunk.parse(a, "diff --git a/f b/f\nBinary files a/f and b/f differ\n"));
    try t.expectError(error.InvalidPatch, hunk.parse(a, "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\ndiff --git a/g b/g\n--- a/g\n+++ b/g\n@@ -1 +1 @@\n-p\n+q\n"));
    // Marker on a non-final old-side line is invalid.
    try t.expectError(error.InvalidPatch, hunk.parse(a, "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-x\n\\ No newline at end of file\n-y\n+Y\n"));
    // Count mismatch.
    try t.expectError(error.InvalidPatch, hunk.parse(a, "--- a/f\n+++ b/f\n@@ -1,5 +1,1 @@\n-x\n+y\n"));
    // No-op hunk (context only).
    try t.expectError(error.InvalidPatch, hunk.parse(a, "--- a/f\n+++ b/f\n@@ -1 +1 @@\n x\n"));
    // Empty input yields zero hunks.
    try t.expectEqual(@as(usize, 0), (try hunk.parse(a, "")).hunks.len);
}

test "bounds: oversized patch, line and output are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, hunk.max_patch_bytes + 1);
    @memset(big, 'x');
    try t.expectError(error.PatchTooLarge, hunk.parse(a, big));
    // Output larger than the file budget is refused.
    const line = try a.alloc(u8, hunk.max_file_bytes);
    @memset(line, 'a');
    const patch = try std.fmt.allocPrint(a, "--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+{s}\n", .{line});
    const p = try hunk.parse(a, patch);
    try t.expectError(error.TooLarge, hunk.apply(a, "", p.hunks[0], .forward));
}

// ---------------------------------------------------------------------------
// Disposable-fixture integration
// ---------------------------------------------------------------------------

const Fixture = struct {
    root: [:0]u8,
    gitdir: [:0]u8,
    fd: c_int,
    cancel: tx.Cancel = .init(false),

    fn init() !Fixture {
        var template = "/tmp/coral-hunk-test-XXXXXX".* ++ [_]u8{0};
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
        try f.git(&.{ "config", "user.name", "Coral hunk fixture" });
        try f.git(&.{ "config", "user.email", "coral-hunk-fixture@invalid" });
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
    fn commit(f: *Fixture) !void {
        // Fixture-only commit: explicit identity/config, no editor/signing/hooks.
        try f.git(&.{ "-c", "commit.gpgsign=false", "commit", "-q", "--no-gpg-sign", "-m", "fixture baseline" });
    }
    fn request(f: *Fixture, path: []const u8, action: tx.Action, ref: ?tx.HunkRef) tx.Request {
        return .{ .root = f.root, .gitdir = f.gitdir, .commondir = f.gitdir, .path = path, .action = action, .hunk = ref };
    }
    /// Build a HunkRef from the displayed diff exactly as the UI will: parse the
    /// real index→disk (stage) or HEAD→index (unstage) diff and digest a hunk.
    fn hunkRef(f: *Fixture, path: []const u8, staged: bool, ordinal: usize) !tx.HunkRef {
        const out = if (staged)
            try f.output(&.{ "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--", path })
        else
            try f.output(&.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--", path });
        defer t.allocator.free(out);
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const parsed = try hunk.parse(arena.allocator(), out);
        if (ordinal >= parsed.hunks.len) return error.NoSuchHunk;
        return .{ .ordinal = ordinal, .digest = hunk.digest(parsed.hunks[ordinal]) };
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

const fourteen = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n";

test "stage_hunk applies only the selected hunk; other hunks and entries survive" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", fourteen);
    try f.write("other", "other head\n");
    try f.git(&.{ "add", "--", "selected", "other" });
    try f.commit();
    // Two well-separated disk edits -> two hunks.
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    // An unrelated staged entry must be preserved.
    try f.write("other", "other staged\n");
    try f.git(&.{ "add", "--", "other" });
    try f.write("other", "other unstaged\n");

    const ref0 = try f.hunkRef("selected", false, 0);
    var p = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, ref0), &f.cancel);
    defer p.deinit();
    try t.expectEqualStrings(fourteen, p.before);
    try t.expectEqualStrings("a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n", p.after);
    try t.expect(p.before_exists and p.after_exists);
    try t.expectEqual(p.before_mode, p.after_mode);
    const summary = p.hunk.?;
    try t.expectEqual(@as(usize, 2), summary.total);
    try t.expectEqual(@as(usize, 0), summary.ordinal);
    try t.expectEqualSlices(u8, &ref0.digest, &summary.digest);
    try t.expect(p.patch.len > 0);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n");
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.expectFile("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    try f.expectFile("other", "other unstaged\n");

    // Now only the second edit remains unstaged; a fresh single-hunk diff.
    const ref1 = try f.hunkRef("selected", false, 0);
    var q = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, ref1), &f.cancel);
    defer q.deinit();
    try t.expectEqual(@as(usize, 1), q.hunk.?.total);
    try t.expect((try tx.apply(&q, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.noLock();
}

test "unstage_hunk reverses only the selected hunk; other staged hunks survive" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", fourteen);
    try f.write("other", "other head\n");
    try f.git(&.{ "add", "--", "selected", "other" });
    try f.commit();
    // Stage two separated edits.
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    try f.git(&.{ "add", "--", "selected" });
    try f.write("other", "other staged\n");
    try f.git(&.{ "add", "--", "other" });

    const ref0 = try f.hunkRef("selected", true, 0);
    var p = try tx.prepare(t.allocator, f.request("selected", .unstage_hunk, ref0), &f.cancel);
    defer p.deinit();
    try t.expectEqualStrings("a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n", p.before);
    try t.expectEqualStrings("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n", p.after);
    try t.expectEqual(@as(usize, 2), p.hunk.?.total);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.expectFile("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");

    const ref1 = try f.hunkRef("selected", true, 0);
    var q = try tx.prepare(t.allocator, f.request("selected", .unstage_hunk, ref1), &f.cancel);
    defer q.deinit();
    try t.expectEqual(@as(usize, 1), q.hunk.?.total);
    try t.expect((try tx.apply(&q, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, fourteen);
    try f.expectGit(&.{ "show", ":other" }, "other staged\n");
    try f.noLock();
}

test "stale hunk body and missing ordinal are refused at prepare" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", fourteen);
    try f.git(&.{ "add", "--", "selected" });
    try f.commit();
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    const ref0 = try f.hunkRef("selected", false, 0);
    // Change the hunk body on disk after the ref was captured.
    try f.write("selected", "a\nX\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\nm\nn\n");
    try t.expectError(error.StaleHunk, tx.prepare(t.allocator, f.request("selected", .stage_hunk, ref0), &f.cancel));
    // Ordinal beyond the regenerated hunk count.
    const bogus = tx.HunkRef{ .ordinal = 9, .digest = ref0.digest };
    try t.expectError(error.HunkNotFound, tx.prepare(t.allocator, f.request("selected", .stage_hunk, bogus), &f.cancel));
    // Missing ref entirely.
    try t.expectError(error.MissingHunk, tx.prepare(t.allocator, f.request("selected", .stage_hunk, null), &f.cancel));
    try f.expectGit(&.{ "show", ":selected" }, fourteen);
    try f.noLock();
}

test "hunk stage/unstage preserve CRLF and no-final-newline bytes exactly" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", "a\r\nb\r\nc\r\n");
    try f.git(&.{ "add", "--", "selected" });
    try f.commit();
    try f.write("selected", "a\r\nB\r\nc\r\n");
    const crlf_ref = try f.hunkRef("selected", false, 0);
    var p = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, crlf_ref), &f.cancel);
    defer p.deinit();
    try t.expectEqualStrings("a\r\nB\r\nc\r\n", p.after);
    try t.expect((try tx.apply(&p, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\r\nB\r\nc\r\n");
    var u = try tx.prepare(t.allocator, f.request("selected", .unstage_hunk, try f.hunkRef("selected", true, 0)), &f.cancel);
    defer u.deinit();
    try t.expectEqualStrings("a\r\nb\r\nc\r\n", u.after);
    try t.expect((try tx.apply(&u, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\r\nb\r\nc\r\n");

    // No final newline, including a hunk that adds the final newline.
    try f.write("selected", "a\nb\nc");
    try f.git(&.{ "add", "--", "selected" });
    try f.commit();
    try f.write("selected", "a\nB\nc");
    var n = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, try f.hunkRef("selected", false, 0)), &f.cancel);
    defer n.deinit();
    try t.expectEqualStrings("a\nB\nc", n.after);
    try t.expect((try tx.apply(&n, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\nB\nc");
    try f.write("selected", "a\nB\nc\n");
    var nl = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, try f.hunkRef("selected", false, 0)), &f.cancel);
    defer nl.deinit();
    try t.expectEqualStrings("a\nB\nc\n", nl.after);
    try t.expect((try tx.apply(&nl, &f.cancel)).committed);
    try f.expectGit(&.{ "show", ":selected" }, "a\nB\nc\n");
    try f.noLock();
}

test "hunk actions refuse mode changes, absent sides, binary and oversized" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", fourteen);
    try f.git(&.{ "add", "--", "selected" });
    try f.commit();
    const dummy = tx.HunkRef{ .ordinal = 0, .digest = @splat(0) };
    // Mode change on disk: capture the ref while modes still match, then chmod.
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n");
    const mode_ref = try f.hunkRef("selected", false, 0);
    try t.expectEqual(@as(c_int, 0), c.fchmodat(f.fd, "selected", 0o755, 0));
    try t.expectError(error.ModeChangeUnsupported, tx.prepare(t.allocator, f.request("selected", .stage_hunk, mode_ref), &f.cancel));
    try t.expectEqual(@as(c_int, 0), c.fchmodat(f.fd, "selected", 0o644, 0));
    // Absent disk side for stage_hunk.
    _ = c.unlinkat(f.fd, "selected", 0);
    try t.expectError(error.AbsentSide, tx.prepare(t.allocator, f.request("selected", .stage_hunk, dummy), &f.cancel));
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n");
    // Absent index side (untracked new file).
    try f.write("fresh", "new\n");
    try t.expectError(error.AbsentSide, tx.prepare(t.allocator, f.request("fresh", .stage_hunk, dummy), &f.cancel));
    // Absent HEAD side for unstage_hunk (staged new file).
    try f.git(&.{ "add", "--", "fresh" });
    try t.expectError(error.AbsentSide, tx.prepare(t.allocator, f.request("fresh", .unstage_hunk, dummy), &f.cancel));
    // Binary disk.
    try f.write("selected", "a\x00b\n");
    try t.expectError(error.Binary, tx.prepare(t.allocator, f.request("selected", .stage_hunk, dummy), &f.cancel));
    // Oversized disk.
    const big = try t.allocator.alloc(u8, tx.max_file_bytes + 1);
    defer t.allocator.free(big);
    @memset(big, 'a');
    try f.write("selected", big);
    try t.expectError(error.TooLarge, tx.prepare(t.allocator, f.request("selected", .stage_hunk, dummy), &f.cancel));
    try f.noLock();
}

test "hunk apply recheck detects a late disk edit and leaves the index unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("selected", fourteen);
    try f.git(&.{ "add", "--", "selected" });
    try f.commit();
    try f.write("selected", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n");
    const original = try f.read(".git/index");
    defer t.allocator.free(original);
    var p = try tx.prepare(t.allocator, f.request("selected", .stage_hunk, try f.hunkRef("selected", false, 0)), &f.cancel);
    defer p.deinit();
    try f.write("selected", "a\nZ\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\n");
    try t.expectError(error.StaleSnapshot, tx.apply(&p, &f.cancel));
    try f.expectFile(".git/index", original);
    try f.expectGit(&.{ "show", ":selected" }, fourteen);
    try f.noLock();
}
