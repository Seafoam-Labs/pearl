//! Catalog of every structured log event name in the tree with the scopes
//! that emit it. The test walks the sources relative to the repository root,
//! where `zig build test` runs, so an undeclared name fails the pure tests
//! instead of silently escaping documentation and grep habits.
const std = @import("std");
const logging = @import("logging.zig");

pub const Event = struct {
    name: []const u8,
    scopes: []const logging.Scope,
};

pub const events: []const Event = &.{
    .{ .name = "activity-auth-presented", .scopes = &.{.services} },
    .{ .name = "app-index-ready", .scopes = &.{.desktop} },
    .{ .name = "appearance", .scopes = &.{.gallery} },
    .{ .name = "application-launch", .scopes = &.{.desktop} },
    .{ .name = "aqueous-availability", .scopes = &.{.pearl} },
    .{ .name = "aqueous-disconnected", .scopes = &.{.pearl} },
    .{ .name = "bar-autohide-unavailable", .scopes = &.{.ui} },
    .{ .name = "bluetooth-failed", .scopes = &.{.services} },
    .{ .name = "blur-capability", .scopes = &.{.platform} },
    .{ .name = "capture-failed", .scopes = &.{.services} },
    .{ .name = "cleanup", .scopes = &.{.pearl} },
    .{ .name = "clipboard-failed", .scopes = &.{.services} },
    .{ .name = "connectivity-focus", .scopes = &.{.desktop} },
    .{ .name = "control-ready", .scopes = &.{.pearl} },
    .{ .name = "css-error", .scopes = &.{.pearl} },
    .{ .name = "desktop-action", .scopes = &.{.ui} },
    .{ .name = "desktop-action-dropped", .scopes = &.{.ui} },
    .{ .name = "dock-action", .scopes = &.{.desktop} },
    .{ .name = "gallery-error", .scopes = &.{.pearl} },
    .{ .name = "gallery-probe", .scopes = &.{.gallery} },
    .{ .name = "greeter-active-output", .scopes = &.{.greeter} },
    .{ .name = "greeter-appearance-sync", .scopes = &.{.settings} },
    .{ .name = "greeter-contrast", .scopes = &.{.greeter} },
    .{ .name = "greeter-host-reaped", .scopes = &.{.greeter} },
    .{ .name = "greeter-host-started", .scopes = &.{.greeter} },
    .{ .name = "greeter-outputs", .scopes = &.{.greeter} },
    .{ .name = "greeter-ready", .scopes = &.{.greeter} },
    .{ .name = "greeter-reduced-motion", .scopes = &.{.greeter} },
    .{ .name = "greeter-state", .scopes = &.{.greeter} },
    .{ .name = "idle-audit", .scopes = &.{.gallery} },
    .{ .name = "ipc-connect-failed", .scopes = &.{.aqueous} },
    .{ .name = "ipc-disconnected", .scopes = &.{.aqueous} },
    .{ .name = "ipc-request", .scopes = &.{.aqueous} },
    .{ .name = "ipc-request-failed", .scopes = &.{.aqueous} },
    .{ .name = "ipc-response", .scopes = &.{.aqueous} },
    .{ .name = "ipc-sequence-gap", .scopes = &.{.aqueous} },
    .{ .name = "language", .scopes = &.{.gallery} },
    .{ .name = "launcher-error", .scopes = &.{.desktop} },
    .{ .name = "launcher-painted", .scopes = &.{.desktop} },
    .{ .name = "launcher-results", .scopes = &.{.desktop} },
    .{ .name = "lifecycle-failed", .scopes = &.{.services} },
    .{ .name = "lock-acquired", .scopes = &.{.lock} },
    .{ .name = "lock-caps", .scopes = &.{.lock} },
    .{ .name = "lock-clock", .scopes = &.{.lock} },
    .{ .name = "lock-monitor", .scopes = &.{.lock} },
    .{ .name = "lock-output-limit", .scopes = &.{.lock} },
    .{ .name = "lock-released", .scopes = &.{.lock} },
    .{ .name = "lock-ui", .scopes = &.{.lock} },
    .{ .name = "logind-session-unavailable", .scopes = &.{.services} },
    .{ .name = "logout-result", .scopes = &.{.pearl} },
    .{ .name = "mpris-failed", .scopes = &.{.services} },
    .{ .name = "network-failed", .scopes = &.{.services} },
    .{ .name = "night-light-failed", .scopes = &.{.services} },
    .{ .name = "notification-filter-config", .scopes = &.{.ui} },
    .{ .name = "output-mapped", .scopes = &.{.ui} },
    .{ .name = "pearlctl-failed", .scopes = &.{.cli} },
    .{ .name = "plugin-callback-failed", .scopes = &.{.plugins} },
    .{ .name = "plugin-failed", .scopes = &.{.plugins} },
    .{ .name = "popup-closed", .scopes = &.{.ui} },
    .{ .name = "popup-opened", .scopes = &.{.ui} },
    .{ .name = "power-failed", .scopes = &.{.services} },
    .{ .name = "power-intent", .scopes = &.{.desktop} },
    .{ .name = "preferences-applied", .scopes = &.{.config} },
    .{ .name = "preferences-error", .scopes = &.{.config} },
    .{ .name = "ready", .scopes = &.{.pearl} },
    .{ .name = "report-failed", .scopes = &.{.cli} },
    .{ .name = "report-written", .scopes = &.{.cli} },
    .{ .name = "resource-error", .scopes = &.{.pearl} },
    .{ .name = "sample-activated", .scopes = &.{.gallery} },
    .{ .name = "sample-workspace", .scopes = &.{.gallery} },
    .{ .name = "search", .scopes = &.{.gallery} },
    .{ .name = "services-focus", .scopes = &.{.desktop} },
    .{ .name = "session-error", .scopes = &.{.pearl} },
    .{ .name = "session-focus", .scopes = &.{.desktop} },
    .{ .name = "settings-activation", .scopes = &.{.settings} },
    .{ .name = "settings-aqueous-action", .scopes = &.{.settings} },
    .{ .name = "settings-backend-ready", .scopes = &.{.pearl} },
    .{ .name = "settings-connection-unavailable", .scopes = &.{.settings} },
    .{ .name = "settings-focus", .scopes = &.{.desktop} },
    .{ .name = "settings-forward", .scopes = &.{.settings} },
    .{ .name = "settings-instance-error", .scopes = &.{.settings} },
    .{ .name = "settings-instance-ready", .scopes = &.{.settings} },
    .{ .name = "settings-launch", .scopes = &.{.settings} },
    .{ .name = "settings-page", .scopes = &.{ .desktop, .settings } },
    .{ .name = "settings-page-failed", .scopes = &.{.desktop} },
    .{ .name = "settings-show-failed", .scopes = &.{.settings} },
    .{ .name = "settings-stale-response", .scopes = &.{.settings} },
    .{ .name = "settings-style-error", .scopes = &.{.settings} },
    .{ .name = "settings-window-created", .scopes = &.{.settings} },
    .{ .name = "shortcut-record-ended", .scopes = &.{.desktop} },
    .{ .name = "startup-failed", .scopes = &.{.pearl} },
    .{ .name = "stopped", .scopes = &.{.pearl} },
    .{ .name = "stopping", .scopes = &.{.pearl} },
    .{ .name = "surface-error", .scopes = &.{.ui} },
    .{ .name = "theme-command-failed", .scopes = &.{.theme} },
    .{ .name = "theme-index-offline", .scopes = &.{.theme} },
    .{ .name = "tile-changed", .scopes = &.{.gallery} },
    .{ .name = "tray-failed", .scopes = &.{.services} },
    .{ .name = "wallpaper-applications-applied", .scopes = &.{.config} },
    .{ .name = "wallpaper-changed", .scopes = &.{.config} },
    .{ .name = "work-finished", .scopes = &.{.pearl} },
    .{ .name = "work-started", .scopes = &.{.pearl} },
};

fn declared(name: []const u8) ?usize {
    for (events, 0..) |event, index| {
        if (std.mem.eql(u8, event.name, name)) return index;
    }
    return null;
}

const name_bytes = "abcdefghijklmnopqrstuvwxyz0123456789-";
const marker = "event" ++ "=";

test "catalog matches the literal event names in the tree" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const t = std.testing;
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(t.allocator);
    defer walker.deinit();
    var seen = [_]bool{false} ** events.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        // This file carries the search marker as data and its own catalog.
        if (std.mem.eql(u8, entry.basename, "log_events.zig")) continue;
        const text = try src.readFileAlloc(io, entry.path, t.allocator, .limited(16 << 20));
        defer t.allocator.free(text);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, marker)) |start| {
            pos = start + marker.len;
            const end = pos + (std.mem.indexOfNone(u8, text[pos..], name_bytes) orelse text.len - pos);
            const name = text[pos..end];
            const index = if (name.len > 0) declared(name) orelse null else null;
            if (index == null) {
                std.debug.print("{s}: literal event name not in core/log_events.zig: '{s}'\n", .{ entry.path, name });
                return error.UndeclaredEventName;
            }
            seen[index.?] = true;
        }
    }
    for (events, 0..) |event, index| {
        if (!seen[index]) {
            std.debug.print("declared event name no longer emitted anywhere: '{s}'\n", .{event.name});
            return error.StaleEventName;
        }
    }
}

test "catalog names are unique, sorted and well-formed" {
    var previous: ?[]const u8 = null;
    for (events) |event| {
        try std.testing.expect(event.name.len > 0 and event.scopes.len > 0);
        try std.testing.expect(std.mem.indexOfNone(u8, event.name, name_bytes) == null);
        if (previous) |old| try std.testing.expect(std.mem.order(u8, old, event.name) == .lt);
        previous = event.name;
    }
}
