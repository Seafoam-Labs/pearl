//! Context attachments with size budgets and disclosure.
//!
//! Attachments (file / selection / diagnostics / git_diff / folder) are
//! truncated to a per-kind byte budget and an overall total budget. Every
//! rendered prompt carries a disclosure header listing what was attached and
//! whether it was truncated, so the model and the user can see exactly what
//! context was provided.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    file,
    selection,
    diagnostics,
    git_diff,
    folder,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .file => "file",
            .selection => "selection",
            .diagnostics => "diagnostics",
            .git_diff => "git_diff",
            .folder => "folder",
        };
    }
};

pub const Budget = struct {
    file: usize = 64 * 1024,
    selection: usize = 32 * 1024,
    diagnostics: usize = 16 * 1024,
    git_diff: usize = 64 * 1024,
    folder: usize = 8 * 1024,
    total: usize = 256 * 1024,

    pub fn capFor(self: Budget, kind: Kind) usize {
        return switch (kind) {
            .file => self.file,
            .selection => self.selection,
            .diagnostics => self.diagnostics,
            .git_diff => self.git_diff,
            .folder => self.folder,
        };
    }
};

pub const Attachment = struct {
    kind: Kind,
    label: []const u8,
    content: []const u8,
    truncated: bool = false,
    original_len: usize = 0,

    pub fn deinit(self: *Attachment, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.content);
    }
};

/// Truncate to `cap` bytes without splitting a UTF-8 code point.
pub fn truncateUtf8(content: []const u8, cap: usize) []const u8 {
    if (content.len <= cap) return content;
    var end = cap;
    // Back up while the first excluded byte is a continuation byte.
    while (end > 0 and (content[end] & 0xC0) == 0x80) : (end -= 1) {}
    return content[0..end];
}

/// Build an attachment, truncating to `cap` and recording disclosure metadata.
/// The label and content are duplicated into `allocator`.
pub fn prepare(allocator: Allocator, kind: Kind, label: []const u8, content: []const u8, cap: usize) !Attachment {
    const truncated = content.len > cap;
    const kept = truncateUtf8(content, cap);
    return .{
        .kind = kind,
        .label = try allocator.dupe(u8, label),
        .content = try allocator.dupe(u8, kept),
        .truncated = truncated,
        .original_len = content.len,
    };
}

pub fn totalSize(attachments: []const Attachment) usize {
    var sum: usize = 0;
    for (attachments) |a| sum += a.content.len;
    return sum;
}

/// Human-readable disclosure listing each attachment, its size and truncation.
pub fn disclosure(allocator: Allocator, attachments: []const Attachment) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.print(allocator, "Context attachments ({d} bytes total):\n", .{totalSize(attachments)});
    if (attachments.len == 0) try list.appendSlice(allocator, "  (none)\n");
    for (attachments) |a| {
        try list.print(allocator, "  - {s}: {s} ({d} bytes{s})\n", .{
            a.kind.label(),
            a.label,
            a.content.len,
            if (a.truncated) ", truncated" else "",
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Render the full context block injected into the prompt, with disclosure.
pub fn renderPrompt(allocator: Allocator, attachments: []const Attachment) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const disc = try disclosure(allocator, attachments);
    defer allocator.free(disc);
    try list.appendSlice(allocator, "<context>\n");
    try list.appendSlice(allocator, disc);
    for (attachments) |a| {
        try list.print(allocator, "<attachment kind=\"{s}\" label=\"{s}\" bytes=\"{d}\" truncated=\"{s}\">\n", .{
            a.kind.label(), a.label, a.content.len, if (a.truncated) "true" else "false",
        });
        try list.appendSlice(allocator, a.content);
        if (a.content.len == 0 or a.content[a.content.len - 1] != '\n') try list.append(allocator, '\n');
        try list.appendSlice(allocator, "</attachment>\n");
    }
    try list.appendSlice(allocator, "</context>\n");
    return list.toOwnedSlice(allocator);
}

test "truncateUtf8 respects code points" {
    const s = "aé😀z"; // a(1) é(2) 😀(4) z(1)
    try std.testing.expectEqualStrings("a", truncateUtf8(s, 1));
    try std.testing.expectEqualStrings("aé", truncateUtf8(s, 3));
    try std.testing.expectEqualStrings("aé", truncateUtf8(s, 4)); // mid-emoji backs up
    try std.testing.expectEqualStrings("aé😀", truncateUtf8(s, 7));
    try std.testing.expectEqualStrings(s, truncateUtf8(s, 100));
}

test "prepare truncates and discloses" {
    const a = std.testing.allocator;
    var att = try prepare(a, .file, "big.txt", "0123456789", 4);
    defer att.deinit(a);
    try std.testing.expect(att.truncated);
    try std.testing.expectEqualStrings("0123", att.content);
    try std.testing.expectEqual(@as(usize, 10), att.original_len);

    const disc = try disclosure(a, &.{att});
    defer a.free(disc);
    try std.testing.expect(std.mem.indexOf(u8, disc, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, disc, "big.txt") != null);
}

test "renderPrompt includes attachment body and disclosure" {
    const a = std.testing.allocator;
    var att = try prepare(a, .selection, "main.zig:1-2", "const x = 1;", 1024);
    defer att.deinit(a);
    const prompt = try renderPrompt(a, &.{att});
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<context>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "selection") != null);
}

test "budget capFor" {
    const b: Budget = .{};
    try std.testing.expectEqual(@as(usize, 64 * 1024), b.capFor(.file));
    try std.testing.expectEqual(@as(usize, 8 * 1024), b.capFor(.folder));
}
