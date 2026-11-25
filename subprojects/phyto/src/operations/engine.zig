//! Worker-only file operations. No GTK calls; all operands are owned GFiles.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const a = std.heap.c_allocator;
pub const Kind = enum { copy, move, trash, delete, mkdir, document, link, restore, empty_trash };
pub const Failure = error{ Io, Cancelled, Conflict, InvalidTarget, Changed, Unsupported, Limit };

/// One batch-level category for a finished job, so a large copy cannot flood the
/// journal with per-item lines. A single aggregate count cannot tell a failed
/// batch from a user cancellation or an optimistic-concurrency conflict, so each
/// gets its own value.
pub const Outcome = enum { ok, cancelled, conflict, partial, failed };

/// Derives the batch category from the aggregate counts a finished job carries.
/// Cancellation wins over everything; with no failures, a skipped item means a
/// conflict was resolved by skipping; otherwise failures split into a partial
/// batch (some completed) and a total failure (none did).
pub fn outcome(cancelled: bool, successful: usize, skipped: usize, failed: usize) Outcome {
    if (cancelled) return .cancelled;
    if (failed == 0) return if (skipped > 0) .conflict else .ok;
    return if (successful > 0) .partial else .failed;
}

/// The journal payload for a finished batch: kind, category and aggregate counts
/// only. It deliberately carries no path, URI, document content or provider
/// message, so it is safe to log without redaction.
pub fn eventPayload(buffer: []u8, kind: Kind, result: Outcome, successful: usize, skipped: usize, failed: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "kind={s} outcome={s} completed={d} skipped={d} failed={d}", .{ @tagName(kind), @tagName(result), successful, skipped, failed }) catch buffer[0..0];
}

const attrs = "standard::*,unix::mode,time::modified,time::modified-usec,etag::value,id::file,trash::*";

/// Per-file content digests recorded while a transfer streams bytes, keyed by
/// parse name. The fingerprint walk reuses them instead of re-reading every
/// copied byte, so a large copy hashes its content once (overlapped with I/O)
/// rather than twice. Only regular files are cached; directories and symlinks
/// are hashed from metadata, which is cheap to query.
const ContentCache = struct {
    map: std.StringHashMap([32]u8),
    fn init() ContentCache {
        return .{ .map = std.StringHashMap([32]u8).init(a) };
    }
    fn deinit(self: *ContentCache) void {
        var it = self.map.keyIterator();
        while (it.next()) |key| a.free(key.*);
        self.map.deinit();
    }
    fn put(self: *ContentCache, file: *gio.File, value: [32]u8) void {
        const parse_name = file.getParseName();
        defer glib.free(parse_name);
        const key = a.dupe(u8, std.mem.span(parse_name)) catch unreachable;
        self.map.put(key, value) catch {
            a.free(key);
            unreachable;
        };
    }
    fn get(self: *const ContentCache, file: *gio.File) ?[32]u8 {
        const parse_name = file.getParseName();
        defer glib.free(parse_name);
        return self.map.get(std.mem.span(parse_name));
    }
};

/// Which sides of a transfer to record content digests for. A copy only needs
/// the destination (for its undo fingerprint); a cross-filesystem move also
/// records the source so it can verify the source did not change without a
/// second full read.
const CopyCache = struct {
    src: ?*ContentCache = null,
    dst: ?*ContentCache = null,
};

pub const Pair = struct {
    source: *gio.File,
    destination: ?*gio.File = null,
    expected: ?[32]u8 = null,
    completed: bool = false,
    undone: bool = false,
    original_index: usize = 0,
    skipped: bool = false,
    /// Replace was chosen for this item: the existing destination goes to Trash
    /// before anything is written. Consumed by perform(), so a later collision
    /// on the same item asks again instead of replacing implicitly.
    replace: bool = false,
    /// This job moved an existing destination to Trash, so the receipt can say
    /// where the previous item went.
    replaced: bool = false,
    fingerprint: ?[32]u8 = null,
    pub fn deinit(self: *Pair) void {
        self.source.unref();
        if (self.destination) |f| f.unref();
    }
};
/// What the worker learned about the existing destination when a collision
/// stopped the batch. The dialog reads this instead of querying a possibly
/// remote file on the main thread, and uses it to explain or withhold Replace.
pub const ConflictInfo = struct {
    /// False when the destination could not be queried. Replace is then still
    /// offered and the transfer reports the real outcome.
    known: bool = false,
    directory: bool = false,
    can_trash: bool = false,
};
pub const Job = struct {
    kind: Kind,
    pairs: std.ArrayList(Pair) = .empty,
    cancel: *gio.Cancellable,
    /// Current top-level item. The worker advances it; the main thread reads it
    /// for progress reporting and advances it while a conflict pauses the batch.
    index: std.atomic.Value(usize) = .init(0),
    /// Total bytes of a single regular-file transfer, measured once by the
    /// worker. maxInt means the total is unknown (trees, batches, remote sizes).
    total_bytes: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    error_message: ?[:0]u8 = null,
    failures: std.ArrayList(u8) = .empty,
    conflict: bool = false,
    conflict_info: ConflictInfo = .{},
    cancelled: bool = false,
    undo: bool = false,
    redo: bool = false,
    cut: bool = false,
    clipboard_serial: u64 = 0,
    /// Paste/transfer jobs may resolve a destination equal to the source as a
    /// numbered duplicate. Rename jobs must not: their operands are equal only
    /// when the user kept the current name.
    self_duplicate: bool = false,
    bytes: std.atomic.Value(u64) = .init(0),
    nodes: usize = 0,
    /// Count of items that failed (not cancelled, not skipped), accumulated
    /// across the run/resume cycles of one batch.
    failed: usize = 0,
    pub fn create(kind: Kind) *Job {
        const j = a.create(Job) catch unreachable;
        j.* = .{ .kind = kind, .cancel = gio.Cancellable.new() };
        return j;
    }
    pub fn add(self: *Job, source: *gio.File, dest: ?*gio.File) void {
        source.ref();
        if (dest) |d| d.ref();
        self.pairs.append(a, .{ .source = source, .destination = dest }) catch unreachable;
    }
    pub fn destroy(self: *Job) void {
        for (self.pairs.items) |*p| p.deinit();
        self.pairs.deinit(a);
        if (self.error_message) |m| a.free(m);
        self.failures.deinit(a);
        self.cancel.unref();
        a.destroy(self);
    }
    fn setError(self: *Job, msg: []const u8) void {
        if (self.error_message) |old| a.free(old);
        self.error_message = a.dupeSentinel(u8, msg, 0) catch unreachable;
    }
    fn io(self: *Job, err: ?*glib.Error) Failure {
        if (err) |e| {
            defer e.free();
            self.setError(std.mem.span(e.f_message orelse "I/O error"));
            if (e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.exists)) != 0) return error.Conflict;
            if (e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.cancelled)) != 0) return error.Cancelled;
        }
        return error.Io;
    }
    fn check(self: *Job, depth: usize) Failure!void {
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        self.nodes += 1;
        if (depth > 128 or self.nodes > 1_000_000) return error.Limit;
    }
    pub fn run(self: *Job) void {
        self.conflict = false;
        self.measure();
        while (self.index.load(.monotonic) < self.pairs.items.len) {
            const p = &self.pairs.items[self.index.load(.monotonic)];
            self.perform(p) catch |err| {
                if (err == error.Conflict) {
                    self.conflict = true;
                    self.describeConflict(p);
                    return;
                }
                if (err == error.Cancelled) {
                    self.cancelled = true;
                    return;
                }
                const uri = p.source.getParseName();
                defer glib.free(uri);
                const line = std.fmt.allocPrint(a, "{s}: {s}\n", .{ uri, self.error_message orelse @errorName(err) }) catch unreachable;
                defer a.free(line);
                self.failures.appendSlice(a, line) catch unreachable;
                self.failed += 1;
                self.index.store(self.index.load(.monotonic) + 1, .monotonic);
                continue;
            };
            p.completed = true;
            // Copy and move record a fingerprint from their in-stream content
            // digests inside perform(); other kinds have tiny destinations, so a
            // direct digest here is cheap. The null check also provides a safe
            // fallback to a full digest if the cached walk could not complete.
            if (p.destination) |dest| {
                if (p.fingerprint == null) p.fingerprint = self.digest(dest) catch null;
            }
            self.index.store(self.index.load(.monotonic) + 1, .monotonic);
        }
    }
    /// A single regular file has a cheap known total; trees, batches and remote
    /// sources stay unknown rather than paying for a recursive pre-scan. Runs on
    /// the worker before the first item; a failed query leaves the total unknown.
    fn measure(self: *Job) void {
        if (self.total_bytes.load(.monotonic) != std.math.maxInt(u64)) return;
        if (self.kind != .copy and self.kind != .move and self.kind != .restore) return;
        if (self.pairs.items.len != 1) return;
        const p = &self.pairs.items[0];
        var err: ?*glib.Error = null;
        const info = p.source.queryInfo("standard::type,standard::size", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer info.unref();
        if (info.getFileType() == .regular) self.total_bytes.store(@intCast(@max(0, info.getSize())), .monotonic);
    }
    fn perform(self: *Job, p: *Pair) Failure!void {
        if (self.error_message) |m| {
            a.free(m);
            self.error_message = null;
        }
        try self.check(0);
        if (p.expected) |expected| {
            const actual = try self.digest(p.source);
            if (!std.mem.eql(u8, &actual, &expected)) {
                self.setError("The item changed after the original operation. It was left untouched.");
                return error.Changed;
            }
        }
        if (self.kind == .restore and p.destination == null) {
            var e: ?*glib.Error = null;
            const info = p.source.queryInfo("trash::orig-path", .{}, self.cancel, &e) orelse return self.io(e);
            defer info.unref();
            const path = info.getAttributeByteString("trash::orig-path") orelse {
                self.setError("Original location is unavailable. Use Restore to… instead.");
                return error.Unsupported;
            };
            p.destination = gio.File.newForPath(path);
        }
        if (p.destination) |dest| {
            if (dest.equal(p.source) != 0) {
                // Pasting onto the source itself is a duplicate, not recursion:
                // keep the source and transfer to a numbered sibling instead.
                if ((self.kind == .copy or self.kind == .move) and self.self_duplicate) {
                    const renamed = try self.numberedSibling(dest);
                    p.destination = renamed;
                    dest.unref();
                } else if (self.kind != .mkdir and self.kind != .document) {
                    self.setError("A folder cannot be copied or moved into itself.");
                    return error.InvalidTarget;
                }
            } else if (dest.hasPrefix(p.source) != 0) {
                if (self.kind != .mkdir and self.kind != .document) {
                    self.setError("A folder cannot be copied or moved into itself.");
                    return error.InvalidTarget;
                }
            }
            // Also reject local aliases through a symlinked destination parent.
            if (self.kind == .copy or self.kind == .move) try self.checkLocalTarget(p.source, p.destination.?);
        }
        if (p.replace) try self.replaceTarget(p);
        var err: ?*glib.Error = null;
        switch (self.kind) {
            .copy => {
                var cache = ContentCache.init();
                defer cache.deinit();
                var caches: CopyCache = .{ .dst = &cache };
                try self.copyTree(p.source, p.destination.?, 0, &caches);
                p.fingerprint = self.cachedDigest(p.destination.?, &cache, true) catch null;
            },
            .move, .restore => try self.moveTree(p),
            .trash => if (p.source.trash(self.cancel, &err) == 0) {
                return self.io(err);
            },
            .empty_trash => {
                const entries = p.source.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const info = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer info.unref();
                    const f = p.source.getChild(info.getName());
                    defer f.unref();
                    try self.removeTree(f, 0, self.cancel);
                }
            },
            .delete => try self.removeTree(p.source, 0, self.cancel),
            .mkdir => if (p.destination.?.makeDirectory(self.cancel, &err) == 0) {
                return self.io(err);
            },
            .document => {
                const stream = p.destination.?.create(.{}, self.cancel, &err) orelse return self.io(err);
                defer stream.unref();
                if (stream.as(gio.OutputStream).close(self.cancel, &err) == 0) return self.io(err);
            },
            .link => {
                const path = p.source.getPath() orelse return error.Unsupported;
                defer glib.free(path);
                if (p.destination.?.makeSymbolicLink(path, self.cancel, &err) == 0) return self.io(err);
            },
        }
    }
    fn checkLocalTarget(self: *Job, src: *gio.File, dest: *gio.File) Failure!void {
        var err: ?*glib.Error = null;
        const info = src.queryInfo("standard::type", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        if (info.getFileType() != .directory) return;
        const src_path = src.getPath() orelse return;
        defer glib.free(src_path);
        const parent = dest.getParent() orelse return error.InvalidTarget;
        defer parent.unref();
        const parent_path = parent.getPath() orelse return;
        defer glib.free(parent_path);
        const real_src = realpath(src_path, null) orelse return;
        defer std.c.free(real_src);
        const real_parent = realpath(parent_path, null) orelse return;
        defer std.c.free(real_parent);
        const s = std.mem.span(real_src);
        const d = std.mem.span(real_parent);
        if (std.mem.eql(u8, s, d) or (std.mem.startsWith(u8, d, s) and d.len > s.len and d[s.len] == '/')) return error.InvalidTarget;
    }
    pub fn copyTree(self: *Job, src: *gio.File, dst: *gio.File, depth: usize, caches: ?*CopyCache) Failure!void {
        try self.check(depth);
        var err: ?*glib.Error = null;
        const info = src.queryInfo(attrs, .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        switch (info.getFileType()) {
            .directory => {
                if (dst.makeDirectory(self.cancel, &err) == 0) return self.io(err);
                errdefer self.removeTree(dst, 0, null) catch {};
                const entries = src.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const child = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer child.unref();
                    const from = src.getChild(child.getName());
                    defer from.unref();
                    const to = dst.getChild(child.getName());
                    defer to.unref();
                    try self.copyTree(from, to, depth + 1, caches);
                }
                // Copy permissions/timestamps after children so read-only source directories work.
                try self.copyMetadata(info, dst);
            },
            .symbolic_link => {
                const target = info.getSymlinkTarget() orelse return error.Unsupported;
                if (dst.makeSymbolicLink(target, self.cancel, &err) == 0) return self.io(err);
            },
            .regular => {
                const input = src.read(self.cancel, &err) orelse return self.io(err);
                defer input.unref();
                const output = dst.create(.{ .private = true }, self.cancel, &err) orelse return self.io(err);
                defer output.unref();
                errdefer {
                    _ = output.as(gio.OutputStream).close(null, null);
                    _ = dst.delete(null, null);
                }
                var buffer: [128 * 1024]u8 = undefined;
                var content_hash = std.crypto.hash.sha2.Sha256.init(.{});
                while (true) {
                    const n = input.as(gio.InputStream).read(&buffer, buffer.len, self.cancel, &err);
                    if (n < 0) return self.io(err);
                    if (n == 0) break;
                    if (output.as(gio.OutputStream).writeAll(&buffer, @intCast(n), null, self.cancel, &err) == 0) return self.io(err);
                    content_hash.update(buffer[0..@intCast(n)]);
                    _ = self.bytes.fetchAdd(@intCast(n), .monotonic);
                }
                if (output.as(gio.OutputStream).close(self.cancel, &err) == 0) return self.io(err);
                try self.copyMetadata(info, dst);
                // The bytes written to the destination are exactly the bytes read
                // from the source, so one in-stream digest serves both sides.
                if (caches) |cc| {
                    const digest_ = content_hash.finalResult();
                    if (cc.src) |c| c.put(src, digest_);
                    if (cc.dst) |c| c.put(dst, digest_);
                }
            },
            else => return error.Unsupported,
        }
    }
    fn copyMetadata(self: *Job, source: *gio.FileInfo, dest: *gio.File) Failure!void {
        const attributes = gio.FileInfo.new();
        defer attributes.unref();
        if (source.hasAttribute("unix::mode") != 0) attributes.setAttributeUint32("unix::mode", source.getAttributeUint32("unix::mode") & 0o777);
        if (source.hasAttribute("time::modified") != 0) attributes.setAttributeUint64("time::modified", source.getAttributeUint64("time::modified"));
        if (source.hasAttribute("time::modified-usec") != 0) attributes.setAttributeUint32("time::modified-usec", source.getAttributeUint32("time::modified-usec"));
        var err: ?*glib.Error = null;
        if (dest.setAttributesFromInfo(attributes, .{ .nofollow_symlinks = true }, self.cancel, &err) == 0) return self.io(err);
    }
    pub fn removeTree(self: *Job, file: *gio.File, depth: usize, cancel: ?*gio.Cancellable) Failure!void {
        if (depth > 128) return error.Limit;
        var err: ?*glib.Error = null;
        const info = file.queryInfo("standard::type", .{ .nofollow_symlinks = true }, cancel, &err) orelse return self.io(err);
        defer info.unref();
        if (info.getFileType() == .directory) {
            const entries = file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, cancel, &err) orelse return self.io(err);
            defer entries.unref();
            while (true) {
                const child = entries.nextFile(cancel, &err) orelse {
                    if (err != null) return self.io(err);
                    break;
                };
                defer child.unref();
                const f = file.getChild(child.getName());
                defer f.unref();
                try self.removeTree(f, depth + 1, cancel);
            }
        }
        if (file.delete(cancel, &err) == 0) return self.io(err);
    }
    fn moveTree(self: *Job, p: *Pair) Failure!void {
        const src = p.source;
        const dst = p.destination.?;
        var err: ?*glib.Error = null;
        if (src.move(dst, .{ .nofollow_symlinks = true, .no_fallback_for_move = true }, self.cancel, null, null, &err) != 0) return;
        if (err) |e| {
            const fallback = e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.not_supported)) != 0 or e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.would_recurse)) != 0;
            if (!fallback) return self.io(err);
            e.free();
            err = null;
        }
        // A pre-copy content baseline is still read once so a source edited
        // during the transfer is detected with a full content comparison. The
        // post-copy source and destination digests come from the in-stream
        // caches instead of two more full reads.
        const before = try self.contentDigest(src);
        var src_cache = ContentCache.init();
        defer src_cache.deinit();
        var dst_cache = ContentCache.init();
        defer dst_cache.deinit();
        var caches: CopyCache = .{ .src = &src_cache, .dst = &dst_cache };
        try self.copyTree(src, dst, 0, &caches);
        // Source changes and cancellation leave the original intact. Keep the copy visible.
        const after = try self.cachedDigest(src, &src_cache, false);
        const copied = try self.cachedDigest(dst, &dst_cache, false);
        if (!std.mem.eql(u8, &before, &after) or !std.mem.eql(u8, &after, &copied)) return error.Changed;
        try self.check(0);
        // Commit phase is non-cancellable: destination is complete and verified.
        try self.removeTree(src, 0, null);
        p.fingerprint = self.cachedDigest(dst, &dst_cache, true) catch null;
    }
    pub fn digest(self: *Job, file: *gio.File) Failure![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashTree(file, &hash, 0, true, null);
        return hash.finalResult();
    }
    fn contentDigest(self: *Job, file: *gio.File) Failure![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashTree(file, &hash, 0, false, null);
        return hash.finalResult();
    }
    /// Same walk as digest/contentDigest, but regular-file content digests come
    /// from a cache recorded during the transfer instead of a fresh read. Because
    /// the assembly is shared with hashTree, the result is byte-identical to a
    /// full digest of the same tree.
    fn cachedDigest(self: *Job, file: *gio.File, cache: *const ContentCache, metadata: bool) Failure![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashTree(file, &hash, 0, metadata, cache);
        return hash.finalResult();
    }
    fn fileContentDigest(self: *Job, file: *gio.File) Failure![32]u8 {
        var err: ?*glib.Error = null;
        const input = file.read(self.cancel, &err) orelse return self.io(err);
        defer input.unref();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = input.as(gio.InputStream).read(&buf, buf.len, self.cancel, &err);
            if (n < 0) return self.io(err);
            if (n == 0) break;
            hash.update(buf[0..@intCast(n)]);
        }
        return hash.finalResult();
    }
    fn hashTree(self: *Job, file: *gio.File, hash: *std.crypto.hash.sha2.Sha256, depth: usize, metadata: bool, cache: ?*const ContentCache) Failure!void {
        try self.check(depth);
        var err: ?*glib.Error = null;
        const info = file.queryInfo(attrs, .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        hash.update(&.{@intCast(@backingInt(info.getFileType()))});
        // Undo also checks identity, mode and timestamp; transfer verification compares contents.
        if (metadata) {
            const mode = info.getAttributeUint32("unix::mode");
            const seconds = info.getAttributeUint64("time::modified");
            const micros = info.getAttributeUint32("time::modified-usec");
            hash.update(std.mem.asBytes(&mode));
            hash.update(std.mem.asBytes(&seconds));
            hash.update(std.mem.asBytes(&micros));
            hash.update(std.mem.span(info.getAttributeString("id::file") orelse ""));
            hash.update(&.{0});
        }
        if (info.getFileType() == .regular) {
            const size = info.getSize();
            hash.update(std.mem.asBytes(&size));
        }
        switch (info.getFileType()) {
            .directory => {
                var names: std.ArrayList([:0]u8) = .empty;
                defer {
                    for (names.items) |n| a.free(n);
                    names.deinit(a);
                }
                const entries = file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const child = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer child.unref();
                    if (names.items.len >= 100_000) return error.Limit;
                    names.append(a, a.dupeSentinel(u8, std.mem.span(child.getName()), 0) catch unreachable) catch unreachable;
                }
                std.mem.sort([:0]u8, names.items, {}, struct {
                    fn less(_: void, x: [:0]u8, y: [:0]u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.less);
                for (names.items) |n| {
                    hash.update(n);
                    hash.update(&.{0});
                    const child = file.getChild(n);
                    defer child.unref();
                    try self.hashTree(child, hash, depth + 1, metadata, cache);
                }
            },
            .symbolic_link => hash.update(std.mem.span(info.getSymlinkTarget() orelse "")),
            .regular => {
                // Feed a per-file content digest rather than the raw bytes so a
                // transfer can reuse the digest it computed while streaming. The
                // uncached path reads the file to produce the same digest.
                const content_sha = if (cache) |c| (c.get(file) orelse return error.Unsupported) else try self.fileContentDigest(file);
                hash.update(&content_sha);
            },
            else => return error.Unsupported,
        }
        hash.update(&.{0xff});
    }
    /// The Replace resolution for the item that stopped the batch. The dialog
    /// offers it only for transfers, never for undo/redo: a collision there
    /// means the destination changed underneath the journal.
    pub fn replace(self: *Job) void {
        self.pairs.items[self.index.load(.monotonic)].replace = true;
    }
    /// Replace is recoverable: the existing destination is moved to Trash before
    /// the transfer writes anything, so the previous item can be restored. When
    /// it cannot be trashed the item is kept and the failure is reported, so
    /// Replace never becomes a silent permanent deletion.
    fn replaceTarget(self: *Job, p: *Pair) Failure!void {
        p.replace = false;
        const dest = p.destination orelse return;
        var err: ?*glib.Error = null;
        if (dest.trash(self.cancel, &err) != 0) {
            p.replaced = true;
            return;
        }
        if (err) |e| {
            defer e.free();
            // A destination that vanished needs no replacement; the transfer
            // creates it.
            if (e.matches(gio.ioErrorQuark(), @backingInt(gio.IOErrorEnum.not_found)) != 0) return;
            const msg = std.fmt.allocPrint(a, "The existing item could not be moved to Trash ({s}), so it was kept.", .{std.mem.span(e.f_message orelse "Trash is unavailable")}) catch unreachable;
            defer a.free(msg);
            self.setError(msg);
            return error.Unsupported;
        }
        self.setError("The existing item could not be moved to Trash, so it was kept.");
        return error.Unsupported;
    }
    /// Records the collision facts the dialog needs. This runs on the worker, so
    /// a slow or remote destination never blocks the main thread; a failed query
    /// leaves the information unknown rather than guessing.
    fn describeConflict(self: *Job, p: *Pair) void {
        self.conflict_info = .{};
        const dest = p.destination orelse return;
        var err: ?*glib.Error = null;
        const info = dest.queryInfo("standard::type,access::can-trash", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer info.unref();
        self.conflict_info = .{
            .known = true,
            .directory = info.getFileType() == .directory,
            .can_trash = info.getAttributeBoolean("access::can-trash") != 0,
        };
    }
    /// First free sibling of `file` named "base (2)", "base (3)", …, so duplicate
    /// paste and Keep both produce readable numbered copies instead of random
    /// ids. Bounded so an almost-full directory cannot spin forever.
    fn numberedSibling(self: *Job, file: *gio.File) Failure!*gio.File {
        const parent = file.getParent() orelse return error.InvalidTarget;
        defer parent.unref();
        const base = file.getBasename() orelse return error.InvalidTarget;
        defer glib.free(base);
        var n: usize = 2;
        while (n < 10_000) : (n += 1) {
            try self.check(0);
            const name = std.fmt.allocPrintSentinel(a, "{s} ({d})", .{ std.mem.span(base), n }, 0) catch unreachable;
            defer a.free(name);
            const candidate = parent.getChild(name);
            if (candidate.queryExists(self.cancel) == 0) return candidate;
            candidate.unref();
        }
        return error.Limit;
    }
    pub fn keepBoth(self: *Job) void {
        const p = &self.pairs.items[self.index.load(.monotonic)];
        const old = p.destination orelse return;
        const renamed = self.numberedSibling(old) catch return;
        p.destination = renamed;
        old.unref();
    }
};
extern "c" fn realpath([*:0]const u8, ?[*]u8) ?[*:0]u8;

const Fixture = struct {
    root: *gio.File,
    path: [*:0]u8,
    fn init() Fixture {
        const path = glib.Dir.makeTmp("phyto-engine-XXXXXX", null) orelse unreachable;
        return .{ .root = gio.File.newForPath(path), .path = path };
    }
    fn deinit(self: *Fixture) void {
        const cleaner = Job.create(.delete);
        defer cleaner.destroy();
        cleaner.removeTree(self.root, 0, null) catch {};
        self.root.unref();
        glib.free(self.path);
    }
    fn child(self: *Fixture, name: [*:0]const u8) *gio.File {
        return self.root.getChild(name);
    }
};
fn writeFixture(file: *gio.File, value: []const u8) void {
    std.debug.assert(file.replaceContents(value.ptr, value.len, null, 0, .{}, null, null, null) != 0);
}
fn expectContents(file: *gio.File, expected: []const u8) !void {
    var contents: [*]u8 = undefined;
    var length: usize = 0;
    std.debug.assert(file.loadContents(null, &contents, &length, null, null) != 0);
    defer glib.free(contents);
    try std.testing.expectEqualStrings(expected, contents[0..length]);
}
fn setMode(file: *gio.File, mode: u32) void {
    const info = gio.FileInfo.new();
    defer info.unref();
    info.setAttributeUint32("unix::mode", mode);
    std.debug.assert(file.setAttributesFromInfo(info, .{}, null, null) != 0);
}
test "recursive copy preserves bytes, symlink identity and existing destinations" {
    var f = Fixture.init();
    defer f.deinit();
    const source = f.child("source");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const nested = source.getChild("nested");
    defer nested.unref();
    try std.testing.expect(nested.makeDirectory(null, null) != 0);
    const content = nested.getChild("spaces ü\n-file");
    defer content.unref();
    writeFixture(content, "untouched source bytes");
    const link = source.getChild("loop");
    defer link.unref();
    try std.testing.expect(link.makeSymbolicLink(".", null, null) != 0);
    const dest = f.child("copy");
    defer dest.unref();
    const job = Job.create(.copy);
    defer job.destroy();
    job.add(source, dest);
    job.run();
    if (!job.pairs.items[0].completed) std.debug.print("Copy failure: {s} conflict={any}\n", .{ job.failures.items, job.conflict });
    try std.testing.expect(job.pairs.items[0].completed);
    const before = try job.contentDigest(source);
    const after = try job.contentDigest(dest);
    try std.testing.expectEqualSlices(u8, &before, &after);
    const again = Job.create(.copy);
    defer again.destroy();
    again.add(source, dest);
    again.run();
    try std.testing.expect(again.conflict);
    const unchanged = try job.contentDigest(dest);
    try std.testing.expectEqualSlices(u8, &before, &unchanged);
}
test "cached transfer fingerprint equals a full digest for files, trees and symlinks" {
    var f = Fixture.init();
    defer f.deinit();
    const source = f.child("source");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const top = source.getChild("top.bin");
    defer top.unref();
    writeFixture(top, "top-level bytes");
    const nested = source.getChild("nested");
    defer nested.unref();
    try std.testing.expect(nested.makeDirectory(null, null) != 0);
    const inner = nested.getChild("inner.bin");
    defer inner.unref();
    writeFixture(inner, "nested bytes");
    const link = source.getChild("link");
    defer link.unref();
    try std.testing.expect(link.makeSymbolicLink("top.bin", null, null) != 0);
    const dest = f.child("copy");
    defer dest.unref();
    const job = Job.create(.copy);
    defer job.destroy();
    job.add(source, dest);
    job.run();
    try std.testing.expect(job.pairs.items[0].completed);
    // The fingerprint recorded from in-stream digests must match a fresh full
    // digest of the destination, including metadata, structure and content.
    const full = try job.digest(dest);
    try std.testing.expectEqualSlices(u8, &full, &job.pairs.items[0].fingerprint.?);
    // Undo relies on this equality: a changed destination must still be detected.
    const dest_nested = dest.getChild("nested");
    defer dest_nested.unref();
    const dest_inner = dest_nested.getChild("inner.bin");
    defer dest_inner.unref();
    writeFixture(dest_inner, "tampered");
    const changed = try job.digest(dest);
    try std.testing.expect(!std.mem.eql(u8, &changed, &job.pairs.items[0].fingerprint.?));
}
test "in-stream content caches reproduce full content digests for a copied tree" {
    var f = Fixture.init();
    defer f.deinit();
    const source = f.child("source");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const one = source.getChild("one.bin");
    defer one.unref();
    writeFixture(one, "first file bytes");
    const sub = source.getChild("sub");
    defer sub.unref();
    try std.testing.expect(sub.makeDirectory(null, null) != 0);
    const two = sub.getChild("two.bin");
    defer two.unref();
    writeFixture(two, "second file bytes");
    const dest = f.child("dest");
    defer dest.unref();
    var src_cache = ContentCache.init();
    defer src_cache.deinit();
    var dst_cache = ContentCache.init();
    defer dst_cache.deinit();
    var caches: CopyCache = .{ .src = &src_cache, .dst = &dst_cache };
    const job = Job.create(.copy);
    defer job.destroy();
    try job.copyTree(source, dest, 0, &caches);
    const src_full = try job.contentDigest(source);
    const src_cached = try job.cachedDigest(source, &src_cache, false);
    try std.testing.expectEqualSlices(u8, &src_full, &src_cached);
    const dst_full = try job.contentDigest(dest);
    const dst_cached = try job.cachedDigest(dest, &dst_cache, false);
    try std.testing.expectEqualSlices(u8, &dst_full, &dst_cached);
    try std.testing.expectEqualSlices(u8, &src_full, &dst_full);
}
test "cancelled batches and invalid descendant targets retain sources" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("src");
    defer src.unref();
    writeFixture(src, "keep");
    const dest = f.child("dest");
    defer dest.unref();
    const cancelled = Job.create(.move);
    defer cancelled.destroy();
    cancelled.add(src, dest);
    cancelled.cancel.cancel();
    cancelled.run();
    try std.testing.expect(cancelled.cancelled);
    try std.testing.expect(src.queryExists(null) != 0);
    try std.testing.expect(dest.queryExists(null) == 0);
    const folder = f.child("folder");
    defer folder.unref();
    _ = folder.makeDirectory(null, null);
    const child = folder.getChild("inside");
    defer child.unref();
    const invalid = Job.create(.copy);
    defer invalid.destroy();
    invalid.add(folder, child);
    invalid.run();
    try std.testing.expect(invalid.failures.items.len > 0);
    try std.testing.expect(child.queryExists(null) == 0);
}
test "undo fingerprint rejects externally changed files and batch failures do not lose siblings" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("src");
    defer src.unref();
    writeFixture(src, "original");
    const dest = f.child("dest");
    defer dest.unref();
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    if (!j.pairs.items[0].completed) std.debug.print("Copy failure: {s} conflict={any}\n", .{ j.failures.items, j.conflict });
    const undo = Job.create(.delete);
    defer undo.destroy();
    undo.add(dest, null);
    undo.pairs.items[0].expected = j.pairs.items[0].fingerprint;
    writeFixture(dest, "new external content");
    undo.run();
    try std.testing.expect(!undo.pairs.items[0].completed);
    try std.testing.expect(dest.queryExists(null) != 0);
    const absent = f.child("absent");
    defer absent.unref();
    const one = f.child("one");
    defer one.unref();
    const two = f.child("two");
    defer two.unref();
    const batch = Job.create(.copy);
    defer batch.destroy();
    batch.add(absent, one);
    batch.add(src, two);
    batch.run();
    try std.testing.expect(batch.failures.items.len > 0);
    try std.testing.expect(batch.pairs.items[1].completed);
    try std.testing.expect(src.queryExists(null) != 0);
}

test "cross-filesystem moves verify a complete directory before source removal" {
    // /tmp and the project filesystem are distinct in the native qualification environment.
    var f = Fixture.init();
    defer f.deinit();
    const cwd = glib.getCurrentDir();
    defer glib.free(cwd);
    const id = glib.uuidStringRandom();
    defer glib.free(id);
    const path = std.fmt.allocPrintSentinel(a, "{s}/.phyto-engine-{s}", .{ cwd, id }, 0) catch unreachable;
    defer a.free(path);
    const destination = gio.File.newForPath(path);
    defer destination.unref();
    const cleaner = Job.create(.delete);
    defer {
        cleaner.removeTree(destination, 0, null) catch {};
        cleaner.destroy();
    }
    const source = f.child("move-directory");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const item = source.getChild("bytes");
    defer item.unref();
    writeFixture(item, "different filesystem content");
    const link = source.getChild("link");
    defer link.unref();
    try std.testing.expect(link.makeSymbolicLink("bytes", null, null) != 0);
    const move = Job.create(.move);
    defer move.destroy();
    const expected = try move.contentDigest(source);
    move.add(source, destination);
    move.run();
    try std.testing.expect(move.pairs.items[0].completed);
    try std.testing.expect(source.queryExists(null) == 0);
    const actual = try move.contentDigest(destination);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "batch outcome distinguishes cancellation, conflict, partial and total failure" {
    const t = std.testing;
    try t.expectEqual(Outcome.ok, outcome(false, 3, 0, 0));
    try t.expectEqual(Outcome.cancelled, outcome(true, 1, 0, 0));
    // A skipped item with no failures is a conflict resolved by skipping.
    try t.expectEqual(Outcome.conflict, outcome(false, 2, 1, 0));
    try t.expectEqual(Outcome.partial, outcome(false, 1, 0, 1));
    try t.expectEqual(Outcome.failed, outcome(false, 0, 0, 2));
    // Cancellation wins even when items also failed.
    try t.expectEqual(Outcome.cancelled, outcome(true, 0, 0, 1));
}

test "a single regular file measures its total; trees and batches stay unknown" {
    var f = Fixture.init();
    defer f.deinit();
    const t = std.testing;
    const file = f.child("sized.bin");
    defer file.unref();
    writeFixture(file, "0123456789");
    const dest = f.child("sized-copy");
    defer dest.unref();
    const single = Job.create(.copy);
    defer single.destroy();
    single.add(file, dest);
    single.run();
    try t.expect(single.pairs.items[0].completed);
    try t.expectEqual(@as(u64, 10), single.total_bytes.load(.monotonic));
    try t.expectEqual(@as(u64, 10), single.bytes.load(.monotonic));
    try t.expectEqual(@as(usize, 1), single.index.load(.monotonic));
    // A directory source has no cheap total.
    const tree = f.child("tree");
    defer tree.unref();
    try t.expect(tree.makeDirectory(null, null) != 0);
    const tree_dest = f.child("tree-copy");
    defer tree_dest.unref();
    const dir_job = Job.create(.copy);
    defer dir_job.destroy();
    dir_job.add(tree, tree_dest);
    dir_job.run();
    try t.expectEqual(std.math.maxInt(u64), dir_job.total_bytes.load(.monotonic));
    // A multi-item batch does not pre-scan either.
    const second = f.child("second.bin");
    defer second.unref();
    writeFixture(second, "abc");
    const batch_dest = f.child("batch-copy");
    defer batch_dest.unref();
    const batch = Job.create(.copy);
    defer batch.destroy();
    batch.add(file, batch_dest);
    batch.add(second, f.child("second-copy"));
    batch.run();
    try t.expectEqual(std.math.maxInt(u64), batch.total_bytes.load(.monotonic));
}

test "the batch event payload carries counts and no path, uri or content" {
    const t = std.testing;
    var buffer: [128]u8 = undefined;
    const text = eventPayload(&buffer, .copy, .partial, 1, 0, 1);
    try t.expectEqualStrings("kind=copy outcome=partial completed=1 skipped=0 failed=1", text);
    // Only closed tag names and numbers, so nothing can carry a filename, a URI
    // scheme or document bytes into the journal.
    try t.expect(std.mem.indexOf(u8, text, "/") == null);
    try t.expect(std.mem.indexOf(u8, text, ":") == null);
}

test "a job counts failed items separately from completed ones" {
    var f = Fixture.init();
    defer f.deinit();
    const good = f.child("good");
    defer good.unref();
    writeFixture(good, "bytes");
    const absent = f.child("absent");
    defer absent.unref();
    const dest_good = f.child("dest-good");
    defer dest_good.unref();
    const dest_absent = f.child("dest-absent");
    defer dest_absent.unref();
    const job = Job.create(.copy);
    defer job.destroy();
    // One missing source (fails) and one real source (succeeds): a partial batch.
    job.add(absent, dest_absent);
    job.add(good, dest_good);
    job.run();
    try std.testing.expectEqual(@as(usize, 1), job.failed);
    var successful: usize = 0;
    var skipped: usize = 0;
    for (job.pairs.items) |p| {
        if (p.completed) successful += 1;
        if (p.skipped) skipped += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), successful);
    try std.testing.expectEqual(Outcome.partial, outcome(job.cancelled, successful, skipped, job.failed));
}

test "replace trashes the existing destination before transferring the source" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("replace-copy-src");
    defer src.unref();
    writeFixture(src, "new bytes");
    const dest = f.child("replace-copy-dest");
    defer dest.unref();
    writeFixture(dest, "previous bytes");
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    try std.testing.expect(j.conflict);
    try std.testing.expect(j.conflict_info.known);
    try std.testing.expect(j.conflict_info.can_trash);
    try std.testing.expect(!j.conflict_info.directory);
    // The collision itself changed nothing.
    try expectContents(dest, "previous bytes");
    j.replace();
    j.run();
    try std.testing.expect(!j.conflict);
    const p = j.pairs.items[0];
    try std.testing.expect(p.completed);
    // Set only after GIO moved the previous item to Trash, so the receipt can
    // promise recovery. The native suite restores it end to end.
    try std.testing.expect(p.replaced);
    // The resolution is one-shot: a later collision must ask again.
    try std.testing.expect(!p.replace);
    try expectContents(dest, "new bytes");
    try expectContents(src, "new bytes");
    // Undo still guards the new destination, not the item that was replaced.
    const full = try j.digest(dest);
    try std.testing.expectEqualSlices(u8, &full, &p.fingerprint.?);
}

test "replace swaps a whole folder rather than merging into the existing one" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("replace-folder-src");
    defer src.unref();
    try std.testing.expect(src.makeDirectory(null, null) != 0);
    const incoming = src.getChild("incoming.txt");
    defer incoming.unref();
    writeFixture(incoming, "incoming");
    const dest = f.child("replace-folder-dest");
    defer dest.unref();
    try std.testing.expect(dest.makeDirectory(null, null) != 0);
    const stale = dest.getChild("stale.txt");
    defer stale.unref();
    writeFixture(stale, "stale");
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    try std.testing.expect(j.conflict);
    try std.testing.expect(j.conflict_info.directory);
    j.replace();
    j.run();
    try std.testing.expect(j.pairs.items[0].completed);
    try std.testing.expect(j.pairs.items[0].replaced);
    try std.testing.expect(stale.queryExists(null) == 0);
    const copied = dest.getChild("incoming.txt");
    defer copied.unref();
    try expectContents(copied, "incoming");
}

test "replace lets a cut/paste move overwrite and still removes the source last" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("replace-move-src");
    defer src.unref();
    writeFixture(src, "moved bytes");
    const dest = f.child("replace-move-dest");
    defer dest.unref();
    writeFixture(dest, "previous bytes");
    const j = Job.create(.move);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    try std.testing.expect(j.conflict);
    try std.testing.expect(src.queryExists(null) != 0);
    j.replace();
    j.run();
    try std.testing.expect(j.pairs.items[0].completed);
    try std.testing.expect(src.queryExists(null) == 0);
    try expectContents(dest, "moved bytes");
}

test "an untrashable destination is kept and reported instead of replaced" {
    // Root bypasses the directory permission this test relies on.
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var f = Fixture.init();
    defer f.deinit();
    const locked = f.child("locked");
    defer locked.unref();
    try std.testing.expect(locked.makeDirectory(null, null) != 0);
    const dest = locked.getChild("replace-locked-dest");
    defer dest.unref();
    writeFixture(dest, "previous bytes");
    setMode(locked, 0o555);
    defer setMode(locked, 0o755);
    const src = f.child("replace-locked-src");
    defer src.unref();
    writeFixture(src, "new bytes");
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    try std.testing.expect(j.conflict);
    try std.testing.expect(j.conflict_info.known);
    try std.testing.expect(!j.conflict_info.can_trash);
    j.replace();
    j.run();
    try std.testing.expect(!j.pairs.items[0].completed);
    try std.testing.expect(!j.pairs.items[0].replaced);
    try std.testing.expectEqual(@as(usize, 1), j.failed);
    try std.testing.expect(j.failures.items.len > 0);
    try expectContents(dest, "previous bytes");
    try expectContents(src, "new bytes");
}

test "pasting onto the source itself creates numbered duplicates instead of failing" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("dup");
    defer src.unref();
    try std.testing.expect(src.makeDirectory(null, null) != 0);
    const inner = src.getChild("inner.txt");
    defer inner.unref();
    writeFixture(inner, "duplicate me");
    const first = Job.create(.copy);
    defer first.destroy();
    first.self_duplicate = true;
    first.add(src, src);
    first.run();
    try std.testing.expect(!first.conflict);
    try std.testing.expect(first.pairs.items[0].completed);
    const second = f.child("dup (2)");
    defer second.unref();
    const copied = second.getChild("inner.txt");
    defer copied.unref();
    try expectContents(copied, "duplicate me");
    try expectContents(inner, "duplicate me");
    const again = Job.create(.copy);
    defer again.destroy();
    again.self_duplicate = true;
    again.add(src, src);
    again.run();
    try std.testing.expect(again.pairs.items[0].completed);
    const third = f.child("dup (3)");
    defer third.unref();
    try std.testing.expect(third.queryExists(null) != 0);
    // A true descendant target still recurses and must stay rejected.
    const nested = src.getChild("inside");
    defer nested.unref();
    const recursive = Job.create(.copy);
    defer recursive.destroy();
    recursive.add(src, nested);
    recursive.run();
    try std.testing.expect(recursive.failures.items.len > 0);
    try std.testing.expect(nested.queryExists(null) == 0);
    // Without paste intent (a rename keeps the current name) equal operands
    // stay an error instead of inventing a numbered rename.
    const rename = Job.create(.move);
    defer rename.destroy();
    rename.add(src, src);
    rename.run();
    try std.testing.expect(rename.failures.items.len > 0);
    try std.testing.expect(src.queryExists(null) != 0);
}

test "cut and paste into the same folder renames to a numbered sibling" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("move-dup");
    defer src.unref();
    writeFixture(src, "moved");
    const j = Job.create(.move);
    defer j.destroy();
    j.self_duplicate = true;
    j.add(src, src);
    j.run();
    try std.testing.expect(j.pairs.items[0].completed);
    try std.testing.expect(src.queryExists(null) == 0);
    const renamed = f.child("move-dup (2)");
    defer renamed.unref();
    try expectContents(renamed, "moved");
}

test "keep both numbers successive copies of the same destination" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("keep-src");
    defer src.unref();
    writeFixture(src, "bytes");
    const dest = f.child("keep-dest");
    defer dest.unref();
    writeFixture(dest, "existing");
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    try std.testing.expect(j.conflict);
    j.keepBoth();
    j.run();
    try std.testing.expect(j.pairs.items[0].completed);
    const two = f.child("keep-dest (2)");
    defer two.unref();
    try expectContents(two, "bytes");
    try expectContents(dest, "existing");
    const again = Job.create(.copy);
    defer again.destroy();
    again.add(src, dest);
    again.run();
    try std.testing.expect(again.conflict);
    again.keepBoth();
    again.run();
    try std.testing.expect(again.pairs.items[0].completed);
    const three = f.child("keep-dest (3)");
    defer three.unref();
    try expectContents(three, "bytes");
}
