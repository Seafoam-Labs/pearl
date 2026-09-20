//! Cached launcher artwork shared by Settings and the bar. Only the worker reads
//! or decodes files; detached jobs cannot access destroyed/reconfigured owners.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const policy = @import("../../desktop/launcher_icon_policy.zig");
const assets = @import("../../theme/assets.zig");
const a = std.heap.c_allocator;
pub const Config = policy.Config;
const Job = struct { owner: ?*Renderer, path: [:0]u8, cancel: *gio.Cancellable };
const Target = struct { image: *gtk.Image, size: c_int };
pub const Renderer = struct {
    selection: Config = .{},
    owned: ?[:0]u8 = null,
    job: ?*Job = null,
    pixels: ?*pixbuf.Pixbuf = null,
    failed: bool = false,
    targets: std.ArrayList(Target) = .empty,
    status: ?*gtk.Label = null,
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,

    pub fn clearTargets(self: *Renderer) void {
        for (self.targets.items) |target| target.image.unref();
        self.targets.clearRetainingCapacity();
        if (self.status) |status_label| status_label.unref();
        self.status = null;
    }
    fn cancel(self: *Renderer) void {
        if (self.job) |job| {
            job.owner = null;
            job.cancel.cancel();
            self.job = null;
        }
    }
    pub fn deinit(self: *Renderer) void {
        self.cancel();
        self.clearTargets();
        self.targets.deinit(a);
        if (self.owned) |value| a.free(value);
        if (self.pixels) |pixels| pixels.unref();
        self.* = .{};
    }
    pub fn want(self: *Renderer, selection: Config, retry: bool) !void {
        try selection.validate();
        if (!retry and self.selection.eql(selection)) {
            self.refresh(); // Theme availability may have changed.
            return;
        }
        const owned = try a.dupeZ(u8, selection.value);
        self.cancel();
        if (self.owned) |value| a.free(value);
        if (self.pixels) |pixels| pixels.unref();
        self.pixels = null;
        self.owned = owned;
        self.selection = .{ .kind = selection.kind, .value = owned };
        self.failed = false;
        if (selection.kind == .file) {
            const job = try a.create(Job);
            errdefer a.destroy(job);
            job.* = .{ .owner = self, .path = try a.dupeZ(u8, owned), .cancel = gio.Cancellable.new() };
            self.job = job;
            const task = gio.Task.new(null, job.cancel, completed, job);
            task.setCheckCancellable(0);
            _ = task.setReturnOnCancel(0);
            task.setTaskData(job, null);
            task.runInThread(work);
            task.unref();
        }
        self.refresh();
    }
    pub fn image(self: *Renderer, size: c_int) !*gtk.Image {
        const result = gtk.Image.new();
        _ = result.as(object.Object).refSink();
        errdefer result.unref();
        try self.targets.append(a, .{ .image = result, .size = size });
        self.render(.{ .image = result, .size = size });
        return result;
    }
    pub fn label(self: *Renderer) *gtk.Label {
        if (self.status) |old| old.unref();
        const result = @import("widgets.zig").label("", "pearl-secondary");
        _ = result.as(object.Object).refSink();
        self.status = result;
        self.refresh();
        return result;
    }
    pub fn message(self: *Renderer) [:0]const u8 {
        if (self.job != null) return "Loading launcher icon…";
        if (self.failed) return "Icon unavailable. Using the default. Choose another icon or Retry.";
        return "";
    }
    fn render(self: *Renderer, target: Target) void {
        const image_ = target.image;
        image_.setPixelSize(target.size);
        if (self.pixels) |pixels| {
            // Supply a bounded pixbuf as well as a logical pixel size, so the
            // source's intrinsic dimensions cannot expand a narrow bar.
            const width = pixels.getWidth();
            const height = pixels.getHeight();
            const longest = @max(width, height);
            const scaled = pixels.scaleSimple(@max(1, @divTrunc(width * target.size, longest)), @max(1, @divTrunc(height * target.size, longest)), .bilinear);
            defer if (scaled) |value| value.unref();
            if (scaled) |value| image_.setFromPixbuf(value) else image_.setFromIconName(policy.default_icon);
        } else {
            var name: [:0]const u8 = policy.default_icon;
            if (self.selection.kind == .theme) {
                const theme = gtk.IconTheme.getForDisplay(image_.as(gtk.Widget).getDisplay());
                self.failed = theme.hasIcon(self.owned.?) == 0;
                if (!self.failed) name = self.owned.?;
            }
            image_.setFromIconName(name);
        }
    }
    fn refresh(self: *Renderer) void {
        for (self.targets.items) |target| self.render(target);
        if (self.status) |label_| label_.setText(self.message());
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        task.returnPointer(load(job) catch null, null);
    }
    fn load(job: *Job) !?*pixbuf.Pixbuf {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const input = try @import("../../config/io.zig").read(alloc, job.path, assets.max_image, job.cancel);
        const checked = try assets.validate(alloc, "launcher", input.bytes);
        if (job.cancel.isCancelled() != 0) return null;
        const bytes = glib.Bytes.new(checked.blob.bytes.ptr, checked.blob.bytes.len);
        defer bytes.unref();
        const stream = gio.MemoryInputStream.newFromBytes(bytes);
        defer stream.unref();
        var err: ?*glib.Error = null;
        const pixels = pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), 256, 256, 1, job.cancel, &err);
        if (err) |e| e.free();
        return pixels;
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        defer {
            job.cancel.unref();
            a.free(job.path);
            a.destroy(job);
        }
        const raw = object.ext.cast(gio.Task, result).?.propagatePointer(null);
        const pixels: ?*pixbuf.Pixbuf = if (raw) |value| @ptrCast(@alignCast(value)) else null;
        if (job.owner) |self| {
            self.job = null;
            self.pixels = pixels;
            self.failed = pixels == null;
            self.refresh();
            if (self.changed) |changed| changed(self.context.?);
        } else if (pixels) |value| value.unref();
    }
};
