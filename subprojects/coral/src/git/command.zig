//! Fixed read-only Git boundary. Local repository filters remain executable;
//! neither this argv policy nor the process supervisor is an OS sandbox.
const std = @import("std");
const status = @import("status.zig");

pub const prefix: []const []const u8 = &.{
    "/usr/bin/git", "--no-pager",                "--no-optional-locks", "--literal-pathspecs",
    "-c",           "core.fsmonitor=false",      "-c",                  "core.hooksPath=/dev/null",
    "-c",           "core.untrackedCache=false", "-c",                  "credential.helper=",
    "-c",           "protocol.allow=never",      "-c",                  "core.attributesFile=/dev/null",
};
pub const Environment = struct { name: []const u8, value: []const u8 };
// Complete environment, never merged with the editor's environment.
pub const environment = [_]Environment{
    .{ .name = "PATH", .value = "/usr/bin:/bin" },
    .{ .name = "HOME", .value = "/dev/null" },
    .{ .name = "XDG_CONFIG_HOME", .value = "/dev/null" },
    .{ .name = "LC_ALL", .value = "C" },
    .{ .name = "LANG", .value = "C" },
    .{ .name = "TZ", .value = "UTC" },
    .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" },
    .{ .name = "GIT_CONFIG_SYSTEM", .value = "/dev/null" },
    .{ .name = "GIT_CONFIG_GLOBAL", .value = "/dev/null" },
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
    .{ .name = "GIT_ASKPASS", .value = "/bin/false" },
    .{ .name = "SSH_ASKPASS", .value = "/bin/false" },
    .{ .name = "GIT_SSH", .value = "/bin/false" },
    .{ .name = "GIT_PROTOCOL_FROM_USER", .value = "0" },
    .{ .name = "GIT_ALLOW_PROTOCOL", .value = "" },
    .{ .name = "GIT_NO_LAZY_FETCH", .value = "1" },
    .{ .name = "GIT_OPTIONAL_LOCKS", .value = "0" },
};
pub const status_args: []const []const u8 = &.{ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal", "--ignore-submodules=all", "--no-renames" };
pub const diff_args: []const []const u8 = &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--ignore-submodules=all", "--no-relative", "--src-prefix=a/", "--dst-prefix=b/" };

pub fn supportedVersion(bytes: []const u8) bool {
    const tag = "git version ";
    if (!std.mem.startsWith(u8, bytes, tag)) return false;
    var parts = std.mem.splitScalar(u8, bytes[tag.len..], '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return major > 2 or (major == 2 and minor >= 31);
}

/// Each rev-parse request emits ONE path plus ONE LF. Do not trim whitespace or
/// split lines: a valid Unix path can contain or end with newlines.
pub fn outputPath(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return error.InvalidGitPath;
    const path = bytes[0 .. bytes.len - 1];
    if (path.len > 4095 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidGitPath;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGitPath;
    }
    return path;
}
pub fn contains(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and (std.mem.eql(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}

/// GTK receives plain, bounded UTF-8. Escape raw path bytes (including controls
/// and backslashes) instead of silently changing the path used for Git argv.
pub fn display(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (std.unicode.utf8ValidateSlice(bytes)) return displayUtf8(allocator, bytes, limit);
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        const escape = b < 32 or b >= 127 or b == '\\';
        const rendered: usize = if (escape) 4 else 1;
        if (out.items.len + rendered + 3 > limit) {
            if (out.items.len + 3 <= limit) try out.appendSlice(allocator, "...");
            break;
        }
        if (escape) {
            try out.appendSlice(allocator, &.{ '\\', 'x', hex[b >> 4], hex[b & 15] });
        } else {
            try out.append(allocator, b);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn displayUtf8(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]u8 {
    // Escaping never shrinks the input. Bound the prefix before allocating the
    // shared label, including for callers passing more than a Git path's budget.
    var end = @min(bytes.len, @min(limit, status.max_path_bytes));
    while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
    const label = try status.displayLabel(allocator, bytes[0..end]);
    if (end == bytes.len and label.len <= limit) return label;
    defer allocator.free(label);

    const suffix: []const u8 = if (limit >= 3) "..." else "";
    const budget = limit - suffix.len;
    var kept: usize = 0;
    while (kept < label.len) {
        // displayLabel emits either a complete UTF-8 character, \\ or \u{hex}.
        // Never leave a misleading half-escape at the truncation boundary.
        const width: usize = if (label[kept] == '\\')
            if (label[kept + 1] == '\\') 2 else (std.mem.indexOfScalarPos(u8, label, kept, '}').? - kept + 1)
        else
            std.unicode.utf8ByteSequenceLength(label[kept]) catch unreachable;
        if (width > budget - kept) break;
        kept += width;
    }
    const result = try allocator.alloc(u8, kept + suffix.len);
    @memcpy(result[0..kept], label[0..kept]);
    @memcpy(result[kept..], suffix);
    return result;
}

pub const Preview = enum { text, binary, non_utf8, too_large };
pub fn preview(bytes: []const u8) Preview {
    if (std.mem.indexOf(u8, bytes, "\nBinary files ") != null or std.mem.indexOf(u8, bytes, "\nGIT binary patch") != null or std.mem.indexOfScalar(u8, bytes, 0) != null) return .binary;
    if (!std.unicode.utf8ValidateSlice(bytes)) return .non_utf8;
    if (bytes.len > 256 * 1024) return .too_large;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        if (line.len > 2048 or count > 4000) return .too_large;
    }
    return .text;
}

test "Git version floor, path framing and component containment" {
    const t = std.testing;
    try t.expect(supportedVersion("git version 2.31.0\n"));
    try t.expect(supportedVersion("git version 2.49.1.vendor\n"));
    try t.expect(!supportedVersion("git version 2.30.9\n"));
    try t.expect(!supportedVersion("garbage"));
    try t.expectEqualStrings("/root/line\n", try outputPath("/root/line\n\n"));
    try t.expectError(error.InvalidGitPath, outputPath("/root/../else\n"));
    try t.expect(contains("/root", "/root/nested"));
    try t.expect(!contains("/root", "/root-other"));
    try t.expect(!contains("/root", "/"));
}
test "bounded noneditable preview classification and hostile display paths" {
    const t = std.testing;
    try t.expectEqual(Preview.binary, preview("diff --git a/x b/x\nBinary files a/x and b/x differ\n"));
    try t.expectEqual(Preview.non_utf8, preview("\xff"));
    try t.expectEqual(Preview.text, preview("diff --git a/x b/x\n+hello\n"));
    const escaped = try display(t.allocator, "a\n\xff\\b", 128);
    defer t.allocator.free(escaped);
    try t.expectEqualStrings("a\\x0a\\xff\\x5cb", escaped);
    for (0..32) |limit| {
        const bounded = try display(t.allocator, "日日本語日本語\n", limit);
        defer t.allocator.free(bounded);
        try t.expect(bounded.len <= limit);
        try t.expect(std.unicode.utf8ValidateSlice(bounded));
    }
    const long_line: [2049]u8 = @splat('a');
    try t.expectEqual(Preview.too_large, preview(&long_line));
    const many_lines: [4000]u8 = @splat('\n');
    try t.expectEqual(Preview.too_large, preview(&many_lines));
}

test "command display visibly escapes Unicode controls using the shared label policy" {
    const t = std.testing;
    const raw = "日\u{202e}\u{2066}\u{2069}\u{2028}\u{2029}\u{80}\u{85}\u{9f}\u{61c}\u{200e}\u{200f}\\name";
    const expected = "日\\u{202e}\\u{2066}\\u{2069}\\u{2028}\\u{2029}\\u{80}\\u{85}\\u{9f}\\u{61c}\\u{200e}\\u{200f}\\\\name";
    const label = try display(t.allocator, raw, expected.len);
    defer t.allocator.free(label);
    try t.expectEqualStrings(expected, label);
    const shared = try status.displayLabel(t.allocator, raw);
    defer t.allocator.free(shared);
    try t.expectEqualStrings(shared, label);

    for (0..expected.len + 4) |limit| {
        const bounded = try display(t.allocator, raw, limit);
        defer t.allocator.free(bounded);
        try t.expect(bounded.len <= limit);
        try t.expect(std.unicode.utf8ValidateSlice(bounded));
        var i: usize = 0;
        while (i < bounded.len) {
            if (bounded[i] == '\\') {
                try t.expect(i + 1 < bounded.len);
                if (bounded[i + 1] == '\\') {
                    i += 2;
                } else {
                    try t.expect(std.mem.startsWith(u8, bounded[i..], "\\u{"));
                    const close = std.mem.indexOfScalarPos(u8, bounded, i, '}');
                    try t.expect(close != null);
                    i = close.? + 1;
                }
            } else {
                const width = try std.unicode.utf8ByteSequenceLength(bounded[i]);
                const cp = try std.unicode.utf8Decode(bounded[i..][0..width]);
                try t.expect(cp == 0x65e5 or (cp >= 0x20 and cp < 0x7f));
                i += width;
            }
        }
    }
}

test "command display retains invalid byte escaping and never mutates a raw path or Git argv" {
    const t = std.testing;
    for ([_][]const u8{ ":(glob)日\u{202e}\u{2066}\u{2069}\u{2028}\u{2029}\u{85}\\file", ":(glob)\xff\u{202e}\n\\file" }) |original| {
        const raw = try t.allocator.dupe(u8, original);
        defer t.allocator.free(raw);
        var argv: [prefix.len + diff_args.len + 2][]const u8 = undefined;
        @memcpy(argv[0..prefix.len], prefix);
        @memcpy(argv[prefix.len..][0..diff_args.len], diff_args);
        argv[argv.len - 2] = "--";
        argv[argv.len - 1] = raw;
        for (0..128) |limit| {
            const label = try display(t.allocator, argv[argv.len - 1], limit);
            defer t.allocator.free(label);
            try t.expect(label.len <= limit);
            try t.expect(std.unicode.utf8ValidateSlice(label));
            try t.expectEqualStrings(original, raw);
            try t.expectEqualStrings(original, argv[argv.len - 1]);
            try t.expect(argv[argv.len - 1].ptr == raw.ptr);
            try t.expectEqualStrings("--", argv[argv.len - 2]);
            for (prefix, argv[0..prefix.len]) |expected, actual| try t.expectEqualStrings(expected, actual);
            for (diff_args, argv[prefix.len..][0..diff_args.len]) |expected, actual| try t.expectEqualStrings(expected, actual);
        }
    }
    const invalid = try display(t.allocator, "\xff\u{202e}\u{85}", 128);
    defer t.allocator.free(invalid);
    try t.expectEqualStrings("\\xff\\xe2\\x80\\xae\\xc2\\x85", invalid);
}

test "command display bounds shared helper allocation before escaping oversized input" {
    const t = std.testing;
    const raw: [status.max_path_bytes + 1]u8 = @splat('a');
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const label = try display(fixed.allocator(), &raw, 16);
    try t.expectEqualStrings("aaaaaaaaaaaaa...", label);
}
