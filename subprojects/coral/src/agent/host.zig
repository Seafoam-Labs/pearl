//! Host callback boundary for the Coral agent backend.
//!
//! The backend never imports GTK or touches the UI directly. The embedding
//! application supplies these callbacks so the agent can read files, apply
//! reviewed edits, and drive terminals (PTYs) through the host. Callbacks may
//! be invoked from agent worker threads; the host is responsible for any
//! required marshalling onto its own main loop.
//!
//! Every callback that returns a slice transfers ownership of that slice to
//! the caller (allocated with the provided allocator). A missing callback is
//! reported as `error.Unsupported` by the engine rather than crashing.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LogLevel = enum { debug, info, warn, @"error" };

pub const DirEntry = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum { file, directory, other };
};

/// Opaque host terminal identifier (PTY session, subprocess, ...).
pub const TerminalHandle = u64;

pub const TerminalResult = struct {
    exit_code: ?i32 = null,
    output: []const u8 = "",
    cancelled: bool = false,
};

pub const Host = struct {
    ctx: ?*anyopaque = null,

    /// Read a whole file. `error.FileNotFound` when absent.
    readFile: ?*const fn (ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 = null,
    /// List a directory (non-recursive).
    listDir: ?*const fn (ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]DirEntry = null,
    /// Search `pattern` under `root`; returns rendered matches.
    search: ?*const fn (ctx: ?*anyopaque, allocator: Allocator, root: []const u8, pattern: []const u8) anyerror![]u8 = null,
    /// Write a file. Only invoked for accepted reviews / checkpoint reverts.
    writeFile: ?*const fn (ctx: ?*anyopaque, path: []const u8, content: []const u8) anyerror!void = null,

    /// Spawn a terminal command; returns a host handle.
    terminalSpawn: ?*const fn (ctx: ?*anyopaque, command: []const u8, cwd: ?[]const u8) anyerror!TerminalHandle = null,
    /// Wait for output/exit. `timeout_ms == 0` waits indefinitely.
    terminalWait: ?*const fn (ctx: ?*anyopaque, handle: TerminalHandle, timeout_ms: u32) anyerror!TerminalResult = null,
    /// Forcibly terminate a terminal. Must be idempotent.
    terminalKill: ?*const fn (ctx: ?*anyopaque, handle: TerminalHandle) void = null,

    /// Render a git diff for a worktree root.
    gitDiff: ?*const fn (ctx: ?*anyopaque, allocator: Allocator, root: []const u8) anyerror![]u8 = null,
    /// Render diagnostics for a path.
    diagnostics: ?*const fn (ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 = null,

    /// Optional structured log sink. The backend redacts secrets before
    /// calling this; hosts must still treat messages as untrusted.
    log: ?*const fn (ctx: ?*anyopaque, level: LogLevel, message: []const u8) void = null,
};

test "Host defaults are null and constructible" {
    const host: Host = .{};
    try std.testing.expect(host.readFile == null);
    try std.testing.expect(host.terminalKill == null);
    try std.testing.expect(host.ctx == null);
}
