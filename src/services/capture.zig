//! Native one-shot output capture. Portal ownership and screensharing are untouched.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const gdk = @import("gdk4");
const object = @import("gobject2");
const backend = @import("gdkwayland4");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;
const pixbuf = @import("gdkpixbuf2");
const clipboard = @import("clipboard.zig");
const policy = clipboard.policy;
const Text = @import("policy.zig").Text;
const a = std.heap.c_allocator;
const Output = struct { owner: *Capture, proxy: *wl.Output, id: u32, name: Text(128) = .{}, transform: u32 = 0 };
const Job = struct { owner: *Capture, cancel: *gio.Cancellable, pixels: []u8, width: u32, height: u32, stride: u32, format: u32, transform: u32, inverted: bool, region: ?policy.Region, connector: Text(128), logical_width: i32, logical_height: i32, png: ?[]u8 = null, out_width: i32 = 0, out_height: i32 = 0 };
pub const Capture = struct {
    app: *gio.Application,
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    registry: ?*wl.Registry = null,
    manager: ?*zwlr.ScreencopyManagerV1 = null,
    manager_id: u32 = 0,
    shm: ?*wl.Shm = null,
    shm_id: u32 = 0,
    outputs: std.ArrayList(*Output) = .empty,
    target: ?*Output = null,
    frame: ?*zwlr.ScreencopyFrameV1 = null,
    buffer: ?*wl.Buffer = null,
    mapping: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    format: u32 = 0,
    inverted: bool = false,
    crop: ?policy.Region = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    start_delay: c_uint = 0,
    deadline: c_uint = 0,
    job: ?*Job = null,
    locked: bool = true,
    image: ?[]u8 = null,
    image_crop: ?policy.Region = null,
    image_output: Text(128) = .{},
    image_width: i32 = 0,
    image_height: i32 = 0,
    generation: u64 = 0,
    message: [:0]const u8 = "Capture paused",
    saved: Text(1024) = .{},
    pub fn start(self: *Capture) !void {
        const display = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.Unavailable;
        const connection: *wl.Display = @ptrCast(display.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Capture, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Capture) void {
        self.setLocked(true);
        self.cancel();
        self.clearImage();
        for (self.outputs.items) |o| {
            o.proxy.release();
            a.destroy(o);
        }
        self.outputs.deinit(a);
        if (self.manager) |m| m.destroy();
        if (self.shm) |s| @as(*wl.Proxy, @ptrCast(s)).destroy();
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
    }
    pub fn setLocked(self: *Capture, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        if (locked) {
            self.cancel();
            self.clearImage();
            self.saved.set("");
            self.message = "Capture paused";
        } else self.message = "Capture an output or a region of its visible contents";
        self.changed(self.context);
    }
    fn clearImage(self: *Capture) void {
        if (self.image) |bytes| {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        self.image = null;
        self.image_crop = null;
        self.image_output.set("");
        self.image_width = 0;
        self.image_height = 0;
    }
    pub fn cancel(self: *Capture) void {
        self.fail("Capture cancelled");
    }
    fn fail(self: *Capture, message: [:0]const u8) void {
        if (self.start_delay != 0) _ = glib.Source.remove(self.start_delay);
        self.start_delay = 0;
        if (self.job) |j| j.cancel.cancel();
        self.releaseFrame();
        self.target = null;
        self.message = message;
        self.changed(self.context);
    }
    fn releaseFrame(self: *Capture) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (self.frame) |f| f.destroy();
        self.frame = null;
        if (self.buffer) |b| b.destroy();
        self.buffer = null;
        if (self.mapping) |m| {
            std.crypto.secureZero(u8, m);
            _ = std.c.munmap(@ptrCast(@alignCast(m.ptr)), m.len);
        }
        self.mapping = null;
    }
    pub fn pending(self: *Capture) bool {
        return self.start_delay != 0 or self.frame != null or self.job != null;
    }
    pub fn take(self: *Capture, connector: []const u8, width: i32, height: i32, crop: ?policy.Region) !void {
        if (self.locked) return error.Locked;
        if (self.pending()) return error.Busy;
        _ = self.manager orelse return error.Unavailable;
        if (self.shm == null or width <= 0 or height <= 0) return error.Unavailable;
        var target: ?*Output = null;
        for (self.outputs.items) |o| if (std.mem.eql(u8, connector, o.name.slice())) {
            if (target != null) return error.OutputUnavailable;
            target = o;
        };
        const output = target orelse return error.OutputUnavailable;
        self.target = output;
        self.crop = crop;
        self.logical_width = width;
        self.logical_height = height;
        self.width = 0;
        self.inverted = false;
        self.start_delay = glib.timeoutAdd(200, beginFrame, self);
        self.message = "Capturing…";
        self.changed(self.context);
    }
    fn beginFrame(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Capture = @ptrCast(@alignCast(data.?));
        self.start_delay = 0;
        self.frame = self.manager.?.captureOutput(0, self.target.?.proxy) catch {
            self.cancel();
            return 0;
        };
        self.frame.?.setListener(*Capture, frameEvent, self);
        self.display.flush();
        self.deadline = glib.timeoutAdd(5000, expired, self);
        return 0;
    }
    pub fn validateTarget(self: *Capture, connector: []const u8, width: i32, height: i32) void {
        if (self.target) |o| if (std.mem.eql(u8, connector, o.name.slice()) and (width != self.logical_width or height != self.logical_height)) self.cancel();
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Capture = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.fail("Capture timed out — try again");
        return 0;
    }
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Capture) void {
        switch (event) {
            .global => |g| {
                const name = std.mem.span(g.interface);
                if (std.mem.eql(u8, name, "zwlr_screencopy_manager_v1") and g.version >= 3 and self.manager == null) {
                    self.manager = self.registry.?.bind(g.name, zwlr.ScreencopyManagerV1, 3) catch return;
                    self.manager_id = g.name;
                }
                if (std.mem.eql(u8, name, "wl_shm") and self.shm == null) {
                    self.shm = self.registry.?.bind(g.name, wl.Shm, 1) catch return;
                    self.shm_id = g.name;
                    self.shm.?.setListener(*Capture, shmEvent, self);
                }
                if (std.mem.eql(u8, name, "wl_output") and g.version >= 4 and self.outputs.items.len < 32) {
                    const output = a.create(Output) catch return;
                    const proxy = self.registry.?.bind(g.name, wl.Output, 4) catch {
                        a.destroy(output);
                        return;
                    };
                    output.* = .{ .owner = self, .proxy = proxy, .id = g.name };
                    self.outputs.append(a, output) catch {
                        proxy.release();
                        a.destroy(output);
                        return;
                    };
                    proxy.setListener(*Output, outputEvent, output);
                }
            },
            .global_remove => |g| {
                for (self.outputs.items, 0..) |o, i| if (o.id == g.name) {
                    if (self.target == o) self.cancel();
                    o.proxy.release();
                    a.destroy(o);
                    _ = self.outputs.orderedRemove(i);
                    break;
                };
                if (g.name == self.manager_id) {
                    self.cancel();
                    self.manager.?.destroy();
                    self.manager = null;
                }
                if (g.name == self.shm_id) {
                    self.cancel();
                    @as(*wl.Proxy, @ptrCast(self.shm.?)).destroy();
                    self.shm = null;
                }
            },
        }
        self.changed(self.context);
    }
    fn shmEvent(_: *wl.Shm, _: wl.Shm.Event, _: *Capture) void {}
    fn outputEvent(_: *wl.Output, event: wl.Output.Event, o: *Output) void {
        if (event == .geometry or event == .mode or event == .scale) if (o.owner.target == o) o.owner.cancel();
        switch (event) {
            .geometry => |g| o.transform = @intCast(@intFromEnum(g.transform)),
            .name => |n| o.name.set(std.mem.span(n.name)),
            else => {},
        }
    }
    fn frameEvent(_: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, self: *Capture) void {
        switch (event) {
            .buffer => |b| {
                self.width = b.width;
                self.height = b.height;
                self.stride = b.stride;
                self.format = b.format;
            },
            .buffer_done => self.allocate() catch {
                self.fail("Unsupported or oversized screenshot buffer");
            },
            .flags => |f| self.inverted = f.flags.y_invert,
            .ready => self.convert() catch {
                self.fail("Screenshot conversion failed");
            },
            .failed => {
                self.fail("Output capture failed — try again");
            },
            else => {},
        }
        self.changed(self.context);
    }
    fn allocate(self: *Capture) !void {
        if (self.buffer != null or self.width == 0 or self.height == 0 or self.width > 8192 or self.height > 8192 or @as(u64, self.width) * self.height > 8 * 1024 * 1024 or self.stride < self.width * 4 or self.stride > self.width * 4 + 4096) return error.InvalidBuffer;
        if (self.format != 0 and self.format != 1 and self.format != 0x34324241 and self.format != 0x34324258) return error.Unsupported;
        const size: usize = @as(usize, self.stride) * self.height;
        if (size > 40 * 1024 * 1024) return error.InvalidBuffer;
        const raw = std.os.linux.memfd_create("pearl-capture", 1);
        if (std.os.linux.errno(raw) != .SUCCESS) return error.Allocation;
        const fd: c_int = @intCast(raw);
        defer _ = std.c.close(fd);
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.Allocation;
        const ptr = std.c.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (ptr == std.c.MAP_FAILED) return error.Allocation;
        self.mapping = @as([*]u8, @ptrCast(ptr))[0..size];
        const pool = try self.shm.?.createPool(fd, @intCast(size));
        defer pool.destroy();
        self.buffer = try pool.createBuffer(0, @intCast(self.width), @intCast(self.height), @intCast(self.stride), @enumFromInt(self.format));
        self.buffer.?.setListener(*Capture, bufferEvent, self);
        self.frame.?.copy(self.buffer.?);
        self.display.flush();
    }
    fn bufferEvent(_: *wl.Buffer, _: wl.Buffer.Event, _: *Capture) void {}
    fn convert(self: *Capture) !void {
        const pixels = try a.dupe(u8, self.mapping orelse return error.InvalidBuffer);
        errdefer a.free(pixels);
        const job = try a.create(Job);
        job.* = .{ .owner = self, .cancel = gio.Cancellable.new(), .pixels = pixels, .width = self.width, .height = self.height, .stride = self.stride, .format = self.format, .transform = self.target.?.transform, .inverted = self.inverted, .region = self.crop, .connector = self.target.?.name, .logical_width = self.logical_width, .logical_height = self.logical_height };
        self.job = job;
        self.releaseFrame();
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
        render(job) catch {};
        task.returnBoolean(1);
    }
    fn render(j: *Job) !void {
        const rotated = j.transform & 1 != 0;
        const width = if (rotated) j.height else j.width;
        const height = if (rotated) j.width else j.height;
        const rgb = try a.alloc(u8, @as(usize, width) * height * 3);
        defer {
            std.crypto.secureZero(u8, rgb);
            a.free(rgb);
        }
        for (0..j.height) |y| {
            if (j.cancel.isCancelled() != 0) return error.Cancelled;
            for (0..j.width) |x| {
                const sy = if (j.inverted) j.height - 1 - y else y;
                const src = sy * j.stride + x * 4;
                var dx: usize = undefined;
                var dy: usize = undefined;
                switch (j.transform & 3) {
                    0 => {
                        dx = x;
                        dy = y;
                    },
                    1 => {
                        dx = j.height - 1 - y;
                        dy = x;
                    },
                    2 => {
                        dx = j.width - 1 - x;
                        dy = j.height - 1 - y;
                    },
                    3 => {
                        dx = y;
                        dy = j.width - 1 - x;
                    },
                    else => unreachable,
                }
                if (j.transform & 4 != 0) dx = width - 1 - dx;
                const dst = (dy * width + dx) * 3;
                const bgr = j.format == 0 or j.format == 1;
                rgb[dst] = j.pixels[src + @as(usize, if (bgr) 2 else 0)];
                rgb[dst + 1] = j.pixels[src + 1];
                rgb[dst + 2] = j.pixels[src + @as(usize, if (bgr) 0 else 2)];
            }
        }
        const image = pixbuf.Pixbuf.newFromData(rgb.ptr, .rgb, 0, 8, @intCast(width), @intCast(height), @intCast(width * 3), null, null);
        defer image.unref();
        var crop: ?*pixbuf.Pixbuf = null;
        defer if (crop) |c| c.unref();
        if (j.region) |r| {
            // Map logical extents to the actual transformed buffer, rounding outwards.
            const x: i32 = @intCast(@divFloor(@as(i64, r.x) * width, j.logical_width));
            const y: i32 = @intCast(@divFloor(@as(i64, r.y) * height, j.logical_height));
            const right: i32 = @intCast(@divFloor(@as(i64, r.x + r.width) * width + j.logical_width - 1, j.logical_width));
            const bottom: i32 = @intCast(@divFloor(@as(i64, r.y + r.height) * height + j.logical_height - 1, j.logical_height));
            crop = image.newSubpixbuf(x, y, right - x, bottom - y);
        }
        if (j.cancel.isCancelled() != 0) return error.Cancelled;
        const result = crop orelse image;
        j.out_width = result.getWidth();
        j.out_height = result.getHeight();
        j.png = try clipboard.encode(result);
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        const self = j.owner;
        _ = object.ext.cast(gio.Task, result).?.propagateBoolean(null);
        defer self.app.release();
        self.job = null;
        self.target = null;
        if (j.cancel.isCancelled() == 0 and !self.locked) {
            if (j.png) |bytes| {
                self.clearImage();
                self.image = bytes;
                j.png = null;
                self.image_crop = j.region;
                self.image_output = j.connector;
                self.image_width = j.out_width;
                self.image_height = j.out_height;
                self.generation += 1;
                self.saved.set("");
                self.message = "Screenshot ready — save or copy";
            } else self.message = "Screenshot conversion failed — try again";
        }
        if (j.png) |bytes| {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        std.crypto.secureZero(u8, j.pixels);
        a.free(j.pixels);
        j.cancel.unref();
        a.destroy(j);
        self.changed(self.context);
    }
    pub fn copy(self: *Capture, history: *clipboard.Clipboard, generation: u64) !void {
        if (self.locked) return error.Locked;
        if (generation != self.generation) return error.Stale;
        const bytes = self.image orelse return error.Unavailable;
        try history.add(.png, bytes);
        // A duplicate may already exist deeper in history.
        for (history.entries.items) |e| if (e.kind == .png and std.mem.eql(u8, e.bytes, bytes)) {
            try history.select(e.id);
            self.message = "Screenshot copied";
            self.changed(self.context);
            return;
        };
        return error.InvalidPayload;
    }
    pub fn save(self: *Capture, generation: u64, path: ?[]const u8) !void {
        if (self.locked) return error.Locked;
        if (generation != self.generation) return error.Stale;
        const bytes = self.image orelse return error.Unavailable;
        const destination = if (path) |p| try a.dupeZ(u8, p) else blk: {
            const pictures = glib.getUserSpecialDir(.directory_pictures) orelse glib.getHomeDir();
            const dir = try std.fmt.allocPrintSentinel(a, "{s}/Pearl Screenshots", .{pictures}, 0);
            defer a.free(dir);
            try @import("../config/io.zig").mkdir(dir);
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/Screenshot-{d}-{d}.png", .{ dir, glib.getRealTime(), self.generation }, 0);
        };
        defer a.free(destination);
        if (destination.len == 0 or destination[0] != '/' or destination.len >= 1024) return error.InvalidPath;
        try @import("../config/io.zig").atomic(destination, bytes, true);
        self.saved.set(destination);
        self.message = "Screenshot saved";
        self.changed(self.context);
    }
    pub fn status(self: *Capture, alloc: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(alloc, .{ .available = self.manager != null and self.shm != null, .locked = self.locked, .pending = self.pending(), .ready = self.image != null, .generation = self.generation, .width = self.image_width, .height = self.image_height, .isolated_window = false, .output_crop = self.image_crop != null, .region = self.image_crop, .output_connector = self.image_output.slice(), .message = self.message, .saved = self.saved.slice() }, .{});
    }
};
