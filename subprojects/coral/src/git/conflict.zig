//! Bounded, filesystem-independent parsing and planning for native Git conflict
//! workflows. Unmerged entries come from `git ls-files -u -z`; operation state is
//! read from gitdir state refs (MERGE_HEAD / REBASE_HEAD / …), never guessed from
//! conflict markers in file contents. No GTK, no I/O. Fails closed on malformed
//! or unsupported input.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 1024 * 1024;
pub const max_entries = 10_000;
pub const max_path_bytes = 4096;
pub const max_file_bytes = 256 * 1024;

pub const StageEntry = struct { mode: u32, oid: []const u8 };

/// Derived from which index stages are present, not from textual markers.
pub const Kind = enum {
    both_modified, // stages 1,2,3 (UU)
    both_added, // stages 2,3 (AA)
    deleted_by_us, // stages 1,3 (DU)
    deleted_by_them, // stages 1,2 (UD)
    added_by_us, // stage 2 (AU)
    added_by_them, // stage 3 (UA)
    both_deleted, // no stages (DD)
    unknown,

    /// Only simple text merges where both sides exist are auto-resolvable.
    /// Rename/delete/add-with-deletion and binary cases are refused.
    pub fn resolvable(self: Kind) bool {
        return self == .both_modified or self == .both_added;
    }
};

pub const Conflict = struct {
    path: []const u8,
    base: ?StageEntry = null, // stage 1
    ours: ?StageEntry = null, // stage 2
    theirs: ?StageEntry = null, // stage 3
    kind: Kind = .unknown,
};

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    conflicts: []Conflict,

    pub fn deinit(self: *Listing) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    TooManyEntries,
    InvalidUtf8,
    TruncatedRecord,
    InvalidRecord,
    InvalidPath,
    PathTooLong,
    InvalidMode,
    InvalidOid,
    InvalidStage,
};

/// `git ls-files -u -z` emits `<mode> <oid> <stage>\t<path>\0` per stage.
pub const unmerged_args: []const []const u8 = &.{ "ls-files", "-u", "-z" };

pub fn parseUnmerged(allocator: Allocator, bytes: []const u8) ParseError!Listing {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var result: Listing = .{ .arena = std.heap.ArenaAllocator.init(allocator), .conflicts = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var conflicts: std.ArrayList(Conflict) = .empty;
    var index_by_path: std.StringHashMap(usize) = .init(a);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, offset, 0) orelse return error.TruncatedRecord;
        const record = bytes[offset..end];
        offset = end + 1;
        if (record.len == 0) return error.InvalidRecord;
        const sp1 = std.mem.indexOfScalar(u8, record, ' ') orelse return error.InvalidRecord;
        const sp2 = std.mem.indexOfScalarPos(u8, record, sp1 + 1, ' ') orelse return error.InvalidRecord;
        const tab = std.mem.indexOfScalarPos(u8, record, sp2 + 1, '\t') orelse return error.InvalidRecord;
        const mode = try parseMode(record[0..sp1]);
        const oid = record[sp1 + 1 .. sp2];
        if (!validOid(oid)) return error.InvalidOid;
        const stage = try parseStage(record[sp2 + 1 .. tab]);
        const path = record[tab + 1 ..];
        try validPath(path);
        const gop = try index_by_path.getOrPut(path);
        const slot: *Conflict = if (gop.found_existing) blk: {
            break :blk &conflicts.items[gop.value_ptr.*];
        } else blk: {
            if (conflicts.items.len == max_entries) return error.TooManyEntries;
            gop.value_ptr.* = conflicts.items.len;
            gop.key_ptr.* = try a.dupe(u8, path);
            try conflicts.append(a, .{ .path = gop.key_ptr.* });
            break :blk &conflicts.items[conflicts.items.len - 1];
        };
        const entry: StageEntry = .{ .mode = mode, .oid = try a.dupe(u8, oid) };
        switch (stage) {
            1 => slot.base = entry,
            2 => slot.ours = entry,
            3 => slot.theirs = entry,
            else => return error.InvalidStage,
        }
    }
    for (conflicts.items) |*conflict| conflict.kind = classify(conflict);
    result.conflicts = try conflicts.toOwnedSlice(a);
    return result;
}

fn parseMode(value: []const u8) ParseError!u32 {
    if (value.len != 6) return error.InvalidMode;
    var mode: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '7') return error.InvalidMode;
        mode = mode * 8 + (ch - '0');
    }
    return mode;
}

fn parseStage(value: []const u8) ParseError!u8 {
    if (value.len != 1) return error.InvalidStage;
    return switch (value[0]) {
        '1' => 1,
        '2' => 2,
        '3' => 3,
        else => error.InvalidStage,
    };
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn validPath(path: []const u8) ParseError!void {
    if (path.len == 0) return error.InvalidPath;
    if (path.len > max_path_bytes) return error.PathTooLong;
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

pub fn classify(conflict: *const Conflict) Kind {
    const base = conflict.base != null;
    const ours = conflict.ours != null;
    const theirs = conflict.theirs != null;
    if (base and ours and theirs) return .both_modified;
    if (!base and ours and theirs) return .both_added;
    if (base and !ours and theirs) return .deleted_by_us;
    if (base and ours and !theirs) return .deleted_by_them;
    if (!base and ours and !theirs) return .added_by_us;
    if (!base and !ours and theirs) return .added_by_them;
    if (!base and !ours and !theirs) return .both_deleted;
    return .unknown;
}

pub const Choice = enum { current, incoming, both };

/// Reject binary, non-UTF-8 and oversized stage bytes before any worktree write.
pub fn text(bytes: []const u8) !void {
    if (bytes.len > max_file_bytes) return error.TooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.Binary;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.NonUtf8;
}

/// `both` keeps the current side followed by the incoming side, inserting a
/// single LF only when the current side is non-empty and lacks a trailing LF.
pub fn combineBoth(allocator: Allocator, ours: []const u8, theirs: []const u8) ![]u8 {
    const needs_sep = ours.len != 0 and ours[ours.len - 1] != '\n';
    const total = ours.len + theirs.len + @as(usize, if (needs_sep) 1 else 0);
    if (total > max_file_bytes) return error.TooLarge;
    const out = try allocator.alloc(u8, total);
    @memcpy(out[0..ours.len], ours);
    var at = ours.len;
    if (needs_sep) {
        out[at] = '\n';
        at += 1;
    }
    @memcpy(out[at..][0..theirs.len], theirs);
    return out;
}

pub const Operation = enum {
    none,
    merge,
    rebase,
    cherry_pick,
    revert,

    /// gitdir state file/ref whose presence indicates this operation. These are
    /// resolved by Git from the gitdir; conflict markers are never inspected.
    pub fn stateRef(self: Operation) ?[]const u8 {
        return switch (self) {
            .none => null,
            .merge => "MERGE_HEAD",
            .rebase => "REBASE_HEAD",
            .cherry_pick => "CHERRY_PICK_HEAD",
            .revert => "REVERT_HEAD",
        };
    }

    pub fn label(self: Operation) []const u8 {
        return switch (self) {
            .none => "no operation in progress",
            .merge => "merge",
            .rebase => "rebase",
            .cherry_pick => "cherry-pick",
            .revert => "revert",
        };
    }
};

pub const max_args = 4;

/// `git cat-file blob <oid>` reads an immutable stage object.
pub fn catFileArgs(buf: [][]const u8, oid: []const u8) ![]const []const u8 {
    if (!validOid(oid)) return error.InvalidOid;
    buf[0] = "cat-file";
    buf[1] = "blob";
    buf[2] = oid;
    return buf[0..3];
}

/// `git add -- <path>` stages the resolved worktree file.
pub fn addArgs(buf: [][]const u8, path: []const u8) ![]const []const u8 {
    try validPath(path);
    buf[0] = "add";
    buf[1] = "--";
    buf[2] = path;
    return buf[0..3];
}

/// Continue/abort argv for the detected operation. `GIT_EDITOR=true` in the write
/// environment accepts prepared commit messages without an interactive editor.
pub fn operationArgs(buf: [][]const u8, operation: Operation, continue_operation: bool) ![]const []const u8 {
    const verb: []const u8 = switch (operation) {
        .none => return error.NoOperation,
        .merge => "merge",
        .rebase => "rebase",
        .cherry_pick => "cherry-pick",
        .revert => "revert",
    };
    buf[0] = verb;
    buf[1] = if (continue_operation) "--continue" else "--abort";
    return buf[0..2];
}

fn rep(comptime ch: u8, comptime n: usize) [n]u8 {
    return @splat(ch);
}

test "ls-files -u groups stages per path and classifies conflict kinds" {
    const t = std.testing;
    const a40 = rep('a', 40);
    const b40 = rep('b', 40);
    const c40 = rep('c', 40);
    const input = "100644 " ++ a40 ++ " 1\tf.txt\x00" ++
        "100644 " ++ b40 ++ " 2\tf.txt\x00" ++
        "100644 " ++ c40 ++ " 3\tf.txt\x00" ++
        "100644 " ++ b40 ++ " 2\tadded.txt\x00" ++
        "100644 " ++ c40 ++ " 3\tadded.txt\x00" ++
        "100644 " ++ a40 ++ " 1\tgone.txt\x00" ++
        "100644 " ++ c40 ++ " 3\tgone.txt\x00";
    var listing = try parseUnmerged(t.allocator, input);
    defer listing.deinit();
    try t.expectEqual(@as(usize, 3), listing.conflicts.len);
    try t.expectEqualStrings("f.txt", listing.conflicts[0].path);
    try t.expectEqual(Kind.both_modified, listing.conflicts[0].kind);
    try t.expect(listing.conflicts[0].base != null and listing.conflicts[0].ours != null and listing.conflicts[0].theirs != null);
    try t.expectEqual(Kind.both_added, listing.conflicts[1].kind);
    try t.expect(listing.conflicts[1].base == null);
    try t.expectEqual(Kind.deleted_by_us, listing.conflicts[2].kind);
    try t.expect(listing.conflicts[2].ours == null);
    try t.expect(listing.conflicts[0].kind.resolvable());
    try t.expect(listing.conflicts[1].kind.resolvable());
    try t.expect(!listing.conflicts[2].kind.resolvable());
}

test "ls-files -u rejects malformed records, paths and stages" {
    const t = std.testing;
    const a40 = rep('a', 40);
    try t.expectError(error.TruncatedRecord, parseUnmerged(t.allocator, "100644 " ++ a40 ++ " 1\tf.txt"));
    try t.expectError(error.InvalidRecord, parseUnmerged(t.allocator, "garbage\x00"));
    try t.expectError(error.InvalidMode, parseUnmerged(t.allocator, "10064 " ++ a40 ++ " 1\tf.txt\x00"));
    try t.expectError(error.InvalidOid, parseUnmerged(t.allocator, "100644 zzz 1\tf.txt\x00"));
    try t.expectError(error.InvalidStage, parseUnmerged(t.allocator, "100644 " ++ a40 ++ " 4\tf.txt\x00"));
    try t.expectError(error.InvalidPath, parseUnmerged(t.allocator, "100644 " ++ a40 ++ " 1\t../escape.txt\x00"));
    try t.expectError(error.InvalidPath, parseUnmerged(t.allocator, "100644 " ++ a40 ++ " 1\t/abs.txt\x00"));
    try t.expectError(error.InvalidUtf8, parseUnmerged(t.allocator, "100644 " ++ a40 ++ " 1\t\xff.txt\x00"));
}

test "text gate refuses binary, non-UTF-8 and oversized bytes" {
    const t = std.testing;
    try text("hello\n");
    try t.expectError(error.Binary, text("a\x00b"));
    try t.expectError(error.NonUtf8, text("\xff"));
    const big = rep('x', max_file_bytes + 1);
    try t.expectError(error.TooLarge, text(&big));
}

test "combineBoth joins sides with a single separating LF when needed" {
    const t = std.testing;
    const joined = try combineBoth(t.allocator, "ours\n", "theirs\n");
    defer t.allocator.free(joined);
    try t.expectEqualStrings("ours\ntheirs\n", joined);
    const sep = try combineBoth(t.allocator, "ours", "theirs");
    defer t.allocator.free(sep);
    try t.expectEqualStrings("ours\ntheirs", sep);
    const empty = try combineBoth(t.allocator, "", "theirs");
    defer t.allocator.free(empty);
    try t.expectEqualStrings("theirs", empty);
}

test "operation state refs and continue/abort argv are explicit" {
    const t = std.testing;
    try t.expectEqualStrings("MERGE_HEAD", Operation.merge.stateRef().?);
    try t.expectEqualStrings("REBASE_HEAD", Operation.rebase.stateRef().?);
    try t.expect(Operation.none.stateRef() == null);
    var buf: [max_args][]const u8 = undefined;
    try t.expectEqualSlices([]const u8, &.{ "merge", "--continue" }, try operationArgs(&buf, .merge, true));
    try t.expectEqualSlices([]const u8, &.{ "rebase", "--abort" }, try operationArgs(&buf, .rebase, false));
    try t.expectEqualSlices([]const u8, &.{ "cherry-pick", "--continue" }, try operationArgs(&buf, .cherry_pick, true));
    try t.expectError(error.NoOperation, operationArgs(&buf, .none, true));
    try t.expectEqualSlices([]const u8, &.{ "add", "--", "f.txt" }, try addArgs(&buf, "f.txt"));
    try t.expectError(error.InvalidPath, addArgs(&buf, "../x"));
    const oid_a = rep('a', 40);
    const expected_cat = [_][]const u8{ "cat-file", "blob", &oid_a };
    try t.expectEqualSlices([]const u8, &expected_cat, try catFileArgs(&buf, &oid_a));
    try t.expectError(error.InvalidOid, catFileArgs(&buf, "nope"));
}
