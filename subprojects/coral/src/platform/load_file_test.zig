//! Headless Linux tests; no GTK initialization or display required. Import this
//! file OR load_file.zig from the parent test root. Race hooks are per-request,
//! worker-only and absent from production. Watchdogs fail rather than hang.
const std = @import("std");
const c = @import("pearl_app_c");
const loader = @import("load_file.zig");
const a = std.testing.allocator;

const Harness = struct {
    directory: [*:0]u8,
    path: [:0]u8,
    context: *c.GMainContext,
    cancel: *c.GCancellable,

    fn init() !Harness {
        const directory = c.g_dir_make_tmp("coral-load-XXXXXX", null) orelse return error.TempDirectory;
        errdefer c.g_free(directory);
        errdefer _ = c.g_rmdir(directory);
        const path = try std.fmt.allocPrintSentinel(a, "{s}/file", .{directory}, 0);
        const context = c.g_main_context_new().?;
        c.g_main_context_push_thread_default(context);
        return .{ .directory = directory, .path = path, .context = context, .cancel = c.g_cancellable_new().? };
    }

    fn deinit(self: Harness) void {
        c.g_main_context_pop_thread_default(self.context);
        c.g_main_context_unref(self.context);
        c.g_object_unref(self.cancel);
        _ = c.g_unlink(self.path);
        std.debug.assert(c.g_rmdir(self.directory) == 0);
        c.g_free(self.directory);
        a.free(self.path);
    }

    fn write(self: Harness, bytes: []const u8) !void {
        try std.testing.expect(c.g_file_set_contents(self.path, bytes.ptr, @intCast(bytes.len), null) != 0);
    }

    fn wait(self: Harness, seen: *Seen) !void {
        const until = c.g_get_monotonic_time() + 5_000_000;
        while (seen.calls == 0) {
            _ = c.g_main_context_iteration(self.context, 0);
            if (c.g_get_monotonic_time() > until) @panic("load_file completion watchdog expired");
            c.g_usleep(1000);
        }
        for (0..10) |_| {
            _ = c.g_main_context_iteration(self.context, 0);
            c.g_usleep(1000);
        }
        try std.testing.expectEqual(@as(usize, 1), seen.calls);
        try std.testing.expect(seen.on_context);
        try std.testing.expect(seen.null_source);
    }

    fn run(self: Harness, seen: *Seen) !void {
        loader.load(self.path, self.cancel, &Seen.complete, seen);
        try std.testing.expectEqual(@as(usize, 0), seen.calls);
        try self.wait(seen);
    }
};

const Seen = struct {
    context: *c.GMainContext,
    calls: usize = 0,
    on_context: bool = false,
    null_source: bool = false,
    discard: bool = false,
    cancel_before_finish: ?*c.GCancellable = null,
    ok: bool = false,
    contents: [*c]u8 = null,
    length: usize = 0,
    etag: [*c]u8 = null,
    err: ?*c.GError = null,

    fn complete(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Seen = @ptrCast(@alignCast(data.?));
        self.calls += 1;
        self.null_source = source == null;
        self.on_context = c.g_main_context_is_owner(self.context) != 0;
        if (self.cancel_before_finish) |cancel| c.g_cancellable_cancel(cancel);
        if (!self.discard) self.ok = loader.finish(result.?, &self.contents, &self.length, &self.etag, &self.err) != 0;
    }

    fn deinit(self: Seen) void {
        c.g_free(self.contents);
        c.g_free(self.etag);
        if (self.err) |err| c.g_error_free(err);
    }

    fn expectError(self: Seen, code: c_int) !void {
        try std.testing.expect(!self.ok);
        try std.testing.expect(self.err != null);
        try std.testing.expectEqual(c.g_io_error_quark(), self.err.?.domain);
        try std.testing.expectEqual(code, self.err.?.code);
        try std.testing.expect(std.mem.span(self.err.?.message).len > 0);
        try std.testing.expect(self.contents == null and self.etag == null and self.length == 0);
    }
};

test "load after default VFS probing uses the selected native backend" {
    const h = try Harness.init();
    defer h.deinit();
    try h.write("default VFS was initialized before the loader");
    // Match GTK startup, before the worker touches GIO. Also run this test in
    // a private D-Bus session without GVfs services, with G_DEBUG=fatal-criticals
    // and GIO_USE_VFS unset: the rejected daemon backend can finalize its
    // borrowed local-VFS singleton. A no-bus test process misses that failure.
    const file = c.g_file_new_for_path(h.path).?;
    defer c.g_object_unref(file);
    try std.testing.expect(c.g_file_is_native(file) != 0);
    const info = c.g_file_query_info(file, "etag::value", 0, null, null).?;
    defer c.g_object_unref(info);
    var seen = Seen{ .context = h.context };
    defer seen.deinit();
    try h.run(&seen);
    try std.testing.expect(seen.ok);
    try std.testing.expectEqualStrings("default VFS was initialized before the loader", seen.contents[0..seen.length]);
    try std.testing.expectEqualStrings(std.mem.span(c.g_file_info_get_etag(info)), std.mem.span(seen.etag));
}

test "load preserves normal, empty, BOM and binary bytes with GIO etag and owned path" {
    const h = try Harness.init();
    defer h.deinit();
    for ([_][]const u8{ "hello\n", "", "\xef\xbb\xbfhello\r\n", "a\x00b\xff" }) |bytes| {
        try h.write(bytes);
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        const copied = try a.dupeSentinel(u8, h.path, 0);
        loader.load(copied, h.cancel, &Seen.complete, &seen);
        @memset(copied, '?');
        a.free(copied);
        try std.testing.expectEqual(@as(usize, 0), seen.calls);
        try h.wait(&seen);
        try std.testing.expect(seen.ok);
        try std.testing.expect(seen.err == null);
        try std.testing.expectEqualStrings(bytes, seen.contents[0..seen.length]);
        try std.testing.expectEqual(@as(u8, 0), seen.contents[seen.length]);
        const file = c.g_file_new_for_path(h.path).?;
        defer c.g_object_unref(file);
        const info = c.g_file_query_info(file, "etag::value", 0, null, null).?;
        defer c.g_object_unref(info);
        try std.testing.expect(seen.etag != null);
        try std.testing.expectEqualStrings(std.mem.span(c.g_file_info_get_etag(info)), std.mem.span(seen.etag));
    }
}

test "load never creates missing files and rejects invalid paths asynchronously" {
    const h = try Harness.init();
    defer h.deinit();
    var missing = Seen{ .context = h.context };
    defer missing.deinit();
    try h.run(&missing);
    try missing.expectError(c.G_IO_ERROR_NOT_FOUND);
    try std.testing.expect(c.g_file_test(h.path, c.G_FILE_TEST_EXISTS) == 0);
    for ([_][:0]const u8{ "", "bad\x00ignored" }) |path| {
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        loader.load(path, h.cancel, &Seen.complete, &seen);
        try std.testing.expectEqual(@as(usize, 0), seen.calls);
        try h.wait(&seen);
        try seen.expectError(c.G_IO_ERROR_INVALID_ARGUMENT);
    }
}

test "load rejects directories, FIFO reloads, FIFO symlinks and sockets promptly" {
    const h = try Harness.init();
    defer h.deinit();
    var directory = Seen{ .context = h.context };
    defer directory.deinit();
    loader.load(std.mem.span(h.directory), h.cancel, &Seen.complete, &directory);
    try h.wait(&directory);
    try directory.expectError(c.G_IO_ERROR_IS_DIRECTORY);

    // Model a path that passed open_target (or a previous load), then changed.
    try h.write("previously regular");
    var regular = Seen{ .context = h.context };
    defer regular.deinit();
    try h.run(&regular);
    try std.testing.expect(regular.ok);
    try std.testing.expect(c.g_unlink(h.path) == 0);
    try std.testing.expect(c.mkfifo(h.path, 0o600) == 0);
    const started = c.g_get_monotonic_time();
    var fifo = Seen{ .context = h.context };
    defer fifo.deinit();
    try h.run(&fifo);
    try fifo.expectError(c.G_IO_ERROR_NOT_REGULAR_FILE);
    try std.testing.expect(c.g_get_monotonic_time() - started < 2_000_000);
    const alias = try std.fmt.allocPrintSentinel(a, "{s}/alias", .{h.directory}, 0);
    defer a.free(alias);
    try std.testing.expect(c.symlink("file", alias) == 0);
    defer _ = c.g_unlink(alias);
    var symlink = Seen{ .context = h.context };
    defer symlink.deinit();
    loader.load(alias, h.cancel, &Seen.complete, &symlink);
    try h.wait(&symlink);
    try symlink.expectError(c.G_IO_ERROR_NOT_REGULAR_FILE);

    try std.testing.expect(c.g_unlink(h.path) == 0);
    const socket = c.g_socket_new(c.G_SOCKET_FAMILY_UNIX, c.G_SOCKET_TYPE_STREAM, c.G_SOCKET_PROTOCOL_DEFAULT, null).?;
    defer c.g_object_unref(socket);
    const address = c.g_unix_socket_address_new(h.path).?;
    defer c.g_object_unref(address);
    try std.testing.expect(c.g_socket_bind(socket, address, 0, null) != 0);
    var socket_result = Seen{ .context = h.context };
    defer socket_result.deinit();
    try h.run(&socket_result);
    // Linux rejects opening a socket itself; no content read or connection.
    try std.testing.expect(!socket_result.ok and socket_result.err != null);
    try std.testing.expect(socket_result.contents == null and socket_result.etag == null);
}

const Race = struct {
    path: [:0]const u8,
    kind: enum { fifo, regular, cancel_open, cancel_read, grow, rewrite },
    fd: c_int = -1,
    done: bool = false,
    worker_thread: bool = false,
    context: *c.GMainContext,

    fn opened(fd: c_int, cancel: *c.GCancellable, data: ?*anyopaque) void {
        const self: *Race = @ptrCast(@alignCast(data.?));
        self.fd = fd;
        self.worker_thread = c.g_main_context_is_owner(self.context) == 0;
        switch (self.kind) {
            .fifo, .regular => {
                std.debug.assert(c.g_unlink(self.path) == 0);
                if (self.kind == .fifo) {
                    std.debug.assert(c.mkfifo(self.path, 0o600) == 0);
                } else {
                    std.debug.assert(c.g_file_set_contents(self.path, "replacement", 11, null) != 0);
                }
            },
            .cancel_open => c.g_cancellable_cancel(cancel),
            else => {},
        }
    }

    fn read(length: usize, cancel: *c.GCancellable, data: ?*anyopaque) void {
        const self: *Race = @ptrCast(@alignCast(data.?));
        std.debug.assert(length > 0);
        if (self.done) return;
        self.done = true;
        switch (self.kind) {
            .cancel_read => c.g_cancellable_cancel(cancel),
            .grow => std.debug.assert(c.truncate(self.path, loader.max_bytes + 1) == 0),
            .rewrite => {
                const fd = std.c.open(self.path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
                std.debug.assert(fd >= 0);
                defer _ = std.c.close(fd);
                // Change size deterministically, not a timing-based timestamp test.
                std.debug.assert(c.ftruncate(fd, 1) == 0);
                std.debug.assert(c.write(fd, "x", 1) == 1);
            },
            else => {},
        }
    }

    fn expectClosed(self: Race) !void {
        try std.testing.expect(self.fd >= 0);
        try std.testing.expect(self.worker_thread);
        var stat: c.GStatBuf = undefined;
        try std.testing.expect(c.fstat(self.fd, &stat) == -1);
        try std.testing.expectEqual(std.c.E.BADF, std.c.errno(@as(c_int, -1)));
    }
};

test "held descriptor survives unlink and replacement with FIFO or different regular inode" {
    const h = try Harness.init();
    defer h.deinit();
    for ([_]@FieldType(Race, "kind"){ .fifo, .regular }) |kind| {
        _ = c.g_unlink(h.path);
        try h.write("original pinned bytes");
        const file = c.g_file_new_for_path(h.path).?;
        defer c.g_object_unref(file);
        const info = c.g_file_query_info(file, "etag::value", 0, null, null).?;
        defer c.g_object_unref(info);
        var race = Race{ .path = h.path, .kind = kind, .context = h.context };
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        loader.testing.loadWithHooks(h.path, h.cancel, &Seen.complete, &seen, .{ .data = &race, .after_open = &Race.opened });
        try h.wait(&seen);
        try std.testing.expect(seen.ok);
        try std.testing.expectEqualStrings("original pinned bytes", seen.contents[0..seen.length]);
        try std.testing.expectEqualStrings(std.mem.span(c.g_file_info_get_etag(info)), std.mem.span(seen.etag));
        try race.expectClosed();
    }
}

test "pre-cancelled loads and cancellation after acquisition or mid-read finish once without data" {
    for (0..3) |mode| {
        const h = try Harness.init();
        defer h.deinit();
        try h.write("content");
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        var race = Race{ .path = h.path, .kind = if (mode == 1) .cancel_open else .cancel_read, .context = h.context };
        if (mode == 0) {
            c.g_cancellable_cancel(h.cancel);
            try h.run(&seen);
        } else {
            loader.testing.loadWithHooks(h.path, h.cancel, &Seen.complete, &seen, .{ .data = &race, .after_open = &Race.opened, .after_read = &Race.read });
            try h.wait(&seen);
            try race.expectClosed();
            if (mode == 2) try std.testing.expect(race.done);
        }
        try seen.expectError(c.G_IO_ERROR_CANCELLED);
    }
}

test "cancellation at delivery discards an already completed successful result" {
    const h = try Harness.init();
    defer h.deinit();
    try h.write("successful worker result must not escape late cancellation");
    var seen = Seen{ .context = h.context, .cancel_before_finish = h.cancel };
    defer seen.deinit();
    var race = Race{ .path = h.path, .kind = .regular, .context = h.context };
    loader.testing.loadWithHooks(h.path, h.cancel, &Seen.complete, &seen, .{ .data = &race, .after_open = &Race.opened });
    try h.wait(&seen);
    try seen.expectError(c.G_IO_ERROR_CANCELLED);
    try race.expectClosed();
}

test "load enforces inclusive 128 MiB cap and rejects one extra byte without partial success" {
    const h = try Harness.init();
    defer h.deinit();
    try h.write("");
    try std.testing.expect(c.truncate(h.path, loader.max_bytes) == 0);
    var exact = Seen{ .context = h.context };
    defer exact.deinit();
    try h.run(&exact);
    try std.testing.expect(exact.ok);
    try std.testing.expectEqual(loader.max_bytes, exact.length);
    try std.testing.expectEqual(@as(u8, 0), exact.contents[exact.length]);
    try std.testing.expect(c.truncate(h.path, loader.max_bytes + 1) == 0);
    var oversized = Seen{ .context = h.context };
    defer oversized.deinit();
    try h.run(&oversized);
    try oversized.expectError(c.G_IO_ERROR_MESSAGE_TOO_LARGE);
}

test "growing files still hit read cap and in-place mutation is rejected" {
    const h = try Harness.init();
    defer h.deinit();
    for ([_]@FieldType(Race, "kind"){ .grow, .rewrite }) |kind| {
        try h.write("initial content");
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        var race = Race{ .path = h.path, .kind = kind, .context = h.context };
        loader.testing.loadWithHooks(h.path, h.cancel, &Seen.complete, &seen, .{ .data = &race, .after_open = &Race.opened, .after_read = &Race.read });
        try h.wait(&seen);
        try std.testing.expect(race.done);
        try seen.expectError(if (kind == .grow) c.G_IO_ERROR_MESSAGE_TOO_LARGE else c.G_IO_ERROR_BUSY);
        try race.expectClosed();
    }
}

test "loaded etag permits ordinary GIO replacement and rejects external edits" {
    const h = try Harness.init();
    defer h.deinit();
    try h.write("original");
    const file = c.g_file_new_for_path(h.path).?;
    defer c.g_object_unref(file);
    var first = Seen{ .context = h.context };
    defer first.deinit();
    try h.run(&first);
    try std.testing.expect(first.ok);
    try std.testing.expect(c.g_file_replace_contents(file, "saved", 5, first.etag, 0, c.G_FILE_CREATE_NONE, null, null, null) != 0);
    var second = Seen{ .context = h.context };
    defer second.deinit();
    try h.run(&second);
    try std.testing.expect(second.ok);
    try std.testing.expectEqualStrings("saved", second.contents[0..second.length]);
    try h.write("external edit");
    // Force a distinct mtime even on coarse-timestamp filesystems.
    try std.testing.expect(c.g_file_set_attribute_uint64(file, "time::modified", 123456789, 0, null, null) != 0);
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    try std.testing.expect(c.g_file_replace_contents(file, "lost", 4, second.etag, 0, c.G_FILE_CREATE_NONE, null, null, &err) == 0);
    try std.testing.expectEqual(@as(c_int, c.G_IO_ERROR_WRONG_ETAG), err.?.code);
    var external = Seen{ .context = h.context };
    defer external.deinit();
    try h.run(&external);
    try std.testing.expect(external.ok);
    try std.testing.expectEqualStrings("external edit", external.contents[0..external.length]);
}

fn descriptorCount() !usize {
    const directory = c.g_dir_open("/proc/self/fd", 0, null) orelse return error.ProcUnavailable;
    defer c.g_dir_close(directory);
    var count: usize = 0;
    while (c.g_dir_read_name(directory) != null) count += 1;
    return count;
}

test "repeated loads and discarded completions release descriptors" {
    const h = try Harness.init();
    defer h.deinit();
    try h.write("warm GTask worker and local VFS");
    var warm = Seen{ .context = h.context };
    defer warm.deinit();
    try h.run(&warm);
    try std.testing.expect(warm.ok);
    const before = try descriptorCount();
    for (0..20) |i| {
        var seen = Seen{ .context = h.context, .discard = i % 2 == 0 };
        defer seen.deinit();
        try h.run(&seen);
        if (!seen.discard) try std.testing.expect(seen.ok);
    }
    try std.testing.expect(c.g_unlink(h.path) == 0);
    try std.testing.expect(c.mkfifo(h.path, 0o600) == 0);
    for (0..10) |_| {
        var seen = Seen{ .context = h.context };
        defer seen.deinit();
        try h.run(&seen);
        try seen.expectError(c.G_IO_ERROR_NOT_REGULAR_FILE);
    }
    try std.testing.expectEqual(before, try descriptorCount());
}
