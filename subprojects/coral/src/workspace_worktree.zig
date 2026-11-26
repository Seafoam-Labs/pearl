//! Build a private Git index on a worker. The user's index, branch and working files remain independent.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
pub const Snapshot = struct {
    base: [:0]u8,
    directory: [:0]u8,
    pub fn deinit(self: Snapshot) void {
        a.free(self.base);
        a.free(self.directory);
    }
};
pub const Ready = *const fn (*anyopaque, u64, anyerror!?Snapshot) void;
const Job = struct { root: [:0]u8, ctx: *anyopaque, epoch: u64, done: Ready, result: anyerror!?Snapshot = null };

pub fn prepare(root: [:0]const u8, cancel: *c.GCancellable, ctx: *anyopaque, epoch: u64, done: Ready) void {
    const job = a.create(Job) catch unreachable;
    job.* = .{ .root = u.z(root), .ctx = ctx, .epoch = epoch, .done = done };
    const task = c.g_task_new(null, cancel, &completed, job).?;
    c.g_task_set_task_data(task, job, null);
    c.g_task_run_in_thread(task, &worker);
    c.g_object_unref(task);
}
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, cancel: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    job.result = snapshot(job.root, cancel.?);
    c.g_task_return_boolean(task, 1);
}
fn completed(_: ?*c.GObject, res: ?*c.GAsyncResult, ctx: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, ctx.?);
    defer a.destroy(job);
    defer a.free(job.root);
    defer if (job.result) |value| {
        if (value) |s| s.deinit();
    } else |_| {};
    const task = u.cast(c.GTask, res.?);
    if (c.g_cancellable_is_cancelled(c.g_task_get_cancellable(task)) == 0) job.done(job.ctx, job.epoch, job.result);
}
pub fn git(root: [:0]const u8, index: ?[:0]const u8, args: []const [*:0]const u8, cancel: ?*c.GCancellable) ![:0]u8 {
    const bytes = try gitRaw(root, index, args, cancel, false);
    defer a.free(bytes);
    return u.z(std.mem.trimEnd(u8, bytes, "\r\n"));
}
pub fn gitRaw(root: [:0]const u8, index: ?[:0]const u8, args: []const [*:0]const u8, cancel: ?*c.GCancellable, accept_conflict: bool) ![:0]u8 {
    const launcher = c.g_subprocess_launcher_new(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE).?;
    defer c.g_object_unref(launcher);
    c.g_subprocess_launcher_set_cwd(launcher, root);
    for ([_][*:0]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR" }) |key| c.g_subprocess_launcher_unsetenv(launcher, key);
    if (index) |path| c.g_subprocess_launcher_setenv(launcher, "GIT_INDEX_FILE", path, 1);
    c.g_subprocess_launcher_setenv(launcher, "GIT_TERMINAL_PROMPT", "0", 1);
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Coral Workspace", "-c", "user.email=workspace@localhost" });
    for (args) |arg| try argv.append(a, arg);
    try argv.append(a, null);
    const child = c.g_subprocess_launcher_spawnv(launcher, @ptrCast(argv.items.ptr), null) orelse return error.GitUnavailable;
    defer c.g_object_unref(child);
    var stdout: [*c]u8 = null;
    defer if (stdout != null) c.g_free(stdout);
    if (c.g_subprocess_communicate_utf8(child, null, cancel, &stdout, null, null) == 0) {
        c.g_subprocess_force_exit(child);
        return error.GitInterrupted;
    }
    if (c.g_subprocess_get_successful(child) == 0 and !(accept_conflict and c.g_subprocess_get_if_exited(child) != 0 and c.g_subprocess_get_exit_status(child) > 0 and c.g_subprocess_get_exit_status(child) < 128)) return error.GitFailed;
    return u.z(if (stdout != null) std.mem.span(stdout) else "");
}
fn snapshot(root: [:0]const u8, cancel: *c.GCancellable) !?Snapshot {
    const top = git(root, null, &.{ "rev-parse", "--show-toplevel" }, cancel) catch |err| switch (err) {
        error.GitFailed => return null,
        else => return err,
    };
    defer a.free(top);
    const head = git(root, null, &.{ "rev-parse", "--verify", "HEAD" }, cancel) catch |err| switch (err) {
        error.GitFailed => return null, // A new repository can chat before its first commit.
        else => return err,
    };
    defer a.free(head);
    const parent = u.fmt("{s}/coral-workspace/worktrees", .{std.mem.span(c.g_get_user_state_dir())});
    defer a.free(parent);
    if (c.g_mkdir_with_parents(parent, 0o700) != 0) return error.StateDirectory;
    const tmp = u.fmt("{s}/session-XXXXXX", .{parent});
    defer a.free(tmp);
    if (c.g_mkdtemp(tmp) == null) return error.StateDirectory;
    errdefer _ = c.g_rmdir(tmp);
    const index = u.fmt("{s}/index", .{tmp});
    defer a.free(index);
    defer _ = c.g_remove(index);
    const dir = u.fmt("{s}/tree", .{tmp});
    defer a.free(dir);
    a.free(try git(top, index, &.{ "read-tree", head }, cancel));
    a.free(try git(root, index, &.{ "add", "-A", "--", "." }, cancel));
    const tree = try git(top, index, &.{"write-tree"}, cancel);
    defer a.free(tree);
    const base = try git(top, null, &.{ "commit-tree", tree, "-p", head, "-m", "Coral Workspace session base" }, cancel);
    errdefer a.free(base);
    a.free(try git(top, null, &.{ "worktree", "add", "--detach", dir, base }, cancel));
    const relative = try std.fs.path.relativeAllocPosix(a, "/", top, root);
    defer a.free(relative);
    return .{ .base = base, .directory = if (relative.len == 0 or std.mem.eql(u8, relative, ".")) u.z(dir) else u.fmt("{s}/{s}", .{ dir, relative }) };
}
