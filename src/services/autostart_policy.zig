//! Pure XDG autostart rules: desktop-entry parsing, launch selection and the
//! file texts Pearl writes. Mirrors what gnome-session and Plasma honor:
//! Hidden, the legacy X-GNOME-Autostart-enabled key, TryExec, OnlyShowIn and
//! NotShowIn against XDG_CURRENT_DESKTOP, and X-GNOME-Autostart-Delay.
const std = @import("std");

pub const Source = enum { user, system };

pub const Limits = struct {
    pub const entries = 64;
    pub const text = 64 * 1024;
    pub const delay = 3600;
};

pub const Entry = struct {
    /// Base name in the autostart directory, e.g. `firefox.desktop`.
    file: []const u8,
    name: []const u8,
    comment: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    hidden: bool = false,
    /// Legacy `X-GNOME-Autostart-enabled=false`; null when the key is absent.
    autostart_enabled: ?bool = null,
    try_exec: []const u8 = "",
    only_show_in: []const []const u8 = &.{},
    not_show_in: []const []const u8 = &.{},
    delay: u32 = 0,
    /// Desktop ID recorded by Pearl when the entry was added through Settings.
    app_id: ?[]const u8 = null,
    managed: bool = false,
    source: Source = .user,
    /// A user file replacing a system entry of the same name.
    masks_system: bool = false,
};

/// The keys Pearl writes when adding an application through Settings.
pub const New = struct {
    app_id: []const u8,
    name: []const u8,
    comment: []const u8 = "",
    exec: []const u8,
    icon: []const u8 = "",
};

pub fn desktopId(id: []const u8) bool {
    if (id.len < 9 or id.len > 1024 or !std.mem.endsWith(u8, id, ".desktop") or !std.unicode.utf8ValidateSlice(id)) return false;
    if (id[0] == '.' or id[0] == '/') return false;
    for (id) |ch| if (ch < 32 or ch == 127 or ch == '/' or ch == '\\') return false;
    return std.mem.indexOf(u8, id, "..") == null;
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn boolean(value: []const u8) ?bool {
    if (eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

fn list(alloc: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, value, ';');
    while (parts.next()) |part| {
        const text = trim(part);
        if (text.len == 0) continue;
        try items.append(alloc, text);
    }
    return items.toOwnedSlice(alloc);
}

fn validText(value: []const u8) bool {
    if (value.len > Limits.text) return false;
    for (value) |ch| if (ch < 32 and ch != '\t') return false;
    return std.unicode.utf8ValidateSlice(value);
}

/// Reads one `[Desktop Entry]` group. Returns null when the text is not a
/// launchable application entry. Localized keys (`Name[de]=`) are ignored;
/// the first plain occurrence of a key wins.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, source: Source, file: []const u8) !?Entry {
    var entry: Entry = .{ .file = file, .name = "", .source = source };
    var seen_group = false;
    var type_ok = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const closed = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            seen_group = std.mem.eql(u8, line[1..closed], "Desktop Entry");
            continue;
        }
        if (!seen_group) continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = trim(line[0..split]);
        if (std.mem.indexOfScalar(u8, name, '[') != null) continue;
        const value = trim(line[split + 1 ..]);
        if (!validText(value)) return null;
        if (eqlIgnoreCase(name, "Type")) {
            type_ok = eqlIgnoreCase(value, "Application");
        } else if (eqlIgnoreCase(name, "Name") and entry.name.len == 0) {
            entry.name = value;
        } else if (eqlIgnoreCase(name, "GenericName") and entry.name.len == 0) {
            entry.name = value;
        } else if (eqlIgnoreCase(name, "Comment") and entry.comment.len == 0) {
            entry.comment = value;
        } else if (eqlIgnoreCase(name, "Exec") and entry.exec.len == 0) {
            entry.exec = value;
        } else if (eqlIgnoreCase(name, "Icon") and entry.icon.len == 0) {
            entry.icon = value;
        } else if (eqlIgnoreCase(name, "Hidden") and !entry.hidden) {
            entry.hidden = boolean(value) orelse false;
        } else if (eqlIgnoreCase(name, "X-GNOME-Autostart-enabled") and entry.autostart_enabled == null) {
            entry.autostart_enabled = boolean(value);
        } else if (eqlIgnoreCase(name, "TryExec") and entry.try_exec.len == 0) {
            entry.try_exec = value;
        } else if (eqlIgnoreCase(name, "OnlyShowIn") and entry.only_show_in.len == 0) {
            entry.only_show_in = try list(alloc, value);
        } else if (eqlIgnoreCase(name, "NotShowIn") and entry.not_show_in.len == 0) {
            entry.not_show_in = try list(alloc, value);
        } else if (eqlIgnoreCase(name, "X-GNOME-Autostart-Delay") and entry.delay == 0) {
            entry.delay = @min(std.fmt.parseInt(u32, value, 10) catch 0, Limits.delay);
        } else if (eqlIgnoreCase(name, "X-Pearl-Source-Id") and entry.app_id == null) {
            if (desktopId(value)) entry.app_id = value;
        } else if (eqlIgnoreCase(name, "X-Pearl-Managed") and !entry.managed) {
            entry.managed = boolean(value) orelse false;
        }
    }
    if (!type_ok or entry.exec.len == 0 or entry.name.len == 0) return null;
    return entry;
}

/// An entry runs when it is neither hidden nor legacy-disabled, targets this
/// desktop and its TryExec program exists.
pub fn launchable(entry: Entry, desktops: []const []const u8, try_exec_found: *const fn ([]const u8) bool) bool {
    if (entry.hidden) return false;
    if (entry.autostart_enabled != null and !entry.autostart_enabled.?) return false;
    if (entry.only_show_in.len > 0) {
        var shown = false;
        for (desktops) |desktop| for (entry.only_show_in) |allowed| {
            if (eqlIgnoreCase(desktop, allowed)) shown = true;
        };
        if (!shown) return false;
    }
    for (desktops) |desktop| for (entry.not_show_in) |blocked| {
        if (eqlIgnoreCase(desktop, blocked)) return false;
    };
    if (entry.try_exec.len > 0 and !try_exec_found(entry.try_exec)) return false;
    return true;
}

fn setHiddenLine(out: *std.ArrayList(u8), alloc: std.mem.Allocator, hidden: bool) !void {
    if (!hidden) return;
    try out.appendSlice(alloc, "Hidden=true\n");
}

/// Rewrites a desktop-entry text with `Hidden` toggled, preserving every
/// other line. Un-hiding also drops the legacy X-GNOME-Autostart-enabled
/// key so enabling always yields a runnable entry. The key is inserted
/// directly after the `[Desktop Entry]` header when it does not exist.
pub fn setHidden(alloc: std.mem.Allocator, text: []const u8, hidden: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var seen_group = false;
    var wrote_key = false;
    var offset: usize = 0;
    while (offset < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, offset, '\n')) |i| i + 1 else text.len;
        const raw = text[offset..end];
        const line = trim(std.mem.trim(u8, raw, "\n"));
        if (line.len > 0 and line[0] == '[') {
            // Leaving the group without having written the key appends it last.
            if (seen_group and hidden and !wrote_key) try setHiddenLine(&out, alloc, true);
            const closed = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
            seen_group = std.mem.eql(u8, line[1..closed], "Desktop Entry");
            try out.appendSlice(alloc, raw);
            if (seen_group and hidden and !wrote_key) {
                try setHiddenLine(&out, alloc, true);
                wrote_key = true;
            }
            offset = end;
            continue;
        }
        var drop = false;
        if (seen_group) {
            if (std.mem.indexOfScalar(u8, line, '=')) |split| {
                const name = trim(line[0..split]);
                if (std.mem.indexOfScalar(u8, name, '[') == null and (eqlIgnoreCase(name, "Hidden") or (eqlIgnoreCase(name, "X-GNOME-Autostart-enabled") and !hidden))) {
                    drop = true;
                    if (eqlIgnoreCase(name, "Hidden") and hidden and !wrote_key) {
                        try setHiddenLine(&out, alloc, true);
                        wrote_key = true;
                    }
                }
            }
        }
        if (!drop) try out.appendSlice(alloc, raw);
        offset = end;
    }
    if (seen_group and hidden and !wrote_key) try setHiddenLine(&out, alloc, true);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

/// Renders the file Pearl writes into the user autostart directory. The
/// X-Pearl keys record that the entry is managed and which installed
/// application it was created from.
pub fn render(alloc: std.mem.Allocator, entry: New) ![]const u8 {
    if (!desktopId(entry.app_id)) return error.InvalidDesktopId;
    for ([_][]const u8{ entry.name, entry.comment, entry.exec, entry.icon }) |value| {
        if (value.len > 4096) return error.InvalidValue;
        for (value) |ch| if (ch < 32 or ch == 127) return error.InvalidValue;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
    }
    if (entry.name.len == 0 or entry.exec.len == 0) return error.InvalidValue;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "[Desktop Entry]\nType=Application\nName=");
    try out.appendSlice(alloc, entry.name);
    if (entry.comment.len > 0) {
        try out.appendSlice(alloc, "\nComment=");
        try out.appendSlice(alloc, entry.comment);
    }
    try out.appendSlice(alloc, "\nExec=");
    try out.appendSlice(alloc, entry.exec);
    if (entry.icon.len > 0) {
        try out.appendSlice(alloc, "\nIcon=");
        try out.appendSlice(alloc, entry.icon);
    }
    try out.appendSlice(alloc, "\nTerminal=false\nX-Pearl-Managed=true\nX-Pearl-Source-Id=");
    try out.appendSlice(alloc, entry.app_id);
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

pub fn sort(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, l: Entry, r: Entry) bool {
            const order = std.mem.order(u8, l.name, r.name);
            return if (order != .eq) order == .lt else std.mem.order(u8, l.file, r.file) == .lt;
        }
    }.less);
}

test "parse reads launchable application entries and skips the rest" {
    const alloc = std.testing.allocator;
    const text =
        \\[Desktop Entry]
        \\Type=Application
        \\Name[de]=Feuerfuchs
        \\Name=Firefox
        \\Comment=Browse the web
        \\Exec=/usr/bin/firefox %u
        \\Icon=firefox
        \\TryExec=/usr/bin/firefox
        \\OnlyShowIn=GNOME;Pearl;
        \\X-GNOME-Autostart-Delay=5
        \\X-Pearl-Managed=true
        \\X-Pearl-Source-Id=firefox.desktop
        \\
    ;
    const entry = (try parse(alloc, text, .user, "firefox.desktop")).?;
    defer alloc.free(entry.only_show_in);
    try std.testing.expectEqualStrings("Firefox", entry.name);
    try std.testing.expectEqualStrings("/usr/bin/firefox %u", entry.exec);
    try std.testing.expectEqual(@as(u32, 5), entry.delay);
    try std.testing.expectEqual(@as(usize, 2), entry.only_show_in.len);
    try std.testing.expect(entry.managed);
    try std.testing.expectEqualStrings("firefox.desktop", entry.app_id.?);
    try std.testing.expect(try parse(alloc, "[Desktop Entry]\nType=Link\nName=x\nExec=y\n", .user, "x.desktop") == null);
    try std.testing.expect(try parse(alloc, "[Desktop Entry]\nType=Application\nName=x\n", .user, "x.desktop") == null);
    try std.testing.expect(try parse(alloc, "[Desktop Action]\nType=Application\nName=x\nExec=y\n", .user, "x.desktop") == null);
    try std.testing.expect(try parse(alloc, "[Desktop Entry]\nType=Application\nName=bad\x01\nExec=y\n", .user, "x.desktop") == null);
}

test "launch selection honors hidden, legacy, desktops and TryExec" {
    const alloc = std.testing.allocator;
    const found = struct {
        fn f(program: []const u8) bool {
            return std.mem.eql(u8, program, "present");
        }
    }.f;
    const base = (try parse(alloc, "[Desktop Entry]\nType=Application\nName=a\nExec=a\n", .user, "a.desktop")).?;
    const desktops = [_][]const u8{ "Pearl", "GNOME" };
    try std.testing.expect(launchable(base, &desktops, found));
    try std.testing.expect(!launchable(.{ .hidden = true, .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(!launchable(.{ .autostart_enabled = false, .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(!launchable(.{ .only_show_in = &.{"KDE"}, .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(launchable(.{ .only_show_in = &.{ "KDE", "pearl" }, .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(!launchable(.{ .not_show_in = &.{"GNOME"}, .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(!launchable(.{ .try_exec = "absent", .file = "a", .name = "a", .exec = "a" }, &desktops, found));
    try std.testing.expect(launchable(.{ .try_exec = "present", .file = "a", .name = "a", .exec = "a" }, &desktops, found));
}

test "setHidden preserves other lines and clears the legacy key on enable" {
    const alloc = std.testing.allocator;
    const text =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=a
        \\Exec=a
        \\X-GNOME-Autostart-enabled=false
        \\
    ;
    const hidden = try setHidden(alloc, text, true);
    defer alloc.free(hidden);
    try std.testing.expectEqualStrings("[Desktop Entry]\nHidden=true\nType=Application\nName=a\nExec=a\nX-GNOME-Autostart-enabled=false\n", hidden);
    const shown = try setHidden(alloc, hidden, false);
    defer alloc.free(shown);
    try std.testing.expectEqualStrings("[Desktop Entry]\nType=Application\nName=a\nExec=a\n", shown);
    const again = try setHidden(alloc, shown, true);
    defer alloc.free(again);
    const entry = (try parse(alloc, again, .user, "a.desktop")).?;
    try std.testing.expect(entry.hidden);
    // An existing Hidden line is replaced in place, never duplicated.
    const replaced = try setHidden(alloc, again, true);
    defer alloc.free(replaced);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replaced, "Hidden="));
}

test "render writes managed entries that parse back" {
    const alloc = std.testing.allocator;
    const text = try render(alloc, .{ .app_id = "org.example.App.desktop", .name = "Example", .comment = "An example", .exec = "/usr/bin/example --start", .icon = "org.example.App" });
    defer alloc.free(text);
    const entry = (try parse(alloc, text, .user, "org.example.App.desktop")).?;
    try std.testing.expect(entry.managed);
    try std.testing.expectEqualStrings("org.example.App.desktop", entry.app_id.?);
    try std.testing.expectEqualStrings("Example", entry.name);
    try std.testing.expectError(error.InvalidDesktopId, render(alloc, .{ .app_id = "bad", .name = "x", .exec = "y" }));
    try std.testing.expectError(error.InvalidValue, render(alloc, .{ .app_id = "ok.desktop", .name = "x\ny", .exec = "y" }));
    try std.testing.expectError(error.InvalidValue, render(alloc, .{ .app_id = "ok.desktop", .name = "", .exec = "y" }));
}

test "desktop ids reject traversal and control characters" {
    try std.testing.expect(desktopId("firefox.desktop"));
    try std.testing.expect(desktopId("org.example.App.desktop"));
    try std.testing.expect(!desktopId("../etc/passwd.desktop"));
    try std.testing.expect(!desktopId("sub/dir.desktop"));
    try std.testing.expect(!desktopId("bad\x7f.desktop"));
    try std.testing.expect(!desktopId(".desktop"));
}
