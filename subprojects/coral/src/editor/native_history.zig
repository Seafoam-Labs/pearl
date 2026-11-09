//! GTK has no public non-merging undo barrier. A one-edit user action is hoisted
//! and may merge with adjacent typing, so canonical native undo is NOT safe after
//! a grouped edit. Each protected interval instead has a private GTK typing stack.
//! Group commits/replays switch intervals without entering those typing stacks.
//! Never call raw canonical undo/redo once a Guard is installed; use replay().
//!
//! Earlier canonical history is NOT cleared. At the first protected interval's
//! baseline it is inaccessible through this API (GroupedBoundary), not speculatively
//! replayed. Group records retain before/after intervals, so typing before a later
//! group becomes available again when that group is safely undone. History eviction
//! releases inactive intervals; the buffer retains its current interval and fence.
//! Auxiliary owners use the process C allocator, independent of History's lifetime.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const tx = @import("transactions.zig");
const a = std.heap.c_allocator;
const key = "coral-native-history-guard";
pub const Error = tx.PrepareError || error{ GroupedBoundary, NativeHistoryUnavailable };

const Epoch = struct {
    refs: usize = 1,
    buffer: *c.GtkTextBuffer,
    // Only redo actions undone in this branch are reachable. A new grouped
    // commit invalidates an older native redo branch without clearing GTK history.
    redo_depth: usize = 0,
    // Identity of the disk checkpoint represented by GTK's private clean marker.
    // Setting modified=true does not erase that marker inside GTK's undo manager.
    saved_generation: ?u64 = null,
    fn create(text: []const u8, modified: bool) !*Epoch {
        const self = try a.create(Epoch);
        const buffer = c.gtk_text_buffer_new(null).?;
        c.gtk_text_buffer_set_text(buffer, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_set_enable_undo(buffer, 1);
        c.gtk_text_buffer_set_modified(buffer, @intFromBool(modified));
        self.* = .{ .buffer = buffer };
        return self;
    }
    fn retain(self: *Epoch) *Epoch {
        self.refs += 1;
        return self;
    }
    fn release(self: *Epoch) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.buffer);
            a.destroy(self);
        }
    }
};

pub const Boundary = struct {
    guard: *Guard,
    before: *Epoch,
    after: *Epoch,
    committed: bool = false,
    /// All fallible work precedes canonical validation/mutation. Preparation does
    /// not attach observers, alter undo policy or replace a live typing interval.
    pub fn prepare(target: tx.Target, before: []const u8, after: []const u8) Error!Boundary {
        const guard = if (get(target.buffer)) |existing| blk: {
            try existing.validate(target);
            existing.refs += 1;
            break :blk existing;
        } else try Guard.create(target, before);
        errdefer guard.release();
        const previous = if (guard.reset_needed) try guard.resetEpoch(before) else guard.current.retain();
        errdefer previous.release();
        const next = try Epoch.create(after, true);
        return .{ .guard = guard, .before = previous, .after = next };
    }
    pub fn deinit(self: *Boundary) void {
        self.before.release();
        self.after.release();
        self.guard.release();
    }
    /// Called only by transaction observers AFTER all targets validate.
    pub fn begin(self: *Boundary) void {
        if (!self.committed) {
            self.before.redo_depth = 0;
            self.committed = true;
        }
        self.guard.attach();
        self.guard.suspended = true;
        self.guard.clearPending();
    }
    pub fn end(self: *const Boundary, forward: bool) void {
        const guard = self.guard;
        const next = if (forward) self.after else self.before;
        guard.current.release();
        guard.current = next.retain();
        guard.reset_needed = false;
        copySelection(guard.buffer, next.buffer);

        guard.suspended = false;
    }
};

const Guard = struct {
    refs: usize = 1,
    buffer: *c.GtkTextBuffer, // Borrowed; attached owner is the buffer itself.
    id: u64,
    revision_identity: usize,
    current: *Epoch,
    save_generation: u64 = 1,
    save_generation_exhausted: bool = false,
    // A successful load/save while waiting to replace an unattributed baseline.
    reset_saved: bool = false,
    attached: bool = false,
    suspended: bool = false,
    broken: bool = false,
    // Unattributed programmatic mutations (e.g. reload) establish a new baseline,
    // never an undoable typing action crossing the previous protected interval.
    reset_needed: bool = false,
    user_action: bool = false,
    pending: ?struct { count: c_int, start: c_int, end: c_int, text: [*c]const u8 = null, len: c_int = 0 } = null,

    fn create(target: tx.Target, text: []const u8) !*Guard {
        const self = try a.create(Guard);
        errdefer a.destroy(self);
        self.* = .{ .buffer = target.buffer, .id = target.id, .revision_identity = @intFromPtr(target.revision), .current = try Epoch.create(text, c.gtk_text_buffer_get_modified(target.buffer) != 0) };
        // Before the first boundary canonical GTK is still the authoritative
        // history. Import only an actually clean baseline, never a dirty one.
        if (c.gtk_text_buffer_get_modified(target.buffer) == 0) self.current.saved_generation = self.save_generation;
        copySelection(target.buffer, self.current.buffer);
        return self;
    }
    fn release(self: *Guard) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.current.release();
            a.destroy(self);
        }
    }
    fn attach(self: *Guard) void {
        if (self.attached) return;
        self.attached = true;
        self.refs += 1;
        c.g_object_set_data_full(u.cast(c.GObject, self.buffer), key, self, &destroy);
        u.connect(self.buffer, "insert-text", &insert, self);
        u.connect(self.buffer, "delete-range", &delete, self);
        u.connect(self.buffer, "insert-child-anchor", &object, self);
        u.connect(self.buffer, "insert-paintable", &object, self);
        u.connect(self.buffer, "changed", &changed, self);
        u.connect(self.buffer, "begin-user-action", &beginAction, self);
        u.connect(self.buffer, "end-user-action", &endAction, self);
        u.connect(self.buffer, "mark-set", &markSet, self);
    }
    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        self.attached = false;
        self.release();
    }
    fn validate(self: *Guard, target: tx.Target) Error!void {
        if (target.id != self.id or target.buffer != self.buffer or @intFromPtr(target.revision) != self.revision_identity) return error.TargetMismatch;
        if (self.suspended or self.user_action) return error.Busy;
        if (self.broken) return error.NativeHistoryUnavailable;
    }
    fn clearPending(self: *Guard) void {
        self.pending = null;
    }
    fn insert(buffer: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (self.suspended or self.broken) return;
        const offset = c.gtk_text_iter_get_offset(at);
        self.pending = .{ .count = c.gtk_text_buffer_get_char_count(buffer), .start = offset, .end = offset, .text = text, .len = len };
    }
    fn delete(buffer: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (self.suspended or self.broken) return;
        self.pending = .{ .count = c.gtk_text_buffer_get_char_count(buffer), .start = c.gtk_text_iter_get_offset(start), .end = c.gtk_text_iter_get_offset(end) };
    }
    fn object(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (!self.suspended) self.broken = true;
        self.clearPending();
    }
    fn changed(buffer: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (self.suspended or self.broken) return;
        if (!self.user_action) {
            self.reset_needed = true;
            self.reset_saved = false;
            self.clearPending();
            return;
        }
        const delta = self.pending orelse {
            self.broken = true;
            return;
        };
        self.clearPending();
        const added: i64 = if (delta.text != null) c.g_utf8_strlen(delta.text, delta.len) else 0;
        if (@as(i64, delta.count) + added - (delta.end - delta.start) != c.gtk_text_buffer_get_char_count(buffer) or c.gtk_text_buffer_get_char_count(self.current.buffer) != delta.count) {
            self.broken = true;
            return;
        }
        self.current.redo_depth = 0;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.current.buffer, &start, delta.start);
        if (delta.text != null) {
            c.gtk_text_buffer_insert(self.current.buffer, &start, delta.text, delta.len);
        } else {
            c.gtk_text_buffer_get_iter_at_offset(self.current.buffer, &end, delta.end);
            c.gtk_text_buffer_delete(self.current.buffer, &start, &end);
        }
    }
    fn beginAction(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (self.suspended or self.broken) return;
        if (self.reset_needed) {
            const bytes = snapshot(a, self.buffer, (tx.Limits{}).max_buffer_bytes) catch {
                self.broken = true;
                return;
            };
            defer a.free(bytes);
            const next = self.resetEpoch(bytes) catch {
                self.broken = true;
                return;
            };
            self.current.release();
            self.current = next;
            self.reset_needed = false;
            copySelection(self.buffer, next.buffer);
        }
        self.user_action = true;
        c.gtk_text_buffer_begin_user_action(self.current.buffer);
    }
    fn endAction(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (!self.user_action) return;
        c.gtk_text_buffer_end_user_action(self.current.buffer);
        self.user_action = false;
    }
    fn markSet(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, mark: ?*c.GtkTextMark, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Guard, data.?);
        if (self.suspended or self.broken or self.reset_needed or self.pending != null) return;
        if (mark == c.gtk_text_buffer_get_insert(buffer) or mark == c.gtk_text_buffer_get_selection_bound(buffer)) copySelection(self.buffer, self.current.buffer);
    }
    fn resetEpoch(self: *Guard, text: []const u8) !*Epoch {
        const clean = self.reset_saved and !self.save_generation_exhausted and c.gtk_text_buffer_get_modified(self.buffer) == 0;
        const next = try Epoch.create(text, !clean);
        if (clean) next.saved_generation = self.save_generation;
        return next;
    }
    fn currentIsClean(self: *const Guard) bool {
        return !self.save_generation_exhausted and
            self.current.saved_generation == self.save_generation and
            c.gtk_text_buffer_get_modified(self.current.buffer) == 0;
    }
};
/// Notify after a successful save/load and the canonical modified flag update.
/// `current` means the saved revision is still the current document revision.
/// Even a stale save changes disk identity: invalidate every prior clean marker.
/// Allocation-free/O(1); arbitrary modified-changed signals are NOT save evidence.
/// Before guard installation the canonical modified flag supplies the baseline.
/// Callers must retain their stale-save close protection for unguarded history too.
pub fn recordSavedCheckpoint(buffer: *c.GtkTextBuffer, current: bool) void {
    const guard = get(buffer) orelse return;
    guard.save_generation = std.math.add(u64, guard.save_generation, 1) catch {
        guard.save_generation_exhausted = true;
        return;
    };
    guard.reset_saved = false;
    if (!current or guard.save_generation_exhausted or guard.broken or guard.suspended or guard.user_action) return;
    if (guard.reset_needed) {
        guard.reset_saved = true;
        return;
    }
    c.gtk_text_buffer_set_modified(guard.current.buffer, 0);
    guard.current.saved_generation = guard.save_generation;
}

fn get(buffer: *c.GtkTextBuffer) ?*Guard {
    const data = c.g_object_get_data(u.cast(c.GObject, buffer), key) orelse return null;
    return u.cast(Guard, data);
}
fn selection(buffer: *c.GtkTextBuffer) [2]c_int {
    var insert: c.GtkTextIter = undefined;
    var bound: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(buffer, &insert, c.gtk_text_buffer_get_insert(buffer));
    c.gtk_text_buffer_get_iter_at_mark(buffer, &bound, c.gtk_text_buffer_get_selection_bound(buffer));
    return .{ c.gtk_text_iter_get_offset(&insert), c.gtk_text_iter_get_offset(&bound) };
}
fn select(buffer: *c.GtkTextBuffer, offsets: [2]c_int) void {
    var insert: c.GtkTextIter = undefined;
    var bound: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(buffer, &insert, offsets[0]);
    c.gtk_text_buffer_get_iter_at_offset(buffer, &bound, offsets[1]);
    c.gtk_text_buffer_select_range(buffer, &insert, &bound);
}
fn copySelection(from: *c.GtkTextBuffer, to: *c.GtkTextBuffer) void {
    select(to, selection(from));
}
fn snapshot(allocator: std.mem.Allocator, buffer: *c.GtkTextBuffer, cap: usize) ![]u8 {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    return tx.readRange(allocator, buffer, start, end, cap);
}

const Trace = struct {
    allocator: std.mem.Allocator,
    limits: tx.Limits,
    edits: std.ArrayList(tx.CharacterEdit) = .empty,
    bytes: usize = 0,
    failure: ?Error = null,
    fn deinit(self: *Trace) void {
        for (self.edits.items) |edit| self.allocator.free(edit.text);
        self.edits.deinit(self.allocator);
    }
    fn add(self: *Trace, start: c_int, end: c_int, text: []const u8) Error!void {
        if (self.edits.items.len >= self.limits.max_replacements or text.len > self.limits.max_total_bytes -| self.bytes) return error.LimitExceeded;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.edits.append(self.allocator, .{ .start = start, .end = end, .text = owned });
        self.bytes += text.len;
    }
    fn insert(_: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Trace, data.?);
        if (self.failure != null) return;
        const offset = c.gtk_text_iter_get_offset(at);
        self.add(offset, offset, text[0..@intCast(len)]) catch |err| {
            self.failure = err;
        };
    }
    fn delete(_: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Trace, data.?);
        if (self.failure != null) return;
        self.add(c.gtk_text_iter_get_offset(start), c.gtk_text_iter_get_offset(end), "") catch |err| {
            self.failure = err;
        };
    }
};

/// false means no grouped boundary has ever been installed: the caller may use
/// canonical GTK undo. Otherwise ONLY the private typing stack may drive replay.
/// No observer/revision chain is rewound or legitimized by undoing native typing.
pub fn replay(allocator: std.mem.Allocator, target: tx.Target, redo: bool, limits: tx.Limits) Error!bool {
    const guard = get(target.buffer) orelse return false;
    try guard.validate(target);
    if (guard.reset_needed) return error.NativeHistoryUnavailable;
    if (tx.isApplying() or target.busy) return error.Busy;
    if (!target.writable) return error.ReadOnly;
    if (target.expected_revision != target.revision.*) return error.StaleRevision;
    const shadow = guard.current.buffer;
    if (redo and guard.current.redo_depth == 0) return error.GroupedBoundary;
    if ((if (redo) c.gtk_text_buffer_get_can_redo(shadow) else c.gtk_text_buffer_get_can_undo(shadow)) == 0) return error.GroupedBoundary;
    const before = try snapshot(allocator, shadow, @min(limits.max_buffer_bytes, limits.max_total_bytes));
    defer allocator.free(before);
    const old_selection = selection(shadow);
    const old_modified = c.gtk_text_buffer_get_modified(shadow);
    var trace = Trace{ .allocator = allocator, .limits = limits };
    defer trace.deinit();
    u.connect(shadow, "insert-text", &Trace.insert, &trace);
    u.connect(shadow, "delete-range", &Trace.delete, &trace);
    if (redo) c.gtk_text_buffer_redo(shadow) else c.gtk_text_buffer_undo(shadow);
    _ = c.g_signal_handlers_disconnect_matched(shadow, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, &trace);
    errdefer {
        if (redo) c.gtk_text_buffer_undo(shadow) else c.gtk_text_buffer_redo(shadow);
        select(shadow, old_selection);
        c.gtk_text_buffer_set_modified(shadow, old_modified);
    }
    if (trace.failure) |err| return err;
    const after = try snapshot(allocator, shadow, @min(limits.max_buffer_bytes, limits.max_total_bytes));
    defer allocator.free(after);
    var plan = try tx.prepareSequence(allocator, target, before, after, trace.edits.items, limits);
    defer plan.deinit();
    guard.suspended = true;
    defer guard.suspended = false;
    try plan.commit(&.{target});
    if (redo) guard.current.redo_depth -= 1 else guard.current.redo_depth += 1;
    copySelection(shadow, target.buffer);
    c.gtk_text_buffer_set_modified(target.buffer, @intFromBool(!guard.currentIsClean()));
    return true;
}
