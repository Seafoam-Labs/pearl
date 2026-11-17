//! Background indexing pass: walk selected folders (or a dirty scope), extract
//! text, chunk it, embed changed files and commit the store. One cancellable
//! worker; defers while the chat assistant is answering and yields to live
//! launcher queries. Automatic passes run in bounded bursts: a deadline ends
//! the burst with committed progress and a "more pending" outcome.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const config = @import("../agent/config.zig");
const Runtime = @import("../agent/runtime.zig").Runtime;
const embed = @import("../agent/embed.zig");
const store_mod = @import("store.zig");
const chunk = @import("chunk.zig");
const extract = @import("extract.zig");
pub const max_depth = 24;
pub const batch_size = 8;
pub const commit_interval = 256;
pub const exclude_dirs = [_][]const u8{ ".git", ".hg", ".svn", ".cache", ".zig-cache", "zig-out", "node_modules", "__pycache__", ".npm", ".cargo" };
pub const State = enum(u8) { idle, walking, indexing, paused, done, failed };
pub const Scope = enum { walk, dirty };
pub const Outcome = enum { done, more };
pub const Progress = struct {
    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    indexed: std.atomic.Value(u64) = .init(0),
    skipped: std.atomic.Value(u64) = .init(0),
    pub fn setState(self: *Progress, state: State) void {
        self.state.store(@backingInt(state), .monotonic);
    }
};
pub const Options = struct {
    runtime_lock: *glib.Mutex,
    chat_busy: ?*const fn (*anyopaque) bool = null,
    chat_context: ?*anyopaque = null,
    query_active: ?*std.atomic.Value(bool) = null,
    scope: Scope = .walk,
    dirty: []const []const u8 = &.{},
    deadline_us: i64 = 0,
    note_dir: ?*const fn (*anyopaque, []const u8) void = null,
    note_context: ?*anyopaque = null,
};
const File = struct { path: []const u8, mtime_ns: i64, size: u64, kind: extract.Kind };
fn expired(deadline_us: i64) bool {
    return deadline_us != 0 and glib.getMonotonicTime() > deadline_us;
}
pub fn pass(a: std.mem.Allocator, cfg: config.Config, store: *store_mod.Store, runtime: *Runtime, progress: *Progress, cancel: *gio.Cancellable, options: Options) !Outcome {
    progress.setState(.walking);
    progress.done.store(0, .monotonic);
    progress.indexed.store(0, .monotonic);
    progress.skipped.store(0, .monotonic);
    var files: std.ArrayList(File) = .empty;
    var seen: std.StringHashMap(void) = .init(a);
    switch (options.scope) {
        .walk => {
            for (cfg.semantic.folders) |folder_raw| {
                const folder = std.mem.trimEnd(u8, folder_raw, "/");
                const root = if (folder.len == 0) "/" else folder;
                try walk(a, root, &files, &seen, cancel, 0, options);
            }
        },
        .dirty => {
            for (options.dirty) |path| {
                if (cancel.isCancelled() != 0) return error.Cancelled;
                const path_z = try a.dupeSentinel(u8, path, 0);
                var st: std.os.linux.Statx = undefined;
                if (std.os.linux.statx(std.os.linux.AT.FDCWD, path_z, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &st) != 0) {
                    store.removeFile(path); // Vanished file: tombstone on commit.
                    continue;
                }
                if (st.mode & std.c.S.IFMT == std.c.S.IFDIR) {
                    try walk(a, path, &files, &seen, cancel, 0, options);
                } else if (st.mode & std.c.S.IFMT == std.c.S.IFREG) {
                    const kind = extract.kind(path);
                    if (kind == .unsupported or st.size > extract.max_file) continue;
                    try seen.put(path, {});
                    try files.append(a, .{ .path = try a.dupe(u8, path), .mtime_ns = st.mtime.sec *| std.time.ns_per_s +| st.mtime.nsec, .size = st.size, .kind = kind });
                }
            }
        },
    }
    if (cancel.isCancelled() != 0) return error.Cancelled;
    progress.total.store(files.items.len, .monotonic);
    progress.setState(.indexing);
    var since_commit: usize = 0;
    for (files.items) |file| {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (expired(options.deadline_us)) {
            try store.commit();
            return .more;
        }
        try yieldWhileBusy(progress, cancel, options);
        if (store.fileStats(file.path)) |stats| {
            if (stats.mtime_ns == file.mtime_ns and stats.size == file.size) {
                progress.skipped.store(progress.skipped.load(.monotonic) + 1, .monotonic);
                progress.done.store(progress.done.load(.monotonic) + 1, .monotonic);
                continue;
            }
        }
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const path_z = try temp.dupeSentinel(u8, file.path, 0);
        const content: []const u8 = switch (file.kind) {
            .text => extract.text(temp, path_z) catch |err| {
                if (err == error.OutOfMemory) return err;
                progress.skipped.store(progress.skipped.load(.monotonic) + 1, .monotonic);
                progress.done.store(progress.done.load(.monotonic) + 1, .monotonic);
                continue;
            },
            .pdf => extract.pdf(temp, path_z) catch |err| {
                if (err == error.OutOfMemory) return err;
                progress.skipped.store(progress.skipped.load(.monotonic) + 1, .monotonic);
                progress.done.store(progress.done.load(.monotonic) + 1, .monotonic);
                continue;
            },
            .unsupported => continue,
        };
        const passages = try chunk.chunk(temp, content);
        if (passages.len == 0) {
            store.removeFile(file.path);
            progress.done.store(progress.done.load(.monotonic) + 1, .monotonic);
            continue;
        }
        const title = extract.title(file.path);
        const vectors = try temp.alloc(f32, passages.len * store_mod.dimensions);
        var offset: usize = 0;
        while (offset < passages.len) {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            if (expired(options.deadline_us)) {
                try store.commit();
                return .more;
            }
            try yieldWhileBusy(progress, cancel, options);
            const end = @min(offset + batch_size, passages.len);
            const inputs = try temp.alloc([]const u8, end - offset);
            for (passages[offset..end], 0..) |passage, i| {
                inputs[i] = try std.fmt.allocPrint(temp, "title: {s} | text: {s}", .{ title, passage });
            }
            options.runtime_lock.lock();
            const batch = embed.batch(temp, runtime, inputs, cancel) catch |err| {
                options.runtime_lock.unlock();
                return err;
            };
            options.runtime_lock.unlock();
            for (batch, 0..) |vector, i| {
                try embed.reduce(vector, store_mod.dimensions);
                @memcpy(vectors[(offset + i) * store_mod.dimensions ..][0..store_mod.dimensions], vector[0..store_mod.dimensions]);
            }
            offset = end;
        }
        try store.addFile(file.path, file.mtime_ns, file.size, passages, vectors);
        progress.indexed.store(progress.indexed.load(.monotonic) + 1, .monotonic);
        progress.done.store(progress.done.load(.monotonic) + 1, .monotonic);
        since_commit += 1;
        if (since_commit >= commit_interval) {
            try store.commit();
            since_commit = 0;
        }
    }
    if (options.scope == .walk) {
        // Drop entries whose files disappeared or whose folder was removed.
        var it = store.files.keyIterator();
        while (it.next()) |key| {
            if (seen.contains(key.*)) continue;
            if (underFolders(cfg.semantic.folders, key.*)) store.removeFile(key.*);
        }
    }
    try store.commit();
    progress.setState(.done);
    return .done;
}
pub fn underFolders(folders: []const []const u8, path: []const u8) bool {
    for (folders) |folder_raw| {
        const folder = std.mem.trimEnd(u8, folder_raw, "/");
        const root = if (folder.len == 0) "/" else folder;
        if (std.mem.eql(u8, root, "/")) return true;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return true;
    }
    return false;
}
fn yieldWhileBusy(progress: *Progress, cancel: *gio.Cancellable, options: Options) !void {
    var waiting = false;
    while ((options.chat_busy != null and options.chat_busy.?(options.chat_context.?)) or (options.query_active != null and options.query_active.?.load(.monotonic))) {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        if (!waiting) {
            progress.setState(.paused);
            waiting = true;
        }
        glib.usleep(50_000);
    }
    if (waiting) progress.setState(.indexing);
}
fn walk(a: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList(File), seen: *std.StringHashMap(void), cancel: *gio.Cancellable, depth: usize, options: Options) !void {
    if (depth > max_depth or files.items.len >= store_mod.max_files) return;
    if (cancel.isCancelled() != 0) return error.Cancelled;
    if (options.note_dir) |note| note(options.note_context.?, dir_path);
    const dir_z = try a.dupeSentinel(u8, dir_path, 0);
    const dir = std.c.opendir(dir_z) orelse return;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry| {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
        if (name.len == 0 or name[0] == '.') continue;
        if (files.items.len >= store_mod.max_files) return;
        if (entry.type == std.c.DT.LNK) continue; // Symlinks are never followed.
        const path = try std.fs.path.join(a, &.{ dir_path, name });
        var is_dir = entry.type == std.c.DT.DIR;
        var is_reg = entry.type == std.c.DT.REG;
        var st: std.os.linux.Statx = undefined;
        var have_stats = false;
        if (entry.type == std.c.DT.UNKNOWN) {
            const path_z = try a.dupeSentinel(u8, path, 0);
            if (std.os.linux.statx(std.os.linux.AT.FDCWD, path_z, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &st) != 0) continue;
            is_dir = st.mode & std.c.S.IFMT == std.c.S.IFDIR;
            is_reg = st.mode & std.c.S.IFMT == std.c.S.IFREG;
            have_stats = true;
        }
        if (is_dir) {
            var excluded = false;
            for (exclude_dirs) |ex| if (std.mem.eql(u8, name, ex)) {
                excluded = true;
                break;
            };
            if (!excluded) try walk(a, path, files, seen, cancel, depth + 1, options);
        } else if (is_reg) {
            const kind = extract.kind(name);
            if (kind == .unsupported) continue;
            if (!have_stats) {
                const path_z = try a.dupeSentinel(u8, path, 0);
                if (std.os.linux.statx(std.os.linux.AT.FDCWD, path_z, 0, .{ .SIZE = true, .MTIME = true }, &st) != 0) continue;
            }
            if (st.size > extract.max_file) continue;
            try seen.put(path, {});
            try files.append(a, .{ .path = path, .mtime_ns = st.mtime.sec *| std.time.ns_per_s +| st.mtime.nsec, .size = st.size, .kind = kind });
        }
    }
}
test "folder membership respects boundaries, not prefixes" {
    try std.testing.expect(underFolders(&.{"/home/zoey/Documents"}, "/home/zoey/Documents/lease.pdf"));
    try std.testing.expect(!underFolders(&.{"/home/zoey/Documents"}, "/home/zoey/Documents-other/lease.pdf"));
    try std.testing.expect(!underFolders(&.{"/home/zoey/Documents"}, "/etc/passwd"));
    try std.testing.expect(underFolders(&.{"/"}, "/anything/at/all"));
    try std.testing.expect(underFolders(&.{"/home/zoey/Documents/"}, "/home/zoey/Documents/a"));
}
test "burst deadlines expire only when set and in the past" {
    try std.testing.expect(!expired(0));
    try std.testing.expect(expired(1));
    try std.testing.expect(!expired(std.math.maxInt(i64)));
}
