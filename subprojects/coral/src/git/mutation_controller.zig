//! One-shot native review of an independently prepared selected-path index change.
//! GTK owns admission; workers alone prepare, apply and retire backend resources.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const identity = @import("../workspace/identity.zig");
const model = @import("../workspace/model.zig");
const status = @import("status.zig");
const backend = @import("index_transaction.zig");
const hooks = @import("build_options").test_hooks;
pub const Action = backend.Action;
pub const State = enum { idle, preparing, confirming, applying, retiring, succeeded, cancelled, failed };
const Phase = enum { prepare, apply, retire };

pub const Controller = struct {
    app: *App,
    dialog: ?u.W = null,
    job: ?*Job = null,
    state: State = .idle,
    error_name: ?[]const u8 = null,
    action: ?Action = null,
    path: [:0]u8,
    review: [:0]u8,
    before_exists: ?bool = null,
    after_exists: ?bool = null,
    before_mode: ?u32 = null,
    after_mode: ?u32 = null,
    before_bytes: usize = 0,
    after_bytes: usize = 0,
    committed: bool = false,
    durability_uncertain: bool = false,
    jobs_started: u64 = 0,
    jobs_reaped: u64 = 0,
    delay_phase: Phase = .prepare,
    delay_us: u64 = 0,

    pub fn init(app: *App) Controller {
        // Do not reach through App.git here: its parent is still being initialized.
        return .{ .app = app, .path = u.z(""), .review = u.z("") };
    }
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.job == null and self.dialog == null);
        a.free(self.path);
        a.free(self.review);
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null;
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
    }
    pub fn cancel(self: *Controller) void {
        // Publish cancellation before destroying GTK surfaces or doing any other
        // owner-thread work. Only the worker's committed result can override it.
        if (self.job) |job| job.cancel.store(true, .release);
        self.closeDialog();
        const job = self.job orelse return;
        if (job.outcome != .failed) job.outcome = .cancelled;
        if (!job.running) self.retire();
    }

    pub fn request(self: *Controller, req: backend.Request, root_id: model.RootId, owner: []const u8, generation: u64) void {
        if (self.busy()) {
            self.app.message("An index review is already pending. Finish or cancel it before requesting another.");
            return;
        }
        self.error_name = null;
        self.committed = false;
        self.durability_uncertain = false;
        self.action = req.action;
        self.before_exists = null;
        self.after_exists = null;
        self.before_mode = null;
        self.after_mode = null;
        self.before_bytes = 0;
        self.after_bytes = 0;
        a.free(self.path);
        self.path = u.z(req.path);
        a.free(self.review);
        self.review = u.z("");
        self.begin(req, root_id, owner, generation) catch |err| self.abort(err);
    }
    fn begin(self: *Controller, req: backend.Request, root_id: model.RootId, owner: []const u8, generation: u64) !void {
        const snapshot = if (self.app.browser.model) |*value| value else return error.WorkspaceChanged;
        const token = snapshot.scope.capture() orelse return error.WorkspaceChanged;
        const request_token = self.app.browser.requests.capture() orelse return error.WorkspaceChanged;
        const workspace = self.app.workspace.capture() orelse return error.WorkspaceChanged;
        const job = try a.create(Job);
        job.* = .{
            .controller = self,
            .root = u.z(req.root),
            .gitdir = u.z(req.gitdir),
            .commondir = u.z(req.commondir),
            .path = u.z(req.path),
            .absolute = u.fmt("{s}/{s}", .{ std.mem.trimEnd(u8, req.root, "/"), req.path }),
            .index_path = u.fmt("{s}/index", .{req.gitdir}),
            .owner = u.z(owner),
            .root_id = root_id,
            .action = req.action,
            .generation = generation,
            .token = token,
            .request_token = request_token,
            .workspace = workspace,
        };
        errdefer job.destroy();
        try self.check(job);
        self.job = job;
        self.app.hold();
        self.state = .preparing;
        self.dispatch(.prepare);
    }

    fn check(self: *Controller, job: *const Job) !void {
        const git = &self.app.git;
        if (self.app.closing or self.app.quitting or git.window == null or !git.approved or
            git.generation != job.generation or job.cancel.load(.acquire)) return error.RequestChanged;
        const permit = git.permit orelse return error.Restricted;
        if (!self.app.workspace_policy.validate(permit, .git)) return error.Restricted;
        if (!self.app.workspace.accepts(job.workspace) or self.app.browser.closed or
            self.app.browser.loading or self.app.browser.choosing) return error.WorkspaceChanged;
        const snapshot = if (self.app.browser.model) |*value| value else return error.WorkspaceChanged;
        if (!snapshot.scope.accepts(job.token) or !self.app.browser.requests.accepts(job.request_token)) return error.WorkspaceChanged;
        const root = snapshot.rootById(job.root_id) orelse return error.WorkspaceChanged;
        if (root.availability != .available or !std.mem.eql(u8, root.canonical_path orelse return error.WorkspaceChanged, job.owner)) return error.WorkspaceChanged;
        if (git.job != null or !git.mutationSelectionMatches(job.root_id, job.owner, .{
            .root = job.root,
            .gitdir = job.gitdir,
            .commondir = job.commondir,
            .path = job.path,
            .action = job.action,
        })) return error.SelectionChanged;
        const manager = self.app.manager orelse return error.NoManager;
        for (manager.entries) |entry| if (entry) |window| {
            for (window.app.snapshotDocuments()) |doc| {
                if (doc.path) |path| if (std.mem.eql(u8, path, job.absolute)) {
                    if (doc.busy or doc.loading or doc.pending != null or doc.pending_reload) return error.DocumentPending;
                };
            }
        };
        // This changes the index, not the selected worktree file. Supplying the
        // actual index path permits dirty buffers while retaining manager-wide
        // save/load/modal admission and the shared editor/operation barrier.
        try manager.checkFileOperation(self.app, job.index_path, "");
    }

    fn respond(self: *Controller, accept: bool) void {
        if (self.dialog == null or self.state != .confirming) return;
        const job = self.job orelse return;
        if (!accept) {
            self.cancel();
            return;
        }
        self.check(job) catch |err| {
            self.abort(err);
            return;
        };
        self.app.manager.?.beginFileOperation(self.app, job.index_path, "") catch |err| {
            self.abort(err);
            return;
        };
        job.barrier = true;
        job.attempted = true;
        // Consumes this dialog's approval before dispatch. No retry can reuse it.
        self.closeDialog();
        self.state = .applying;
        self.dispatch(.apply);
    }

    fn showReview(self: *Controller) !void {
        const p = &self.job.?.prepared.?;
        self.before_exists = p.before_exists;
        self.after_exists = p.after_exists;
        self.before_mode = p.before_mode;
        self.after_mode = p.after_mode;
        self.before_bytes = p.before.len;
        self.after_bytes = p.after.len;
        const path = try status.displayLabel(a, p.path);
        defer a.free(path);
        const root = try status.displayLabel(a, self.job.?.root);
        defer a.free(root);
        const before = try preview(p.before);
        defer a.free(before);
        const after = try preview(p.after);
        defer a.free(after);
        const heading = u.fmt("{s} selected file: {s}\nRepository: {s}\nFULL FILE, NOT HUNKS. Unsaved editor documents across windows: {d} (at review creation). Dirty buffers are allowed, excluded and NEVER saved. Stage uses only the captured disk snapshot; Unstage restores the HEAD snapshot to the index.\nThis approval changes only this path in the index; no commit or worktree write.\nComplete captured bytes below (scroll each pane). Backslashes and controls are escaped; each \\n marks an actual LF. Empty and absent files differ. SHA-256 digests identify the original, unescaped bytes.", .{ if (p.action == .stage) "Stage" else "Unstage", path, root, self.app.git.dirtyCount() });
        defer a.free(heading);
        var before_digest: [32]u8 = undefined;
        var after_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(p.before, &before_digest, .{});
        std.crypto.hash.sha2.Sha256.hash(p.after, &after_digest, .{});
        const before_hash = std.fmt.bytesToHex(before_digest, .lower);
        const after_hash = std.fmt.bytesToHex(after_digest, .lower);
        const before_label = u.fmt("BEFORE — INDEX · exists: {s} · mode: {o} · {d} bytes\nSHA-256: {s}", .{ if (p.before_exists) "yes" else "no", p.before_mode, p.before.len, before_hash });
        defer a.free(before_label);
        const after_label = u.fmt("AFTER — INDEX FROM {s} · exists: {s} · mode: {o} · {d} bytes\nSHA-256: {s}", .{ if (p.action == .stage) "DISK" else "HEAD", if (p.after_exists) "yes" else "no", p.after_mode, p.after.len, after_hash });
        defer a.free(after_label);
        a.free(self.review);
        self.review = u.fmt("{s}\n\n{s}\n{s}\n\n{s}\n{s}", .{ heading, before_label, before, after_label, after });
        // language.UI renders its body in a label. Use native text views here
        // instead so every reviewed byte remains scrollable, without a giant
        // shaped label or a truncated preview authorizing unseen content.
        const dialog = c.gtk_dialog_new().?;
        self.dialog = dialog;
        self.state = .confirming;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), "Review full-file index change — not hunks");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.app.git.window.?));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 900, 760);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), if (p.action == .stage) "_Stage reviewed file" else "_Unstage reviewed file", c.GTK_RESPONSE_ACCEPT);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        const box = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?);
        u.margin(box, 12);
        // Paths can be thousands of escaped bytes too. Keep the full scope
        // disclosure scrollable instead of letting it push approval off-screen.
        addPane(box, "Selected path and scope — complete disclosure", heading);
        addPane(box, before_label, before);
        addPane(box, after_label, after);
        u.connect(dialog, "response", &response, self);
        u.connect(dialog, "destroy", &destroyed, self);
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn closeDialog(self: *Controller) void {
        const dialog = self.dialog orelse return;
        self.dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_insert_action_group(dialog, "win", null);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    }
    fn abort(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.closeDialog();
        if (!self.app.closing) {
            const text = u.fmt("Index mutation refused: {s}. No index change was published. {s}", .{ @errorName(err), if (err == error.PreviewTooLarge) "Complete review exceeds 256 KiB of display per side, 4,000 lines or 2,048 source bytes per line; no partial approval is available." else "Resolve pending operations or changed selection/workspace/disk state, then request a new review. Dirty buffers need not be saved." });
            defer a.free(text);
            self.app.message(text);
        }
        if (self.job) |job| {
            job.outcome = .failed;
            job.cancel.store(true, .release);
            if (!job.running) self.retire();
        } else self.state = .failed;
    }
    fn retire(self: *Controller) void {
        const job = self.job.?;
        std.debug.assert(!job.running);
        if (job.prepared != null) {
            self.state = .retiring;
            self.dispatch(.retire);
        } else self.finish();
    }
    fn finish(self: *Controller) void {
        const job = self.job.?;
        std.debug.assert(!job.running and job.prepared == null);
        if (job.barrier) {
            self.app.manager.?.endFileOperation(self.app);
            job.barrier = false;
        }
        self.closeDialog();
        self.state = job.outcome;
        const refresh = job.attempted;
        self.job = null;
        job.destroy();
        // Clear/reload even failed or cancelled apply attempts: their old status
        // and read-only diff must not continue to look like a current snapshot.
        self.app.git.mutationFinished(refresh);
        self.app.release();
    }
    fn dispatch(self: *Controller, phase: Phase) void {
        const job = self.job.?;
        std.debug.assert(!job.running);
        job.phase = phase;
        job.running = true;
        self.app.git.updateMutationActions();
        job.err = null;
        job.delay_us = 0;
        if (hooks and self.delay_phase == phase) {
            job.delay_us = @min(self.delay_us, 2_000_000);
            self.delay_us = 0;
        }
        self.jobs_started += 1;
        // No GCancellable on GTask: cancellation cannot skip worker retirement or
        // deliver an early callback while a worker still owns backend resources.
        const task = c.g_task_new(null, null, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "git-mutation-accept") or std.mem.eql(u8, action, "git-mutation-reject")) {
            if (self.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), if (std.mem.eql(u8, action, "git-mutation-accept")) c.GTK_RESPONSE_ACCEPT else c.GTK_RESPONSE_CANCEL);
        } else if (std.mem.eql(u8, action, "git-mutation-delay")) {
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return true;
            self.delay_phase = std.meta.stringToEnum(Phase, value[0..colon]) orelse return true;
            self.delay_us = @as(u64, @min(std.fmt.parseInt(u64, value[colon + 1 ..], 10) catch return true, 2000)) * 1000;
        } else return false;
        return true;
    }
    pub fn probe(self: *const Controller) Probe {
        return .{ .state = @tagName(self.state), .action = if (self.action) |action| @tagName(action) else null, .path = self.path, .@"error" = self.error_name, .review = self.review, .before_exists = self.before_exists, .after_exists = self.after_exists, .before_mode = self.before_mode, .after_mode = self.after_mode, .before_bytes = self.before_bytes, .after_bytes = self.after_bytes, .dialog = self.dialog != null, .busy = self.busy(), .committed = self.committed, .durability_uncertain = self.durability_uncertain, .barrier = if (self.job) |job| job.barrier else false, .jobs_started = self.jobs_started, .jobs_reaped = self.jobs_reaped };
    }
};
pub const Probe = struct {
    state: []const u8,
    action: ?[]const u8,
    path: []const u8,
    @"error": ?[]const u8,
    review: []const u8,
    before_exists: ?bool,
    after_exists: ?bool,
    before_mode: ?u32,
    after_mode: ?u32,
    before_bytes: usize,
    after_bytes: usize,
    dialog: bool,
    busy: bool,
    committed: bool,
    durability_uncertain: bool,
    barrier: bool,
    jobs_started: u64,
    jobs_reaped: u64,
};
const Job = struct {
    controller: *Controller,
    root: [:0]u8,
    gitdir: [:0]u8,
    commondir: [:0]u8,
    path: [:0]u8,
    absolute: [:0]u8,
    index_path: [:0]u8,
    owner: [:0]u8,
    root_id: model.RootId,
    action: Action,
    generation: u64,
    token: identity.Token,
    request_token: identity.Token,
    workspace: identity.Token,

    cancel: backend.Cancel = .init(false),
    prepared: ?backend.Prepared = null,
    err: ?anyerror = null,
    phase: Phase = .prepare,
    running: bool = false,
    barrier: bool = false,
    attempted: bool = false,
    delay_us: u64 = 0,
    outcome: State = .cancelled,
    result: backend.Outcome = .{ .committed = false },

    fn destroy(self: *Job) void {
        std.debug.assert(self.prepared == null and !self.running and !self.barrier);
        inline for (.{ "root", "gitdir", "commondir", "path", "absolute", "index_path", "owner" }) |field| a.free(@field(self, field));
        a.destroy(self);
    }
    fn perform(self: *Job) !void {
        var remaining = self.delay_us;
        while (remaining != 0 and !self.cancel.load(.acquire)) {
            const slice = @min(remaining, 10_000);
            c.g_usleep(@intCast(slice));
            remaining -= slice;
        }
        switch (self.phase) {
            .prepare => self.prepared = try backend.prepare(a, .{ .root = self.root, .gitdir = self.gitdir, .commondir = self.commondir, .path = self.path, .action = self.action }, &self.cancel),
            .apply => {
                defer self.clearPrepared();
                self.result = try backend.apply(&self.prepared.?, &self.cancel);
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
    // Publication wins over every invalidation/cancellation race, including close.
    if (job.result.committed) {
        job.outcome = .succeeded;
        self.committed = true;
        self.durability_uncertain = job.result.durability_uncertain;
        self.error_name = null;
        if (!self.app.closing) self.app.message(if (self.durability_uncertain) "Selected index change committed, but directory durability is uncertain. Do not blindly retry." else "Selected index change committed. No commit or worktree file was written.");
        self.finish();
        return;
    }
    if (job.cancel.load(.acquire) or self.app.closing) {
        self.retire();
        return;
    }
    if (job.err) |err| {
        self.abort(err);
        return;
    }
    if (job.phase == .apply) {
        self.abort(error.NotCommitted);
        return;
    }
    self.check(job) catch |err| {
        self.abort(err);
        return;
    };
    self.showReview() catch |err| self.abort(err);
}
fn response(dialog: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.dialog != u.cast(c.GtkWidget, dialog.?)) return;
    self.respond(id == c.GTK_RESPONSE_ACCEPT);
}
fn destroyed(widget: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.dialog != widget) return;
    self.dialog = null;
    self.cancel();
}
fn addPane(box: u.W, heading: []const u8, text: []const u8) void {
    const label = u.label(heading);
    c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
    u.append(box, label);
    const scroll = c.gtk_scrolled_window_new().?;
    c.gtk_widget_set_vexpand(scroll, 1);
    c.gtk_widget_set_size_request(scroll, -1, 180);
    const view = c.gtk_text_view_new().?;
    c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
    c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
    c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
    c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), text.ptr, @intCast(text.len));
    c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view);
    u.append(box, scroll);
}
fn preview(bytes: []const u8) ![]u8 {
    if (bytes.len > backend.max_file_bytes) return error.PreviewTooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    var consumed: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        if (count > 4000 or line.len > 2048) return error.PreviewTooLarge;
        const escaped = try status.displayLabel(a, line);
        defer a.free(escaped);
        try out.appendSlice(a, escaped);
        consumed += line.len;
        if (consumed < bytes.len) {
            try out.appendSlice(a, "\\n\n");
            consumed += 1;
        }
        if (out.items.len > backend.max_file_bytes) return error.PreviewTooLarge;
    }
    return out.toOwnedSlice(a);
}
