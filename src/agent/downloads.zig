const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const registry = @import("model_registry.zig");
const fetch = @import("fetch.zig");
const a = std.heap.c_allocator;
pub fn directory(alloc: std.mem.Allocator) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}/pearl/assistant/models", .{glib.getUserDataDir()}, 0);
}
pub fn path(alloc: std.mem.Allocator, model: registry.Model) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ try directory(alloc), model.filename }, 0);
}
pub fn verify(filename: [:0]const u8, model: ?registry.Model, cancel: *gio.Cancellable) ![64]u8 {
    const fd = std.c.open(filename, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return error.ModelNotInstalled;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG or st.size < 16) return error.InvalidModelFile;
    if (model) |m| if (st.size != m.bytes) return error.ModelChecksumMismatch;
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n < 0) return error.ModelReadFailed;
        if (n == 0) break;
        const bytes = buffer[0..@intCast(n)];
        if (total == 0 and (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "GGUF") or std.mem.readInt(u32, bytes[4..8], .little) != 3)) return error.InvalidModelFile;
        total += bytes.len;
        if (total > st.size) return error.ModelChanged;
        sha.update(bytes);
    }
    if (total != st.size) return error.ModelChanged;
    const digest = std.fmt.bytesToHex(sha.finalResult(), .lower);
    if (model) |m| if (!std.mem.eql(u8, &digest, m.sha256)) return error.ModelChecksumMismatch;
    return digest;
}
pub fn install(model: registry.Model, cancel: *gio.Cancellable, progress: *std.atomic.Value(u64)) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const dir = try directory(alloc);
    if (glib.mkdirWithParents(dir, 0o700) != 0) return error.ModelDirectoryUnavailable;
    const target = try path(alloc, model);
    const partial = try std.fmt.allocPrintSentinel(alloc, "{s}.part", .{target}, 0);
    const fd = std.c.open(partial, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
    if (fd < 0) return error.ModelDownloadUnavailable;
    defer _ = std.c.close(fd);
    if (fetch.c.flock(fd, fetch.c.LOCK_EX | fetch.c.LOCK_NB) != 0) return error.ModelDownloadAlreadyRunning;
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidModelFile;
    if (st.size > model.bytes) {
        _ = std.c.unlink(partial);
        return error.ModelChecksumMismatch;
    }
    const offset: usize = @intCast(st.size);
    var space: fetch.c.struct_statvfs = undefined;
    if (fetch.c.fstatvfs(fd, &space) != 0 or space.f_bavail *| space.f_frsize < model.bytes - offset + 1024 * 1024) return error.InsufficientModelDiskSpace;
    if (std.c.lseek(fd, @intCast(offset), std.c.SEEK.SET) < 0) return error.ModelDownloadFailed;
    progress.store(offset, .monotonic);
    if (offset < model.bytes) {
        const response = try fetch.request(alloc, .{ .url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ model.base_url, model.filename }), .max_bytes = model.bytes - offset, .resume_from = offset, .timeout_seconds = 1800, .output_fd = fd, .progress = progress }, cancel);
        if (response.status != (if (offset > 0) @as(c_long, 206) else 200)) return error.ModelDownloadFailed;
    }
    if (std.c.fsync(fd) != 0) return error.ModelDownloadFailed;
    _ = verify(partial, model, cancel) catch |err| {
        if (err != error.Cancelled) _ = std.c.unlink(partial);
        return err;
    };
    if (cancel.isCancelled() != 0) return error.Cancelled;
    if (std.c.rename(partial, target) != 0) return error.ModelDownloadFailed;
}
pub fn remove(model: registry.Model) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    if (std.c.unlink(try path(arena.allocator(), model)) != 0) return error.ModelRemoveFailed;
}

test "large custom GGUFs reach cancellable verification without a size ceiling" {
    var name = "/tmp/pearl-large-model-XXXXXX".*;
    const fd = glib.mkstempFull(&name, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CLOEXEC = true }), 0o600);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(&name);
    try std.testing.expectEqual(@as(isize, 16), std.c.write(fd, "GGUF\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 16));
    // Sparse file: exercise the multi-GB boundary without allocating weights.
    try std.testing.expectEqual(@as(c_int, 0), fetch.c.ftruncate(fd, 4 * @as(i64, 1024 * 1024 * 1024)));
    const cancel = gio.Cancellable.new();
    defer cancel.unref();
    cancel.cancel();
    try std.testing.expectError(error.Cancelled, verify(&name, null, cancel));
    try std.testing.expectError(error.ModelChecksumMismatch, verify(&name, registry.models[0], cancel));
}
