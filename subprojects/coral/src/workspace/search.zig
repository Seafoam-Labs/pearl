//! M2 bounded incremental workspace search. Zig 0.17, worker-only Linux.
//!
//! No controller or UI work is performed here; the caller owns dispatch,
//! backpressure, and request generations.
//!
//! PUBLIC API (the following signatures/fields are the integration ABI)
//!
//! RootId = @import("model.zig").RootId
//! Mode = enum { quick_open, text }
//! Root = struct { id: RootId, canonical_path: []const u8 }
//! Overlay = struct {
//!     root_id: RootId, relative_path: []const u8,
//!     document_id: u64, revision: u64, text: []const u8,
//! }
//! Inputs = struct {
//!     mode: Mode, query: []const u8, roots: []const Root,
//!     excludes: []const []const u8 = &.{}, overlays: []const Overlay = &.{},
//!     limits: Limits = .{},
//! }
//! Source = union(enum) {
//!     disk,
//!     overlay: struct { document_id: u64, revision: u64 },
//! }
//! Result = struct {
//!     root_id: RootId, relative_path: []const u8, source: Source,
//!     score: i64, // quick-open only; larger is better; text uses zero
//!     line: u32, column: u32, end_line: u32, end_column: u32,
//!     byte_offset: usize, byte_length: usize,
//!     preview: []const u8,
//! }
//! Status = enum { running, complete, incomplete, cancelled, reset_required, failed }
//! Delivery = enum { append, replace }
//! Reason = enum {
//!     traversal_limit, page_limit, depth_limit, path_limit, memory_limit,
//!     result_limit, file_too_large, total_bytes_limit, query_work_limit,
//!     policy_work_limit, overlay_too_large, unsafe_overlay,
//!     binary_file, invalid_utf8, unavailable_file,
//! }
//! Reasons = std.EnumSet(Reason)
//! Progress = struct {
//!     records: usize = 0, pages: usize = 0, files: usize = 0,
//!     scanned_bytes: usize = 0, query_steps: usize = 0,
//!     policy_steps: usize = 0, policy_bytes: usize = 0,
//! }
//! Batch.init(allocator: std.mem.Allocator) Batch
//! Batch.deinit(self: *Batch) void
//! Batch public fields:
//!     results: []const Result, delivery: Delivery, status: Status,
//!     reasons: Reasons, progress: Progress, discard_previous: bool,
//!     failure: ?anyerror
//! Session.init(allocator: std.mem.Allocator, inputs: Inputs,
//!              cancel: *c.GCancellable) !Session
//! Session.next(self: *Session, batch: *Batch) !void
//! Session.deinit(self: *Session) void
//!
//! OWNERSHIP / LIFETIME
//!
//! Session and Batch are move-only owned values. init validates bounded inputs;
//! no filesystem traversal occurs until next. Inputs, every transitive slice,
//! and GCancellable are borrowed immutable for the ENTIRE session lifetime.
//! Caller retains the cancellable reference and snapshots unsaved buffers before
//! dispatch. No GTK/GObject document/model access or callback into the UI occurs.
//! One worker owns a session; never call next/deinit concurrently. Cancellation
//! may be signalled from another thread. deinit works after every terminal state.
//! Batch owns copied result paths/previews independently of the session. Its
//! contents survive Session.deinit, but are invalidated by its next reuse or
//! Batch.deinit. Reuse a batch only after the receiving UI has consumed/copied it;
//! alternatively move each batch to the receiver and create another on the worker.
//! Caller must bound its own queued batches and keep workspace/request generation
//! routing outside this API; cancel/reap stale workers even when dropping results.
//!
//! STREAMING / TERMINATION
//!
//! Each next clears its output batch and performs bounded work; empty running
//! batches are valid and MUST be followed by another next. Text uses append
//! batches of <=128 matches, with <=4096 matches across a session by default.
//! Quick-open uses replace batches containing the entire current sorted top K
//! (K<=128), never append-only candidates that could later need retraction.
//! Results are root-qualified, relative paths are never display-only identities.
//! complete means enumeration finished without omissions. Reasons are cumulative;
//! finishing with any reason yields incomplete. A reached global budget stops
//! immediately as incomplete; skippable per-file/depth limits record a reason and
//! continue. Keeping only K fuzzy candidates records result_limit when any matching
//! candidate is omitted, even though the retained K are the best evaluated set.
//! Cancellation returns status=cancelled, not an error, with no new results.
//! A stale scanPage continuation or detected read/policy generation change returns
//! reset_required, no results, discard_previous=true, and stops permanently.
//! Caller MUST discard the entire accumulated result set and explicitly start a
//! new session; this engine never silently restarts or combines generations.
//! Fatal I/O/policy/allocation errors set failed, failure=err, no new results,
//! discard_previous=true, then return err from next. init errors create no session.
//! Calling next after termination repeats terminal metadata with no new results.
//! Partial results from cancelled/incomplete sessions may be shown only labelled
//! as partial; failed/reset_required results must not remain presented as current.
//!
//! MATCHING / GTK POSITIONS
//!
//! Queries must be valid UTF-8, NUL-free, and <=1024 bytes. Empty quick-open queries
//! list ranked paths; empty text queries are rejected (error.EmptyQuery).
//! Literal text matching and fuzzy path subsequence matching use Unicode scalar
//! simple lowercase via GLib g_unichar_tolower: no regex, normalization, locale
//! tailoring, or multi-scalar full case folding (e.g. ss does not match sharp-s).
//! Text matches are nonoverlapping and may span newlines. Coordinates follow
//! GtkTextBuffer: LF, lone CR, CRLF, and U+2029 delimit lines; U+2028 does not.
//! Matching still uses the original bytes/scalars, with no newline normalization.
//! UTF-8 is validated before publishing ANY
//! matches from a source. A NUL marks binary content. Invalid UTF-8/binary content
//! is skipped with a reason; invalid filename UTF-8 is also skipped explicitly.
//! Quick-open disk candidates inspect paths, not file content; buffer overlays
//! are size/content checked in both modes and never fall back to disk.
//! line/column and exclusive end_line/end_column are zero-based Unicode SCALAR
//! offsets, suitable for GtkTextIter line/line_offset on the searched text,
//! NOT UTF-8 byte offsets or
//! grapheme/display columns. byte_offset/byte_length refer to original source
//! bytes. Quick-open positions/byte spans are zero. Preview is valid UTF-8, <=256
//! bytes, clipped on scalar boundaries; navigation never derives from preview.
//! Fuzzy ranking prefers consecutive matches, component/word boundaries, basename
//! matches, and shorter paths. Equal scores sort by relative UTF-8 byte order,
//! then numeric RootId. Ranking is deterministic for the evaluated candidate set;
//! a capped traversal does not claim to have found the global best candidates.
//!
//! FILESYSTEM / POLICY / OVERLAYS
//!
//! Reuse browser_fs.scanSearchPage and the strict scanPage ignore/exclude semantics,
//! including .git exclusion, pruned ignored parents, policy failures, and continuation
//! generations. Search pages report overlong-child omissions as path_limit without
//! weakening request/policy errors or changing explorer scanPage's TooLarge behavior.
//! Never enumerate a whole directory into an unbounded list. Recursive traversal
//! is an explicit bounded stack with incremental per-directory continuation.
//! Read regular files only through checked descriptors: no symlink component at
//! root/ancestor/leaf, O_NOFOLLOW/O_NONBLOCK, inspect the opened descriptor, read
//! that SAME pinned file, and compare pre/post metadata. The descriptor and stamp
//! remain owned by pending text until matching finishes: revalidate before/after
//! resumed matching and before publishing yielded batches, including the final
//! short batch. Never checkFile followed by a path-based read. Revalidate applicable
//! policy/generation around reads.
//! FIFO/device/symlink entries are not opened for blocking reads. Cancellation is
//! cooperative, not a guarantee against uninterruptible remote filesystem I/O.
//! No transactional filesystem snapshot is promised; normal observable generation
//! changes invalidate the session, not undetectable hostile timestamp restoration.
//!
//! Canonical roots are absolute, with no empty/dot/dot-dot components (except /).
//! Overlay paths are nonempty canonical root-relative paths with the same lexical
//! restrictions. Root IDs are unique. Duplicate overlay physical paths or document
//! IDs are rejected, rather than selecting a revision arbitrarily. Deepest nested
//! canonical root owns a path; equal canonical roots use the lowest numeric RootId.
//! Remap overlays to that owner, prune parent traversal of nested roots, and emit
//! one root-qualified path. Hard-link and bind-mount aliases are not deduplicated.
//! An overlay suppresses disk matches for its path BEFORE size/content/policy
//! filtering, including when too large, binary, or invalid UTF-8. There is never
//! fallback to stale disk content. Overlay identity/revision accompanies results.
//! Overlay paths can participate without a disk leaf (deleted-but-dirty files),
//! but every parent must be safely descriptor-traversable and current ignore /
//! exclude rules must allow the hypothetical file. Missing/unsafe parents fail
//! closed with unsafe_overlay; existing symlink/nonregular leaves are not allowed.
//! Policy-denied overlays are excluded normally, not searched outside policy;
//! denied leaves and hidden parents retain generations for completion validation.
//! Parent depth is checked against the owning root BEFORE filesystem traversal;
//! over-depth overlays report depth_limit and still suppress disk matches.
//! Oversize overlays explicitly report overlay_too_large. Policy changes detected
//! while validating overlays invalidate the session just like disk traversal.
//!
//! HARD BOUNDS (Limits defaults are ceilings; callers may only lower them)
//!
//! Limits fields and maximum/default values:
//!     roots: usize = 32; overlays: usize = 4096;
//!     records: usize = 1_000_000; pages: usize = 16_384;
//!     depth: usize = 64; path_bytes: usize = 4095;
//!     path_memory_bytes: usize = 8 * 1024 * 1024;
//!     session_memory_bytes: usize = 64 * 1024 * 1024;
//!     results: usize = 4096; fuzzy_candidates: usize = 128;
//!     file_bytes: usize = 1024 * 1024;
//!     total_bytes: usize = 256 * 1024 * 1024;
//!     query_steps: usize = 256 * 1024 * 1024;
//!     policy_steps: usize = 1024 * 1024 * 1024;
//!     policy_bytes: usize = 64 * 1024 * 1024;
//! records includes ignored/skipped directory records, not just returned entries.
//! pages includes overlay policy probes and generation revalidation scans. Policy
//! counters aggregate actual successful browser/helper work. Worst-case headroom
//! is required before starting a call, but NOT debited on success. A failed/reset
//! call receives a worst-case failure charge. Query work uses conservative charges
//! for comparisons, decoding, ranking, and overlay lookup/ownership, before work.
//! Near a cap, insufficient headroom can stop before the exact ceiling is reached.
//! total_bytes includes disk payload, EOF probes, and overlay text inspected;
//! ignore reads have the separate policy_bytes cap. No full overlay copy is made.
//! Path memory counts retained traversal/candidate/result-identity path bytes;
//! session memory caps allocator-requested live backing storage including pages,
//! policy scratch, buffers, and candidates (not caller inputs or allocator metadata).
//! Browser descriptor walking additionally uses bounded <=4096-byte temporary
//! component storage through its existing C allocator; fixed stack scratch is
//! bounded independently. Retained page names count towards path memory, with
//! worst-case page headroom required before enumeration.
//! Each Batch caps its own allocator-requested storage at 1 MiB. Caller-owned input
//! payload can exceed these bounds, but oversized payload is not scanned/copied.
//! Per next: <=1 browser page (256 entries / 4096 records), <=1 MiB source bytes
//! plus one EOF probe, <=1 Mi charged query steps, <=128 emitted results; resumable
//! pending work carries over. There are <=4 browser/checked-policy calls per next;
//! each retains a <=16 Mi matching-step and <=512 KiB policy payload ceiling,
//! charged to the session separately. Overlay sources are checked before traversal
//! and their directory generations are verified again before completion. Poll
//! cancellation before filesystem calls, between path components/records, every
//! <=4096 query steps, and every <=4096 read bytes. Limits are not wall-time bounds.
//!
//! VALIDATION
//!
//! Isolated Zig tests in search_test.zig cover paged 100k-file traversal and bounded
//! storage, recursive/depth limits, deterministic fuzzy replacement/top-K, literal
//! Unicode scalar navigation, invalid UTF-8/binary input, ignored/excluded/nested
//! roots, dirty/deleted/oversized overlay precedence and revision propagation,
//! symlink component/leaf and FIFO rejection, cancellation during scan/read/match,
//! stale continuation/read races without mixed batches, lowered resource caps,
//! allocation failures, and owned-batch/input lifetime rules. Native controller
//! acceptance is covered separately by tests/search.py.

const std = @import("std");
const c = @import("pearl_app_c");
const browser = @import("browser_fs.zig");
const checked = @import("ignore_fs.zig");
const ignore = @import("ignore.zig");
const fs = @import("search_fs.zig");
pub const RootId = @import("model.zig").RootId;
pub const Mode = enum { quick_open, text };
pub const Root = struct { id: RootId, canonical_path: []const u8 };
pub const Overlay = struct { root_id: RootId, relative_path: []const u8, document_id: u64, revision: u64, text: []const u8 };
pub const Inputs = struct {
    mode: Mode,
    query: []const u8,
    roots: []const Root,
    excludes: []const []const u8 = &.{},
    overlays: []const Overlay = &.{},
    limits: Limits = .{},
};
pub const Limits = struct {
    roots: usize = 32,
    overlays: usize = 4096,
    records: usize = 1_000_000,
    pages: usize = 16_384,
    depth: usize = 64,
    path_bytes: usize = 4095,
    path_memory_bytes: usize = 8 * 1024 * 1024,
    session_memory_bytes: usize = 64 * 1024 * 1024,
    results: usize = 4096,
    fuzzy_candidates: usize = 128,
    file_bytes: usize = 1024 * 1024,
    total_bytes: usize = 256 * 1024 * 1024,
    query_steps: usize = 256 * 1024 * 1024,
    policy_steps: usize = 1024 * 1024 * 1024,
    policy_bytes: usize = 64 * 1024 * 1024,
};
pub const Source = union(enum) { disk, overlay: struct { document_id: u64, revision: u64 } };
pub const Result = struct {
    root_id: RootId,
    relative_path: []const u8,
    source: Source,
    score: i64 = 0,
    line: u32 = 0,
    column: u32 = 0,
    end_line: u32 = 0,
    end_column: u32 = 0,
    byte_offset: usize = 0,
    byte_length: usize = 0,
    preview: []const u8 = "",
};
pub const Status = enum { running, complete, incomplete, cancelled, reset_required, failed };
pub const Delivery = enum { append, replace };
pub const Reason = enum {
    traversal_limit,
    page_limit,
    depth_limit,
    path_limit,
    memory_limit,
    result_limit,
    file_too_large,
    total_bytes_limit,
    query_work_limit,
    policy_work_limit,
    overlay_too_large,
    unsafe_overlay,
    binary_file,
    invalid_utf8,
    unavailable_file,
};
pub const Reasons = std.EnumSet(Reason);
pub const Progress = struct {
    records: usize = 0,
    pages: usize = 0,
    files: usize = 0,
    scanned_bytes: usize = 0,
    query_steps: usize = 0,
    policy_steps: usize = 0,
    policy_bytes: usize = 0,
};
const batch_limit = 128;
const turn_limit = 1024 * 1024;
pub const TestHooks = if (@import("builtin").is_test) struct {
    pub var before_query: ?*const fn (usize, *c.GCancellable) void = null;
} else struct {};

pub const Batch = struct {
    results: []const Result = &.{},
    delivery: Delivery = .append,
    status: Status = .running,
    reasons: Reasons = .empty,
    progress: Progress = .{},
    discard_previous: bool = false,
    failure: ?anyerror = null,
    allocator: std.mem.Allocator,
    storage: []Result = &.{},

    pub fn init(allocator: std.mem.Allocator) Batch {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Batch) void {
        self.clear();
        self.allocator.free(self.storage);
        self.* = undefined;
    }
    fn clear(self: *Batch) void {
        for (self.results) |result| {
            self.allocator.free(result.relative_path);
            self.allocator.free(result.preview);
        }
        self.results = &.{};
    }
    fn append(self: *Batch, result: Result) !void {
        std.debug.assert(self.results.len < batch_limit);
        if (self.storage.len == 0) self.storage = try self.allocator.alloc(Result, batch_limit);
        var copy = result;
        copy.relative_path = try self.allocator.dupe(u8, result.relative_path);
        errdefer self.allocator.free(copy.relative_path);
        copy.preview = try self.allocator.dupe(u8, result.preview);
        self.storage[self.results.len] = copy;
        self.results = self.storage[0 .. self.results.len + 1];
    }
};

const Key = struct { root: usize, path: []const u8 };
const KeyContext = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        return std.hash.Wyhash.hash(@intCast(key.root), key.path);
    }
    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.root == b.root and std.mem.eql(u8, a.path, b.path);
    }
};
const OverlayMap = std.HashMapUnmanaged(Key, usize, KeyContext, 80);
const MappedOverlay = struct {
    key: Key,
    input: usize,
    generation: ?browser.Generation = null,
    parent_hidden: bool = false,
};
const Frame = struct {
    root: usize,
    path: []const u8,
    page: ?browser.Page = null,
    index: usize = 0,
    page_path_bytes: usize = 0,
    overlay_check: usize = 0,
    continuation: ?browser.Continuation = null,
    directory: ?browser.CheckedDirectory = null,
    finished: bool = false,
};
const Position = struct { byte: usize = 0, line: u32 = 0, column: u32 = 0 };
const Pending = struct {
    root: usize,
    path: []const u8,
    source: Source,
    bytes: []const u8,
    owned: bool,
    file: ?fs.PinnedFile = null,
    validated: usize = 0,
    position: Position = .{},
    scalar_index: usize = 0,
    matched: usize = 0,
};

/// Move-only worker handle. All borrowed inputs must outlive deinit().
pub const Session = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, inputs: Inputs, cancel: *c.GCancellable) !Session {
        const ceilings: Limits = .{};
        inline for (@typeInfo(Limits).@"struct".field_names) |field| {
            if (@field(inputs.limits, field) > @field(ceilings, field)) return error.InvalidLimits;
        }
        if (inputs.limits.session_memory_bytes < @sizeOf(State)) return error.InvalidLimits;
        if (inputs.roots.len > inputs.limits.roots or inputs.overlays.len > inputs.limits.overlays) return error.TooLarge;
        if (inputs.query.len > 1024 or !std.unicode.utf8ValidateSlice(inputs.query) or std.mem.indexOfScalar(u8, inputs.query, 0) != null) return error.InvalidQuery;
        if (inputs.mode == .text and inputs.query.len == 0) return error.EmptyQuery;
        if (inputs.excludes.len > ignore.limits.excludes) return error.TooLarge;
        for (inputs.excludes) |pattern| {
            if (pattern.len > ignore.limits.pattern_bytes) return error.TooLarge;
            try ignore.validateExclude(pattern);
        }
        for (inputs.roots, 0..) |root, i| {
            try validPath(root.canonical_path, true, 4095);
            for (inputs.roots[0..i]) |previous| if (previous.id == root.id) return error.DuplicateRoot;
        }
        const state = try allocator.create(State);
        state.* = .{ .memory = .{ .backing = allocator, .limit = inputs.limits.session_memory_bytes, .live = @sizeOf(State), .peak = @sizeOf(State) }, .inputs = inputs, .cancel = cancel };
        const session: Session = .{ .state = state };
        errdefer {
            var owner = session;
            owner.deinit();
        }
        var offset: usize = 0;
        while (offset < inputs.query.len) {
            const scalar = decode(inputs.query, offset) catch unreachable;
            state.query[state.query_len] = lower(scalar.value);
            state.query_len += 1;
            offset += scalar.len;
        }
        var matched: usize = 0;
        for (@min(1, state.query_len)..state.query_len) |i| {
            while (matched != 0 and state.query[i] != state.query[matched]) matched = state.prefix[matched - 1];
            if (state.query[i] == state.query[matched]) matched += 1;
            state.prefix[i] = matched;
        }
        for (inputs.overlays, 0..) |overlay, i| {
            try validPath(overlay.relative_path, false, 4095);
            state.turn_steps = 0;
            try state.charge(i + (overlay.relative_path.len + 4096) * (inputs.roots.len + 3));
            const root = state.rootIndex(overlay.root_id) orelse return error.UnknownRoot;
            for (inputs.overlays[0..i]) |previous| if (previous.document_id == overlay.document_id) return error.DuplicateOverlay;
            var absolute_buffer: [8192]u8 = undefined;
            const absolute = try join(&absolute_buffer, inputs.roots[root].canonical_path, overlay.relative_path);
            const owner = try state.owner(absolute);
            const relative = relativeTo(inputs.roots[owner].canonical_path, absolute);
            if (relative.len == 0) return error.InvalidPath;
            const path = try state.copyPath(relative);
            errdefer state.freePath(path);
            const key: Key = .{ .root = owner, .path = path };
            if (state.overlay_map.contains(key)) return error.DuplicateOverlay;
            try state.overlays.append(state.a(), .{ .key = key, .input = i });
            // Ownership has transferred to overlays even if the map allocation fails.
            state.overlay_map.put(state.a(), key, i) catch |err| {
                _ = state.overlays.pop();
                return err;
            };
        }
        return session;
    }

    pub fn deinit(self: *Session) void {
        const s = self.state;
        s.clearPending();
        if (s.overlay_directory) |*directory| directory.deinit();
        while (s.frames.items.len != 0) s.popFrame();
        s.frames.deinit(s.a());
        for (s.overlays.items) |overlay| s.freePath(overlay.key.path);
        s.overlays.deinit(s.a());
        s.overlay_map.deinit(s.a());
        for (s.candidates.items) |result| s.freePath(result.relative_path);
        s.candidates.deinit(s.a());
        std.debug.assert(s.memory.live == @sizeOf(State));
        const allocator = s.memory.backing;
        allocator.destroy(s);
        self.* = undefined;
    }

    pub fn next(self: *Session, batch: *Batch) !void {
        const s = self.state;
        batch.clear();
        batch.delivery = if (s.inputs.mode == .quick_open) .replace else .append;
        s.turn_steps = 0;
        s.turn_bytes = 0;
        const was_running = s.status == .running;
        if (was_running) s.step(batch) catch |err| {
            switch (err) {
                error.Yield, error.Limit => {},
                error.Cancelled => s.status = .cancelled,
                error.DirectoryChanged => s.status = .reset_required,
                error.OutOfMemory => if (s.memory.hit) {
                    s.reasons.insert(.memory_limit);
                    s.status = .incomplete;
                } else {
                    s.status = .failed;
                    s.failure = err;
                },
                else => {
                    s.status = .failed;
                    s.failure = err;
                },
            }
        };
        var publish = true;
        // A yielded matcher still needs a generation check before exposing matches.
        if (was_running and (s.status == .running or s.status == .complete or s.status == .incomplete)) {
            s.validateActive() catch |err| {
                publish = false;
                switch (err) {
                    error.Limit => {},
                    error.Cancelled => s.status = .cancelled,
                    error.DirectoryChanged => s.status = .reset_required,
                    error.OutOfMemory => if (s.memory.hit) {
                        s.reasons.insert(.memory_limit);
                        s.status = .incomplete;
                    } else {
                        s.status = .failed;
                        s.failure = err;
                    },
                    else => {
                        s.status = .failed;
                        s.failure = err;
                    },
                }
                batch.clear();
            };
        }
        if (s.status == .cancelled or s.status == .reset_required or s.status == .failed) batch.clear();
        if (publish and was_running and s.inputs.mode == .quick_open and s.status != .cancelled and s.status != .reset_required and s.status != .failed) {
            for (s.candidates.items) |result| batch.append(result) catch |err| {
                batch.clear();
                s.status = .failed;
                s.failure = err;
                break;
            };
        }
        batch.status = s.status;
        batch.reasons = s.reasons;
        batch.progress = s.progress;
        batch.discard_previous = s.status == .reset_required or s.status == .failed;
        batch.failure = s.failure;
        if (s.failure) |err| return err;
    }
};

const State = struct {
    memory: fs.Memory,
    inputs: Inputs,
    cancel: *c.GCancellable,
    status: Status = .running,
    failure: ?anyerror = null,
    reasons: Reasons = .empty,
    progress: Progress = .{},
    path_memory: usize = 0,
    turn_steps: usize = 0,
    turn_bytes: usize = 0,
    query: [1024]u21 = undefined,
    prefix: [1024]usize = @splat(0),
    query_len: usize = 0,
    positions: [1024]Position = undefined,
    overlays: std.ArrayList(MappedOverlay) = .empty,
    overlay_map: OverlayMap = .empty,
    overlay_index: usize = 0,
    verified_overlays: usize = 0,
    overlay_directory: ?browser.CheckedDirectory = null,
    frames: std.ArrayList(Frame) = .empty,
    root_index: usize = 0,
    pending: ?Pending = null,
    candidates: std.ArrayList(Result) = .empty,
    emitted: usize = 0,

    fn a(self: *State) std.mem.Allocator {
        return self.memory.allocator();
    }
    fn stop(self: *State, reason: Reason) error{Limit} {
        self.reasons.insert(reason);
        self.status = .incomplete;
        return error.Limit;
    }
    fn charge(self: *State, steps: usize) !void {
        if (@import("builtin").is_test) {
            if (TestHooks.before_query) |hook| hook(self.progress.query_steps, self.cancel);
        }
        try checked.cancelled(self.cancel);
        if (steps > self.inputs.limits.query_steps - self.progress.query_steps) return self.stop(.query_work_limit);
        if (steps > turn_limit - self.turn_steps) return error.Yield;
        self.progress.query_steps += steps;
        self.turn_steps += steps;
    }
    fn copyPath(self: *State, path: []const u8) ![]const u8 {
        if (path.len > self.inputs.limits.path_bytes) return self.stop(.path_limit);
        if (path.len > self.inputs.limits.path_memory_bytes - self.path_memory) return self.stop(.path_limit);
        const copy = try self.a().dupe(u8, path);
        self.path_memory += path.len;
        return copy;
    }
    fn freePath(self: *State, path: []const u8) void {
        self.path_memory -= path.len;
        self.a().free(path);
    }
    fn rootIndex(self: *State, id: RootId) ?usize {
        for (self.inputs.roots, 0..) |root, i| if (root.id == id) return i;
        return null;
    }
    fn owner(self: *State, absolute: []const u8) !usize {
        var best: ?usize = null;
        for (self.inputs.roots, 0..) |root, i| {
            try checked.cancelled(self.cancel);
            if (!within(root.canonical_path, absolute)) continue;
            if (best == null or root.canonical_path.len > self.inputs.roots[best.?].canonical_path.len or
                (root.canonical_path.len == self.inputs.roots[best.?].canonical_path.len and @backingInt(root.id) < @backingInt(self.inputs.roots[best.?].id))) best = i;
        }
        return best.?;
    }
    fn owned(self: *State, root: usize, path: []const u8) !bool {
        try self.charge((path.len + self.inputs.roots[root].canonical_path.len + 1) * @max(1, self.inputs.roots.len));
        var buffer: [8192]u8 = undefined;
        return try self.owner(try join(&buffer, self.inputs.roots[root].canonical_path, path)) == root;
    }
    fn beginPolicy(self: *State) !void {
        try checked.cancelled(self.cancel);
        if (self.progress.pages == self.inputs.limits.pages) return self.stop(.page_limit);
        // Reserve only permission to start one bounded call. Successful calls
        // debit actual work, not this worst-case allowance (important at 100k).
        if (self.inputs.limits.policy_steps - self.progress.policy_steps < 2 * ignore.limits.page_match_steps or
            self.inputs.limits.policy_bytes - self.progress.policy_bytes < ignore.limits.policy_read_bytes) return self.stop(.policy_work_limit);
        self.progress.pages += 1;
    }
    fn account(self: *State, work: browser.Work) void {
        self.progress.policy_steps += work.match_steps + work.policy_match_steps;
        self.progress.policy_bytes += work.policy_bytes;
    }
    fn failureCharge(self: *State) void {
        self.account(.{ .match_steps = ignore.limits.page_match_steps, .policy_match_steps = ignore.limits.policy_match_steps, .policy_bytes = ignore.limits.policy_read_bytes });
    }
    fn openDirectory(self: *State, root: usize, path: []const u8, expected: ?browser.Generation) !browser.CheckedDirectory {
        try self.beginPolicy();
        var work: browser.Work = .{};
        const directory = browser.CheckedDirectory.open(self.a(), self.inputs.roots[root].canonical_path, path, self.inputs.excludes, expected, self.cancel, &work) catch |err| {
            self.failureCharge();
            return err;
        };
        self.account(work);
        return directory;
    }
    fn validateDirectory(self: *State, directory: *browser.CheckedDirectory) !void {
        try self.beginPolicy();
        var work: browser.Work = .{};
        directory.validate(&work) catch |err| {
            self.failureCharge();
            return err;
        };
        self.account(work);
    }
    fn validateActive(self: *State) !void {
        if (self.overlay_directory) |*directory| {
            try self.validateDirectory(directory);
        } else if (self.frames.items.len != 0) {
            if (self.frames.items[self.frames.items.len - 1].directory) |*directory| try self.validateDirectory(directory);
        }
        try self.validatePending();
    }
    fn validatePending(self: *State) !void {
        if (self.pending) |*pending| {
            if (pending.file) |*file| try file.validate(self.cancel);
        }
    }
    fn clearPending(self: *State) void {
        if (self.pending) |*pending| {
            if (pending.file) |*file| file.deinit();
            if (pending.owned) self.a().free(pending.bytes);
            self.freePath(pending.path);
            self.pending = null;
        }
    }
    fn popFrame(self: *State) void {
        var frame = self.frames.pop().?;
        if (frame.page) |*page| page.deinit();
        self.path_memory -= frame.page_path_bytes;
        if (frame.directory) |*directory| directory.deinit();
        self.freePath(frame.path);
    }
    fn pushFrame(self: *State, root: usize, path: []const u8) !void {
        const copy = try self.copyPath(path);
        errdefer self.freePath(copy);
        try self.frames.append(self.a(), .{ .root = root, .path = copy });
    }

    fn step(self: *State, batch: *Batch) !void {
        try checked.cancelled(self.cancel);
        if (self.overlay_index < self.overlays.items.len or self.overlay_directory != null) return self.overlayStep(batch);
        if (self.frames.items.len == 0) {
            if (self.root_index == self.inputs.roots.len) {
                // An overlay parent may have been pruned by a later ancestor
                // policy change, so traversal alone cannot validate its snapshot.
                if (self.verified_overlays < self.overlays.items.len) {
                    const overlay = self.overlays.items[self.verified_overlays];
                    try self.charge(overlay.key.path.len + 1);
                    if (overlay.generation) |generation| {
                        var directory = self.openDirectory(overlay.key.root, parent(overlay.key.path), null) catch |err| {
                            if (err == error.UnavailableOrSymlink) return error.DirectoryChanged;
                            return err;
                        };
                        defer directory.deinit();
                        if (directory.hidden() != overlay.parent_hidden or !std.mem.eql(u8, &generation, &directory.generation())) return error.DirectoryChanged;
                    }
                    self.verified_overlays += 1;
                    return;
                }
                self.status = if (self.reasons.count() == 0) .complete else .incomplete;
                return;
            }
            const root = self.root_index;
            try self.charge((self.inputs.roots[root].canonical_path.len + 1) * self.inputs.roots.len);
            self.root_index += 1;
            if (try self.owner(self.inputs.roots[root].canonical_path) == root) try self.pushFrame(root, "");
            return;
        }
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (frame.directory) |*directory| try self.validateDirectory(directory);
        if (self.pending != null) {
            try self.matchPending(batch);
            if (self.pending != null or batch.results.len == batch_limit) return;
        }
        if (frame.page == null) {
            if (frame.finished) {
                self.popFrame();
                return;
            }
            if (self.inputs.limits.records - self.progress.records < browser.record_limit) return self.stop(.traversal_limit);
            // scanPage can allocate at most this many filename bytes. Reserve
            // headroom, but retain only its actual path-byte charge afterwards.
            if (browser.page_limit * 4095 > self.inputs.limits.path_memory_bytes - self.path_memory) return self.stop(.path_limit);
            try self.beginPolicy();
            var page = browser.scanSearchPage(self.a(), self.inputs.roots[frame.root].canonical_path, frame.path, self.inputs.excludes, frame.continuation, self.cancel) catch |err| {
                self.failureCharge();
                return err;
            };
            if (page.status == .reset_required) {
                page.deinit();
                self.failureCharge();
                return error.DirectoryChanged;
            }
            self.account(page.work);
            self.progress.records += page.processed;
            if (page.path_omissions != 0) self.reasons.insert(.path_limit);
            if (frame.directory) |*directory| {
                if (!std.mem.eql(u8, &directory.generation(), &page.generation)) {
                    page.deinit();
                    return error.DirectoryChanged;
                }
            } else if (page.status != .ignored) {
                frame.directory = self.openDirectory(frame.root, frame.path, page.generation) catch |err| {
                    page.deinit();
                    return err;
                };
            }
            for (page.entries) |entry| frame.page_path_bytes += entry.name.len;
            self.path_memory += frame.page_path_bytes;
            frame.continuation = page.continuation;
            frame.finished = page.complete;
            frame.page = page;
            frame.index = 0;
            frame.overlay_check = 0;
        }
        const page = &frame.page.?;
        while (frame.overlay_check < self.overlays.items.len) {
            const overlay = self.overlays.items[frame.overlay_check];
            try self.charge(overlay.key.path.len + frame.path.len + 1);
            if (overlay.key.root == frame.root and std.mem.eql(u8, parent(overlay.key.path), frame.path)) {
                if (overlay.generation) |generation| {
                    if (!std.mem.eql(u8, &generation, &page.generation)) return error.DirectoryChanged;
                }
            }
            frame.overlay_check += 1;
        }
        while (frame.index < page.entries.len) {
            try checked.cancelled(self.cancel);
            const entry = page.entries[frame.index];
            var buffer: [8192]u8 = undefined;
            const path = try join(&buffer, frame.path, entry.name);
            if (path.len > self.inputs.limits.path_bytes) {
                self.reasons.insert(.path_limit);
                frame.index += 1;
                continue;
            }
            if (!try self.owned(frame.root, path)) {
                frame.index += 1;
                continue;
            }
            try self.charge(path.len + 1);
            if (entry.kind == .blocked) {
                if (std.mem.eql(u8, entry.name, "[unsupported filename encoding]")) self.reasons.insert(.invalid_utf8);
                frame.index += 1;
                continue;
            }
            if (entry.kind == .directory) {
                if (self.frames.items.len > self.inputs.limits.depth) {
                    self.reasons.insert(.depth_limit);
                    frame.index += 1;
                    continue;
                }
                // Validate the parent BEFORE switching the active frame.
                try self.validateDirectory(&frame.directory.?);
                const root = frame.root;
                frame.index += 1;
                try self.pushFrame(root, path);
                return;
            }
            if (self.overlay_map.contains(.{ .root = frame.root, .path = path })) {
                frame.index += 1;
                continue;
            }
            if (self.inputs.mode == .quick_open) {
                try self.fuzzy(frame.root, path, .disk);
                frame.index += 1;
                continue;
            }
            try self.startDisk(frame, entry.name, path);
            frame.index += 1;
            if (self.pending != null) try self.matchPending(batch);
            if (self.pending != null or batch.results.len == batch_limit) return;
        }
        page.deinit();
        self.path_memory -= frame.page_path_bytes;
        frame.page_path_bytes = 0;
        frame.page = null;
    }

    fn overlayStep(self: *State, batch: *Batch) !void {
        if (self.overlay_directory != null) {
            try self.validateDirectory(&self.overlay_directory.?);
            if (self.pending != null) try self.matchPending(batch);
            if (self.pending != null) return;
            try self.validateDirectory(&self.overlay_directory.?);
            self.overlay_directory.?.deinit();
            self.overlay_directory = null;
            self.overlay_index += 1;
            return;
        }
        const mapped = &self.overlays.items[self.overlay_index];
        const overlay = self.inputs.overlays[mapped.input];
        // Count parent components relative to the canonical owning root, exactly
        // as recursive traversal does. The suppression map remains intact.
        if (std.mem.count(u8, mapped.key.path, "/") > self.inputs.limits.depth) {
            self.reasons.insert(.depth_limit);
            self.overlay_index += 1;
            return;
        }
        self.overlay_directory = self.openDirectory(mapped.key.root, parent(mapped.key.path), null) catch |err| {
            if (err == error.UnavailableOrSymlink) {
                self.reasons.insert(.unsafe_overlay);
                self.overlay_index += 1;
                return;
            }
            return err;
        };
        const directory = &self.overlay_directory.?;
        // A denial is a snapshot decision too: losing its generation would let
        // later traversal silently suppress an overlay under a different policy.
        mapped.generation = directory.generation();
        mapped.parent_hidden = directory.hidden();
        if (!directory.hidden()) {
            try self.beginPolicy();
            var work: browser.Work = .{};
            const allowed = directory.allowsOverlay(leaf(mapped.key.path), &work) catch |err| {
                self.failureCharge();
                if (err == error.UnavailableOrSymlink or err == error.NotRegularFile) {
                    self.reasons.insert(.unsafe_overlay);
                    return;
                }
                return err;
            };
            self.account(work);
            if (allowed) {
                if (overlay.text.len > self.inputs.limits.file_bytes) {
                    self.reasons.insert(.overlay_too_large);
                    return;
                }
                const path = try self.copyPath(mapped.key.path);
                self.pending = .{ .root = mapped.key.root, .path = path, .source = .{ .overlay = .{ .document_id = overlay.document_id, .revision = overlay.revision } }, .bytes = overlay.text, .owned = false };
                self.progress.files += 1;
                try self.matchPending(batch);
            }
        }
    }

    fn startDisk(self: *State, frame: *Frame, name: []const u8, path: []const u8) !void {
        if (self.turn_bytes >= turn_limit) return error.Yield;
        const fd = frame.directory.?.openFile(name) catch |err| {
            if (err == error.UnavailableOrSymlink or err == error.NotRegularFile) {
                self.reasons.insert(.unavailable_file);
                return;
            }
            return err;
        };
        var retained = false;
        defer if (!retained) {
            _ = std.c.close(fd);
        };
        const stat = try checked.inspect(fd);
        if (stat.size > self.inputs.limits.file_bytes) {
            self.reasons.insert(.file_too_large);
            return;
        }
        const required: usize = @as(usize, @intCast(stat.size)) + 1;
        if (required > self.inputs.limits.total_bytes - self.progress.scanned_bytes) return self.stop(.total_bytes_limit);
        if (self.turn_bytes != 0 and required > turn_limit - self.turn_bytes) return error.Yield;
        const copy = try self.copyPath(path);
        errdefer self.freePath(copy);
        const before = self.progress.scanned_bytes;
        const bytes = try fs.read(self.a(), fd, stat, self.cancel, &self.progress.scanned_bytes);
        self.turn_bytes += self.progress.scanned_bytes - before;
        self.progress.files += 1;
        self.pending = .{ .root = frame.root, .path = copy, .source = .disk, .bytes = bytes, .owned = true, .file = .{ .fd = fd, .stamp = stat } };
        retained = true;
    }

    fn matchPending(self: *State, batch: *Batch) !void {
        try self.validatePending();
        const complete = try self.matchPendingContent(batch);
        // Also check the final short batch before releasing the pin. Yield/limit
        // exits retain it for next's pre-publication validation and deinit.
        try self.validatePending();
        if (complete) self.clearPending();
    }

    fn matchPendingContent(self: *State, batch: *Batch) !bool {
        const pending = &self.pending.?;
        // Validate the WHOLE source before emitting any match, including a prefix.
        while (pending.validated < pending.bytes.len) {
            try self.charge(4);
            const scalar = decode(pending.bytes, pending.validated) catch {
                self.reasons.insert(.invalid_utf8);
                return true;
            };
            if (!pending.owned) {
                if (scalar.len > self.inputs.limits.total_bytes - self.progress.scanned_bytes) return self.stop(.total_bytes_limit);
                if (self.turn_bytes + scalar.len > turn_limit) return error.Yield;
                self.progress.scanned_bytes += scalar.len;
                self.turn_bytes += scalar.len;
            }
            if (scalar.value == 0) {
                self.reasons.insert(.binary_file);
                return true;
            }
            pending.validated += scalar.len;
        }
        if (self.inputs.mode == .quick_open) {
            try self.fuzzy(pending.root, pending.path, pending.source);
            return true;
        }
        while (pending.position.byte < pending.bytes.len and batch.results.len < batch_limit) {
            try self.charge(4);
            const scalar = decode(pending.bytes, pending.position.byte) catch unreachable;
            const value = lower(scalar.value);
            while (pending.matched > 0 and value != self.query[pending.matched]) {
                try self.charge(1);
                pending.matched = self.prefix[pending.matched - 1];
            }
            const start = pending.position;
            self.positions[pending.scalar_index % self.query_len] = start;
            pending.scalar_index += 1;
            pending.position.byte += scalar.len;
            const line_break = scalar.value == '\n' or scalar.value == 0x2029 or
                (scalar.value == '\r' and (pending.position.byte == pending.bytes.len or pending.bytes[pending.position.byte] != '\n'));
            if (line_break) {
                pending.position.line += 1;
                pending.position.column = 0;
            } else pending.position.column += 1;
            if (value == self.query[pending.matched]) pending.matched += 1;
            if (pending.matched == self.query_len) {
                pending.matched = 0;
                if (self.emitted == self.inputs.limits.results) return self.stop(.result_limit);
                const begin = self.positions[(pending.scalar_index - self.query_len) % self.query_len];
                var preview_end = @min(pending.bytes.len, begin.byte + 256);
                while (preview_end < pending.bytes.len and preview_end > begin.byte and pending.bytes[preview_end] & 0xc0 == 0x80) preview_end -= 1;
                try batch.append(.{
                    .root_id = self.inputs.roots[pending.root].id,
                    .relative_path = pending.path,
                    .source = pending.source,
                    .line = begin.line,
                    .column = begin.column,
                    .end_line = pending.position.line,
                    .end_column = pending.position.column,
                    .byte_offset = begin.byte,
                    .byte_length = pending.position.byte - begin.byte,
                    .preview = pending.bytes[begin.byte..preview_end],
                });
                self.emitted += 1;
            }
        }
        return pending.position.byte == pending.bytes.len;
    }

    fn fuzzy(self: *State, root: usize, path: []const u8, source: Source) !void {
        try self.charge((path.len + 1) * (self.candidates.items.len + 8));
        var at: usize = 0;
        var matched: usize = 0;
        var score: i64 = -@as(i64, @intCast(path.len));
        var consecutive = false;
        var boundary = true;
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
        while (at < path.len and matched < self.query_len) {
            const scalar = try decode(path, at);
            if (lower(scalar.value) == self.query[matched]) {
                score += 10 + @as(i64, if (consecutive) 40 else 0) + @as(i64, if (boundary) 20 else 0) + @as(i64, if (at >= basename) 15 else 0);
                matched += 1;
                consecutive = true;
            } else consecutive = false;
            boundary = scalar.value == '/' or scalar.value == '_' or scalar.value == '-' or scalar.value == '.' or scalar.value == ' ';
            at += scalar.len;
        }
        if (matched != self.query_len) return;
        const result: Result = .{ .root_id = self.inputs.roots[root].id, .relative_path = path, .source = source, .score = score };
        const capacity = @min(self.inputs.limits.fuzzy_candidates, self.inputs.limits.results);
        if (capacity == 0) {
            self.reasons.insert(.result_limit);
            return;
        }
        if (self.candidates.items.len == capacity) {
            self.reasons.insert(.result_limit);
            if (!better({}, result, self.candidates.items[capacity - 1])) return;
        }
        var copy = result;
        copy.relative_path = try self.copyPath(path);
        if (self.candidates.items.len == capacity) {
            self.freePath(self.candidates.items[capacity - 1].relative_path);
            self.candidates.items[capacity - 1] = copy;
        } else self.candidates.append(self.a(), copy) catch |err| {
            self.freePath(copy.relative_path);
            return err;
        };
        var index = self.candidates.items.len - 1;
        while (index > 0) : (index -= 1) {
            try checked.cancelled(self.cancel);
            if (!better({}, self.candidates.items[index], self.candidates.items[index - 1])) break;
            std.mem.swap(Result, &self.candidates.items[index], &self.candidates.items[index - 1]);
        }
    }
};

fn better(_: void, a: Result, b: Result) bool {
    if (a.score != b.score) return a.score > b.score;
    const order = std.mem.order(u8, a.relative_path, b.relative_path);
    if (order != .eq) return order == .lt;
    return @backingInt(a.root_id) < @backingInt(b.root_id);
}
fn lower(value: u21) u21 {
    return @intCast(c.g_unichar_tolower(value));
}
const Scalar = struct { value: u21, len: usize };
fn decode(bytes: []const u8, at: usize) !Scalar {
    const len = try std.unicode.utf8ByteSequenceLength(bytes[at]);
    if (len > bytes.len - at) return error.InvalidUtf8;
    return .{ .value = try std.unicode.utf8Decode(bytes[at .. at + len]), .len = len };
}
fn parent(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[0..i] else "";
}
fn leaf(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}
fn within(root: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and (root.len == 1 or root.len == path.len or path[root.len] == '/');
}
fn relativeTo(root: []const u8, path: []const u8) []const u8 {
    if (root.len == path.len) return "";
    return path[root.len + @intFromBool(root.len != 1) ..];
}
fn join(buffer: []u8, prefix: []const u8, suffix: []const u8) ![]const u8 {
    if (prefix.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{suffix});
    if (suffix.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{prefix});
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ prefix, if (prefix[prefix.len - 1] == '/') "" else "/", suffix });
}
fn validPath(path: []const u8, absolute: bool, maximum: usize) !void {
    if (path.len == 0 or path.len > maximum or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if ((path[0] == '/') != absolute) return error.InvalidPath;
    if (absolute and path.len == 1) return;
    var parts = std.mem.splitScalar(u8, path[@intFromBool(absolute)..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
}
