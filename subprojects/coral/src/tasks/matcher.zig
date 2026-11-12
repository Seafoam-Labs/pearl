//! Bounded problem matchers for captured task output. Pure std: no GTK, no I/O,
//! no execution. A matcher only classifies text the supervisor already captured;
//! it never opens, runs, or mutates anything. Locations are plain file:line:col
//! diagnostics (zig/gcc/clang/generic) or Python tracebacks. Limits reject or
//! bound, never silently drop a matched problem without setting `truncated`.
//!
//! Problem file/message slices returned by matchLine borrow the input line.
//! parse() copies them into a caller-owned arena and bounds path/message bytes.
//! Presentation escaping is the controller's job; this layer keeps raw bytes but
//! refuses control characters in file paths because they are navigation targets.
const std = @import("std");

pub const Kind = enum { zig, gcc, clang, python, generic };
/// `err` rather than `error` because the latter is a Zig keyword; severityName
/// renders the human-facing spelling.
pub const Severity = enum { err, warning, note, info };

pub fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .err => "error",
        .warning => "warning",
        .note => "note",
        .info => "info",
    };
}

pub const limits = struct {
    pub const problems = 1000;
    pub const path_bytes = 4095;
    pub const message_bytes = 2048;
    /// Lines longer than this are not scanned: bounds per-line matcher work even
    /// though the supervisor already caps total capture at 1 MiB.
    pub const line_bytes = 8192;
};

pub const Problem = struct {
    file: []const u8,
    /// 1-based line number.
    line: u32,
    /// 1-based column, or 0 when the source format does not provide one.
    column: u32,
    severity: Severity,
    message: []const u8,
};

pub const Problems = struct {
    arena: std.heap.ArenaAllocator,
    items: []Problem,
    /// True when more matches existed than limits.problems allows.
    truncated: bool = false,

    pub fn deinit(self: *Problems) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

/// Parse a matcher name from a task definition. Unknown names fail closed.
pub fn parseKind(name: []const u8) ?Kind {
    const info = @typeInfo(Kind).@"enum";
    inline for (info.field_names, info.field_values) |field_name, value| {
        if (std.mem.eql(u8, name, field_name)) return @fromBackingInt(@intCast(value));
    }
    return null;
}

const Location = struct { file: []const u8, line: u32, column: u32, rest: []const u8 };
const Number = struct { value: u32, len: usize };

fn leadingNumber(text: []const u8) ?Number {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == 0) return null;
    const value = std.fmt.parseInt(u32, text[0..end], 10) catch return null;
    return .{ .value = value, .len = end };
}

/// Leftmost `file:line[:col]:` location. The file is everything before the first
/// colon that begins a valid line number, so paths containing other colons are
/// preserved. A trailing colon after the numeric part is required.
fn location(text: []const u8) ?Location {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ':' or i == 0) continue;
        const line = leadingNumber(text[i + 1 ..]) orelse continue;
        if (line.value == 0) continue;
        var pos = i + 1 + line.len;
        var column: u32 = 0;
        if (pos < text.len and text[pos] == ':') {
            if (leadingNumber(text[pos + 1 ..])) |col| {
                column = col.value;
                pos += 1 + col.len;
            }
        }
        if (pos >= text.len or text[pos] != ':') continue;
        return .{ .file = text[0..i], .line = line.value, .column = column, .rest = text[pos + 1 ..] };
    }
    return null;
}

fn trimSpace(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t");
}

const Classified = struct { severity: Severity, message: []const u8 };

/// Split an optional leading severity keyword ("error:", "warning:", "note:",
/// "info:", "hint:", "fatal error:") from the diagnostic message. Without a
/// keyword the problem defaults to error so it stays visible.
fn classify(rest: []const u8) Classified {
    const text = trimSpace(rest);
    const keywords = [_]struct { word: []const u8, severity: Severity }{
        .{ .word = "fatal error", .severity = .err },
        .{ .word = "error", .severity = .err },
        .{ .word = "warning", .severity = .warning },
        .{ .word = "note", .severity = .note },
        .{ .word = "info", .severity = .info },
        .{ .word = "hint", .severity = .info },
    };
    for (keywords) |kw| {
        if (text.len > kw.word.len and std.ascii.eqlIgnoreCase(text[0..kw.word.len], kw.word) and text[kw.word.len] == ':') {
            return .{ .severity = kw.severity, .message = trimSpace(text[kw.word.len + 1 ..]) };
        }
    }
    return .{ .severity = .err, .message = text };
}

fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > limits.path_bytes) return false;
    for (path) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

/// Match a single line. Returned file/message slices borrow `line`.
pub fn matchLine(kind: Kind, line: []const u8) ?Problem {
    if (line.len == 0 or line.len > limits.line_bytes) return null;
    if (kind == .python) {
        if (pythonTraceback(line)) |problem| return problem;
        // Fall through to the generic diagnostic form for tooling that emits it.
    }
    const loc = location(line) orelse return null;
    if (!safePath(loc.file)) return null;
    const classified = classify(loc.rest);
    return .{
        .file = loc.file,
        .line = loc.line,
        .column = loc.column,
        .severity = classified.severity,
        .message = classified.message,
    };
}

/// `  File "/path/x.py", line 12, in <module>` traceback locations.
fn pythonTraceback(line: []const u8) ?Problem {
    const marker = "File \"";
    const start = std.mem.indexOf(u8, line, marker) orelse return null;
    const path_start = start + marker.len;
    const path_end = std.mem.indexOfScalarPos(u8, line, path_start, '"') orelse return null;
    const file = line[path_start..path_end];
    if (!safePath(file)) return null;
    const after = line[path_end + 1 ..];
    const line_marker = ", line ";
    if (!std.mem.startsWith(u8, after, line_marker)) return null;
    const number = leadingNumber(after[line_marker.len..]) orelse return null;
    if (number.value == 0) return null;
    const rest = trimSpace(after[line_marker.len + number.len ..]);
    return .{
        .file = file,
        .line = number.value,
        .column = 0,
        .severity = .err,
        .message = if (rest.len != 0) rest else "Python traceback",
    };
}

fn dupMessage(arena: std.mem.Allocator, message: []const u8) ![]const u8 {
    if (message.len <= limits.message_bytes) return arena.dupe(u8, message);
    // Bound presentation bytes on a UTF-8 boundary; never split a codepoint.
    var end: usize = limits.message_bytes;
    while (end > 0 and message[end] & 0xc0 == 0x80) end -= 1;
    const kept = try arena.alloc(u8, end + 3);
    @memcpy(kept[0..end], message[0..end]);
    @memcpy(kept[end..], "...");
    return kept;
}

/// Parse captured output into owned, bounded problems. Both stdout and stderr
/// may be supplied; call once per stream or concatenate before calling.
pub fn parse(allocator: std.mem.Allocator, kind: Kind, bytes: []const u8) !Problems {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList(Problem) = .empty;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const matched = matchLine(kind, line) orelse continue;
        if (list.items.len >= limits.problems) {
            truncated = true;
            break;
        }
        try list.append(a, .{
            .file = try a.dupe(u8, matched.file),
            .line = matched.line,
            .column = matched.column,
            .severity = matched.severity,
            .message = try dupMessage(a, matched.message),
        });
    }
    return .{ .arena = arena, .items = try list.toOwnedSlice(a), .truncated = truncated };
}
