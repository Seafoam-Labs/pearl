//! Steam library sync: every installed Steam game gets a launcher entry.
//! Steam only writes `steam_app_*.desktop` shortcuts for games installed
//! through its own client flow, so libraries imported from another drive
//! never appear in the launcher. Pearl scans every library recorded in
//! `libraryfolders.vdf`, maintains marked shortcuts of its own, and never
//! touches files Steam or the user owns. Entries land in the standard
//! applications directory, so the app index picks them up through its
//! regular monitor without any launcher changes.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;

/// Marks Pearl-generated shortcuts; unmarked files are never modified or removed.
pub const marker = "X-Pearl-Steam-Appid=";
/// Valve's Steamworks Common Redistributables is not a launcher item.
const redistributable = "228980";
/// StateFlags bit 4 is StateInstalled.
const state_installed: u32 = 4;

pub const Game = struct { appid: []const u8, name: []const u8 };
pub const Stats = struct { games: usize = 0, created: usize = 0, removed: usize = 0 };

const Token = struct { kind: enum { string, open, close }, text: []const u8 = "" };

/// Minimal VDF tokenizer: quoted strings with \" \\ \n \t escapes, braces and
/// `//` comments. Values are unescaped copies owned by `alloc`.
fn tokenize(alloc: std.mem.Allocator, text: []const u8, tokens: *std.ArrayList(Token)) !void {
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            ' ', '\t', '\r', '\n' => i += 1,
            '/' => {
                if (i + 1 < text.len and text[i + 1] == '/') {
                    while (i < text.len and text[i] != '\n') i += 1;
                } else i += 1;
            },
            '{' => {
                try tokens.append(alloc, .{ .kind = .open });
                i += 1;
            },
            '}' => {
                try tokens.append(alloc, .{ .kind = .close });
                i += 1;
            },
            '"' => {
                i += 1;
                var value: std.ArrayList(u8) = .empty;
                var closed = false;
                while (i < text.len) : (i += 1) {
                    switch (text[i]) {
                        '"' => {
                            closed = true;
                            i += 1;
                            break;
                        },
                        '\\' => {
                            i += 1;
                            if (i >= text.len) break;
                            try value.append(alloc, switch (text[i]) {
                                'n' => '\n',
                                't' => '\t',
                                else => text[i],
                            });
                        },
                        else => try value.append(alloc, text[i]),
                    }
                }
                if (!closed) return error.TruncatedVdf;
                try tokens.append(alloc, .{ .kind = .string, .text = value.items });
            },
            else => i += 1,
        }
    }
}

pub const Library = struct { path: []const u8 = "", appids: std.ArrayList([]const u8) = .empty };

/// Walks a `libraryfolders.vdf` and returns each library's path with the appids
/// the file records for it. The appid list lets the sync keep shortcuts for
/// libraries that are momentarily unreadable, such as an unmounted drive.
pub fn parseLibraries(alloc: std.mem.Allocator, text: []const u8) ![]Library {
    var tokens: std.ArrayList(Token) = .empty;
    try tokenize(alloc, text, &tokens);
    var libraries: std.ArrayList(Library) = .empty;
    var depth: usize = 0;
    var in_apps = false;
    var apps_depth: usize = 0;
    var value_slot = false;
    var i: usize = 0;
    while (i < tokens.items.len) : (i += 1) {
        switch (tokens.items[i].kind) {
            .open => depth += 1,
            .close => {
                if (in_apps and depth == apps_depth) in_apps = false;
                if (depth > 0) depth -= 1;
            },
            .string => {
                if (in_apps) {
                    // apps blocks hold `"appid" "size"` pairs; keep the keys.
                    if (!value_slot and libraries.items.len > 0) try libraries.items[libraries.items.len - 1].appids.append(alloc, tokens.items[i].text);
                    value_slot = !value_slot;
                } else if (depth == 1) {
                    try libraries.append(alloc, .{});
                } else if (depth == 2 and libraries.items.len > 0) {
                    const current = &libraries.items[libraries.items.len - 1];
                    if (std.mem.eql(u8, tokens.items[i].text, "path") and i + 1 < tokens.items.len and tokens.items[i + 1].kind == .string) {
                        current.path = tokens.items[i + 1].text;
                        i += 1;
                    } else if (std.mem.eql(u8, tokens.items[i].text, "apps")) {
                        in_apps = true;
                        apps_depth = depth + 1;
                        value_slot = false;
                    }
                }
            },
        }
    }
    return libraries.items;
}

fn numeric(text: []const u8) bool {
    if (text.len == 0 or text.len > 10) return false;
    for (text) |digit| if (digit < '0' or digit > '9') return false;
    return true;
}

/// Valve support components that install like games but are never launchable;
/// Steam hides them from its own library, so Pearl hides them too.
const tool_prefixes = [_][]const u8{ "Proton", "Steam Linux Runtime", "Steam Play", "SteamVR", "Steamworks" };

/// Parses an `appmanifest_*.acf` and accepts only fully installed games.
pub fn installedGame(alloc: std.mem.Allocator, text: []const u8) !?Game {
    const appid = try vdfValue(alloc, text, "appid") orelse return null;
    if (!numeric(appid) or std.mem.eql(u8, appid, redistributable)) return null;
    const state = try vdfValue(alloc, text, "StateFlags") orelse return null;
    const flags = std.fmt.parseInt(u32, state, 10) catch return null;
    if (flags & state_installed == 0) return null;
    const name = try vdfValue(alloc, text, "name") orelse return null;
    if (name.len == 0 or name.len > 512 or !std.unicode.utf8ValidateSlice(name)) return null;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    for (tool_prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return null;
    return .{ .appid = appid, .name = name };
}

/// First value stored under a VDF key, unescaped and owned by `alloc`.
fn vdfValue(alloc: std.mem.Allocator, text: []const u8, key: []const u8) !?[]const u8 {
    var tokens: std.ArrayList(Token) = .empty;
    try tokenize(alloc, text, &tokens);
    var i: usize = 0;
    while (i + 1 < tokens.items.len) : (i += 1) {
        if (tokens.items[i].kind == .string and tokens.items[i + 1].kind == .string and std.mem.eql(u8, tokens.items[i].text, key)) return tokens.items[i + 1].text;
    }
    return null;
}

/// Desktop entry mirroring the format Steam itself generates.
pub fn renderEntry(alloc: std.mem.Allocator, game: Game, command: []const u8) ![]const u8 {
    const quoted = std.mem.indexOfScalar(u8, command, ' ') != null;
    return std.fmt.allocPrint(alloc,
        \\[Desktop Entry]
        \\Name={s}
        \\Comment=Play {s}
        \\Exec={s}{s}{s} steam://rungameid/{s}
        \\Icon=steam_icon_{s}
        \\Terminal=false
        \\Type=Application
        \\Categories=Game;
        \\{s}{s}
        \\
    , .{ game.name, game.name, if (quoted) "\"" else "", command, if (quoted) "\"" else "", game.appid, game.appid, marker, game.appid });
}

fn find(games: []const Game, appid: []const u8) ?Game {
    for (games) |game| if (std.mem.eql(u8, game.appid, appid)) return game;
    return null;
}

fn launchCommand(alloc: std.mem.Allocator, steam_root: []const u8) ![]const u8 {
    const script = try std.fmt.allocPrintSentinel(alloc, "{s}/steam.sh", .{steam_root}, 0);
    if (glib.fileTest(script, .{ .is_regular = true }) != 0) return script;
    return "steam";
}

/// Reads a small text file; null when it is missing or unreadable.
fn readFile(alloc: std.mem.Allocator, tio: std.Io, path: []const u8, limit: usize) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(tio, path, alloc, .limited(limit)) catch null;
}

/// Temp-file plus rename replacement; with `exclusive` a colliding destination
/// fails instead of ever overwriting a file Steam or the user owns.
fn writeFile(path: [:0]const u8, bytes: []const u8, exclusive: bool) !void {
    const temp = try std.fmt.allocPrintSentinel(a, "{s}.pearl-XXXXXX", .{path}, 0);
    defer a.free(temp);
    const fd = glib.mkstempFull(temp, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o644);
    if (fd < 0) return error.SaveFailed;
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(temp);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return error.SaveFailed;
        offset += @intCast(n);
    }
    if (exclusive) {
        if (std.c.link(temp, path) != 0) return error.Conflict;
    } else if (std.c.rename(temp, path) != 0) return error.SaveFailed;
}

/// Scans `steam_root` and every library it records, creating missing shortcuts
/// in `applications` and removing Pearl-generated ones whose game is gone.
/// Unreadable libraries (unmounted or stale) keep their recorded shortcuts.
pub fn syncPaths(steam_root: [:0]const u8, applications: [:0]const u8) !Stats {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    const tio = threaded.io();
    const config_path = try std.fmt.allocPrint(alloc, "{s}/steamapps/libraryfolders.vdf", .{steam_root});
    const config = readFile(alloc, tio, config_path, 4 << 20) orelse return .{};
    const parsed = try parseLibraries(alloc, config);

    const Source = struct { path: []const u8, reserved: []const []const u8 };
    var sources: std.ArrayList(Source) = .empty;
    try sources.append(alloc, .{ .path = steam_root, .reserved = &.{} });
    for (parsed) |library| {
        if (library.path.len == 0 or !std.fs.path.isAbsolute(library.path)) continue;
        var duplicate = std.mem.eql(u8, steam_root, library.path);
        for (sources.items) |seen| duplicate = duplicate or std.mem.eql(u8, seen.path, library.path);
        if (!duplicate) try sources.append(alloc, .{ .path = library.path, .reserved = library.appids.items });
    }

    var games: std.ArrayList(Game) = .empty;
    var reserved: std.ArrayList([]const u8) = .empty;
    for (sources.items) |source| {
        const steamapps = try std.fmt.allocPrint(alloc, "{s}/steamapps", .{source.path});
        var dir = std.Io.Dir.openDirAbsolute(tio, steamapps, .{ .iterate = true }) catch {
            try reserved.appendSlice(alloc, source.reserved);
            continue;
        };
        defer dir.close(tio);
        var iterator = dir.iterate();
        while (iterator.next(tio) catch null) |file| {
            if (file.kind != .file) continue;
            if (!std.mem.startsWith(u8, file.name, "appmanifest_") or !std.mem.endsWith(u8, file.name, ".acf")) continue;
            const text = dir.readFileAlloc(tio, file.name, alloc, .limited(4 << 20)) catch continue;
            const game = try installedGame(alloc, text) orelse continue;
            if (find(games.items, game.appid) == null) try games.append(alloc, game);
        }
    }
    const stats_games = games.items.len;

    const command = try launchCommand(alloc, steam_root);
    if (glib.mkdirWithParents(applications, 0o755) != 0) return error.CreateDirectoryFailed;
    var created: usize = 0;
    for (games.items) |game| {
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/steam_app_{s}.desktop", .{ applications, game.appid }, 0);
        const bytes = try renderEntry(alloc, game, command);
        if (readFile(alloc, tio, path, 16384)) |existing| {
            if (std.mem.indexOf(u8, existing, marker) != null and !std.mem.eql(u8, existing, bytes)) writeFile(path, bytes, false) catch {};
        } else {
            writeFile(path, bytes, true) catch continue;
            created += 1;
        }
    }

    var removed: usize = 0;
    if (std.Io.Dir.openDirAbsolute(tio, applications, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(tio);
        var iterator = dir.iterate();
        while (iterator.next(tio) catch null) |file| {
            if (file.kind != .file) continue;
            if (!std.mem.startsWith(u8, file.name, "steam_app_") or !std.mem.endsWith(u8, file.name, ".desktop")) continue;
            const appid = file.name["steam_app_".len .. file.name.len - ".desktop".len];
            if (!numeric(appid)) continue;
            if (find(games.items, appid) != null) continue;
            var keep = false;
            for (reserved.items) |id| {
                if (std.mem.eql(u8, id, appid)) keep = true;
            }
            if (keep) continue;
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ applications, file.name }, 0);
            const existing = readFile(alloc, tio, path, 16384) orelse continue;
            if (std.mem.indexOf(u8, existing, marker) == null) continue;
            if (std.c.unlink(path) != 0) continue;
            removed += 1;
        }
    } else |_| {}
    return .{ .games = stats_games, .created = created, .removed = removed };
}

fn steamRoots(alloc: std.mem.Allocator, home: []const u8) ![][:0]const u8 {
    const patterns = [_][]const u8{
        "{s}/.local/share/Steam",
        "{s}/.steam/steam",
        "{s}/.var/app/com.valvesoftware.Steam/.local/share/Steam",
        "{s}/.var/app/com.valvesoftware.Steam/.steam/steam",
    };
    var roots: [][:0]const u8 = try alloc.alloc([:0]const u8, patterns.len);
    inline for (patterns, 0..) |pattern, i| roots[i] = try std.fmt.allocPrintSentinel(alloc, pattern, .{home}, 0);
    return roots;
}

/// Resolves the local Steam installation and the user's applications
/// directory, then runs one sync pass.
pub fn sync() !Stats {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const home = std.mem.span(glib.getHomeDir());
    if (home.len == 0) return error.HomeUnavailable;
    const data_home: []const u8 = if (glib.getenv("XDG_DATA_HOME")) |raw| std.mem.span(raw) else try std.fmt.allocPrint(alloc, "{s}/.local/share", .{home});
    const applications = try std.fmt.allocPrintSentinel(alloc, "{s}/applications", .{data_home}, 0);
    for (try steamRoots(alloc, home)) |root| {
        const probe = try std.fmt.allocPrintSentinel(alloc, "{s}/steamapps/libraryfolders.vdf", .{root}, 0);
        if (glib.fileTest(probe, .{ .is_regular = true }) == 0) continue;
        return syncPaths(root, applications);
    }
    return .{};
}

/// Runs one sync pass in a worker thread; written shortcuts refresh the app
/// index through its regular monitor, so no callback state is needed.
pub fn startAsync(app: *gio.Application) void {
    app.hold();
    const task = gio.Task.new(null, null, completed, app);
    task.runInThread(run);
    task.unref();
}

fn run(task: *gio.Task, _: ?*object.Object, _: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    if (sync()) |stats| {
        log.info("event=steam-library-sync games={d} created={d} removed={d}", .{ stats.games, stats.created, stats.removed });
        task.returnBoolean(1);
    } else |_| task.returnBoolean(0);
}

fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const app: *gio.Application = @ptrCast(@alignCast(data.?));
    app.release();
}

const testing = std.testing;

fn tempRoot(alloc: std.mem.Allocator) ![:0]const u8 {
    const template = try alloc.dupeSentinel(u8, "/tmp/pearl-steam-XXXXXX", 0);
    if (glib.mkdtemp(template.ptr) == null) return error.TempUnavailable;
    return template;
}

fn removeTree(root: []const u8) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};
}

fn write(alloc: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const sentinel = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(sentinel);
    const parent = try alloc.dupeSentinel(u8, std.fs.path.dirname(path) orelse "/", 0);
    defer alloc.free(parent);
    if (glib.mkdirWithParents(parent, 0o755) != 0) return error.CreateDirectoryFailed;
    try writeFile(sentinel, bytes, false);
}

fn manifest(alloc: std.mem.Allocator, appid: []const u8, name: []const u8, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\"AppState"
        \\{{
        \\    "appid"        "{s}"
        \\    "Universe"        "1"
        \\    "StateFlags"        "{s}"
        \\    "name"        "{s}"
        \\}}
        \\
    , .{ appid, state, name });
}

fn exists(alloc: std.mem.Allocator, path: []const u8) !bool {
    const sentinel = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(sentinel);
    return glib.fileTest(sentinel, .{ .exists = true }) != 0;
}

test "parseLibraries reads paths and reserves appids per library" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const text =
        \\"libraryfolders"
        \\{
        \\    "0"
        \\    {
        \\        "path"        "/home/u/.local/share/Steam"
        \\        "apps"
        \\        {
        \\            "228980"        "128606066"
        \\        }
        \\    }
        \\    "1"
        \\    {
        \\        "path"        "/mnt/SecondDrive/SteamLibrary"
        \\        "label"        ""
        \\        "apps"
        \\        {
        \\            "230410"        "55734858184"
        \\            "236390"        "91349672784"
        \\        }
        \\    }
        \\}
    ;
    const libraries = try parseLibraries(alloc, text);
    try testing.expectEqual(@as(usize, 2), libraries.len);
    try testing.expectEqualStrings("/home/u/.local/share/Steam", libraries[0].path);
    try testing.expectEqual(@as(usize, 1), libraries[0].appids.items.len);
    try testing.expectEqualStrings("228980", libraries[0].appids.items[0]);
    try testing.expectEqualStrings("/mnt/SecondDrive/SteamLibrary", libraries[1].path);
    try testing.expectEqual(@as(usize, 2), libraries[1].appids.items.len);
    try testing.expectEqualStrings("230410", libraries[1].appids.items[0]);
    try testing.expectEqualStrings("236390", libraries[1].appids.items[1]);
}

test "installedGame accepts installed games only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const installed = try manifest(alloc, "230410", "Warframe", "4");
    const game = (try installedGame(alloc, installed)).?;
    try testing.expectEqualStrings("230410", game.appid);
    try testing.expectEqualStrings("Warframe", game.name);
    try testing.expectEqual(null, try installedGame(alloc, try manifest(alloc, "999", "Gone", "0")));
    try testing.expectEqual(null, try installedGame(alloc, try manifest(alloc, "228980", "Steamworks Common Redistributables", "4")));
    try testing.expectEqual(null, try installedGame(alloc, try manifest(alloc, "1493710", "Proton Experimental", "4")));
    try testing.expectEqual(null, try installedGame(alloc, try manifest(alloc, "1628350", "Steam Linux Runtime 3.0 (sniper)", "4")));
    try testing.expectEqual(null, try installedGame(alloc, "\"AppState\"\n{\n}\n"));
}

test "renderEntry launches through rungameid and carries the marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try renderEntry(alloc, .{ .appid = "440", .name = "Team Fortress 2" }, "/home/u/.local/share/Steam/steam.sh");
    try testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Name=Team Fortress 2
        \\Comment=Play Team Fortress 2
        \\Exec=/home/u/.local/share/Steam/steam.sh steam://rungameid/440
        \\Icon=steam_icon_440
        \\Terminal=false
        \\Type=Application
        \\Categories=Game;
        \\X-Pearl-Steam-Appid=440
        \\
    , bytes);
}

test "syncPaths creates missing shortcuts, keeps foreign files and prunes stale ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = try tempRoot(alloc);
    defer removeTree(root);
    const drive = try std.fmt.allocPrint(alloc, "{s}/mnt/SecondDrive/SteamLibrary", .{root});
    const applications = try std.fmt.allocPrintSentinel(alloc, "{s}/applications", .{root}, 0);
    const vdf = try std.fmt.allocPrint(alloc,
        \\"libraryfolders"
        \\{{
        \\    "0"
        \\    {{
        \\        "path"        "{s}"
        \\        "apps"
        \\        {{
        \\            "228980"        "128606066"
        \\        }}
        \\    }}
        \\    "1"
        \\    {{
        \\        "path"        "{s}"
        \\        "apps"
        \\        {{
        \\            "230410"        "55734858184"
        \\            "1234"        "100"
        \\        }}
        \\    }}
        \\}}
    , .{ root, drive });
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steamapps/libraryfolders.vdf", .{root}), vdf);
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steamapps/appmanifest_228980.acf", .{root}), try manifest(alloc, "228980", "Steamworks Common Redistributables", "4"));
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steam.sh", .{root}), "#!/bin/sh\n");
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steamapps/appmanifest_230410.acf", .{drive}), try manifest(alloc, "230410", "Warframe", "4"));
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steamapps/appmanifest_999.acf", .{drive}), try manifest(alloc, "999", "Uninstalled", "0"));
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_1234.desktop", .{root}), try std.fmt.allocPrint(alloc, "[Desktop Entry]\nName=Old\n{s}1234\n", .{marker}));
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_230410.desktop", .{root}), "[Desktop Entry]\nName=Steam Owned\n");

    const first = try syncPaths(root, applications);
    try testing.expectEqual(@as(usize, 1), first.games);
    // 230410 already has a Steam-owned file, so nothing is created and it stays untouched.
    try testing.expectEqual(@as(usize, 0), first.created);
    try testing.expectEqualStrings("[Desktop Entry]\nName=Steam Owned\n", blk: {
        var threaded: std.Io.Threaded = .init_single_threaded;
        break :blk readFile(alloc, threaded.io(), try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_230410.desktop", .{root}), 16384).?;
    });
    // 1234 is reserved by the readable drive library only if installed; its
    // manifest is absent, but the library is readable, so the stale entry goes.
    try testing.expectEqual(@as(usize, 1), first.removed);
    try testing.expectEqual(false, try exists(alloc, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_1234.desktop", .{root})));

    // With a Steam-owned file removed, the second pass generates the shortcut.
    const owned = try alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_230410.desktop", .{root}), 0);
    defer alloc.free(owned);
    _ = std.c.unlink(owned);
    const second = try syncPaths(root, applications);
    try testing.expectEqual(@as(usize, 1), second.created);
    try testing.expectEqual(@as(usize, 0), second.removed);
    const third = try syncPaths(root, applications);
    try testing.expectEqual(@as(usize, 0), third.created);
}

test "syncPaths keeps shortcuts reserved by an unreadable library" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const root = try tempRoot(alloc);
    defer removeTree(root);
    const applications = try std.fmt.allocPrintSentinel(alloc, "{s}/applications", .{root}, 0);
    const vdf = try std.fmt.allocPrint(alloc,
        \\"libraryfolders"
        \\{{
        \\    "0"
        \\    {{
        \\        "path"        "{s}"
        \\        "apps"
        \\        {{
        \\        }}
        \\    }}
        \\    "1"
        \\    {{
        \\        "path"        "{s}/mnt/gone/SteamLibrary"
        \\        "apps"
        \\        {{
        \\            "236390"        "91349672784"
        \\        }}
        \\    }}
        \\}}
    , .{ root, root });
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/steamapps/libraryfolders.vdf", .{root}), vdf);
    try write(alloc, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_236390.desktop", .{root}), try std.fmt.allocPrint(alloc, "[Desktop Entry]\nName=War Thunder\n{s}236390\n", .{marker}));

    const stats = try syncPaths(root, applications);
    // The second drive is unmounted: its recorded games must not be pruned.
    try testing.expectEqual(@as(usize, 0), stats.removed);
    try testing.expect(try exists(alloc, try std.fmt.allocPrint(alloc, "{s}/applications/steam_app_236390.desktop", .{root})));
}
