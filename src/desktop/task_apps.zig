//! GIO adapter shared by the dock and global task snapshot.
const std = @import("std");
const object = @import("gobject2");
const unix = @import("giounix2");
const Apps = @import("apps.zig");
const tasks = @import("task_model.zig");
pub const Store = struct {
    snapshot: tasks.Snapshot = tasks.Snapshot.init(std.heap.c_allocator),
    catalog_arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),
    generation: ?u64 = null,
    apps: []const tasks.Application = &.{},
    pub fn match(self: *const Store, win: @import("../aqueous/entities.zig").Window, choices: []const @import("app_identity.zig").Association, pins: []const []const u8) ?[]const u8 {
        const app = tasks.resolve(self.apps, win, choices, pins) orelse return null;
        return app.id;
    }
    pub fn deinit(self: *Store) void {
        self.snapshot.deinit();
        self.catalog_arena.deinit();
    }
    pub fn update(self: *Store, model: *const @import("../aqueous/reducer.zig").Model, index: *const Apps.Index, choices: []const @import("app_identity.zig").Association, pins: []const []const u8) !void {
        if (self.generation == null or self.generation.? != index.generation) {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            var apps: std.ArrayList(tasks.Application) = .empty;
            if (index.catalog) |catalog| for (catalog.entries.items) |entry| {
                if (entry.action != null) continue;
                const desktop = object.ext.cast(unix.DesktopAppInfo, entry.info) orelse continue;
                try apps.append(a, .{ .id = try a.dupe(u8, entry.id), .name = try a.dupe(u8, entry.name), .user_local = if (desktop.getFilename()) |path| try @import("app_identity.zig").userDesktopFile(a, std.mem.span(path), std.mem.span(@import("glib2").getUserDataDir())) else false, .wmclass = if (desktop.getStartupWmClass()) |v| try a.dupe(u8, std.mem.span(v)) else null });
            };
            const owned = try apps.toOwnedSlice(a);
            self.catalog_arena.deinit();
            self.catalog_arena = arena;
            self.apps = owned;
            self.generation = index.generation;
        }
        try self.snapshot.updateWithLaunchers(model, self.apps, index.generation, choices, pins);
    }
};
