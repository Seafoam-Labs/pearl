//! One owned, atomic desktop model. All returned pointers/slices are borrowed
//! until the next successful apply, clear or deinit; failed applies preserve them.
const std = @import("std");
const e = @import("entities.zig");
const codec = @import("codec.zig");
const Allocator = std.mem.Allocator;
const Context = struct {
    pub fn hash(_: Context, key: e.Key) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(key.kind));
        h.update(key.id);
        return h.final();
    }
    pub fn eql(_: Context, a: e.Key, b: e.Key) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.id, b.id);
    }
};
const Map = std.HashMapUnmanaged(e.Key, e.Entity, Context, 80);
const Keys = std.HashMapUnmanaged(e.Key, void, Context, 80);

pub const Model = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    limit: usize,
    ready: bool = false,
    session: []const u8 = "",
    sequence: []const u8 = "",
    entities: Map = .empty,
    accounted_bytes: usize = 0,

    pub fn init(allocator: Allocator, limit: usize) !Model {
        if (limit == 0 or limit > (codec.Limits{}).state_bytes) return error.InvalidLimits;
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .limit = limit };
    }
    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn clear(self: *Model) void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.entities = .empty;
        self.session = "";
        self.sequence = "";
        self.accounted_bytes = 0;
        self.ready = false;
    }
    /// A broken transport must hide stale state and require a new snapshot.
    pub fn invalidate(self: *Model) void {
        self.ready = false;
    }

    pub fn apply(self: *Model, batch: codec.Batch) !void {
        try e.sessionToken(batch.session);
        try e.decimal(batch.sequence);
        switch (batch.type) {
            .snapshot => if (batch.base_sequence != null or batch.removed.len != 0) return error.InvalidBatch,
            .delta => {
                if (!self.ready) return error.SnapshotRequired;
                if (!std.mem.eql(u8, batch.session, self.session)) return error.SessionChanged;
                const base = batch.base_sequence orelse return error.InvalidBatch;
                if (!std.mem.eql(u8, base, self.sequence)) return error.SequenceGap;
                // Publication counters may jump, but a delta must advance.
                try e.decimal(base);
                if (try std.fmt.parseInt(u64, batch.sequence, 10) <= try std.fmt.parseInt(u64, base, 10)) return error.SequenceRegression;
            },
        }
        var candidate = try Model.init(self.allocator, self.limit);
        errdefer candidate.deinit();
        const a = candidate.arena.allocator();
        var changed: Keys = .empty;
        defer changed.deinit(self.allocator);
        for (batch.upsert) |entity| {
            const key: e.Key = .{ .kind = std.meta.activeTag(entity), .id = entity.id() };
            if ((try changed.getOrPut(self.allocator, key)).found_existing) return error.DuplicateIdentity;
        }
        for (batch.removed) |key| {
            if ((try changed.getOrPut(self.allocator, key)).found_existing) return error.DuplicateIdentity;
            if (!self.entities.contains(key)) return error.UnknownRemoval;
        }
        if (batch.type == .delta) {
            var it = self.entities.iterator();
            while (it.next()) |entry| if (!changed.contains(entry.key_ptr.*)) try candidate.insert(entry.value_ptr.*);
        }
        for (batch.upsert) |entity| try candidate.insert(entity);
        candidate.session = try a.dupe(u8, batch.session);
        candidate.sequence = try a.dupe(u8, batch.sequence);
        candidate.ready = true;
        try candidate.validateReferences();
        // No fallible work follows this ownership swap.
        self.arena.deinit();
        self.* = candidate;
    }

    fn insert(self: *Model, entity: e.Entity) !void {
        try entity.validate();
        // Aqueous accounts key + JSON + 64 bytes per entity. Also cover the
        // larger of the retained typed value and its canonical known-field JSON.
        const size = @max(e.ownedBytes(entity), entity.encodedBytes()) + @tagName(std.meta.activeTag(entity)).len + entity.id().len + 1 + 64;
        if (size > self.limit - self.accounted_bytes) return error.StateTooLarge;
        const owned = try e.clone(e.Entity, self.arena.allocator(), entity);
        try self.entities.put(self.arena.allocator(), .{ .kind = std.meta.activeTag(owned), .id = owned.id() }, owned);
        self.accounted_bytes += size;
    }

    pub fn get(self: *const Model, comptime kind: e.Kind, id: []const u8) ?*const @FieldType(e.Entity, @tagName(kind)) {
        if (!self.ready) return null;
        const entity = self.entities.getPtr(.{ .kind = kind, .id = id }) orelse return null;
        return &@field(entity, @tagName(kind));
    }
    pub fn outputByName(self: *const Model, name: []const u8) ?*const e.Output {
        if (!self.ready) return null;
        var it = self.entities.valueIterator();
        while (it.next()) |entity| if (entity.* == .output and std.mem.eql(u8, entity.output.name, name)) return &entity.output;
        return null;
    }
    pub fn activeWorkspace(self: *const Model, output: []const u8) ?*const e.Workspace {
        const o = self.get(.output, output) orelse return null;
        return self.get(.workspace, o.active_workspace orelse return null);
    }
    /// Caller owns the slice; its elements remain borrowed from this model.
    pub fn workspaces(self: *const Model, allocator: Allocator, output: []const u8) ![]*const e.Workspace {
        var list: std.ArrayList(*const e.Workspace) = .empty;
        errdefer list.deinit(allocator);
        if (self.ready) {
            var it = self.entities.valueIterator();
            while (it.next()) |entity| if (entity.* == .workspace and std.mem.eql(u8, entity.workspace.output, output)) try list.append(allocator, &entity.workspace);
        }
        std.mem.sort(*const e.Workspace, list.items, {}, struct {
            fn less(_: void, a: *const e.Workspace, b: *const e.Workspace) bool {
                return if (a.number != b.number) a.number < b.number else std.mem.lessThan(u8, a.id, b.id);
            }
        }.less);
        return list.toOwnedSlice(allocator);
    }
    pub const WindowFilter = struct {
        output: ?[]const u8 = null,
        workspace: ?[]const u8 = null,
        purpose: enum { all, taskbar, switcher } = .all,
    };
    pub fn windows(self: *const Model, allocator: Allocator, filter: WindowFilter) ![]*const e.Window {
        var list: std.ArrayList(*const e.Window) = .empty;
        errdefer list.deinit(allocator);
        if (self.ready) {
            var it = self.entities.valueIterator();
            while (it.next()) |entity| {
                if (entity.* != .window) continue;
                const w = &entity.window;
                if (filter.output) |id| if (w.output == null or !std.mem.eql(u8, w.output.?, id)) continue;
                if (filter.workspace) |id| if (w.workspace == null or !std.mem.eql(u8, w.workspace.?, id)) continue;
                if ((filter.purpose == .taskbar and w.skip_taskbar) or (filter.purpose == .switcher and w.skip_switcher)) continue;
                try list.append(allocator, w);
            }
        }
        std.mem.sort(*const e.Window, list.items, {}, struct {
            fn less(_: void, a: *const e.Window, b: *const e.Window) bool {
                return std.mem.lessThan(u8, a.id, b.id);
            }
        }.less);
        return list.toOwnedSlice(allocator);
    }
    pub const Focus = struct { seat: *const e.Seat, output: ?*const e.Output, window: ?*const e.Window, keyboard: ?*const e.Keyboard };
    pub fn focus(self: *const Model, seat_id: ?[]const u8) !Focus {
        if (!self.ready) return error.Unavailable;
        var selected: ?*const e.Seat = null;
        if (seat_id) |id| {
            selected = self.get(.seat, id) orelse return error.UnknownSeat;
        } else {
            var it = self.entities.valueIterator();
            while (it.next()) |entity| if (entity.* == .seat) {
                if (selected != null) return error.AmbiguousSeat;
                selected = &entity.seat;
            };
        }
        const seat = selected orelse return error.Unavailable;
        return .{
            .seat = seat,
            .output = if (seat.output) |id| self.get(.output, id) else null,
            .window = if (seat.window) |id| self.get(.window, id) else null,
            .keyboard = if (seat.keyboard) |id| self.get(.keyboard, id) else null,
        };
    }

    fn require(self: *const Model, comptime kind: e.Kind, id: ?[]const u8) !void {
        if (id) |value| if (self.get(kind, value) == null) return error.DanglingReference;
    }
    fn validateReferences(self: *const Model) !void {
        const session = self.get(.session, "session") orelse return error.MissingSession;
        var seat_count: usize = 0;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);
        var it = self.entities.valueIterator();
        while (it.next()) |entity| switch (entity.*) {
            .output => |v| {
                if ((try names.getOrPut(self.allocator, v.name)).found_existing) return error.DuplicateConnector;
                try self.require(.workspace, v.active_workspace);
                if (v.active_workspace) |id| {
                    const ws = self.get(.workspace, id).?;
                    if (!std.mem.eql(u8, ws.output, v.id) or !ws.active) return error.InconsistentWorkspace;
                }
            },
            .workspace => |v| {
                try self.require(.output, v.output);
                if (v.active) {
                    const out = self.get(.output, v.output).?;
                    if (out.active_workspace == null or !std.mem.eql(u8, out.active_workspace.?, v.id)) return error.InconsistentWorkspace;
                }
            },
            .window => |v| {
                try self.require(.workspace, v.workspace);
                try self.require(.output, v.output);
                if (v.workspace) |ws| if (v.output) |out| {
                    if (!std.mem.eql(u8, self.get(.workspace, ws).?.output, out)) return error.InconsistentWorkspace;
                };
            },
            .seat => |v| {
                seat_count += 1;
                try self.require(.output, v.output);
                try self.require(.window, v.window);
                try self.require(.keyboard, v.keyboard);
                if (v.window != null and v.focus_kind != .window) return error.InconsistentFocus;
                if (v.keyboard) |id| if (!std.mem.eql(u8, self.get(.keyboard, id).?.seat, v.id)) return error.InconsistentSeat;
            },
            .keyboard => |v| try self.require(.seat, v.seat),
            .keyboard_device => |v| {
                try self.require(.seat, v.seat);
                try self.require(.keyboard, v.group);
                if (v.group) |id| if (!std.mem.eql(u8, self.get(.keyboard, id).?.seat, v.seat)) return error.InconsistentSeat;
            },
            .session => |v| {
                try self.require(.seat, v.default_seat);
                try self.require(.output, v.overview_output);
                try self.require(.window, v.overview_window);
            },
        };
        if ((seat_count == 1) != (session.default_seat != null)) return error.InconsistentSeat;
    }
};
