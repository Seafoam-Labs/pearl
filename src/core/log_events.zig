//! Catalog of every structured log event name in the tree, including the
//! subprojects, with the scopes that emit it. The test walks the sources
//! relative to the repository root, where `zig build test` runs, so an
//! undeclared name fails the pure tests instead of silently escaping
//! documentation and grep habits.
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
    .{ .name = "background-effect-owner", .scopes = &.{.platform} },
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
    .{ .name = "document-load-failed", .scopes = &.{.platform} },
    .{ .name = "document-save-failed", .scopes = &.{.platform} },
    .{ .name = "file-chooser-failed", .scopes = &.{.platform} },
    .{ .name = "gallery-error", .scopes = &.{.pearl} },
    .{ .name = "gallery-probe", .scopes = &.{.gallery} },
    .{ .name = "greeter-account", .scopes = &.{.greeter} },
    .{ .name = "greeter-active-output", .scopes = &.{.greeter} },
    .{ .name = "greeter-appearance-sync", .scopes = &.{.settings} },
    .{ .name = "greeter-contrast", .scopes = &.{.greeter} },
    .{ .name = "greeter-host-reaped", .scopes = &.{.greeter} },
    .{ .name = "greeter-host-started", .scopes = &.{.greeter} },
    .{ .name = "greeter-outputs", .scopes = &.{.greeter} },
    .{ .name = "greeter-ready", .scopes = &.{.greeter} },
    .{ .name = "greeter-reduced-motion", .scopes = &.{.greeter} },
    .{ .name = "greeter-state", .scopes = &.{.greeter} },
    .{ .name = "greeter-timeout", .scopes = &.{.greeter} },
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
    .{ .name = "operation-finished", .scopes = &.{.platform} },
    .{ .name = "output-mapped", .scopes = &.{.ui} },
    .{ .name = "pearlctl-failed", .scopes = &.{.cli} },
    .{ .name = "plugin-callback-failed", .scopes = &.{.plugins} },
    .{ .name = "plugin-failed", .scopes = &.{.plugins} },
    .{ .name = "popup-close-reason", .scopes = &.{.ui} },
    .{ .name = "popup-closed", .scopes = &.{.ui} },
    .{ .name = "popup-opened", .scopes = &.{.ui} },
    .{ .name = "power-failed", .scopes = &.{.services} },
    .{ .name = "power-intent", .scopes = &.{.desktop} },
    .{ .name = "preferences-applied", .scopes = &.{.config} },
    .{ .name = "preferences-error", .scopes = &.{.config} },
    .{ .name = "preferences-load-degraded", .scopes = &.{.cli} },
    .{ .name = "preferences-save-failed", .scopes = &.{.config} },
    .{ .name = "preview-cache-failed", .scopes = &.{.platform} },
    .{ .name = "preview-decode-failed", .scopes = &.{.platform} },
    .{ .name = "preview-failed", .scopes = &.{.platform} },
    .{ .name = "ready", .scopes = &.{.pearl} },
    .{ .name = "report-failed", .scopes = &.{.cli} },
    .{ .name = "report-status-unavailable", .scopes = &.{.cli} },
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
    .{ .name = "settings-page-probe", .scopes = &.{.ui} },
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
    .{ .name = "tray-choices", .scopes = &.{.desktop} },
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
const scope_marker = "std.log.scoped(.";

/// The scopes a file binds through `std.log.scoped(.name)` declarations. An
/// event emitted from this file must declare at least one of them, so a stale
/// scope mapping fails the catalog test instead of quietly misleading a
/// `--log-scopes` filter.
fn fileScopes(text: []const u8) std.EnumSet(logging.Scope) {
    var set = std.EnumSet(logging.Scope).empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, scope_marker)) |start| {
        pos = start + scope_marker.len;
        const end = pos + (std.mem.indexOfScalarPos(u8, text, pos, ')') orelse text.len - pos);
        if (std.meta.stringToEnum(logging.Scope, text[pos..end])) |scope| set.insert(scope);
    }
    return set;
}

fn declaresScope(event: Event, scopes: std.EnumSet(logging.Scope)) bool {
    for (event.scopes) |scope| if (scopes.contains(scope)) return true;
    return false;
}

/// Coral, Dome and Phyto ship in the same source tree and their lines reach the
/// same journal stream as the shell's, so their names are declared here too.
const roots = [_][]const u8{ "src", "subprojects/coral/src", "subprojects/dome/src", "subprojects/phyto/src" };

test "catalog matches the literal event names in the tree" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const t = std.testing;
    var seen = [_]bool{false} ** events.len;
    for (roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(t.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // This file carries the search marker as data and its own catalog.
            if (std.mem.eql(u8, entry.basename, "log_events.zig")) continue;
            const text = try dir.readFileAlloc(io, entry.path, t.allocator, .limited(16 << 20));
            defer t.allocator.free(text);
            // A file that binds no scope logs on `.default`, which the catalog
            // never declares; there is nothing to cross-check there.
            const scopes = fileScopes(text);
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, text, pos, marker)) |start| {
                pos = start + marker.len;
                const end = pos + (std.mem.indexOfNone(u8, text[pos..], name_bytes) orelse text.len - pos);
                const name = text[pos..end];
                const index = if (name.len > 0) declared(name) orelse null else null;
                if (index == null) {
                    std.debug.print("{s}/{s}: literal event name not in core/log_events.zig: '{s}'\n", .{ root, entry.path, name });
                    return error.UndeclaredEventName;
                }
                seen[index.?] = true;
                if (scopes.count() > 0 and !declaresScope(events[index.?], scopes)) {
                    std.debug.print("{s}/{s}: event '{s}' declares scopes that this file does not bind\n", .{ root, entry.path, name });
                    return error.EventScopeMismatch;
                }
            }
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
