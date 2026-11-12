//! Pure, bounded single-file unified-diff parser and strict applier. No I/O, no
//! Git, no fuzz and no offset: a hunk applies only at its exact recorded line
//! position and only when every matched line is byte-identical. Exact bytes are
//! preserved, including CRLF (CR stays inside line content) and a missing final
//! newline (`\ No newline at end of file`). The canonical digest identifies a
//! hunk by its header numbers and body alone, never by file-header paths or the
//! decorative section heading, so a displayed hunk and a regenerated hunk match.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// A single-file patch is at most two bounded sides plus per-line overhead.
pub const max_file_bytes = 256 * 1024;
pub const max_patch_bytes = 4 * max_file_bytes + 4096;
pub const max_patch_lines = 2 * max_file_bytes + 16;
pub const max_hunks = 8192;
pub const max_line_bytes = max_file_bytes + 1;

const no_newline_marker = "\\ No newline at end of file";

/// One body line. `text` excludes the format LF but keeps any CR. `nonl` marks a
/// following `\ No newline at end of file`, valid only on a side's final line.
pub const Line = struct {
    tag: u8, // ' ', '-' or '+'
    text: []const u8,
    nonl: bool = false,
};

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []const Line,

    pub fn added(self: Hunk) usize {
        var n: usize = 0;
        for (self.lines) |l| if (l.tag == '+') {
            n += 1;
        };
        return n;
    }
    pub fn removed(self: Hunk) usize {
        var n: usize = 0;
        for (self.lines) |l| if (l.tag == '-') {
            n += 1;
        };
        return n;
    }
};

pub const Patch = struct {
    hunks: []const Hunk,
};

/// Stable identity for a requested hunk: its zero-based ordinal within the
/// single-file diff plus the SHA-256 of its canonical form (see `digest`).
pub const HunkRef = struct {
    ordinal: usize,
    digest: [32]u8,
};

pub const Direction = enum { forward, reverse };

/// SHA-256 over `@@ -o,oc +n,nc @@\n` (always explicit counts, no section
/// heading) followed by each body line as `{tag}{text}\n` and, when present,
/// `\ No newline at end of file\n`. Independent of paths and count omission.
pub fn digest(h: Hunk) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var header: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&header, "@@ -{d},{d} +{d},{d} @@\n", .{ h.old_start, h.old_count, h.new_start, h.new_count }) catch unreachable;
    hasher.update(text);
    for (h.lines) |l| {
        hasher.update(&.{l.tag});
        hasher.update(l.text);
        hasher.update("\n");
        if (l.nonl) hasher.update(no_newline_marker ++ "\n");
    }
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

const Range = struct { start: usize, count: usize };
const Header = struct { old: Range, new: Range };

fn parseRange(s: []const u8) !Range {
    if (s.len == 0) return error.InvalidPatch;
    if (std.mem.indexOfScalar(u8, s, ',')) |comma| {
        return .{
            .start = try std.fmt.parseInt(usize, s[0..comma], 10),
            .count = try std.fmt.parseInt(usize, s[comma + 1 ..], 10),
        };
    }
    return .{ .start = try std.fmt.parseInt(usize, s, 10), .count = 1 };
}

fn parseHeader(line: []const u8) !Header {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.InvalidPatch;
    const rest = line[4..];
    const plus = std.mem.indexOf(u8, rest, " +") orelse return error.InvalidPatch;
    const after = rest[plus + 2 ..];
    const close = std.mem.indexOf(u8, after, " @@") orelse return error.InvalidPatch;
    const old = try parseRange(rest[0..plus]);
    const new = try parseRange(after[0..close]);
    if (old.start > max_patch_lines or old.count > max_patch_lines) return error.PatchTooLarge;
    if (new.start > max_patch_lines or new.count > max_patch_lines) return error.PatchTooLarge;
    return .{ .old = old, .new = new };
}

/// Validate and append the accumulated body as one hunk, then reset `lines`.
fn finishHunk(a: Allocator, header: Header, lines: *std.ArrayList(Line), hunks: *std.ArrayList(Hunk)) !void {
    if (hunks.items.len >= max_hunks) return error.PatchTooLarge;
    var old_seen: usize = 0;
    var new_seen: usize = 0;
    var changes: usize = 0;
    var last_old: ?usize = null;
    var last_new: ?usize = null;
    for (lines.items, 0..) |l, i| {
        switch (l.tag) {
            ' ' => {
                old_seen += 1;
                new_seen += 1;
                last_old = i;
                last_new = i;
            },
            '-' => {
                old_seen += 1;
                changes += 1;
                last_old = i;
            },
            '+' => {
                new_seen += 1;
                changes += 1;
                last_new = i;
            },
            else => return error.InvalidPatch,
        }
    }
    if (old_seen != header.old.count or new_seen != header.new.count) return error.InvalidPatch;
    if (changes == 0) return error.InvalidPatch;
    if (header.old.count > 0 and header.old.start < 1) return error.InvalidPatch;
    if (header.new.count > 0 and header.new.start < 1) return error.InvalidPatch;
    // A no-newline marker may sit only on the final line of the side(s) it
    // belongs to; a context line carries it for both sides at once.
    for (lines.items, 0..) |l, i| {
        if (!l.nonl) continue;
        switch (l.tag) {
            ' ' => if (i != last_old.? or i != last_new.?) return error.InvalidPatch,
            '-' => if (i != last_old.?) return error.InvalidPatch,
            '+' => if (i != last_new.?) return error.InvalidPatch,
            else => return error.InvalidPatch,
        }
    }
    try hunks.append(a, .{
        .old_start = header.old.start,
        .old_count = header.old.count,
        .new_start = header.new.start,
        .new_count = header.new.count,
        .lines = try lines.toOwnedSlice(a),
    });
    lines.* = .empty;
}

/// Parse a bounded single-file unified diff. File-header paths are accepted but
/// never trusted for application; absent sides (`/dev/null`), mode/rename/copy
/// changes and binary patches are refused. An empty input yields zero hunks.
pub fn parse(a: Allocator, patch: []const u8) !Patch {
    if (patch.len == 0) return .{ .hunks = &.{} };
    if (patch.len > max_patch_bytes) return error.PatchTooLarge;
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(a);
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(a);

    var state: enum { header, body } = .header;
    var seen_git = false;
    var seen_minus = false;
    var seen_plus = false;
    var header: Header = undefined;
    var total: usize = 0;

    var it = std.mem.splitScalar(u8, patch, '\n');
    var pending = it.next();
    while (pending) |line| {
        const next = it.next();
        // Drop exactly one trailing empty segment produced by a final LF.
        const last = next == null and line.len == 0 and patch.len > 0 and patch[patch.len - 1] == '\n';
        if (last) break;
        total += 1;
        if (total > max_patch_lines) return error.PatchTooLarge;
        if (line.len > max_line_bytes) return error.PatchTooLarge;

        if (std.mem.startsWith(u8, line, "@@ -")) {
            if (state == .header and (!seen_minus or !seen_plus)) return error.InvalidPatch;
            if (state == .body) try finishHunk(a, header, &lines, &hunks);
            header = try parseHeader(line);
            state = .body;
        } else if (state == .body) {
            if (std.mem.eql(u8, line, no_newline_marker)) {
                if (lines.items.len == 0) return error.InvalidPatch;
                const prev = &lines.items[lines.items.len - 1];
                if (prev.nonl) return error.InvalidPatch;
                prev.nonl = true;
            } else if (line.len > 0 and (line[0] == ' ' or line[0] == '-' or line[0] == '+')) {
                try lines.append(a, .{ .tag = line[0], .text = line[1..] });
            } else return error.InvalidPatch;
        } else if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (seen_git) return error.InvalidPatch; // multi-file
            seen_git = true;
        } else if (std.mem.startsWith(u8, line, "index ")) {
            // Optional abbreviated-oid/mode line; content is irrelevant here.
        } else if (std.mem.startsWith(u8, line, "--- ")) {
            if (seen_minus) return error.InvalidPatch;
            if (std.mem.eql(u8, line[4..], "/dev/null")) return error.AbsentSide;
            seen_minus = true;
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            if (!seen_minus or seen_plus) return error.InvalidPatch;
            if (std.mem.eql(u8, line[4..], "/dev/null")) return error.AbsentSide;
            seen_plus = true;
        } else if (std.mem.startsWith(u8, line, "old mode ") or
            std.mem.startsWith(u8, line, "new mode ") or
            std.mem.startsWith(u8, line, "new file mode ") or
            std.mem.startsWith(u8, line, "deleted file mode ") or
            std.mem.startsWith(u8, line, "similarity ") or
            std.mem.startsWith(u8, line, "rename ") or
            std.mem.startsWith(u8, line, "copy ") or
            std.mem.startsWith(u8, line, "Binary files ") or
            std.mem.startsWith(u8, line, "GIT binary patch"))
        {
            return error.UnsupportedChange;
        } else return error.InvalidPatch;

        pending = next;
    }

    if (state == .body) {
        try finishHunk(a, header, &lines, &hunks);
    } else if (patch.len > 0) {
        return error.InvalidPatch;
    }
    return .{ .hunks = try hunks.toOwnedSlice(a) };
}

/// Strictly apply one hunk to `base`, returning fresh exact bytes. `forward`
/// matches the old side and emits the new side; `reverse` matches the new side
/// and emits the old side. The match must sit at the hunk's exact start with
/// byte-identical lines and consistent final-newline state; there is no search.
pub fn apply(a: Allocator, base: []const u8, h: Hunk, dir: Direction) ![]u8 {
    if (base.len > max_file_bytes) return error.TooLarge;

    var base_lines: std.ArrayList([]const u8) = .empty;
    defer base_lines.deinit(a);
    var base_trailing_lf = false;
    if (base.len > 0) {
        base_trailing_lf = base[base.len - 1] == '\n';
        var it = std.mem.splitScalar(u8, base, '\n');
        while (it.next()) |seg| try base_lines.append(a, seg);
        if (base_trailing_lf) _ = base_lines.pop();
    }

    const match_start = if (dir == .forward) h.old_start else h.new_start;
    const match_count = if (dir == .forward) h.old_count else h.new_count;
    const produce_count = if (dir == .forward) h.new_count else h.old_count;

    var match_texts: std.ArrayList([]const u8) = .empty;
    defer match_texts.deinit(a);
    var produce_texts: std.ArrayList([]const u8) = .empty;
    defer produce_texts.deinit(a);
    var match_last_nonl = false;
    var produce_last_nonl = false;
    for (h.lines) |l| {
        const is_old = l.tag == ' ' or l.tag == '-';
        const is_new = l.tag == ' ' or l.tag == '+';
        if (if (dir == .forward) is_old else is_new) {
            try match_texts.append(a, l.text);
            match_last_nonl = l.nonl;
        }
        if (if (dir == .forward) is_new else is_old) {
            try produce_texts.append(a, l.text);
            produce_last_nonl = l.nonl;
        }
    }
    if (match_texts.items.len != match_count or produce_texts.items.len != produce_count) return error.InvalidPatch;

    var prefix_len: usize = undefined;
    if (match_count > 0) {
        if (match_start < 1) return error.HunkMismatch;
        prefix_len = match_start - 1;
        if (prefix_len + match_count > base_lines.items.len) return error.HunkMismatch;
    } else {
        if (match_start > base_lines.items.len) return error.HunkMismatch;
        prefix_len = match_start;
    }
    for (match_texts.items, 0..) |txt, i| {
        if (!std.mem.eql(u8, base_lines.items[prefix_len + i], txt)) return error.HunkMismatch;
    }

    const match_end = prefix_len + match_count;
    const at_eof = match_end == base_lines.items.len;
    if (match_count > 0) {
        if (match_last_nonl) {
            if (!at_eof or base_trailing_lf) return error.HunkMismatch;
        } else if (at_eof and !base_trailing_lf) {
            return error.HunkMismatch;
        }
    } else if (at_eof and base_lines.items.len > 0 and !base_trailing_lf) {
        // Git represents an append to a no-LF file as a -/+ pair, never a pure
        // insertion; accepting one here would silently add a newline elsewhere.
        return error.HunkMismatch;
    }

    const suffix = base_lines.items[match_end..];
    var out_lines: std.ArrayList([]const u8) = .empty;
    defer out_lines.deinit(a);
    for (base_lines.items[0..prefix_len]) |l| try out_lines.append(a, l);
    for (produce_texts.items) |l| try out_lines.append(a, l);
    for (suffix) |l| try out_lines.append(a, l);

    var out_trailing_lf: bool = undefined;
    if (suffix.len > 0) {
        if (produce_last_nonl) return error.HunkMismatch; // marker mid-file
        out_trailing_lf = base_trailing_lf;
    } else if (produce_texts.items.len > 0) {
        out_trailing_lf = !produce_last_nonl;
    } else {
        // Pure deletion to EOF: the retained prefix keeps its final newline.
        out_trailing_lf = out_lines.items.len > 0;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (out_lines.items, 0..) |l, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, l);
    }
    if (out_trailing_lf and out_lines.items.len > 0) try out.append(a, '\n');
    if (out.items.len > max_file_bytes) return error.TooLarge;
    return out.toOwnedSlice(a);
}
