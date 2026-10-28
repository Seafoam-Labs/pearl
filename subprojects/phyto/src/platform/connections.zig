//! Saved remote locations. No credentials or transient mount state belong here.
const std = @import("std");
const u = @import("../ui.zig");
const a = u.a;
const glib = u.glib;
const gio = u.gio;
pub const Policy = enum { on_click, on_open };
pub const Profile = struct {
    id: [:0]u8,
    name: [:0]u8,
    uri: [:0]u8,
    policy: Policy,
    pub fn deinit(self: Profile) void {
        a.free(self.id);
        a.free(self.name);
        a.free(self.uri);
    }
};
pub const Error = error{ InvalidAddress, InvalidName, Duplicate, ReadOnly, SaveFailed, Conflict, Missing };
pub fn dup(value: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, value, 0) catch unreachable;
}
pub fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn normalize(text: []const u8) Error![:0]u8 {
    if (text.len == 0 or text.len > 8192 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidAddress;
    for (text) |c| if (c < 0x20 or c == 0x7f) return error.InvalidAddress;
    const input = dup(std.mem.trim(u8, text, " "));
    defer a.free(input);
    const uri = glib.Uri.parse(input, .{ .has_password = true, .encoded_path = true }, null) orelse return error.InvalidAddress;
    defer uri.unref();
    const scheme = std.mem.span(uri.getScheme());
    const port: c_int = if (eq(scheme, "smb")) 445 else if (eq(scheme, "sftp")) 22 else if (eq(scheme, "dav")) 80 else if (eq(scheme, "davs")) 443 else return error.InvalidAddress;
    if (uri.getPassword() != null or uri.getQuery() != null or uri.getFragment() != null or uri.getPort() == 0) return error.InvalidAddress;
    const host = uri.getHost() orelse return error.InvalidAddress;
    if (host[0] == 0) return error.InvalidAddress;
    for (std.mem.span(host)) |c| if (c <= 0x20 or c == '/' or c == '\\' or c == '@') return error.InvalidAddress;
    // Reject decoded separators in user information as well as literal passwords.
    if (uri.getUser()) |user| for (std.mem.span(user)) |c| if (c < 0x20 or c == ':' or c == '@') return error.InvalidAddress;
    const lower = dup(std.mem.span(host));
    defer a.free(lower);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    const rebuilt = glib.Uri.buildWithUser(.{ .encoded_path = true }, uri.getScheme(), uri.getUser(), null, null, lower, if (uri.getPort() == port) -1 else uri.getPort(), if (uri.getPath()[0] == 0) "/" else uri.getPath(), null, null);
    defer rebuilt.unref();
    const result = rebuilt.toString();
    defer glib.free(result);
    return dup(std.mem.span(result));
}

/// Conservative mount grouping: account + authority; SMB shares remain distinct.
/// Prefix paths are encoded, so an encoded slash never becomes a separator.
pub fn mountKey(address: [:0]const u8) [:0]u8 {
    const uri = glib.Uri.parse(address, .{ .encoded = true }, null).?;
    defer uri.unref();
    const path = std.mem.span(uri.getPath());
    const share = if (eq(std.mem.span(uri.getScheme()), "smb") and path.len > 1) path[0..(std.mem.indexOfScalarPos(u8, path, 1, '/') orelse path.len)] else if (eq(std.mem.span(uri.getScheme()), "sftp")) "/" else path; // DAV servers may mount distinct roots.
    return u.format("{s}://{s}@{s}:{d}{s}", .{ uri.getScheme(), uri.getUserinfo() orelse "", uri.getHost().?, uri.getPort(), share });
}

pub const Store = struct {
    path: [:0]u8,
    key: *glib.KeyFile,
    profiles: std.ArrayList(Profile) = .empty,
    etag: ?[*:0]u8 = null,
    writable: bool = true,
    warning: ?[:0]const u8 = null,
    revision: u64 = 0,

    pub fn init(path: []const u8) Store {
        var self: Store = .{ .path = dup(path), .key = glib.KeyFile.new() };
        self.reload();
        return self;
    }
    pub fn deinit(self: *Store) void {
        self.clear();
        self.key.unref();
        a.free(self.path);
    }
    fn clear(self: *Store) void {
        for (self.profiles.items) |p| p.deinit();
        self.profiles.clearAndFree(a);
        if (self.etag) |e| glib.free(e);
        self.etag = null;
    }
    pub fn get(self: *Store, id: []const u8) ?*const Profile {
        for (self.profiles.items) |*p| if (eq(p.id, id)) return p;
        return null;
    }
    pub fn reload(self: *Store) void {
        const file = gio.File.newForPath(self.path);
        defer file.unref();
        var bytes: [*]u8 = undefined;
        var n: usize = 0;
        var tag: [*:0]u8 = undefined;
        var err: ?*glib.Error = null;
        self.clear();
        self.key.unref();
        self.key = glib.KeyFile.new();
        self.warning = null;
        self.writable = true;
        self.revision += 1;
        if (file.loadContents(null, &bytes, &n, &tag, &err) == 0) {
            if (err) |e| {
                defer e.free();
                if (e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.not_found)) == 0) {
                    self.writable = false;
                    self.warning = "Saved connections could not be read. Check configuration permissions.";
                }
            }
            return;
        }
        defer glib.free(bytes);
        self.etag = tag;
        if (n > 1024 * 1024 or self.key.loadFromData(@ptrCast(bytes), n, .{ .keep_comments = true, .keep_translations = true }, null) == 0) {
            self.writable = false;
            self.warning = "The connections file is invalid. Repair or move it before saving connections.";
            return;
        }
        if (self.key.getInteger("Connections", "version", null) != 1) {
            self.writable = false;
            self.warning = "This connections file has an unsupported version and will not be overwritten.";
            return;
        }
        const groups = self.key.getGroups(null);
        defer glib.strfreev(groups);
        for (std.mem.span(groups)) |group_| {
            const group = group_.?;
            const g = std.mem.span(group);
            if (!std.mem.startsWith(u8, g, "Connection ")) continue;
            const id = g[11.. :0];
            const name = self.key.getString(group, "name", null);
            defer if (name) |v| glib.free(v);
            const address = self.key.getString(group, "uri", null);
            defer if (address) |v| glib.free(v);
            if (glib.uuidStringIsValid(id) == 0 or name == null or address == null or !validName(std.mem.span(name.?))) {
                self.warning = "Some invalid saved connections were skipped. Repair them in connections.ini.";
                continue;
            }
            const uri = normalize(std.mem.span(address.?)) catch {
                self.warning = "Some invalid saved connections were skipped. Repair them in connections.ini.";
                continue;
            };
            var duplicate = false;
            for (self.profiles.items) |p| if (eq(p.uri, uri)) {
                duplicate = true;
                break;
            };
            if (duplicate) {
                a.free(uri);
                self.warning = "Duplicate saved connections were skipped.";
                continue;
            }
            const policy = self.key.getString(group, "reconnect", null);
            defer if (policy) |v| glib.free(v);
            self.profiles.append(a, .{ .id = dup(id), .name = dup(std.mem.span(name.?)), .uri = uri, .policy = if (policy != null and eq(std.mem.span(policy.?), "on-open")) .on_open else .on_click }) catch unreachable;
        }
    }
    pub fn put(self: *Store, id: ?[:0]const u8, name: []const u8, address: []const u8, policy: Policy) Error![:0]u8 {
        if (!validName(name)) return error.InvalidName;
        const uri = try normalize(address);
        defer a.free(uri);
        if (id) |v| if (self.get(v) == null) return error.Missing;
        for (self.profiles.items) |p| if (eq(p.uri, uri) and (id == null or !eq(p.id, id.?))) return error.Duplicate;
        const uuid = glib.uuidStringRandom();
        defer glib.free(uuid);
        const identity = dup(if (id) |v| v else std.mem.span(uuid));
        errdefer a.free(identity);
        const next = self.cloneKey();
        defer next.unref();
        const group = u.format("Connection {s}", .{identity});
        defer a.free(group);
        const label = dup(std.mem.trim(u8, name, " "));
        defer a.free(label);
        next.setInteger("Connections", "version", 1);
        next.setString(group, "name", label);
        next.setString(group, "uri", uri);
        next.setString(group, "reconnect", if (policy == .on_open) "on-open" else "on-click");
        try self.commit(next);
        return identity;
    }
    pub fn remove(self: *Store, id: [:0]const u8) Error!void {
        if (self.get(id) == null) return error.Missing;
        const next = self.cloneKey();
        defer next.unref();
        const group = u.format("Connection {s}", .{id});
        defer a.free(group);
        _ = next.removeGroup(group, null);
        try self.commit(next);
    }
    fn cloneKey(self: *Store) *glib.KeyFile {
        const next = glib.KeyFile.new();
        var n: usize = 0;
        const data = self.key.toData(&n, null).?;
        defer glib.free(data);
        _ = next.loadFromData(@ptrCast(data), n, .{ .keep_comments = true, .keep_translations = true }, null);
        return next;
    }
    fn commit(self: *Store, next: *glib.KeyFile) Error!void {
        if (!self.writable) return error.ReadOnly;
        const file = gio.File.newForPath(self.path);
        defer file.unref();
        const parent = file.getParent().?;
        defer parent.unref();
        const dir = parent.getPath().?;
        defer glib.free(dir);
        if (glib.mkdirWithParents(dir, 0o700) != 0) return error.SaveFailed;
        // Serialize cooperating Phyto writers including the first creation.
        const lockpath = u.format("{s}.lock", .{self.path});
        defer a.free(lockpath);
        const fd = open(lockpath, 0x42 | 0x80000 | 0x20000, @as(c_uint, 0o600)); // CREAT|RDWR|CLOEXEC|NOFOLLOW
        if (fd < 0) return error.SaveFailed;
        defer _ = close(fd);
        if (flock(fd, 2 | 4) != 0) return error.Conflict; // EX|NB: never block GTK
        defer _ = flock(fd, 8);
        const info = file.queryInfo("etag::value", .{}, null, null);
        defer if (info) |i| i.unref();
        const current = if (info) |i| i.getAttributeString("etag::value") else null;
        if ((current == null) != (self.etag == null) or (current != null and !eq(std.mem.span(current.?), std.mem.span(self.etag.?)))) return error.Conflict;
        var n: usize = 0;
        const data = next.toData(&n, null) orelse return error.SaveFailed;
        defer glib.free(data);
        var err: ?*glib.Error = null;
        if (file.replaceContents(data, n, self.etag, 0, .{ .private = true, .replace_destination = true }, null, null, &err) == 0) {
            if (err) |e| {
                defer e.free();
                if (e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.wrong_etag)) != 0) return error.Conflict;
            }
            return error.SaveFailed;
        }
        self.reload();
    }
};
fn validName(name: []const u8) bool {
    const clean = std.mem.trim(u8, name, " ");
    if (clean.len == 0 or clean.len > 256 or !std.unicode.utf8ValidateSlice(clean)) return false;
    for (clean) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}
pub fn errorText(err: Error) [:0]const u8 {
    return switch (err) {
        error.InvalidName => "Enter a connection name (up to 256 bytes, without control characters).",
        error.InvalidAddress => "Enter an SMB, SFTP or WebDAV URI with a valid host and port. Passwords, queries and fragments are not allowed.",
        error.Duplicate => "This address is already saved. Open its connection settings to edit it.",
        error.Conflict => "Connections changed in another process. Close and reopen this editor to review the latest settings.",
        error.ReadOnly => "This connections file cannot be edited. Check its version and permissions.",
        error.Missing => "This saved connection was removed. Close the editor and add it again if needed.",
        error.SaveFailed => "Connection was not saved. Check configuration permissions and try again.",
    };
}
extern "c" fn open([*:0]const u8, c_int, ...) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn flock(c_int, c_int) c_int;
