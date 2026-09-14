//! Native image-copy capture and exact foreign-toplevel source identities.
const std = @import("std");
const glib = @import("glib2");
const native = @import("wayland").client;
const wl = native.wl;
const ext = native.ext;
const aq = native.aqueous;
const Capture = @import("capture.zig").Capture;
const Text = @import("policy.zig").Text;
const a = std.heap.c_allocator;
pub const Window = struct { owner: *Copy, proxy: *ext.ForeignToplevelHandleV1, id: Text(128) = .{}, title: Text(512) = .{}, app_id: Text(256) = .{}, done: bool = false };
pub const Copy = struct {
    owner: *Capture = undefined,
    manager: ?*ext.ImageCopyCaptureManagerV1 = null,
    output: ?*ext.OutputImageCaptureSourceManagerV1 = null,
    toplevel: ?*ext.ForeignToplevelImageCaptureSourceManagerV1 = null,
    list: ?*ext.ForeignToplevelListV1 = null,
    colors: ?*aq.CaptureColorManagerV1 = null,
    globals: [5]u32 = @splat(0),
    windows: std.ArrayList(*Window) = .empty,
    target: ?*Window = null,
    source: ?*ext.ImageCaptureSourceV1 = null,
    session: ?*ext.ImageCopyCaptureSessionV1 = null,
    frame: ?*ext.ImageCopyCaptureFrameV1 = null,
    color: ?*aq.CaptureColorInfoV1 = null,
    transform: u32 = 0,
    primaries: u32 = 0,
    transfer: u32 = 0,
    described: bool = false,
    pub fn status(self: *const Copy, alloc: std.mem.Allocator, offset: usize) ![]const u8 {
        const Item = struct { id: []const u8, title: []const u8, app_id: []const u8 };
        var items: std.ArrayList(Item) = .empty;
        if (!self.owner.locked) for (self.windows.items[@min(offset, self.windows.items.len)..]) |window| {
            if (items.items.len >= 32) break;
            if (window.done and window.id.len > 0) try items.append(alloc, .{ .id = window.id.slice(), .title = window.title.slice(), .app_id = window.app_id.slice() });
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .available = self.windowAvailable(), .windows = items.items, .total = if (self.owner.locked) @as(usize, 0) else self.windows.items.len, .offset = offset }, .{});
    }
    pub fn available(self: *const Copy) bool {
        return self.manager != null and self.colors != null;
    }
    pub fn windowAvailable(self: *const Copy) bool {
        return self.available() and self.toplevel != null and self.list != null;
    }
    pub fn registry(self: *Copy, event: wl.Registry.Event) void {
        switch (event) {
            .global => |g| {
                inline for (.{ .{ "ext_image_copy_capture_manager_v1", "manager", ext.ImageCopyCaptureManagerV1 }, .{ "ext_output_image_capture_source_manager_v1", "output", ext.OutputImageCaptureSourceManagerV1 }, .{ "ext_foreign_toplevel_image_capture_source_manager_v1", "toplevel", ext.ForeignToplevelImageCaptureSourceManagerV1 }, .{ "ext_foreign_toplevel_list_v1", "list", ext.ForeignToplevelListV1 }, .{ "aqueous_capture_color_manager_v1", "colors", aq.CaptureColorManagerV1 } }, 0..) |item, i| {
                    if (g.version >= 1 and std.mem.eql(u8, std.mem.span(g.interface), item[0]) and @field(self, item[1]) == null) {
                        @field(self, item[1]) = self.owner.registry.?.bind(g.name, item[2], 1) catch return;
                        self.globals[i] = g.name;
                        if (comptime i == 3) self.list.?.setListener(*Copy, listEvent, self);
                    }
                }
            },
            .global_remove => |g| inline for (.{ "manager", "output", "toplevel", "list", "colors" }, 0..) |field, i| {
                if (g.name == self.globals[i]) {
                    self.owner.cancel();
                    if (@field(self, field)) |proxy| proxy.destroy();
                    @field(self, field) = null;
                    self.globals[i] = 0;
                }
            },
        }
    }
    pub fn stop(self: *Copy) void {
        self.release();
        for (self.windows.items) |window| {
            window.proxy.destroy();
            a.destroy(window);
        }
        self.windows.deinit(a);
        self.windows = .empty;
        inline for (.{ "manager", "output", "toplevel", "list", "colors" }) |field| {
            if (@field(self, field)) |proxy| proxy.destroy();
            @field(self, field) = null;
        }
    }
    pub fn release(self: *Copy) void {
        if (self.color) |v| v.destroy();
        self.color = null;
        if (self.frame) |v| v.destroy();
        self.frame = null;
        if (self.session) |v| v.destroy();
        self.session = null;
        if (self.source) |v| v.destroy();
        self.source = null;
        self.target = null;
    }
    pub fn takeWindow(self: *Copy, id: []const u8) !void {
        if (self.owner.locked) return error.Locked;
        if (self.owner.pending()) return error.Busy;
        if (!self.windowAvailable() or self.owner.shm == null) return error.Unavailable;
        var target: ?*Window = null;
        for (self.windows.items) |window| if (window.done and window.id.len > 0 and std.mem.eql(u8, id, window.id.slice())) {
            if (target != null) return error.AmbiguousWindow;
            target = window;
        };
        self.target = target orelse return error.WindowUnavailable;
        self.owner.clearImage();
        self.owner.saved.set("");
        self.owner.target = null;
        self.owner.crop = null;
        self.owner.width = 0;
        self.owner.inverted = false;
        self.source = try self.toplevel.?.createSource(self.target.?.proxy);
        errdefer self.release();
        try self.begin();
    }
    pub fn takeOutput(self: *Copy, output: *wl.Output) !void {
        self.source = try (self.output orelse return error.Unavailable).createSource(output);
        errdefer self.release();
        try self.begin();
    }
    fn begin(self: *Copy) !void {
        self.described = false;
        self.primaries = 0;
        self.transfer = 0;
        self.transform = 0;
        self.owner.format = std.math.maxInt(u32);
        self.session = try self.manager.?.createSession(self.source.?, .{});
        self.session.?.setListener(*Copy, sessionEvent, self);
        self.owner.deadline = glib.timeoutAdd(5000, Capture.expired, self.owner);
        self.owner.message = "Capturing source…";
        self.owner.display.flush();
        self.owner.changed(self.owner.context);
    }
    fn listEvent(_: *ext.ForeignToplevelListV1, event: ext.ForeignToplevelListV1.Event, self: *Copy) void {
        switch (event) {
            .toplevel => |t| {
                if (self.windows.items.len >= 256) {
                    t.toplevel.destroy();
                    return;
                }
                const window = a.create(Window) catch {
                    t.toplevel.destroy();
                    return;
                };
                window.* = .{ .owner = self, .proxy = t.toplevel };
                self.windows.append(a, window) catch {
                    t.toplevel.destroy();
                    a.destroy(window);
                    return;
                };
                window.proxy.setListener(*Window, windowEvent, window);
            },
            .finished => {
                self.owner.cancel();
                if (self.list) |list| list.destroy();
                self.list = null;
            },
        }
        self.owner.changed(self.owner.context);
    }
    fn windowEvent(_: *ext.ForeignToplevelHandleV1, event: ext.ForeignToplevelHandleV1.Event, window: *Window) void {
        const self = window.owner;
        switch (event) {
            .identifier => |v| {
                const id = std.mem.span(v.identifier);
                if (id.len == 0 or id.len > 128) {
                    window.id.set("");
                } else window.id.set(id);
            },
            .title => |v| window.title.set(std.mem.span(v.title)),
            .app_id => |v| window.app_id.set(std.mem.span(v.app_id)),
            .done => window.done = true,
            .closed => {
                if (self.target == window) self.owner.fail("Window closed during capture");
                for (self.windows.items, 0..) |v, i| if (v == window) {
                    _ = self.windows.orderedRemove(i);
                    break;
                };
                window.proxy.destroy();
                a.destroy(window);
            },
        }
        self.owner.changed(self.owner.context);
    }
    fn sessionEvent(_: *ext.ImageCopyCaptureSessionV1, event: ext.ImageCopyCaptureSessionV1.Event, self: *Copy) void {
        switch (event) {
            .buffer_size => |v| {
                if (self.frame != null) {
                    self.owner.fail("Capture dimensions changed");
                    return;
                }
                self.owner.width = v.width;
                self.owner.height = v.height;
            },
            .shm_format => |v| {
                const f: u32 = @intCast(@intFromEnum(v.format));
                if (f == 0 or f == 1 or f == 0x34324241 or f == 0x34324258) self.owner.format = f;
            },
            .done => self.allocate() catch self.owner.fail("Unsupported or oversized source buffer"),
            .stopped => self.owner.fail("Capture source is unavailable, unmapped or protected"),
            else => {},
        }
    }
    fn allocate(self: *Copy) !void {
        if (self.frame != null) return error.ConstraintsChanged;
        if (self.owner.width > 8192) return error.InvalidBuffer;
        self.owner.stride = self.owner.width * 4;
        self.frame = try self.session.?.createFrame();
        self.frame.?.setListener(*Copy, frameEvent, self);
        self.color = try self.colors.?.getFrameInfo(self.frame.?);
        self.color.?.setListener(*Copy, colorEvent, self);
        try self.owner.allocate();
    }
    fn colorEvent(_: *aq.CaptureColorInfoV1, event: aq.CaptureColorInfoV1.Event, self: *Copy) void {
        switch (event) {
            .encoding => |v| {
                self.primaries = @intCast(@intFromEnum(v.primaries));
                self.transfer = @intCast(@intFromEnum(v.transfer_function));
            },
            .done => self.described = true,
            .unavailable => self.described = false,
            else => {},
        }
    }
    fn frameEvent(_: *ext.ImageCopyCaptureFrameV1, event: ext.ImageCopyCaptureFrameV1.Event, self: *Copy) void {
        switch (event) {
            .transform => |v| self.transform = @intCast(@intFromEnum(v.transform)),
            .ready => {
                if (!self.described) {
                    self.owner.fail("Source color metadata unavailable; PNG export withheld");
                    return;
                }
                if (self.primaries != 1 or (self.transfer != 1 and self.transfer != 2)) {
                    self.owner.fail("HDR or unsupported color encoding; SDR PNG export withheld");
                    return;
                }
                self.owner.convert() catch self.owner.fail("Source image conversion failed");
            },
            .failed => self.owner.fail("Source capture failed or was denied"),
            else => {},
        }
    }
};
