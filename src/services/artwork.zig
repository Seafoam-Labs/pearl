//! One cancellable worker, 2 MiB input, validated PNG/JPEG dimensions, 256px output.
//! Local file URIs only; remote art never initiates network traffic.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const Text = @import("policy.zig").Text;
const a = std.heap.c_allocator;
const limit = 2 * 1024 * 1024;
const Job = struct { art: *Art, uri: Text(512), epoch: u64, cancel: *gio.Cancellable };
pub const Art = struct {
    app: *gio.Application = undefined,
    context: *anyopaque = undefined,
    changed: *const fn (*anyopaque) void = undefined,
    uri: Text(512) = .{},
    epoch: u64 = 0,
    job: ?*Job = null,
    image: ?*pixbuf.Pixbuf = null,
    pub fn want(self: *Art, uri: []const u8) void {
        if (std.mem.eql(u8, self.uri.slice(), uri)) return;
        self.uri.set(uri);
        self.epoch += 1;
        if (self.image) |image| image.unref();
        self.image = null;
        if (self.job) |job| job.cancel.cancel() else self.launch();
    }
    fn launch(self: *Art) void {
        if (!std.mem.startsWith(u8, self.uri.slice(), "file:///") or self.uri.len >= 512) return;
        const job = a.create(Job) catch return;
        job.* = .{ .art = self, .uri = self.uri, .epoch = self.epoch, .cancel = gio.Cancellable.new() };
        self.job = job;
        self.app.hold();
        const task = gio.Task.new(null, job.cancel, completed, job);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        task.returnPointer(load(job), null);
    }
    fn load(job: *Job) ?*pixbuf.Pixbuf {
        const file = gio.File.newForUri(job.uri.z());
        defer file.unref();
        const path = file.getPath() orelse return null;
        defer glib.free(path);
        // O_NONBLOCK prevents malicious FIFO/device opens from hanging a worker.
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
        if (fd < 0) return null;
        defer _ = std.c.close(fd);
        var stat: std.os.linux.Statx = undefined;
        if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat) != 0 or !stat.mask.TYPE or !stat.mask.SIZE or stat.mode & std.c.S.IFMT != std.c.S.IFREG or stat.size < 1 or stat.size > limit) return null;
        const bytes = a.alloc(u8, limit + 1) catch return null;
        defer a.free(bytes);
        var used: usize = 0;
        while (used < bytes.len) {
            if (job.cancel.isCancelled() != 0) return null;
            const n = std.c.read(fd, bytes[used..].ptr, @min(65536, bytes.len - used));
            if (n < 0) return null;
            if (n == 0) break;
            used += @intCast(n);
        }
        if (used > limit or !dimensions(bytes[0..used])) return null;
        const storage = glib.Bytes.new(bytes.ptr, used);
        defer storage.unref();
        const stream = gio.MemoryInputStream.newFromBytes(storage);
        defer stream.unref();
        var err: ?*glib.Error = null;
        const image = pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), 256, 256, 1, job.cancel, &err);
        if (err) |e| e.free();
        return image;
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const self = job.art;
        defer self.app.release();
        const task = object.ext.cast(gio.Task, result).?;
        const raw = task.propagatePointer(null);
        const image: ?*pixbuf.Pixbuf = if (raw) |p| @ptrCast(@alignCast(p)) else null;
        self.job = null;
        const current = job.epoch == self.epoch;
        job.cancel.unref();
        a.destroy(job);
        if (current) {
            self.image = image;
            self.changed(self.context);
        } else {
            if (image) |p| p.unref();
            self.launch();
        }
    }
};
fn valid(w: u32, h: u32, max_axis: u32, max_pixels: u64) bool {
    return w > 0 and h > 0 and w <= max_axis and h <= max_axis and @as(u64, w) * h <= max_pixels;
}
pub fn dimensions(bytes: []const u8) bool {
    return dimensionsWithin(bytes, 4096, 8 * 1024 * 1024);
}
pub fn dimensionsWithin(bytes: []const u8, max_axis: u32, max_pixels: u64) bool {
    if (bytes.len >= 33 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return valid(std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big), max_axis, max_pixels);
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return false;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xff) return false;
        const marker = bytes[i + 1];
        if (marker == 0xff) {
            i += 1;
            continue;
        }
        if (marker == 0xda or marker == 0xd9) return false;
        const size = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (size < 2 or i + 2 + size > bytes.len) return false;
        if (marker == 0xc0 or marker == 0xc1 or marker == 0xc2) {
            if (size < 8) return false;
            return valid(std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big), std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big), max_axis, max_pixels);
        }
        i += 2 + size;
    }
    return false;
}

test "artwork rejects huge dimensions, unsupported formats and truncated JPEG headers" {
    const t = std.testing;
    var png: [33]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 256, .big);
    std.mem.writeInt(u32, png[20..24], 256, .big);
    try t.expect(dimensions(&png));
    std.mem.writeInt(u32, png[16..20], 0x7fffffff, .big);
    try t.expect(!dimensions(&png));
    try t.expect(!dimensions("<svg width='1000000'/>"));
    try t.expect(!dimensions(&.{ 0xff, 0xd8, 0xff, 0xc0, 0, 8 }));
    try t.expect(dimensions(&.{ 0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 32, 0, 32, 0 }));
}
