//! Periodic Open-Meteo fetch on a cancellable worker; bars read the snapshot
//! synchronously. HTTPS-only transport is inherited from the theme repository
//! downloader, which also bounds the response size.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const repository = @import("../theme/repository.zig");
pub const policy = @import("../desktop/weather_policy.zig");
const a = std.heap.c_allocator;
const refresh_ms: u32 = 30 * 60 * 1000;
const max_response = 65536;

const Job = struct { service: *Service, url: [:0]const u8, epoch: u64, cancel: *gio.Cancellable };
pub const Snapshot = policy.Forecast;

pub const Service = struct {
    app: *gio.Application = undefined,
    context: *anyopaque = undefined,
    changed: *const fn (*anyopaque) void = undefined,
    config: policy.Config = .{},
    /// Owned copy of the configured location name; preference arenas rotate.
    location: ?[]u8 = null,
    snapshot: ?Snapshot = null,
    failed: bool = false,
    running: bool = false,
    job: ?*Job = null,
    timer: c_uint = 0,
    epoch: u64 = 0,
    pub fn start(self: *Service) void {
        self.running = true;
        self.refresh();
    }
    pub fn stop(self: *Service) void {
        self.running = false;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.job) |job| job.cancel.cancel();
    }
    pub fn configure(self: *Service, config: policy.Config) void {
        if (policy.Config.eql(self.config, config)) return;
        const owned = a.dupe(u8, config.location) catch return;
        if (self.location) |old| a.free(old);
        self.location = owned;
        self.config = config;
        self.config.location = owned;
        // A new location must never present the previous place's numbers.
        self.epoch += 1;
        self.snapshot = null;
        self.failed = false;
        self.refresh();
    }
    fn refresh(self: *Service) void {
        if (!self.running or self.job != null) return;
        const url = policy.forecastUrl(a, self.config) catch return;
        const job = a.create(Job) catch {
            a.free(url);
            return;
        };
        job.* = .{ .service = self, .url = url, .epoch = self.epoch, .cancel = gio.Cancellable.new() };
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
        const bytes = repository.download(a, job.url, max_response, job.cancel, null) catch {
            task.returnPointer(null, null);
            return;
        };
        defer a.free(bytes);
        const current = policy.parseForecast(a, bytes) orelse {
            task.returnPointer(null, null);
            return;
        };
        const snapshot = a.create(Snapshot) catch {
            task.returnPointer(null, null);
            return;
        };
        snapshot.* = current;
        task.returnPointer(snapshot, null);
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const self = job.service;
        defer self.app.release();
        const task = object.ext.cast(gio.Task, result).?;
        const raw = task.propagatePointer(null);
        const snapshot: ?*Snapshot = if (raw) |p| @ptrCast(@alignCast(p)) else null;
        const current = job.epoch == self.epoch;
        a.free(job.url);
        job.cancel.unref();
        a.destroy(job);
        self.job = null;
        // Cancellation still completes asynchronously after the UI is torn down.
        // Drain ownership and the application hold without notifying its owner.
        if (!self.running) {
            if (snapshot) |s| a.destroy(s);
            return;
        }
        if (!current) {
            if (snapshot) |s| a.destroy(s);
            // The configuration moved on mid-flight; fetch for the new one.
            self.refresh();
        } else if (snapshot) |s| {
            self.snapshot = s.*;
            self.failed = false;
            a.destroy(s);
            self.changed(self.context);
        } else {
            self.failed = true;
            self.changed(self.context);
        }
        if (self.running and self.timer == 0) self.timer = glib.timeoutAdd(refresh_ms, scheduled, self);
    }
    fn scheduled(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.refresh();
        return 0;
    }
};

/// Synchronous geocoding for the settings editor; callers must run it on a
/// worker thread and free the returned places with the same allocator.
pub fn search(alloc: std.mem.Allocator, query: []const u8, cancel: *gio.Cancellable) ![]policy.Place {
    const url = try policy.searchUrl(alloc, query);
    defer alloc.free(url);
    const bytes = try repository.download(alloc, url, max_response, cancel, null);
    defer alloc.free(bytes);
    return policy.parsePlaces(alloc, bytes, 8);
}
