const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");

pub const Result = struct { bytes: u64 = 0, complete: bool = true };

/// Recursive sum of apparent file sizes under `file`. Only enumeration and
/// standard attributes are used, so this works on every GVfs backend (local,
/// SFTP, SMB, …) — unlike File.measureDiskUsage, which some backends (SFTP)
/// do not implement. Returns null when the top level cannot be read or the
/// walk is cancelled; unreadable subtrees are skipped and flag `complete`.
pub fn folderSize(file: *gio.File, cancel: ?*gio.Cancellable) ?Result {
    var result: Result = .{};
    walk(file, &result, cancel, 0) catch return null;
    return result;
}

fn cancelled(cancel: ?*gio.Cancellable) bool {
    return if (cancel) |c| c.isCancelled() != 0 else false;
}

fn walk(dir: *gio.File, result: *Result, cancel: ?*gio.Cancellable, depth: usize) error{ Cancelled, Unreadable }!void {
    if (depth > 128) {
        result.complete = false;
        return;
    }
    if (cancelled(cancel)) return error.Cancelled;
    var err: ?*glib.Error = null;
    const entries = dir.enumerateChildren("standard::name,standard::type,standard::size", .{ .nofollow_symlinks = true }, cancel, &err) orelse {
        if (err) |e| e.free();
        return error.Unreadable;
    };
    defer entries.unref();
    while (true) {
        if (cancelled(cancel)) return error.Cancelled;
        var next_err: ?*glib.Error = null;
        const info = entries.nextFile(cancel, &next_err) orelse {
            if (next_err) |e| {
                e.free();
                if (cancelled(cancel)) return error.Cancelled;
                result.complete = false;
            }
            break;
        };
        defer info.unref();
        if (info.getFileType() == .directory) {
            const child = dir.getChild(info.getName());
            defer child.unref();
            walk(child, result, cancel, depth + 1) catch |e| switch (e) {
                error.Cancelled => return error.Cancelled,
                error.Unreadable => result.complete = false,
            };
        } else result.bytes += @intCast(@max(info.getSize(), 0));
    }
}

fn removeTree(file: *gio.File) void {
    var err: ?*glib.Error = null;
    const entries = file.enumerateChildren("standard::name,standard::type", .{}, null, &err);
    if (entries) |e| {
        while (e.nextFile(null, null)) |info| {
            defer info.unref();
            const child = file.getChild(info.getName());
            defer child.unref();
            if (info.getFileType() == .directory) removeTree(child);
            _ = child.delete(null, null);
        }
        e.unref();
    }
    if (err) |e| e.free();
    _ = file.delete(null, null);
}

fn writeFixture(file: *gio.File, value: []const u8) void {
    std.debug.assert(file.replaceContents(value.ptr, value.len, null, 0, .{}, null, null, null) != 0);
}

test "folderSize sums nested files and flags unreadable subtrees" {
    const path = glib.Dir.makeTmp("phyto-measure-XXXXXX", null) orelse unreachable;
    defer glib.free(path);
    const root = gio.File.newForPath(path);
    defer root.unref();
    defer removeTree(root);
    const sub = root.getChild("sub");
    defer sub.unref();
    try std.testing.expect(sub.makeDirectory(null, null) != 0);
    var big: [1000]u8 = undefined;
    @memset(&big, 0);
    var small: [250]u8 = undefined;
    @memset(&small, 0);
    const a = root.getChild("a.bin");
    defer a.unref();
    writeFixture(a, &big);
    const b = sub.getChild("b.bin");
    defer b.unref();
    writeFixture(b, &small);
    const result = folderSize(root, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1250), result.bytes);
    try std.testing.expect(result.complete);
    // An unreadable subtree is skipped, not fatal: the readable remainder
    // still counts and the result is flagged incomplete. Root bypasses mode
    // checks, so only assert this for unprivileged test runs.
    if (std.c.geteuid() != 0) {
        const locked = root.getChild("locked");
        defer locked.unref();
        try std.testing.expect(locked.makeDirectory(null, null) != 0);
        const hidden = locked.getChild("hidden.bin");
        defer hidden.unref();
        writeFixture(hidden, &small);
        const mode = gio.FileInfo.new();
        defer mode.unref();
        mode.setAttributeUint32("unix::mode", 0o000);
        try std.testing.expect(locked.setAttributesFromInfo(mode, .{}, null, null) != 0);
        const partial = folderSize(root, null) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u64, 1250), partial.bytes);
        try std.testing.expect(!partial.complete);
        mode.setAttributeUint32("unix::mode", 0o700);
        try std.testing.expect(locked.setAttributesFromInfo(mode, .{}, null, null) != 0);
    }
}
