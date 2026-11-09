//! Safe grouped BUFFER undo, not disk undo. GTK-thread-only; inherits transactions'
//! synchronous observer/serialization contract. Resolve fresh Targets for every call;
//! never recycle IDs. No document pointers are retained. Revisions must advance on
//! every changed signal, including native undo. Parent checkpoints the full recovery
//! session AFTER successful perform/commit/undo/redo, not between changed signals.
//!
//! Move-only owners. prepare(label, changes) supports previews; commit(&pending,
//! fresh_targets) records only successful operations. perform is the synchronous
//! convenience path. undo/redo accept a fresh registry slice (unrelated IDs allowed).
//! Failure changes neither buffers nor the history cursor/redo branch. Native edits
//! (even edit + native undo) invalidate older history rather than being overwritten.
const std = @import("std");
const c = @import("../c.zig").c;
const tx = @import("transactions.zig");
const native = @import("native_history.zig");
pub const Target = tx.Target;
pub const Change = tx.Change;
pub const Error = native.Error || error{ NothingToUndo, NothingToRedo, HistoryLimit };
pub const Limits = struct {
    max_records: usize = 100,
    /// Owned snapshots, native interval baseline text, deltas, entries and labels;
    /// GTK undo-node overhead is additional. Array capacity is additionally
    /// bounded by max_records. Pending plans/transient transactions have tx limits.
    max_bytes: usize = 64 * 1024 * 1024,
    transaction: tx.Limits = .{},
};
pub const Delta = struct { before_start: usize, before_end: usize, after_start: usize, after_end: usize };
pub const Entry = struct {
    id: u64,
    buffer: *c.GtkTextBuffer,
    revision_identity: usize,
    before_revision: u64,
    after_revision: u64 = 0,
    guard_revision: u64,
    before: []u8,
    after: []u8,
    deltas: []Delta,
    native_boundary: ?native.Boundary = null,

    fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.before);
        a.free(self.after);
        a.free(self.deltas);
        if (self.native_boundary) |*boundary| boundary.deinit();
        c.g_object_unref(self.buffer);
    }
};
pub const Record = struct {
    label: []u8,
    entries: []Entry,
    bytes: usize,
    fn deinit(self: *Record, a: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(a);
        a.free(self.entries);
        a.free(self.label);
    }
};
pub const Pending = struct {
    plan: tx.Prepared,
    record: ?Record,
    pub fn deinit(self: *Pending) void {
        if (self.record) |*record| record.deinit(self.plan.allocator);
        self.plan.deinit();
        self.* = undefined;
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    records: std.ArrayList(Record) = .empty,
    cursor: usize = 0,
    bytes: usize = 0,
    active: bool = false,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) History {
        return .{ .allocator = allocator, .limits = limits };
    }
    pub fn deinit(self: *History) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn canUndo(self: *const History) bool {
        return self.cursor != 0;
    }
    pub fn canRedo(self: *const History) bool {
        return self.cursor < self.records.items.len;
    }
    /// Borrowed attribution and exact deltas; invalidated by subsequent history calls.
    pub fn undoRecord(self: *const History) ?*const Record {
        return if (self.canUndo()) &self.records.items[self.cursor - 1] else null;
    }
    pub fn redoRecord(self: *const History) ?*const Record {
        return if (self.canRedo()) &self.records.items[self.cursor] else null;
    }
    pub fn prepare(self: *History, label: []const u8, changes: []const Change) Error!Pending {
        if (self.active or tx.isApplying()) return error.Busy;
        var plan = try tx.prepare(self.allocator, changes, self.limits.transaction);
        errdefer plan.deinit();
        const record = try makeRecord(self.allocator, label, &plan, changes, self.limits);
        return .{ .plan = plan, .record = record };
    }
    /// Fresh targets must contain exactly the pending IDs, with prepared revisions.
    /// Pending must originate from this allocator and is always deinitialized by caller.
    pub fn commit(self: *History, pending: *Pending, targets: []const Target) Error!void {
        if (self.active or tx.isApplying()) return error.Busy;
        self.active = true;
        defer self.active = false;
        if (pending.plan.committed) return error.AlreadyCommitted;
        if (pending.record) |record| {
            if (self.limits.max_records == 0 or record.bytes > self.limits.max_bytes) return error.HistoryLimit;
            // Reserve BEFORE mutation, but never grow the list past its count cap.
            try self.records.ensureTotalCapacity(self.allocator, @min(self.records.items.len + 1, self.limits.max_records));
        }
        var observation = Observation{ .record = if (pending.record) |*record| record else null, .forward = true };
        try pending.plan.commitObserved(targets, observation.observer());
        if (pending.record) |*record| {
            self.advanceGuards(targets);
            for (record.entries) |*entry| {
                const target = find(targets, entry.id).?;
                entry.after_revision = target.revision.*;
                entry.guard_revision = target.revision.*;
            }
            while (self.records.items.len > self.cursor) self.dropLast();
            while (self.records.items.len >= self.limits.max_records or self.bytes > self.limits.max_bytes - record.bytes) {
                var oldest = self.records.orderedRemove(0);
                self.bytes -= oldest.bytes;
                oldest.deinit(self.allocator);
                self.cursor -= 1;
            }
            self.bytes += record.bytes;
            self.records.appendAssumeCapacity(record.*);
            self.cursor += 1;
            pending.record = null;
        }
    }
    pub fn perform(self: *History, label: []const u8, changes: []const Change) Error!void {
        var pending = try self.prepare(label, changes);
        defer pending.deinit();
        const targets = try self.allocator.alloc(Target, changes.len);
        defer self.allocator.free(targets);
        for (changes, targets) |change, *target| target.* = change.target;
        try self.commit(&pending, targets);
    }
    pub fn undo(self: *History, targets: []const Target) Error!void {
        if (!self.canUndo()) return error.NothingToUndo;
        try self.replay(targets, false);
    }
    pub fn redo(self: *History, targets: []const Target) Error!void {
        if (!self.canRedo()) return error.NothingToRedo;
        try self.replay(targets, true);
    }
    /// Returns false only for a buffer never protected by grouped history.
    /// A true result is a checked native-typing replay, not canonical GTK undo.
    pub fn replayNative(self: *History, target: Target, forward: bool) Error!bool {
        if (self.active or tx.isApplying()) return error.Busy;
        self.active = true;
        defer self.active = false;
        return native.replay(self.allocator, target, forward, self.limits.transaction);
    }
    fn replay(self: *History, targets: []const Target, forward: bool) Error!void {
        if (self.active or tx.isApplying()) return error.Busy;
        self.active = true;
        defer self.active = false;
        const record = &self.records.items[if (forward) self.cursor else self.cursor - 1];
        const changes = try self.allocator.alloc(Change, record.entries.len);
        defer self.allocator.free(changes);
        const fresh = try self.allocator.alloc(Target, record.entries.len);
        defer self.allocator.free(fresh);
        var initialized: usize = 0;
        defer for (changes[0..initialized]) |change| self.allocator.free(change.replacements);
        for (record.entries, changes, fresh) |entry, *change, *target| {
            target.* = try resolve(targets, entry);
            const edits = try self.allocator.alloc(tx.Replacement, entry.deltas.len);
            for (entry.deltas, edits) |delta, *edit| {
                edit.* = if (forward) .{ .start = delta.before_start, .end = delta.before_end, .text = entry.after[delta.after_start..delta.after_end] } else .{ .start = delta.after_start, .end = delta.after_end, .text = entry.before[delta.before_start..delta.before_end] };
            }
            change.* = .{ .target = target.*, .replacements = edits };
            initialized += 1;
        }
        var plan = try tx.prepare(self.allocator, changes, self.limits.transaction);
        defer plan.deinit();
        for (record.entries, 0..) |entry, i| {
            if (!std.mem.eql(u8, plan.before(i), if (forward) entry.before else entry.after)) return error.SnapshotMismatch;
        }
        var observation = Observation{ .record = record, .forward = forward };
        try plan.commitObserved(fresh, observation.observer());
        self.advanceGuards(fresh);
        if (forward) self.cursor += 1 else self.cursor -= 1;
    }
    // Advance only unbroken revision chains attributable to THIS history. A newer
    // external edit can never be legitimized by a later workspace operation.
    fn advanceGuards(self: *History, targets: []const Target) void {
        for (self.records.items) |*record| for (record.entries) |*entry| {
            const target = find(targets, entry.id) orelse continue;
            if (entry.buffer == target.buffer and entry.revision_identity == @intFromPtr(target.revision) and entry.guard_revision == target.expected_revision)
                entry.guard_revision = target.revision.*;
        };
    }
    fn dropLast(self: *History) void {
        var record = self.records.pop().?;
        self.bytes -= record.bytes;
        record.deinit(self.allocator);
    }
};
const Observation = struct {
    record: ?*Record,
    forward: bool,
    fn observer(self: *Observation) tx.Prepared.Observer {
        return .{ .context = self, .begin = begin, .end = end };
    }
    fn begin(context: *anyopaque) void {
        const self: *Observation = @ptrCast(@alignCast(context));
        if (self.record) |record| for (record.entries) |*entry| {
            if (entry.native_boundary) |*boundary| boundary.begin();
        };
    }
    fn end(context: *anyopaque) void {
        const self: *Observation = @ptrCast(@alignCast(context));
        if (self.record) |record| for (record.entries) |*entry| {
            if (entry.native_boundary) |*boundary| boundary.end(self.forward);
        };
    }
};
fn find(targets: []const Target, id: u64) ?Target {
    for (targets) |target| if (target.id == id) return target;
    return null;
}
fn resolve(targets: []const Target, entry: Entry) Error!Target {
    var result: ?Target = null;
    for (targets) |target| if (target.id == entry.id) {
        if (result != null) return error.DuplicateTarget;
        result = target;
    };
    var target = result orelse return error.TargetMismatch;
    if (target.buffer != entry.buffer or @intFromPtr(target.revision) != entry.revision_identity) return error.TargetMismatch;
    if (target.revision.* != entry.guard_revision) return error.StaleRevision;
    target.expected_revision = entry.guard_revision;
    return target;
}
fn charge(bytes: *usize, n: usize, cap: usize) Error!void {
    if (n > cap -| bytes.*) return error.HistoryLimit;
    bytes.* += n;
}
fn makeRecord(a: std.mem.Allocator, label: []const u8, plan: *const tx.Prepared, changes: []const Change, limits: Limits) Error!?Record {
    var changed = false;
    for (0..plan.targetCount()) |i| for (0..plan.replacementCount(i)) |j| {
        const r = plan.replacement(i, j);
        if (!std.mem.eql(u8, plan.before(i)[r.start..r.end], r.text)) changed = true;
    };
    if (!changed) return null;
    if (limits.max_records == 0) return error.HistoryLimit;
    var bytes: usize = @sizeOf(Record);
    try charge(&bytes, label.len, limits.max_bytes);
    try charge(&bytes, changes.len * @sizeOf(Entry), limits.max_bytes);
    const owned_label = try a.dupe(u8, label);
    errdefer a.free(owned_label);
    const entries = try a.alloc(Entry, changes.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(a);
        a.free(entries);
    }
    for (entries, changes, 0..) |*entry, change, i| {
        entry.* = try makeEntry(a, plan, i, change.target, &bytes, limits.max_bytes);
        initialized += 1;
    }
    return .{ .label = owned_label, .entries = entries, .bytes = bytes };
}
fn makeEntry(a: std.mem.Allocator, plan: *const tx.Prepared, i: usize, target: Target, bytes: *usize, cap: usize) Error!Entry {
    const base = plan.before(i);
    var size = base.len;
    var groups: usize = 0;
    var last_end: ?usize = null;
    for (0..plan.replacementCount(i)) |j| {
        const r = plan.replacement(i, j);
        size = size - (r.end - r.start) + r.text.len;
        if (last_end == null or last_end.? != r.start) groups += 1;
        last_end = r.end;
    }
    try charge(bytes, base.len, cap);
    try charge(bytes, size, cap);
    try charge(bytes, groups * @sizeOf(Delta), cap);
    const before = try a.dupe(u8, base);
    errdefer a.free(before);
    const after = try a.alloc(u8, size);
    errdefer a.free(after);
    const deltas = try a.alloc(Delta, groups);
    errdefer a.free(deltas);
    var source: usize = 0;
    var dest: usize = 0;
    var n: usize = 0;
    for (0..plan.replacementCount(i)) |j| {
        const r = plan.replacement(i, j);
        const gap = r.start - source;
        @memcpy(after[dest..][0..gap], before[source..r.start]);
        dest += gap;
        const start = dest;
        @memcpy(after[dest..][0..r.text.len], r.text);
        dest += r.text.len;
        // Adjacent deletions become coincident inverse insertions. Coalesce the
        // adjacent group so BOTH directions remain valid unambiguous tx ranges.
        if (n != 0 and deltas[n - 1].before_end == r.start) {
            deltas[n - 1].before_end = r.end;
            deltas[n - 1].after_end = dest;
        } else {
            deltas[n] = .{ .before_start = r.start, .before_end = r.end, .after_start = start, .after_end = dest };
            n += 1;
        }
        source = r.end;
    }
    @memcpy(after[dest..], before[source..]);
    const boundary = if (!std.mem.eql(u8, before, after)) blk: {
        // Conservatively charge both baselines even when an older record shares
        // the before interval. Native GTK history is never disabled or cleared.
        try charge(bytes, before.len, cap);
        try charge(bytes, after.len, cap);
        break :blk try native.Boundary.prepare(target, before, after);
    } else null;
    _ = c.g_object_ref(target.buffer);
    return .{ .id = target.id, .buffer = target.buffer, .revision_identity = @intFromPtr(target.revision), .before_revision = target.expected_revision, .guard_revision = target.expected_revision, .before = before, .after = after, .deltas = deltas, .native_boundary = boundary };
}

test {
    _ = @import("history_tests.zig");
}
