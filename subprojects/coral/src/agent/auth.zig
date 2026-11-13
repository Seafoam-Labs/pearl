//! External authentication configuration and secret handling.
//!
//! API keys are resolved from user config first, then from an environment
//! variable named by the config (never a hardcoded default secret). Secrets
//! are never written to logs; `redact` scrubs them from any rendered text.
//!
//! Config lives at `$XDG_CONFIG_HOME/coral/auth.json` (or
//! `~/.config/coral/auth.json`). Schema:
//!   { "providers": { "openai": { "api_key": "...", "api_key_env": "OPENAI_API_KEY",
//!                                "base_url": "https://api.openai.com/v1" } } }
//! `base_url` is always user-supplied; the backend never substitutes a proxy.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Environment lookup abstraction so tests never mutate the real environment.
pub const Env = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8 = systemGet,

    pub fn lookup(self: Env, name: []const u8) ?[]const u8 {
        return self.get(self.ctx, name);
    }
};

/// Reads the process environment via libc. Returned memory is owned by the
/// C runtime and is valid until the environment changes.
pub fn systemGet(_: ?*anyopaque, name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = std.c.getenv(buf[0..name.len :0]) orelse return null;
    return std.mem.span(ptr);
}

pub const ProviderAuth = struct {
    api_key: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
};

pub const AuthConfig = struct {
    allocator: Allocator,
    providers: std.StringHashMap(ProviderAuth),

    pub fn init(allocator: Allocator) AuthConfig {
        return .{ .allocator = allocator, .providers = std.StringHashMap(ProviderAuth).init(allocator) };
    }

    pub fn deinit(self: *AuthConfig) void {
        var it = self.providers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const v = entry.value_ptr.*;
            if (v.api_key) |s| self.allocator.free(s);
            if (v.api_key_env) |s| self.allocator.free(s);
            if (v.base_url) |s| self.allocator.free(s);
        }
        self.providers.deinit();
    }

    /// Load config from `path`. A missing file yields an empty config.
    pub fn load(allocator: Allocator, io: Io, path: []const u8) !AuthConfig {
        var config = AuthConfig.init(allocator);
        errdefer config.deinit();
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return config,
            else => return err,
        };
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidAuthConfig;
        const providers = root.object.get("providers") orelse return config;
        if (providers != .object) return error.InvalidAuthConfig;
        var it = providers.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;
            var auth: ProviderAuth = .{};
            if (val.object.get("api_key")) |v| if (v == .string) {
                auth.api_key = try allocator.dupe(u8, v.string);
            };
            if (val.object.get("api_key_env")) |v| if (v == .string) {
                auth.api_key_env = try allocator.dupe(u8, v.string);
            };
            if (val.object.get("base_url")) |v| if (v == .string) {
                auth.base_url = try allocator.dupe(u8, v.string);
            };
            const key = try allocator.dupe(u8, name);
            try config.providers.put(key, auth);
        }
        return config;
    }

    /// Resolve an API key for `provider`: explicit config key first, then the
    /// configured environment variable. Returns an owned slice or null.
    pub fn resolveApiKey(self: *const AuthConfig, allocator: Allocator, provider: []const u8, env: Env) !?[]u8 {
        const auth = self.providers.get(provider) orelse return null;
        if (auth.api_key) |key| return try allocator.dupe(u8, key);
        if (auth.api_key_env) |name| {
            if (env.lookup(name)) |value| return try allocator.dupe(u8, value);
        }
        return null;
    }

    pub fn baseUrl(self: *const AuthConfig, provider: []const u8) ?[]const u8 {
        const auth = self.providers.get(provider) orelse return null;
        return auth.base_url;
    }
};

/// Default config path honoring XDG. Caller owns the result.
pub fn defaultConfigPath(allocator: Allocator, env: Env) ![]u8 {
    const base = env.lookup("XDG_CONFIG_HOME") orelse blk: {
        const home = env.lookup("HOME") orelse return error.NoHomeDirectory;
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer if (env.lookup("XDG_CONFIG_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "coral", "auth.json" });
}

/// Replace every occurrence of each secret with a placeholder. Used before
/// logging or surfacing provider errors so keys never leak.
pub fn redact(allocator: Allocator, text: []const u8, secrets: []const []const u8) ![]u8 {
    var current = try allocator.dupe(u8, text);
    for (secrets) |secret| {
        if (secret.len == 0) continue;
        const replaced = try std.mem.replaceOwned(u8, allocator, current, secret, "[REDACTED]");
        allocator.free(current);
        current = replaced;
    }
    return current;
}

test "redact scrubs secrets" {
    const a = std.testing.allocator;
    const out = try redact(a, "key=sk-secret-123 and sk-secret-123 again", &.{"sk-secret-123"});
    defer a.free(out);
    try std.testing.expectEqualStrings("key=[REDACTED] and [REDACTED] again", out);
}

test "Env fake lookup and resolveApiKey precedence" {
    const a = std.testing.allocator;
    const Fake = struct {
        fn get(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "MY_KEY")) return "env-value";
            return null;
        }
    };
    const env: Env = .{ .get = Fake.get };
    try std.testing.expectEqualStrings("env-value", env.lookup("MY_KEY").?);
    try std.testing.expect(env.lookup("ABSENT") == null);

    var config = AuthConfig.init(a);
    defer config.deinit();
    try config.providers.put(try a.dupe(u8, "openai"), .{
        .api_key = try a.dupe(u8, "config-value"),
        .api_key_env = try a.dupe(u8, "MY_KEY"),
    });
    const key = (try config.resolveApiKey(a, "openai", env)).?;
    defer a.free(key);
    try std.testing.expectEqualStrings("config-value", key);
}

test "defaultConfigPath honors XDG" {
    const a = std.testing.allocator;
    const Fake = struct {
        fn get(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "XDG_CONFIG_HOME")) return "/xdg";
            return null;
        }
    };
    const path = try defaultConfigPath(a, .{ .get = Fake.get });
    defer a.free(path);
    try std.testing.expectEqualStrings("/xdg/coral/auth.json", path);
}
