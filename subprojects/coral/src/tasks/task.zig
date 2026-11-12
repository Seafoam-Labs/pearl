//! Workspace task definitions and the argv/cwd/environment policy. Pure std:
//! parsing and policy validation perform no GTK and no execution. load() reads
//! the bounded `.coral/tasks.json` under one workspace root; callers must run it
//! off the GTK thread (the controller dispatches a worker).
//!
//! Executable workspace content is NOT trusted by default. A definition only
//! becomes runnable after the workspace trust gate AND an explicit per-run
//! review of the exact argv/cwd/environment. This module enforces the shape:
//!   * argv[0] must be an absolute path (no PATH lookup, no shell, no expansion);
//!   * cwd is root-relative and resolved lexically inside the workspace root;
//!   * env is a COMPLETE allowlist — nothing is inherited, not even PATH/HOME.
//! Neither this policy nor the supervisor is an OS sandbox: a reviewed command
//! runs with the user's permissions and can have side effects. Symlink escape by
//! a reviewed cwd/argv is not contained; the review must show the resolved path.
const std = @import("std");
const matcher = @import("matcher.zig");

pub const limits = struct {
    pub const tasks = 64;
    pub const file_bytes = 64 * 1024;
    pub const json_depth = 8;
    pub const argv = 64;
    pub const env = 64;
    pub const name_bytes = 128;
    pub const string_bytes = 8192;
    pub const path_bytes = 4095;
    /// Combined stdout/stderr capture handed to the supervisor.
    pub const output_bytes = 1024 * 1024;
    pub const timeout_ms = 30_000;
};

pub const Environment = struct { name: []const u8, value: []const u8 };

pub const Definition = struct {
    name: []const u8,
    /// argv[0] is absolute. Elements are literal; no shell is ever invoked.
    argv: []const []const u8,
    /// Absolute, resolved inside the owning workspace root.
    cwd: []const u8,
    /// Complete allowlist passed to the child; may be empty.
    env: []const Environment,
    /// null disables problem matching for this task.
    matcher: ?matcher.Kind,
    /// Canonical path of the workspace root that supplied this definition.
    root: []const u8,
};

pub const Definitions = struct {
    arena: std.heap.ArenaAllocator,
    tasks: []Definition,
    /// SHA-256 of the source bytes; detects definition changes between loads.
    digest: [32]u8,

    pub fn deinit(self: *Definitions) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// --- bounded JSON preflight --------------------------------------------------
// Mirrors language/protocol.boundedJson semantics without that subsystem import:
// size, UTF-8 and structural depth are bounded before any DOM allocation.
fn boundedJson(bytes: []const u8) !void {
    if (bytes.len > limits.file_bytes) return error.TaskFileTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |ch| {
        if (quoted) {
            if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') quoted = false;
        } else switch (ch) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == limits.json_depth) return error.JsonTooDeep;
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (quoted or depth != 0) return error.InvalidJson;
}

fn object(v: std.json.Value) !void {
    if (v != .object) return error.InvalidTaskShape;
}
fn required(v: std.json.Value, name: []const u8) !std.json.Value {
    return v.object.get(name) orelse error.MissingTaskField;
}
fn string(v: std.json.Value) ![]const u8 {
    if (v != .string) return error.InvalidTaskShape;
    return v.string;
}
fn array(v: std.json.Value, limit: usize) ![]const std.json.Value {
    if (v != .array) return error.InvalidTaskShape;
    if (v.array.items.len > limit) return error.TaskLimitExceeded;
    return v.array.items;
}
fn knownFields(v: std.json.Value, allowed: []const []const u8) !void {
    try object(v);
    for (v.object.keys()) |key| {
        var known = false;
        for (allowed) |name| if (std.mem.eql(u8, key, name)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownTaskField;
    }
}
fn safeString(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.string_bytes or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidTaskString;
}
fn safeName(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.name_bytes) return error.InvalidTaskName;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidTaskName;
}
fn safeEnvName(text: []const u8) !void {
    if (text.len == 0 or text.len > limits.string_bytes or std.mem.indexOfScalar(u8, text, '=') != null) return error.InvalidTaskEnvironment;
    for (text) |ch| if (ch < 0x20 or ch == 0x7f or ch == ' ') return error.InvalidTaskEnvironment;
}

/// Resolve a root-relative cwd lexically inside `root`. Absolute or escaping
/// paths fail closed. The result is always `root` or a descendant of it. This is
/// a lexical containment check, not a symlink walk; the run review shows it.
pub fn resolveCwd(arena: std.mem.Allocator, root: []const u8, rel: []const u8) ![]const u8 {
    if (root.len == 0 or root[0] != '/') return error.InvalidRoot;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return error.InvalidTaskString;
    if (rel.len != 0 and rel[0] == '/') return error.CwdMustBeRelative;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.CwdOutsideWorkspace;
            _ = parts.pop();
            continue;
        }
        if (part.len > limits.path_bytes) return error.InvalidTaskString;
        try parts.append(arena, part);
    }
    const base = if (std.mem.eql(u8, root, "/")) "" else std.mem.trimEnd(u8, root, "/");
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, base);
    for (parts.items) |part| {
        try out.append(arena, '/');
        try out.appendSlice(arena, part);
    }
    if (out.items.len == 0) return arena.dupe(u8, "/");
    if (out.items.len > limits.path_bytes) return error.InvalidTaskString;
    return out.toOwnedSlice(arena);
}

/// Parse and validate one root's task file bytes. `root` must be the canonical
/// absolute workspace root; each task's cwd is resolved against it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, root: []const u8) !Definitions {
    try boundedJson(bytes);
    if (root.len == 0 or root[0] != '/') return error.InvalidRoot;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.file_bytes,
    });
    const value = parsed.value;
    try knownFields(value, &.{ "version", "tasks" });
    const version = try required(value, "version");
    if (version != .integer or version.integer != 1) return error.UnsupportedTaskVersion;
    const raw = try array(try required(value, "tasks"), limits.tasks);
    const tasks = try a.alloc(Definition, raw.len);
    const owned_root = try a.dupe(u8, root);
    for (raw, tasks, 0..) |item, *task, i| {
        try knownFields(item, &.{ "name", "argv", "cwd", "env", "matcher" });
        const name = try string(try required(item, "name"));
        try safeName(name);
        for (tasks[0..i]) |prior| if (std.mem.eql(u8, name, prior.name)) return error.DuplicateTaskName;
        const args = try array(try required(item, "argv"), limits.argv);
        if (args.len == 0) return error.EmptyArgv;
        const argv = try a.alloc([]const u8, args.len);
        for (args, argv) |arg, *out| {
            out.* = try string(arg);
            try safeString(out.*);
        }
        if (argv[0][0] != '/') return error.ExecutableMustBeAbsolute;
        const rel = if (item.object.get("cwd")) |v| try string(v) else "";
        const cwd = try resolveCwd(a, owned_root, rel);
        var env: std.ArrayList(Environment) = .empty;
        if (item.object.get("env")) |v| {
            try object(v);
            if (v.object.count() > limits.env) return error.TaskLimitExceeded;
            var iter = v.object.iterator();
            while (iter.next()) |entry| {
                try safeEnvName(entry.key_ptr.*);
                const val = try string(entry.value_ptr.*);
                if (val.len > limits.string_bytes or std.mem.indexOfScalar(u8, val, 0) != null) return error.InvalidTaskString;
                try env.append(a, .{ .name = entry.key_ptr.*, .value = val });
            }
        }
        const matcher_kind: ?matcher.Kind = if (item.object.get("matcher")) |v| blk: {
            const text = try string(v);
            break :blk matcher.parseKind(text) orelse return error.UnknownMatcher;
        } else null;
        task.* = .{
            .name = try a.dupe(u8, name),
            .argv = argv,
            .cwd = cwd,
            .env = env.items,
            .matcher = matcher_kind,
            .root = owned_root,
        };
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .arena = arena, .tasks = tasks, .digest = digest };
}

/// Read `.coral/tasks.json` under `root` and parse it. A missing file yields an
/// empty definition list (no tasks), not an error. The file must be a regular,
/// user-owned, non-group/other-writable file opened without following symlinks;
/// executable workspace content that fails these checks is refused. Blocking and
/// bounded: run off the GTK thread.
pub fn load(allocator: std.mem.Allocator, root: []const u8) !Definitions {
    // Scratch arena for path construction and the raw read. parse() owns a
    // separate arena for the returned definitions, so this one is always freed.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const dir_path = try std.fs.path.join(a, &.{ root, ".coral" });
    const file_path = try std.fs.path.join(a, &.{ root, ".coral", "tasks.json" });
    const dir_z = try a.dupeSentinel(u8, dir_path, 0);
    const file_z = try a.dupeSentinel(u8, file_path, 0);
    const dir_flags: std.c.O = .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true, .PATH = true };
    const dir_fd = std.c.open(dir_z, dir_flags);
    if (dir_fd < 0) {
        if (std.c.errno(dir_fd) == .NOENT) return empty(allocator);
        return error.TaskConfigUnreadable;
    }
    defer _ = std.c.close(dir_fd);
    const file_flags: std.c.O = .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true };
    const fd = std.c.openat(dir_fd, file_z, file_flags);
    if (fd < 0) {
        if (std.c.errno(fd) == .NOENT) return empty(allocator);
        return error.TaskConfigUnreadable;
    }
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true }, &st) != 0) return error.TaskConfigUnreadable;
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.SIZE) return error.TaskConfigUnreadable;
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG) return error.TaskConfigNotRegular;
    if (st.uid != std.c.geteuid()) return error.TaskConfigNotUserOwned;
    if (st.mode & 0o022 != 0) return error.TaskConfigWritableByOthers;
    if (st.size > limits.file_bytes) return error.TaskFileTooLarge;
    const bytes = try a.alloc(u8, @intCast(st.size));
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.TaskConfigUnreadable;
        }
        if (n == 0) break;
        used += @intCast(n);
    }
    return parse(allocator, bytes[0..used], root);
}

fn empty(allocator: std.mem.Allocator) Definitions {
    const arena = std.heap.ArenaAllocator.init(allocator);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &digest, .{});
    return .{ .arena = arena, .tasks = &.{}, .digest = digest };
}

/// Load and merge `.coral/tasks.json` across several workspace roots into one
/// bounded definition list. Each task keeps its own root for cwd resolution and
/// display. The combined list is capped at limits.tasks; exceeding it fails
/// closed rather than silently dropping tasks. Blocking: run off the GTK thread.
pub fn loadRoots(allocator: std.mem.Allocator, roots: []const []const u8) !Definitions {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(Definition) = .empty;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (roots) |root| {
        var defs = try load(allocator, root);
        defer defs.deinit();
        for (defs.tasks) |t| {
            if (list.items.len >= limits.tasks) return error.TaskLimitExceeded;
            try list.append(alloc, try copyDefinition(alloc, t));
        }
        hash.update(&defs.digest);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .arena = arena, .tasks = try list.toOwnedSlice(alloc), .digest = digest };
}

fn copyDefinition(alloc: std.mem.Allocator, t: Definition) !Definition {
    const argv = try alloc.alloc([]const u8, t.argv.len);
    for (t.argv, argv) |src, *dst| dst.* = try alloc.dupe(u8, src);
    const env = try alloc.alloc(Environment, t.env.len);
    for (t.env, env) |src, *dst| dst.* = .{ .name = try alloc.dupe(u8, src.name), .value = try alloc.dupe(u8, src.value) };
    return .{
        .name = try alloc.dupe(u8, t.name),
        .argv = argv,
        .cwd = try alloc.dupe(u8, t.cwd),
        .env = env,
        .matcher = t.matcher,
        .root = try alloc.dupe(u8, t.root),
    };
}
