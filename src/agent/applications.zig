//! Shell-side policy for the assistant's narrow app-open channel (Phase 6).
//! Discovery stays with the child (Gio AppInfo); the shell only gates and
//! re-validates the single resolved desktop entry it may launch. No command,
//! argument, action, file or URI surface exists here.
const std = @import("std");
const gio = @import("gio2");
const giounix = @import("giounix2");
const glib = @import("glib2");

/// Accepts config.Config (host) or any structurally compatible value, mirroring
/// files.Tools.init's boundary: the host config gains `local` in a separate
/// change, and until then this fails closed. App opening needs the assistant
/// enabled plus the explicit local-tools opt-in and its open_apps capability.
pub fn openAppsEnabled(cfg: anytype) bool {
    if (!cfg.enabled) return false;
    if (comptime !@hasField(@TypeOf(cfg), "local")) return false;
    const local = cfg.local;
    if (comptime @hasField(@TypeOf(local), "enabled")) {
        if (!local.enabled) return false;
    }
    if (comptime @hasField(@TypeOf(local), "open_apps")) return local.open_apps;
    return false;
}

/// Only visible, non-terminal entries may be opened, and only through their
/// default launch. Entries running in a terminal would execute a command line
/// the user never reviewed; hidden entries are not user-facing applications.
pub fn checkLaunchable(desktop: *giounix.DesktopAppInfo) !void {
    if (desktop.as(gio.AppInfo).shouldShow() == 0) return error.ApplicationHidden;
    if (desktop.getBoolean("Terminal") != 0) return error.TerminalNotSupported;
}

test "open-apps gate fails closed without explicit local opt-in" {
    const Local = struct { enabled: bool = false, open_apps: bool = false };
    const Fake = struct { enabled: bool = false, local: Local = .{} };
    try std.testing.expect(!openAppsEnabled(@import("config.zig").Config{}));
    try std.testing.expect(!openAppsEnabled(Fake{}));
    try std.testing.expect(!openAppsEnabled(Fake{ .enabled = true }));
    try std.testing.expect(!openAppsEnabled(Fake{ .enabled = true, .local = .{ .enabled = true } }));
    try std.testing.expect(!openAppsEnabled(Fake{ .enabled = true, .local = .{ .open_apps = true } }));
    try std.testing.expect(!openAppsEnabled(Fake{ .enabled = false, .local = .{ .enabled = true, .open_apps = true } }));
    try std.testing.expect(openAppsEnabled(Fake{ .enabled = true, .local = .{ .enabled = true, .open_apps = true } }));
    // A config without any local section grants nothing.
    try std.testing.expect(!openAppsEnabled(struct { enabled: bool }{ .enabled = true }));
}

fn policyEntry(terminal: bool, no_display: bool) !*giounix.DesktopAppInfo {
    const key = glib.KeyFile.new();
    defer key.unref();
    key.setString("Desktop Entry", "Type", "Application");
    key.setString("Desktop Entry", "Name", "Policy Probe");
    key.setString("Desktop Entry", "Exec", "/bin/true");
    if (terminal) key.setBoolean("Desktop Entry", "Terminal", 1);
    if (no_display) key.setBoolean("Desktop Entry", "NoDisplay", 1);
    return giounix.DesktopAppInfo.newFromKeyfile(key) orelse error.TestFixture;
}

test "only visible non-terminal desktop entries are launchable" {
    const visible = try policyEntry(false, false);
    defer visible.unref();
    try checkLaunchable(visible);
    const terminal = try policyEntry(true, false);
    defer terminal.unref();
    try std.testing.expectError(error.TerminalNotSupported, checkLaunchable(terminal));
    const hidden = try policyEntry(false, true);
    defer hidden.unref();
    try std.testing.expectError(error.ApplicationHidden, checkLaunchable(hidden));
}
