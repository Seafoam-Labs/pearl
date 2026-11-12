//! Bounded, filesystem-independent parsers and validators for branch/tag refs.
//! Pure std: no GTK, libc, process or repository access. Controllers in
//! refs_controller.zig own execution; this module only parses captured bytes and
//! validates user-supplied names before they become fixed Git argv elements.
//!
//! Listing format: `git for-each-ref --format=<branch_format|tag_format>`.
//! Fields are separated by 0x1f and records terminated by 0x1e; Git appends one
//! LF after each formatted record. Git rejects ASCII control characters in ref
//! names, so 0x1f/0x1e cannot occur inside a field; oids are hex and tracking
//! summaries are single-line ASCII. Invalid UTF-8, malformed framing, unknown
//! fields and over-budget input fail closed as a whole, never partially.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_input_bytes = 1024 * 1024;
pub const max_refs = 10_000;
pub const max_ref_bytes = 4096;
pub const field_sep = 0x1f;
pub const record_sep = 0x1e;

/// %(HEAD) marks the current branch with `*`, otherwise a single space.
pub const branch_format = "%(refname)%1f%(objectname)%1f%(upstream)%1f%(upstream:track)%1f%(HEAD)%1e";
pub const tag_format = "%(refname)%1f%(objectname)%1f%(objecttype)%1e";

pub const Track = struct {
    ahead: usize = 0,
    behind: usize = 0,
    gone: bool = false,
};

pub const Branch = struct {
    /// Short name without refs/heads/ or refs/remotes/ (remote names keep origin/…).
    name: []const u8,
    ref: []const u8,
    oid: []const u8,
    /// Full upstream ref (refs/remotes/… or refs/heads/…), null when unset.
    upstream: ?[]const u8,
    track: Track,
    current: bool,
    remote: bool,
};

pub const Branches = struct {
    arena: std.heap.ArenaAllocator,
    items: []Branch,

    /// All slices become invalid. Do not deinitialize copies of this owner.
    pub fn deinit(self: *Branches) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Tag = struct {
    name: []const u8,
    ref: []const u8,
    oid: []const u8,
    /// True when the ref points directly at a commit/tree/blob (no tag object).
    lightweight: bool,
};

pub const Tags = struct {
    arena: std.heap.ArenaAllocator,
    items: []Tag,

    pub fn deinit(self: *Tags) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = Allocator.Error || error{
    InputTooLarge,
    TooManyRefs,
    InvalidUtf8,
    NulByte,
    TruncatedRecord,
    InvalidRecord,
    InvalidRef,
    InvalidOid,
    InvalidTrack,
    InvalidHeadMarker,
    InvalidObjectType,
};

/// Parse `for-each-ref` branch capture (refs/heads and refs/remotes).
pub fn parseBranches(allocator: Allocator, bytes: []const u8) ParseError!Branches {
    var result: Branches = .{ .arena = std.heap.ArenaAllocator.init(allocator), .items = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    try checkInput(bytes);
    var items: std.ArrayList(Branch) = .empty;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const record = try nextRecord(bytes, &offset);
        if (items.items.len == max_refs) return error.TooManyRefs;
        var fields: [5][]const u8 = undefined;
        try splitFields(record, &fields);
        const ref = fields[0];
        const remote = std.mem.startsWith(u8, ref, "refs/remotes/");
        if (!remote and !std.mem.startsWith(u8, ref, "refs/heads/")) return error.InvalidRef;
        const name = try shortNameChecked(ref);
        if (!validOid(fields[1])) return error.InvalidOid;
        const upstream: ?[]const u8 = if (fields[2].len == 0) null else blk: {
            if (!std.mem.startsWith(u8, fields[2], "refs/") or fields[2].len > max_ref_bytes) return error.InvalidRef;
            break :blk try a.dupe(u8, fields[2]);
        };
        const track = try parseTrack(fields[3]);
        const current = if (std.mem.eql(u8, fields[4], "*")) true else if (std.mem.eql(u8, fields[4], " ")) false else return error.InvalidHeadMarker;
        try items.append(a, .{
            .name = try a.dupe(u8, name),
            .ref = try a.dupe(u8, ref),
            .oid = try a.dupe(u8, fields[1]),
            .upstream = upstream,
            .track = track,
            .current = current,
            .remote = remote,
        });
    }
    result.items = try items.toOwnedSlice(a);
    return result;
}

/// Parse `for-each-ref` tag capture (refs/tags).
pub fn parseTags(allocator: Allocator, bytes: []const u8) ParseError!Tags {
    var result: Tags = .{ .arena = std.heap.ArenaAllocator.init(allocator), .items = &.{} };
    errdefer result.deinit();
    const a = result.arena.allocator();
    try checkInput(bytes);
    var items: std.ArrayList(Tag) = .empty;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const record = try nextRecord(bytes, &offset);
        if (items.items.len == max_refs) return error.TooManyRefs;
        var fields: [3][]const u8 = undefined;
        try splitFields(record, &fields);
        if (!std.mem.startsWith(u8, fields[0], "refs/tags/")) return error.InvalidRef;
        const name = try shortNameChecked(fields[0]);
        if (!validOid(fields[1])) return error.InvalidOid;
        const lightweight = if (std.mem.eql(u8, fields[2], "tag")) false else if (std.mem.eql(u8, fields[2], "commit") or std.mem.eql(u8, fields[2], "tree") or std.mem.eql(u8, fields[2], "blob")) true else return error.InvalidObjectType;
        try items.append(a, .{
            .name = try a.dupe(u8, name),
            .ref = try a.dupe(u8, fields[0]),
            .oid = try a.dupe(u8, fields[1]),
            .lightweight = lightweight,
        });
    }
    result.items = try items.toOwnedSlice(a);
    return result;
}

fn checkInput(bytes: []const u8) ParseError!void {
    if (bytes.len > max_input_bytes) return error.InputTooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.NulByte;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
}

/// Each record is terminated by 0x1e followed by exactly one LF (Git appends
/// the LF after the formatted record). No trailing garbage is accepted.
fn nextRecord(bytes: []const u8, offset: *usize) ParseError![]const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, offset.*, record_sep) orelse return error.TruncatedRecord;
    if (end + 1 >= bytes.len or bytes[end + 1] != '\n') return error.InvalidRecord;
    const record = bytes[offset.*..end];
    offset.* = end + 2;
    return record;
}

fn splitFields(record: []const u8, out: []([]const u8)) ParseError!void {
    var rest = record;
    for (out, 0..) |*field, i| {
        if (i + 1 == out.len) {
            if (std.mem.indexOfScalar(u8, rest, field_sep) != null) return error.InvalidRecord;
            field.* = rest;
            return;
        }
        const end = std.mem.indexOfScalar(u8, rest, field_sep) orelse return error.InvalidRecord;
        field.* = rest[0..end];
        rest = rest[end + 1 ..];
    }
}

fn shortNameChecked(ref: []const u8) ParseError![]const u8 {
    const name = shortName(ref) orelse return error.InvalidRef;
    if (name.len == 0 or name.len > max_ref_bytes) return error.InvalidRef;
    for (name) |ch| if (ch < 0x20 or ch == 0x7f) return error.InvalidRef;
    return name;
}

/// Strip the refs/heads/, refs/remotes/ or refs/tags/ prefix. Null for anything
/// else (including HEAD and pseudorefs, which these listings never request).
pub fn shortName(ref: []const u8) ?[]const u8 {
    for ([_][]const u8{ "refs/heads/", "refs/remotes/", "refs/tags/" }) |prefix| {
        if (std.mem.startsWith(u8, ref, prefix)) return ref[prefix.len..];
    }
    return null;
}

pub fn validOid(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Parse %(upstream:track): "", "[gone]", "[ahead N]", "[behind N]" or
/// "[ahead N, behind M]". Anything else fails closed.
pub fn parseTrack(text: []const u8) ParseError!Track {
    if (text.len == 0) return .{};
    if (std.mem.eql(u8, text, "[gone]")) return .{ .gone = true };
    if (text.len < 3 or text[0] != '[' or text[text.len - 1] != ']') return error.InvalidTrack;
    const body = text[1 .. text.len - 1];
    var track: Track = .{};
    var parts = std.mem.splitSequence(u8, body, ", ");
    while (parts.next()) |part| {
        const space = std.mem.indexOfScalar(u8, part, ' ') orelse return error.InvalidTrack;
        const key = part[0..space];
        const digits = part[space + 1 ..];
        if (digits.len == 0) return error.InvalidTrack;
        for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidTrack;
        const value = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidTrack;
        if (std.mem.eql(u8, key, "ahead")) {
            if (track.ahead != 0) return error.InvalidTrack;
            track.ahead = value;
        } else if (std.mem.eql(u8, key, "behind")) {
            if (track.behind != 0) return error.InvalidTrack;
            track.behind = value;
        } else return error.InvalidTrack;
    }
    if (track.ahead == 0 and track.behind == 0) return error.InvalidTrack;
    return track;
}

pub const HeadState = enum { branch, detached, unborn, unknown };

/// Classify status --porcelain=v2 --branch headers. `(initial)` is unborn,
/// `(detached)` is detached; missing headers stay unknown, never guessed.
pub fn headState(head: ?[]const u8, branch: ?[]const u8) HeadState {
    const oid = head orelse return .unknown;
    const name = branch orelse return .unknown;
    if (std.mem.eql(u8, oid, "(initial)")) return .unborn;
    if (std.mem.eql(u8, name, "(detached)")) return .detached;
    return .branch;
}

/// Lexical check-ref-format-style validation for user-supplied branch/tag short
/// names, plus UTF-8 and argv-safety rules. This is not a filesystem or ref
/// existence check; Git remains the authority at write time.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_ref_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    // argv safety: a leading dash could be read as an option even after `--`
    // is not accepted by every subcommand position.
    if (name[0] == '-' or name[0] == '/' or name[0] == '.') return false;
    if (std.mem.eql(u8, name, "@")) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "@{") != null) return false;
    for (name) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == ' ') return false;
        if (std.mem.indexOfScalar(u8, "~^:?*[\\", ch) != null) return false;
    }
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (component[0] == '.') return false;
        if (std.mem.endsWith(u8, component, ".lock")) return false;
        if (std.mem.endsWith(u8, component, ".")) return false;
    }
    return true;
}

test "parseBranches reads local/remote/upstream/track/current framing" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const input = "refs/heads/main\x1f" ++ oid ++ "\x1frefs/remotes/origin/main\x1f[ahead 1, behind 2]\x1f*\x1e\n" ++
        "refs/heads/topic\x1f" ++ oid ++ "\x1f\x1f\x1f \x1e\n" ++
        "refs/remotes/origin/main\x1f" ++ oid ++ "\x1f\x1f[gone]\x1f \x1e\n";
    var parsed = try parseBranches(t.allocator, input);
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 3), parsed.items.len);
    const main = parsed.items[0];
    try t.expectEqualStrings("main", main.name);
    try t.expectEqualStrings("refs/heads/main", main.ref);
    try t.expectEqualStrings(oid, main.oid);
    try t.expectEqualStrings("refs/remotes/origin/main", main.upstream.?);
    try t.expectEqual(Track{ .ahead = 1, .behind = 2 }, main.track);
    try t.expect(main.current and !main.remote);
    try t.expectEqualStrings("topic", parsed.items[1].name);
    try t.expect(parsed.items[1].upstream == null);
    try t.expect(!parsed.items[1].current);
    const remote = parsed.items[2];
    try t.expect(remote.remote and !remote.current);
    try t.expectEqualStrings("origin/main", remote.name);
    try t.expect(remote.track.gone);
}

test "parseBranches empty capture is an empty listing, not an error" {
    var parsed = try parseBranches(std.testing.allocator, "");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "parseBranches fails closed on malformed framing and fields" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const good = "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f\x1f*\x1e\n";
    try t.expectError(error.TruncatedRecord, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid));
    try t.expectError(error.InvalidRecord, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f\x1f*\x1e"));
    try t.expectError(error.TruncatedRecord, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f\x1f*\x1e\n\n"));
    try t.expectError(error.InvalidRecord, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f*\x1e\n"));
    try t.expectError(error.InvalidRecord, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f\x1f\x1f*\x1e\n"));
    try t.expectError(error.InvalidRef, parseBranches(t.allocator, "refs/tags/v1\x1f" ++ oid ++ "\x1f\x1f\x1f*\x1e\n"));
    try t.expectError(error.InvalidOid, parseBranches(t.allocator, "refs/heads/main\x1fnothex\x1f\x1f\x1f*\x1e\n"));
    try t.expectError(error.InvalidHeadMarker, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1f\x1f\x1fx\x1e\n"));
    try t.expectError(error.InvalidRef, parseBranches(t.allocator, "refs/heads/main\x1f" ++ oid ++ "\x1fnotaref\x1f\x1f*\x1e\n"));
    try t.expectError(error.InvalidUtf8, parseBranches(t.allocator, "refs/heads/\xff\x1f" ++ oid ++ "\x1f\x1f\x1f*\x1e\n"));
    try t.expectError(error.NulByte, parseBranches(t.allocator, good[0..10] ++ "\x00"));
    const big = try t.allocator.alloc(u8, max_input_bytes + 1);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try t.expectError(error.InputTooLarge, parseBranches(t.allocator, big));
}

test "parseBranches enforces the ref count bound" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    for (0..max_refs + 1) |_| try bytes.appendSlice(t.allocator, "refs/heads/b\x1f" ++ oid ++ "\x1f\x1f\x1f \x1e\n");
    try t.expectError(error.TooManyRefs, parseBranches(t.allocator, bytes.items));
}

test "parseTrack accepts documented summaries and rejects everything else" {
    const t = std.testing;
    try t.expectEqual(Track{}, try parseTrack(""));
    try t.expectEqual(Track{ .gone = true }, try parseTrack("[gone]"));
    try t.expectEqual(Track{ .ahead = 3 }, try parseTrack("[ahead 3]"));
    try t.expectEqual(Track{ .behind = 4 }, try parseTrack("[behind 4]"));
    try t.expectEqual(Track{ .ahead = 1, .behind = 2 }, try parseTrack("[ahead 1, behind 2]"));
    for ([_][]const u8{ "ahead 1", "[ahead]", "[ahead x]", "[ahead 1,behind 2]", "[ahead 1, behind]", "[up 1]", "[ahead 1, ahead 2]", "[]", "[gone ]", "[ahead -1]" }) |bad| {
        try t.expectError(error.InvalidTrack, parseTrack(bad));
    }
}

test "parseTags distinguishes lightweight and annotated tags" {
    const t = std.testing;
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const input = "refs/tags/v1\x1f" ++ oid ++ "\x1fcommit\x1e\n" ++
        "refs/tags/v2\x1f" ++ oid ++ "\x1ftag\x1e\n" ++
        "refs/tags/v3\x1f" ++ oid ++ "\x1ftree\x1e\n";
    var parsed = try parseTags(t.allocator, input);
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 3), parsed.items.len);
    try t.expectEqualStrings("v1", parsed.items[0].name);
    try t.expect(parsed.items[0].lightweight);
    try t.expect(!parsed.items[1].lightweight);
    try t.expect(parsed.items[2].lightweight);
    try t.expectError(error.InvalidObjectType, parseTags(t.allocator, "refs/tags/v1\x1f" ++ oid ++ "\x1fblobx\x1e\n"));
    try t.expectError(error.InvalidRef, parseTags(t.allocator, "refs/heads/v1\x1f" ++ oid ++ "\x1fcommit\x1e\n"));
}

test "headState classifies unborn, detached, branch and unknown" {
    const t = std.testing;
    try t.expectEqual(HeadState.unborn, headState("(initial)", "main"));
    try t.expectEqual(HeadState.detached, headState("0123456789abcdef0123456789abcdef01234567", "(detached)"));
    try t.expectEqual(HeadState.branch, headState("0123456789abcdef0123456789abcdef01234567", "main"));
    try t.expectEqual(HeadState.unknown, headState(null, "main"));
    try t.expectEqual(HeadState.unknown, headState("(initial)", null));
}

test "validName applies check-ref-format rules plus UTF-8 and argv safety" {
    const t = std.testing;
    for ([_][]const u8{ "main", "feature/x", "v1.2.3", "release-2026", "日", "a/b/c", "user@host" }) |name| {
        try t.expect(validName(name));
    }
    for ([_][]const u8{ "", "-x", "/x", ".x", "@", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a..b", "a@{b", "a/", "a//b", "a.lock", "a/.lock", "a.", "a/.hidden", "a\x01b", "a\x7fb", "\xff", "a\nb" }) |name| {
        try t.expect(!validName(name));
    }
    const long: [max_ref_bytes + 1]u8 = @splat('a');
    try t.expect(!validName(&long));
}

test "shortName strips only the three listing prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("main", shortName("refs/heads/main").?);
    try t.expectEqualStrings("origin/main", shortName("refs/remotes/origin/main").?);
    try t.expectEqualStrings("v1", shortName("refs/tags/v1").?);
    try t.expect(shortName("HEAD") == null);
    try t.expect(shortName("refs/other/x") == null);
}
