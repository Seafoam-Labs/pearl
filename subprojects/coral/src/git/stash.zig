//! Bounded, filesystem-independent planning and parsing for native Git stash
//! workflows. Paths/selectors are preserved byte-for-byte as data, never shell
//! arguments. Validation is lexical and fails closed; unknown or malformed
//! records are rejected rather than partially interpreted. No GTK, no I/O.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 1024 * 1024;
pub const max_entries = 1000;
pub const max_message_bytes = 4096;
pub const max_selector_bytes = 64;

/// `git stash push` scope. `tracked` is Git's default (tracked modifications,
/// staged and unstaged). `staged` requires Git >= 2.35 (`--staged`). `all` adds
/// untracked files (`--include-untracked`); ignored files are never stashed.
pub const Mode = enum {
    tracked,
    staged,
    all,

    pub fn flag(self: Mode) ?[]const u8 {
        return switch (self) {
            .tracked => null,
            .staged => "--staged",
            .all => "--include-untracked",
        };
    }
};

pub const Entry = struct {
    /// Reflog selector exactly as Git emitted it, e.g. `stash@{0}`.
    selector: []const u8,
    /// Numeric reflog index parsed from the selector.
    index: usize,
    /// Full stash commit object id (hex, 40 or 64 chars).
    oid: []const u8,
    /// Committer timestamp (Unix seconds) as emitted by `%ct`.
    timestamp: i64,
    /// Reflog subject (`%gs`), e.g. `On main: name`. Free-form, bounded.
    message: []const u8,
};

pub const List = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    /// All slices become invalid. Do not deinitialize copies of this owner.
    pub fn deinit(self: *List) void {
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
    InvalidSelector,
    InvalidOid,
    InvalidTimestamp,
    MessageTooLong,
};

/// Record framing for `git stash list`: NUL between records (`-z`), unit
/// separator between the four fields. The message is the final field and is
/// taken as the remainder, so it may itself contain unit separators.
pub const list_format = "%gd%x1f%H%x1f%ct%x1f%gs";
pub const list_args: []const []const u8 = &.{ "stash", "list", "-z", "--format=" ++ list_format };

pub fn parseList(allocator: Allocator, bytes: []const u8) ParseError!List {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var result: List = .{ .arena = std.heap.ArenaAllocator.init(allocator), .entries = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, offset, 0) orelse return error.TruncatedRecord;
        const record = bytes[offset..end];
        offset = end + 1;
        if (record.len == 0) return error.InvalidRecord;
        if (entries.items.len == max_entries) return error.TooManyEntries;
        try entries.append(a, try parseEntry(a, record));
    }
    result.entries = try entries.toOwnedSlice(a);
    return result;
}

fn parseEntry(a: Allocator, record: []const u8) ParseError!Entry {
    const sep = 0x1f;
    const first = std.mem.indexOfScalar(u8, record, sep) orelse return error.InvalidRecord;
    const second = std.mem.indexOfScalarPos(u8, record, first + 1, sep) orelse return error.InvalidRecord;
    const third = std.mem.indexOfScalarPos(u8, record, second + 1, sep) orelse return error.InvalidRecord;
    const selector = record[0..first];
    const oid = record[first + 1 .. second];
    const timestamp = record[second + 1 .. third];
    const message = record[third + 1 ..];
    const index = try selectorIndex(selector);
    if (!validOid(oid)) return error.InvalidOid;
    if (message.len > max_message_bytes) return error.MessageTooLong;
    return .{
        .selector = try a.dupe(u8, selector),
        .index = index,
        .oid = try a.dupe(u8, oid),
        .timestamp = std.fmt.parseInt(i64, timestamp, 10) catch return error.InvalidTimestamp,
        .message = try a.dupe(u8, message),
    };
}

/// Accepts only `stash@{<decimal>}` with a bounded, non-negative index.
pub fn selectorIndex(selector: []const u8) ParseError!usize {
    if (selector.len > max_selector_bytes) return error.InvalidSelector;
    if (!std.mem.startsWith(u8, selector, "stash@{") or !std.mem.endsWith(u8, selector, "}")) return error.InvalidSelector;
    const digits = selector["stash@{".len .. selector.len - 1];
    if (digits.len == 0 or digits.len > 10) return error.InvalidSelector;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidSelector;
    return std.fmt.parseInt(usize, digits, 10) catch return error.InvalidSelector;
}

pub fn validSelector(selector: []const u8) bool {
    _ = selectorIndex(selector) catch return false;
    return true;
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Locate an entry by its immutable commit id. Selectors shift as the reflog
/// changes; callers re-list and match by oid before apply/pop/drop.
pub fn findByOid(list: *const List, oid: []const u8) ?*const Entry {
    for (list.entries) |*entry| if (std.mem.eql(u8, entry.oid, oid)) return entry;
    return null;
}

/// Git >= 2.35 is required for `git stash push --staged`.
pub fn stagedSupported(version_bytes: []const u8) bool {
    const tag = "git version ";
    if (!std.mem.startsWith(u8, version_bytes, tag)) return false;
    var parts = std.mem.splitScalar(u8, version_bytes[tag.len..], '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return major > 2 or (major == 2 and minor >= 35);
}

pub const max_args = 8;

/// Fill `buf` with `git stash push` arguments for a named, whole-repository
/// stash. Returns the used slice. The caller prefixes the write argv policy.
pub fn pushArgs(buf: [][]const u8, mode: Mode, message: []const u8) ![]const []const u8 {
    if (message.len == 0 or message.len > max_message_bytes) return error.InvalidMessage;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidMessage;
    var n: usize = 0;
    buf[n] = "stash";
    n += 1;
    buf[n] = "push";
    n += 1;
    if (mode.flag()) |flag| {
        buf[n] = flag;
        n += 1;
    }
    buf[n] = "-m";
    n += 1;
    buf[n] = message;
    n += 1;
    return buf[0..n];
}

pub fn applyArgs(buf: [][]const u8, selector: []const u8) ![]const []const u8 {
    if (!validSelector(selector)) return error.InvalidSelector;
    buf[0] = "stash";
    buf[1] = "apply";
    buf[2] = selector;
    return buf[0..3];
}

pub fn dropArgs(buf: [][]const u8, selector: []const u8) ![]const []const u8 {
    if (!validSelector(selector)) return error.InvalidSelector;
    buf[0] = "stash";
    buf[1] = "drop";
    buf[2] = selector;
    return buf[0..3];
}

/// Patch output for one stash, bounded and classified by command.preview.
pub fn showArgs(buf: [][]const u8, selector: []const u8) ![]const []const u8 {
    if (!validSelector(selector)) return error.InvalidSelector;
    buf[0] = "stash";
    buf[1] = "show";
    buf[2] = "--patch";
    buf[3] = "--no-ext-diff";
    buf[4] = "--no-textconv";
    buf[5] = "--no-color";
    buf[6] = selector;
    return buf[0..7];
}

fn rep(comptime ch: u8, comptime n: usize) [n]u8 {
    return @splat(ch);
}

test "stash list parses framed records and preserves the free-form message" {
    const t = std.testing;
    const input = "stash@{0}\x1f" ++ rep('a', 40) ++ "\x1f1700000000\x1fOn main: hello\x1fworld\x00" ++
        "stash@{1}\x1f" ++ rep('b', 40) ++ "\x1f1700000001\x1fOn main: second\x00";
    var list = try parseList(t.allocator, input);
    defer list.deinit();
    try t.expectEqual(@as(usize, 2), list.entries.len);
    try t.expectEqualStrings("stash@{0}", list.entries[0].selector);
    try t.expectEqual(@as(usize, 0), list.entries[0].index);
    try t.expectEqualStrings("On main: hello\x1fworld", list.entries[0].message);
    try t.expectEqual(@as(i64, 1700000000), list.entries[0].timestamp);
    try t.expectEqualStrings("stash@{1}", list.entries[1].selector);
    try t.expect(findByOid(&list, &rep('b', 40)) != null);
    try t.expect(findByOid(&list, &rep('c', 40)) == null);
}

test "stash list rejects malformed, oversized and non-UTF-8 input" {
    const t = std.testing;
    try t.expectError(error.TruncatedRecord, parseList(t.allocator, "stash@{0}\x1f"));
    try t.expectError(error.InvalidRecord, parseList(t.allocator, "no-separators\x00"));
    try t.expectError(error.InvalidSelector, parseList(t.allocator, "bogus\x1f" ++ rep('a', 40) ++ "\x1f1\x1fm\x00"));
    try t.expectError(error.InvalidOid, parseList(t.allocator, "stash@{0}\x1fxyz\x1f1\x1fm\x00"));
    try t.expectError(error.InvalidTimestamp, parseList(t.allocator, "stash@{0}\x1f" ++ rep('a', 40) ++ "\x1fnope\x1fm\x00"));
    try t.expectError(error.InvalidUtf8, parseList(t.allocator, "stash@{0}\x1f" ++ rep('a', 40) ++ "\x1f1\x1f\xff\x00"));
    const long_message = rep('x', max_message_bytes + 1);
    try t.expectError(error.MessageTooLong, parseList(t.allocator, "stash@{0}\x1f" ++ rep('a', 40) ++ "\x1f1\x1f" ++ long_message ++ "\x00"));
}

test "selector validation is strict and bounded" {
    const t = std.testing;
    try t.expect(validSelector("stash@{0}"));
    try t.expect(validSelector("stash@{123}"));
    try t.expect(!validSelector("stash@{}"));
    try t.expect(!validSelector("stash@{-1}"));
    try t.expect(!validSelector("stash@{1x}"));
    try t.expect(!validSelector("refs/stash"));
    try t.expect(!validSelector("stash@{99999999999}"));
    try t.expectEqual(@as(usize, 42), try selectorIndex("stash@{42}"));
}

test "staged version gate requires Git 2.35" {
    const t = std.testing;
    try t.expect(stagedSupported("git version 2.35.0\n"));
    try t.expect(stagedSupported("git version 2.56.0\n"));
    try t.expect(stagedSupported("git version 3.0.0\n"));
    try t.expect(!stagedSupported("git version 2.34.9\n"));
    try t.expect(!stagedSupported("git version 2.31.0\n"));
    try t.expect(!stagedSupported("garbage"));
}

test "argv builders produce fixed, shell-free argument vectors" {
    const t = std.testing;
    var buf: [max_args][]const u8 = undefined;
    const tracked = try pushArgs(&buf, .tracked, "name");
    try t.expectEqualSlices([]const u8, &.{ "stash", "push", "-m", "name" }, tracked);
    const staged = try pushArgs(&buf, .staged, "name");
    try t.expectEqualSlices([]const u8, &.{ "stash", "push", "--staged", "-m", "name" }, staged);
    const all = try pushArgs(&buf, .all, "name");
    try t.expectEqualSlices([]const u8, &.{ "stash", "push", "--include-untracked", "-m", "name" }, all);
    try t.expectError(error.InvalidMessage, pushArgs(&buf, .tracked, ""));
    try t.expectEqualSlices([]const u8, &.{ "stash", "apply", "stash@{2}" }, try applyArgs(&buf, "stash@{2}"));
    try t.expectEqualSlices([]const u8, &.{ "stash", "drop", "stash@{2}" }, try dropArgs(&buf, "stash@{2}"));
    try t.expectError(error.InvalidSelector, applyArgs(&buf, "HEAD"));
    const show = try showArgs(&buf, "stash@{0}");
    try t.expectEqualStrings("stash", show[0]);
    try t.expectEqualStrings("stash@{0}", show[show.len - 1]);
}
