//! App-owned M2 root/manifest management. Core integration contract:
//!   App.workspace_roots = Controller.init(app); request(.add/.remove/.save_as)
//!   busy(), shutdown(), deinit(); testRequest(kind, path), respond(bool), probe().
//!   Manager.checkManifestOperation(owner:*App)!void
//!   Manager.beginManifestOperation(owner:*App)!void / endManifestOperation(owner)
//! Those GTK-only methods share file_operation_owner, exclude the owner's roots
//! dialog, allow an active manifest target, and otherwise conservatively reject
//! pending loads/saves/sessions/dialogs across live AND draining owners. They must
//! not delegate to/relax generic checkFileOperation's protected-root checks.
//! Core guards openDialogs, workspace switches/mutations and document bindings
//! during apply. We copy all registry bound paths and check physical aliases on
//! workers; no synchronous filesystem work belongs in manager admission.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const chooser = @import("file_chooser");
const identity = @import("identity.zig");
const model = @import("model.zig");
pub const fs = @import("roots_fs.zig");
pub const Kind = fs.Kind;
const hooks = @import("build_options").test_hooks;
pub const State = enum { idle, choosing, preparing, confirming, applying, retiring, succeeded, cancelled, failed };
const Phase = enum { prepare, apply, retire };

pub const Controller = struct {
    app: *App,
    dialog: ?u.W = null,
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
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        self.cancel();
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(!self.busy() and self.jobs_started == self.jobs_reaped);
    }
    pub fn request(self: *Controller, kind: Kind) void {
        self.begin(kind) catch |err| {
            self.report(err);
            return;
        };
        if (kind == .remove) self.submit("") catch |err| self.abort(err) else self.showChooser();
    }
    /// Same selection, admission, worker preparation and explicit confirmation as
    /// the native commands. Remove ignores no path: it requires an empty argument.
    pub fn testRequest(self: *Controller, kind: Kind, path: []const u8) void {
        if (!hooks) return;
        self.begin(kind) catch |err| {
            self.report(err);
            return;
        };
        self.submit(path) catch |err| self.abort(err);
    }
    fn begin(self: *Controller, kind: Kind) !void {
        if (self.closed or self.app.closing or self.app.quitting) return error.Closing;
        if (self.busy()) return error.OperationPending;
        if (self.app.openDialogs()) return error.DialogPending;
        const browser = &self.app.browser;
        if (browser.closed or browser.loading or browser.choosing) return error.WorkspaceBusy;
        const manager = self.app.manager orelse return error.NoManager;
        try manager.checkManifestOperation(self.app);
        const current = if (browser.model) |*m| m else return error.NoWorkspace;
        if (kind != .save_as and current.manifest_path == null) return error.SaveWorkspaceFirst;
        var selected: ?model.RootId = null;
        if (kind == .remove) {
            const index = c.gtk_single_selection_get_selected(browser.view.selection);
            if (index >= browser.tree.rows.items.len) return error.NoSelection;
            const row = browser.tree.rows.items[index];
            if (row.more or row.node >= browser.tree.nodes.items.len) return error.NoSelection;
            selected = browser.tree.nodes.items[row.node].root;
            if (current.rootById(selected.?) == null) return error.WorkspaceChanged;
            if (current.roots.len <= 1) return error.LastRoot;
        }
        const token = current.scope.capture() orelse return error.WorkspaceChanged;
        const request_token = browser.requests.capture() orelse return error.WorkspaceChanged;
        var snapshot = try fs.Snapshot.capture(a, current);
        errdefer snapshot.deinit();
        const job = try a.create(Job);
        job.* = .{ .controller = self, .kind = kind, .snapshot = snapshot, .selected = selected, .token = token, .request_token = request_token, .cancel = c.g_cancellable_new().? };
        self.job = job;
        self.state = .choosing;
        self.error_name = null;
        self.app.hold();
    }
    fn fresh(self: *const Controller, job: *const Job) bool {
        if (self.closed or self.app.closing or self.app.quitting) return false;
        const browser = &self.app.browser;
        if (browser.closed or browser.loading or browser.choosing) return false;
        const current = if (browser.model) |*m| m else return false;
        return current.scope.accepts(job.token) and browser.requests.accepts(job.request_token) and
            std.mem.eql(u8, &current.policy_fingerprint, &job.snapshot.fingerprint);
    }
    fn check(self: *Controller, job: *const Job) !void {
        if (!self.fresh(job)) return error.WorkspaceChanged;
        const manager = self.app.manager orelse return error.NoManager;
        try manager.checkManifestOperation(self.app);
    }
    fn captureBound(self: *Controller, job: *Job) !void {
        std.debug.assert(!job.running);
        job.clearBound();
        const manager = self.app.manager orelse return error.NoManager;
        // Include closing registry entries: their held documents still bind paths.
        for (manager.entries) |entry| if (entry) |e| {
            for (e.app.snapshotDocuments()) |doc| if (doc.path) |path| {
                if (path.len > @import("manifest.zig").limits.path_bytes or job.bound.items.len >= 16 * 128) return error.TooLarge;
                const copy = try a.dupe(u8, path);
                errdefer a.free(copy);
                try job.bound.append(a, copy);
            };
        };
    }
    fn submit(self: *Controller, path: []const u8) !void {
        const job = self.job.?;
        try self.check(job);
        if (job.kind == .remove) {
            if (path.len != 0) return error.InvalidPath;
        } else try @import("manifest_fs.zig").absolutePath(path);
        job.path = try a.dupe(u8, path);
        try self.captureBound(job);
        self.closeDialog();
        self.state = .preparing;
        self.dispatch(.prepare);
    }
    pub fn respond(self: *Controller, accept: bool) void {
        if (self.job == null or self.state != .confirming) return;
        if (!accept) {
            self.cancel();
            return;
        }
        const job = self.job.?;
        self.check(job) catch |err| {
            self.abort(err);
            return;
        };
        self.app.manager.?.beginManifestOperation(self.app) catch |err| {
            self.abort(err);
            return;
        };
        job.barrier = true;
        self.captureBound(job) catch |err| {
            self.abort(err);
            return;
        };
        self.closeDialog();
        self.state = .applying;
        self.dispatch(.apply);
    }
    fn attachDialog(self: *Controller, dialog: u.W) void {
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        self.dialog = dialog;
        u.connect(dialog, "response", &response, self);
        u.connect(dialog, "destroy", &destroyed, self);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn showChooser(self: *Controller) void {
        const kind = self.job.?.kind;
        const dialog = chooser.create(title(kind), if (kind == .add) .select_folder else .save);
        chooser.setLocalOnly(dialog, 1);
        chooser.setMultiple(dialog, 0);
        chooser.setAcceptLabel(dialog, if (kind == .add) "_Review folder" else "_Review workspace save");
        if (kind == .save_as) chooser.setName(dialog, "Workspace.coral-workspace");
        self.attachDialog(@ptrCast(dialog));
    }
    fn showConfirmation(self: *Controller) void {
        const job = self.job.?;
        self.state = .confirming;
        const dialog = c.gtk_dialog_new().?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), "Review workspace manifest edit");
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 620, 460);
        const box = c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?;
        u.margin(u.cast(c.GtkWidget, box), 18);
        c.gtk_box_set_spacing(u.cast(c.GtkBox, box), 10);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Apply reviewed manifest", c.GTK_RESPONSE_ACCEPT);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        var selected_name: []const u8 = "";
        for (job.snapshot.roots) |root| if (job.selected == root.id) {
            selected_name = root.name;
        };
        const text = u.fmt("{s}\nManifest: {s}\n{s}{s}\nOnly this manifest is written. No root folders or open documents are deleted or closed. Existing destinations are refused for Save As; changed sources require a new review. Root paths below are absolute lexical paths. Canonical aliases are deduplicated.", .{
            title(job.kind), job.prepared.?.targetPath(), if (job.kind == .remove) "Remove root: " else "", selected_name,
        });
        defer a.free(text);
        const label = u.label(text);
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_wrap_mode(u.cast(c.GtkLabel, label), c.PANGO_WRAP_WORD_CHAR);
        c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
        u.append(u.cast(c.GtkWidget, box), label);
        // Review the exact validated bytes, not merely the operation's title.
        const view = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        const bytes = job.prepared.?.bytes;
        c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), bytes.ptr, @intCast(bytes.len));
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view);
        u.append(u.cast(c.GtkWidget, box), scroll);
        self.attachDialog(dialog);
    }
    fn closeDialog(self: *Controller) void {
        const dialog = self.dialog orelse return;
        self.dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_insert_action_group(dialog, "win", null);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    }
    fn cancel(self: *Controller) void {
        self.closeDialog();
        const job = self.job orelse return;
        c.g_cancellable_cancel(job.cancel);
        job.outcome = .cancelled;
        if (!job.running) self.retire();
    }
    fn abort(self: *Controller, err: anyerror) void {
        self.report(err);
        self.closeDialog();
        const job = self.job orelse return;
        c.g_cancellable_cancel(job.cancel);
        job.outcome = .failed;
        if (!job.running) self.retire();
    }
    fn retire(self: *Controller) void {
        if (self.job.?.prepared != null) {
            self.state = .retiring;
            self.dispatch(.retire);
        } else self.finish();
    }
    fn releaseBarrier(self: *Controller) void {
        const job = self.job.?;
        if (!job.barrier) return;
        self.app.manager.?.endManifestOperation(self.app);
        job.barrier = false;
    }
    fn finish(self: *Controller) void {
        const job = self.job.?;
        std.debug.assert(!job.running and job.prepared == null);
        self.releaseBarrier();
        self.closeDialog();
        self.state = job.outcome;
        self.job = null;
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
        // No GTask cancellable: never deliver early or skip worker retirement.
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
            error.SaveWorkspaceFirst => "This is a folder-only workspace. Run Save Workspace As… first, then retry Add Folder to Workspace or Remove Selected Root. No changes were made.",
            error.LastRoot => "Keep at least one root. To detach the workspace, use Close Workspace; open documents are kept.",
            error.NoSelection => "Select a root or one of its children in the explorer. Remove acts on that entry's owning root, never on disk contents.",
            error.NoWorkspace => "Open a folder or workspace first.",
            error.DuplicateRoot => "That folder is already a workspace root (including canonical symlink aliases).",
            error.TooManyRoots => "A workspace can contain at most 32 roots.",
            error.AlreadyExists => "Save Workspace As requires a new filename. Existing files, directories and symlinks are never overwritten.",
            error.WorkspaceChanged, error.StaleSnapshot => "The workspace, source manifest, settings or paths changed. Rescan the workspace, then start a new request and review it again.",
            error.OpenDocument, error.UnverifiableDocument => "Close documents bound to this manifest in every window before editing it. Symlink and hardlink aliases are checked too.",
            error.NotFound, error.NotDirectory => "Choose an existing folder/parent directory. This command does not create directories.",
            error.Symlink, error.NotRegularFile, error.NoEtag => "Editing requires a stable regular manifest with a usable etag. Special files and paths changed into symlinks during the operation are refused.",
            error.DurabilityUncertain => "The new manifest was published, but directory durability could not be confirmed. Check it on disk; do not assume the old state remains.",
            error.Cancelled => "The workspace edit was cancelled.",
            else => "Finish pending dialogs, loads, saves and sessions in all windows, then retry. No root directories or open documents are removed by this command.",
        };
        const text = u.fmt("Workspace roots: {s}. {s}", .{ @errorName(err), hint });
        defer a.free(text);
        self.app.message(text);
    }
    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const job = self.job;
        const text = std.json.Stringify.valueAlloc(a, .{
            .state = self.state,
            .busy = self.busy(),
            .dialog = self.dialog != null,
            .confirmation = self.state == .confirming,
            .closed = self.closed,
            .kind = if (job) |j| j.kind else @as(?Kind, null),
            .path = if (job) |j| j.path else @as(?[]const u8, null),
            .selected = if (job) |j| if (j.selected) |id| @backingInt(id) else null else @as(?u64, null),
            .workspace = if (job) |j| @backingInt(j.token.workspace) else @as(?u64, null),
            .generation = if (job) |j| j.token.generation else @as(?u64, null),
            .barrier = if (job) |j| j.barrier else false,
            .err = self.error_name,
            .jobs_started = self.jobs_started,
            .jobs_reaped = self.jobs_reaped,
            .completed = self.completed,
        }, .{}) catch return;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_ROOTS %s\n", z.ptr);
    }
};

const Job = struct {
    controller: *Controller,
    kind: Kind,
    snapshot: fs.Snapshot,
    selected: ?model.RootId,
    path: ?[]u8 = null,
    bound: std.ArrayList([]const u8) = .empty,
    token: identity.Token,
    request_token: identity.Token,
    cancel: *c.GCancellable,
    prepared: ?fs.Prepared = null,
    err: ?anyerror = null,
    phase: Phase = .prepare,
    delay_us: u64 = 0,
    running: bool = false,
    barrier: bool = false,
    committed: bool = false,
    outcome: State = .cancelled,
    fn clearBound(self: *Job) void {
        for (self.bound.items) |p| a.free(p);
        self.bound.clearRetainingCapacity();
    }
    fn clearPrepared(self: *Job) void {
        if (self.prepared) |*p| p.deinit();
        self.prepared = null;
    }
    fn destroy(self: *Job) void {
        std.debug.assert(!self.running and !self.barrier and self.prepared == null);
        self.clearBound();
        self.bound.deinit(a);
        if (self.path) |p| a.free(p);
        self.snapshot.deinit();
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
            .prepare => self.prepared = try fs.prepare(a, .{ .kind = self.kind, .snapshot = &self.snapshot, .path = self.path.?, .selected = self.selected }, self.bound.items, self.cancel),
            .apply => {
                defer self.clearPrepared();
                defer self.committed = self.prepared.?.committed;
                try fs.apply(&self.prepared.?, self.bound.items, self.cancel);
            },
            .retire => self.clearPrepared(),
        }
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
    if (job.phase == .apply and job.committed) {
        job.outcome = .succeeded;
        self.completed += 1;
        const load = self.fresh(job);
        const path = u.z(if (job.kind == .save_as) job.path.? else job.snapshot.source.?);
        defer a.free(path);
        const app = self.app;
        // Release the admission barrier AND busy state before ordinary load.
        // That path revalidates trust; no document close/restore is performed.
        app.hold();
        defer app.release();
        if (job.err) |err| self.report(err);
        self.finish();
        if (load) {
            app.browser.load(.manifest, path);
            if (self.error_name == null) app.message("Workspace manifest saved. Reloading roots and policy; open documents are kept.");
        }
        return;
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
        return;
    }
    if (id != c.GTK_RESPONSE_ACCEPT) {
        self.cancel();
        return;
    }
    const file = chooser.getFile(@ptrCast(dialog.?)) orelse {
        self.abort(error.NonLocalPath);
        return;
    };
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(@ptrCast(file));
    defer c.g_free(path);
    if (path == null) {
        self.abort(error.NonLocalPath);
        return;
    }
    self.submit(std.mem.span(path)) catch |err| self.abort(err);
}
fn destroyed(widget: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.dialog != widget) return;
    self.dialog = null;
    self.cancel();
}
fn title(kind: Kind) [*:0]const u8 {
    return switch (kind) {
        .add => "Add Folder to Workspace",
        .remove => "Remove Selected Root",
        .save_as => "Save Workspace As",
    };
}
