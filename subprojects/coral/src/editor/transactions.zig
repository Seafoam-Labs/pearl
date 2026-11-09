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
    noop: bool = false,
};

const Entry = struct {
    target: Target,
    text: []u8,
    operations: []Operation,
    sequential: bool = false,

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
        return self.commitObserved(current_targets, null);
    }
    /// Preallocated bookkeeping only: observers must not mutate text, policy or
    /// lifetimes, allocate fallibly, or reenter. Neither runs on validation failure.
    pub const Observer = struct {
        context: *anyopaque,
        begin: *const fn (*anyopaque) void,
        end: *const fn (*anyopaque) void,
    };
    pub fn commitObserved(self: *Prepared, current_targets: []const Target, observer: ?Observer) ValidationError!void {
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
        if (observer) |o| o.begin(o.context);
        defer if (observer) |o| o.end(o.context);
        for (self.entries) |entry| {
            var has_edits = false;
            for (entry.operations) |op| {
                if (!op.noop and (entry.sequential or !std.mem.eql(u8, entry.text[op.range.start..op.range.end], op.range.text))) {
                    has_edits = true;
                    break;
                }
            }
            if (!has_edits) continue;
            const buffer = entry.target.buffer;
            c.gtk_text_buffer_begin_user_action(buffer);
            for (0..entry.operations.len) |i| {
                const op = entry.operations[if (entry.sequential) i else entry.operations.len - 1 - i];
                if (op.noop or (!entry.sequential and std.mem.eql(u8, entry.text[op.range.start..op.range.end], op.range.text))) continue;
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

/// Ordered GTK undo trace: positions are characters in the state immediately
/// before each step. Pre-simulate EVERY step and compare exact initial/final text
/// before allowing commit; this preserves real edit locations in repeated text
/// and disjoint actions instead of guessing them from a common-prefix text diff.
pub const CharacterEdit = struct { start: c_int, end: c_int, text: []const u8 };
pub fn prepareSequence(allocator: std.mem.Allocator, target: Target, before: []const u8, after: []const u8, edits: []const CharacterEdit, limits: Limits) PrepareError!Prepared {
    if (edits.len > limits.max_replacements) return error.LimitExceeded;
    var plan = try prepare(allocator, &.{.{ .target = target, .replacements = &.{} }}, limits);
    errdefer plan.deinit();
    if (!std.mem.eql(u8, plan.before(0), before)) return error.SnapshotMismatch;
    var working = try allocator.dupe(u8, before);
    defer allocator.free(working);
    const operations = try allocator.alloc(Operation, edits.len);
    var initialized: usize = 0;
    errdefer {
        for (operations[0..initialized]) |op| allocator.free(op.range.text);
        allocator.free(operations);
    }
    var owned = before.len;
    for (edits, operations) |edit, *op| {
        if (edit.start < 0 or edit.end < edit.start) return error.OutOfBounds;
        try validateText(edit.text);
        try addWithin(&owned, edit.text.len, limits.max_total_bytes);
        const start = try byteAtCharacter(working, edit.start);
        const end = try byteAtCharacter(working, edit.end);
        var size = working.len - (end - start);
        try addWithin(&size, edit.text.len, bufferLimit(limits));
        op.* = .{ .range = .{ .start = start, .end = end, .text = try allocator.dupe(u8, edit.text) }, .start_char = edit.start, .end_char = edit.end, .noop = std.mem.eql(u8, working[start..end], edit.text) };
        initialized += 1;
        const next = try allocator.alloc(u8, size);
        @memcpy(next[0..start], working[0..start]);
        @memcpy(next[start..][0..edit.text.len], edit.text);
        @memcpy(next[start + edit.text.len ..], working[end..]);
        allocator.free(working);
        working = next;
    }
    if (!std.mem.eql(u8, working, after)) return error.SnapshotMismatch;
    allocator.free(plan.entries[0].operations);
    plan.entries[0].operations = operations;
    plan.entries[0].sequential = true;
    return plan;
}
fn byteAtCharacter(text: []const u8, character: c_int) ValidationError!usize {
    var byte: usize = 0;
    var n: c_int = 0;
    while (n < character) : (n += 1) {
        if (byte == text.len) return error.OutOfBounds;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch return error.InvalidUtf8;
    }
    return byte;
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

// Read backwards with both GTK byte/character caches populated. Large forward
// character jumps discard the byte cache: each following slice then rescans the
// giant UTF-8 segment prefix, making a whole-buffer read quadratic. GTK's public
// backward_chars preserves byte offsets within segments and walks back from the
// cached byte position. Crossing a segment may rescan that segment once.
// At most 64 KiB + NUL of GLib scratch exists at a time. get_slice includes hidden
// text AND object placeholders, unlike get_text which silently omits objects.
const Chunk = struct {
    text: [:0]u8,
    fn read(buffer: *c.GtkTextBuffer, iter: *c.GtkTextIter, limit: *const c.GtkTextIter) ValidationError!Chunk {
        const remaining = c.gtk_text_iter_get_offset(iter) - c.gtk_text_iter_get_offset(limit);
        const step = @min(16 * 1024, remaining);
        _ = c.gtk_text_iter_get_line_index(iter);
        const end = iter.*;
        _ = c.gtk_text_iter_backward_chars(iter, step);
        _ = c.gtk_text_iter_get_line_index(iter);
        const text = std.mem.span(c.gtk_text_buffer_get_slice(buffer, iter, &end, 1));
        errdefer c.g_free(text.ptr);
        try validateText(text);
        const count = std.unicode.utf8CountCodepoints(text) catch return error.InvalidUtf8;
        if (count != @as(usize, @intCast(step))) return error.UnsupportedBufferContent;
        // A literal U+FFFC is valid source. Only these candidate positions need
        // GTK object queries; rejecting the codepoint itself would corrupt that
        // distinction, including during commit's missed-revision defense.
        var at = end;
        var scanned = text.len;
        while (std.mem.lastIndexOf(u8, text[0..scanned], "\xef\xbf\xbc")) |index| {
            _ = c.gtk_text_iter_get_line_index(&at);
            _ = c.gtk_text_iter_backward_chars(&at, @intCast(std.unicode.utf8CountCodepoints(text[index..scanned]) catch unreachable));
            if (c.gtk_text_iter_get_child_anchor(&at) != null or c.gtk_text_iter_get_paintable(&at) != null) return error.UnsupportedBufferContent;
            scanned = index;
        }
        return .{ .text = text };
    }
    fn deinit(self: Chunk) void {
        c.g_free(self.text.ptr);
    }
};

fn snapshot(allocator: std.mem.Allocator, buffer: *c.GtkTextBuffer, cap: usize) PrepareError![]u8 {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &end);
    return readRange(allocator, buffer, start, end, cap);
}

/// Checked, owned bytes for a bounded presentation range. Does not validate text
/// outside that range; transaction prepare/commit always read the FULL target.
/// All GTK content must remain serialized for the duration of this call.
pub fn readRange(allocator: std.mem.Allocator, buffer: *c.GtkTextBuffer, start: c.GtkTextIter, end: c.GtkTextIter, cap: usize) PrepareError![]u8 {
    if (c.gtk_text_iter_get_buffer(&start) != buffer or c.gtk_text_iter_get_buffer(&end) != buffer) return error.TargetMismatch;
    const count = c.gtk_text_iter_get_offset(&end) - c.gtk_text_iter_get_offset(&start);
    if (count < 0) return error.OutOfBounds;
    if (@as(usize, @intCast(count)) > cap) return error.LimitExceeded;
    var iter = start;
    var size: usize = 0;
    // GTK's line byte metadata sizes the allocation without reading/validating
    // every byte twice. Include invisible text and object placeholders here;
    // the bounded slice pass below still validates ALL content before mutation.
    // This also avoids speculative 4x-character allocations or grow/copy buffers.
    const last_line = c.gtk_text_iter_get_line(&end);
    while (c.gtk_text_iter_get_line(&iter) < last_line) {
        const bytes = @as(i64, c.gtk_text_iter_get_bytes_in_line(&iter)) - c.gtk_text_iter_get_line_index(&iter);
        if (bytes < 0) return error.LimitExceeded;
        try addWithin(&size, @intCast(bytes), cap);
        _ = c.gtk_text_iter_forward_line(&iter);
    }
    const remainder = @as(i64, c.gtk_text_iter_get_line_index(&end)) - c.gtk_text_iter_get_line_index(&iter);
    if (remainder < 0) return error.LimitExceeded;
    try addWithin(&size, @intCast(remainder), cap);
    const text = try allocator.alloc(u8, size);
    errdefer allocator.free(text);
    iter = end;
    var offset = text.len;
    while (c.gtk_text_iter_compare(&iter, &start) > 0) {
        const chunk = try Chunk.read(buffer, &iter, &start);
        defer chunk.deinit();
        if (chunk.text.len > offset) return error.SnapshotMismatch;
        offset -= chunk.text.len;
        @memcpy(text[offset..][0..chunk.text.len], chunk.text);
    }
    if (offset != 0) return error.SnapshotMismatch;
    return text;
}

fn matchesSnapshot(buffer: *c.GtkTextBuffer, text: []const u8) bool {
    if (@as(usize, @intCast(c.gtk_text_buffer_get_char_count(buffer))) > text.len) return false;
    var start: c.GtkTextIter = undefined;
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(buffer, &start, &iter);
    var offset = text.len;
    while (c.gtk_text_iter_compare(&iter, &start) > 0) {
        const chunk = Chunk.read(buffer, &iter, &start) catch return false;
        defer chunk.deinit();
        if (chunk.text.len > offset) return false;
        offset -= chunk.text.len;
        if (!std.mem.eql(u8, text[offset..][0..chunk.text.len], chunk.text)) return false;
    }
    return offset == 0;
}

test {
    _ = @import("transaction_tests.zig");
}
