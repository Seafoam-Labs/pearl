//! Default-application categories shared by the Settings page. MIME-backed
//! categories are stored through GIO in mimeapps.list so every application
//! that follows the XDG defaults honors them. Terminals have no MIME type;
//! they use the xdg-terminal-exec list (~/.config/xdg-terminals.list).
const std = @import("std");

pub const Category = enum { browser, files, terminal, mail, editor, music, video };

pub const Spec = struct {
    category: Category,
    label: [:0]const u8,
    description: [:0]const u8,
    /// Content types written when this category's default changes. The first
    /// entry is also the type used to discover candidate applications.
    mimes: []const [:0]const u8,
};

pub const specs = [_]Spec{
    .{ .category = .browser, .label = "Web browser", .description = "Opens web links and HTML files.", .mimes = &.{ "x-scheme-handler/http", "x-scheme-handler/https" } },
    .{ .category = .files, .label = "File manager", .description = "Opens folders and drives.", .mimes = &.{"inode/directory"} },
    .{ .category = .terminal, .label = "Terminal", .description = "Runs command-line sessions.", .mimes = &.{} },
    .{ .category = .mail, .label = "Mail", .description = "Composes messages for mailto links.", .mimes = &.{"x-scheme-handler/mailto"} },
    .{ .category = .editor, .label = "Text editor", .description = "Opens plain-text documents.", .mimes = &.{"text/plain"} },
    .{ .category = .music, .label = "Music player", .description = "Plays audio files.", .mimes = &.{"audio/mpeg"} },
    .{ .category = .video, .label = "Video player", .description = "Plays video files.", .mimes = &.{"video/mp4"} },
};

pub const terminal_list_name = "xdg-terminals.list";

/// True when a desktop file's `Categories` list contains `needle`.
pub fn hasCategory(categories: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, categories, ';');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), needle)) return true;
    }
    return false;
}

/// First non-comment, non-empty entry of an xdg-terminals.list document.
pub fn firstTerminalEntry(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        return line;
    }
    return null;
}

/// All entries of an xdg-terminals.list document in file order.
fn terminalEntries(alloc: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer entries.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try entries.append(alloc, line);
    }
    return entries;
}

/// Current terminal default, or null when no list entry exists.
pub fn terminalDefault(alloc: std.mem.Allocator, config_dir: []const u8) !?[]u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const path = try std.fs.path.join(alloc, &.{ config_dir, terminal_list_name });
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(text);
    const entry = firstTerminalEntry(text) orelse return null;
    return try alloc.dupe(u8, entry);
}

/// Make `desktop_id` the terminal default, keeping the remaining list entries
/// in their previous order below it.
pub fn setTerminalDefault(alloc: std.mem.Allocator, config_dir: []const u8, desktop_id: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const path = try std.fs.path.join(alloc, &.{ config_dir, terminal_list_name });
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (text.len > 0) alloc.free(text);
    var entries = try terminalEntries(alloc, text);
    defer entries.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, desktop_id);
    try out.append(alloc, '\n');
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry, desktop_id)) continue;
        try out.appendSlice(alloc, entry);
        try out.append(alloc, '\n');
    }
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

test "terminal list parsing skips comments and blank lines" {
    const t = std.testing;
    try t.expectEqualStrings("org.gnome.Terminal.desktop", firstTerminalEntry("# comment\n\n  org.gnome.Terminal.desktop\nghostty.desktop\n").?);
    try t.expectEqualStrings("ghostty.desktop", firstTerminalEntry("ghostty.desktop").?);
    try t.expect(firstTerminalEntry("# only comments\n\n") == null);
    try t.expect(firstTerminalEntry("") == null);
}

test "terminal default round trips and keeps other entries in order" {
    const t = std.testing;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const config_dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(config_dir);

    try t.expect((try terminalDefault(t.allocator, config_dir)) == null);
    try setTerminalDefault(t.allocator, config_dir, "ghostty.desktop");
    const first = (try terminalDefault(t.allocator, config_dir)).?;
    defer t.allocator.free(first);
    try t.expectEqualStrings("ghostty.desktop", first);

    try setTerminalDefault(t.allocator, config_dir, "org.wezfurlong.wezterm.desktop");
    const text = try tmp.dir.readFileAlloc(io, terminal_list_name, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    try t.expectEqualStrings("org.wezfurlong.wezterm.desktop\nghostty.desktop\n", text);
}

test "terminal category matching splits the desktop Categories list" {
    const t = std.testing;
    try t.expect(hasCategory("System;TerminalEmulator;", "TerminalEmulator"));
    try t.expect(hasCategory("TerminalEmulator", "TerminalEmulator"));
    try t.expect(!hasCategory("System;Utility;", "TerminalEmulator"));
    try t.expect(!hasCategory("NotTerminalEmulator;", "TerminalEmulator"));
    try t.expect(!hasCategory("", "TerminalEmulator"));
}

test "category specs cover every category once with stable discovery types" {
    const t = std.testing;
    var seen: std.EnumSet(Category) = .{};
    for (specs) |spec| {
        try t.expect(!seen.contains(spec.category));
        seen.insert(spec.category);
        try t.expect(spec.label.len > 0 and spec.description.len > 0);
        if (spec.category == .terminal) {
            try t.expectEqual(@as(usize, 0), spec.mimes.len);
        } else try t.expect(spec.mimes.len > 0);
    }
    try t.expectEqual(std.enums.values(Category).len, seen.count());
    try t.expectEqualStrings("x-scheme-handler/http", specs[0].mimes[0]);
    try t.expectEqualStrings("x-scheme-handler/https", specs[0].mimes[1]);
}
