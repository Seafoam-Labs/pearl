//! Explicit desktop setup. Only the distribution package manager installs code.
//! Interactive transactions own their terminal and are never killed by Settings.
const std = @import("std");
const gio = @import("gio2");
const config = @import("config.zig");
const probe = @import("runtime_probe.zig");
pub const Manager = enum { shelly, pacman };

pub fn manager(os_release: []const u8) !Manager {
    var id: []const u8 = "";
    var like: []const u8 = "";
    var lines = std.mem.splitScalar(u8, os_release, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..equals];
        const value = std.mem.trim(u8, line[equals + 1 ..], "\"'");
        if (std.mem.eql(u8, key, "ID")) id = value;
        if (std.mem.eql(u8, key, "ID_LIKE")) like = value;
    }
    if (std.mem.eql(u8, id, "devario") or contains(like, "devario")) return .shelly;
    if (std.mem.eql(u8, id, "arch") or contains(like, "arch")) return .pacman;
    return error.RuntimeInstallationUnsupportedDistribution;
}
fn contains(list: []const u8, value: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, list, " \t");
    while (words.next()) |word| if (std.mem.eql(u8, word, value)) return true;
    return false;
}
pub fn packages(compute: config.Compute) []const [:0]const u8 {
    if (compute.mode == .cpu) return &.{"llama-cpp"};
    return if (compute.backend == .cuda) &.{ "llama-cpp", "ggml-cuda" } else &.{ "llama-cpp", "ggml-vulkan" };
}
pub fn command(a: std.mem.Allocator, selected: Manager, compute: config.Compute) ![]const [:0]const u8 {
    var args: std.ArrayList([:0]const u8) = .empty;
    try args.appendSlice(a, switch (selected) {
        .shelly => &.{ "/usr/bin/shelly", "install", "standard", "--needed" },
        .pacman => &.{ "/usr/bin/sudo", "/usr/bin/pacman", "-S", "--needed" },
    });
    try args.appendSlice(a, packages(compute));
    return args.toOwnedSlice(a);
}
pub const Result = struct { runtime: config.RuntimeConfig, info: probe.Probe, installed: bool = false };
fn suitable(info: probe.Probe, compute: config.Compute) bool {
    if (compute.mode == .cpu) return true;
    if (!info.has("--device") or !info.has("--split-mode")) return false;
    for (info.devices) |device| {
        if (compute.backend == .auto or compute.backend == device.backend) return true;
    }
    return false;
}
// The environment boundary also lets tests exercise setup without touching the
// host package database, authenticating, or launching an actual terminal.
pub fn ensureWith(a: std.mem.Allocator, cfg: config.Config, cancel: *gio.Cancellable, environment: anytype) !Result {
    const candidates = [_]config.RuntimeConfig{ cfg.runtime, .{ .source = .system }, .{ .source = .packaged } };
    for (candidates, 0..) |candidate, i| {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (i > 0 and candidate.source == cfg.runtime.source) continue;
        const info = environment.inspect(a, candidate, cancel) catch |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            continue;
        };
        if (suitable(info, cfg.compute)) return .{ .runtime = candidate, .info = info };
    }
    if (cancel.isCancelled() != 0) return error.Cancelled;
    try environment.install(a, cfg.compute, cancel);
    if (cancel.isCancelled() != 0) return error.Cancelled;
    const runtime: config.RuntimeConfig = .{ .source = .system };
    // Probe again even if the package manager reported success. A repository
    // release may lack required options; never claim it is compatible blindly.
    return .{ .runtime = runtime, .info = try environment.inspect(a, runtime, cancel), .installed = true };
}
pub fn ensure(a: std.mem.Allocator, cfg: config.Config, cancel: *gio.Cancellable) !Result {
    return ensureWith(a, cfg, cancel, Desktop{});
}
const Desktop = struct {
    fn inspect(_: Desktop, a: std.mem.Allocator, runtime: config.RuntimeConfig, cancel: *gio.Cancellable) !probe.Probe {
        return probe.inspect(a, runtime, true, cancel);
    }
    fn install(_: Desktop, a: std.mem.Allocator, compute: config.Compute, cancel: *gio.Cancellable) !void {
        var buffer: [16384]u8 = undefined;
        const release = @import("memory.zig").read("/etc/os-release", &buffer) catch
            @import("memory.zig").read("/usr/lib/os-release", &buffer) catch return error.RuntimeInstallationUnsupportedDistribution;
        const selected = try manager(release);
        const cmd = try command(a, selected, compute);
        for (cmd[0..if (selected == .pacman) @as(usize, 2) else 1]) |exe| {
            if (std.c.access(exe, std.c.X_OK) != 0) return error.RuntimePackageManagerUnavailable;
        }
        const terminals = [_][]const [:0]const u8{
            &.{ "/usr/bin/foot", "-e" },
            &.{ "/usr/bin/kitty", "--" },
            &.{ "/usr/bin/alacritty", "-e" },
            &.{ "/usr/bin/konsole", "--nofork", "-e" },
            &.{ "/usr/bin/xterm", "-e" },
        };
        for (terminals) |terminal| {
            if (std.c.access(terminal[0], std.c.X_OK) != 0) continue;
            var args: std.ArrayList(?[*:0]const u8) = .empty;
            for (terminal) |arg| try args.append(a, arg.ptr);
            for (cmd) |arg| try args.append(a, arg.ptr);
            try args.append(a, null);
            if (cancel.isCancelled() != 0) return error.Cancelled;
            const child = gio.Subprocess.newv(@ptrCast(args.items.ptr), .{}, null) orelse continue;
            defer child.unref();
            // No cancellation, timeout, parent-death signal, or forceExit:
            // stopping a package commit can leave a damaged system database.
            if (child.wait(null, null) == 0 or child.getSuccessful() == 0) return error.RuntimePackageInstallationFailed;
            return;
        }
        return error.RuntimeInstallTerminalUnavailable;
    }
};

test "distribution identity gives Devario precedence and never evaluates shell text" {
    try std.testing.expectEqual(Manager.shelly, try manager("ID=devario\nID_LIKE=arch\n"));
    try std.testing.expectEqual(Manager.shelly, try manager("ID=variant\nID_LIKE=\"devario arch\"\n"));
    try std.testing.expectEqual(Manager.pacman, try manager("ID='arch'\n"));
    try std.testing.expectEqual(Manager.pacman, try manager("ID=cachyos\nID_LIKE=arch\n"));
    try std.testing.expectError(error.RuntimeInstallationUnsupportedDistribution, manager("ID=ubuntu\nID_LIKE=debian"));
    try std.testing.expectError(error.RuntimeInstallationUnsupportedDistribution, manager("ID=$(touch /tmp/not-executed)\nID_LIKE=archfake"));
}
test "install commands retain authentication and confirmation and request selected backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shelly = try command(a, .shelly, .{});
    try std.testing.expectEqualStrings("/usr/bin/shelly install standard --needed llama-cpp", try std.mem.join(a, " ", shelly));
    const pacman = try command(a, .pacman, .{ .mode = .gpu, .backend = .cuda });
    try std.testing.expectEqualStrings("/usr/bin/sudo /usr/bin/pacman -S --needed llama-cpp ggml-cuda", try std.mem.join(a, " ", pacman));
    try std.testing.expectEqualStrings("ggml-vulkan", packages(.{ .mode = .auto })[1]);
    try std.testing.expectEqual(@as(usize, 1), packages(.{ .mode = .cpu, .backend = .cuda }).len);
}
test "setup reuses compatible runtimes, installs once when absent, and rejects failed verification" {
    const Fake = struct {
        present: bool = false,
        installs: usize = 0,
        inspections: usize = 0,
        broken: bool = false,
        fail_install: bool = false,
        cancel_install: bool = false,
        only_system: bool = false,
        gpu: bool = false,
        fn inspect(self: *@This(), _: std.mem.Allocator, runtime: config.RuntimeConfig, _: *gio.Cancellable) !probe.Probe {
            self.inspections += 1;
            if (!self.present or (self.only_system and runtime.source != .system)) return error.AssistantRuntimeNotInstalled;
            if (self.broken) return error.RuntimeCapabilityMissing;
            return .{ .executable = "/usr/bin/llama-server", .fingerprint = "test", .version = "unrestricted release", .help = "--device --split-mode", .devices = if (self.gpu) &.{.{ .id = "fixture", .name = "CUDA0", .description = "Fixture", .backend = .cuda, .total_mib = 8192, .free_mib = 8192 }} else &.{}, .child_environment = &.{} };
        }
        fn install(self: *@This(), _: std.mem.Allocator, _: config.Compute, cancel: *gio.Cancellable) !void {
            self.installs += 1;
            if (self.fail_install) return error.RuntimePackageInstallationFailed;
            self.present = true;
            if (self.cancel_install) cancel.cancel();
        }
    };
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    var existing: Fake = .{ .present = true };
    const reused = try ensureWith(std.testing.allocator, .{}, cancel, &existing);
    try std.testing.expect(!reused.installed and existing.installs == 0);
    var missing: Fake = .{};
    const installed = try ensureWith(std.testing.allocator, .{ .runtime = .{ .source = .packaged } }, cancel, &missing);
    try std.testing.expect(installed.installed and missing.installs == 1);
    try std.testing.expectEqual(config.RuntimeSource.system, installed.runtime.source);
    var fallback: Fake = .{ .present = true, .only_system = true };
    const adopted = try ensureWith(std.testing.allocator, .{ .runtime = .{ .source = .custom, .executable = "/missing" } }, cancel, &fallback);
    try std.testing.expectEqual(config.RuntimeSource.system, adopted.runtime.source);
    try std.testing.expectEqual(@as(usize, 0), fallback.installs);
    var cuda: Fake = .{ .present = true, .gpu = true };
    _ = try ensureWith(std.testing.allocator, .{ .compute = .{ .mode = .auto, .backend = .cuda } }, cancel, &cuda);
    try std.testing.expectEqual(@as(usize, 0), cuda.installs);
    _ = try ensureWith(std.testing.allocator, .{ .compute = .{ .mode = .auto, .backend = .vulkan } }, cancel, &cuda);
    try std.testing.expectEqual(@as(usize, 1), cuda.installs);
    var broken: Fake = .{ .broken = true };
    try std.testing.expectError(error.RuntimeCapabilityMissing, ensureWith(std.testing.allocator, .{}, cancel, &broken));
    try std.testing.expectEqual(@as(usize, 1), broken.installs);
    var failed: Fake = .{ .fail_install = true };
    try std.testing.expectError(error.RuntimePackageInstallationFailed, ensureWith(std.testing.allocator, .{}, cancel, &failed));
    var closed_during_install: Fake = .{ .cancel_install = true };
    try std.testing.expectError(error.Cancelled, ensureWith(std.testing.allocator, .{}, cancel, &closed_during_install));
    try std.testing.expect(closed_during_install.present and closed_during_install.installs == 1);
    var cancelled: Fake = .{};
    try std.testing.expectError(error.Cancelled, ensureWith(std.testing.allocator, .{}, cancel, &cancelled));
    try std.testing.expectEqual(@as(usize, 0), cancelled.installs);
}
