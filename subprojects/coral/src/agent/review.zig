//! Multi-file review proposals with checkpoints and stale-revision refusal.
//!
//! A proposal records, per file, the base revision (SHA-256 of the content at
//! proposal time, or a sentinel for an absent file) and the proposed content.
//! Accepting re-reads every file and refuses the whole proposal if any base
//! revision changed (`error.StaleRevision`), performing NO writes in that
//! case. On success a checkpoint snapshots the original contents so the edit
//! can be reverted. Rejection discards the proposal without side effects.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Hex-encoded SHA-256, or the all-zero sentinel for an absent file.
pub const Revision = [64]u8;
pub const absent: Revision = blk: {
    var r: Revision = undefined;
    @memset(&r, 0);
    break :blk r;
};

fn hexEncode(digest: [32]u8) Revision {
    const hex = "0123456789abcdef";
    var out: Revision = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

pub fn revisionOf(content: ?[]const u8) Revision {
    const bytes = content orelse return absent;
    var digest: [32]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return hexEncode(digest);
}

pub fn isAbsent(rev: Revision) bool {
    return std.mem.eql(u8, &rev, &absent);
}

/// True when the current content no longer matches the proposal's base.
pub fn checkStale(current: ?[]const u8, base: Revision) bool {
    const now = revisionOf(current);
    return !std.mem.eql(u8, &now, &base);
}

pub const FileEdit = struct {
    path: []const u8,
    base: Revision,
    new_content: []const u8,

    pub fn deinit(self: *FileEdit, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.new_content);
    }
};

pub const State = enum { pending, accepted, rejected, stale };

pub const Proposal = struct {
    id: []const u8,
    thread_id: []const u8,
    title: []const u8,
    files: []FileEdit,
    state: State = .pending,
    checkpoint_id: ?[]const u8 = null,

    pub fn deinit(self: *Proposal, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.thread_id);
        allocator.free(self.title);
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        if (self.checkpoint_id) |c| allocator.free(c);
    }
};

pub const Original = struct {
    path: []const u8,
    /// null means the file did not exist before the edit.
    content: ?[]u8,

    pub fn deinit(self: *Original, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.content) |c| allocator.free(c);
    }
};

pub const Checkpoint = struct {
    id: []const u8,
    files: []Original,

    pub fn deinit(self: *Checkpoint, allocator: Allocator) void {
        allocator.free(self.id);
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
    }
};

test "revisionOf and stale detection" {
    const a = revisionOf("hello");
    const b = revisionOf("hello");
    const c = revisionOf("world");
    try std.testing.expect(std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
    try std.testing.expect(!checkStale("hello", a));
    try std.testing.expect(checkStale("changed", a));
    try std.testing.expect(isAbsent(revisionOf(null)));
    try std.testing.expect(!isAbsent(a));
    try std.testing.expect(!checkStale(null, revisionOf(null)));
    try std.testing.expect(checkStale("now exists", revisionOf(null)));
}
