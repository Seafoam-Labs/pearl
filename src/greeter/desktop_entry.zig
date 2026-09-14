//! Bounded desktop metadata/Exec parser, with no process or filesystem authority.
const std = @import("std");
const p = @import("protocol.zig");
const A = std.mem.Allocator;
pub const Entry = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    try_exec: []const u8 = "",
    desktops: []const u8 = "",
    icon: []const u8 = "",
    hidden: bool = false,
    no_display: bool = false,
    application: bool = false,
};
fn unescape(a: A, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        var c = value[i];
        if (c == '\\') {
            i += 1;
            if (i == value.len) return error.InvalidEscape;
            c = switch (value[i]) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => return error.InvalidEscape,
            };
        }
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}
pub fn parse(a: A, bytes: []const u8, locale: []const u8) !Entry {
    if (!p.validText(bytes, 65536)) return error.InvalidDesktopEntry;
    var out: Entry = .{};
    var active = false;
    var found = false;
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(a);
    var best_locale: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            active = std.mem.eql(u8, line, "[Desktop Entry]");
            if (active and found) return error.DuplicateGroup;
            found = found or active;
            continue;
        }
        if (!active) continue;
        const n = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidDesktopEntry;
        const key = std.mem.trim(u8, line[0..n], " \t");
        const result = try keys.getOrPut(a, key);
        if (result.found_existing) return error.DuplicateKey;
        const v = std.mem.trim(u8, line[n + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Hidden")) out.hidden = try boolean(v) else if (std.mem.eql(u8, key, "NoDisplay")) out.no_display = try boolean(v) else if (std.mem.eql(u8, key, "Terminal") and try boolean(v)) return error.TerminalSessionUnsupported else if (std.mem.eql(u8, key, "Type")) out.application = std.mem.eql(u8, v, "Application") else if (std.mem.eql(u8, key, "Name")) {
            if (best_locale == 0) out.name = try unescape(a, v);
        } else if (std.mem.startsWith(u8, key, "Name[") and std.mem.endsWith(u8, key, "]")) {
            const lang = key[5 .. key.len - 1];
            const rank: usize = if (std.mem.eql(u8, locale, lang)) 2 else if (std.mem.indexOfScalar(u8, locale, '_')) |end| (if (std.mem.eql(u8, locale[0..end], lang)) 1 else 0) else 0;
            if (rank > best_locale) {
                out.name = try unescape(a, v);
                best_locale = rank;
            }
        } else if (std.mem.eql(u8, key, "Exec")) out.exec = try unescape(a, v) else if (std.mem.eql(u8, key, "TryExec")) out.try_exec = try unescape(a, v) else if (std.mem.eql(u8, key, "DesktopNames")) out.desktops = try unescape(a, v) else if (std.mem.eql(u8, key, "Icon")) out.icon = try unescape(a, v) else if (std.mem.eql(u8, key, "Path") and v.len != 0) return error.WorkingDirectoryUnsupported;
    }
    if (!found) return error.InvalidDesktopEntry;
    if (!out.hidden and (!out.application or out.name.len == 0 or out.exec.len == 0)) return error.InvalidDesktopEntry;
    return out;
}
fn boolean(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}
/// Input is the decoded Exec string (desktop string escapes already processed).
/// Field codes are expanded as argv, never passed to a shell by this parser.
pub fn arguments(a: A, entry: Entry, path: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var total: usize = 0;
    while (i < entry.exec.len) {
        while (i < entry.exec.len and entry.exec[i] == ' ') : (i += 1) {}
        if (i == entry.exec.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quoted = false;
        var was_quoted = false;
        var started = false;
        while (i < entry.exec.len) : (i += 1) {
            const c = entry.exec[i];
            if (!quoted and c == ' ') break;
            if (c == '"') {
                quoted = !quoted;
                was_quoted = true;
                started = true;
                continue;
            }
            if (c == '\\') {
                i += 1;
                if (i == entry.exec.len) return error.InvalidExec;
                if (quoted and std.mem.indexOfScalar(u8, "\"`$\\", entry.exec[i]) == null) return error.InvalidExec;
                try word.append(a, entry.exec[i]);
                started = true;
                continue;
            }
            if ((!quoted and std.mem.indexOfScalar(u8, "\t\n\r'`><~|&;$()", c) != null) or (quoted and (c == '$' or c == '`'))) return error.InvalidExec;
            try word.append(a, c);
            started = true;
        }
        if (quoted or !started) return error.InvalidExec;
        const token = try word.toOwnedSlice(a);
        if (was_quoted and std.mem.indexOfScalar(u8, token, '%') != null) return error.QuotedFieldCode;
        if (std.mem.eql(u8, token, "%f") or std.mem.eql(u8, token, "%F") or std.mem.eql(u8, token, "%u") or std.mem.eql(u8, token, "%U")) continue;
        if (std.mem.eql(u8, token, "%i")) {
            if (entry.icon.len > 0) {
                total += entry.icon.len + 8;
                if (total > 32768) return error.ExecLimit;
                try argv.append(a, "--icon");
                try argv.append(a, entry.icon);
            }
        } else {
            var expanded: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            while (n < token.len) : (n += 1) {
                if (token[n] != '%') {
                    if (expanded.items.len >= 32768) return error.ExecLimit;
                    try expanded.append(a, token[n]);
                    continue;
                }
                n += 1;
                if (n == token.len) return error.InvalidFieldCode;
                switch (token[n]) {
                    '%' => {
                        if (expanded.items.len >= 32768) return error.ExecLimit;
                        try expanded.append(a, '%');
                    },
                    'c' => {
                        if (entry.name.len > 32768 - expanded.items.len) return error.ExecLimit;
                        try expanded.appendSlice(a, entry.name);
                    },
                    'k' => {
                        if (path.len > 32768 - expanded.items.len) return error.ExecLimit;
                        try expanded.appendSlice(a, path);
                    },
                    else => return error.InvalidFieldCode,
                }
            }
            const arg = try expanded.toOwnedSlice(a);
            total += arg.len + 1;
            try argv.append(a, arg);
        }
        if (argv.items.len > 256 or total > 32768) return error.ExecLimit;
    }
    if (argv.items.len == 0 or argv.items[0].len == 0 or std.mem.indexOfScalar(u8, argv.items[0], '=') != null) return error.InvalidExec;
    return argv.toOwnedSlice(a);
}
test "localized metadata and argv quoting do not execute shell metacharacters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parse(a, "[Desktop Entry]\nType=Application\nName=Desktop\nName[fr]=Bureau\nName[fr_CA]=Bureau canadien\nExec=/usr/bin/example \"two words\" %c %% %f\n", "fr_CA");
    const argv = try arguments(a, e, "/usr/share/wayland-sessions/example.desktop");
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("two words", argv[1]);
    try std.testing.expectEqualStrings("Bureau canadien", argv[2]);
    try std.testing.expectEqualStrings("%", argv[3]);
    try std.testing.expectError(error.InvalidExec, arguments(a, .{ .exec = "example;touch /tmp/no" }, ""));
    try std.testing.expectError(error.InvalidFieldCode, arguments(a, .{ .exec = "example %z" }, ""));
    try std.testing.expectError(error.DuplicateKey, parse(a, "[Desktop Entry]\nHidden=true\nHidden=false\n", "C"));
}

test "field expansion has a hard allocation bound and preserves argument boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try a.alloc(u8, 32769);
    @memset(huge, 'x');
    try std.testing.expectError(error.ExecLimit, arguments(a, .{ .name = huge, .exec = "/usr/bin/example %c" }, ""));
    try std.testing.expectError(error.QuotedFieldCode, arguments(a, .{ .exec = "/usr/bin/example \"%c\"" }, ""));
    const args = try arguments(a, .{ .name = "Name with spaces", .icon = "an icon", .exec = "/usr/bin/example %i %c %k" }, "/a path/file.desktop");
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("an icon", args[2]);
    try std.testing.expectEqualStrings("/a path/file.desktop", args[4]);
}
