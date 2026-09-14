//! Trusted system session catalog. Arena owned and replaceable between auth attempts.
const std = @import("std");
const glib = @import("glib2");
const cfg = @import("config.zig");
const desktop = @import("desktop_entry.zig");
const trusted = @import("trusted.zig");
pub const Entry = struct {
    id: []const u8,
    path: []const u8,
    name: []const u8,
    kind: []const u8,
    desktops: []const u8,
    argv: []const []const u8,
    fingerprint: [64]u8,
    available: bool = true,
    reason: []const u8 = "",
};
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    skipped: usize = 0,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }
    pub fn find(self: *const Catalog, id: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn selected(self: *const Catalog, config: cfg.Config, remembered: ?[]const u8) ?*const Entry {
        if (config.force_session) |id| {
            const e = self.find(id) orelse return null;
            return if (e.available) e else null;
        }
        for ([_]?[]const u8{ remembered, config.default_session }) |id| if (id) |v| if (self.find(v)) |e| if (e.available) return e;
        for (self.entries.items) |*e| if (e.available) return e;
        return null;
    }
};
fn includes(list: []const []const u8, id: []const u8) bool {
    for (list) |v| if (std.mem.eql(u8, v, id)) return true;
    return false;
}
pub fn executable(a: std.mem.Allocator, command: []const u8) !?[]const u8 {
    if (command.len == 0) return null;
    if (command[0] == '/') {
        const z = try a.dupeZ(u8, command);
        if ((glib.fileTest(z, .{ .is_executable = true }) == 0 or glib.fileTest(z, .{ .is_regular = true }) == 0)) return null;
        return command;
    }
    if (std.mem.indexOfScalar(u8, command, '/') != null) return null;
    // Never trust the greeter's inherited PATH.
    for ([_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" }) |dir| {
        const z = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, command }, 0);
        if (glib.fileTest(z, .{ .is_executable = true }) != 0 and glib.fileTest(z, .{ .is_regular = true }) != 0) return z;
    }
    return null;
}
pub fn load(allocator: std.mem.Allocator, config: cfg.Config, locale: []const u8) !Catalog {
    var out: Catalog = .{ .arena = .init(allocator) };
    errdefer out.deinit();
    const a = out.arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var scanned: usize = 0;
    var count: usize = 0;
    for (config.roots) |root| {
        const rootz = try a.dupeZ(u8, root.path);
        // A missing optional system directory is normal; any present root must be trusted.
        if (glib.fileTest(rootz, .{ .exists = true }) == 0) continue;
        const fd = try trusted.open(root.path, true);
        defer _ = std.c.close(fd);
        const dir = glib.Dir.open(rootz, 0, null) orelse return error.Directory;
        defer dir.close();
        while (true) {
            const z = dir.readName();
            if (@intFromPtr(z) == 0) break;
            const filename = std.mem.span(z);
            if (!std.mem.endsWith(u8, filename, ".desktop")) continue;
            count += 1;
            if (count > 256) return error.CatalogLimit;
            const id = try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(root.type), filename });
            if (!cfg.validId(id)) {
                out.skipped += 1;
                continue;
            }
            const slot = try seen.getOrPut(a, id);
            if (slot.found_existing) continue;
            if (includes(config.deny, id) or (config.allow.len != 0 and !includes(config.allow, id))) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root.path, filename });
            const bytes = trusted.read(a, path, 65536) catch {
                out.skipped += 1;
                continue;
            };
            scanned += bytes.len;
            if (scanned > 8 * 1024 * 1024) return error.CatalogLimit;
            const meta = desktop.parse(a, bytes, locale) catch {
                out.skipped += 1;
                continue;
            };
            if (meta.hidden or meta.no_display) continue;
            const args = desktop.arguments(a, meta, path) catch {
                out.skipped += 1;
                continue;
            };
            var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
            hash.update(path);
            hash.update(bytes);
            // Include adapter/policy config so a policy change invalidates a frozen selection.
            const policy = try std.json.Stringify.valueAlloc(a, config, .{});
            hash.update(policy);
            const fingerprint = std.fmt.bytesToHex(hash.finalResult(), .lower);
            var e: Entry = .{ .id = id, .path = path, .name = meta.name, .kind = @tagName(root.type), .desktops = meta.desktops, .argv = args, .fingerprint = fingerprint };
            if (try executable(a, args[0])) |exe| {
                const owned = try a.dupe([]const u8, args);
                owned[0] = exe;
                e.argv = owned;
            } else {
                e.available = false;
                e.reason = "Session executable is missing";
            }
            if (meta.try_exec.len != 0 and try executable(a, meta.try_exec) == null) {
                e.available = false;
                e.reason = "TryExec dependency is missing";
            }
            if (root.type == .x11 and (!config.x11 or try executable(a, "/usr/bin/startx") == null or try executable(a, "/usr/lib/pearl/pearl-greeter-x11") == null)) {
                e.available = false;
                e.reason = "Verified X11 launcher is unavailable";
            }
            if (std.mem.eql(u8, std.fs.path.basename(args[0]), "uwsm") and !config.allow_uwsm) {
                e.available = false;
                e.reason = "UWSM profile requires administrator validation";
            }
            if (config.force_session) |forced| if (!std.mem.eql(u8, id, forced)) {
                e.available = false;
                e.reason = "Administrator has selected a fixed desktop";
            };
            try out.entries.append(a, e);
        }
    }
    std.mem.sort(Entry, out.entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.less);
    return out;
}
