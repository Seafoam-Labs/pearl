//! Coral recovery persistence M1 (Linux, Zig 0.17).
//!
//! Integration contract:
//! * Store.open(.{}) does synchronous mkdir/open/flock/fsync. It is bounded in
//!   work, NOT latency: run before showing UI or on a startup worker, and hand
//!   the result to the UI. Existing state-home required; see recovery_fs.zig.
//! * Build OwnedSnapshot.create() from an immutable UI capture. No FS there;
//!   copying a large buffer still costs UI CPU/memory. Capture/debounce sensibly.
//! * saveAsync transfers ownership on success, keeps at most one in-flight and
//!   one pending snapshot, and coalesces the pending one. Every accepted call
//!   completes exactly once on its submitting thread-default GMainContext.
//!   No FS, encoding, hashing, fsync, or waits occur on the submitting thread.
//! * Use ONE UI thread/context for all calls on a Store. Callbacks may reenter.
//!   g_application_hold before each accepted async operation and release from
//!   its callback (balance a rejected call immediately). Keep the context alive.
//! * closeAsync stops accepting checkpoints, flushes the running/latest pending
//!   checkpoint, then keeps or explicitly removes the current journal. It does
//!   not cancel an in-progress syscall. destroy only after the close callback.
//!   Keep callback contexts alive until EACH callback, including coalesced ones;
//!   their delivery order relative to close is not guaranteed.
//! * Run discover/claim/load/discard/release off the GTK loop. Keep the Claim
//!   locked throughout restore UI. Dismiss -> release, NOT discard. Restore as
//!   unsaved copies; checkpoint them in the NEW Store before asking permission
//!   to discard the old Claim. Original paths/etags are metadata, never writes.
//! * Display all errors, notably TooLarge/TooManySessions/UnsupportedVersion,
//!   CorruptManifest and durability_uncertain. No buffer is silently skipped.
//!
//! Imports: only std and existing pearl_app_c (the same binding as ../c.zig).
//! Link libc, gio-2.0, gobject-2.0, glib-2.0. No new build/root imports required
//! until integration. Import this file from the parent test root to run tests.
const std = @import("std");
const c = @import("pearl_app_c");
const a = std.heap.c_allocator;
const fs = @import("recovery_fs.zig");
const model = @import("recovery_model.zig");

pub const Snapshot = model.Snapshot;
pub const OwnedSnapshot = model.OwnedSnapshot;
pub const Document = model.Document;
pub const Group = model.Group;
pub const View = model.View;
pub const limits = model.limits;
pub const SessionId = fs.SessionId;
pub const Discovery = fs.Discovery;
pub const discover = fs.discover;
pub const Claim = fs.Journal;
pub const Approval = fs.Approval;
pub const Checkpoint = fs.Checkpoint;

pub const Result = union(enum) {
    checkpoint: Checkpoint,
    coalesced,
    closed,
    failed: anyerror,
};
pub const Callback = *const fn (context: ?*anyopaque, result: Result) void;
pub const Close = enum {
    /// Dismissal, failed shutdown, or unresolved dirty documents.
    keep,
    /// Parent certifies every dirty document was saved or explicitly discarded
    /// by the user. Refused if the latest checkpoint failed/is not durable.
    remove_after_resolution,
};
pub const Options = struct {
    /// Borrowed only for open(); null uses environment. Native absolute path.
    state_home: ?[]const u8 = null,
    /// Optional worker-only test observation point, never a UI callback.
    before_checkpoint_commit: ?*const fn () void = null,
};

pub const Store = struct {
    journal: fs.Journal,
    before_checkpoint_commit: ?*const fn () void = null,
    pending: ?*Request = null,
    closing: ?*Request = null,
    running: bool = false,
    closed: bool = false,
    last_checkpoint_ok: bool = true,
    owner: ?*c.GThread = null,
    main_context: ?*c.GMainContext = null,

    pub fn open(options: Options) !*Store {
        const self = try a.create(Store);
        errdefer a.destroy(self);
        self.* = .{ .journal = try fs.Journal.create(options.state_home), .before_checkpoint_commit = options.before_checkpoint_commit };
        return self;
    }

    pub fn sessionId(self: *const Store) SessionId {
        return self.journal.id;
    }

    /// No I/O. On error caller STILL owns snapshot and no callback is scheduled.
    /// On success caller must not access it again. Treat coalesced as superseded,
    /// NOT persisted; only a later durable completion establishes protection.
    pub fn saveAsync(self: *Store, snapshot: *OwnedSnapshot, callback: Callback, context: ?*anyopaque) !void {
        try self.checkThread();
        if (self.closed or self.closing != null) return error.Closing;
        const request = try self.makeRequest(.{ .save = snapshot }, callback, context);
        if (self.running) {
            const old = self.pending;
            self.pending = request;
            if (old) |previous| {
                // Release superseded bytes now, not when a delayed callback runs.
                previous.operation.save.?.deinit();
                previous.operation.save = null;
                previous.result = .coalesced;
                c.g_task_return_boolean(previous.task, 1);
                c.g_object_unref(previous.task);
            }
        } else self.start(request);
    }

    /// No I/O. Always flushes; no cancellation that could race manifest removal.
    /// A failed close still releases the lock and permits destroy(), but may
    /// leave the journal behind. Removal is never automatic on ordinary release.
    pub fn closeAsync(self: *Store, disposition: Close, callback: Callback, context: ?*anyopaque) !void {
        try self.checkThread();
        if (self.closed or self.closing != null) return error.Closing;
        const request = try self.makeRequest(.{ .close = disposition }, callback, context);
        self.closing = request;
        if (!self.running) self.start(request);
    }

    /// After close completion only; no FS or blocking joins here. Do not use the
    /// Store again. Other callbacks may remain queued, but never reference it.
    pub fn destroy(self: *Store) void {
        std.debug.assert(self.closed and !self.running and self.pending == null);
        if (self.main_context) |ctx| c.g_main_context_unref(ctx);
        a.destroy(self);
    }

    fn checkThread(self: *Store) !void {
        const thread = c.g_thread_self().?;
        const ctx = c.g_main_context_get_thread_default() orelse c.g_main_context_default().?;
        if (self.owner) |owner| {
            if (owner != thread or self.main_context.? != ctx) return error.WrongContext;
        } else {
            self.owner = thread;
            self.main_context = c.g_main_context_ref(ctx);
        }
    }

    fn makeRequest(self: *Store, operation: Operation, callback: Callback, context: ?*anyopaque) !*Request {
        const req = try a.create(Request);
        const task = c.g_task_new(null, null, &complete, req).?;
        req.* = .{ .store = self, .task = task, .operation = operation, .callback = callback, .context = context };
        c.g_task_set_task_data(task, req, &destroyRequest);
        return req;
    }

    fn start(self: *Store, req: *Request) void {
        self.running = true;
        req.was_worker = true;
        c.g_task_run_in_thread(req.task, &worker);
        c.g_object_unref(req.task);
    }
};

const Operation = union(enum) { save: ?*OwnedSnapshot, close: Close };
const Request = struct {
    store: *Store,
    task: *c.GTask,
    operation: Operation,
    callback: Callback,
    context: ?*anyopaque,
    result: Result = .{ .failed = error.NotCompleted },
    was_worker: bool = false,
};
fn destroyRequest(data: ?*anyopaque) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(data.?));
    switch (req.operation) {
        .save => |snapshot| if (snapshot) |owned| owned.deinit(),
        .close => {},
    }
    a.destroy(req);
}
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(data.?));
    req.result = run(req) catch |err| .{ .failed = err };
    c.g_task_return_boolean(task, 1);
}
fn run(req: *Request) !Result {
    switch (req.operation) {
        .save => |snapshot| return .{ .checkpoint = try req.store.journal.checkpointObserved(snapshot.?.value, req.store.before_checkpoint_commit) },
        .close => |disposition| {
            defer req.store.journal.release();
            // A never-checkpointed empty session is not a corrupt journal.
            // Nonempty error evidence is never removed by this cleanup path.
            if (try req.store.journal.removeIfEmpty()) return .closed;
            if (disposition == .remove_after_resolution) {
                if (!req.store.last_checkpoint_ok) return error.CheckpointNotDurable;
                try req.store.journal.discard(.user_approved);
            }
            return .closed;
        },
    }
}
fn complete(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(data.?));
    _ = c.g_task_propagate_boolean(@ptrCast(result.?), null);
    if (req.was_worker) {
        const self = req.store;
        self.running = false;
        switch (req.operation) {
            .close => {
                self.closed = true;
                self.closing = null;
            },
            .save => {
                self.last_checkpoint_ok = switch (req.result) {
                    .checkpoint => |status| status == .durable,
                    else => false,
                };
                if (self.pending) |next| {
                    self.pending = null;
                    self.start(next);
                } else if (self.closing) |closing| self.start(closing);
            },
        }
    }
    // No dereference of Store after callback: close callback may destroy it.
    req.callback(req.context, req.result);
}

test {
    _ = @import("recovery_test.zig");
    _ = @import("recovery_offsets.zig");
}
