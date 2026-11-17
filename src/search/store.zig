//! Bounded on-disk semantic index. Vectors and entry metadata live in memory;
//! passage text stays in records.bin and is read only for the few search hits
//! that need it. Commits rewrite atomically (manifest renamed last); a torn
//! commit is detected on load and reported as corruption, never a crash.
//! Stores are heap-pinned: their maps allocate from the embedded arena, so a
//! Store must never move after creation (same contract as launcher jobs).
const std = @import("std");
const chunk = @import("chunk.zig");
pub const dimensions = 256; // MRL truncation of the 768d model output.
pub const schema = 1;
pub const max_chunks = 200_000;
pub const max_files = 50_000;
pub const max_path = 4096;
const manifest_limit = 64 * 1024;

pub const Identity = struct { model_id: []const u8, model_sha256: []const u8 };
pub const Entry = struct {
    path: []const u8,
    mtime_ns: i64,
    size: u64,
    ordinal: u32,
    offset: u64 = 0,
    passage_len: u32 = 0,
    passage: ?[]const u8 = null, // Held for new/changed files until commit.
};
pub const Hit = struct { path: []const u8, passage: []const u8, score: f32 };
const Manifest = struct {
    schema: u32,
    model_id: []const u8,
    model_sha256: []const u8,
    dimensions: u32,
    chunker_version: u32,
    folders: []const []const u8,
    files: u64,
    chunks: u64,
    updated_ns: i64,
};
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    vectors: std.ArrayList(f32) = .empty,
    files: std.StringHashMap(usize),
    removed: std.StringHashMap(void),
    identity: Identity,
    folders: []const []const u8,
    updated_ns: i64 = 0,
    records_fd: std.c.fd_t = -1,
    dir: [:0]const u8,

    pub fn create(a: std.mem.Allocator, dir: [:0]const u8, identity: Identity, folders: []const []const u8) !*Store {
        const self = try a.create(Store);
        errdefer a.destroy(self);
        self.* = .{
            .arena = .init(a),
            .backing = a,
            .files = undefined,
            .removed = undefined,
            .identity = undefined,
            .folders = &.{},
            .dir = "",
        };
        const alloc = self.arena.allocator();
        self.files = .init(alloc);
        self.removed = .init(alloc);
        self.identity = .{ .model_id = try alloc.dupe(u8, identity.model_id), .model_sha256 = try alloc.dupe(u8, identity.model_sha256) };
        self.folders = try dupeFolders(alloc, folders);
        self.dir = try alloc.dupeSentinel(u8, dir, 0);
        return self;
    }
    pub fn deinit(self: *Store) void {
        const backing = self.backing;
        if (self.records_fd >= 0) _ = std.c.close(self.records_fd);
        self.records_fd = -1;
        self.arena.deinit();
        backing.destroy(self);
    }
    fn memory(self: *Store) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn load(a: std.mem.Allocator, dir: [:0]const u8, identity: Identity) !*Store {
        const self = try create(a, dir, identity, &.{});
        errdefer self.deinit();
        const alloc = self.memory();
        const manifest_path = try std.fmt.allocPrintSentinel(alloc, "{s}/manifest.json", .{dir}, 0);
        const manifest_bytes = readBounded(alloc, manifest_path, manifest_limit) catch |err| return if (err == error.FileNotFound) error.IndexMissing else err;
        const manifest = std.json.parseFromSliceLeaky(Manifest, alloc, manifest_bytes, .{}) catch return error.IndexCorrupt;
        if (manifest.schema != schema or manifest.dimensions != dimensions or manifest.chunker_version != chunk.version) return error.IndexOutdated;
        if (!std.mem.eql(u8, manifest.model_id, identity.model_id) or !std.mem.eql(u8, manifest.model_sha256, identity.model_sha256)) return error.IndexOutdated;
        if (manifest.chunks > max_chunks or manifest.files > max_files) return error.IndexCorrupt;
        self.folders = try dupeFolders(alloc, manifest.folders);
        self.updated_ns = manifest.updated_ns;
        const vectors_path = try std.fmt.allocPrintSentinel(alloc, "{s}/vectors.bin", .{dir}, 0);
        const records_path = try std.fmt.allocPrintSentinel(alloc, "{s}/records.bin", .{dir}, 0);
        const expected_bytes = manifest.chunks * dimensions * @sizeOf(f32);
        var buffer: [65536]u8 align(4) = undefined;
        const vfd = std.c.open(vectors_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (vfd < 0) return error.IndexCorrupt;
        defer _ = std.c.close(vfd);
        var total: u64 = 0;
        while (total < expected_bytes) {
            const want: usize = @intCast(@min(buffer.len, expected_bytes - total));
            const n = std.c.pread(vfd, &buffer, want, @intCast(total));
            if (n <= 0) return error.IndexCorrupt;
            try self.vectors.appendSlice(alloc, std.mem.bytesAsSlice(f32, buffer[0..@intCast(n)]));
            total += @intCast(n);
        }
        var extra: [1]u8 = undefined;
        if (std.c.pread(vfd, &extra, 1, @intCast(expected_bytes)) > 0) return error.IndexCorrupt;
        self.records_fd = std.c.open(records_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (self.records_fd < 0) return error.IndexCorrupt;
        var offset: u64 = 0;
        var file_count: u64 = 0;
        for (0..@intCast(manifest.chunks)) |_| {
            const entry = try readEntry(alloc, self.records_fd, &offset);
            if (self.files.get(entry.path) == null) {
                file_count += 1;
                if (file_count > max_files) return error.IndexCorrupt;
                try self.files.put(entry.path, self.entries.items.len);
            }
            try self.entries.append(alloc, entry);
        }
        var tail: [1]u8 = undefined;
        if (std.c.pread(self.records_fd, &tail, 1, @intCast(offset)) > 0) return error.IndexCorrupt;
        if (file_count != manifest.files) return error.IndexCorrupt;
        return self;
    }
    pub fn fileStats(self: *Store, path: []const u8) ?struct { mtime_ns: i64, size: u64 } {
        if (self.removed.contains(path)) return null;
        const index = self.files.get(path) orelse return null;
        const entry = self.entries.items[index];
        return .{ .mtime_ns = entry.mtime_ns, .size = entry.size };
    }
    pub fn removeFile(self: *Store, path: []const u8) void {
        if (self.files.contains(path)) self.removed.put(path, {}) catch {};
    }
    pub fn addFile(self: *Store, path: []const u8, mtime_ns: i64, size: u64, passages: []const []const u8, vectors: []const f32) !void {
        if (path.len == 0 or path.len > max_path or !std.unicode.utf8ValidateSlice(path)) return error.InvalidIndexPath;
        if (passages.len == 0 or vectors.len != passages.len * dimensions) return error.InvalidIndexVectors;
        if (self.entries.items.len + passages.len > max_chunks) return error.IndexChunkLimit;
        const is_new = self.files.get(path) == null or self.removed.contains(path);
        if (is_new and self.files.count() - self.removed.count() + 1 > max_files) return error.IndexFileLimit;
        const alloc = self.memory();
        const owned_path = try alloc.dupe(u8, path);
        if (!is_new) self.removeFile(path);
        for (passages, 0..) |passage, i| {
            if (passage.len == 0 or passage.len > chunk.max_passage or !std.unicode.utf8ValidateSlice(passage)) return error.InvalidIndexPassage;
            try self.entries.append(alloc, .{
                .path = owned_path,
                .mtime_ns = mtime_ns,
                .size = size,
                .ordinal = @intCast(i),
                .passage = try alloc.dupe(u8, passage),
            });
            try self.vectors.appendSlice(alloc, vectors[i * dimensions ..][0..dimensions]);
        }
        try self.files.put(owned_path, self.entries.items.len - passages.len);
        _ = self.removed.remove(path);
    }
    pub fn search(self: *Store, a: std.mem.Allocator, query: []const f32, floor: f32, max_hits: usize) ![]Hit {
        if (query.len != dimensions or max_hits == 0) return &.{};
        var best: std.StringHashMap(struct { score: f32, index: usize }) = .init(a);
        defer best.deinit();
        for (self.entries.items, 0..) |entry, i| {
            if (self.removed.contains(entry.path)) continue;
            const vec = self.vectors.items[i * dimensions ..][0..dimensions];
            var dot: f32 = 0;
            for (query, vec) |q, v| dot += q * v;
            const current = best.get(entry.path);
            if (current == null or dot > current.?.score) try best.put(entry.path, .{ .score = dot, .index = i });
        }
        var hits: std.ArrayList(Hit) = .empty;
        // At most a handful of files qualify; repeated selection stays bounded
        // by max_hits and avoids sorting the whole corpus.
        while (hits.items.len < max_hits) {
            var top_path: ?[]const u8 = null;
            var top_score: f32 = floor;
            var top_index: usize = 0;
            var it = best.iterator();
            while (it.next()) |candidate| {
                if (candidate.value_ptr.score > top_score) {
                    top_path = candidate.key_ptr.*;
                    top_score = candidate.value_ptr.score;
                    top_index = candidate.value_ptr.index;
                }
            }
            const path = top_path orelse break;
            const passage = try self.passageAt(top_index);
            try hits.append(a, .{ .path = try a.dupe(u8, path), .passage = try a.dupe(u8, passage), .score = top_score });
            _ = best.remove(path);
        }
        return hits.toOwnedSlice(a);
    }
    fn passageAt(self: *Store, index: usize) ![]const u8 {
        const entry = self.entries.items[index];
        if (entry.passage) |held| return held;
        const buffer = try self.memory().alloc(u8, entry.passage_len);
        var done: usize = 0;
        while (done < buffer.len) {
            const n = std.c.pread(self.records_fd, buffer[done..].ptr, buffer.len - done, @intCast(entry.offset + done));
            if (n <= 0) return error.IndexCorrupt;
            done += @intCast(n);
        }
        return buffer;
    }
    pub fn counts(self: *Store) struct { files: u64, chunks: u64 } {
        var chunks: u64 = 0;
        for (self.entries.items) |entry| {
            if (!self.removed.contains(entry.path)) chunks += 1;
        }
        return .{ .files = self.files.count() - self.removed.count(), .chunks = chunks };
    }
    pub fn commit(self: *Store) !void {
        const alloc = self.memory();
        const made = std.c.mkdir(self.dir, 0o700);
        const made_errno = std.c.errno(made);
        if (made_errno != .SUCCESS and made_errno != .EXIST) return error.IndexDirectoryUnavailable;
        const records_path = try std.fmt.allocPrintSentinel(alloc, "{s}/records.bin", .{self.dir}, 0);
        const vectors_path = try std.fmt.allocPrintSentinel(alloc, "{s}/vectors.bin", .{self.dir}, 0);
        const manifest_path = try std.fmt.allocPrintSentinel(alloc, "{s}/manifest.json", .{self.dir}, 0);
        const records_new = try std.fmt.allocPrintSentinel(alloc, "{s}.new", .{records_path}, 0);
        const vectors_new = try std.fmt.allocPrintSentinel(alloc, "{s}.new", .{vectors_path}, 0);
        const manifest_new = try std.fmt.allocPrintSentinel(alloc, "{s}.new", .{manifest_path}, 0);
        const rfd = std.c.open(records_new, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (rfd < 0) return error.IndexWriteFailed;
        defer _ = std.c.close(rfd);
        const vfd = std.c.open(vectors_new, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (vfd < 0) return error.IndexWriteFailed;
        defer _ = std.c.close(vfd);
        var kept: std.ArrayList(Entry) = .empty;
        var kept_vectors: std.ArrayList(f32) = .empty;
        var files: std.StringHashMap(usize) = .init(alloc);
        var offset: u64 = 0;
        var file_count: u64 = 0;
        for (self.entries.items, 0..) |entry, i| {
            if (self.removed.contains(entry.path)) continue;
            const text = try self.passageAt(i);
            var header: [28]u8 = undefined;
            std.mem.writeInt(u32, header[0..4], @intCast(entry.path.len), .little);
            std.mem.writeInt(i64, header[4..12], entry.mtime_ns, .little);
            std.mem.writeInt(u64, header[12..20], entry.size, .little);
            std.mem.writeInt(u32, header[20..24], entry.ordinal, .little);
            std.mem.writeInt(u32, header[24..28], @intCast(text.len), .little);
            try writeAll(rfd, &header);
            try writeAll(rfd, entry.path);
            try writeAll(rfd, text);
            try writeAll(vfd, std.mem.sliceAsBytes(self.vectors.items[i * dimensions ..][0..dimensions]));
            var updated = entry;
            updated.offset = offset + 28 + entry.path.len;
            updated.passage_len = @intCast(text.len);
            updated.passage = null;
            offset += 28 + entry.path.len + text.len;
            if (files.get(entry.path) == null) {
                file_count += 1;
                try files.put(entry.path, kept.items.len);
            }
            try kept.append(alloc, updated);
            try kept_vectors.appendSlice(alloc, self.vectors.items[i * dimensions ..][0..dimensions]);
        }
        if (std.c.fsync(rfd) != 0 or std.c.fsync(vfd) != 0) return error.IndexWriteFailed;
        var clock: std.c.timespec = undefined;
        const now_ns: i64 = if (std.c.clock_gettime(.REALTIME, &clock) == 0) clock.sec *| std.time.ns_per_s +| clock.nsec else 0;
        const manifest: Manifest = .{
            .schema = schema,
            .model_id = self.identity.model_id,
            .model_sha256 = self.identity.model_sha256,
            .dimensions = dimensions,
            .chunker_version = chunk.version,
            .folders = self.folders,
            .files = file_count,
            .chunks = kept.items.len,
            .updated_ns = now_ns,
        };
        const manifest_bytes = try std.json.Stringify.valueAlloc(alloc, manifest, .{});
        const mfd = std.c.open(manifest_new, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (mfd < 0) return error.IndexWriteFailed;
        defer _ = std.c.close(mfd);
        try writeAll(mfd, manifest_bytes);
        if (std.c.fsync(mfd) != 0) return error.IndexWriteFailed;
        if (std.c.rename(records_new, records_path) != 0 or std.c.rename(vectors_new, vectors_path) != 0) return error.IndexWriteFailed;
        // Manifest last: readers key consistency off it.
        if (std.c.rename(manifest_new, manifest_path) != 0) return error.IndexWriteFailed;
        const reopened = std.c.open(records_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
        if (reopened < 0) return error.IndexCorrupt;
        if (self.records_fd >= 0) _ = std.c.close(self.records_fd);
        self.records_fd = reopened;
        self.entries = kept;
        self.vectors = kept_vectors;
        self.files = files;
        self.removed.clearRetainingCapacity();
        self.updated_ns = manifest.updated_ns;
    }
};
pub fn deleteAll(dir: [:0]const u8) void {
    var buffer: [4096]u8 = undefined;
    for ([_][]const u8{ "manifest.json", "vectors.bin", "records.bin", "manifest.json.new", "vectors.bin.new", "records.bin.new" }) |name| {
        const path = std.mem.printSentinel(&buffer, "{s}/{s}", .{ dir, name }, 0) catch continue;
        _ = std.c.unlink(path);
    }
}
fn dupeFolders(alloc: std.mem.Allocator, folders: []const []const u8) ![]const []const u8 {
    const copy = try alloc.alloc([]const u8, folders.len);
    for (folders, 0..) |folder, i| copy[i] = try alloc.dupe(u8, folder);
    return copy;
}
fn readBounded(alloc: std.mem.Allocator, path: [:0]const u8, limit: usize) ![]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG or st.size > limit) return error.IndexCorrupt;
    const buffer = try alloc.alloc(u8, @intCast(st.size));
    var done: usize = 0;
    while (done < buffer.len) {
        const n = std.c.read(fd, buffer[done..].ptr, buffer.len - done);
        if (n <= 0) return error.IndexCorrupt;
        done += @intCast(n);
    }
    return buffer;
}
fn readEntry(alloc: std.mem.Allocator, fd: std.c.fd_t, offset: *u64) !Entry {
    var header: [28]u8 = undefined;
    try readAt(fd, &header, offset.*);
    const path_len = std.mem.readInt(u32, header[0..4], .little);
    if (path_len == 0 or path_len > max_path) return error.IndexCorrupt;
    const passage_len = std.mem.readInt(u32, header[24..28], .little);
    if (passage_len == 0 or passage_len > chunk.max_passage) return error.IndexCorrupt;
    const path = try alloc.alloc(u8, path_len);
    try readAt(fd, path, offset.* + 28);
    if (!std.unicode.utf8ValidateSlice(path)) return error.IndexCorrupt;
    const entry: Entry = .{
        .path = path,
        .mtime_ns = std.mem.readInt(i64, header[4..12], .little),
        .size = std.mem.readInt(u64, header[12..20], .little),
        .ordinal = std.mem.readInt(u32, header[20..24], .little),
        .offset = offset.* + 28 + path_len,
        .passage_len = passage_len,
    };
    offset.* += 28 + path_len + passage_len;
    return entry;
}
fn readAt(fd: std.c.fd_t, buffer: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buffer.len) {
        const n = std.c.pread(fd, buffer[done..].ptr, buffer.len - done, @intCast(offset + done));
        if (n <= 0) return error.IndexCorrupt;
        done += @intCast(n);
    }
}
fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = std.c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.IndexWriteFailed;
        done += @intCast(n);
    }
}
fn freeHits(a: std.mem.Allocator, hits: []Hit) void {
    for (hits) |hit| {
        a.free(hit.path);
        a.free(hit.passage);
    }
    a.free(hits);
}
test "store round-trips, ranks per file and survives removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [512]u8 = undefined;
    const dir_z = try std.mem.printSentinel(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    const identity: Identity = .{ .model_id = "embeddinggemma-2-q8_0", .model_sha256 = "abc" };
    const store = try Store.create(std.testing.allocator, dir_z, identity, &.{"/docs"});
    defer store.deinit();
    var lease: [dimensions]f32 = @splat(0);
    lease[0] = 1;
    var notes: [dimensions]f32 = @splat(0);
    notes[1] = 1;
    var lease_vectors: [2 * dimensions]f32 = undefined;
    @memcpy(lease_vectors[0..dimensions], &lease);
    @memcpy(lease_vectors[dimensions..], &lease);
    try store.addFile("/docs/lease.pdf", 10, 100, &.{ "Tenant may keep two pets.", "Rent is due monthly." }, &lease_vectors);
    try store.addFile("/docs/notes.md", 20, 50, &.{"Groceries and chores."}, &notes);
    try store.commit();
    var query: [dimensions]f32 = @splat(0);
    query[0] = 1;
    const hits = try store.search(std.testing.allocator, &query, 0.3, 4);
    defer freeHits(std.testing.allocator, hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("/docs/lease.pdf", hits[0].path);
    try std.testing.expectEqualStrings("Tenant may keep two pets.", hits[0].passage);
    try std.testing.expectApproxEqAbs(@as(f32, 1), hits[0].score, 1e-6);
    store.removeFile("/docs/lease.pdf");
    try store.commit();
    const empty = try store.search(std.testing.allocator, &query, 0.3, 4);
    defer freeHits(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const reopened = try Store.load(std.testing.allocator, dir_z, identity);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), reopened.counts().files);
    try std.testing.expectEqual(@as(u64, 1), reopened.counts().chunks);
    try std.testing.expect(reopened.fileStats("/docs/lease.pdf") == null);
    const stats = reopened.fileStats("/docs/notes.md").?;
    try std.testing.expectEqual(@as(i64, 20), stats.mtime_ns);
    try std.testing.expectError(error.IndexOutdated, Store.load(std.testing.allocator, dir_z, .{ .model_id = "other", .model_sha256 = "abc" }));
}
test "store rejects corrupt vectors and invalid additions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [512]u8 = undefined;
    const dir_z = try std.mem.printSentinel(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    const identity: Identity = .{ .model_id = "m", .model_sha256 = "s" };
    const store = try Store.create(std.testing.allocator, dir_z, identity, &.{});
    defer store.deinit();
    var vec: [dimensions]f32 = @splat(0);
    vec[0] = 1;
    try std.testing.expectError(error.InvalidIndexVectors, store.addFile("/a", 1, 1, &.{ "text", "more" }, &vec));
    try std.testing.expectError(error.InvalidIndexPassage, store.addFile("/a", 1, 1, &.{""}, &vec));
    try store.addFile("/a", 1, 1, &.{"valid passage"}, &vec);
    try store.commit();
    const vectors_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/vectors.bin", .{dir_z}, 0);
    defer std.testing.allocator.free(vectors_path);
    const fd = std.c.open(vectors_path, .{ .ACCMODE = .WRONLY }, @as(c_uint, 0));
    try std.testing.expect(fd >= 0);
    _ = std.c.ftruncate(fd, 4);
    _ = std.c.close(fd);
    try std.testing.expectError(error.IndexCorrupt, Store.load(std.testing.allocator, dir_z, identity));
}
