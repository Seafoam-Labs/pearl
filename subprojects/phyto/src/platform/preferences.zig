//! Small, process-shared preferences. File identities are stored as URIs.
const std = @import("std");
const u = @import("../ui.zig");
const a = u.a;
const gio = u.gio;
const glib = u.glib;
pub const Sort = enum { name, size, type, modified };
pub const Preferences = struct {
    key: *glib.KeyFile,
    path: [:0]u8,
    references: usize = 1,
    advanced: bool = false,
    allow_delete: bool = false,
    sort: Sort = .name,
    reverse: bool = false,
    folders_first: bool = true,
    save_error: bool = false,
    pub fn acquire() *Preferences {
        if (shared) |p| {
            p.references += 1;
            return p;
        }
        const p = a.create(Preferences) catch unreachable;
        const path = u.format("{s}/phyto/preferences.ini", .{glib.getUserConfigDir()});
        const key = glib.KeyFile.new();
        _ = key.loadFromFile(path, .{}, null);
        p.* = .{ .key = key, .path = path };
        p.advanced = key.getBoolean("Menus", "advanced", null) != 0;
        p.allow_delete = key.getBoolean("Menus", "permanent-delete", null) != 0;
        p.reverse = key.getBoolean("View", "reverse", null) != 0;
        if (key.hasKey("View", "folders-first", null) != 0) p.folders_first = key.getBoolean("View", "folders-first", null) != 0;
        if (key.getString("View", "sort", null)) |s| {
            defer glib.free(s);
            p.sort = std.meta.stringToEnum(Sort, std.mem.span(s)) orelse .name;
        }
        shared = p;
        return p;
    }
    pub fn release(self: *Preferences) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.key.unref();
        a.free(self.path);
        a.destroy(self);
        shared = null;
    }
    pub fn save(self: *Preferences) void {
        self.key.setBoolean("Menus", "advanced", @intFromBool(self.advanced));
        self.key.setBoolean("Menus", "permanent-delete", @intFromBool(self.allow_delete));
        self.key.setString("View", "sort", @tagName(self.sort));
        self.key.setBoolean("View", "reverse", @intFromBool(self.reverse));
        self.key.setBoolean("View", "folders-first", @intFromBool(self.folders_first));
        const dir = u.format("{s}/phyto", .{glib.getUserConfigDir()});
        defer a.free(dir);
        if (glib.mkdirWithParents(dir, 0o700) != 0) {
            self.save_error = true;
            return;
        }
        var n: usize = 0;
        const bytes = self.key.toData(&n, null) orelse {
            self.save_error = true;
            return;
        };
        defer glib.free(bytes);
        const f = gio.File.newForPath(self.path);
        defer f.unref();
        self.save_error = f.replaceContents(bytes, n, null, 0, .{ .private = true }, null, null, null) == 0;
    }
    pub fn strings(self: *Preferences, key: [*:0]const u8) ?[*:null]?[*:0]u8 {
        return self.key.getStringList("Files", key, null, null);
    }
    pub fn contains(self: *Preferences, key: [*:0]const u8, file: *gio.File) bool {
        const uri = file.getUri();
        defer glib.free(uri);
        const entries = self.strings(key) orelse return false;
        defer glib.strfreev(entries);
        for (std.mem.span(entries)) |entry| if (std.mem.eql(u8, std.mem.span(entry.?), std.mem.span(uri))) return true;
        return false;
    }
    pub fn toggle(self: *Preferences, key: [*:0]const u8, file: *gio.File) void {
        const uri = file.getUri();
        defer glib.free(uri);
        const entries = self.strings(key);
        defer if (entries) |e| glib.strfreev(e);
        var values: std.ArrayList(?[*:0]const u8) = .empty;
        defer values.deinit(a);
        var found = false;
        if (entries) |e| for (std.mem.span(e)) |entry| {
            if (std.mem.eql(u8, std.mem.span(entry.?), std.mem.span(uri))) found = true else values.append(a, entry.?) catch unreachable;
        };
        if (!found) values.append(a, uri) catch unreachable;
        const n = values.items.len;
        values.append(a, null) catch unreachable;
        self.key.setStringList("Files", key, @ptrCast(values.items.ptr), n);
        self.save();
    }
    pub fn relocated(self: *Preferences, source: *gio.File, destination: *gio.File) bool {
        var changed = false;
        inline for (.{ "bookmarks", "favorites", "pinned" }) |key| {
            if (self.contains(key, source)) {
                self.toggle(key, source);
                if (!self.contains(key, destination)) self.toggle(key, destination);
                changed = true;
                if (std.mem.eql(u8, key, "bookmarks")) {
                    const old_key = nameKey(source);
                    defer a.free(old_key);
                    if (self.key.getString("Bookmark names", old_key, null)) |name| {
                        defer glib.free(name);
                        self.renameBookmark(destination, name);
                        _ = self.key.removeKey("Bookmark names", old_key, null);
                    }
                }
            }
        }
        if (changed) self.save();
        return changed;
    }
    pub fn addBookmark(self: *Preferences, file: *gio.File) void {
        if (!self.contains("bookmarks", file)) self.toggle("bookmarks", file);
    }
    pub fn removeBookmark(self: *Preferences, file: *gio.File) void {
        if (self.contains("bookmarks", file)) self.toggle("bookmarks", file);
    }
    fn nameKey(file: *gio.File) [:0]u8 {
        const uri = file.getUri();
        defer glib.free(uri);
        const digest = std.crypto.hash.sha2.Sha256.hash;
        var hash: [32]u8 = undefined;
        digest(std.mem.span(uri), &hash, .{});
        return u.format("{s}", .{std.fmt.bytesToHex(hash, .lower)});
    }
    pub fn renameBookmark(self: *Preferences, file: *gio.File, name: [*:0]const u8) void {
        const key = nameKey(file);
        defer a.free(key);
        self.key.setString("Bookmark names", key, name);
        self.save();
    }
    pub fn bookmarkName(self: *Preferences, file: *gio.File) [*:0]u8 {
        const key = nameKey(file);
        defer a.free(key);
        return self.key.getString("Bookmark names", key, null) orelse file.getBasename() orelse glib.strdup("Bookmark");
    }
};
var shared: ?*Preferences = null;
