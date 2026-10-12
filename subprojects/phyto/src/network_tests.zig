const std = @import("std");
const u = @import("ui.zig");
const c = @import("platform/connections.zig");
const t = std.testing;
fn normalized(input: []const u8, expected: []const u8) !void {
    const actual = try c.normalize(input);
    defer u.a.free(actual);
    try t.expectEqualStrings(expected, actual);
}
test "network URI normalization retains account and escaped path identity" {
    try normalized("SMB://NAS.example:445/Design", "smb://nas.example/Design");
    try normalized("sftp://zoey@DEV.example:22/home/Zoey/My%20Files", "sftp://zoey@dev.example/home/Zoey/My%20Files");
    try normalized("sftp://[::1]:2222/home/zoey", "sftp://[::1]:2222/home/zoey");
    try normalized("davs://CLOUD.example:443/Archive", "davs://cloud.example/Archive");
    try normalized("dav://cloud.example:8080/", "dav://cloud.example:8080/");
    try normalized("sftp://server/My Files", "sftp://server/My%20Files");
    for ([_][]const u8{ "", "file:///tmp", "ftp://server/data", "sftp:///path", "sftp://user:secret@server/a", "sftp://user%3Asecret@server/a", "dav://server/a?token=secret", "davs://server/#fragment", "smb://server:99999/a", "smb://server:0/a", "smb://bad host/a", "smb://server/a\n" }) |bad| try t.expectError(error.InvalidAddress, c.normalize(bad));
}
test "SMB shares and SFTP accounts use appropriate single-flight identities" {
    const one = c.mountKey("smb://user@host/Design/One");
    defer u.a.free(one);
    const two = c.mountKey("smb://user@host/Design/Two");
    defer u.a.free(two);
    const other = c.mountKey("smb://user@host/Other");
    defer u.a.free(other);
    try t.expectEqualStrings(one, two);
    try t.expect(!c.eq(one, other));
    const sftp = c.mountKey("sftp://alice@host/folder");
    defer u.a.free(sftp);
    const sftp2 = c.mountKey("sftp://bob@host/folder");
    defer u.a.free(sftp2);
    try t.expect(!c.eq(sftp, sftp2));
}
const Fixture = struct {
    dir: [*:0]u8,
    path: [:0]u8,
    fn init() Fixture {
        const dir = g_dir_make_tmp("phyto-connections-XXXXXX", null).?;
        return .{ .dir = dir, .path = u.format("{s}/connections.ini", .{dir}) };
    }
    fn deinit(self: Fixture) void {
        _ = u.glib.unlink(self.path);
        const lock = u.format("{s}.lock", .{self.path});
        defer u.a.free(lock);
        _ = u.glib.unlink(lock);
        _ = u.glib.rmdir(self.dir);
        u.glib.free(self.dir);
        u.a.free(self.path);
    }
    fn write(self: Fixture, bytes: []const u8) void {
        const f = u.gio.File.newForPath(self.path);
        defer f.unref();
        std.debug.assert(f.replaceContents(bytes.ptr, bytes.len, null, 0, .{ .private = true }, null, null, null) != 0);
    }
};
test "profile save reload edit duplicate remove and credentials rejection" {
    const f = Fixture.init();
    defer f.deinit();
    var store = c.Store.init(f.path);
    defer store.deinit();
    const id = try store.put(null, "Studio NAS", "smb://NAS.example/Design", .on_open);
    defer u.a.free(id);
    const click = try store.put(null, "Dev", "sftp://dev.example/home/zoey", .on_click);
    defer u.a.free(click);
    store.reload();
    try t.expectEqual(@as(usize, 2), store.profiles.items.len);
    try t.expectEqual(c.Policy.on_open, store.get(id).?.policy);
    try t.expectEqual(c.Policy.on_click, store.get(click).?.policy);
    try t.expectError(error.Duplicate, store.put(null, "Duplicate", "smb://nas.example:445/Design", .on_click));
    try t.expectError(error.InvalidAddress, store.put(null, "Password", "sftp://user:secret@host/a", .on_click));
    const changed = try store.put(id, "New name", "smb://nas.example/Design", .on_click);
    u.a.free(changed);
    try t.expectEqualStrings("New name", store.get(id).?.name);
    try store.remove(id);
    store.reload();
    try t.expect(store.get(id) == null);
    try t.expect(store.get(click) != null);
}
test "external writers conflict instead of losing data including initial creation" {
    const f = Fixture.init();
    defer f.deinit();
    var first = c.Store.init(f.path);
    defer first.deinit();
    var second = c.Store.init(f.path);
    defer second.deinit();
    const id = try first.put(null, "First", "sftp://one/a", .on_click);
    defer u.a.free(id);
    try t.expectError(error.Conflict, second.put(null, "Second", "sftp://two/a", .on_click));
    second.reload();
    const id2 = try second.put(null, "Second", "sftp://two/a", .on_click);
    defer u.a.free(id2);
    try t.expectError(error.Conflict, first.remove(id));
    first.reload();
    try t.expectEqual(@as(usize, 2), first.profiles.items.len);
}
test "unknown policy defaults on-click, unknown fields survive, bad records skip, future schema read-only" {
    const f = Fixture.init();
    defer f.deinit();
    const id = "80d434a0-1df1-4c15-bc77-2d44fc51e5a6";
    f.write("[Connections]\nversion=1\nfuture=keep\n[Connection " ++ id ++ "]\nname=Good\nuri=davs://cloud.example/a\nreconnect=invalid\nextra=keep\n[Connection broken]\nname=Broken\nuri=sftp://host\n");
    var store = c.Store.init(f.path);
    defer store.deinit();
    try t.expectEqual(@as(usize, 1), store.profiles.items.len);
    try t.expectEqual(c.Policy.on_click, store.get(id).?.policy);
    try t.expect(store.warning != null);
    const edited = try store.put(id, "Edited", "davs://cloud.example/a", .on_open);
    u.a.free(edited);
    const kept = store.key.getString("Connection " ++ id, "extra", null).?;
    defer u.glib.free(kept);
    try t.expectEqualStrings("keep", std.mem.span(kept));
    f.write("[Connections]\nversion=99\n");
    store.reload();
    try t.expectError(error.ReadOnly, store.put(null, "Test", "smb://nas/share", .on_click));
    f.write("garbage\n");
    store.reload();
    try t.expect(!store.writable);
}
test "failed write leaves the in-memory profile unchanged" {
    const f = Fixture.init();
    defer f.deinit();
    var store = c.Store.init(f.path);
    defer store.deinit();
    const id = try store.put(null, "Keep", "dav://host/a", .on_click);
    defer u.a.free(id);
    // Deterministic failure even when the suite is run by root.
    const old = store.path;
    store.path = c.dup("/proc/phyto-no-such-directory/connections.ini");
    defer {
        u.a.free(store.path);
        store.path = old;
    }
    try t.expectError(error.SaveFailed, store.put(id, "Lost", "dav://host/a", .on_open));
    try t.expectEqualStrings("Keep", store.get(id).?.name);
}

extern "c" fn g_dir_make_tmp([*:0]const u8, ?*?*u.glib.Error) ?[*:0]u8;
