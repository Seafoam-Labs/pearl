//! Pure multi-file unified-diff parsing and rendering. No I/O, no Git, no GTK.
//!
//! `parse` splits a bounded multi-file `git diff` into per-file `FileDiff`s and
//! reuses the strict single-file `hunk` parser for each textual file, so absent
//! sides, mode/rename/copy changes and binary patches are classified per file
//! rather than failing the whole capture. `renderUnified`/`renderSplit` produce
//! display lines carrying gutter tags and old/new line numbers; `wordRanges`
//! computes word-level changed byte ranges for intra-line highlighting. Every
//! output is bounded; nothing here allocates unbounded storage or trusts paths
//! for anything other than display.
const std = @import("std");
const hunk = @import("hunk.zig");

const Allocator = std.mem.Allocator;

pub const max_file_bytes = hunk.max_file_bytes; // 256 KiB per side
pub const max_hunks = hunk.max_hunks; // 8192 hunks per file
pub const max_files = 4096;
pub const max_diff_bytes = 16 * 1024 * 1024;
pub const max_render_lines = hunk.max_patch_lines;
pub const max_word_ranges = 4096;

/// Why a file has no textual hunks.
pub const Kind = enum { text, binary, mode_change, rename, absent_side, too_large, unsupported };

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    kind: Kind,
    hunks: []const hunk.Hunk,

    pub fn path(self: FileDiff) []const u8 {
        return if (self.new_path.len > 0) self.new_path else self.old_path;
    }
    pub fn added(self: FileDiff) usize {
        var n: usize = 0;
        for (self.hunks) |h| n += h.added();
        return n;
    }
    pub fn removed(self: FileDiff) usize {
        var n: usize = 0;
        for (self.hunks) |h| n += h.removed();
        return n;
    }
};

pub const Diff = struct {
    files: []const FileDiff,
};

/// Gutter marker / display classification for one rendered line.
pub const Tag = enum { context, added, removed, hunk_header, file_header, meta };

/// A half-open byte range within a rendered line's `text`.
pub const WordRange = struct { start: usize, end: usize };

pub const RenderLine = struct {
    tag: Tag,
    text: []const u8,
    old_line: ?usize = null,
    new_line: ?usize = null,
    /// Word-level changed ranges within `text` (word mode only).
    words: []const WordRange = &.{},
};

pub const SplitRow = struct {
    old: ?RenderLine = null,
    new: ?RenderLine = null,
};

pub const SplitView = struct {
    rows: []const SplitRow,
};

pub const Mode = enum { unified, split, word };

const section_marker = "diff --git ";

/// Parse a bounded multi-file diff. An empty input yields zero files. Each file
/// section is parsed independently; an unsupported file is classified, never
/// silently dropped, and never aborts the remaining files.
pub fn parse(a: Allocator, bytes: []const u8) !Diff {
    if (bytes.len == 0) return .{ .files = &.{} };
    if (bytes.len > max_diff_bytes) return error.DiffTooLarge;
    var files: std.ArrayList(FileDiff) = .empty;
    errdefer files.deinit(a);

    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        const at_line_start = i == 0 or bytes[i - 1] == '\n';
        if (at_line_start and std.mem.startsWith(u8, bytes[i..], section_marker) and i > start) {
            try appendFile(a, &files, bytes[start..i]);
            start = i;
        }
        i = if (line_end < bytes.len) line_end + 1 else bytes.len;
    }
    if (start < bytes.len) try appendFile(a, &files, bytes[start..]);
    return .{ .files = try files.toOwnedSlice(a) };
}

fn appendFile(a: Allocator, files: *std.ArrayList(FileDiff), section: []const u8) !void {
    if (files.items.len >= max_files) return error.TooManyFiles;
    const trimmed = std.mem.trimEnd(u8, section, "\n");
    if (trimmed.len == 0) return;
    const paths = sectionPaths(trimmed);
    // The strict single-file parser accepts one `diff --git` section and refuses
    // absent sides, mode/rename/copy and binary changes; map those to a kind.
    const parsed = hunk.parse(a, trimmed) catch |err| {
        const kind: Kind = switch (err) {
            error.AbsentSide => .absent_side,
            error.UnsupportedChange => classifyUnsupported(trimmed),
            error.PatchTooLarge => .too_large,
            else => .unsupported,
        };
        try files.append(a, .{ .old_path = try a.dupe(u8, paths.old), .new_path = try a.dupe(u8, paths.new), .kind = kind, .hunks = &.{} });
        return;
    };
    if (parsed.hunks.len > max_hunks) return error.TooManyHunks;
    try files.append(a, .{
        .old_path = try a.dupe(u8, paths.old),
        .new_path = try a.dupe(u8, paths.new),
        .kind = .text,
        .hunks = parsed.hunks,
    });
}

fn classifyUnsupported(section: []const u8) Kind {
    if (std.mem.indexOf(u8, section, "Binary files ") != null or std.mem.indexOf(u8, section, "GIT binary patch") != null) return .binary;
    if (std.mem.indexOf(u8, section, "new file mode ") != null or std.mem.indexOf(u8, section, "deleted file mode ") != null or std.mem.indexOf(u8, section, "/dev/null") != null) return .absent_side;
    if (std.mem.indexOf(u8, section, "rename from ") != null or std.mem.indexOf(u8, section, "copy from ") != null) return .rename;
    if (std.mem.indexOf(u8, section, "old mode ") != null or std.mem.indexOf(u8, section, "new mode ") != null) return .mode_change;
    return .unsupported;
}

const Paths = struct { old: []const u8, new: []const u8 };

/// Best-effort display paths. Prefers the `---`/`+++` headers (stripping the
/// a/ b/ prefixes); falls back to the `diff --git` line for binary/mode files.
/// Paths are display labels only and are never used as Git arguments here.
fn sectionPaths(section: []const u8) Paths {
    var old: []const u8 = "";
    var new: []const u8 = "";
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "--- ")) {
            old = stripPrefix(line[4..], "a/");
        } else if (std.mem.startsWith(u8, line, "+++ ")) {
            new = stripPrefix(line[4..], "b/");
        } else if (std.mem.startsWith(u8, line, section_marker) and old.len == 0 and new.len == 0) {
            const rest = line[section_marker.len..];
            if (std.mem.indexOf(u8, rest, " b/")) |sep| {
                old = stripPrefix(rest[0..sep], "a/");
                new = stripPrefix(rest[sep + 1 ..], "b/");
            }
        }
    }
    if (old.len == 0) old = new;
    if (new.len == 0) new = old;
    return .{ .old = old, .new = new };
}

fn stripPrefix(path: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/dev/null")) return "";
    return if (std.mem.startsWith(u8, path, prefix)) path[prefix.len..] else path;
}

/// Render one file's hunks as unified display lines. In `.word` mode, paired
/// removed/added lines carry word-level changed ranges. The returned slice and
/// all line text/word ranges are allocated from `a`.
pub fn renderUnified(a: Allocator, file: FileDiff, mode: Mode) ![]RenderLine {
    var out: std.ArrayList(RenderLine) = .empty;
    errdefer out.deinit(a);
    if (file.kind != .text) {
        try out.append(a, .{ .tag = .meta, .text = try notice(a, file) });
        return out.toOwnedSlice(a);
    }
    for (file.hunks) |h| {
        if (out.items.len >= max_render_lines) return error.RenderTooLarge;
        const header = try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{ h.old_start, h.old_count, h.new_start, h.new_count });
        try out.append(a, .{ .tag = .hunk_header, .text = header });
        var old_no = h.old_start;
        var new_no = h.new_start;
        // Pair removed runs with added runs for word highlighting.
        var idx: usize = 0;
        while (idx < h.lines.len) {
            if (out.items.len >= max_render_lines) return error.RenderTooLarge;
            const l = h.lines[idx];
            switch (l.tag) {
                ' ' => {
                    try out.append(a, .{ .tag = .context, .text = l.text, .old_line = old_no, .new_line = new_no });
                    old_no += 1;
                    new_no += 1;
                    idx += 1;
                },
                '-' => {
                    var rem_end = idx;
                    while (rem_end < h.lines.len and h.lines[rem_end].tag == '-') rem_end += 1;
                    var add_end = rem_end;
                    while (add_end < h.lines.len and h.lines[add_end].tag == '+') add_end += 1;
                    const removed = h.lines[idx..rem_end];
                    const added = h.lines[rem_end..add_end];
                    const pairs = @min(removed.len, added.len);
                    for (removed, 0..) |rl, k| {
                        const words = if (mode == .word and k < pairs) try changedWords(a, rl.text, added[k].text, false) else &.{};
                        try out.append(a, .{ .tag = .removed, .text = rl.text, .old_line = old_no, .words = words });
                        old_no += 1;
                    }
                    for (added, 0..) |al, k| {
                        const words = if (mode == .word and k < pairs) try changedWords(a, removed[k].text, al.text, true) else &.{};
                        try out.append(a, .{ .tag = .added, .text = al.text, .new_line = new_no, .words = words });
                        new_no += 1;
                    }
                    idx = add_end;
                },
                '+' => {
                    try out.append(a, .{ .tag = .added, .text = l.text, .new_line = new_no });
                    new_no += 1;
                    idx += 1;
                },
                else => return error.InvalidDiff,
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// Render one file as aligned split rows (old column / new column). Context lines
/// appear on both sides; a removed run pairs with the following added run row by
/// row, leaving blanks where one side is shorter. Word mode populates ranges.
pub fn renderSplit(a: Allocator, file: FileDiff, mode: Mode) !SplitView {
    var rows: std.ArrayList(SplitRow) = .empty;
    errdefer rows.deinit(a);
    if (file.kind != .text) {
        try rows.append(a, .{ .old = .{ .tag = .meta, .text = try notice(a, file) } });
        return .{ .rows = try rows.toOwnedSlice(a) };
    }
    for (file.hunks) |h| {
        if (rows.items.len >= max_render_lines) return error.RenderTooLarge;
        const header = try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{ h.old_start, h.old_count, h.new_start, h.new_count });
        try rows.append(a, .{ .old = .{ .tag = .hunk_header, .text = header }, .new = .{ .tag = .hunk_header, .text = header } });
        var old_no = h.old_start;
        var new_no = h.new_start;
        var idx: usize = 0;
        while (idx < h.lines.len) {
            if (rows.items.len >= max_render_lines) return error.RenderTooLarge;
            const l = h.lines[idx];
            switch (l.tag) {
                ' ' => {
                    try rows.append(a, .{
                        .old = .{ .tag = .context, .text = l.text, .old_line = old_no },
                        .new = .{ .tag = .context, .text = l.text, .new_line = new_no },
                    });
                    old_no += 1;
                    new_no += 1;
                    idx += 1;
                },
                '-' => {
                    var rem_end = idx;
                    while (rem_end < h.lines.len and h.lines[rem_end].tag == '-') rem_end += 1;
                    var add_end = rem_end;
                    while (add_end < h.lines.len and h.lines[add_end].tag == '+') add_end += 1;
                    const removed = h.lines[idx..rem_end];
                    const added = h.lines[rem_end..add_end];
                    const count = @max(removed.len, added.len);
                    const pairs = @min(removed.len, added.len);
                    for (0..count) |k| {
                        var row = SplitRow{};
                        if (k < removed.len) {
                            const words = if (mode == .word and k < pairs) try changedWords(a, removed[k].text, added[k].text, false) else &.{};
                            row.old = .{ .tag = .removed, .text = removed[k].text, .old_line = old_no, .words = words };
                            old_no += 1;
                        }
                        if (k < added.len) {
                            const words = if (mode == .word and k < pairs) try changedWords(a, removed[k].text, added[k].text, true) else &.{};
                            row.new = .{ .tag = .added, .text = added[k].text, .new_line = new_no, .words = words };
                            new_no += 1;
                        }
                        try rows.append(a, row);
                    }
                    idx = add_end;
                },
                '+' => {
                    try rows.append(a, .{ .new = .{ .tag = .added, .text = l.text, .new_line = new_no } });
                    new_no += 1;
                    idx += 1;
                },
                else => return error.InvalidDiff,
            }
        }
    }
    return .{ .rows = try rows.toOwnedSlice(a) };
}

fn notice(a: Allocator, file: FileDiff) ![]const u8 {
    const label: []const u8 = switch (file.kind) {
        .binary => "Binary change — no textual diff is available.",
        .mode_change => "Mode change only — no textual hunks.",
        .rename => "Rename/copy — not rendered as a textual diff.",
        .absent_side => "File added or deleted — whole-file staging only.",
        .too_large => "Diff exceeds the 256 KiB / 8192-hunk per-file limit.",
        .unsupported => "Unsupported change — no textual diff is available.",
        .text => "",
    };
    return std.fmt.allocPrint(a, "{s} ({s})", .{ label, file.path() });
}

const Token = struct { start: usize, end: usize };

/// Tokenize a line into whitespace-delimited words with byte offsets. Leading and
/// trailing whitespace are ignored; interior whitespace separates words.
fn tokenize(a: Allocator, text: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(a);
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and isSpace(text[i])) i += 1;
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and !isSpace(text[i])) i += 1;
        try tokens.append(a, .{ .start = start, .end = i });
        if (tokens.items.len >= max_word_ranges) return error.RenderTooLarge;
    }
    return tokens.toOwnedSlice(a);
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n' or ch == 0x0b or ch == 0x0c;
}

/// Compute word-level changed byte ranges for one side of a removed/added line
/// pair. `for_new` selects which side's ranges to return. A common token prefix
/// and suffix are kept; the differing middle tokens become the changed ranges.
/// Contiguous changed tokens merge into a single range. Pure insert/delete (no
/// counterpart) marks the whole line.
pub fn wordRanges(a: Allocator, old_text: []const u8, new_text: []const u8, for_new: bool) ![]WordRange {
    const subject = if (for_new) new_text else old_text;
    if (old_text.len == 0 or new_text.len == 0) {
        if (subject.len == 0) return &.{};
        const whole = try a.alloc(WordRange, 1);
        whole[0] = .{ .start = 0, .end = subject.len };
        return whole;
    }
    const old_tokens = try tokenize(a, old_text);
    defer a.free(old_tokens);
    const new_tokens = try tokenize(a, new_text);
    defer a.free(new_tokens);
    var prefix: usize = 0;
    while (prefix < old_tokens.len and prefix < new_tokens.len and
        std.mem.eql(u8, old_text[old_tokens[prefix].start..old_tokens[prefix].end], new_text[new_tokens[prefix].start..new_tokens[prefix].end])) : (prefix += 1)
    {}
    var suffix: usize = 0;
    while (suffix < old_tokens.len - prefix and suffix < new_tokens.len - prefix and
        std.mem.eql(u8, old_text[old_tokens[old_tokens.len - 1 - suffix].start..old_tokens[old_tokens.len - 1 - suffix].end], new_text[new_tokens[new_tokens.len - 1 - suffix].start..new_tokens[new_tokens.len - 1 - suffix].end])) : (suffix += 1)
    {}
    const tokens = if (for_new) new_tokens else old_tokens;
    const lo = prefix;
    const hi = tokens.len - suffix;
    if (lo >= hi) return &.{};
    var ranges: std.ArrayList(WordRange) = .empty;
    errdefer ranges.deinit(a);
    for (tokens[lo..hi]) |tok| {
        try ranges.append(a, .{ .start = tok.start, .end = tok.end });
        if (ranges.items.len >= max_word_ranges) return error.RenderTooLarge;
    }
    return ranges.toOwnedSlice(a);
}

fn changedWords(a: Allocator, old_text: []const u8, new_text: []const u8, for_new: bool) ![]const WordRange {
    return wordRanges(a, old_text, new_text, for_new);
}

// ---------------------------------------------------------------------------
// Pure tests (no Git, no GTK)
// ---------------------------------------------------------------------------

const t = std.testing;

const multi =
    \\diff --git a/one b/one
    \\index 1111111..2222222 100644
    \\--- a/one
    \\+++ b/one
    \\@@ -1,3 +1,3 @@
    \\ a
    \\-b
    \\+B
    \\ c
    \\diff --git a/two b/two
    \\--- a/two
    \\+++ b/two
    \\@@ -1 +1 @@
    \\-x
    \\+y
    \\
;

test "parse splits multiple files and preserves per-file hunks and paths" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a, multi);
    try t.expectEqual(@as(usize, 2), diff.files.len);
    try t.expectEqualStrings("one", diff.files[0].path());
    try t.expectEqualStrings("two", diff.files[1].path());
    try t.expectEqual(Kind.text, diff.files[0].kind);
    try t.expectEqual(@as(usize, 1), diff.files[0].hunks.len);
    try t.expectEqual(@as(usize, 1), diff.files[0].added());
    try t.expectEqual(@as(usize, 1), diff.files[0].removed());
    try t.expectEqual(@as(usize, 0), (try parse(a, "")).files.len);
}

test "parse classifies binary, mode, rename and absent sides per file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diff = try parse(a,
        \\diff --git a/bin b/bin
        \\Binary files a/bin and b/bin differ
        \\diff --git a/mode b/mode
        \\old mode 100644
        \\new mode 100755
        \\diff --git a/old b/new
        \\similarity index 90%
        \\rename from old
        \\rename to new
        \\diff --git a/add b/add
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/add
        \\@@ -0,0 +1 @@
        \\+hello
        \\
    );
    try t.expectEqual(@as(usize, 4), diff.files.len);
    try t.expectEqual(Kind.binary, diff.files[0].kind);
    try t.expectEqual(Kind.mode_change, diff.files[1].kind);
    try t.expectEqual(Kind.rename, diff.files[2].kind);
    try t.expectEqual(Kind.absent_side, diff.files[3].kind);
}

test "unified render carries gutter tags and old/new line numbers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = (try parse(a, multi)).files[0];
    const lines = try renderUnified(a, file, .unified);
    try t.expectEqual(Tag.hunk_header, lines[0].tag);
    try t.expectEqual(Tag.context, lines[1].tag);
    try t.expectEqual(@as(?usize, 1), lines[1].old_line);
    try t.expectEqual(@as(?usize, 1), lines[1].new_line);
    try t.expectEqual(Tag.removed, lines[2].tag);
    try t.expectEqual(@as(?usize, 2), lines[2].old_line);
    try t.expectEqual(@as(?usize, null), lines[2].new_line);
    try t.expectEqual(Tag.added, lines[3].tag);
    try t.expectEqual(@as(?usize, 2), lines[3].new_line);
    try t.expectEqual(Tag.context, lines[4].tag);
}

test "split render aligns removed and added rows with blanks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch =
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,4 @@
        \\ a
        \\-b
        \\+B
        \\+C
        \\ c
        \\
    ;
    const file = (try parse(a, patch)).files[0];
    const view = try renderSplit(a, file, .split);
    // header, context a, row(b/B), row(null/C), context c
    try t.expectEqual(@as(usize, 5), view.rows.len);
    try t.expectEqual(Tag.removed, view.rows[2].old.?.tag);
    try t.expectEqual(Tag.added, view.rows[2].new.?.tag);
    try t.expect(view.rows[3].old == null);
    try t.expectEqual(Tag.added, view.rows[3].new.?.tag);
}

test "word ranges mark only the differing tokens" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "the quick brown fox";
    const new = "the slow brown fox";
    const old_ranges = try wordRanges(a, old, new, false);
    try t.expectEqual(@as(usize, 1), old_ranges.len);
    try t.expectEqualStrings("quick", old[old_ranges[0].start..old_ranges[0].end]);
    const new_ranges = try wordRanges(a, old, new, true);
    try t.expectEqual(@as(usize, 1), new_ranges.len);
    try t.expectEqualStrings("slow", new[new_ranges[0].start..new_ranges[0].end]);
    // Identical lines have no changed ranges.
    try t.expectEqual(@as(usize, 0), (try wordRanges(a, old, old, false)).len);
    // Pure insertion marks the whole new line.
    const whole = try wordRanges(a, "", "added line", true);
    try t.expectEqual(@as(usize, 1), whole.len);
    try t.expectEqual(@as(usize, 0), whole[0].start);
    try t.expectEqual(@as(usize, 10), whole[0].end);
}

test "word mode populates ranges on paired removed/added lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch =
        \\--- a/f
        \\+++ b/f
        \\@@ -1 +1 @@
        \\-the quick brown fox
        \\+the slow brown fox
        \\
    ;
    const file = (try parse(a, patch)).files[0];
    const lines = try renderUnified(a, file, .word);
    try t.expectEqual(Tag.removed, lines[1].tag);
    try t.expectEqual(@as(usize, 1), lines[1].words.len);
    try t.expectEqualStrings("quick", lines[1].text[lines[1].words[0].start..lines[1].words[0].end]);
    try t.expectEqual(Tag.added, lines[2].tag);
    try t.expectEqualStrings("slow", lines[2].text[lines[2].words[0].start..lines[2].words[0].end]);
}
