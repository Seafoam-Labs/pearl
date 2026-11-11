//! GTK ownership and explicit confirmation for worker-only workspace mutations.
//! Integration: App owns this at workspace_operations and guards close/modal
//! actions with busy(). shutdown cancels asynchronously; deinit follows hold drain.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const model = @import("model.zig");
const identity = @import("identity.zig");
pub const fs = @import("operations_fs.zig");
const hooks = @import("build_options").test_hooks;

pub const State = enum { idle, input, preparing, confirming, applying, retiring, succeeded, cancelled, failed };
const Phase = enum { prepare, apply, retire };

/// Production callers submit root-relative paths, not Explorer selection state.
/// Preparation is read-only; the native confirmation is always required. The
/// owner must survive until complete, including cancellation/descriptor retirement.
pub const Submission = struct {
    root: model.RootId,
    kind: fs.Kind,
    source: []const u8 = "",
    destination: []const u8 = "",
    review: []const u8,
    context: *anyopaque,
    authorize: *const fn (*anyopaque) anyerror!void,
    complete: *const fn (*anyopaque, Result) void,
};
pub const Result = struct { applied: bool, reason: ?[]const u8 };
const Owner = struct {
    context: *anyopaque,
    authorize: *const fn (*anyopaque) anyerror!void,
    complete: *const fn (*anyopaque, Result) void,
    review: [:0]u8,
};

pub const Controller = struct {
    app: *App,
    dialog: ?u.W = null,
    entry: ?u.W = null,
    job: ?*Job = null,
    state: State = .idle,
    closed: bool = false,
    error_name: ?[]const u8 = null,
    test_next_delay_us: u64 = 0,
    jobs_started: u64 = 0,
    jobs_reaped: u64 = 0,
    completed: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{ .app = app };
    }

    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.dialog != null;
    }

    /// Nonblocking: an active GTask retains the App until its completion and any
    /// descriptor-retirement turn have drained. Never spin a nested GTK loop.
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        self.cancel();
    }

    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(!self.busy());
        std.debug.assert(self.jobs_started == self.jobs_reaped);
    }

    pub fn request(self: *Controller, kind: fs.Kind) void {
        self.requestSelection(kind) catch |err| self.report(err);
    }

    fn available(self: *Controller) !void {
        if (self.closed or self.app.closing or self.app.quitting) return error.Closing;
        if (self.busy()) return error.OperationPending;
        if (self.app.openDialogs()) return error.DialogPending;
        if (self.app.browser.closed or self.app.browser.loading or self.app.browser.choosing) return error.WorkspaceBusy;
        const manager = self.app.manager orelse return error.NoManager;
        if (manager.quitting) return error.Closing;
        try manager.checkFileOperation(self.app, "", "");
    }

    fn requestSelection(self: *Controller, kind: fs.Kind) !void {
        try self.available();
        const browser = &self.app.browser;
        const snapshot = if (browser.model) |*value| value else return error.NoWorkspace;
        const index = c.gtk_single_selection_get_selected(browser.view.selection);
        if (index >= browser.tree.rows.items.len) return error.NoSelection;
        const row = browser.tree.rows.items[index];
        if (row.more or row.node >= browser.tree.nodes.items.len) return error.NoSelection;
        const node = browser.tree.nodes.items[row.node];
        const root = snapshot.rootById(node.root) orelse return error.WorkspaceChanged;
        var selected: []const u8 = node.relative;
        var owned: ?[:0]u8 = null;
        defer if (owned) |path| a.free(path);
        var directory = true;
        if (row.entry) |entry_index| {
            // A watch can retire the page before the next batched row render.
            const page = node.page orelse return error.SelectionChanged;
            if (entry_index >= page.entries.len) return error.SelectionChanged;
            const entry = page.entries[entry_index];
            if (entry.kind == .blocked) return error.UnavailableOrSymlink;
            owned = join(node.relative, entry.name);
            selected = owned.?;
            directory = entry.kind == .directory;
        }
        try self.begin(kind, root, selected, directory);
        self.showInput();
    }

    /// Test submissions use root-relative source/destination, except rename's
    /// destination is a sibling filename, just like the real entry. Creates use
    /// an empty source. This never bypasses prepare or explicit confirmation.
    pub fn testRequest(self: *Controller, kind: fs.Kind, root_index: usize, source: []const u8, destination: []const u8) void {
        if (!hooks) return;
        self.testSubmit(kind, root_index, source, destination) catch |err| self.report(err);
    }

    fn testSubmit(self: *Controller, kind: fs.Kind, root_index: usize, source: []const u8, destination: []const u8) !void {
        try self.available();
        const snapshot = if (self.app.browser.model) |*value| value else return error.NoWorkspace;
        if (root_index >= snapshot.roots.len) return error.InvalidRoot;
        if (isCreate(kind) and source.len != 0) return error.InvalidRequest;
        try self.begin(kind, &snapshot.roots[root_index], source, true);
        self.submit(destination) catch |err| self.abort(err);
    }

    /// Once accepted, complete runs exactly once, possibly synchronously on a
    /// submission error. Rename submissions use a full root-relative destination.
    pub fn submitReviewed(self: *Controller, submission: Submission) !void {
        try self.available();
        try submission.authorize(submission.context);
        if (submission.review.len > 64 * 1024) return error.ReviewTooLarge;
        if (isCreate(submission.kind) and submission.source.len != 0) return error.InvalidRequest;
        const snapshot = if (self.app.browser.model) |*value| value else return error.NoWorkspace;
        const root = snapshot.rootById(submission.root) orelse return error.InvalidRoot;
        try self.begin(if (submission.kind == .rename) .move else submission.kind, root, submission.source, true);
        self.job.?.owner = .{ .context = submission.context, .authorize = submission.authorize, .complete = submission.complete, .review = u.z(submission.review) };
        self.submit(submission.destination) catch |err| self.abort(err);
    }

    /// Only the submitting owner may cancel this job; it cannot cancel Explorer
    /// work or another integration's operation. Completion still follows reap.
    pub fn cancelSubmitted(self: *Controller, context: *anyopaque) void {
        const job = self.job orelse return;
        const owner = job.owner orelse return;
        if (owner.context == context) self.cancel();
    }

    fn begin(self: *Controller, kind: fs.Kind, root: *const model.Root, selected: []const u8, directory: bool) !void {
        if (root.availability != .available) return error.UnavailableRoot;
        const canonical = root.canonical_path orelse return error.UnavailableRoot;
        if (!isCreate(kind) and selected.len == 0) return error.RootMutation;
        if (canonical.len > fs.path_limit or selected.len > fs.path_limit) return error.PathTooLong;
        const snapshot = &self.app.browser.model.?;
        const token = snapshot.scope.capture() orelse return error.WorkspaceChanged;
        const request_token = self.app.browser.requests.capture() orelse return error.WorkspaceChanged;
        const job = try a.create(Job);
        job.* = .{
            .controller = self,
            .kind = kind,
            .root = u.z(canonical),
            .root_name = u.z(root.display_name),
            .root_id = root.id,
            .selected = u.z(selected),
            .source = u.z(if (isCreate(kind)) "" else selected),
            .base = u.z(if (isCreate(kind) and directory) selected else parentPath(selected)),
            .destination = u.z(""),
            .source_abs = u.z(""),
            .destination_abs = u.z(""),
            .token = token,
            .request_token = request_token,
            .cancel = c.g_cancellable_new().?,
        };
        self.job = job;
        self.state = .input;
        self.error_name = null;
        self.app.hold();
    }

    fn fresh(self: *const Controller, job: *const Job) bool {
        if (self.closed or self.app.closing or self.app.quitting or self.app.browser.closed or self.app.browser.loading or self.app.browser.choosing) return false;
        const snapshot = if (self.app.browser.model) |*value| value else return false;
        if (!snapshot.scope.accepts(job.token) or !self.app.browser.requests.accepts(job.request_token)) return false;
        const root = snapshot.rootById(job.root_id) orelse return false;
        return root.availability == .available and if (root.canonical_path) |path| std.mem.eql(u8, path, job.root) else false;
    }

    fn check(self: *Controller, job: *const Job) !void {
        if (!self.fresh(job)) return error.WorkspaceChanged;
        const manager = self.app.manager orelse return error.NoManager;
        try manager.checkFileOperation(self.app, job.source_abs, job.destination_abs);
        if (job.owner) |owner| try owner.authorize(owner.context);
    }

    fn submit(self: *Controller, destination: []const u8) !void {
        const job = self.job.?;
        if (!self.fresh(job)) return error.WorkspaceChanged;
        if (destination.len > fs.path_limit) return error.PathTooLong;
        if (job.kind == .rename) try siblingName(destination);
        if (job.kind == .delete and destination.len != 0) return error.InvalidRequest;
        // Concatenate, never normalize. The backend must see every traversal,
        // empty component and absolute-path attempt exactly as the user typed it.
        const relative = if (job.kind == .rename or isCreate(job.kind)) blk: {
            if (destination.len == 0 or destination[0] == '/') return error.InvalidDestination;
            break :blk join(job.base, destination);
        } else u.z(destination);
        a.free(job.destination);
        job.destination = relative;
        a.free(job.source_abs);
        job.source_abs = absolute(job.root, job.source);
        a.free(job.destination_abs);
        job.destination_abs = absolute(job.root, job.destination);
        try self.check(job);
        self.closeDialog();
        self.state = .preparing;
        self.dispatch(.prepare);
    }

    /// Only a prepared review can authorize apply. In particular this hook cannot
    /// turn the first input dialog's default response into an implicit write.
    pub fn respond(self: *Controller, accept: bool) void {
        if (self.state != .confirming or self.job == null) return;
        if (!accept) {
            self.cancel();
            return;
        }
        const job = self.job.?;
        self.check(job) catch |err| {
            self.abort(err);
            return;
        };
        const manager = self.app.manager.?;
        manager.beginFileOperation(self.app, job.source_abs, job.destination_abs) catch |err| {
            self.abort(err);
            return;
        };
        job.barrier = true;
        self.closeDialog();
        self.state = .applying;
        self.dispatch(.apply);
    }

    fn makeDialog(self: *Controller, heading: [*:0]const u8, accept: [*:0]const u8) u.W {
        const dialog = c.gtk_dialog_new().?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), heading);
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 560, -1);
        const box = c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?;
        u.margin(u.cast(c.GtkWidget, box), 18);
        c.gtk_box_set_spacing(u.cast(c.GtkBox, box), 10);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Cancel", c.GTK_RESPONSE_CANCEL);
        const button = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), accept, c.GTK_RESPONSE_ACCEPT).?;
        if (self.job.?.kind == .delete and self.state == .confirming) c.gtk_widget_add_css_class(button, "destructive-action");
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        self.dialog = dialog;
        u.connect(dialog, "response", &response, self);
        u.connect(dialog, "destroy", &destroyed, self);
        return u.cast(c.GtkWidget, box);
    }

    fn describe(self: *Controller, box: u.W, text: []const u8) void {
        _ = self;
        const label = u.label(text);
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_wrap_mode(u.cast(c.GtkLabel, label), c.PANGO_WRAP_WORD_CHAR);
        c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
        u.append(box, label);
    }

    fn showInput(self: *Controller) void {
        const job = self.job.?;
        const box = self.makeDialog(title(job.kind), "_Review…");
        const detail = u.fmt("Root: {s}\n{s}\nSelected: {s}", .{ job.root_name, job.root, if (job.selected.len == 0) "(workspace root)" else job.selected });
        defer a.free(detail);
        self.describe(box, detail);
        self.describe(box, switch (job.kind) {
            .create_file, .create_directory => "Enter a name or relative path within the selected directory (a selected file uses its parent). Nothing is created until you confirm the review.",
            .rename => "Enter a sibling filename, not a path. The existing destination will never be replaced.",
            .move => "Enter a destination relative to this workspace root. The parent directory must already exist; existing destinations are never replaced.",
            .delete => delete_warning,
        });
        if (job.kind != .delete) {
            const entry = c.gtk_entry_new().?;
            c.gtk_entry_set_max_length(u.cast(c.GtkEntry, entry), fs.path_limit);
            if (job.kind == .rename) {
                const name = u.z(basename(job.source));
                defer a.free(name);
                c.gtk_editable_set_text(u.cast(c.GtkEditable, entry), name);
            }
            self.entry = entry;
            u.append(box, entry);
            _ = c.gtk_widget_grab_focus(entry);
        }
        c.gtk_window_present(u.cast(c.GtkWindow, self.dialog.?));
    }

    fn showConfirmation(self: *Controller) void {
        const job = self.job.?;
        self.state = .confirming;
        const box = self.makeDialog("Confirm workspace file operation", if (job.kind == .delete) "_Delete permanently" else "_Confirm");
        const detail = u.fmt("{s}\nRoot: {s}\n{s}\nSource: {s}\nDestination: {s}", .{
            title(job.kind),                                        job.root_name,                                               job.root,
            if (job.source.len == 0) "(new entry)" else job.source, if (job.destination.len == 0) "(none)" else job.destination,
        });
        defer a.free(detail);
        self.describe(box, detail);
        if (job.owner) |owner| {
            const scroll = c.gtk_scrolled_window_new().?;
            c.gtk_scrolled_window_set_min_content_height(u.cast(c.GtkScrolledWindow, scroll), 140);
            c.gtk_scrolled_window_set_max_content_height(u.cast(c.GtkScrolledWindow, scroll), 280);
            c.gtk_scrolled_window_set_propagate_natural_height(u.cast(c.GtkScrolledWindow, scroll), 1);
            const details = u.box(false, 8);
            c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), details);
            self.describe(details, owner.review);
            u.append(box, scroll);
        }
        self.describe(box, if (job.kind == .delete) delete_warning else "Confirm this exact operation? Existing destinations are never replaced. There is no undo. Changed paths or workspace state require a new request.");
        c.gtk_window_present(u.cast(c.GtkWindow, self.dialog.?));
    }

    fn closeDialog(self: *Controller) void {
        const dialog = self.dialog orelse return;
        self.dialog = null;
        self.entry = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_insert_action_group(dialog, "win", null);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    }

    fn cancel(self: *Controller) void {
        self.closeDialog();
        const job = self.job orelse return;
        c.g_cancellable_cancel(job.cancel);
        job.outcome = .cancelled;
        if (job.running) return;
        self.retire();
    }

    fn abort(self: *Controller, err: anyerror) void {
        self.report(err);
        self.closeDialog();
        const job = self.job orelse return;
        job.outcome = .failed;
        job.failure_reason = @errorName(err);
        c.g_cancellable_cancel(job.cancel);
        if (!job.running) self.retire();
    }

    fn retire(self: *Controller) void {
        const job = self.job.?;
        std.debug.assert(!job.running);
        if (job.prepared != null) {
            self.state = .retiring;
            self.dispatch(.retire);
        } else self.finish();
    }

    fn releaseBarrier(self: *Controller) void {
        const job = self.job.?;
        if (!job.barrier) return;
        self.app.manager.?.endFileOperation(self.app);
        job.barrier = false;
    }

    fn finish(self: *Controller) void {
        const job = self.job.?;
        std.debug.assert(!job.running and job.prepared == null);
        self.releaseBarrier();
        self.closeDialog();
        self.state = job.outcome;
        self.job = null;
        if (job.owner) |owner| owner.complete(owner.context, .{ .applied = job.outcome == .succeeded, .reason = job.failure_reason orelse if (job.outcome == .cancelled) @as(?[]const u8, "Cancelled") else null });
        job.destroy();
        self.app.release();
    }

    fn dispatch(self: *Controller, phase: Phase) void {
        const job = self.job.?;
        std.debug.assert(!job.running);
        job.phase = phase;
        job.running = true;
        job.err = null;
        job.delay_us = if (hooks and phase != .retire) @min(self.test_next_delay_us, 2_000_000) else 0;
        if (phase != .retire) self.test_next_delay_us = 0;
        self.jobs_started += 1;
        // Cancellation must never deliver early or skip descriptor retirement.
        // The backend observes it before mutation and preserves committed success.
        const task = c.g_task_new(null, null, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }

    fn report(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        if (!self.busy()) self.state = .failed;
        if (self.closed or self.app.closing) return;
        const hint = switch (err) {
            error.NoWorkspace, error.NoSelection => "Select an entry in an open workspace's explorer first.",
            error.SelectionChanged, error.WorkspaceChanged, error.StaleSnapshot => "The selection, workspace or on-disk paths changed. Select the entry again and start a new request.",
            error.RootMutation => "Workspace roots cannot be renamed, moved or deleted. Select a child entry.",
            error.UnavailableRoot, error.UnavailableOrSymlink, error.Symlink, error.SpecialFile => "Only available roots and regular files/directories without symlink components can be edited.",
            error.InvalidRename => "Rename requires one sibling filename, not an absolute or relative path.",
            error.InvalidPath, error.InvalidDestination, error.InvalidRequest, error.GitPath => "Use a nonempty root-relative path without '.', '..', empty components or '.git'. Destinations must not be inside the source.",
            error.PathTooLong => "The path exceeds the filesystem operation's 4095-byte limit.",
            error.AlreadyExists => "The destination already exists. Choose another name; nothing will be overwritten.",
            error.DirectoryNotEmpty => "Only empty directories can be permanently deleted. Recursive deletion is not supported.",
            error.NotFound, error.NotDirectory => "The source and destination parent must exist. Refresh the explorer and try again.",
            error.CrossDevice => "Moving across filesystems is not supported; no copy/delete fallback was attempted.",
            error.PermissionDenied, error.ReadOnlyFilesystem => "The filesystem does not permit this operation.",
            error.OperationPending, error.DialogPending, error.WorkspaceBusy => "Finish or cancel the current dialog or operation, then try again.",
            error.Cancelled => "The file operation was cancelled.",
            else => "Close affected documents in every window and wait for pending loads, saves and sessions. Workspace roots/manifests are protected. Then retry the operation.",
        };
        const text = u.fmt("Workspace file operation: {s}. {s}", .{ @errorName(err), hint });
        defer a.free(text);
        self.app.message(text);
    }

    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const job = self.job;
        // Do not inspect worker-owned prepared/err while a GTask is running.
        const text = std.json.Stringify.valueAlloc(a, .{
            .state = self.state,
            .busy = self.busy(),
            .dialog = self.dialog != null,
            .confirmation = self.state == .confirming,
            .submitted = if (job) |j| j.owner != null else false,
            .review = if (job) |j| if (j.owner) |owner| @as(?[]const u8, owner.review) else null else null,
            .closed = self.closed,
            .kind = if (job) |j| j.kind else @as(?fs.Kind, null),
            .root = if (job) |j| j.root else @as(?[]const u8, null),
            .source = if (job) |j| j.source else @as(?[]const u8, null),
            .destination = if (job) |j| j.destination else @as(?[]const u8, null),
            .workspace = if (job) |j| @backingInt(j.token.workspace) else @as(?u64, null),
            .generation = if (job) |j| j.token.generation else @as(?u64, null),
            .barrier = if (job) |j| j.barrier else false,
            .err = self.error_name,
            .jobs_started = self.jobs_started,
            .jobs_reaped = self.jobs_reaped,
            .completed = self.completed,
        }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_OPERATIONS %s\n", z.ptr);
    }
};

const delete_warning = "Permanent deletion: regular files and empty directories only. No recursive deletion, no trash and no undo.";

const Job = struct {
    controller: *Controller,
    kind: fs.Kind,
    root: [:0]u8,
    root_name: [:0]u8,
    root_id: model.RootId,
    selected: [:0]u8,
    source: [:0]u8,
    base: [:0]u8,
    destination: [:0]u8,
    source_abs: [:0]u8,
    destination_abs: [:0]u8,
    token: identity.Token,
    request_token: identity.Token,
    cancel: *c.GCancellable,
    // Only the worker touches prepared/err until its completion is delivered.
    prepared: ?fs.Prepared = null,
    err: ?anyerror = null,
    phase: Phase = .prepare,
    delay_us: u64 = 0,
    running: bool = false,
    barrier: bool = false,
    outcome: State = .cancelled,
    owner: ?Owner = null,
    failure_reason: ?[]const u8 = null,
    directory: bool = false,

    fn destroy(self: *Job) void {
        std.debug.assert(self.prepared == null and !self.running and !self.barrier);
        inline for (.{ "root", "root_name", "selected", "source", "base", "destination", "source_abs", "destination_abs" }) |field| a.free(@field(self, field));
        if (self.owner) |owner| a.free(owner.review);
        c.g_object_unref(self.cancel);
        a.destroy(self);
    }

    fn perform(self: *Job) !void {
        var remaining = self.delay_us;
        while (remaining != 0 and c.g_cancellable_is_cancelled(self.cancel) == 0) {
            const slice = @min(remaining, 10_000);
            c.g_usleep(@intCast(slice));
            remaining -= slice;
        }
        switch (self.phase) {
            .prepare => {
                self.prepared = try fs.prepare(a, .{ .kind = self.kind, .root = self.root, .source = self.source, .destination = self.destination }, self.cancel);
                self.directory = if (self.prepared.?.source_stat) |stat| stat.mode & std.c.S.IFMT == std.c.S.IFDIR else self.kind == .create_directory;
            },
            .apply => {
                defer self.clearPrepared();
                try fs.apply(&self.prepared.?, self.cancel);
            },
            .retire => self.clearPrepared(),
        }
    }

    fn clearPrepared(self: *Job) void {
        if (self.prepared) |*prepared| prepared.deinit();
        self.prepared = null;
    }
};

fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    job.perform() catch |err| {
        job.err = err;
    };
    c.g_task_return_boolean(task, 1);
}

fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, data.?);
    const self = job.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.job == job and job.running);
    job.running = false;
    self.jobs_reaped += 1;
    if (job.phase == .retire) {
        self.finish();
        return;
    }
    if (job.phase == .apply) {
        self.releaseBarrier();
        // A successful syscall stays successful even if shutdown/cancellation
        // raced its completion. Never report a committed mutation as cancelled.
        if (job.err == null) {
            job.outcome = .succeeded;
            self.completed += 1;
            if (self.app.manager) |manager| for (manager.entries) |entry| if (entry) |window| {
                window.app.language.fileOperationCompleted(job.kind, job.source_abs, job.destination_abs, job.directory);
            };
            if (!self.closed and !self.app.closing) {
                self.app.workspace_search.invalidate("Stale — workspace files changed. Refresh to search again.");
                // Refresh accessed directory pages without replacing the workspace
                // owner (which would kill language sessions before did* delivery).
                // The unchanged watcher still performs root/policy verification.
                if (self.fresh(job)) {
                    const browser = &self.app.browser;
                    const now = c.g_get_monotonic_time();
                    for (browser.tree.nodes.items) |*node| {
                        node.invalidate();
                        node.first_event = now;
                        node.last_event = now;
                    }
                    for (browser.jobs.items) |scan| if (scan.kind == .scan) c.g_cancellable_cancel(scan.cancel);
                    browser.render_pending = true;
                }
                self.app.message("Workspace file operation completed. There is no undo.");
            }
            self.finish();
            return;
        }
    }
    if (self.closed or self.app.closing or c.g_cancellable_is_cancelled(job.cancel) != 0) {
        job.outcome = .cancelled;
        self.retire();
        return;
    }
    if (job.err) |err| {
        self.abort(err);
        return;
    }
    self.check(job) catch |err| {
        self.abort(err);
        return;
    };
    self.showConfirmation();
}

fn response(dialog: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.dialog != u.cast(c.GtkWidget, dialog.?)) return;
    if (self.state == .confirming) {
        self.respond(id == c.GTK_RESPONSE_ACCEPT);
    } else if (self.state == .input) {
        if (id != c.GTK_RESPONSE_ACCEPT) {
            self.cancel();
            return;
        }
        self.submit(if (self.entry) |entry| u.entryText(entry) else "") catch |err| self.abort(err);
    }
}

fn destroyed(widget: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.dialog != widget) return;
    self.dialog = null;
    self.entry = null;
    self.cancel();
}

fn isCreate(kind: fs.Kind) bool {
    return kind == .create_file or kind == .create_directory;
}

fn title(kind: fs.Kind) [:0]const u8 {
    return switch (kind) {
        .create_file => "Create file",
        .create_directory => "Create directory",
        .rename => "Rename entry",
        .move => "Move entry",
        .delete => "Delete entry permanently",
    };
}

fn parentPath(path: []const u8) []const u8 {
    return path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
}

fn basename(path: []const u8) []const u8 {
    return path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| at + 1 else 0..];
}

fn siblingName(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidRename;
}

fn join(parent: []const u8, child: []const u8) [:0]u8 {
    return if (parent.len == 0) u.z(child) else u.fmt("{s}/{s}", .{ parent, child });
}

fn absolute(root: []const u8, relative: []const u8) [:0]u8 {
    if (relative.len == 0) return u.z("");
    return if (std.mem.eql(u8, root, "/")) u.fmt("/{s}", .{relative}) else u.fmt("{s}/{s}", .{ root, relative });
}
