//! One synchronous store owner on one dedicated thread. No GTK or Wayland.
//! Admission/status never perform filesystem I/O. Only one active job and one
//! pending snapshot exist; required removals apply backpressure rather than queue.
const std = @import("std");
const codec = @import("codec.zig");
const storage = @import("store.zig");
const history = @import("history.zig");
const Completion = @import("completion.zig").Completion;
pub const StartError = std.Thread.SpawnError || error{ OutOfMemory, NotificationUnavailable };

pub const Key = [32]u8;
pub const receipt_limit = 16;
pub const Operation = enum { ordinary, delete, clear, expiry, eviction };
pub const ReceiptState = enum { pending, running, durable, failed, uncertain, cancelled };
pub const Receipt = struct {
    token: u64,
    revision: u64,
    operation: Operation,
    state: ReceiptState,
    failure: ?storage.Error = null,
};
pub const AdmissionError = error{ Busy, Closed, NotReady, Fenced, StaleRevision, CounterExhausted, InvalidClear };
pub const Status = struct {
    restoring: bool = false,
    initialized: bool = false,
    clear_only: bool = false,
    stopped: bool = false,
    accepting: bool = false,
    desired_revision: u64 = 0,
    durable_revision: u64 = 0,
    active_revision: ?u64 = null,
    pending_revision: ?u64 = null,
    write_count: u64 = 0,
    failure: ?storage.Error = null,
};

const KeyWriter = struct {
    key: Key = @splat(0),
    first: bool = true,
    pub fn writeAll(self: *KeyWriter, bytes: []const u8) error{}!void {
        if (self.first) {
            @memcpy(&self.key, bytes[64..96]);
            self.first = false;
        }
    }
};

fn contentKey(snapshot: codec.Snapshot) codec.Error!Key {
    var writer: KeyWriter = .{};
    // Reuse the codec's validated, complete SHA-256 identity: text, timestamps,
    // sequences, order and floor. A missing file and any empty projection have
    // the same identity because the store removes empty projections.
    try codec.encode(snapshot, &writer);
    return if (snapshot.records.len == 0) @splat(0) else writer.key;
}

/// Immutable, exclusively owned input. Allocator must support cross-thread free
/// (page_allocator, c_allocator and std.testing.allocator do). create() copies
/// borrowed input once into an exact-size text allocation; it does no file I/O.
/// After successful admission the caller must not use or release this pointer.
/// On admission failure ownership stays with the caller. No refcounts/queues of
/// old payloads are retained; only a fixed SHA-256 key survives successful saves.
pub const OwnedSnapshot = struct {
    allocator: std.mem.Allocator,
    payload: []u8,
    rows: [history.entries_limit]codec.Record = undefined,
    len: usize,
    floor: i64,
    key: Key,

    pub fn create(allocator: std.mem.Allocator, snapshot: codec.Snapshot) codec.Error!*OwnedSnapshot {
        const key = try contentKey(snapshot);
        var size: usize = 0;
        for (snapshot.records) |record| size += record.bytes.len; // codec has bounded the sum
        const self = try allocator.create(OwnedSnapshot);
        errdefer allocator.destroy(self);
        const bytes = try allocator.alloc(u8, size);
        self.* = .{ .allocator = allocator, .payload = bytes, .len = snapshot.records.len, .floor = snapshot.floor, .key = key };
        var offset: usize = 0;
        for (snapshot.records, 0..) |record, index| {
            const owned = bytes[offset..][0..record.bytes.len];
            @memcpy(owned, record.bytes);
            self.rows[index] = .{ .bytes = owned, .last_copy = record.last_copy, .sequence = record.sequence };
            offset += owned.len;
        }
        return self;
    }

    pub fn view(self: *const OwnedSnapshot) codec.Snapshot {
        return .{ .records = self.rows[0..self.len], .floor = self.floor };
    }

    pub fn deinit(self: *OwnedSnapshot) void {
        const allocator = self.allocator;
        std.crypto.secureZero(u8, self.payload);
        allocator.free(self.payload);
        allocator.destroy(self);
    }
};

/// Injected synchronous backend; every callback runs only on the worker thread.
/// load returns the validated current content identity (zero for missing/empty).
/// persist may return success only after required file/directory synchronization.
/// close must tolerate a failed load. Context must outlive join().
pub const Backend = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque) storage.Error!Key,
    persist: *const fn (*anyopaque, codec.Snapshot, Operation) storage.Error!void,
    close: *const fn (*anyopaque) void,
};

const FileBackend = struct {
    path: [:0]const u8,
    hooks: storage.Hooks,
    store: ?storage.Store = null,
    retain_load: bool = false,
    loaded: ?codec.Loaded = null,

    fn backend(self: *FileBackend) Backend {
        return .{ .context = self, .load = load, .persist = persist, .close = close };
    }
    fn load(context: *anyopaque) storage.Error!Key {
        const self: *FileBackend = @ptrCast(@alignCast(context));
        // The store and its descriptors never cross the thread boundary.
        self.store = try storage.Store.open(std.heap.page_allocator, self.path);
        self.store.?.hooks = self.hooks;
        try self.store.?.retireTemps();
        var loaded = (try self.store.?.read()) orelse return @splat(0);
        const key = contentKey(loaded.snapshot()) catch |err| {
            loaded.deinit();
            return err;
        };
        if (self.retain_load) self.loaded = loaded else loaded.deinit();
        return key;
    }
    fn persist(context: *anyopaque, snapshot: codec.Snapshot, operation: Operation) storage.Error!void {
        const self: *FileBackend = @ptrCast(@alignCast(context));
        if (operation == .clear) return self.store.?.remove();
        if (operation != .ordinary) return self.store.?.writeRemoval(snapshot);
        return self.store.?.write(snapshot);
    }
    fn close(context: *anyopaque) void {
        const self: *FileBackend = @ptrCast(@alignCast(context));
        if (self.loaded) |*loaded| loaded.deinit();
        self.loaded = null;
        if (self.store) |*store| store.close();
        self.store = null;
    }
};

const Target = union(enum) {
    filesystem: struct { path: [:0]u8, hooks: storage.Hooks, restore: bool = false },
    injected: Backend,
};
const Job = struct { revision: u64, operation: Operation, snapshot: *OwnedSnapshot, token: ?u64 };

/// Stable heap allocation. One caller owns lifecycle/join and submits increasing
/// revisions from the current authoritative model. Every removal (including
/// expiry/PNG eviction) must use requestRemoval, not an ordinary coalescible save.
/// Io and allocators must outlive join; the Io implementation must be thread-safe.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    target: Target,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    state: Status = .{},
    stop_requested: bool = false,
    active: ?Job = null,
    pending: ?Job = null,
    receipts: [receipt_limit]?Receipt = @splat(null),
    next_token: u64 = 1,
    restored: ?codec.Loaded = null,
    restore_claimed: bool = false,
    completion: Completion,

    /// Integration startup pauses admission until the main context takes and
    /// validates the loaded floor/text. Loading/decoding still happens here.
    pub fn startPaused(allocator: std.mem.Allocator, io: std.Io, path: []const u8, hooks: storage.Hooks) StartError!*Worker {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        return launch(allocator, io, .{ .filesystem = .{ .path = owned_path, .hooks = hooks, .restore = true } });
    }
    pub fn takeRestored(self: *Worker) error{ NotReady, Fenced, StaleReceipt }!?codec.Loaded {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.failure != null) return error.Fenced;
        if (!self.state.initialized) return error.NotReady;
        if (!self.state.restoring or self.restore_claimed) return error.StaleReceipt;
        const result = self.restored;
        self.restored = null;
        self.restore_claimed = true;
        return result;
    }
    pub fn resumeAfterRestore(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.restore_claimed);
        self.state.restoring = false;
        self.condition.broadcast(self.io);
    }

    pub fn start(allocator: std.mem.Allocator, io: std.Io, path: []const u8, hooks: storage.Hooks) StartError!*Worker {
        const owned_path = try allocator.dupeSentinel(u8, path, 0);
        errdefer allocator.free(owned_path);
        return launch(allocator, io, .{ .filesystem = .{ .path = owned_path, .hooks = hooks } });
    }

    pub fn startWithBackend(allocator: std.mem.Allocator, io: std.Io, backend: Backend) StartError!*Worker {
        return launch(allocator, io, .{ .injected = backend });
    }

    fn launch(allocator: std.mem.Allocator, io: std.Io, target: Target) StartError!*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .target = target, .completion = try Completion.init() };
        errdefer self.completion.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn requestSave(self: *Worker, revision: u64, snapshot: *OwnedSnapshot) AdmissionError!void {
        _ = try self.admit(.ordinary, revision, snapshot);
    }

    pub fn requestRemoval(self: *Worker, operation: Operation, revision: u64, snapshot: *OwnedSnapshot) AdmissionError!u64 {
        if (operation == .ordinary or (operation == .clear and snapshot.len != 0)) return error.InvalidClear;
        return (try self.admit(operation, revision, snapshot)).?;
    }

    fn admit(self: *Worker, operation: Operation, revision: u64, snapshot: *OwnedSnapshot) AdmissionError!?u64 {
        self.mutex.lockUncancelable(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);
        if (self.state.failure != null and !(self.state.clear_only and operation == .clear)) return error.Fenced;
        if (self.stop_requested or self.state.stopped) return error.Closed;
        if ((!self.state.initialized and !self.state.clear_only) or self.state.restoring) return error.NotReady;
        if (self.state.clear_only and self.state.desired_revision != 0) return error.Busy;
        if (revision <= self.state.desired_revision) return error.StaleRevision;
        if (self.pending) |pending| if (pending.operation != .ordinary) return error.Busy;
        var token: ?u64 = null;
        if (operation != .ordinary) {
            const next = std.math.add(u64, self.next_token, 1) catch return error.CounterExhausted;
            const slot = self.receiptSlot() orelse return error.Busy;
            token = self.next_token;
            self.receipts[slot] = .{ .token = token.?, .revision = revision, .operation = operation, .state = .pending };
            self.next_token = next;
        }
        const retired = self.pending;
        self.pending = .{ .revision = revision, .operation = operation, .snapshot = snapshot, .token = token };
        self.state.desired_revision = revision;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        locked = false;
        // Release superseded input outside the mailbox lock. It is no longer
        // worker-visible. Peak queued ownership remains active + pending;
        // caller construction/retirement may transiently own another candidate.
        if (retired) |job| job.snapshot.deinit();
        return token;
    }

    fn receiptSlot(self: *Worker) ?usize {
        var oldest: ?usize = null;
        for (self.receipts, 0..) |slot, index| {
            const value = slot orelse return index;
            if (value.state == .pending or value.state == .running) continue;
            if (oldest == null or value.token < self.receipts[oldest.?].?.token) oldest = index;
        }
        return oldest;
    }

    pub fn receipt(self: *Worker, token: u64) error{StaleReceipt}!Receipt {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.receipts) |slot| if (slot) |value| if (value.token == token) return value;
        return error.StaleReceipt;
    }

    fn setReceipt(self: *Worker, token: ?u64, state: ReceiptState, failure: ?storage.Error) void {
        const wanted = token orelse return;
        for (&self.receipts) |*slot| if (slot.*) |*value| if (value.token == wanted) {
            value.state = state;
            value.failure = failure;
            return;
        };
        unreachable; // outstanding receipts are never evicted
    }

    fn statusLocked(self: *Worker) Status {
        var result = self.state;
        result.accepting = result.initialized and !result.restoring and !self.stop_requested and !result.stopped and result.failure == null;
        result.active_revision = if (self.active) |job| job.revision else null;
        result.pending_revision = if (self.pending) |job| job.revision else null;
        return result;
    }

    pub fn status(self: *Worker) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.statusLocked();
    }

    /// Blocking helpers for tests/non-UI callers. UI watches completion.fd and
    /// reads status/receipts after a wakeup; it never waits for disk here.
    pub fn waitReady(self: *Worker) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.state.initialized and !self.state.clear_only and !self.state.stopped) self.condition.waitUncancelable(self.io, &self.mutex);
        return self.statusLocked();
    }

    pub fn waitIdle(self: *Worker) Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while ((!self.state.initialized and !self.state.clear_only and !self.state.stopped) or self.active != null or self.pending != null) self.condition.waitUncancelable(self.io, &self.mutex);
        return self.statusLocked();
    }

    pub fn beginShutdown(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stop_requested = true;
        self.condition.broadcast(self.io);
    }

    /// Lifecycle owner only. May block until accepted operations finish. On a
    /// UI thread call only after status.stopped; no store I/O runs in join().
    pub fn join(self: *Worker) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn destroy(self: *Worker) void {
        std.debug.assert(self.thread == null and self.state.stopped);
        self.completion.deinit();
        if (self.target == .filesystem) self.allocator.free(self.target.filesystem.path);
        self.allocator.destroy(self);
    }

    pub fn deinit(self: *Worker) void {
        self.beginShutdown();
        self.join();
        self.destroy();
    }

    fn run(self: *Worker) void {
        var file: FileBackend = .{
            .path = if (self.target == .filesystem) self.target.filesystem.path else "",
            .hooks = if (self.target == .filesystem) self.target.filesystem.hooks else .{},
            .retain_load = self.target == .filesystem and self.target.filesystem.restore,
        };
        const backend = switch (self.target) {
            .filesystem => file.backend(),
            .injected => |value| value,
        };
        // Close all store descriptors before publishing stopped. These defers
        // run on every startup, write-failure and normal-drain exit path.
        defer {
            self.mutex.lockUncancelable(self.io);
            var abandoned = self.restored;
            self.restored = null;
            self.mutex.unlock(self.io);
            if (abandoned) |*loaded| loaded.deinit();
            backend.close(backend.context);
            self.mutex.lockUncancelable(self.io);
            self.state.clear_only = false;
            self.state.stopped = true;
            self.condition.broadcast(self.io);
            self.completion.signal();
            self.mutex.unlock(self.io);
        }
        var saved_key = backend.load(backend.context) catch |err| recovery: {
            self.mutex.lockUncancelable(self.io);
            self.state.failure = err;
            // Only a safely opened file rejected by the codec can await an
            // explicit Clear. Keep its validated directory/file locks owned by
            // this thread; all other startup failures still close and exit.
            self.state.clear_only = self.target == .filesystem and file.store != null and
                (err == error.Corrupt or err == error.Unsupported) and
                (file.store.?.state == .corrupt or file.store.?.state == .unsupported);
            const clear_only = self.state.clear_only;
            self.condition.broadcast(self.io);
            self.completion.signal();
            self.mutex.unlock(self.io);
            if (!clear_only) return;
            break :recovery @as(Key, @splat(0));
        };
        self.mutex.lockUncancelable(self.io);
        self.restored = file.loaded;
        file.loaded = null;
        self.state.restoring = file.retain_load and !self.state.clear_only;
        self.state.initialized = !self.state.clear_only;
        self.condition.broadcast(self.io);
        self.completion.signal();
        self.mutex.unlock(self.io);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while ((self.state.restoring or self.pending == null) and !self.stop_requested) self.condition.waitUncancelable(self.io, &self.mutex);
            const job = self.pending orelse {
                self.mutex.unlock(self.io);
                return;
            };
            self.pending = null;
            self.active = job;
            const recovering = self.state.clear_only;
            self.setReceipt(job.token, .running, null);
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);

            // Single-threaded execution is the ordering fence. Compare against
            // actual last success here, never against a stale admission-time key.
            const write = job.operation != .ordinary or !std.mem.eql(u8, &saved_key, &job.snapshot.key);
            var failure: ?storage.Error = null;
            if (write) backend.persist(backend.context, job.snapshot.view(), job.operation) catch |err| {
                failure = err;
            };
            if (failure == null) saved_key = job.snapshot.key;
            job.snapshot.deinit(); // only this thread releases the active input

            self.mutex.lockUncancelable(self.io);
            self.active = null; // main only reads job metadata, never its pointer
            if (write) self.state.write_count +|= 1;
            if (failure) |err| {
                self.state.clear_only = false;
                self.state.failure = err;
                self.setReceipt(job.token, if (err == error.Uncertain) .uncertain else .failed, err);
                const cancelled = self.pending;
                self.pending = null;
                if (cancelled) |pending| self.setReceipt(pending.token, .cancelled, err);
                self.condition.broadcast(self.io);
                self.completion.signal();
                self.mutex.unlock(self.io);
                if (cancelled) |pending| pending.snapshot.deinit();
                // No automatic retry/replay after any failure or uncertainty.
                return;
            }
            self.state.durable_revision = job.revision;
            self.setReceipt(job.token, .durable, null);
            if (recovering) self.state.clear_only = false;
            self.condition.broadcast(self.io);
            self.completion.signal();
            self.mutex.unlock(self.io);
            // Recovery deliberately requires a restart. Do not resume normal
            // saves/restoration in a session whose startup never completed.
            if (recovering) return;
        }
    }
};
