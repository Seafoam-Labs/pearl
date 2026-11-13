//! Built-in tool specifications and worktree-safe path resolution.
//!
//! Execution lives in the engine (it owns the host callbacks, policy and
//! review state). This module declares the tool schemas advertised to
//! providers and resolves tool paths against a thread's worktree root so
//! concurrent agents bound to different worktrees stay isolated.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");

pub const read_file = "read_file";
pub const list_dir = "list_dir";
pub const search = "search";
pub const propose_edit = "propose_edit";
pub const run_terminal = "run_terminal";

pub const builtin_specs = [_]provider.ToolSpec{
    .{
        .name = read_file,
        .description = "Read a UTF-8 file relative to the worktree root.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    },
    .{
        .name = list_dir,
        .description = "List a directory relative to the worktree root.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
    },
    .{
        .name = search,
        .description = "Search for a pattern under the worktree root.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}",
    },
    .{
        .name = propose_edit,
        .description = "Propose a multi-file edit for human review. Does not write files.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"files\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}},\"required\":[\"files\"]}",
    },
    .{
        .name = run_terminal,
        .description = "Run a terminal command via the host PTY. Requires approval.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"}},\"required\":[\"command\"]}",
    },
};

pub fn isBuiltin(name: []const u8) bool {
    for (builtin_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return true;
    }
    return false;
}

/// Resolve a tool path against the worktree root. Relative paths join the
/// root; absolute paths must stay within the root. `..` escapes are refused
/// when a root is bound, keeping concurrent worktree agents isolated.
pub fn resolvePath(allocator: Allocator, root: ?[]const u8, path: []const u8) ![]u8 {
    const wt = root orelse return allocator.dupe(u8, path);
    if (std.fs.path.isAbsolute(path)) {
        if (!isWithin(wt, path)) return error.OutsideWorktree;
        return allocator.dupe(u8, path);
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.OutsideWorktree;
    }
    return std.fs.path.join(allocator, &.{ wt, path });
}

fn isWithin(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    const next = path[root.len];
    return next == '/' or next == std.fs.path.sep;
}

test "resolvePath joins relative paths to the worktree" {
    const a = std.testing.allocator;
    const p = try resolvePath(a, "/wt", "src/main.zig");
    defer a.free(p);
    try std.testing.expectEqualStrings("/wt/src/main.zig", p);
}

test "resolvePath refuses escapes and outside absolutes" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.OutsideWorktree, resolvePath(a, "/wt", "../secret"));
    try std.testing.expectError(error.OutsideWorktree, resolvePath(a, "/wt", "/etc/passwd"));
    const ok = try resolvePath(a, "/wt", "/wt/file.txt");
    defer a.free(ok);
    try std.testing.expectEqualStrings("/wt/file.txt", ok);
}

test "resolvePath without root passes through" {
    const a = std.testing.allocator;
    const p = try resolvePath(a, null, "anything.txt");
    defer a.free(p);
    try std.testing.expectEqualStrings("anything.txt", p);
}

test "builtin specs are advertised" {
    try std.testing.expect(isBuiltin("read_file"));
    try std.testing.expect(isBuiltin("run_terminal"));
    try std.testing.expect(!isBuiltin("mcp:fake:echo"));
    try std.testing.expectEqual(@as(usize, 5), builtin_specs.len);
}
