//! Opt-in Qt integration. Call on a worker with an arena and committed preferences.
//! Each target has a write-ahead ownership record; user edits are never rolled back.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const io = @import("io.zig");
const ini = @import("ini.zig");
const json_keys = @import("json_keys.zig");
const model = @import("preferences.zig");
const qt = @import("../theme/qt.zig");
const theme = @import("../theme/theme.zig");
const helper = @import("helper_process.zig");
// The pinned GIR marks this return nonnullable; GLib returns NULL at EOF.
extern "c" fn g_dir_read_name(*glib.Dir) ?[*:0]const u8;
const Record = struct {
    group: []const u8,
    key: []const u8,
    original: ?[]const u8 = null,
    last: ?[]const u8 = null,
    owned: bool = false,
    pending: bool = false,
    next: ?[]const u8 = null,
    next_owned: bool = false,
};
const Ledger = struct { version: u32 = 1, records: []Record = &.{} };
pub const Review = struct { digest: [64]u8, text: []const u8, hashes: [5][64]u8 };
pub fn review(a: std.mem.Allocator, root: []const u8, cancel: *gio.Cancellable) !Review {
    const state_fd = try directory(a, try std.fmt.allocPrint(a, "{s}/pearl/qt", .{root}), false);
    defer _ = std.c.close(state_fd);
    var content: std.ArrayList(u8) = .empty;
    var details: std.ArrayList(u8) = .empty;
    var hashes: [5][64]u8 = undefined;
    for ([_][]const u8{ "qt5", "qt6", "darkly", "kde", "engine" }, 0..) |name, index| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, if (index == 4) "qtengine/config.json" else if (index == 3) "kdeglobals" else if (index == 2) "darklyrc" else if (index == 0) "qt5ct/qt5ct.conf" else "qt6ct/qt6ct.conf" }, 0);
        const external = try io.read(a, path, 65536, cancel);
        hashes[index] = external.hash;
        const record = try io.read(a, try at(a, state_fd, try std.fmt.allocPrint(a, "{s}.json", .{name})), 32768, cancel);
        try content.appendSlice(a, &external.hash);
        try content.appendSlice(a, &record.hash);
        if (record.missing) continue;
        const ledger = try std.json.parseFromSliceLeaky(Ledger, a, record.bytes, .{});
        if (ledger.version != 1 or ledger.records.len > 16) return error.InvalidQtLedger;
        for (ledger.records) |field| {
            if (!allowed(name, field.group, field.key)) return error.InvalidQtLedger;
            if (!field.owned and !(field.pending and field.next_owned)) continue;
            const observed = try getField(a, name, external.bytes, field.group, field.key);
            if (ini.equal(observed, field.last)) continue;
            if (field.pending and ini.equal(observed, field.next)) continue;
            const line = try std.json.Stringify.valueAlloc(a, .{ .target = name, .group = field.group, .key = field.key, .current = observed, .pearl = field.last, .original = field.original }, .{});
            try details.appendSlice(a, line);
            try details.append(a, '\n');
        }
    }
    if (details.items.len > 16384) return error.QtReviewTooLarge;
    return .{ .digest = io.digest(content.items), .text = try details.toOwnedSlice(a), .hashes = hashes };
}
const Probe = struct { version: u32, qt: []const u8, darkly: bool, engine: bool, engine_style: bool, alias: bool, family: []const u8, font: []const u8, icon_theme: []const u8, icon_available: bool };

/// Open/create directories using descriptors so no parent symlink can redirect writes.
pub fn directory(a: std.mem.Allocator, path: []const u8, create: bool) !c_int {
    if (path.len == 0 or path[0] != '/' or path.len > 4096) return error.InvalidQtPath;
    var fd = std.c.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.QtDirectoryUnavailable;
    errdefer _ = std.c.close(fd);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidQtPath;
        const z = try a.dupeZ(u8, part);
        var next = std.c.openat(fd, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (next < 0 and std.posix.errno(next) == .NOENT and create) {
            if (std.c.mkdirat(fd, z, 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.QtDirectoryUnavailable;
            next = std.c.openat(fd, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        }
        if (next < 0) return error.QtDirectoryUnavailable;
        _ = std.c.close(fd);
        fd = next;
    }
    return fd;
}
fn at(a: std.mem.Allocator, fd: c_int, name: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "/proc/self/fd/{d}/{s}", .{ fd, name }, 0);
}
fn saveLedger(a: std.mem.Allocator, path: [:0]const u8, ledger: Ledger) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, ledger, .{});
    if (bytes.len > 32768) return error.QtLedgerTooLarge;
    const old = try io.read(a, path, 32768, null);
    if (!old.missing and std.mem.eql(u8, old.bytes, bytes)) return;
    try io.replace(path, bytes, old, null);
}
fn allowed(target: []const u8, group: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, target, "engine")) {
        if (std.mem.eql(u8, group, "theme")) return std.mem.eql(u8, key, "style") or std.mem.eql(u8, key, "colorScheme") or std.mem.eql(u8, key, "iconTheme");
        return std.mem.eql(u8, group, "theme.font") and (std.mem.eql(u8, key, "family") or std.mem.eql(u8, key, "size"));
    } else if (std.mem.eql(u8, target, "kde")) {
        if (std.mem.eql(u8, group, "Colors:View")) return std.mem.eql(u8, key, "DecorationFocus") or std.mem.eql(u8, key, "DecorationHover") or std.mem.eql(u8, key, "ForegroundNegative");
        return std.mem.eql(u8, group, "Colors:Window") and std.mem.eql(u8, key, "BackgroundAlternate");
    } else if (std.mem.eql(u8, target, "darkly")) {
        if (std.mem.eql(u8, group, "Common")) return std.mem.eql(u8, key, "CornerRadius") or std.mem.eql(u8, key, "ButtonHeight") or std.mem.eql(u8, key, "MenuItemHeight");
        if (std.mem.eql(u8, group, "Style")) return std.mem.eql(u8, key, "AnimationsEnabled") or std.mem.eql(u8, key, "ProgressBarAnimated") or std.mem.eql(u8, key, "StackedWidgetTransitionsEnabled");
    } else if (std.mem.eql(u8, target, "qt5") or std.mem.eql(u8, target, "qt6")) {
        if (std.mem.eql(u8, group, "Appearance")) return std.mem.eql(u8, key, "style") or std.mem.eql(u8, key, "custom_palette") or std.mem.eql(u8, key, "color_scheme_path") or std.mem.eql(u8, key, "icon_theme");
        return std.mem.eql(u8, group, "Fonts") and std.mem.eql(u8, key, "general");
    }
    return false;
}

pub fn applyTarget(a: std.mem.Allocator, state_fd: c_int, target: []const u8, path: [:0]const u8, desired: []const ini.Key, cancel: *gio.Cancellable, reviewed: ?[64]u8) !bool {
    const ledger_path = try at(a, state_fd, try std.fmt.allocPrint(a, "{s}.json", .{target}));
    const stored = try io.read(a, ledger_path, 32768, cancel);
    var ledger: Ledger = if (stored.missing) .{} else try std.json.parseFromSliceLeaky(Ledger, a, stored.bytes, .{});
    if (ledger.version != 1 or ledger.records.len > 16) return error.InvalidQtLedger;
    var records: std.ArrayList(Record) = .empty;
    try records.appendSlice(a, ledger.records);
    const old = try io.read(a, path, 65536, cancel);
    if (reviewed) |hash| if (!std.mem.eql(u8, &hash, &old.hash)) return error.QtReviewChanged;
    for (records.items, 0..) |*record, index| {
        if (!allowed(target, record.group, record.key)) return error.InvalidQtLedger;
        for (records.items[0..index]) |other| if (std.mem.eql(u8, other.group, record.group) and std.mem.eql(u8, other.key, record.key)) return error.InvalidQtLedger;
        for ([_]?[]const u8{ record.original, record.last, record.next }) |value| if (value) |v| if (v.len > 4096 or std.mem.indexOfAny(u8, v, "\n\r\x00") != null) return error.InvalidQtLedger;
        // Resolve interrupted commits by observed key values, never by assumption.
        if (record.pending) {
            const observed = try getField(a, target, old.bytes, record.group, record.key);
            if (ini.equal(observed, record.next)) {
                record.last = record.next;
                record.owned = record.next_owned;
            } else if (!ini.equal(observed, record.last)) {
                if (reviewed == null) return error.QtOwnershipConflict;
                record.last = observed;
                record.owned = record.owned or record.next_owned;
            }
            record.pending = false;
        }
        if (record.owned and reviewed != null) record.last = try getField(a, target, old.bytes, record.group, record.key);
        if (desired.len != 0 and record.owned and !ini.equal(try getField(a, target, old.bytes, record.group, record.key), record.last)) return error.QtOwnershipConflict;
    }
    for (desired) |field| {
        if (!allowed(target, field.group, field.key) or field.value == null) return error.InvalidQtField;
        var found = false;
        for (records.items) |record| if (std.mem.eql(u8, record.group, field.group) and std.mem.eql(u8, record.key, field.key)) {
            found = true;
            break;
        };
        if (!found) try records.append(a, .{ .group = field.group, .key = field.key });
    }
    if (records.items.len > 16) return error.InvalidQtLedger;
    var bytes = old.bytes;
    var conflict = false;
    for (records.items) |*record| {
        var wanted: ?[]const u8 = null;
        for (desired) |field| if (std.mem.eql(u8, record.group, field.group) and std.mem.eql(u8, record.key, field.key)) {
            wanted = field.value;
            break;
        };
        const observed = try getField(a, target, old.bytes, record.group, record.key);
        if (record.owned and !ini.equal(observed, record.last)) {
            conflict = true;
            continue;
        }
        if (record.owned and wanted != null and ini.equal(wanted, observed)) continue;
        if (!record.owned and wanted == null) continue;
        if (!record.owned) {
            if (observed) |value| if (value.len > 4096 or std.mem.indexOfAny(u8, value, "\n\r\x00") != null) return error.InvalidQtString;
            record.original = observed;
            record.last = observed;
        }
        record.next = wanted orelse record.original;
        record.next_owned = wanted != null;
        record.pending = true;
        bytes = try patchField(a, target, bytes, .{ .group = record.group, .key = record.key, .value = record.next });
    }
    ledger.records = records.items;
    if (bytes.len > 65536) return error.QtConfigTooLarge;
    if (cancel.isCancelled() != 0) return error.Cancelled;
    // WAL precedes the external write and survives cancellation or process death.
    try saveLedger(a, ledger_path, ledger);
    const changed = !std.mem.eql(u8, bytes, old.bytes);
    if (changed) try io.replace(path, bytes, old, cancel);
    for (records.items) |*record| if (record.pending) {
        record.last = record.next;
        record.owned = record.next_owned;
        record.pending = false;
    };
    try saveLedger(a, ledger_path, ledger);
    if (conflict) return error.QtOwnershipConflict;
    return changed;
}

fn probe(a: std.mem.Allocator, root: []const u8, version: []const u8, p: model.Preferences, cancel: *gio.Cancellable) !Probe {
    var own: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &own, own.len);
    if (n <= 0 or n == own.len) return error.QtProbeUnavailable;
    const sibling = try std.fmt.allocPrintSentinel(a, "{s}/pearl-qt{s}-probe", .{ std.fs.path.dirname(own[0..@intCast(n)]).?, version }, 0);
    const installed = try std.fmt.allocPrintSentinel(a, "/usr/lib/pearl/pearl-qt{s}-probe", .{version}, 0);
    const executable = if (glib.fileTest(sibling, .{ .is_executable = true }) != 0) sibling else installed;
    const family = try a.dupeZ(u8, p.font);
    const size = try std.fmt.allocPrintSentinel(a, "{d}", .{p.font_size}, 0);
    const existing = try std.fmt.allocPrintSentinel(a, "{s}/qtengine/config.json", .{root}, 0);
    const icon = try a.dupeZ(u8, p.qt.icon_theme);
    const result = try helper.run(a, &.{ executable, family, size, existing, icon }, null, cancel, 3000);
    if (!result.success or result.stdout.len > 4096) return error.QtProbeFailed;
    const value = try std.json.parseFromSliceLeaky(Probe, a, result.stdout, .{});
    if (value.version != 2 or !value.darkly) return error.DarklyUnavailable;
    if (!value.engine or !value.engine_style or !value.alias) return error.QtPlatformThemeUnavailable;
    if (!value.icon_available) return error.QtIconThemeUnavailable;
    return value;
}
fn failed(err: anyerror, restore: bool) qt.Target {
    return .{ .state = if (err == error.QtOwnershipConflict) (if (restore) .restore_incomplete else .conflict) else .failed, .error_code = @errorName(err) };
}
fn quote(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
fn getField(a: std.mem.Allocator, target: []const u8, bytes: []const u8, group: []const u8, key: []const u8) !?[]const u8 {
    return if (std.mem.eql(u8, target, "engine")) json_keys.get(a, bytes, group, key) else ini.get(bytes, group, key);
}
fn patchField(a: std.mem.Allocator, target: []const u8, bytes: []const u8, field: ini.Key) ![]const u8 {
    return if (std.mem.eql(u8, target, "engine")) json_keys.patch(a, bytes, field) else ini.patch(a, bytes, field);
}
fn checkTarget(a: std.mem.Allocator, root: []const u8, version: []const u8, enabled: bool, p: model.Preferences, cancel: *gio.Cancellable) qt.Target {
    if (!enabled) return .{};
    _ = probe(a, root, version, p, cancel) catch |err| return .{ .state = .missing_dependency, .error_code = @errorName(err) };
    return .{ .state = .applied };
}
fn integrateEngine(a: std.mem.Allocator, root: []const u8, state_fd: c_int, enabled: bool, p: model.Preferences, palette: theme.Palette, cancel: *gio.Cancellable, reviewed: ?[64]u8) !qt.Target {
    const ledger = try io.read(a, try at(a, state_fd, "engine.json"), 32768, cancel);
    if (!enabled and ledger.missing) return .{};
    const fd = try directory(a, try std.fmt.allocPrint(a, "{s}/qtengine", .{root}), enabled);
    defer _ = std.c.close(fd);
    var desired: std.ArrayList(ini.Key) = .empty;
    if (enabled) {
        const colors = try qt.serializeEngine(a, qt.selected(p.qt, palette));
        const hash = io.digest(colors);
        const color_name = try std.fmt.allocPrint(a, "scheme-{s}.colors", .{hash[0..16]});
        const owned_path = try at(a, state_fd, color_name);
        const previous = try io.read(a, owned_path, 8192, cancel);
        if (previous.missing) try io.atomic(owned_path, colors, true) else if (!std.mem.eql(u8, colors, previous.bytes)) return error.QtPaletteConflict;
        const real_path = try std.fmt.allocPrint(a, "{s}/pearl/qt/{s}", .{ root, color_name });
        try desired.appendSlice(a, &.{ .{ .group = "theme", .key = "style", .value = try quote(a, "Darkly") }, .{ .group = "theme", .key = "colorScheme", .value = try quote(a, real_path) } });
        if (p.qt.sync_font) {
            try desired.append(a, .{ .group = "theme.font", .key = "size", .value = try std.fmt.allocPrint(a, "{d}", .{qt.fontPoints(p.font_size)}) });
            if (p.font.len != 0) try desired.append(a, .{ .group = "theme.font", .key = "family", .value = try quote(a, p.font) });
        }
        if (p.qt.icon_theme.len != 0) try desired.append(a, .{ .group = "theme", .key = "iconTheme", .value = try quote(a, p.qt.icon_theme) });
    }
    _ = applyTarget(a, state_fd, "engine", try at(a, fd, "config.json"), desired.items, cancel, reviewed) catch |err| return failed(err, !enabled);
    return .{ .state = if (enabled) .applied else .disabled };
}
fn restoreLegacy(a: std.mem.Allocator, root: []const u8, state_fd: c_int, version: []const u8, cancel: *gio.Cancellable, reviewed: ?[64]u8) !void {
    const target = try std.fmt.allocPrint(a, "qt{s}", .{version});
    const ledger = try io.read(a, try at(a, state_fd, try std.fmt.allocPrint(a, "{s}.json", .{target})), 32768, cancel);
    if (ledger.missing) return;
    const fd = try directory(a, try std.fmt.allocPrint(a, "{s}/qt{s}ct", .{ root, version }), false);
    defer _ = std.c.close(fd);
    _ = try applyTarget(a, state_fd, target, try at(a, fd, try std.fmt.allocPrint(a, "qt{s}ct.conf", .{version})), &.{}, cancel, reviewed);
}
pub fn reconcile(a: std.mem.Allocator, root: []const u8, p: model.Preferences, palette: theme.Palette, cancel: *gio.Cancellable, reviewed_digest: ?[64]u8) !qt.Status {
    var status: qt.Status = .{ .gtk_fallback = p.qt.enabled and p.qt.palette == .follow_pearl and p.theme.mode == .gtk };
    const state_root = try std.fmt.allocPrint(a, "{s}/pearl/qt", .{root});
    if (!p.qt.enabled and glib.fileTest(try a.dupeZ(u8, state_root), .{ .exists = true }) == 0) return status;
    const state_fd = try directory(a, state_root, p.qt.enabled);
    defer _ = std.c.close(state_fd);
    const lock = std.c.openat(state_fd, "writer.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c_uint, 0o600));
    if (lock < 0) return error.QtWriterUnavailable;
    defer _ = std.c.close(lock);
    if (std.os.linux.errno(std.os.linux.flock(lock, 2 | 4)) != .SUCCESS) return error.QtWriterBusy;
    const reviewed: ?Review = if (reviewed_digest) |expected| blk: {
        const current_review = try review(a, root, cancel);
        if (!std.mem.eql(u8, &expected, &current_review.digest)) return error.QtReviewChanged;
        break :blk current_review;
    } else null;
    const configured = p.qt.enabled and (p.qt.targets.qt5 or p.qt.targets.qt6);
    status.qt5 = checkTarget(a, root, "5", p.qt.enabled and p.qt.targets.qt5, p, cancel);
    status.qt6 = checkTarget(a, root, "6", p.qt.enabled and p.qt.targets.qt6, p, cancel);
    const available = status.qt5.state == .applied or status.qt6.state == .applied;
    if (available or !configured) {
        status.engine = integrateEngine(a, root, state_fd, available and configured, p, palette, cancel, if (reviewed) |r| r.hashes[4] else null) catch |err| failed(err, !configured);
    } else status.engine = .{ .state = .missing_dependency, .error_code = "QtEngineUnavailable" };
    const active = configured and status.engine.state == .applied;
    // Migrate only after publishing a working engine configuration, or on disable.
    if (active or !configured) {
        restoreLegacy(a, root, state_fd, "5", cancel, if (reviewed) |r| r.hashes[0] else null) catch |err| {
            status.qt5 = failed(err, true);
        };
        restoreLegacy(a, root, state_fd, "6", cancel, if (reviewed) |r| r.hashes[1] else null) catch |err| {
            status.qt6 = failed(err, true);
        };
    }
    var notify_darkly = false;
    if (active or !configured) {
        var fields: std.ArrayList(ini.Key) = .empty;
        if (active and p.qt.darkly.sync_kde_colors) {
            const colors = qt.selected(p.qt, palette);
            for ([_]ini.Key{
                .{ .group = "Colors:View", .key = "DecorationFocus", .value = colors.primary },
                .{ .group = "Colors:View", .key = "DecorationHover", .value = colors.primary },
                .{ .group = "Colors:View", .key = "ForegroundNegative", .value = colors.error_color },
                .{ .group = "Colors:Window", .key = "BackgroundAlternate", .value = colors.container },
            }) |field| {
                const color = field.value.?;
                const rgb = try std.fmt.allocPrint(a, "{d},{d},{d}", .{
                    try std.fmt.parseInt(u8, color[1..3], 16), try std.fmt.parseInt(u8, color[3..5], 16), try std.fmt.parseInt(u8, color[5..7], 16),
                });
                try fields.append(a, .{ .group = field.group, .key = field.key, .value = rgb });
            }
        }
        const root_fd = try directory(a, root, false);
        defer _ = std.c.close(root_fd);
        if (applyTarget(a, state_fd, "kde", try at(a, root_fd, "kdeglobals"), fields.items, cancel, if (reviewed) |r| r.hashes[3] else null)) |changed| {
            notify_darkly = changed;
            status.kde.state = if (active and p.qt.darkly.sync_kde_colors) .applied else .disabled;
        } else |err| status.kde = failed(err, !configured);
    }
    // Preserve previously managed Darkly settings on dependency failure; restore on disable.
    if (active or !configured) {
        var fields: std.ArrayList(ini.Key) = .empty;
        if (active) {
            if (p.qt.darkly.corner_radius) |radius| try fields.append(a, .{ .group = "Common", .key = "CornerRadius", .value = try std.fmt.allocPrint(a, "{d}", .{radius}) });
            if (p.qt.darkly.sync_reduced_motion) {
                const value: []const u8 = if (p.reduced_motion) "false" else "true";
                try fields.appendSlice(a, &.{ .{ .group = "Style", .key = "AnimationsEnabled", .value = value }, .{ .group = "Style", .key = "ProgressBarAnimated", .value = value }, .{ .group = "Style", .key = "StackedWidgetTransitionsEnabled", .value = "false" } });
            }
            if (p.qt.darkly.sync_density) try fields.appendSlice(a, &.{ .{ .group = "Common", .key = "ButtonHeight", .value = if (p.density == .compact) "1" else "3" }, .{ .group = "Common", .key = "MenuItemHeight", .value = if (p.density == .compact) "2" else "4" } });
        }
        const root_fd = try directory(a, root, false);
        defer _ = std.c.close(root_fd);
        const darkly_path = try at(a, root_fd, "darklyrc");
        if (applyTarget(a, state_fd, "darkly", darkly_path, fields.items, cancel, if (reviewed) |r| r.hashes[2] else null)) |changed| {
            status.darkly.state = if (active) .applied else .disabled;
            notify_darkly = notify_darkly or changed;
        } else |err| status.darkly = failed(err, !configured);
    }
    // This fixed fragment is read as data by the installed startup script, never sourced.
    const env_path = try at(a, state_fd, "session.conf");
    const old_env = try io.read(a, env_path, 128, cancel);
    const on = "QT_QPA_PLATFORMTHEME=qtengine\n";
    const legacy_on = "QT_QPA_PLATFORMTHEME=qt5ct\n";
    const environment_enabled = active or (configured and std.mem.eql(u8, old_env.bytes, on));
    if (!old_env.missing and old_env.bytes.len != 0 and !std.mem.eql(u8, old_env.bytes, on) and !std.mem.eql(u8, old_env.bytes, legacy_on)) {
        status.environment = failed(error.QtOwnershipConflict, !p.qt.enabled);
    } else {
        // A failed retry must not deactivate a previously working login setup.
        const value = if (active) on else if (configured) old_env.bytes else "";
        if (!ini.equal(value, old_env.bytes)) try io.replace(env_path, value, old_env, cancel);
        status.environment.state = if (environment_enabled) .applied else .disabled;
    }
    if (notify_darkly and glib.getenv("DBUS_SESSION_BUS_ADDRESS") != null) {
        if (gio.busGetSync(.session, cancel, null)) |bus| {
            defer bus.unref();
            _ = bus.emitSignal(null, "/DarklyStyle", "org.kde.Darkly.Style", "reparseConfiguration", null, null);
            _ = bus.flushSync(cancel, null);
        }
    }
    const current = if (glib.getenv("QT_QPA_PLATFORMTHEME")) |s| std.mem.span(s) else "";
    status.restart_session = if (environment_enabled) !std.mem.eql(u8, current, "qtengine") else std.mem.eql(u8, current, "qtengine");
    if (active) if (glib.getenv("QT_STYLE_OVERRIDE")) |s| if (s[0] != 0) {
        status.environment = failed(error.QtStyleOverride, false);
        status.restart_session = true;
    };
    if (active) if (glib.getenv("QTENGINE_CONFIG")) |s| if (s[0] != 0) {
        const expected_path = try std.fmt.allocPrint(a, "{s}/qtengine/config.json", .{root});
        if (!std.mem.eql(u8, std.mem.span(s), expected_path)) {
            status.environment = failed(error.QtEngineConfigOverride, false);
            status.restart_session = true;
        }
    };
    status.restart_apps = active;
    // Also collect unpublished generations after conflicts. An unreadable target
    // prevents collection, but must not turn successful configuration into failure.
    collectPalettes(a, root, state_fd, cancel) catch {};
    return status;
}

fn collectPalettes(a: std.mem.Allocator, root: []const u8, state_fd: c_int, cancel: *gio.Cancellable) !void {
    // Ledgers retain current, initial and interrupted references. Collect only files
    // whose name and contents prove they are generated by this palette adapter.
    const five = try io.read(a, try at(a, state_fd, "qt5.json"), 32768, cancel);
    const six = try io.read(a, try at(a, state_fd, "qt6.json"), 32768, cancel);
    const external_five = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/qt5ct/qt5ct.conf", .{root}, 0), 65536, cancel);
    const external_six = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/qt6ct/qt6ct.conf", .{root}, 0), 65536, cancel);
    const engine = try io.read(a, try at(a, state_fd, "engine.json"), 32768, cancel);
    const external_engine = try io.read(a, try std.fmt.allocPrintSentinel(a, "{s}/qtengine/config.json", .{root}, 0), 65536, cancel);
    const dir = glib.Dir.open(try at(a, state_fd, ""), 0, null) orelse return error.QtDirectoryUnavailable;
    defer dir.close();
    while (g_dir_read_name(dir)) |raw| {
        const name = std.mem.span(raw);
        const scheme = name.len == 30 and std.mem.startsWith(u8, name, "scheme-") and std.mem.endsWith(u8, name, ".colors");
        if (!scheme and (name.len != 31 or (!std.mem.startsWith(u8, name, "palette-5-") and !std.mem.startsWith(u8, name, "palette-6-")) or !std.mem.endsWith(u8, name, ".conf"))) continue;
        if (std.mem.indexOf(u8, five.bytes, name) != null or std.mem.indexOf(u8, six.bytes, name) != null) continue;
        if (std.mem.indexOf(u8, external_five.bytes, name) != null or std.mem.indexOf(u8, external_six.bytes, name) != null) continue;
        if (std.mem.indexOf(u8, engine.bytes, name) != null or std.mem.indexOf(u8, external_engine.bytes, name) != null) continue;
        const file = io.read(a, try at(a, state_fd, name), 8192, cancel) catch continue;
        const prefix = if (scheme) "[General]\nName=Pearl\n" else "[ColorScheme]\n";
        if (!std.mem.startsWith(u8, file.bytes, prefix) or !std.mem.eql(u8, io.digest(file.bytes)[0..16], if (scheme) name[7..23] else name[10..26])) continue;
        if (cancel.isCancelled() != 0) return error.Cancelled;
        _ = std.c.unlinkat(state_fd, try a.dupeZ(u8, name), 0);
    }
}
