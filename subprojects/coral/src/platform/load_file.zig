//! Linux-only existing-file loader. No GTK calls or filesystem I/O on the
//! submitting thread. open(O_RDONLY | O_NONBLOCK | O_CLOEXEC), without O_CREAT,
//! followed by fstat prevents a swapped-in FIFO from blocking the content open.
//! Only regular descriptors are read, and the original fd stays owned until all
//! reads and metadata queries finish. Symlinks are allowed; this is not a sandbox.
//!
//! /proc/self/fd must be available: a GIO stream opened through the held fd is
//! used ONLY for descriptor metadata, never the original pathname. GLib's
//! glocalfileinputstream.c query_info calls _g_local_file_info_get_from_fd, whose
//! etag is the same opaque value used by ordinary GIO local-file saves. Do not
//! synthesize it from timestamps or resolve the proc symlink back to a pathname.
//! See https://gitlab.gnome.org/GNOME/glib/-/blob/main/gio/glocalfileinputstream.c
//! and gio/glocalfileinfo.c. Failure to obtain an etag fails the whole load.
//!
//! This is not a snapshot: concurrent in-place writes may mix bytes. Metadata
//! changes observed across the read are rejected, but timestamp granularity and
//! filesystem behavior prevent a universal detection guarantee. Path replacement
//! after acquisition cannot redirect the read; replacement before acquisition
//! selects the new inode, which must independently pass the regular-file check.
//! GIO etags retain GIO's timestamp-based limitations, not inode/hash identity.
//!
//! Cancellation is checked before open, on EINTR, between bounded reads and at
//! completion. O_NONBLOCK avoids the FIFO rendezvous, not arbitrary kernel/NFS/
//! FUSE/device stalls. Cancellation cannot interrupt an in-progress syscall.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("pearl_app_c");
const a = std.heap.c_allocator;

pub const max_bytes: usize = 128 * 1024 * 1024;
const chunk_bytes = 64 * 1024;
var source_tag: u8 = 0;

comptime {
    if (builtin.os.tag != .linux) @compileError("Coral load_file requires Linux /proc/self/fd");
}

/// Copies path before returning and retains cancellable. callback is dispatched
/// exactly once, asynchronously on the submitting thread-default GMainContext
/// (source_object is null). Keep that context running and user_data alive until
/// callback. All fds are closed BEFORE callback, even on cancellation. GLib's
/// own object allocation follows its usual fatal-OOM policy.
///
/// Use a fresh cancellable per operation; do not reset one while pending. The
/// controller must carry/check its document generation in user_data, and still
/// finish/discard stale completions. This module never accesses document state.
/// Accepts a native local path, not a URI; prefer open_target's absolute result.
/// Relative paths are interpreted at worker open time (do not change cwd).
pub fn load(path: [:0]const u8, cancellable: *c.GCancellable, callback: c.GAsyncReadyCallback, user_data: ?*anyopaque) void {
    start(path, cancellable, callback, user_data, .{});
}

/// Call once for this loader's GAsyncResult. Returns 1 on success, 0 on failure.
/// Initializes all outputs; no partial contents/etag escape on failure. Success
/// transfers NUL-terminated raw bytes (BOM/embedded NUL unchanged) and a non-null
/// GIO etag to the caller: free BOTH with g_free. length excludes the terminator.
/// Failure transfers a GError (if requested): free it with g_error_free. As with
/// GIO, error_out must be null or point to null. The result itself is borrowed;
/// if deferring finish beyond callback, retain/release it with g_object_ref/unref.
/// Unfinished results and cancelled successful results are automatically freed.
pub fn finish(result: *c.GAsyncResult, contents: *[*c]u8, length: *usize, etag: *[*c]u8, error_out: ?*?*c.GError) c.gboolean {
    contents.* = null;
    length.* = 0;
    etag.* = null;
    std.debug.assert(c.g_task_is_valid(result, null) != 0);
    const task: *c.GTask = @ptrCast(result);
    std.debug.assert(c.g_task_get_source_tag(task) == @as(?*anyopaque, &source_tag));
    const raw = c.g_task_propagate_pointer(task, @ptrCast(error_out)) orelse return 0;
    const value: *Payload = @ptrCast(@alignCast(raw));
    contents.* = value.contents;
    length.* = value.length;
    etag.* = value.etag;
    a.destroy(value);
    return 1;
}

const Payload = struct {
    contents: [*c]u8 = null,
    length: usize = 0,
    etag: [*c]u8 = null,
};

// Per-request seams, compiled out of production. No global hooks or worker/UI
// synchronization in the implementation; tests can force races deterministically.
const Hooks = if (builtin.is_test) struct {
    data: ?*anyopaque = null,
    after_open: ?*const fn (c_int, *c.GCancellable, ?*anyopaque) void = null,
    after_read: ?*const fn (usize, *c.GCancellable, ?*anyopaque) void = null,
} else struct {};

pub const testing = if (builtin.is_test) struct {
    pub const loadWithHooks = start;
} else void;

const Request = struct { path: [:0]u8, hooks: Hooks };

fn start(path: [:0]const u8, cancellable: *c.GCancellable, callback: c.GAsyncReadyCallback, user_data: ?*anyopaque, hooks: Hooks) void {
    std.debug.assert(callback != null);
    const task = c.g_task_new(null, cancellable, callback, user_data).?;
    defer c.g_object_unref(task);
    c.g_task_set_source_tag(task, &source_tag);
    // Never deliver cancellation while the worker still owns descriptors/data.
    _ = c.g_task_set_return_on_cancel(task, 0);
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
        c.g_task_return_error(task, newError(c.G_IO_ERROR_INVALID_ARGUMENT, "Load requires a nonempty native path without embedded NUL."));
        return;
    }
    const request = a.create(Request) catch {
        c.g_task_return_error(task, newError(c.G_IO_ERROR_NO_SPACE, "Not enough memory to start file load."));
        return;
    };
    const owned = a.dupeSentinel(u8, path, 0) catch {
        a.destroy(request);
        c.g_task_return_error(task, newError(c.G_IO_ERROR_NO_SPACE, "Not enough memory to copy load path."));
        return;
    };
    request.* = .{ .path = owned, .hooks = hooks };
    c.g_task_set_task_data(task, request, &destroyRequest);
    c.g_task_run_in_thread(task, &worker);
}

fn destroyRequest(data: ?*anyopaque) callconv(.c) void {
    const request: *Request = @ptrCast(@alignCast(data.?));
    a.free(request.path);
    a.destroy(request);
}

fn destroyPayload(data: ?*anyopaque) callconv(.c) void {
    const value: *Payload = @ptrCast(@alignCast(data.?));
    c.g_free(value.contents);
    c.g_free(value.etag);
    a.destroy(value);
}

fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, cancellable: [*c]c.GCancellable) callconv(.c) void {
    var err: ?*c.GError = null;
    // readFile's defers have all run before returning anything to GTask.
    const value = readFile(@ptrCast(@alignCast(data.?)), cancellable, &err) catch {
        c.g_task_return_error(task, err.?);
        return;
    };
    c.g_task_return_pointer(task, value, &destroyPayload);
}

const Failure = error{Failed};
const attributes = "etag::value,standard::size,time::changed,time::changed-nsec";

fn readFile(request: *const Request, cancellable: *c.GCancellable, err: *?*c.GError) Failure!*Payload {
    const fd = while (true) {
        try checkCancelled(cancellable, err);
        const opened = std.c.open(request.path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (opened >= 0) break opened;
        const code = std.c.errno(opened);
        if (code != .INTR) return errnoFailure(err, code, "Cannot open file for reading");
    };
    // Linux releases the fd even if close reports EINTR: never retry close.
    defer _ = std.c.close(fd);
    var stat: c.GStatBuf = undefined;
    while (c.fstat(fd, &stat) != 0) {
        const code = std.c.errno(@as(c_int, -1));
        if (code != .INTR) return errnoFailure(err, code, "Cannot inspect opened file");
        try checkCancelled(cancellable, err);
    }
    switch (stat.st_mode & c.S_IFMT) {
        c.S_IFREG => {},
        c.S_IFDIR => return failure(err, c.G_IO_ERROR_IS_DIRECTORY, "Cannot load a directory."),
        else => return failure(err, c.G_IO_ERROR_NOT_REGULAR_FILE, "Cannot load a non-regular file (FIFO, socket or device)."),
    }
    if (stat.st_size > max_bytes) return tooLarge(err);
    if (builtin.is_test) if (request.hooks.after_open) |hook| hook(fd, cancellable, request.hooks.data);
    try checkCancelled(cancellable, err);

    var proc_buffer: [64]u8 = undefined;
    const proc_path = std.fmt.bufPrintSentinel(&proc_buffer, "/proc/self/fd/{d}", .{fd}, 0) catch unreachable;
    // Use the selected VFS, not g_vfs_get_local(): an inactive GVfs daemon
    // backend can unref that borrowed singleton during default-VFS probing
    // (gdaemonvfs.c finalize), leaving it dangling before GTK's first load.
    // The absolute proc-fd path still pins the inode; refuse a remote mapping
    // before opening a stream. No original-path lookup is introduced here.
    const file = c.g_file_new_for_path(proc_path).?;
    defer c.g_object_unref(file);
    if (c.g_file_is_native(file) == 0) return failure(err, c.G_IO_ERROR_NOT_SUPPORTED, "The proc-fd metadata bridge requires a native file backend.");
    const stream = c.g_file_read(file, cancellable, @ptrCast(err)) orelse return error.Failed;
    defer {
        _ = c.g_input_stream_close(@ptrCast(stream), null, null);
        c.g_object_unref(stream);
    }
    const before = c.g_file_input_stream_query_info(stream, attributes, cancellable, @ptrCast(err)) orelse return error.Failed;
    defer c.g_object_unref(before);
    const initial_etag = c.g_file_info_get_etag(before);
    if (initial_etag == null) return failure(err, c.G_IO_ERROR_NOT_SUPPORTED, "Opened file does not provide a GIO etag.");
    if (c.g_file_info_get_size(before) > max_bytes) return tooLarge(err);

    const value = a.create(Payload) catch return failure(err, c.G_IO_ERROR_NO_SPACE, "Not enough memory for loaded file.");
    value.* = .{};
    errdefer destroyPayload(value);
    var capacity: usize = 0;
    while (true) {
        try checkCancelled(cancellable, err);
        // Probe just one extra byte at the cap; never return a truncated success.
        var extra: [1]u8 = undefined;
        const full = value.length == max_bytes;
        if (!full and value.length == capacity) {
            capacity = @min(max_bytes, @max(chunk_bytes, capacity * 2));
            const memory = c.g_try_realloc(value.contents, capacity + 1) orelse
                return failure(err, c.G_IO_ERROR_NO_SPACE, "Not enough memory for loaded file contents.");
            value.contents = @ptrCast(memory);
        }
        const target: [*]u8 = if (full) &extra else @ptrCast(value.contents + value.length);
        const count = if (full) 1 else @min(chunk_bytes, capacity - value.length);
        const n = std.c.read(fd, target, count);
        if (n < 0) {
            const code = std.c.errno(n);
            if (code == .INTR) continue;
            return errnoFailure(err, code, "Cannot read opened file");
        }
        if (n == 0) break;
        if (full) return tooLarge(err);
        value.length += @intCast(n);
        if (builtin.is_test) if (request.hooks.after_read) |hook| hook(value.length, cancellable, request.hooks.data);
    }
    try checkCancelled(cancellable, err);
    const after = c.g_file_input_stream_query_info(stream, attributes, cancellable, @ptrCast(err)) orelse return error.Failed;
    defer c.g_object_unref(after);
    if (c.g_strcmp0(initial_etag, c.g_file_info_get_etag(after)) != 0 or
        c.g_file_info_get_size(before) != c.g_file_info_get_size(after) or
        c.g_file_info_get_attribute_uint64(before, "time::changed") != c.g_file_info_get_attribute_uint64(after, "time::changed") or
        c.g_file_info_get_attribute_uint32(before, "time::changed-nsec") != c.g_file_info_get_attribute_uint32(after, "time::changed-nsec"))
    {
        return failure(err, c.G_IO_ERROR_BUSY, "File changed while being read; retry the load.");
    }
    value.contents[value.length] = 0;
    value.etag = c.g_strdup(initial_etag);
    try checkCancelled(cancellable, err);
    return value;
}

fn checkCancelled(cancellable: *c.GCancellable, err: *?*c.GError) Failure!void {
    if (c.g_cancellable_set_error_if_cancelled(cancellable, @ptrCast(err)) != 0) return error.Failed;
}

fn newError(code: c_int, message: [*:0]const u8) *c.GError {
    return c.g_error_new_literal(c.g_io_error_quark(), code, message);
}

fn failure(err: *?*c.GError, code: c_int, message: [*:0]const u8) Failure {
    err.* = newError(code, message);
    return error.Failed;
}

fn tooLarge(err: *?*c.GError) Failure {
    return failure(err, c.G_IO_ERROR_MESSAGE_TOO_LARGE, "File exceeds the 128 MiB load limit.");
}

fn errnoFailure(err: *?*c.GError, code: std.c.E, operation: [*:0]const u8) Failure {
    const number: c_int = @intCast(@backingInt(code));
    err.* = c.g_error_new(c.g_io_error_quark(), @intCast(c.g_io_error_from_errno(number)), "%s: %s", operation, c.g_strerror(number));
    return error.Failed;
}

test {
    _ = @import("load_file_test.zig");
}
