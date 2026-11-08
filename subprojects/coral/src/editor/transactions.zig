//! Revision-checked, in-memory, multi-buffer edit transactions (GTK main thread only).
//!
//! Workflow: resolve canonical documents into `Change.target`, call `prepare`,
//! preview `Prepared.before` / `Prepared.replacement`, then resolve those IDs
//! AGAIN and pass the fresh targets to `Prepared.commit`. Always `deinit` the
//! prepared value, including after errors. Treat it as move-only and its fields
//! as private. Inputs may be freed after prepare; preview slices are borrowed.
//!
//! The owner must increment its revision synchronously on EVERY `changed`
//! signal (including undo/redo), never recycle document IDs, and keep current
//! Target pointers alive for each call. Prepared retains buffers, not documents;
//! commit never dereferences the saved revision pointer. Missing/replaced
//! documents must be omitted/replaced in the fresh target list, not represented
//! by stale pointers. Revisions must be monotonic and must not wrap. No revision
//! is incremented by this module itself. The allocator must outlive Prepared.
//!
//! All validation and Zig allocation precedes mutation. Commit is synchronous,
//! allocation-free in Zig, and opens one GTK user action per edited buffer. It
//! uses ordinary delete/insert, not set_text: unaffected marks/tags and undo
//! history survive. Undo/redo remains PER BUFFER, not workspace-wide. Enable GTK
//! undo before use if required; this module does not change undo configuration.
//! Do not enclose commit in another user/irreversible action if a separate undo
//! step is required. Signal observers can see partial progress across buffers;
//! this is validation atomicity, not isolation from observers.
//!
//! GTK emits synchronous signals and allocates internally (GLib OOM is fatal).
//! Callers must serialize edits on the GTK thread: callbacks may observe changes
//! and advance revisions, but MUST NOT mutate participating buffers, policy,
//! lifetimes, or undo configuration, stop emission, or run a nested main loop.
//! Reentrant calls through this module are rejected as Busy; arbitrary external
//! GTK edits cannot be made atomic by this API. No rollback, disk writes, saves,
//! staging, background-thread access, or registry/view dependency is provided.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Target = struct {
    id: u64,
    buffer: *c.GtkTextBuffer,
    revision: *const u64,
    expected_revision: u64,
    /// Document-level policy, NOT GtkTextTag editability. Noninteractive edits
    /// deliberately bypass per-view/per-tag interactive editing restrictions.
    writable: bool = true,
    busy: bool = false,
};

/// Half-open UTF-8 BYTE offsets in the expected-revision buffer, not GTK
/// character offsets, UTF-16/LSP positions, or grapheme indices. Empty ranges
/// insert; empty text deletes. Unsorted ranges are accepted. Same-start edits
/// involving an insertion are ambiguous and rejected. Adjacent nonempty ranges
/// and insertion at the END of a preceding range are permitted.
pub const Replacement = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

pub const Change = struct {
    target: Target,
    replacements: []const Replacement,
};

pub const Limits = struct {
    max_targets: usize = 128,
    max_replacements: usize = 65_536,
    /// Also limits transient size during descending application, not only the
    /// final result. Always clamped to G_MAXINT for GTK's lengths and offsets.
    max_buffer_bytes: usize = 16 * 1024 * 1024,
    /// Sum of owned snapshot bytes and replacement bytes across all targets.
    /// Metadata is separately bounded by max_targets/max_replacements.
    max_total_bytes: usize = 64 * 1024 * 1024,
};

pub const ValidationError = error{
    Busy,
    ReadOnly,
    StaleRevision,
    DuplicateTarget,
    TargetMismatch,
    AlreadyCommitted,
    OutOfBounds,
    InvalidUtf8,
    InvalidBoundary,
    EmbeddedNul,
    UnsupportedBufferContent,
    DuplicateRange,
    OverlappingRanges,
    AmbiguousInsertion,
    LimitExceeded,
    SnapshotMismatch,
};
pub const PrepareError = ValidationError || std.mem.Allocator.Error;

// A main-thread reentrancy gate, not a cross-thread synchronization primitive.
var active = false;

pub fn isApplying() bool {
    return active;
}

const Operation = struct {
    range: Replacement,
    start_char: c_int = 0,
    end_char: c_int = 0,
};

const Entry = struct {
    target: Target,
    text: []u8,
    operations: []Operation,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        for (self.operations) |op| allocator.free(op.range.text);
        allocator.free(self.operations);
        allocator.free(self.text);
        c.g_object_unref(self.target.buffer);
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    committed: bool = false,

    pub fn deinit(self: *Prepared) void {
        for (self.entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn targetCount(self: *const Prepared) usize {
        return self.entries.len;
    }

    pub fn targetId(self: *const Prepared, index: usize) u64 {
        return self.entries[index].target.id;
    }

    pub fn expectedRevision(self: *const Prepared, index: usize) u64 {
        return self.entries[index].target.expected_revision;
    }

    /// Immutable base snapshot, including invisible text. Actual embedded GTK
    /// paintables/child anchors are rejected; a literal U+FFFC is valid text.
    pub fn before(self: *const Prepared, index: usize) []const u8 {
        return self.entries[index].text;
    }

    pub fn replacementCount(self: *const Prepared, index: usize) usize {
        return self.entries[index].operations.len;
    }

    /// Owned replacement in ascending source order (borrowed, immutable text).
    pub fn replacement(self: *const Prepared, index: usize, edit: usize) Replacement {
        return self.entries[index].operations[edit].range;
    }

    /// Freshly resolved targets in ANY order, exactly one for each prepared ID.
    /// Keep expected_revision at the PREPARED value, not the newly read revision.
    /// Compare ID, buffer identity, revision-source identity AND revision value.
    /// Precommit validation errors leave every buffer untouched and permit retry.
    /// Success consumes the transaction logically; a second commit is rejected.
    pub fn commit(self: *Prepared, current_targets: []const Target) ValidationError!void {
        if (active) return error.Busy;
        if (self.committed) return error.AlreadyCommitted;
        if (current_targets.len != self.entries.len) return error.TargetMismatch;
        try validateUniqueTargets(current_targets);
        for (self.entries) |entry| {
            const current = findTarget(current_targets, entry.target.id) orelse return error.TargetMismatch;
            if (current.buffer != entry.target.buffer or current.revision != entry.target.revision or
                current.expected_revision != entry.target.expected_revision) return error.TargetMismatch;
            try validateTarget(current);
            // Defense in depth against an owner missing a changed signal. Equal
            // text NEVER substitutes for the identity and revision checks above.
            if (!matchesSnapshot(current.buffer, entry.text)) return error.SnapshotMismatch;
        }

        active = true;
        defer active = false;
        self.committed = true;
        // No fallible work beyond this point, including between buffers.
        for (self.entries) |entry| {
            var has_edits = false;
            for (entry.operations) |op| {
                if (!std.mem.eql(u8, entry.text[op.range.start..op.range.end], op.range.text)) {
                    has_edits = true;
                    break;
                }
            }
            if (!has_edits) continue;
            const buffer = entry.target.buffer;
            c.gtk_text_buffer_begin_user_action(buffer);
            var i = entry.operations.len;
            while (i > 0) {
                i -= 1;
                const op = entry.operations[i];
                if (std.mem.eql(u8, entry.text[op.range.start..op.range.end], op.range.text)) continue;
                var start: c.GtkTextIter = undefined;
                var end: c.GtkTextIter = undefined;
                c.gtk_text_buffer_get_iter_at_offset(buffer, &start, op.start_char);
                if (op.start_char != op.end_char) {
                    c.gtk_text_buffer_get_iter_at_offset(buffer, &end, op.end_char);
                    c.gtk_text_buffer_delete(buffer, &start, &end);
                }
                if (op.range.text.len != 0) {
                    c.gtk_text_buffer_insert(buffer, &start, op.range.text.ptr, @intCast(op.range.text.len));
                }
            }
            c.gtk_text_buffer_end_user_action(buffer);
        }
    }
};

/// Captures source snapshots, validates every edit, copies replacement text,
/// sorts ranges, and precomputes GTK character offsets. Never changes a buffer.
/// Empty transactions and targets with no edits are valid (and still checked).
pub fn prepare(allocator: std.mem.Allocator, changes: []const Change, limits: Limits) PrepareError!Prepared {
    if (active) return error.Busy;
    if (changes.len > limits.max_targets) return error.LimitExceeded;
    var edit_count: usize = 0;
    var bytes: usize = 0;
    for (changes, 0..) |change, i| {
        try validateTarget(change.target);
        for (changes[0..i]) |previous| {
            if (aliases(previous.target, change.target)) return error.DuplicateTarget;
        }
        try addWithin(&edit_count, change.replacements.len, limits.max_replacements);
        for (change.replacements) |edit| {
            try addWithin(&bytes, edit.text.len, limits.max_total_bytes);
            if (edit.text.len > bufferLimit(limits)) return error.LimitExceeded;
            try validateText(edit.text);
        }
    }
    const entries = try allocator.alloc(Entry, changes.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    for (changes, entries) |change, *entry| {
        entry.* = try prepareEntry(allocator, change, limits, &bytes);
        initialized += 1;
    }
    return .{ .allocator = allocator, .entries = entries };
}

fn prepareEntry(allocator: std.mem.Allocator, change: Change, limits: Limits, bytes: *usize) PrepareError!Entry {
    const text = try snapshot(allocator, change.target.buffer, @min(bufferLimit(limits), limits.max_total_bytes - bytes.*));
    errdefer allocator.free(text);
    try addWithin(bytes, text.len, limits.max_total_bytes);
    const operations = try allocator.alloc(Operation, change.replacements.len);
    var initialized: usize = 0;
    errdefer {
        for (operations[0..initialized]) |op| allocator.free(op.range.text);
        allocator.free(operations);
    }
    for (change.replacements, operations) |edit, *op| {
        if (edit.start > edit.end or edit.end > text.len) return error.OutOfBounds;
        if (!isBoundary(text, edit.start) or !isBoundary(text, edit.end)) return error.InvalidBoundary;
        op.* = .{ .range = .{ .start = edit.start, .end = edit.end, .text = try allocator.dupe(u8, edit.text) } };
        initialized += 1;
    }
    std.mem.sort(Operation, operations, {}, struct {
        fn lessThan(_: void, a: Operation, b: Operation) bool {
            if (a.range.start == b.range.start) return a.range.end < b.range.end;
            return a.range.start < b.range.start;
        }
    }.lessThan);
    var byte: usize = 0;
    var char: c_int = 0;
    for (operations, 0..) |*op, i| {
        const range = op.range;
        if (i != 0) {
            const previous = operations[i - 1].range;
            if (range.start == previous.start) {
                if (range.start == range.end or previous.start == previous.end) return error.AmbiguousInsertion;
                if (range.end == previous.end) return error.DuplicateRange;
            }
            if (range.start < previous.end) return error.OverlappingRanges;
        }
        advance(text, &byte, &char, range.start);
        op.start_char = char;
        advance(text, &byte, &char, range.end);
        op.end_char = char;
    }
    var size = text.len;
    var i = operations.len;
    while (i > 0) {
        i -= 1;
        const range = operations[i].range;
        size -= range.end - range.start;
        try addWithin(&size, range.text.len, bufferLimit(limits));
    }
    _ = c.g_object_ref(change.target.buffer);
    return .{ .target = change.target, .text = text, .operations = operations };
}

fn bufferLimit(limits: Limits) usize {
    return @min(limits.max_buffer_bytes, std.math.maxInt(c_int));
}

fn addWithin(total: *usize, amount: usize, cap: usize) error{LimitExceeded}!void {
    if (total.* > cap or amount > cap - total.*) return error.LimitExceeded;
    total.* += amount;
}

fn validateTarget(target: Target) ValidationError!void {
    if (target.busy) return error.Busy;
    if (!target.writable) return error.ReadOnly;
    if (target.revision.* != target.expected_revision) return error.StaleRevision;
}

fn aliases(a: Target, b: Target) bool {
    return a.id == b.id or a.buffer == b.buffer or a.revision == b.revision;
}

fn validateUniqueTargets(targets: []const Target) ValidationError!void {
    for (targets, 0..) |target, i| {
        for (targets[0..i]) |previous| {
            if (aliases(target, previous)) return error.DuplicateTarget;
        }
    }
}

fn findTarget(targets: []const Target, id: u64) ?Target {
    for (targets) |target| if (target.id == id) return target;
    return null;
}

fn validateText(text: []const u8) ValidationError!void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}

fn isBoundary(text: []const u8, byte: usize) bool {
    return byte == text.len or text[byte] & 0xc0 != 0x80;
}

fn advance(text: []const u8, byte: *usize, char: *c_int, end: usize) void {
    while (byte.* < end) {
        byte.* += std.unicode.utf8ByteSequenceLength(text[byte.*]) catch unreachable;
        char.* += 1;
    }
}

fn iterBytes(iter: *const c.GtkTextIter, out: *[4]u8) ValidationError!usize {
    if (c.gtk_text_iter_get_child_anchor(iter) != null or c.gtk_text_iter_get_paintable(iter) != null)
        return error.UnsupportedBufferContent;
    const char = c.gtk_text_iter_get_char(iter);
    if (char == 0) return error.EmbeddedNul;
    if (char > 0x10ffff) return error.InvalidUtf8;
    return std.unicode.utf8Encode(@intCast(char), out) catch return error.InvalidUtf8;
}

// Two bounded iterator walks avoid GTK's unbounded get_text allocation and do
// not omit invisible text or silently omit embedded objects from byte offsets.
fn snapshot(allocator: std.mem.Allocator, buffer: *c.GtkTextBuffer, cap: usize) PrepareError![]u8 {
    if (@as(usize, @intCast(c.gtk_text_buffer_get_char_count(buffer))) > cap) return error.LimitExceeded;
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_start_iter(buffer, &iter);
    var size: usize = 0;
    var encoded: [4]u8 = undefined;
    while (c.gtk_text_iter_is_end(&iter) == 0) {
        try addWithin(&size, try iterBytes(&iter, &encoded), cap);
        _ = c.gtk_text_iter_forward_char(&iter);
    }
    const text = try allocator.alloc(u8, size);
    errdefer allocator.free(text);
    c.gtk_text_buffer_get_start_iter(buffer, &iter);
    var offset: usize = 0;
    while (c.gtk_text_iter_is_end(&iter) == 0) {
        const len = try iterBytes(&iter, &encoded);
        @memcpy(text[offset..][0..len], encoded[0..len]);
        offset += len;
        _ = c.gtk_text_iter_forward_char(&iter);
    }
    return text;
}

fn matchesSnapshot(buffer: *c.GtkTextBuffer, text: []const u8) bool {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_start_iter(buffer, &iter);
    var offset: usize = 0;
    var encoded: [4]u8 = undefined;
    while (c.gtk_text_iter_is_end(&iter) == 0) {
        const len = iterBytes(&iter, &encoded) catch return false;
        if (len > text.len - offset or !std.mem.eql(u8, text[offset..][0..len], encoded[0..len])) return false;
        offset += len;
        _ = c.gtk_text_iter_forward_char(&iter);
    }
    return offset == text.len;
}

test {
    _ = @import("transaction_tests.zig");
}
