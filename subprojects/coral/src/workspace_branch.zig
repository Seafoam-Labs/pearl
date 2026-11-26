//! Follow the actual worktree HEAD, including linked worktrees and detached HEAD.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const App = @import("app.zig").App;
const git = @import("workspace_worktree.zig").git;
const i18n = @import("i18n");

pub const Branch = struct {
    app: *App,
    label: u.W,
    cancel: ?*c.GCancellable = null,
    monitor: ?*c.GFileMonitor = null,
    root: ?[:0]u8 = null,
    reading: bool = false,
    dirty: bool = false,

    pub fn clear(self: *Branch) void {
        if (self.cancel) |cancel| {
            c.g_cancellable_cancel(cancel);
            c.g_object_unref(cancel);
        }
        if (self.monitor) |monitor| {
            _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            _ = c.g_file_monitor_cancel(monitor);
            c.g_object_unref(monitor);
        }
        if (self.root) |root| u.a.free(root);
        self.cancel = null;
        self.monitor = null;
        self.root = null;
        self.reading = false;
        self.dirty = false;
    }

    pub fn follow(self: *Branch, root: []const u8) void {
        self.clear();
        c.gtk_widget_set_visible(self.label, 0);
        if (root.len == 0) return;
        self.cancel = c.g_cancellable_new().?;
        self.root = u.z(root);
        self.start(true);
    }

    fn start(self: *Branch, discover: bool) void {
        if (self.reading) {
            self.dirty = true;
            return;
        }
        self.reading = true;
        const job = u.a.create(Job) catch unreachable;
        job.* = .{ .owner = self, .root = u.z(self.root.?), .discover = discover };
        const task = c.g_task_new(null, self.cancel, &ready, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
};

const Job = struct { owner: *Branch, root: [:0]u8, discover: bool, result: ?[:0]u8 = null, detached: bool = false };

fn changed(_: ?*c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c.GFileMonitorEvent, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Branch, data.?);
    if (!self.app.closing) self.start(false);
}

fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, cancel: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    if (job.discover) {
        job.result = git(job.root, null, &.{ "rev-parse", "--path-format=absolute", "--git-path", "HEAD" }, cancel) catch null;
    } else {
        job.result = git(job.root, null, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" }, cancel) catch blk: {
            job.detached = true;
            if (c.g_cancellable_is_cancelled(cancel) != 0) break :blk null;
            break :blk git(job.root, null, &.{ "rev-parse", "--short", "HEAD" }, cancel) catch null;
        };
    }
    c.g_task_return_boolean(task, 1);
}

fn ready(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, data.?);
    defer u.a.destroy(job);
    defer u.a.free(job.root);
    defer if (job.result) |value| u.a.free(value);
    const cancel = c.g_task_get_cancellable(u.cast(c.GTask, res.?));
    if (c.g_cancellable_is_cancelled(cancel) != 0) return;
    const self = job.owner;
    self.reading = false;
    if (self.app.closing) return;
    if (job.discover) {
        const path = job.result orelse return;
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        self.monitor = c.g_file_monitor_file(file, c.G_FILE_MONITOR_NONE, cancel, null);
        if (self.monitor) |monitor| u.connect(monitor, "changed", &changed, self);
        self.start(false);
        return;
    }
    if (job.result) |raw| {
        const name = @import("git/command.zig").display(u.a, raw, 512) catch return;
        defer u.a.free(name);
        var buf: [1024]u8 = undefined;
        const caption = if (job.detached) i18n.dfmt("coral", &buf, "Detached HEAD · {s}", .{name}) else i18n.dfmt("coral", &buf, "Branch · {s}", .{name});
        u.setLabel(self.label, if (job.detached) caption else name);
        c.gtk_widget_set_tooltip_text(self.label, caption.ptr);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, self.label), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), caption.ptr, @as(c_int, -1));
    }
    c.gtk_widget_set_visible(self.label, @intFromBool(job.result != null));
    if (self.dirty) {
        self.dirty = false;
        self.start(false);
    }
}
