//! Main-context history/storage coordination; no GTK, Wayland or filesystem I/O.
const std = @import("std");
pub const history = @import("history.zig");
const codec = @import("codec.zig");
pub const clock = @import("clock.zig");
pub const worker = @import("worker.zig");
const storage = @import("store.zig");
pub const presentation = @import("presentation.zig");
pub const Error = history.Error || worker.AdmissionError || storage.Error || clock.Error || error{ Locked, Unavailable, Stale };
pub const Health = presentation.Health;

pub const Transaction = struct {
    prepared: history.History.Prepared,
    snapshot: ?*worker.OwnedSnapshot = null,
    operation: worker.Operation = .ordinary,
    consumed: bool = false,
    pub fn entry(self: *const Transaction) history.Entry {
        return self.prepared.entries()[0];
    }
    pub fn discard(self: *Transaction) void {
        if (self.consumed) return;
        if (self.snapshot) |snapshot| snapshot.deinit();
        self.snapshot = null;
        self.prepared.discard();
        self.consumed = true;
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: [:0]u8,
    hooks: storage.Hooks,
    model: history.History,
    worker: ?*worker.Worker = null,
    clock_state: clock.Clock = .{},
    now: i64 = 0,
    locked: bool = true,
    ready: bool = false,
    stopping: bool = false,
    failure: ?Error = null,
    maintenance_busy: bool = false,
    busy: bool = false,
    save_revision: u64 = 0,
    last_token: ?u64 = null,
    observed_durable: u64 = 0,
    instance: [32]u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, hooks: storage.Hooks) !Session {
        var nonce: [16]u8 = undefined;
        try std.Io.randomSecure(io, &nonce);
        return .{ .allocator = allocator, .io = io, .path = try allocator.dupeSentinel(u8, path, 0), .hooks = hooks, .model = history.History.init(allocator), .instance = std.fmt.bytesToHex(nonce, .lower) };
    }
    pub fn setLocked(self: *Session, locked: bool) void {
        self.locked = locked;
    }
    pub fn accessible(self: *const Session) bool {
        if (self.locked or self.stopping or !self.ready or self.failure != null or self.maintenance_busy) return false;
        const status = (self.worker orelse return false).status();
        return status.initialized and !status.restoring and !status.stopped and status.failure == null;
    }
    pub fn entries(self: *const Session) []const history.Entry {
        return if (self.accessible()) self.model.entries() else &.{};
    }
    pub fn health(self: *const Session) Health {
        if (self.locked) return .paused;
        if (self.failure) |err| return switch (err) {
            error.ClockUntrusted => .clock_untrusted,
            error.Uncertain => .uncertain,
            else => if (!self.ready) .unavailable else .failed,
        };
        const w = self.worker orelse return .loading;
        const status = w.status();
        if (status.failure) |err| return if (err == error.Uncertain) .uncertain else if (self.ready) .failed else .unavailable;
        if (!self.ready) return .loading;
        if (self.busy or self.maintenance_busy) return .busy;
        if (status.desired_revision != status.durable_revision) return .pending;
        return if (status.desired_revision == 0) .enabled else .durable;
    }
    pub fn failClock(self: *Session) void {
        self.failure = error.ClockUntrusted;
        if (self.worker) |w| w.beginShutdown();
    }
    pub fn poll(self: *Session, sample: clock.Sample) Error!bool {
        return self.pollImpl(sample) catch |err| {
            self.failure = err;
            if (self.worker) |w| {
                if (!w.status().clear_only or (err != error.Corrupt and err != error.Unsupported)) w.beginShutdown();
            }
            return err;
        };
    }
    fn pollImpl(self: *Session, sample: clock.Sample) Error!bool {
        if (self.stopping) return false;
        if (self.failure) |err| return err;
        if (self.worker == null) {
            if (self.locked) return false;
            self.worker = worker.Worker.startPaused(self.allocator, self.io, self.path, self.hooks) catch {
                self.failure = error.Unavailable;
                return error.Unavailable;
            };
            return true;
        }
        const w = self.worker.?;
        const status = w.status();
        if (status.failure) |err| {
            self.failure = err;
            return err;
        }
        if (!status.initialized) return false;
        if (!self.ready) {
            if (self.locked) return false;
            var loaded = w.takeRestored() catch return error.Unavailable;
            defer if (loaded) |*data| data.deinit();
            self.now = self.clock_state.start(sample, if (loaded) |data| data.floor else sample.wall_seconds) catch {
                self.failClock();
                return error.ClockUntrusted;
            };
            var restored = history.History.init(self.allocator);
            var installed = false;
            errdefer if (!installed) restored.deinit();
            var max_sequence: u64 = 0;
            var expired_text = false;
            if (loaded) |*data| for (data.snapshot().records) |record| {
                max_sequence = @max(max_sequence, record.sequence);
                if (try restored.restoreText(record.bytes, record.last_copy, self.now)) |id| {
                    for (restored.rows[0..restored.len]) |*entry| if (entry.id == id) {
                        entry.sequence = record.sequence;
                        break;
                    };
                } else expired_text = true;
            };
            restored.next_sequence = std.math.add(u64, max_sequence, 1) catch return error.CounterExhausted;
            self.model.deinit();
            self.model = restored;
            installed = true;
            w.resumeAfterRestore();
            self.ready = true;
            if (expired_text) {
                const prepared = try self.model.preparePrune(self.now);
                var tx = try self.transaction(prepared, .expiry, true);
                defer tx.discard();
                try self.commit(&tx);
            }
            return true;
        }
        self.now = self.clock_state.advance(sample) catch {
            self.failClock();
            return error.ClockUntrusted;
        };
        var changed = status.durable_revision != self.observed_durable;
        self.observed_durable = status.durable_revision;
        self.busy = false;
        var prepared = try self.model.preparePrune(self.now);
        if (prepared.len != self.model.len) {
            var tx = try self.transaction(prepared, .expiry, false);
            defer tx.discard();
            self.commit(&tx) catch |err| {
                if (err == error.Busy) {
                    self.maintenance_busy = true;
                    return true;
                }
                return err;
            };
            self.maintenance_busy = false;
            changed = true;
        } else {
            prepared.discard();
            self.maintenance_busy = false;
        }
        return changed;
    }
    fn gate(self: *Session, sample: clock.Sample) Error!void {
        if (self.locked or self.stopping) return error.Locked;
        _ = try self.poll(sample);
        if (self.maintenance_busy) return error.Busy;
        if (!self.accessible()) return error.Unavailable;
    }
    fn transaction(self: *Session, input: history.History.Prepared, operation: worker.Operation, force: bool) Error!Transaction {
        var prepared = input;
        errdefer prepared.discard();
        var rows: [history.entries_limit]codec.Record = undefined;
        var count: usize = 0;
        for (prepared.entries()) |entry| if (entry.kind == .text) {
            rows[count] = .{ .bytes = entry.bytes, .last_copy = entry.last_copy, .sequence = entry.sequence };
            count += 1;
        };
        var same = true;
        var old_count: usize = 0;
        var removed_text = false;
        for (self.model.entries()) |entry| if (entry.kind == .text) {
            if (old_count >= count or rows[old_count].sequence != entry.sequence) same = false;
            old_count += 1;
            var found = false;
            for (prepared.entries()) |next| if (next.id == entry.id) {
                found = true;
                break;
            };
            if (!found) removed_text = true;
        };
        if (old_count != count) same = false;
        const kind = if (removed_text and operation == .ordinary) worker.Operation.eviction else operation;
        return .{ .prepared = prepared, .operation = kind, .snapshot = if (force or !same) try worker.OwnedSnapshot.create(self.allocator, .{ .records = rows[0..count], .floor = self.now }) else null };
    }
    pub fn prepareCopy(self: *Session, kind: history.Kind, bytes: []const u8, sample: clock.Sample) Error!Transaction {
        try self.gate(sample);
        return self.transaction(try self.model.prepareCopy(kind, bytes, self.now), .ordinary, false);
    }
    pub fn prepareSelection(self: *Session, id: u64, sample: clock.Sample) Error!Transaction {
        try self.gate(sample);
        for (self.model.entries()) |entry| if (entry.id == id) return self.prepareCopy(entry.kind, entry.bytes, sample);
        return error.Stale;
    }
    pub fn commit(self: *Session, tx: *Transaction) Error!void {
        if (self.stopping or (self.locked and tx.operation != .expiry)) return error.Locked;
        if (self.failure) |err| return err;
        if (self.worker) |w| if (w.status().failure) |err| return err;
        if (tx.snapshot) |snapshot| {
            const revision = std.math.add(u64, self.save_revision, 1) catch return error.CounterExhausted;
            const w = self.worker orelse return error.Unavailable;
            if (tx.operation == .ordinary) {
                w.requestSave(revision, snapshot) catch |err| {
                    if (err == error.Busy) self.busy = true;
                    return err;
                };
            } else {
                self.last_token = w.requestRemoval(tx.operation, revision, snapshot) catch |err| {
                    if (err == error.Busy) self.busy = true;
                    return err;
                };
            }
            tx.snapshot = null;
            self.save_revision = revision;
        }
        tx.prepared.commit();
        tx.consumed = true;
    }
    pub fn accept(self: *Session, kind: history.Kind, bytes: []const u8, sample: clock.Sample) Error!u64 {
        var tx = try self.prepareCopy(kind, bytes, sample);
        defer tx.discard();
        const id = tx.prepared.result_id.?;
        try self.commit(&tx);
        return id;
    }
    pub fn delete(self: *Session, id: u64, sample: clock.Sample) Error!void {
        try self.gate(sample);
        var found = false;
        for (self.model.entries()) |entry| if (entry.id == id) {
            found = true;
            break;
        };
        if (!found) return error.Stale;
        var tx = try self.transaction(try self.model.prepareDelete(id), .delete, true);
        defer tx.discard();
        try self.commit(&tx);
    }
    pub fn canRecoverClear(self: *const Session) bool {
        if (self.locked or self.stopping or self.ready) return false;
        if (self.failure) |err| if (err != error.Corrupt and err != error.Unsupported) return false;
        const status = (self.worker orelse return false).status();
        return status.clear_only and !status.stopped;
    }
    pub fn clear(self: *Session) Error!void {
        if (self.locked or self.stopping) return error.Locked;
        if (self.canRecoverClear()) {
            const revision = std.math.add(u64, self.save_revision, 1) catch return error.CounterExhausted;
            const snapshot = try worker.OwnedSnapshot.create(self.allocator, .{ .records = &.{}, .floor = 0 });
            errdefer snapshot.deinit();
            self.last_token = try self.worker.?.requestRemoval(.clear, revision, snapshot);
            self.save_revision = revision;
            return;
        }
        if (self.failure) |err| return err;
        if (!self.accessible()) return error.Unavailable;
        var tx = try self.transaction(try self.model.prepareClear(), .clear, true);
        defer tx.discard();
        try self.commit(&tx);
    }
    pub fn removal(self: *Session) !worker.Receipt {
        return (self.worker orelse return error.Unavailable).receipt(self.last_token orelse return error.Stale);
    }
    pub fn removalStatus(self: *Session, allocator: std.mem.Allocator) ![]const u8 {
        if (self.locked or self.stopping) return error.Locked;
        // Admission already succeeded. A fast worker failure must not hide its
        // token or terminal outcome from the initial Delete/Clear response.
        const result = try self.removal();
        return std.json.Stringify.valueAlloc(allocator, .{ .queued = true, .operation = result.token, .instance = self.instance[0..], .state = result.state, .durable = result.state == .durable }, .{});
    }
    pub fn lastRemoval(self: *const Session) ?worker.Receipt {
        return (self.worker orelse return null).receipt(self.last_token orelse return null) catch null;
    }
    pub fn feedback(self: *const Session) presentation.Feedback {
        return presentation.feedback(self.health(), self.lastRemoval(), if (self.worker) |w| w.status().desired_revision else 0);
    }
    pub fn checkInstance(self: *const Session, instance: ?[]const u8) !void {
        if (instance) |value| if (!std.mem.eql(u8, value, &self.instance)) return error.StaleInstance;
    }
    pub fn pageStatus(self: *const Session, allocator: std.mem.Allocator, native_available: bool, incoming_pending: bool, message: []const u8, page: presentation.Page) ![]u8 {
        const visible = native_available and self.accessible();
        var receipt = self.lastRemoval();
        if (page.operation) |token| {
            if (self.locked or self.stopping) return error.Locked;
            if (page.instance == null) return error.InstanceRequired;
            try self.checkInstance(page.instance);
            receipt = (self.worker orelse return error.Unavailable).receipt(token) catch return error.StaleOperation;
        }
        const ws = if (self.worker) |w| w.status() else worker.Status{};
        const failure: ?Error = self.failure orelse ws.failure;
        return presentation.status(allocator, .{
            .accessible = visible,
            .receipts_accessible = !self.locked and !self.stopping,
            .persistent = self.ready and failure == null,
            .incoming_pending = incoming_pending,
            .persistence_pending = ws.desired_revision != ws.durable_revision,
            .health = self.health(),
            .code = if (failure) |err| @errorName(err) else null,
            .message = message,
            .entries = self.model.entries(),
            .revision = self.model.generation,
            .instance = &self.instance,
            .removal = receipt,
        }, page);
    }
    pub fn beginShutdown(self: *Session) void {
        self.stopping = true;
        self.locked = true;
        if (self.worker) |w| w.beginShutdown();
    }
    pub fn stopped(self: *const Session) bool {
        return if (self.worker) |w| w.status().stopped else true;
    }
    pub fn deinit(self: *Session) void {
        std.debug.assert(self.stopped());
        if (self.worker) |w| {
            w.join();
            w.destroy();
        }
        self.worker = null;
        self.model.deinit();
        self.allocator.free(self.path);
    }
};

/// Existing callers retain the default first page.
pub fn legacyStatus(s: *const Session, allocator: std.mem.Allocator, native_available: bool, transfer_pending: bool, message: []const u8) ![]const u8 {
    return s.pageStatus(allocator, native_available, transfer_pending, message, .{});
}
