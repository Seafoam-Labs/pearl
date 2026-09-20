//! Matugen subprocesses use argv, bounded pipes, cancellation and a caller deadline.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const io = @import("../config/io.zig");
const theme = @import("theme.zig");
const Prefs = @import("../config/preferences.zig");
pub fn run(a: std.mem.Allocator, argv: []const [:0]const u8, cancel: *gio.Cancellable) ![]const u8 {
    const pointers = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| pointers[i] = arg.ptr;
    const launcher = gio.SubprocessLauncher.new(.{ .stdout_pipe = true, .stderr_silence = true });
    defer launcher.unref();
    launcher.setChildSetup(childLimits, null, null);
    const proc = launcher.spawnv(@ptrCast(pointers.ptr), null) orelse return error.MatugenUnavailable;
    defer proc.unref();
    defer {
        proc.forceExit();
        _ = proc.wait(null, null);
    }
    const bytes = try a.alloc(u8, 131073);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = proc.getStdoutPipe().?.read(bytes[used..].ptr, @min(8192, bytes.len - used), cancel, null);
        if (n < 0) return error.GeneratorCancelled;
        if (n == 0) break;
        used += @intCast(n);
    }
    if (used > 131072) return error.GeneratorOutputTooLarge;
    if (proc.waitCheck(cancel, null) == 0) return error.GeneratorFailed;
    return bytes[0..used];
}
fn childLimits(_: ?*anyopaque) callconv(.c) void {
    // Async-signal-safe syscalls only: this runs after fork in a multithreaded app.
    const limit: std.os.linux.rlimit = .{ .cur = 131072, .max = 131072 };
    if (std.os.linux.setrlimit(.FSIZE, &limit) != 0) std.os.linux.exit(126);
    const memory: std.os.linux.rlimit = .{ .cur = 512 * 1024 * 1024, .max = 512 * 1024 * 1024 };
    if (std.os.linux.setrlimit(.AS, &memory) != 0) std.os.linux.exit(126);
    const cpu: std.os.linux.rlimit = .{ .cur = 10, .max = 10 };
    if (std.os.linux.setrlimit(.CPU, &cpu) != 0) std.os.linux.exit(126);
}
pub fn palette(a: std.mem.Allocator, p: Prefs.Preferences, image: ?[]const u8, cache_dir: [:0]const u8, cancel: *gio.Cancellable, hit: *bool) !theme.Palette {
    return (try full(a, p, image, cache_dir, cancel, hit)).palette;
}
pub const Full = struct { palette: theme.Palette, json: []const u8, version: []const u8 };
/// One probe per appearance job, shared by extraction and all profile renders.
pub const Context = struct {
    version: ?[]const u8 = null,
    failure: ?anyerror = null,
    pub fn getVersion(self: *Context, a: std.mem.Allocator, cancel: *gio.Cancellable) ![]const u8 {
        if (self.failure) |err| return err;
        if (self.version) |value| return value;
        const value = run(a, &.{ "matugen", "--version" }, cancel) catch |err| {
            self.failure = err;
            return err;
        };
        if (value.len > 256 or !std.mem.startsWith(u8, value, "matugen 4.")) {
            self.failure = error.UnsupportedMatugenVersion;
            return error.UnsupportedMatugenVersion;
        }
        self.version = value;
        return value;
    }
};
pub fn full(a: std.mem.Allocator, p: Prefs.Preferences, image: ?[]const u8, cache_dir: [:0]const u8, cancel: *gio.Cancellable, hit: *bool) !Full {
    var context: Context = .{};
    return fullWithContext(a, p, image, cache_dir, cancel, hit, &context);
}
pub fn fullWithContext(a: std.mem.Allocator, p: Prefs.Preferences, image: ?[]const u8, cache_dir: [:0]const u8, cancel: *gio.Cancellable, hit: *bool, context: *Context) !Full {
    const version = try context.getVersion(a, cancel);
    const identity = try std.fmt.allocPrint(a, "pearl-palette-v1\n{s}\n{s}\n{s}\n{s}", .{ version, @tagName(p.theme.variant), @tagName(p.theme.source), if (p.theme.source == .seed) p.theme.seed else image orelse return error.ImageRequired });
    const key = io.digest(identity);
    const slot = key[0] % 8;
    const cache = try std.fmt.allocPrintSentinel(a, "{s}/palette-{d}.json", .{ cache_dir, slot }, 0);
    if (io.read(a, cache, 131072, cancel)) |cached| {
        if (cached.bytes.len > 65 and std.mem.eql(u8, cached.bytes[0..64], &key)) {
            if (theme.matugenPalette(a, cached.bytes[65..], @tagName(p.theme.variant))) |value| {
                hit.* = true;
                return .{ .palette = value, .json = cached.bytes[65..], .version = version };
            } else |_| {}
        }
    } else |_| {}
    const config = try std.fmt.allocPrintSentinel(a, "{s}/matugen.toml", .{cache_dir}, 0);
    try io.atomic(config, "[config]\n[templates]\n", false);
    const input = try std.fmt.allocPrintSentinel(a, "{s}/source.png", .{cache_dir}, 0);
    // Snapshot validated bytes so replacing the source cannot race extraction.
    if (p.theme.source == .wallpaper) try io.atomic(input, image.?, false);
    defer {
        if (p.theme.source == .wallpaper) _ = std.c.unlink(input);
    }
    const seed = try a.dupeZ(u8, p.theme.seed);
    const args: []const [:0]const u8 = if (p.theme.source == .seed)
        &.{ "matugen", "--config", config, "--dry-run", "--json", "hex", "--source-color-index", "0", "--mode", @tagName(p.theme.variant), "color", "hex", seed }
    else
        &.{ "matugen", "--config", config, "--dry-run", "--json", "hex", "--source-color-index", "0", "--mode", @tagName(p.theme.variant), "image", input };
    const json = try run(a, args, cancel);
    const value = try theme.matugenPalette(a, json, @tagName(p.theme.variant));
    if (cancel.isCancelled() != 0) return error.Cancelled;
    const encoded = try std.fmt.allocPrint(a, "{s}\n{s}", .{ key, json });
    io.atomic(cache, encoded, false) catch {}; // Cache failure cannot discard a valid palette.
    return .{ .palette = value, .json = json, .version = version };
}
