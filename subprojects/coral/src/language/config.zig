//! Only this user-owned file supplies executable configuration. No workspace lookup.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const p = @import("protocol.zig");
const f = @import("features.zig");
const transport = @import("transport.zig");
pub const max_bytes = 64 * 1024;
pub const Digest = [32]u8;
pub const Identity = struct { major: u32, minor: u32, inode: u64, birth_seconds: i64, birth_nanoseconds: u32 };
pub const Binding = struct {
    digest: Digest,
    identities: [4]?Identity,
    pub fn same(self: Binding, other: Binding) bool {
        return std.mem.eql(u8, &self.digest, &other.digest) and std.meta.eql(self.identities, other.identities);
    }
};
pub const Server = struct { language: []const u8, argv: []const []const u8, env: []const transport.Environment, cwd: []const u8 };
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    servers: []const Server,
    digest: Digest,
    identities: [4]?Identity = @splat(null),
    pub fn binding(self: *const Config) Binding {
        return .{ .digest = self.digest, .identities = self.identities };
    }
    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
    pub fn find(self: *const Config, language: []const u8) ?Server {
        for (self.servers) |server| if (std.mem.eql(u8, server.language, language)) return server;
        return null;
    }
};
const defaults =
    \\{"version":1,"servers":[{"language":"zig","argv":["/usr/bin/zls"],"env":{"PATH":"/usr/bin:/bin"},"cwd":"root"}]}
;
/// Blocking, bounded work: callers must run this off the GTK thread. Parent
/// identity is part of authorization even when replacement contents are equal.
pub fn load() !Config {
    const before = try captureIdentity();
    var result = try loadContents();
    errdefer result.deinit();
    const after = try captureIdentity();
    if (!std.meta.eql(before, after)) return error.LanguageConfigChangedDuringRead;
    result.identities = after;
    return result;
}
fn captureIdentity() ![4]?Identity {
    const home = c.g_get_home_dir();
    if (home == null or !std.fs.path.isAbsolute(std.mem.span(home))) return error.HomeUnavailable;
    var result: [4]?Identity = @splat(null);
    const suffixes = [_][]const u8{ "", "/.config", "/.config/coral", "/.config/coral/languages.json" };
    for (suffixes, 0..) |suffix, i| {
        const path = u.fmt("{s}{s}", .{ std.mem.span(home), suffix });
        defer u.a.free(path);
        var stat: std.os.linux.Statx = undefined;
        if (std.c.statx(std.c.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .INO = true, .BTIME = true }, &stat) != 0) {
            if (std.c.errno(@as(c_int, -1)) == .NOENT and i != 0) break;
            return error.LanguageConfigIdentityUnavailable;
        }
        if (!stat.mask.TYPE or !stat.mask.INO or !stat.mask.BTIME) return error.LanguageConfigIdentityUnavailable;
        if (stat.mode & std.c.S.IFMT != (if (i == 3) @as(u16, std.c.S.IFREG) else std.c.S.IFDIR)) return error.LanguageConfigUnsafePath;
        result[i] = .{ .major = stat.dev_major, .minor = stat.dev_minor, .inode = stat.ino, .birth_seconds = stat.btime.sec, .birth_nanoseconds = stat.btime.nsec };
    }
    return result;
}
fn loadContents() !Config {
    const home = c.g_get_home_dir();
    if (home == null) return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(std.mem.span(home))) return error.HomeMustBeAbsolute;
    const path = u.fmt("{s}/.config/coral/languages.json", .{std.mem.span(home)});
    defer u.a.free(path);
    // Open nonblocking before inspecting the same descriptor: a FIFO/device or
    // a raced symlink must not block the GTK thread or supply executable config.
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) {
        if (std.c.errno(fd) == .NOENT) return parse(defaults);
        return error.LanguageConfigUnreadable;
    }
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true }, &st) != 0) return error.LanguageConfigStat;
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG or st.uid != std.c.geteuid() or st.mode & 0o022 != 0) return error.LanguageConfigNotUserOwned;
    if (st.size > max_bytes) return error.LanguageConfigTooLarge;
    var bytes: [max_bytes + 1]u8 = undefined;
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.LanguageConfigUnreadable;
        }
        if (n == 0) break;
        used += @intCast(n);
    }
    if (used > max_bytes) return error.LanguageConfigTooLarge;
    return parse(bytes[0..used]);
}
pub fn parse(bytes: []const u8) !Config {
    try p.boundedJson(bytes, max_bytes, 12);
    var arena = std.heap.ArenaAllocator.init(u.a);
    errdefer arena.deinit();
    const a = arena.allocator();
    const value = (try p.parseMessage(a, bytes)).value;
    try fields(value, &.{ "version", "servers" });
    if (try f.integer(try f.required(value, "version")) != 1) return error.LanguageConfigVersion;
    const raw = try f.array(try f.required(value, "servers"), 32);
    const servers = try a.alloc(Server, raw.len);
    for (raw, servers, 0..) |item, *server, i| {
        try fields(item, &.{ "language", "argv", "env", "cwd" });
        const language = try f.string(try f.required(item, "language"));
        if (language.len == 0 or language.len > 64) return error.InvalidLanguage;
        for (servers[0..i]) |prior| if (std.mem.eql(u8, language, prior.language)) return error.DuplicateLanguage;
        const args = try f.array(try f.required(item, "argv"), 64);
        if (args.len == 0) return error.EmptyArgv;
        const argv = try a.alloc([]const u8, args.len);
        for (args, argv) |arg, *out| {
            out.* = try f.string(arg);
            try safeString(out.*);
        }
        if (!std.fs.path.isAbsolute(argv[0])) return error.ExecutableMustBeAbsolute;
        const cwd = if (f.field(item, "cwd")) |v| try f.string(v) else "root";
        if (!std.mem.eql(u8, cwd, "root")) return error.CwdMustBeRoot;
        var env: std.ArrayList(transport.Environment) = .empty;
        if (f.field(item, "env")) |v| {
            try f.object(v);
            if (v.object.count() > 64) return error.EnvironmentLimit;
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const name = entry.key_ptr.*;
                const val = try f.string(entry.value_ptr.*);
                try safeString(name);
                try safeString(val);
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return error.InvalidEnvironment;
                try env.append(a, .{ .name = name, .value = val });
            }
        }
        // HOME is explicit and user-owned, needed by ZLS for caches. No arbitrary
        // parent environment (LD_PRELOAD etc.) is inherited by the transport.
        var has_home = false;
        for (env.items) |entry| if (std.mem.eql(u8, entry.name, "HOME")) {
            has_home = true;
        };
        if (!has_home) if (c.g_get_home_dir()) |home| try env.append(a, .{ .name = "HOME", .value = try a.dupe(u8, std.mem.span(home)) });
        server.* = .{ .language = language, .argv = argv, .env = env.items, .cwd = cwd };
    }
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .arena = arena, .servers = servers, .digest = digest };
}
fn fields(value: std.json.Value, allowed: []const []const u8) !void {
    try f.object(value);
    for (value.object.keys()) |key| {
        var known = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownLanguageConfigField;
    }
}
fn safeString(text: []const u8) !void {
    if (text.len > 8192 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidConfigString;
}

test "language config approval binds both contents and parent incarnation" {
    var original = try parse(defaults);
    defer original.deinit();
    const identity: Identity = .{ .major = 8, .minor = 1, .inode = 42, .birth_seconds = 100, .birth_nanoseconds = 0 };
    original.identities[2] = identity;
    const before = original.binding();
    try std.testing.expect(before.same(original.binding()));
    original.identities[2].?.inode += 1;
    try std.testing.expect(!before.same(original.binding()));
    original.identities[2] = identity;
    original.identities[2].?.birth_seconds += 1;
    try std.testing.expect(!before.same(original.binding()));
    original.identities[2] = null;
    try std.testing.expect(!before.same(original.binding()));
    original.identities[2] = identity;
    original.digest[0] ^= 1;
    try std.testing.expect(!before.same(original.binding()));
}

test "language config uses versioned absolute executable argv and root cwd" {
    var cfg = try parse(defaults);
    defer cfg.deinit();
    const server = cfg.find("zig").?;
    try std.testing.expectEqualStrings("/usr/bin/zls", server.argv[0]);
    try std.testing.expectEqualStrings("root", server.cwd);
    try std.testing.expectError(error.ExecutableMustBeAbsolute, parse("{\"version\":1,\"servers\":[{\"language\":\"zig\",\"argv\":[\"zls\"]}]}"));
    try std.testing.expectError(error.LanguageConfigVersion, parse("{\"version\":2,\"servers\":[]}"));
    try std.testing.expectError(error.UnknownLanguageConfigField, parse("{\"version\":1,\"servers\":[],\"command\":\"bad\"}"));
    try std.testing.expectError(error.CwdMustBeRoot, parse("{\"version\":1,\"servers\":[{\"language\":\"zig\",\"argv\":[\"/usr/bin/zls\"],\"cwd\":\".\"}]}"));
}
