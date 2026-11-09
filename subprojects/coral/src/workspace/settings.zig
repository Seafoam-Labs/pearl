//! M2 SAFE SETTINGS ABI (worker/model/UI/trust integration contract).
//! Patch = { lines:?bool, wrap:?bool, spaces:?bool, indent:?u8 }, all null.
//! Baseline = { lines:bool=true, wrap:bool=true, spaces:bool=true, indent:u8=4 }.
//! KeyMask = { lines:bool=false, wrap:bool=false, spaces:bool=false, indent:bool=false }.
//! Platform owner must supply ACTUAL user-key presence (including explicit default
//! values); never infer it by comparing values. Baseline contains safe values only.
//! Config = { general:Patch, languages:[]const Language }; Language = { id:[]const u8, patch:Patch }.
//! Config owns language IDs: clone(allocator), deinit(allocator); empty .{} is valid.
//! Origin = enum { default, user, workspace, folder, workspace_language, folder_language }.
//! Origins has one Origin field per safe key; Effective = { values:Baseline,
//! origins:Origins, context:Context }; Context = { root_path:?[]const u8=null,
//! language:?[]const u8=null }, borrowed from caller/model, never retained internally.
//! resolve(user:Baseline, present:KeyMask, workspace:Config, folder:Config,
//! context:Context) Effective is pure/allocation-free. Order: defaults, supplied
//! user keys, workspace general, folder general, workspace language, folder language.
//! No user-language schema. Theme/font/dictionary/spelling remain platform-owned.
//! parse(allocator, bytes) parses version-1 {settings:{safe keys, languages:{ID:patch}}}.
//! Source <=64KiB, <=32 language IDs, ID <=64 bytes; unknown/duplicate/null keys
//! reject regardless of trust. Manifest.settings uses the same Config/schema.
//! Model.workspace_settings and Root.folder_settings own their Config lifetimes.
//! Model.policy_fingerprint:[32]u8 is canonical SHA-256 policy input, NOT a machine
//! filesystem identity/trust key. Covers manifest/root paths, settings and excludes.
//! Model constructors and rescan() perform WORKER-only folder config reads; errors
//! reject the whole candidate snapshot. Integrator retains the previous model.
//! rescan() returns a fresh Model; no live folder-settings watcher is promised.
//! settings_fs.load(allocator, canonical_root) reads optional .coral/settings.json
//! descriptor-relative with no symlink components/special files. Missing => .{};
//! all other failures reject. <=32 roots gives <=32*64KiB aggregate folder source.
const std = @import("std");

pub const limits = struct {
    pub const source_bytes = 64 * 1024;
    pub const languages = 32;
    pub const language_bytes = 64;
    pub const aggregate_folder_bytes = 32 * source_bytes;
};
pub const Error = error{ TooLarge, EmptyString, EmbeddedNul, InvalidUtf8, InvalidSchema, DuplicateField, UnknownField, UnsupportedVersion, UnsupportedSettings, OutOfMemory };
pub const Patch = struct { lines: ?bool = null, wrap: ?bool = null, spaces: ?bool = null, indent: ?u8 = null };
pub const Baseline = struct { lines: bool = true, wrap: bool = true, spaces: bool = true, indent: u8 = 4 };
pub const KeyMask = struct { lines: bool = false, wrap: bool = false, spaces: bool = false, indent: bool = false };
pub const Language = struct { id: []const u8, patch: Patch };
pub const Origin = enum { default, user, workspace, folder, workspace_language, folder_language };
pub const Origins = struct { lines: Origin = .default, wrap: Origin = .default, spaces: Origin = .default, indent: Origin = .default };
pub const Context = struct { root_path: ?[]const u8 = null, language: ?[]const u8 = null };
pub const Effective = struct { values: Baseline, origins: Origins, context: Context };
const keys = .{ "lines", "wrap", "spaces", "indent" };

/// Move-only owner. parse/clone produce owned strings; .{} needs no allocation.
/// Directly constructed borrowed configs may be resolved/hashed/cloned, not deinitialized.
pub const Config = struct {
    general: Patch = .{},
    languages: []const Language = &.{},

    pub fn clone(self: Config, allocator: std.mem.Allocator) Error!Config {
        const entries = try allocator.alloc(Language, self.languages.len);
        var count: usize = 0;
        errdefer {
            for (entries[0..count]) |entry| allocator.free(entry.id);
            allocator.free(entries);
        }
        for (self.languages, 0..) |entry, i| {
            entries[i] = .{ .id = try allocator.dupe(u8, entry.id), .patch = entry.patch };
            count += 1;
        }
        return .{ .general = self.general, .languages = entries };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.languages) |entry| allocator.free(entry.id);
        allocator.free(self.languages);
        self.* = .{};
    }

    pub fn forLanguage(self: Config, id: []const u8) Patch {
        for (self.languages) |entry| if (std.mem.eql(u8, id, entry.id)) return entry.patch;
        return .{};
    }

    /// Canonical encoding: fixed key order, sorted decoded language IDs, explicit
    /// absence tags. No JSON spelling, native integer endianness or struct padding.
    pub fn hashInto(self: Config, hash: *std.crypto.hash.sha2.Sha256) void {
        hashPatch(hash, self.general);
        hashLength(hash, self.languages.len);
        var previous: ?[]const u8 = null;
        for (0..self.languages.len) |_| {
            var next: ?Language = null;
            for (self.languages) |entry| {
                if (previous) |p| if (std.mem.order(u8, entry.id, p) != .gt) continue;
                if (next == null or std.mem.order(u8, entry.id, next.?.id) == .lt) next = entry;
            }
            const entry = next.?;
            hashField(hash, entry.id);
            hashPatch(hash, entry.patch);
            previous = entry.id;
        }
    }
};

pub fn resolve(user: Baseline, present: KeyMask, workspace: Config, folder: Config, context: Context) Effective {
    var result: Effective = .{ .values = .{}, .origins = .{}, .context = context };
    inline for (keys) |key| {
        if (@field(present, key)) {
            @field(result.values, key) = @field(user, key);
            @field(result.origins, key) = .user;
        }
    }
    apply(&result, workspace.general, .workspace);
    apply(&result, folder.general, .folder);
    if (context.language) |id| {
        apply(&result, workspace.forLanguage(id), .workspace_language);
        apply(&result, folder.forLanguage(id), .folder_language);
    }
    return result;
}

fn apply(result: *Effective, patch: Patch, origin: Origin) void {
    inline for (keys) |key| if (@field(patch, key)) |value| {
        @field(result.values, key) = value;
        @field(result.origins, key) = origin;
    };
}

pub fn hashLength(hash: *std.crypto.hash.sha2.Sha256, length: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(length), .little);
    hash.update(&bytes);
}
pub fn hashField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashLength(hash, bytes.len);
    hash.update(bytes);
}
fn hashPatch(hash: *std.crypto.hash.sha2.Sha256, patch: Patch) void {
    inline for (.{ "lines", "wrap", "spaces" }) |key| {
        hash.update(&.{if (@field(patch, key)) |v| if (v) @as(u8, 2) else 1 else 0});
    }
    hash.update(&.{patch.indent orelse 0});
}

/// Standalone folder document; settings is required, even if empty.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Config {
    if (bytes.len > limits.source_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var scanner: std.json.Scanner = .initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    var p: Parser = .{ .allocator = arena.allocator(), .scanner = &scanner };
    try p.expect(.object_begin);
    var seen: u8 = 0;
    var config: Config = .{};
    while (true) {
        const token = try p.next();
        if (token == .object_end) break;
        const key = try string(token);
        const bit: u8 = if (std.mem.eql(u8, key, "version")) 1 else if (std.mem.eql(u8, key, "settings")) 2 else return error.UnknownField;
        if (seen & bit != 0) return error.DuplicateField;
        seen |= bit;
        if (bit == 1) {
            const number = switch (try p.next()) {
                .number, .allocated_number => |n| n,
                else => return error.InvalidSchema,
            };
            if (!std.mem.eql(u8, number, "1")) return error.UnsupportedVersion;
        } else config = try parseObject(p.allocator, &scanner);
    }
    if (seen != 3) return error.InvalidSchema;
    try p.expect(.end_of_document);
    return config.clone(allocator);
}

/// Shared fixed-depth manifest parser. Storage belongs to the supplied arena;
/// caller deinitializes the arena, NOT this intermediate Config.
pub fn parseObject(arena: std.mem.Allocator, scanner: *std.json.Scanner) Error!Config {
    var p: Parser = .{ .allocator = arena, .scanner = scanner };
    var config: Config = .{};
    config.general = try p.patch(&config.languages);
    return config;
}

fn string(token: std.json.Token) Error![]const u8 {
    return switch (token) {
        .string, .allocated_string => |s| s,
        else => error.InvalidSchema,
    };
}
const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: *std.json.Scanner,

    fn next(self: *Parser) Error!std.json.Token {
        return self.scanner.nextAllocMax(self.allocator, .alloc_always, limits.language_bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ValueTooLong => error.TooLarge,
            else => error.InvalidSchema,
        };
    }
    fn expect(self: *Parser, tag: std.meta.Tag(std.json.Token)) Error!void {
        if (std.meta.activeTag(try self.next()) != tag) return error.InvalidSchema;
    }
    fn patch(self: *Parser, languages: ?*[]const Language) Error!Patch {
        try self.expect(.object_begin);
        var result: Patch = .{};
        var seen: u8 = 0;
        while (true) {
            const token = try self.next();
            if (token == .object_end) break;
            const key = try string(token);
            const bit: u8 = if (std.mem.eql(u8, key, "lines")) 1 else if (std.mem.eql(u8, key, "wrap")) 2 else if (std.mem.eql(u8, key, "spaces")) 4 else if (std.mem.eql(u8, key, "indent")) 8 else if (languages != null and std.mem.eql(u8, key, "languages")) 16 else return error.UnsupportedSettings;
            if (seen & bit != 0) return error.DuplicateField;
            seen |= bit;
            if (bit == 16) {
                languages.?.* = try self.languageMap();
            } else if (bit == 8) {
                const n = switch (try self.next()) {
                    .number, .allocated_number => |n| n,
                    else => return error.InvalidSchema,
                };
                if (n.len != 1 or n[0] < '1' or n[0] > '8') return error.InvalidSchema;
                result.indent = n[0] - '0';
            } else {
                const value = switch (try self.next()) {
                    .true => true,
                    .false => false,
                    else => return error.InvalidSchema,
                };
                switch (bit) {
                    1 => result.lines = value,
                    2 => result.wrap = value,
                    4 => result.spaces = value,
                    else => unreachable,
                }
            }
        }
        return result;
    }
    fn languageMap(self: *Parser) Error![]const Language {
        try self.expect(.object_begin);
        var entries: [limits.languages]Language = undefined;
        var count: usize = 0;
        while (true) {
            const token = try self.next();
            if (token == .object_end) break;
            if (count == entries.len) return error.TooLarge;
            const id = try string(token);
            if (id.len == 0) return error.EmptyString;
            if (id.len > limits.language_bytes) return error.TooLarge;
            if (std.mem.indexOfScalar(u8, id, 0) != null) return error.EmbeddedNul;
            if (!std.unicode.utf8ValidateSlice(id)) return error.InvalidUtf8;
            // IDs are opaque GtkSourceView IDs, not paths or dictionary names.
            for (id) |ch| if (ch <= 0x20 or ch == 0x7f or ch == '/' or ch == '\\') return error.InvalidSchema;
            for (entries[0..count]) |entry| if (std.mem.eql(u8, id, entry.id)) return error.DuplicateField;
            entries[count] = .{ .id = id, .patch = try self.patch(null) };
            count += 1;
        }
        return self.allocator.dupe(Language, entries[0..count]);
    }
};

test {
    _ = @import("settings_test.zig");
}
