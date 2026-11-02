//! Independent, single-owner clipboard history. No Wayland, GTK, clocks or I/O.
//! Callers provide trusted epoch seconds and prune before exposing borrowed views.
const std = @import("std");
const policy = @import("../clipboard_policy.zig");

pub const Kind = policy.Kind;
pub const entries_limit = 100;
pub const total_limit = policy.total_limit;
pub const text_limit = policy.text_limit;
pub const lifetime_seconds: i64 = 604800;
pub const Error = error{ InvalidPayload, InvalidTime, CounterExhausted, OutOfMemory };

pub const Entry = struct {
    id: u64,
    kind: Kind,
    bytes: []const u8,
    last_copy: i64,
    sequence: u64 = 0,
};

/// Borrowed future persistence input. Runtime IDs and PNGs are deliberately absent.
pub const TextRecord = struct { bytes: []const u8, last_copy: i64 };
pub const TextIterator = struct {
    remaining: []const Entry,

    pub fn next(self: *TextIterator) ?TextRecord {
        while (self.remaining.len != 0) {
            const entry = self.remaining[0];
            self.remaining = self.remaining[1..];
            if (entry.kind == .text) return .{ .bytes = entry.bytes, .last_copy = entry.last_copy };
        }
        return null;
    }
};

/// Owns exact-size payload allocations, with fixed metadata for at most 100 rows.
/// Do not copy a live History by value. All views/iterators are borrowed until the
/// next mutation; a future asynchronous writer must acquire independent ownership.
pub const History = struct {
    allocator: std.mem.Allocator,
    rows: [entries_limit]Entry = undefined,
    len: usize = 0,
    total_bytes: usize = 0,
    next_id: u64 = 1,
    next_sequence: u64 = 1,
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.clear();
    }

    pub fn entries(self: *const History) []const Entry {
        return self.rows[0..self.len];
    }

    /// Does not sample time or prune. Prune before reading a projection. This is
    /// a synchronous borrowed iterator, not an owned background-save snapshot.
    pub fn textRecords(self: *const History) TextIterator {
        return .{ .remaining = self.entries() };
    }

    /// Duplicates caller bytes; never consumes or modifies input, even on error.
    /// PNG input MUST already be canonical output of clipboard.zig's sanitizer.
    /// policy.valid is only the existing bounded header check, not PNG decoding.
    /// All fallible work precedes pruning/eviction, so failure leaves rows, IDs,
    /// timestamps and ownership unchanged. A successful copy prunes first, then
    /// refreshes a live duplicate or inserts at the front, including equal times.
    pub fn copy(self: *History, kind: Kind, bytes: []const u8, now: i64) Error!u64 {
        var prepared = try self.prepareCopy(kind, bytes, now);
        defer prepared.discard();
        const id = prepared.result_id.?;
        prepared.commit();
        return id;
    }

    /// Inserts with the saved copy time, never the load time. May be called in
    /// any timestamp order; equal times preserve input order. Duplicate restored
    /// text keeps the newer saved time and its live ID. Returns null for expired
    /// text or a record too old to fit the retained newest prefix. This inserts
    /// one record atomically; whole-file validation/install belongs to the loader.
    pub fn restoreText(self: *History, bytes: []const u8, last_copy: i64, now: i64) Error!?u64 {
        const result = try self.retain(.text, bytes, last_copy, now, false);
        self.generation +|= 1;
        return result;
    }

    pub fn prune(self: *History, now: i64) Error!usize {
        var prepared = try self.preparePrune(now);
        defer prepared.discard();
        const removed = self.len - prepared.len;
        if (removed != 0) prepared.commit();
        return removed;
    }

    pub fn delete(self: *History, id: u64) bool {
        for (self.entries(), 0..) |entry, index| {
            if (entry.id == id) {
                self.remove(index);
                self.generation +|= 1;
                return true;
            }
        }
        return false;
    }

    /// Destruction is independent of clock/counter availability. IDs are never
    /// reset here, so stale actions cannot address a later newly copied value.
    pub fn clear(self: *History) void {
        while (self.len != 0) self.remove(self.len - 1);
        self.generation +|= 1;
    }

    /// Candidate metadata borrows existing payloads. Only a new copy allocates;
    /// abort releases only that candidate. No live eviction occurs until commit.
    /// The owning main context must not yield or mutate History before commit.
    pub const Prepared = struct {
        owner: *History,
        base: u64,
        rows: [entries_limit]Entry = undefined,
        len: usize = 0,
        total_bytes: usize = 0,
        next_id: u64,
        next_sequence: u64,
        result_id: ?u64 = null,
        new_payload: ?[]u8 = null,
        consumed: bool = false,
        pub fn entries(self: *const Prepared) []const Entry {
            return self.rows[0..self.len];
        }
        pub fn discard(self: *Prepared) void {
            if (self.consumed) return;
            if (self.new_payload) |bytes| self.owner.wipe(bytes);
            self.new_payload = null;
            self.consumed = true;
        }
        pub fn commit(self: *Prepared) void {
            std.debug.assert(!self.consumed and self.owner.generation == self.base);
            for (self.owner.entries()) |old| {
                var retained = false;
                for (self.entries()) |entry| if (entry.id == old.id) {
                    retained = true;
                    break;
                };
                if (!retained) self.owner.wipe(old.bytes);
            }
            @memcpy(self.owner.rows[0..self.len], self.entries());
            self.owner.len = self.len;
            self.owner.total_bytes = self.total_bytes;
            self.owner.next_id = self.next_id;
            self.owner.next_sequence = self.next_sequence;
            self.owner.generation = self.base + 1;
            self.new_payload = null;
            self.consumed = true;
        }
    };

    fn candidate(self: *History) Error!Prepared {
        _ = std.math.add(u64, self.generation, 1) catch return error.CounterExhausted;
        return .{ .owner = self, .base = self.generation, .next_id = self.next_id, .next_sequence = self.next_sequence };
    }
    pub fn preparePrune(self: *History, now: i64) Error!Prepared {
        try self.validateTime(now);
        var result = try self.candidate();
        for (self.entries()) |entry| if (!expired(entry.last_copy, now)) {
            result.rows[result.len] = entry;
            result.len += 1;
            result.total_bytes += entry.bytes.len;
        };
        return result;
    }
    pub fn prepareClear(self: *History) Error!Prepared {
        return self.candidate();
    }
    pub fn prepareDelete(self: *History, id: u64) Error!Prepared {
        var result = try self.candidate();
        for (self.entries()) |entry| if (entry.id != id) {
            result.rows[result.len] = entry;
            result.len += 1;
            result.total_bytes += entry.bytes.len;
        };
        return result;
    }
    pub fn prepareCopy(self: *History, kind: Kind, input: []const u8, now: i64) Error!Prepared {
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        var result = try self.preparePrune(now);
        errdefer result.discard();
        const sequence = self.next_sequence;
        result.next_sequence = std.math.add(u64, sequence, 1) catch return error.CounterExhausted;
        var copied: ?Entry = null;
        for (result.entries(), 0..) |entry, index| if (entry.kind == kind and std.mem.eql(u8, entry.bytes, input)) {
            copied = entry;
            result.len -= 1;
            std.mem.copyForwards(Entry, result.rows[index..result.len], result.rows[index + 1 .. result.len + 1]);
            result.total_bytes -= entry.bytes.len;
            break;
        };
        if (copied == null) {
            result.next_id = std.math.add(u64, self.next_id, 1) catch return error.CounterExhausted;
            const bytes = try self.allocator.dupe(u8, input);
            result.new_payload = bytes;
            copied = .{ .id = self.next_id, .kind = kind, .bytes = bytes, .last_copy = now };
        }
        var entry = copied.?;
        entry.last_copy = now;
        entry.sequence = sequence;
        while (result.len >= entries_limit or result.total_bytes > total_limit - entry.bytes.len) {
            result.len -= 1;
            result.total_bytes -= result.rows[result.len].bytes.len;
        }
        var pos = result.len;
        while (pos > 0) : (pos -= 1) result.rows[pos] = result.rows[pos - 1];
        result.rows[0] = entry;
        result.len += 1;
        result.total_bytes += entry.bytes.len;
        result.result_id = entry.id;
        return result;
    }

    fn validateTime(self: *const History, now: i64) Error!void {
        if (now < 0) return error.InvalidTime;
        for (self.entries()) |entry| if (entry.last_copy > now) return error.InvalidTime;
    }

    // Subtract nonnegative, ordered i64 times rather than adding a lifetime to a
    // timestamp, which would overflow near maxInt(i64).
    fn expired(last_copy: i64, now: i64) bool {
        return now - last_copy >= lifetime_seconds;
    }

    fn pruneUnchecked(self: *History, now: i64) usize {
        var removed: usize = 0;
        var index = self.len;
        while (index > 0) {
            index -= 1;
            if (expired(self.rows[index].last_copy, now)) {
                self.remove(index);
                removed += 1;
            }
        }
        return removed;
    }

    fn retain(self: *History, kind: Kind, input: []const u8, last_copy: i64, now: i64, is_copy: bool) Error!?u64 {
        if (!policy.valid(kind, input)) return error.InvalidPayload;
        try self.validateTime(now);
        if (last_copy < 0 or last_copy > now) return error.InvalidTime;
        if (expired(last_copy, now)) {
            _ = self.pruneUnchecked(now);
            return null;
        }

        // Search only live rows. Recopy at the expiry boundary creates a new ID.
        var duplicate_id: ?u64 = null;
        for (self.entries()) |entry| {
            if (!expired(entry.last_copy, now) and entry.kind == kind and std.mem.eql(u8, entry.bytes, input)) {
                duplicate_id = entry.id;
                break;
            }
        }
        if (duplicate_id) |id| {
            _ = self.pruneUnchecked(now);
            for (self.entries(), 0..) |entry, index| {
                if (entry.id != id) continue;
                if (is_copy or last_copy > entry.last_copy) {
                    var updated = self.detach(index);
                    updated.last_copy = last_copy;
                    self.insert(if (is_copy) 0 else self.restoreIndex(last_copy), updated);
                }
                return id;
            }
            unreachable;
        }

        // Reserve the next ID and payload before any destructive maintenance.
        const next_id = std.math.add(u64, self.next_id, 1) catch return error.CounterExhausted;
        const bytes = try self.allocator.dupe(u8, input);
        // Input can alias a borrowed history payload: copying above must happen
        // before any expired row or capacity victim can be wiped.
        _ = self.pruneUnchecked(now);
        const index = if (is_copy) 0 else self.restoreIndex(last_copy);

        var keep = self.len;
        var kept_bytes = self.total_bytes;
        // Subtraction avoids even a transient unchecked aggregate size addition.
        // policy.valid guarantees the candidate fits the total budget by itself.
        while (keep >= entries_limit or kept_bytes > total_limit - bytes.len) {
            if (index >= keep) {
                self.wipe(bytes);
                return null;
            }
            keep -= 1;
            kept_bytes -= self.rows[keep].bytes.len;
        }
        while (self.len > keep) self.remove(self.len - 1);
        const id = self.next_id;
        self.insert(index, .{ .id = id, .kind = kind, .bytes = bytes, .last_copy = last_copy });
        self.next_id = next_id;
        return id;
    }

    fn restoreIndex(self: *const History, last_copy: i64) usize {
        for (self.entries(), 0..) |entry, index| if (entry.last_copy < last_copy) return index;
        return self.len;
    }

    fn insert(self: *History, index: usize, entry: Entry) void {
        std.debug.assert(index <= self.len and self.len < entries_limit);
        var pos = self.len;
        while (pos > index) : (pos -= 1) self.rows[pos] = self.rows[pos - 1];
        self.rows[index] = entry;
        self.len += 1;
        self.total_bytes += entry.bytes.len;
        std.debug.assert(self.total_bytes <= total_limit);
    }

    /// Transfers an existing row's ownership internally without freeing bytes.
    fn detach(self: *History, index: usize) Entry {
        const entry = self.rows[index];
        self.total_bytes -= entry.bytes.len;
        self.len -= 1;
        std.mem.copyForwards(Entry, self.rows[index..self.len], self.rows[index + 1 .. self.len + 1]);
        self.rows[self.len] = undefined;
        return entry;
    }

    fn remove(self: *History, index: usize) void {
        self.wipe(self.detach(index).bytes);
    }

    fn wipe(self: *History, bytes: []const u8) void {
        std.crypto.secureZero(u8, @constCast(bytes));
        self.allocator.free(bytes);
    }
};
