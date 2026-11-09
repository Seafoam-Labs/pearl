const std = @import("std");
const model = @import("model.zig");
const manifest = @import("manifest.zig");
const fs = @import("manifest_fs.zig");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;

test "manifest parent resolves relative roots; aliases deduplicate; names never identify roots" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("config");
    try f.mkdir("one");
    try f.mkdir("two");
    try f.symlink("one", "alias");
    try f.write("config/project.coral-workspace",
        \\{"version":1,"roots":[{"name":"same","path":"../one"},{"name":"ignored alias","path":"../alias"},{"name":"same","path":"../two"},{"path":"offline/child"}],"settings":{}}
    );
    const path = try f.path("config/project.coral-workspace");
    defer a.free(path);
    var value = try model.Model.fromManifest(a, path);
    defer value.deinit();
    try std.testing.expectEqual(model.Trust.restricted, value.trust);
    try std.testing.expectEqual(@as(usize, 3), value.roots.len);
    try std.testing.expectEqualStrings("same", value.roots[0].display_name);
    try std.testing.expectEqualStrings("same", value.roots[1].display_name);
    try std.testing.expect(value.roots[0].id != value.roots[1].id);
    try std.testing.expectEqual(value.roots[0].id, value.rootById(value.roots[0].id).?.id);
    try std.testing.expectEqual(model.Availability.missing, value.roots[2].availability);
    try std.testing.expect(value.roots[2].canonical_path == null);
    const one = try f.path("one");
    defer a.free(one);
    try std.testing.expectEqualStrings(one, value.roots[0].canonical_path.?);
    const lexical = try f.path("config/../one");
    defer a.free(lexical);
    try std.testing.expectEqualStrings(lexical, value.roots[0].lexical_path);
    const missing = try f.path("config/offline");
    defer a.free(missing);
    try std.testing.expectError(error.NotFound, fs.canonical(a, missing));
    const id = value.roots[0].id;
    _ = try value.ownerOfCanonicalPath(one);
    try std.testing.expectEqual(id, value.roots[0].id);
}

test "folder and manifest data are owned and workspace/root identities never collide" {
    var f = try Fixture.init();
    defer f.deinit();
    const input = try a.dupe(u8, f.base);
    defer a.free(input);
    var folder = try model.Model.fromFolder(a, input);
    defer folder.deinit();
    @memset(input, 'x');
    try std.testing.expectEqualStrings(f.base, folder.roots[0].lexical_path);
    try std.testing.expectEqualStrings(f.base, folder.roots[0].canonical_path.?);
    try std.testing.expectEqual(model.Availability.available, folder.roots[0].availability);
    const token = folder.scope.capture().?;
    const path = try f.path("project.coral-workspace");
    defer a.free(path);
    const json = try a.dupe(u8, "{\"version\":1,\"roots\":[{\"name\":\"owned\",\"path\":\".\"}],\"exclude\":[\"**/out/\",\"二/*.tmp\"]}");
    defer a.free(json);
    var other = try model.Model.fromManifestBytes(a, path, json);
    defer other.deinit();
    @memset(path, 'x');
    @memset(json, 'x');
    try std.testing.expectEqualStrings("owned", other.roots[0].display_name);
    try std.testing.expectEqual(@as(usize, 0), folder.exclude.len);
    try std.testing.expectEqual(@as(usize, 2), other.exclude.len);
    try std.testing.expectEqualStrings("**/out/", other.exclude[0]);
    try std.testing.expectEqualStrings("二/*.tmp", other.exclude[1]);
    try std.testing.expect(std.mem.endsWith(u8, other.manifest_path.?, "/project.coral-workspace"));
    try std.testing.expect(other.scope.id != folder.scope.id);
    try std.testing.expect(!other.scope.accepts(token));
    try std.testing.expect(other.roots[0].id != folder.roots[0].id);
    try std.testing.expect(other.rootById(folder.roots[0].id) == null);
    try std.testing.expect(model.RootId != model.identity.WorkspaceId);
}

test "physical symlink dot-dot traversal is not erased by lexical normalization" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("real");
    try f.mkdir("real/child");
    try f.symlink("real/child", "link");
    const p = try f.path("workspace.coral-workspace");
    defer a.free(p);
    var value = try model.Model.fromManifestBytes(a, p,
        \\{"version":1,"roots":[{"name":"physical","path":"link/.."},{"path":"real"}]}
    );
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 1), value.roots.len);
    const real = try f.path("real");
    defer a.free(real);
    try std.testing.expectEqualStrings(real, value.roots[0].canonical_path.?);
    try std.testing.expect(std.mem.endsWith(u8, value.roots[0].lexical_path, "/link/.."));
}

test "file ownership uses longest canonical component prefix and follows file aliases" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("root");
    try f.mkdir("root/nested");
    try f.mkdir("root-other");
    try f.write("root/nested/file", "contents");
    try f.write("root-other/file", "outside");
    try f.symlink("root/nested/file", "file-alias");
    try f.symlink("../root-other/file", "root/escape");
    const p = try f.path("project.coral-workspace");
    defer a.free(p);
    var value = try model.Model.fromManifestBytes(a, p,
        \\{"version":1,"roots":[{"path":"root/nested"},{"path":"root"},{"path":"missing"}]}
    );
    defer value.deinit();
    const nested = try f.path("root/nested/file");
    defer a.free(nested);
    const root = try f.path("root");
    defer a.free(root);
    const sibling = try f.path("root-other/file");
    defer a.free(sibling);
    const alias = try f.path("file-alias");
    defer a.free(alias);
    const escape = try f.path("root/escape");
    defer a.free(escape);
    try std.testing.expectEqual(value.roots[0].id, (try value.ownerOfCanonicalPath(nested)).?);
    try std.testing.expectEqual(value.roots[0].id, (try value.ownerOfPath(alias)).?);
    try std.testing.expectEqual(value.roots[1].id, (try value.ownerOfCanonicalPath(root)).?);
    try std.testing.expect(try value.ownerOfPath(escape) == null);
    try std.testing.expect(try value.ownerOfCanonicalPath(sibling) == null);
    try std.testing.expectError(error.InvalidSchema, value.ownerOfCanonicalPath("/tmp/../file"));
    try std.testing.expectError(error.InvalidSchema, value.ownerOfCanonicalPath("/tmp//file"));
    try std.testing.expectError(error.AbsolutePathRequired, value.ownerOfCanonicalPath("relative"));
    var filesystem = try model.Model.fromFolder(a, "/");
    defer filesystem.deinit();
    try std.testing.expectEqual(filesystem.roots[0].id, (try filesystem.ownerOfCanonicalPath(nested)).?);
    try std.testing.expectEqual(filesystem.roots[0].id, (try filesystem.ownerOfCanonicalPath("/")).?);
}

test "missing dangling looping non-directory and FIFO roots are retained without creation or reads" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.symlink("absent/child", "dangling");
    try f.symlink("loop", "loop");
    try f.write("file", "not a directory");
    try f.fifo("fifo");
    const p = try f.path("project.coral-workspace");
    defer a.free(p);
    var value = try model.Model.fromManifestBytes(a, p,
        \\{"version":1,"roots":[{"path":"absent/child"},{"path":"dangling"},{"path":"loop"},{"path":"file"},{"path":"fifo"},{"path":"file/child"}]}
    );
    defer value.deinit();
    const expected = [_]model.Availability{ .missing, .missing, .symlink_loop, .not_directory, .not_directory, .not_directory };
    try std.testing.expectEqual(expected.len, value.roots.len);
    for (value.roots, expected) |root, availability| {
        try std.testing.expectEqual(availability, root.availability);
        try std.testing.expect(root.canonical_path == null);
    }
    const absent = try f.path("absent");
    defer a.free(absent);
    try std.testing.expectError(error.NotFound, fs.canonical(a, absent));
    var folder = try model.Model.fromFolder(a, absent);
    defer folder.deinit();
    try std.testing.expectEqual(model.Availability.missing, folder.roots[0].availability);
    try std.testing.expectError(error.NotFound, folder.ownerOfPath(absent));
}

test "manifest read rejects directory FIFO FIFO symlink device missing and oversized files" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.fifo("fifo");
    try f.symlink("fifo", "alias");
    for ([_][]const u8{ "fifo", "alias" }) |name| {
        const p = try f.path(name);
        defer a.free(p);
        // No writer exists: a blocking open/read would hang the bounded test run.
        try std.testing.expectError(error.NotRegularFile, model.Model.fromManifest(a, p));
    }
    try std.testing.expectError(error.NotRegularFile, model.Model.fromManifest(a, f.base));
    try std.testing.expectError(error.NotRegularFile, model.Model.fromManifest(a, "/dev/null"));
    const absent = try f.path("absent.coral-workspace");
    defer a.free(absent);
    try std.testing.expectError(error.NotFound, model.Model.fromManifest(a, absent));
    const large = try a.alloc(u8, manifest.limits.manifest_bytes + 1);
    defer a.free(large);
    @memset(large, ' ');
    try f.write("large", large);
    const p = try f.path("large");
    defer a.free(p);
    try std.testing.expectError(error.TooLarge, model.Model.fromManifest(a, p));
}

test "symlink manifest uses the supplied containing directory and never scans children" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("config");
    try f.mkdir("root");
    try f.fifo("root/no-reader");
    try f.symlink("loop", "root/loop");
    try f.write("config/source", "{\"version\":1,\"roots\":[{\"path\":\"root\"}]}");
    try f.symlink("config/source", "alias.coral-workspace");
    const p = try f.path("alias.coral-workspace");
    defer a.free(p);
    var value = try model.Model.fromManifest(a, p);
    defer value.deinit();
    const root = try f.path("root");
    defer a.free(root);
    try std.testing.expectEqualStrings(root, value.roots[0].canonical_path.?);
}

test "absolute roots UTF-8 input canonical identity and joined path bounds" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("café");
    try f.mkdir("\xff");
    try f.symlink("\xff", "valid-alias");
    const invalid = try f.path("valid-alias");
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidUtf8, model.Model.fromFolder(a, invalid));
    try std.testing.expectError(error.InvalidUtf8, model.Model.fromFolder(a, "/tmp/\xff"));
    try std.testing.expectError(error.EmbeddedNul, model.Model.fromFolder(a, "/tmp/a\x00b"));
    try std.testing.expectError(error.AbsolutePathRequired, model.Model.fromFolder(a, "."));
    try std.testing.expectError(error.AbsolutePathRequired, model.Model.fromManifest(a, "https://example.invalid/workspace"));
    const utf8 = try f.path("café");
    defer a.free(utf8);
    const bytes = try std.fmt.allocPrint(a, "{{\"version\":1,\"roots\":[{{\"path\":\"{s}\"}}]}}", .{utf8});
    defer a.free(bytes);
    var value = try model.Model.fromManifestBytes(a, "/unused/project.coral-workspace", bytes);
    defer value.deinit();
    try std.testing.expectEqualStrings(utf8, value.roots[0].canonical_path.?);
    try std.testing.expectEqualStrings("café", value.roots[0].display_name);
    const long = try a.alloc(u8, manifest.limits.path_bytes);
    defer a.free(long);
    @memset(long, 'x');
    const oversized = try std.fmt.allocPrint(a, "{{\"version\":1,\"roots\":[{{\"path\":\"{s}\"}}]}}", .{long});
    defer a.free(oversized);
    try std.testing.expectError(error.TooLarge, model.Model.fromManifestBytes(a, "/parent/workspace", oversized));
}

test "permission-denied roots remain visible but unreadable manifests fail" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("denied");
    const denied = try f.path("denied");
    defer a.free(denied);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(denied, 0));
    defer std.debug.assert(std.c.chmod(denied, 0o700) == 0);
    var value = try model.Model.fromFolder(a, denied);
    defer value.deinit();
    try std.testing.expectEqual(model.Availability.permission_denied, value.roots[0].availability);
    try std.testing.expect(value.roots[0].canonical_path == null);
    try f.write("unreadable", "{\"version\":1,\"roots\":[]}");
    const p = try f.path("unreadable");
    defer a.free(p);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(p, 0));
    try std.testing.expectError(error.PermissionDenied, model.Model.fromManifest(a, p));
}

test "model accepts full byte limit and empty roots while retaining 32 unavailable declarations" {
    var f = try Fixture.init();
    defer f.deinit();
    const bytes = try a.alloc(u8, manifest.limits.manifest_bytes);
    defer a.free(bytes);
    @memset(bytes, ' ');
    const empty = "{\"version\":1,\"roots\":[]}";
    @memcpy(bytes[0..empty.len], empty);
    try f.write("workspace", bytes);
    const p = try f.path("workspace");
    defer a.free(p);
    var value = try model.Model.fromManifest(a, p);
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 0), value.roots.len);
    try std.testing.expect(try value.ownerOfCanonicalPath(f.base) == null);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try json.appendSlice(a, "{\"version\":1,\"roots\":[");
    for (0..manifest.limits.roots) |i| {
        if (i != 0) try json.append(a, ',');
        try json.appendSlice(a, "{\"name\":\"same\",\"path\":\"missing\"}");
    }
    const end = json.items.len;
    try json.appendSlice(a, "]}");
    var full = try model.Model.fromManifestBytes(a, p, json.items);
    defer full.deinit();
    try std.testing.expectEqual(manifest.limits.roots, full.roots.len);
    for (full.roots, 0..) |root, i| {
        try std.testing.expectEqual(model.Availability.missing, root.availability);
        for (full.roots[0..i]) |previous| try std.testing.expect(root.id != previous.id);
    }
    json.shrinkRetainingCapacity(end);
    try json.appendSlice(a, ",{\"path\":\"missing\"}]}");
    try std.testing.expectError(error.TooLarge, model.Model.fromManifestBytes(a, p, json.items));
}

fn allocationCase(allocator: std.mem.Allocator, path: []const u8) !void {
    var value = try model.Model.fromManifest(allocator, path);
    defer value.deinit();
    _ = try value.ownerOfPath(value.roots[0].lexical_path);
}

fn folderAllocationCase(allocator: std.mem.Allocator, path: []const u8) !void {
    var value = try model.Model.fromFolder(allocator, path);
    defer value.deinit();
}

test "model descriptor parser dedup and ownership allocation failures clean up" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.mkdir("root");
    try f.symlink("root", "alias");
    try f.write("workspace",
        \\{"version":1,"roots":[{"name":"one","path":"root"},{"path":"alias"},{"path":"missing"}],"exclude":["**/out/","二/*.tmp"]}
    );
    const p = try f.path("workspace");
    defer a.free(p);
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{p});
    try std.testing.checkAllAllocationFailures(a, folderAllocationCase, .{f.base});
}
