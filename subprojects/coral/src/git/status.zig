//! Bounded, filesystem-independent parser for `git status --porcelain=v2 --branch -z`.
//! Paths are POSIX repository-relative UTF-8, preserved byte-for-byte, not shell
//! arguments or display labels. Validation is lexical, not symlink authorization.
//! Unknown headers are ignored for Git's forward compatibility; unknown records
//! fail closed. Every record (including headers and rename sources) needs a NUL.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 1024 * 1024;
pub const max_entries = 10_000;
pub const max_path_bytes = 4096;
pub const max_header_bytes = 4096;

pub const Entry = struct {
    path: []const u8,
    original_path: ?[]const u8,
    index: u8,
    worktree: u8,
    kind: enum { ordinary, rename, unmerged, untracked, ignored },
    submodule: bool,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    /// Raw branch.oid: `(initial)` means unborn; null means not supplied.
    head: ?[]const u8,
    /// Raw branch.head: `(detached)` means detached; null means not supplied.
    branch: ?[]const u8,
    upstream: ?[]const u8,
    ahead: usize,
    behind: usize,

    /// All slices become invalid. Do not deinitialize copies of this owner.
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    TooManyEntries,
    PathTooLong,
    InvalidPath,
    InvalidUtf8,
    TruncatedRecord,
    InvalidRecord,
    UnknownRecord,
    InvalidHeader,
    DuplicateHeader,
};

pub fn parse(allocator: Allocator, bytes: []const u8) ParseError!Snapshot {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    var result: Snapshot = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .entries = &.{},
        .head = null,
        .branch = null,
        .upstream = null,
        .ahead = 0,
        .behind = 0,
    };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var offset: usize = 0;
    var seen_ab = false;
    while (offset < bytes.len) {
        const record = try nextRecord(bytes, &offset);
        if (record.len == 0) return error.InvalidRecord;
        if (record[0] == '#') {
            try parseHeader(a, &result, &seen_ab, record);
            continue;
        }
        if (entries.items.len == max_entries) return error.TooManyEntries;
        if (record.len < 2 or record[1] != ' ') return error.InvalidRecord;
        var entry: Entry = .{
            .path = undefined,
            .original_path = null,
            .index = '.',
            .worktree = '.',
            .kind = .ordinary,
            .submodule = false,
        };
        var rest = record[2..];
        switch (record[0]) {
            '?', '!' => {
                entry.kind = if (record[0] == '?') .untracked else .ignored;
                entry.index = record[0];
                entry.worktree = record[0];
            },
            '1', '2', 'u' => {
                const xy = try field(&rest);
                if (xy.len != 2) return error.InvalidRecord;
                entry.index = xy[0];
                entry.worktree = xy[1];
                entry.kind = switch (record[0]) {
                    '1' => .ordinary,
                    '2' => .rename,
                    else => .unmerged,
                };
                if (entry.kind == .unmerged) {
                    var valid = false;
                    for ([_][]const u8{ "DD", "AU", "UD", "UA", "DU", "AA", "UU" }) |pair| {
                        valid = valid or std.mem.eql(u8, pair, xy);
                    }
                    if (!valid) return error.InvalidRecord;
                } else {
                    const allowed = if (entry.kind == .rename) ".MTADRC" else ".MTAD";
                    for (xy) |ch| {
                        if (std.mem.indexOfScalar(u8, allowed, ch) == null) return error.InvalidRecord;
                    }
                    if (std.mem.eql(u8, xy, "..")) return error.InvalidRecord;
                }
                entry.submodule = try submodule(try field(&rest));
                const mode_count: usize = if (entry.kind == .unmerged) 4 else 3;
                for (0..mode_count) |_| try mode(try field(&rest));
                const oid_count: usize = if (entry.kind == .unmerged) 3 else 2;
                var oid_len: usize = 0;
                for (0..oid_count) |_| {
                    const oid = try field(&rest);
                    if (!validOid(oid)) return error.InvalidRecord;
                    if (oid_len != 0 and oid_len != oid.len) return error.InvalidRecord;
                    oid_len = oid.len;
                }
                if (entry.kind == .rename) {
                    const score = try field(&rest);
                    if (score.len < 2 or (score[0] != 'R' and score[0] != 'C')) return error.InvalidRecord;
                    if (score.len > 4 or (decimal(score[1..]) orelse return error.InvalidRecord) > 100) return error.InvalidRecord;
                    if (std.mem.indexOfScalar(u8, xy, score[0]) == null) return error.InvalidRecord;
                    entry.original_path = try ownPath(a, try nextRecord(bytes, &offset));
                }
            },
            else => return error.UnknownRecord,
        }
        entry.path = try ownPath(a, rest);
        try entries.append(a, entry);
    }
    result.entries = try entries.toOwnedSlice(a);
    return result;
}

fn nextRecord(bytes: []const u8, offset: *usize) ParseError![]const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, offset.*, 0) orelse return error.TruncatedRecord;
    const record = bytes[offset.*..end];
    offset.* = end + 1;
    return record;
}

// Consume exactly one ASCII separator; never tokenize or trim the path tail.
fn field(rest: *[]const u8) ParseError![]const u8 {
    const end = std.mem.indexOfScalar(u8, rest.*, ' ') orelse return error.InvalidRecord;
    if (end == 0) return error.InvalidRecord;
    const value = rest.*[0..end];
    rest.* = rest.*[end + 1 ..];
    return value;
}

fn ownPath(a: Allocator, path: []const u8) ParseError![]const u8 {
    if (path.len > max_path_bytes) return error.PathTooLong;
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
        // Git may emit a trailing slash for an untracked/ignored directory.
        if (component.len == 0 and components.index != null) return error.InvalidPath;
    }
    return a.dupe(u8, path);
}

fn mode(value: []const u8) ParseError!void {
    if (value.len != 6) return error.InvalidRecord;
    for (value) |ch| if (ch < '0' or ch > '7') return error.InvalidRecord;
}

fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn submodule(value: []const u8) ParseError!bool {
    if (std.mem.eql(u8, value, "N...")) return false;
    if (value.len != 4 or value[0] != 'S' or
        (value[1] != '.' and value[1] != 'C') or
        (value[2] != '.' and value[2] != 'M') or
        (value[3] != '.' and value[3] != 'U')) return error.InvalidRecord;
    return true;
}

fn decimal(value: []const u8) ?usize {
    if (value.len == 0) return null;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn parseHeader(a: Allocator, result: *Snapshot, seen_ab: *bool, record: []const u8) ParseError!void {
    if (!std.mem.startsWith(u8, record, "# ") or record.len == 2) return error.InvalidHeader;
    const content = record[2..];
    const end = std.mem.indexOfScalar(u8, content, ' ') orelse content.len;
    const key = content[0..end];
    if (key.len == 0) return error.InvalidHeader;
    const value = if (end < content.len) content[end + 1 ..] else "";
    if (value.len > max_header_bytes) return error.InvalidHeader;
    const slot: *?[]const u8 = if (std.mem.eql(u8, key, "branch.oid")) &result.head else if (std.mem.eql(u8, key, "branch.head")) &result.branch else if (std.mem.eql(u8, key, "branch.upstream")) &result.upstream else if (std.mem.eql(u8, key, "branch.ab")) {
        if (seen_ab.*) return error.DuplicateHeader;
        seen_ab.* = true;
        const space = std.mem.indexOfScalar(u8, value, ' ') orelse return error.InvalidHeader;
        const ahead = value[0..space];
        const behind = value[space + 1 ..];
        if (ahead.len < 2 or ahead[0] != '+' or behind.len < 2 or behind[0] != '-') return error.InvalidHeader;
        result.ahead = decimal(ahead[1..]) orelse return error.InvalidHeader;
        result.behind = decimal(behind[1..]) orelse return error.InvalidHeader;
        return;
    } else return;
    if (slot.* != null) return error.DuplicateHeader;
    if (value.len == 0) return error.InvalidHeader;
    if (slot == &result.head and !std.mem.eql(u8, value, "(initial)") and !validOid(value)) return error.InvalidHeader;
    slot.* = try a.dupe(u8, value);
}

/// Caller-owned label, never a replacement for the original path. Escapes C0/C1,
/// Unicode line separators and bidi controls; doubles backslashes for clarity.
/// Accepts at most max_path_bytes of UTF-8; output is bounded by 10x that size.
pub fn displayLabel(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len > max_path_bytes) return error.PathTooLong;
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |encoded| {
        const cp = std.unicode.utf8Decode(encoded) catch unreachable;
        if (cp == '\\') {
            try out.appendSlice(allocator, "\\\\");
        } else if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x61c or
            cp == 0x200e or cp == 0x200f or (cp >= 0x2028 and cp <= 0x202e) or
            (cp >= 0x2066 and cp <= 0x206f))
        {
            var buffer: [16]u8 = undefined;
            const escaped = try std.fmt.bufPrint(&buffer, "\\u{{{x}}}", .{cp});
            try out.appendSlice(allocator, escaped);
        } else {
            try out.appendSlice(allocator, encoded);
        }
    }
    return out.toOwnedSlice(allocator);
}
