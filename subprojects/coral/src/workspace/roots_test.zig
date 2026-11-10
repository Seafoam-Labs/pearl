//! Backend tests; parent/core owns test-root and build discovery.
const std = @import("std");
const fs = @import("roots_fs.zig");
const model = @import("model.zig");
const manifest = @import("manifest.zig");
const native = @import("manifest_fs.zig");
const c = @import("pearl_app_c");
const a = std.testing.allocator;
const io = std.testing.io;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    cancel: *c.GCancellable,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [4096]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        const base = try a.dupeSentinel(u8, buffer[0..len], 0);
        return .{ .tmp = tmp, .base = base, .cancel = c.g_cancellable_new().? };
    }
    fn deinit(self: *Fixture) void {
        c.g_object_unref(self.cancel);
        a.free(self.base);
        self.tmp.cleanup();
    }
    fn path(self: *const Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.base, name }, 0);
    }
    fn mkdir(self: *const Fixture, name: []const u8) !void {
        try self.tmp.dir.createDir(io, name, .fromMode(0o700));
    }
    fn write(self: *const Fixture, name: []const u8, bytes: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try std.testing.expect(n > 0);
            offset += @intCast(n);
        }
    }
    fn snapshot(self: *const Fixture, name: []const u8) !fs.Snapshot {
        const p = try self.path(name);
        defer a.free(p);
        var value = try model.Model.fromManifest(a, p);
        defer value.deinit();
        return fs.Snapshot.capture(a, &value);
    }
    fn contents(self: *const Fixture, name: []const u8, expected: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        const bytes = try native.read(a, p);
        defer a.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    fn symlink(self: *const Fixture, target: [:0]const u8, name: []const u8) !void {
        const p = try self.path(name);
        defer a.free(p);
        try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target, p));
    }
};
const one = "{\"version\":1,\"roots\":[{\"name\":\"Root\",\"path\":\"one\"}]}";
const two = "{\"version\":1,\"roots\":[{\"name\":\"Root\",\"path\":\"one\"},{\"name\":\"Second\",\"path\":\"two\"}]}";

fn setup(f: *Fixture, bytes: []const u8) !fs.Snapshot {
    try f.mkdir("one");
    try f.mkdir("two");
    try f.write("work.coral-workspace", bytes);
    return f.snapshot("work.coral-workspace");
}

test "roots: folder Save As is exclusive, parses, and never creates parents" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("one");
    const folder = try f.path("one");
    defer a.free(folder);
    var value = try model.Model.fromFolder(a, folder);
    defer value.deinit();
    var snapshot = try fs.Snapshot.capture(a, &value);
    defer snapshot.deinit();
    const missing = try f.path("missing/work.coral-workspace");
    defer a.free(missing);
    try std.testing.expectError(error.NotFound, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = missing }, &.{}, f.cancel));
    const target = try f.path("new.coral-workspace");
    defer a.free(target);
    var p = try fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel);
    defer p.deinit();
    try std.testing.expectError(error.NotFound, native.read(a, target));
    try fs.apply(&p, &.{}, f.cancel);
    try std.testing.expect(p.committed);
    try std.testing.expectError(error.AlreadyApplied, fs.apply(&p, &.{}, f.cancel));
    const bytes = try native.read(a, target);
    defer a.free(bytes);
    var parsed = try manifest.parse(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(folder, parsed.roots[0].path);
    try std.testing.expectError(error.AlreadyExists, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel));
    try std.testing.expectError(error.SaveWorkspaceFirst, fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = folder }, &.{}, f.cancel));
    try std.testing.expectError(error.SaveWorkspaceFirst, fs.serialize(a, &snapshot, .remove, "", snapshot.roots[0].id));
}

test "roots: reviewed add/remove preserve settings languages excludes names and disk files" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f,
        \\{"version":1,"roots":[{"name":"名 \"root\"","path":"one"}],"settings":{"wrap":false,"indent":7,"languages":{"zig":{"spaces":false,"indent":2},"c":{"lines":false}}},"exclude":["build/**","*.tmp"]}
    );
    defer snapshot.deinit();
    try f.write("one/document.txt", "open document contents");
    const added = try f.path("two");
    defer a.free(added);
    var p = try fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = added }, &.{}, f.cancel);
    defer p.deinit();
    try fs.apply(&p, &.{}, f.cancel);
    var next = try f.snapshot("work.coral-workspace");
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 2), next.roots.len);
    try std.testing.expectEqualStrings("名 \"root\"", next.roots[0].name);
    try std.testing.expectEqual(@as(?bool, false), next.settings.general.wrap);
    try std.testing.expectEqual(@as(?u8, 7), next.settings.general.indent);
    try std.testing.expectEqual(@as(?u8, 2), next.settings.forLanguage("zig").indent);
    try std.testing.expectEqual(@as(?bool, false), next.settings.forLanguage("c").lines);
    try std.testing.expectEqualStrings("build/**", next.exclude[0]);
    const bound_document = try f.path("one/document.txt");
    defer a.free(bound_document);
    var remove = try fs.prepare(a, .{ .kind = .remove, .snapshot = &next, .selected = next.roots[0].id }, &.{bound_document}, f.cancel);
    defer remove.deinit();
    try fs.apply(&remove, &.{bound_document}, f.cancel);
    try f.contents("one/document.txt", "open document contents");
    var final = try f.snapshot("work.coral-workspace");
    defer final.deinit();
    try std.testing.expectEqual(@as(usize, 1), final.roots.len);
    try std.testing.expectEqualStrings(added, final.roots[0].path);
    try std.testing.expectError(error.LastRoot, fs.serialize(a, &final, .remove, "", final.roots[0].id));
    try std.testing.expectError(error.NoSelection, fs.serialize(a, &final, .remove, "", next.roots[0].id));
}

test "roots: add deduplicates canonical aliases and rejects missing or nondirectory folders" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    try f.symlink("one", "alias");
    const alias = try f.path("alias");
    defer a.free(alias);
    try std.testing.expectError(error.DuplicateRoot, fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = alias }, &.{}, f.cancel));
    const missing = try f.path("missing");
    defer a.free(missing);
    try std.testing.expectError(error.NotFound, fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = missing }, &.{}, f.cancel));
    try std.testing.expectError(error.NotDirectory, fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = snapshot.source.? }, &.{}, f.cancel));
}

test "roots: fresh disk must match loaded model including names and lexical aliases" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    const target = try f.path("saved.coral-workspace");
    defer a.free(target);
    const changes = [_][]const u8{
        "{\"version\":1,\"roots\":[{\"name\":\"Changed\",\"path\":\"one\"}]}",
        "{\"version\":1,\"roots\":[{\"name\":\"Root\",\"path\":\"./one\"}]}",
        "{\"version\":1,\"roots\":[{\"name\":\"Root\",\"path\":\"one\"}],\"settings\":{\"wrap\":false}}",
    };
    for (changes) |bytes| {
        try f.write("work.coral-workspace", bytes);
        try std.testing.expectError(error.WorkspaceChanged, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel));
        try f.contents("work.coral-workspace", bytes);
    }
}

test "roots: source edit after review conflicts even if it only changes formatting" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    var p = try fs.prepare(a, .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id }, &.{}, f.cancel);
    defer p.deinit();
    try f.write("work.coral-workspace", two ++ " ");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&p, &.{}, f.cancel));
    try f.contents("work.coral-workspace", two ++ " ");
}

test "roots: replacement inode with identical bytes is not the reviewed source" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    var p = try fs.prepare(a, .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id }, &.{}, f.cancel);
    defer p.deinit();
    const source = try f.path("work.coral-workspace");
    defer a.free(source);
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(source));
    try f.write("work.coral-workspace", two);
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&p, &.{}, f.cancel));
    try f.contents("work.coral-workspace", two);
}

test "roots: Save As collision after review preserves competitor, including dangling symlink" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    const target = try f.path("saved.coral-workspace");
    defer a.free(target);
    var p = try fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel);
    defer p.deinit();
    try f.write("saved.coral-workspace", "competitor");
    try std.testing.expectError(error.AlreadyExists, fs.apply(&p, &.{}, f.cancel));
    try f.contents("saved.coral-workspace", "competitor");
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(target));
    try f.symlink("does-not-exist", "saved.coral-workspace");
    try std.testing.expectError(error.AlreadyExists, fs.apply(&p, &.{}, f.cancel));
    try f.contents("work.coral-workspace", one);
}

test "roots: bound manifest paths, symlinks, hardlinks and late bindings block apply" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    const request: fs.Request = .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id };
    try std.testing.expectError(error.OpenDocument, fs.prepare(a, request, &.{snapshot.source.?}, f.cancel));
    try f.symlink("work.coral-workspace", "alias");
    const alias = try f.path("alias");
    defer a.free(alias);
    try std.testing.expectError(error.OpenDocument, fs.prepare(a, request, &.{alias}, f.cancel));
    const original = try f.path("work.coral-workspace");
    defer a.free(original);
    const hard = try f.path("hardlink");
    defer a.free(hard);
    try std.testing.expectEqual(@as(c_int, 0), std.c.link(original, hard));
    try std.testing.expectError(error.OpenDocument, fs.prepare(a, request, &.{hard}, f.cancel));
    var p = try fs.prepare(a, request, &.{}, f.cancel);
    defer p.deinit();
    try std.testing.expectError(error.OpenDocument, fs.apply(&p, &.{alias}, f.cancel));
    try f.contents("work.coral-workspace", two);
    const target = try f.path("unsaved.coral-workspace");
    defer a.free(target);
    try std.testing.expectError(error.OpenDocument, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{target}, f.cancel));
}

test "roots: cancellation before prepare and after review never writes" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    const request: fs.Request = .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id };
    var p = try fs.prepare(a, request, &.{}, f.cancel);
    defer p.deinit();
    c.g_cancellable_cancel(f.cancel);
    try std.testing.expectError(error.Cancelled, fs.apply(&p, &.{}, f.cancel));
    try std.testing.expectError(error.Cancelled, fs.prepare(a, request, &.{}, f.cancel));
    try f.contents("work.coral-workspace", two);
}

test "roots: Save As preserves physical link dot-dot traversal and offline lexical roots" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("physical");
    try f.mkdir("physical/child");
    try f.mkdir("physical/root");
    try f.mkdir("elsewhere");
    try f.symlink("physical/child", "link");
    try f.write("work.coral-workspace", "{\"version\":1,\"roots\":[{\"name\":\"Physical\",\"path\":\"link/../root\"},{\"name\":\"Offline\",\"path\":\"link/../missing/../later\"}]}");
    var snapshot = try f.snapshot("work.coral-workspace");
    defer snapshot.deinit();
    const target = try f.path("elsewhere/new.coral-workspace");
    defer a.free(target);
    var p = try fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel);
    defer p.deinit();
    try fs.apply(&p, &.{}, f.cancel);
    var saved = try model.Model.fromManifest(a, target);
    defer saved.deinit();
    const physical = try f.path("physical/root");
    defer a.free(physical);
    try std.testing.expectEqualStrings(physical, saved.roots[0].canonical_path.?);
    try std.testing.expectEqualStrings(snapshot.roots[0].path, saved.roots[0].lexical_path);
    try std.testing.expectEqualStrings(snapshot.roots[1].path, saved.roots[1].lexical_path);
    try std.testing.expectEqual(model.Availability.missing, saved.roots[1].availability);
    try std.testing.expectEqualStrings("Offline", saved.roots[1].display_name);
}

test "roots: changed folder policy and added folder retarget require another review" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    try f.symlink("two", "added");
    const added = try f.path("added");
    defer a.free(added);
    var p = try fs.prepare(a, .{ .kind = .add, .snapshot = &snapshot, .path = added }, &.{}, f.cancel);
    defer p.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(added));
    try f.symlink("one", "added");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&p, &.{}, f.cancel));
    try f.mkdir("one/.coral");
    try f.write("one/.coral/settings.json", "{\"version\":1,\"settings\":{\"wrap\":false}}");
    try std.testing.expectError(error.WorkspaceChanged, fs.apply(&p, &.{}, f.cancel));
    try f.contents("work.coral-workspace", one);
}

test "roots: root cap, zero-root schema, invalid paths and serialization validation" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    var many: [32]fs.Root = undefined;
    for (&many, 0..) |*root, i| root.* = .{ .id = @fromBackingInt(@as(u64, i + 1)), .name = "root", .path = "/offline" };
    const original = snapshot.roots;
    snapshot.roots = &many;
    try std.testing.expectError(error.TooManyRoots, fs.serialize(a, &snapshot, .add, "/new", null));
    snapshot.roots = &.{};
    const bytes = try fs.serialize(a, &snapshot, .save_as, "", null);
    defer a.free(bytes);
    var parsed = try manifest.parse(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.roots.len);
    try std.testing.expectError(error.NoSelection, fs.serialize(a, &snapshot, .remove, "", null));
    snapshot.roots = original;
    try std.testing.expectError(error.AbsolutePathRequired, fs.serialize(a, &snapshot, .add, "relative", null));
    try std.testing.expectError(error.EmbeddedNul, fs.serialize(a, &snapshot, .add, "/bad\x00path", null));
    var bad = original[0];
    var name: [257]u8 = @splat('a');
    bad.name = &name;
    snapshot.roots = &.{bad};
    try std.testing.expectError(error.TooLarge, fs.serialize(a, &snapshot, .save_as, "", null));
}

test "roots: nonblocking special-file source refuses" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    const source = try f.path("work.coral-workspace");
    defer a.free(source);
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(source));
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(source, 0o600));
    try std.testing.expectError(error.NotRegularFile, fs.prepare(a, .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id }, &.{}, f.cancel));
}

test "roots: source manifest alias preserves lexical base and alias retarget conflicts" {
    var f = try Fixture.init();
    defer f.deinit();
    var unused = try setup(&f, two);
    defer unused.deinit();
    try f.mkdir("sub");
    try f.symlink("../work.coral-workspace", "sub/alias.coral-workspace");
    var snapshot = try f.snapshot("sub/alias.coral-workspace");
    defer snapshot.deinit();
    const target = try f.path("new.coral-workspace");
    defer a.free(target);
    var p = try fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel);
    defer p.deinit();
    try fs.apply(&p, &.{}, f.cancel);
    var saved = try f.snapshot("new.coral-workspace");
    defer saved.deinit();
    const lexical = try f.path("sub/one");
    defer a.free(lexical);
    try std.testing.expectEqualStrings(lexical, saved.roots[0].path);
    var edit = try fs.prepare(a, .{ .kind = .remove, .snapshot = &snapshot, .selected = snapshot.roots[0].id }, &.{}, f.cancel);
    defer edit.deinit();
    try f.write("other.coral-workspace", two);
    const alias = try f.path("sub/alias.coral-workspace");
    defer a.free(alias);
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlink(alias));
    try f.symlink("../other.coral-workspace", "sub/alias.coral-workspace");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&edit, &.{}, f.cancel));
    try f.contents("work.coral-workspace", two);
    try f.contents("other.coral-workspace", two);
}

test "roots: Save As refuses directory FIFO and a changed destination parent" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, one);
    defer snapshot.deinit();
    const dir = try f.path("two");
    defer a.free(dir);
    try std.testing.expectError(error.AlreadyExists, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = dir }, &.{}, f.cancel));
    const fifo = try f.path("fifo");
    defer a.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    try std.testing.expectError(error.AlreadyExists, fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = fifo }, &.{}, f.cancel));
    const target = try f.path("two/saved.coral-workspace");
    defer a.free(target);
    var p = try fs.prepare(a, .{ .kind = .save_as, .snapshot = &snapshot, .path = target }, &.{}, f.cancel);
    defer p.deinit();
    const moved = try f.path("moved");
    defer a.free(moved);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rename(dir, moved));
    try f.mkdir("two");
    try std.testing.expectError(error.StaleSnapshot, fs.apply(&p, &.{}, f.cancel));
    try std.testing.expectError(error.NotFound, native.read(a, target));
}

test "roots: capture and preparation allocation failures release all ownership" {
    var f = try Fixture.init();
    defer f.deinit();
    var snapshot = try setup(&f, two);
    defer snapshot.deinit();
    const source = try f.path("work.coral-workspace");
    defer a.free(source);
    var value = try model.Model.fromManifest(a, source);
    defer value.deinit();
    try std.testing.checkAllAllocationFailures(a, captureAllocationCase, .{&value});
    const target = try f.path("new.coral-workspace");
    defer a.free(target);
    const bound = try f.path("unrelated-missing-document");
    defer a.free(bound);
    try std.testing.checkAllAllocationFailures(a, prepareAllocationCase, .{ &snapshot, target, bound, f.cancel });
}
fn captureAllocationCase(allocator: std.mem.Allocator, value: *const model.Model) !void {
    var snapshot = try fs.Snapshot.capture(allocator, value);
    defer snapshot.deinit();
    const bytes = try fs.serialize(allocator, &snapshot, .save_as, "", null);
    defer allocator.free(bytes);
}
fn prepareAllocationCase(allocator: std.mem.Allocator, snapshot: *const fs.Snapshot, path: []const u8, bound: []const u8, cancel: *c.GCancellable) !void {
    var p = try fs.prepare(allocator, .{ .kind = .save_as, .snapshot = snapshot, .path = path }, &.{bound}, cancel);
    defer p.deinit();
}
