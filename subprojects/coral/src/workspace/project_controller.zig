//! Automatic per-window sessions. Explicit checkpoints and recovery are separate.
//! GTK owns metadata/captures; workers own all catalog and snapshot filesystem I/O.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const session = @import("session_controller.zig").Controller;
const model = @import("session_model.zig");
const recovery = @import("recovery_model.zig");
pub const fs = @import("project_fs.zig");
const picker_ui = @import("../workbench/workspace_picker.zig");
const identity = @import("identity.zig");
const hooks = @import("build_options").test_hooks;
pub const Target = struct { id: fs.Id, updated: i64, reopen: bool };
const Kind = enum { save, retire, resume_membership, identity, list, startup, suppress, load, restore_commit, restore_abort, abandon, release, forget };
const PickerKind = enum { projects, buffers, forget };
const Mapping = union(enum) { project: Target, buffer: u64 };

pub const Controller = struct {
    app: *App,
    id: ?fs.Id = null,
    established: bool = false,
    generation: ?i64 = null,
    storage: Storage = .{},
    retiring: bool = false,
    retirement_ready: bool = false,
    retirement_cancelled: bool = false,
    retirement_error: ?anyerror = null,
    retirement_hash: ?u64 = null,
    restore_cleanup: bool = false,
    source: ?fs.Source = null,
    path: ?[]u8 = null,
    enabled: bool = false,
    suppression_pending: bool = false,
    closed: bool = false,
    restoring: bool = false,
    restore_target: ?Target = null,
    restore_succeeded: bool = false,
    prepared: ?*model.Owned = null,
    restore_token: ?identity.Token = null,
    catalog: ?fs.Catalog = null,
    job: ?*Job = null,
    queue: std.ArrayList(*Job) = .empty,
    timer: c_uint = 0,
    first_change: i64 = 0,
    last_change: i64 = 0,
    observed: ?u64 = null,
    saved_hash: ?u64 = null,
    error_name: ?[]const u8 = null,
    retry_after: i64 = 0,
    failed_restore_hash: ?u64 = null,
    failed_capture_hash: ?u64 = null,
    captures: u64 = 0,
    writes: u64 = 0,
    test_next_delay_us: u64 = 0,
    picker: ?*picker_ui.Picker = null,
    picker_kind: PickerKind = .projects,
    mapping: [picker_ui.max_items]Mapping = undefined,
    mapping_len: usize = 0,
    show_after_list: bool = false,
    forget_target: ?Target = null,
    dialog: ?u.W = null,
    frozen: ?*model.Owned = null,
    discarded: [recovery.limits.documents]u64 = undefined,
    discarded_len: usize = 0,

    pub fn init(app: *App) Controller {
        return .{ .app = app };
    }
    pub fn enable(self: *Controller) void {
        self.enabled = true;
        if (self.timer == 0 and !self.closed) self.timer = c.g_timeout_add(1000, &tick, self);
        self.changed();
    }
    pub fn startup(self: *Controller, suppress: bool) void {
        if (suppress) {
            if (self.app.snapshotDocuments().len == 0) _ = self.app.newDocument();
            self.suppressStartup();
            return;
        }
        self.submit(.startup, null, null) catch |err| {
            self.report(err);
            if (self.app.snapshotDocuments().len == 0) _ = self.app.newDocument();
            self.enable();
        };
    }
    /// Recovery/explicit CLI selects a new launch set, but never deletes history.
    /// Clearing old membership also prevents a later launch from reviving older
    /// dirty text after the recovery chooser explicitly discarded its journal.
    pub fn suppressStartup(self: *Controller) void {
        self.suppression_pending = true;
        if (self.job) |job| if (job.kind == .suppress) return;
        for (self.queue.items) |job| if (job.kind == .suppress) return;
        self.submit(.suppress, null, null) catch |err| self.report(err);
        self.enable();
    }
    pub fn changed(self: *Controller) void {
        if (!self.enabled or self.closed or self.restoring or self.frozen != null) return;
        // Checkpoint notifications are metadata only. No capture or I/O here.
        const now = c.g_get_monotonic_time();
        if (self.first_change == 0) self.first_change = now;
        self.last_change = now;
    }
    fn available(self: *Controller) bool {
        const app = self.app;
        return self.enabled and !self.suppression_pending and !self.closed and !self.restoring and !self.restore_cleanup and !self.retiring and !self.retirement_ready and !app.editingFrozen() and self.frozen == null and self.failed_restore_hash == null and c.g_get_monotonic_time() >= self.retry_after and
            !app.recovery_suspended and !app.quitting and !app.browser.loading and
            !app.browser.choosing and !app.fileOperationBarrier() and !app.workspaceOperationBusy() and
            app.session.work == null and app.pending_file_loads == 0 and !app.history.active;
    }
    fn ensureIdentity(self: *Controller) !void {
        var source: ?fs.Source = null;
        var path: ?[]const u8 = null;
        if (self.app.browser.model) |current| {
            source = if (current.manifest_path != null) .manifest else .folder;
            path = current.manifest_path orelse current.roots[0].lexical_path;
        }
        if (self.id != null and self.source == source and optionalEqual(self.path, path)) return;
        const id = try fs.newId();
        const copy = if (path) |p| try a.dupe(u8, p) else null;
        if (self.path) |p| a.free(p);
        if (self.id != null) {
            self.restore_succeeded = false;
        }
        self.id = id;
        self.established = false;
        self.generation = null;
        self.path = copy;
        self.source = source;
        self.saved_hash = null;
    }
    /// Called before retiring a model. Preserve the old identity before Open
    /// Folder/Workspace keeps its documents and establishes a different project.
    pub fn beforeWorkspaceChange(self: *Controller, next: ?*const @import("model.zig").Model) !bool {
        if (!self.enabled or self.closed or self.restoring) return true;
        if (self.frozen != null) return false;
        if (self.app.browser.model == null) {
            if (next == null) return true;
            // Do not manufacture history for the pristine launch placeholder.
            // Real scratch windows (including split/layout work) remain sessions.
            if (self.id == null and self.app.snapshotDocuments().len <= 1 and self.app.groups.items.items.len == 1 and self.app.views.items.len <= 1 and self.app.excerpts.items.len == 0) {
                var pristine = true;
                for (self.app.snapshotDocuments()) |doc| if (doc.path != null or doc.dirty() or c.gtk_text_buffer_get_char_count(doc.buffer) != 0) {
                    pristine = false;
                };
                if (pristine) return true;
            }
        }
        if (self.app.browser.model) |old| if (next) |new| {
            const old_path = old.manifest_path orelse old.roots[0].lexical_path;
            const new_path = new.manifest_path orelse new.roots[0].lexical_path;
            if ((old.manifest_path != null) == (new.manifest_path != null) and std.mem.eql(u8, old_path, new_path)) return true;
        };
        if (self.retirement_error) |err| {
            self.retirement_error = null;
            return err;
        }
        if (self.retirement_ready) {
            if (self.retirement_hash == try self.app.projectFingerprint()) return true;
            self.retirement_ready = false;
        }
        if (self.retiring or self.job != null or self.queue.items.len != 0) return false;
        try self.ensureIdentity();
        const value = try session.capture(self.app);
        errdefer value.deinit();
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .controller = self, .kind = .retire, .id = self.id, .value = value, .reopen = false };
        self.retirement_hash = try self.app.projectFingerprint();
        self.retiring = true;
        errdefer self.retiring = false;
        try self.enqueue(job);
        return false;
    }
    pub fn cancelWorkspaceChange(self: *Controller) void {
        self.retirement_error = null;
        if (self.retiring) {
            self.retirement_cancelled = true;
            return;
        }
        if (!self.retirement_ready) return;
        self.retirement_ready = false;
        self.retirement_hash = null;
        self.saved_hash = null;
        self.submit(.resume_membership, null, null) catch |err| self.report(err);
        self.changed();
    }
    pub fn workspaceChanged(self: *Controller) void {
        self.retirement_ready = false;
        self.retirement_hash = null;
        if (!self.enabled or self.closed or self.restoring) return;
        const previous = self.id;
        self.ensureIdentity() catch |err| {
            self.report(err);
            return;
        };
        if (previous == null or !sameId(previous.?, self.id.?)) {
            self.submit(.identity, .{ .id = self.id.?, .updated = 0, .reopen = true }, null) catch |err| self.report(err);
        }
        self.changed();
    }
    pub fn checkpoint(self: *Controller) void {
        if (self.failed_restore_hash) |old| {
            const current = self.app.projectFingerprint() catch |err| {
                self.report(err);
                return;
            };
            if (old == current) return;
            self.failed_restore_hash = null;
        }
        // An explicit retry is not subject to the automatic failure backoff.
        self.retry_after = 0;
        self.failed_capture_hash = null;
        if (self.suppression_pending) {
            self.suppressStartup();
            return;
        }
        if (!self.available()) {
            self.changed();
            return;
        }
        self.capture(true, true) catch |err| self.report(err);
    }
    fn capture(self: *Controller, reopen: bool, force: bool) !void {
        try self.ensureIdentity();
        const hash = try self.app.projectFingerprint();
        if (!force and self.saved_hash == hash) return;
        self.app.checkpoint();
        const value = session.capture(self.app) catch |err| {
            self.failed_capture_hash = hash;
            return err;
        };
        errdefer value.deinit();
        self.failed_capture_hash = null;
        try self.enqueueSave(value, reopen, false);
        self.saved_hash = hash;
        self.captures += 1;
        self.first_change = 0;
        self.last_change = 0;
    }
    fn enqueueSave(self: *Controller, value: *model.Owned, reopen: bool, finalize: bool) !void {
        const id = self.id orelse return error.NoIdentity;
        // Only supersede a pending snapshot of THIS durable identity. A retired
        // project's final snapshot is never dropped by a new project's edits.
        for (self.queue.items) |pending| {
            if (pending.kind == .save and sameId(pending.id.?, id)) {
                pending.value.?.deinit();
                pending.value = value;
                pending.reopen = reopen;
                pending.finalize = finalize;
                return;
            }
        }
        // At most one running and one pending image per window. A rapid
        // identity transition waits rather than discarding another project's
        // final image or growing a queue of whole-buffer captures.
        for (self.queue.items) |pending| if (pending.kind == .save) return error.Busy;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .controller = self, .kind = .save, .id = id, .value = value, .reopen = reopen, .finalize = finalize };
        try self.enqueue(job);
    }
    fn submit(self: *Controller, kind: Kind, target: ?Target, value: ?*model.Owned) !void {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .controller = self, .kind = kind, .id = if (target) |t| t.id else null, .target = target, .value = value };
        try self.enqueue(job);
    }
    fn enqueue(self: *Controller, job: *Job) !void {
        if (self.queue.items.len >= fs.limits.sessions + 4) return error.Busy;
        try self.queue.append(a, job);
        self.app.hold();
        self.dispatch();
    }
    fn dispatch(self: *Controller) void {
        if (self.job != null or self.queue.items.len == 0) return;
        const job = self.queue.orderedRemove(0);
        self.job = job;
        job.delay_us = if (hooks) self.test_next_delay_us else 0;
        self.test_next_delay_us = 0;
        const task = c.g_task_new(null, null, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    fn retryRestoreCleanup(self: *Controller) void {
        if (!self.restore_cleanup or self.closed) return;
        if (self.job) |job| if (job.kind == .restore_abort or job.kind == .restore_commit) return;
        for (self.queue.items) |job| if (job.kind == .restore_abort or job.kind == .restore_commit) return;
        self.submit(if (self.restore_succeeded) .restore_commit else .restore_abort, null, null) catch |err| self.report(err);
    }
    pub fn refresh(self: *Controller) void {
        if (self.closed) return;
        self.retryRestoreCleanup();
        if (self.suppression_pending) self.suppressStartup();
        if (self.job) |job| if (job.kind == .list or job.kind == .startup) return;
        for (self.queue.items) |job| if (job.kind == .list) return;
        self.submit(.list, null, null) catch |err| self.report(err);
    }
    pub fn restore(self: *Controller, target: Target) void {
        if (self.closed or self.restoring or self.app.snapshotDocuments().len != 0 or self.app.browser.model != null) return;
        self.restore_target = target;
        self.restoring = true;
        self.restore_token = self.app.browser.requests.capture();
        self.enable();
        self.submit(.load, target, null) catch |err| self.restoreFailed(err);
    }
    fn tryPrepared(self: *Controller) void {
        const value = self.prepared orelse return;
        if (self.closed or self.app.quitting or !self.app.browser.requests.accepts(self.restore_token.?)) {
            self.prepared = null;
            value.deinit();
            self.restoreFailed(error.StaleWorkspace);
            return;
        }
        if (self.app.manager) |manager| if (manager.session_owner != null) return;
        session.startPrepared(&self.app.session, value, self, &restored) catch |err| {
            if (err == error.Busy or err == error.Loading) return;
            self.prepared = null;
            value.deinit();
            self.restoreFailed(err);
            return;
        };
        self.prepared = null;
    }
    fn restoreFailed(self: *Controller, err: anyerror) void {
        self.restoring = false;
        self.restore_succeeded = false;
        self.restore_cleanup = true;
        self.submit(.restore_abort, null, null) catch |failure| self.report(failure);
        self.report(err);
        // Do not overwrite/consume the source record. Recents remains a retry UI.
        var placeholder = false;
        if (!self.closed and self.app.snapshotDocuments().len == 0) {
            _ = self.app.newDocument();
            placeholder = true;
        }
        self.failed_restore_hash = if (placeholder) self.app.projectFingerprint() catch null else null;
        self.changed();
    }
    pub fn open(self: *Controller, target: Target) void {
        if (self.closed or self.app.openDialogs() or self.app.fileOperationBarrier()) return;
        const manager = self.app.manager orelse return;
        for (manager.entries) |entry| if (entry) |e| {
            const p = &e.app.projects;
            if (p.job) |job| if (job.kind == .forget and sameId(job.id.?, target.id)) {
                self.report(error.Busy);
                return;
            };
            for (p.queue.items) |job| if (job.kind == .forget and sameId(job.id.?, target.id)) {
                self.report(error.Busy);
                return;
            };
        };
        var record: ?fs.Record = null;
        if (self.catalog) |catalog| for (catalog.records) |r| {
            if (sameId(r.id, target.id)) {
                record = r;
                break;
            }
        };
        for (manager.entries) |entry| if (entry) |e| {
            const other = &e.app.projects;
            if (e.app.closing) continue;
            const exact = if (other.id) |id| sameId(id, target.id) else false;
            const origin = if (other.restore_target) |t| (other.restoring or other.restore_succeeded) and sameId(t.id, target.id) else false;
            var matches = false;
            if (record) |r| if (r.source != null) {
                if (e.app.browser.model) |m| {
                    const s: fs.Source = if (m.manifest_path != null) .manifest else .folder;
                    matches = s == r.source and optionalEqual(m.manifest_path orelse m.roots[0].lexical_path, r.path);
                }
            };
            if (exact or origin or matches) {
                c.gtk_window_present(u.cast(c.GtkWindow, e.app.window));
                return;
            }
        };
        if (record) |r| if (r.live) {
            self.report(error.LiveSession);
            return;
        };
        manager.createProject(self.app, target);
    }
    pub fn targetFromText(self: *Controller, text: []const u8) ?Target {
        const catalog = self.catalog orelse return null;
        if (text.len == 32) for (catalog.records) |r| {
            if (std.mem.eql(u8, &r.id, text)) return .{ .id = r.id, .updated = r.updated, .reopen = r.reopen };
        };
        const index = std.fmt.parseInt(usize, text, 10) catch return null;
        if (index >= catalog.records.len) return null;
        const r = catalog.records[index];
        return .{ .id = r.id, .updated = r.updated, .reopen = r.reopen };
    }
    pub fn showProjects(self: *Controller, forget: bool) void {
        if (self.closed or self.app.openDialogs() or self.picker != null) return;
        self.picker_kind = if (forget) .forget else .projects;
        self.show_after_list = true;
        self.refresh();
    }
    fn presentProjects(self: *Controller) !void {
        if (self.closed or self.app.openDialogs() or self.picker != null) return;
        var items: [fs.limits.sessions]picker_ui.Item = undefined;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        self.mapping_len = 0;
        if (self.catalog) |catalog| for (catalog.records) |record| {
            const i = self.mapping_len;
            self.mapping[i] = .{ .project = .{ .id = record.id, .updated = record.updated, .reopen = record.reopen } };
            items[i] = .{ .id = i, .label = record.label, .detail = try displayPath(arena.allocator(), record.path orelse "Independent untitled window") };
            self.mapping_len += 1;
        };
        try self.present(if (self.picker_kind == .forget) "Forget Recent Session" else "Recent Projects and Workspaces", "No retained project sessions", items[0..self.mapping_len]);
    }
    pub fn showBuffers(self: *Controller) void {
        if (self.closed or self.app.openDialogs() or self.picker != null) return;
        self.picker_kind = .buffers;
        self.mapping_len = 0;
        var items: [picker_ui.max_items]picker_ui.Item = undefined;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        for (self.app.views.items) |view| {
            if (self.mapping_len == items.len) break;
            const i = self.mapping_len;
            const group = self.app.groups.forPage(view.page).?;
            self.mapping[i] = .{ .buffer = view.id };
            items[i] = .{ .id = i, .label = displayPath(arena.allocator(), if (view.document.path) |p| std.fs.path.basename(p) else "Untitled") catch return, .detail = std.fmt.allocPrint(arena.allocator(), "Group {d} · {s}", .{ group.id, displayPath(arena.allocator(), view.document.path orelse "Unsaved buffer") catch return }) catch return, .dirty = view.document.dirty() };
            self.mapping_len += 1;
        }
        for (self.app.excerpts.items) |pane| {
            if (self.mapping_len == items.len) break;
            const i = self.mapping_len;
            const group = self.app.groups.forPage(pane.editor.root).?;
            self.mapping[i] = .{ .buffer = pane.id };
            items[i] = .{ .id = i, .label = displayPath(arena.allocator(), if (pane.document.path) |p| std.fs.path.basename(p) else "Untitled excerpt") catch return, .detail = std.fmt.allocPrint(arena.allocator(), "Excerpt · Group {d} · {s}", .{ group.id, displayPath(arena.allocator(), pane.document.path orelse "Unsaved buffer") catch return }) catch return, .dirty = pane.document.dirty() };
            self.mapping_len += 1;
        }
        self.present("Open Buffers", "No open buffers", items[0..self.mapping_len]) catch |err| self.report(err);
    }
    fn present(self: *Controller, title: []const u8, empty: []const u8, items: []const picker_ui.Item) !void {
        self.picker = try picker_ui.Picker.create(self.app.window, self, title, empty, items, &activated, &pickerClosed);
        self.app.styleWindow(self.picker.?.window);
        self.app.installTestKeys(self.picker.?.window);
        self.picker.?.show();
    }
    fn inUse(self: *Controller, target: Target) bool {
        if (self.app.manager) |manager| for (manager.entries) |entry| if (entry) |e| {
            const p = &e.app.projects;
            if (p.id) |id| if (sameId(id, target.id)) return true;

            if (p.restore_target) |from| if (p.restoring and sameId(from.id, target.id)) return true;
        };
        return false;
    }
    pub fn requestForget(self: *Controller, target: Target) void {
        if (self.closed or self.app.openDialogs() or self.dialog != null) return;
        var live = self.inUse(target);
        if (self.catalog) |catalog| for (catalog.records) |r| if (sameId(r.id, target.id) and r.live) {
            live = true;
        };
        if (live) {
            self.app.message("Close this live project first. Forget only removes retained sessions, never live documents.");
            return;
        }
        self.forget_target = target;
        const dialog = c.gtk_message_dialog_new(u.cast(c.GtkWindow, self.app.window), c.GTK_DIALOG_MODAL, c.GTK_MESSAGE_WARNING, c.GTK_BUTTONS_NONE, "%s", @as([*:0]const u8, "Forget this retained session?")).?;
        c.gtk_message_dialog_format_secondary_text(u.cast(c.GtkMessageDialog, dialog), "%s", @as([*:0]const u8, "This permanently removes the retained tabs and unsaved text from automatic project history. It does not delete files or the explicit workspace checkpoint. This cannot be undone."));
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Cancel", 0);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Forget Session", 1);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), 0);
        self.dialog = dialog;
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        u.connect(dialog, "response", &forgetResponse, self);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    pub fn confirmForget(self: *Controller, accept: bool) void {
        const dialog = self.dialog orelse return;
        self.dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
        const target = self.forget_target;
        self.forget_target = null;
        if (accept) {
            if (self.inUse(target.?)) {
                self.report(error.LiveSession);
                return;
            }
            self.submit(.forget, target, null) catch |err| self.report(err);
        }
    }
    pub fn freeze(self: *Controller) !void {
        if (self.suppression_pending) return error.StartupMembershipPending;
        if (self.frozen != null or !self.enabled) return;
        if (self.failed_restore_hash) |hash| {
            if (hash == try self.app.projectFingerprint()) return;
        }
        if (self.restoring or self.restore_cleanup or self.retiring) return error.Loading;
        try self.ensureIdentity();
        self.app.checkpoint();
        self.frozen = try session.capture(self.app);
        self.discarded_len = 0;
    }
    pub fn discard(self: *Controller, id: u64) void {
        if (self.frozen == null) return;
        for (self.discarded[0..self.discarded_len]) |old| if (id == old) return;
        if (self.discarded_len < self.discarded.len) {
            self.discarded[self.discarded_len] = id;
            self.discarded_len += 1;
        }
    }
    pub fn cancelClose(self: *Controller) void {
        if (self.frozen) |value| value.deinit();
        self.frozen = null;
        self.discarded_len = 0;
        self.changed();
    }
    /// Keep the pre-prompt layout and selection, but update successfully saved
    /// document baselines and omit explicitly discarded buffers and their views.
    pub fn finishClose(self: *Controller, reopen: bool) !void {
        const frozen = self.frozen orelse return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var docs: std.ArrayList(recovery.Document) = .empty;
        for (self.app.snapshotDocuments()) |live| {
            var found = false;
            for (frozen.value.snapshot.documents) |doc| if (doc.id == live.id) {
                found = true;
                if (doc.revision != live.revision and std.mem.indexOfScalar(u64, self.discarded[0..self.discarded_len], live.id) == null) return error.EditedDuringClose;
                break;
            };
            if (!found) return error.EditedDuringClose;
        }
        for (frozen.value.snapshot.documents) |original| {
            if (std.mem.indexOfScalar(u64, self.discarded[0..self.discarded_len], original.id) != null) continue;
            var doc = original;
            for (self.app.snapshotDocuments()) |live| if (live.id == doc.id and !live.dirty()) {
                doc.path = live.path;
                doc.saved_etag = live.etag;
                doc.dirty = false;
                doc.revision = live.revision;
                doc.bom = live.bom;
                doc.newline = switch (live.newline) {
                    .lf => .lf,
                    .crlf => .crlf,
                    .mixed => .mixed,
                };
                // Editing is blocked during close resolution; a newer revision
                // cancels closing in finishSave instead of losing text.
                break;
            };
            try docs.append(alloc, doc);
        }
        var value = frozen.value;
        value.snapshot.documents = docs.items;
        const owned = try withoutDiscarded(value, self.discarded[0..self.discarded_len]);
        errdefer owned.deinit();
        try self.enqueueSave(owned, reopen, true);
    }
    pub fn closeWithoutSession(self: *Controller) !void {
        try self.submit(.abandon, null, null);
    }
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.picker) |picker| picker.close();
        self.confirmForget(false);
        if (self.prepared) |value| value.deinit();
        self.prepared = null;
        // The release task owns an App hold just like a write. All lease closes
        // happen on the worker after earlier operations have drained.
        self.submit(.release, null, null) catch @panic("Could not queue project lease release");
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(self.job == null and self.queue.items.len == 0);
        std.debug.assert(self.storage.lease == null and self.storage.source_lease == null);
        self.queue.deinit(a);
        if (self.catalog) |*catalog| catalog.deinit();
        if (self.path) |path| a.free(path);
        if (self.frozen) |value| value.deinit();
    }
    fn report(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        std.log.scoped(.projects).err("event=project-session-failed error={s}; retained records are not evicted", .{@errorName(err)});
        if (!self.closed) {
            const text = u.fmt("Automatic project session: {s}. Existing retained sessions are kept; retry from Recent Projects. If the 64-session catalog or storage budget is full, use Forget Recent Session explicitly. Save important documents separately.", .{@errorName(err)});
            defer a.free(text);
            self.app.message(text);
        }
        self.probe();
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const Record = struct { id: []const u8, label: []const u8, source: ?fs.Source, path: ?[]const u8, reopen: bool, updated: i64, live: bool };
        var records: [fs.limits.sessions]Record = undefined;
        var count: usize = 0;
        if (self.catalog) |catalog| for (catalog.records) |*r| {
            records[count] = .{ .id = &r.id, .label = r.label, .source = r.source, .path = r.path, .reopen = r.reopen, .updated = r.updated, .live = r.live };
            count += 1;
        };
        const json = std.json.Stringify.valueAlloc(a, .{ .window = self.app.window_id, .id = if (self.id) |*id| @as(?[]const u8, id) else null, .generation = self.generation, .retiring = self.retiring, .restore_cleanup = self.restore_cleanup, .enabled = self.enabled, .suppression_pending = self.suppression_pending, .busy = self.job != null or self.queue.items.len != 0 or self.restoring, .restoring = self.restoring, .error_name = self.error_name, .captures = self.captures, .writes = self.writes, .frozen = self.frozen != null, .closing_write = self.app.project_close_waiting, .pending = self.queue.items.len, .source = self.source, .path = self.path, .records = records[0..count], .limit = fs.limits.sessions }, .{}) catch return;
        defer a.free(json);
        const line = u.z(json);
        defer a.free(line);
        c.g_print("CORAL_PROJECTS %s\n", line.ptr);
    }
    pub fn pickerProbe(self: *Controller) void {
        if (!hooks) return;
        const picker = self.picker;
        const json = std.json.Stringify.valueAlloc(a, .{ .open = picker != null, .kind = self.picker_kind, .query = if (picker) |p| p.query() else "", .matches = if (picker) |p| p.matchCount() else 0, .visible = if (picker) |p| p.visibleCount() else 0, .selected = if (picker) |p| p.selectedId() else null }, .{}) catch return;
        defer a.free(json);
        const line = u.z(json);
        defer a.free(line);
        c.g_print("CORAL_PICKER %s\n", line.ptr);
    }
};

/// Pure reconciliation of an intended reopen image. Removing a canonical
/// document also removes every full/excerpt presentation, never another tab.
fn withoutDiscarded(original: model.Value, discarded: []const u64) !*model.Owned {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var docs: std.ArrayList(recovery.Document) = .empty;
    var views: std.ArrayList(recovery.View) = .empty;
    const groups = try alloc.dupe(recovery.Group, original.snapshot.groups);
    for (original.snapshot.documents) |doc| if (std.mem.indexOfScalar(u64, discarded, doc.id) == null) try docs.append(alloc, doc);
    for (original.snapshot.views) |view| if (std.mem.indexOfScalar(u64, discarded, view.document_id) == null) try views.append(alloc, view);
    for (groups) |*group| if (group.active_view) |id| {
        var found = false;
        for (views.items) |view| if (view.id == id) {
            found = true;
            break;
        };
        if (!found) {
            group.active_view = null;
            for (views.items) |view| if (std.mem.eql(u8, view.group_path, group.path)) {
                group.active_view = view.id;
                break;
            };
        }
    };
    var value = original;
    value.snapshot.documents = docs.items;
    value.snapshot.views = views.items;
    value.snapshot.groups = groups;
    return model.Owned.create(value);
}

test "automatic quit drops discarded full and excerpt views but retains clean tabs and pane selections" {
    const original: model.Value = .{ .snapshot = .{
        .documents = &.{ .{ .id = 1, .text = "clean", .dirty = false, .path = "/clean.txt" }, .{ .id = 2, .text = "dirty text", .dirty = true } },
        .groups = &.{ .{ .path = "root/0", .active_view = 23 }, .{ .path = "root/1", .active_view = 22 } },
        .views = &.{ .{ .id = 11, .document_id = 1, .group_path = "root/0", .anchor = 1, .cursor = 4 }, .{ .id = 22, .document_id = 2, .group_path = "root/1" }, .{ .id = 23, .document_id = 2, .group_path = "root/0", .excerpt_start = 0, .excerpt_end = 5 } },
        .active_group = "root/1",
    } };
    const value = try withoutDiscarded(original, &.{2});
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 1), value.value.snapshot.documents.len);
    try std.testing.expectEqualStrings("clean", value.value.snapshot.documents[0].text);
    try std.testing.expect(!value.value.snapshot.documents[0].dirty);
    try std.testing.expectEqual(@as(usize, 1), value.value.snapshot.views.len);
    try std.testing.expectEqual(@as(u64, 4), value.value.snapshot.views[0].cursor);
    try std.testing.expectEqual(@as(?u64, 11), value.value.snapshot.groups[0].active_view);
    try std.testing.expect(value.value.snapshot.groups[1].active_view == null);
    try std.testing.expectEqualStrings("root/1", value.value.snapshot.active_group.?);
    try std.testing.expectEqual(@as(usize, 2), original.snapshot.documents.len);
}

/// Worker-exclusive, move-only lease ownership. GTK never touches these fields
/// until all tasks (including the final release task) have drained.
const Storage = struct {
    id: ?fs.Id = null,
    lease: ?fs.Lease = null,
    generation: ?i64 = null,
    retired: bool = false,
    source_lease: ?fs.Lease = null,
    source: ?Target = null,
    clone_published: bool = false,
    source_touched: bool = false,
    fn ensure(self: *Storage, id: fs.Id) !void {
        if (self.id) |old| if (sameId(old, id)) return;
        if (self.lease != null and self.generation != null and !self.retired) return error.UnretiredProject;
        self.releaseCurrent();
        self.lease = try fs.claim(null, id);
        self.id = id;
    }
    fn releaseCurrent(self: *Storage) void {
        if (self.lease) |*lease| lease.deinit();
        self.lease = null;
        self.id = null;
        self.generation = null;
        self.retired = false;
    }
    fn releaseSource(self: *Storage) void {
        if (self.source_lease) |*lease| lease.deinit();
        self.source_lease = null;
        self.source = null;
        self.clone_published = false;
        self.source_touched = false;
    }
    fn selectSource(self: *Storage, target: Target, current_reopen: bool) !void {
        // Called under the source lease. A selected startup member may have
        // been consumed by another process without changing its generation.
        // Only a record selected as closed history may be re-enabled for clone.
        if (target.reopen and !current_reopen) return error.Conflict;
        self.source = target;
        self.source.?.reopen = current_reopen;
    }
    fn abortRestore(self: *Storage) !void {
        if (self.source) |source| {
            if (self.clone_published) try fs.setReopenLeased(null, self.id.?, false, &self.lease.?);
            if (self.source_touched) try fs.setReopenLeased(null, source.id, source.reopen, &self.source_lease.?);
        }
        self.releaseSource();
        self.releaseCurrent();
    }
};

test "consumed startup selection conflicts without arming membership rollback" {
    var storage: Storage = .{};
    const target: Target = .{ .id = @splat('a'), .updated = 7, .reopen = true };
    // Snapshot generations are unchanged when another process consumes reopen.
    try std.testing.expectError(error.Conflict, storage.selectSource(target, false));
    try std.testing.expect(storage.source == null);
    try std.testing.expect(!storage.source_touched and !storage.clone_published);
    // No source membership is restored or otherwise written on failed claim.
    try storage.abortRestore();
    try std.testing.expect(storage.source == null);
}

test "source admission preserves rollback membership and explicit closed recent intent" {
    const id: fs.Id = @splat('b');
    inline for (.{ false, true }) |selected_reopen| {
        inline for (.{ false, true }) |current_reopen| {
            if (selected_reopen and !current_reopen) continue;
            var storage: Storage = .{};
            const target: Target = .{ .id = id, .updated = 9, .reopen = selected_reopen };
            try storage.selectSource(target, current_reopen);
            try std.testing.expectEqual(current_reopen, storage.source.?.reopen);
            try std.testing.expectEqual(target.updated, storage.source.?.updated);
            try std.testing.expectEqual(target.id, storage.source.?.id);
            try std.testing.expect(!storage.source_touched);
            try storage.abortRestore();
        }
    }
}

const Job = struct {
    controller: *Controller,
    kind: Kind,
    id: ?fs.Id = null,
    target: ?Target = null,
    new_id: ?fs.Id = null,
    updated: ?i64 = null,
    value: ?*model.Owned = null,
    catalog: ?fs.Catalog = null,
    reopen: bool = true,
    finalize: bool = false,
    err: ?anyerror = null,
    committed: bool = false,
    delay_us: u64 = 0,
    fn perform(self: *Job) !void {
        const storage = &self.controller.storage;
        switch (self.kind) {
            .list, .startup => self.catalog = try fs.list(null),
            .suppress => {
                var catalog = try fs.list(null);
                defer catalog.deinit();
                for (catalog.records) |record| {
                    if (!record.reopen or record.live) continue;
                    var lease = fs.claim(null, record.id) catch |err| {
                        if (err == error.Busy) continue;
                        return err;
                    };
                    defer lease.deinit();
                    var current = try fs.list(null);
                    defer current.deinit();
                    for (current.records) |r| if (sameId(r.id, record.id) and r.updated == record.updated) {
                        try fs.setReopenLeased(null, r.id, false, &lease);
                        break;
                    };
                }
            },
            .load => {
                if (storage.source_lease == null) {
                    storage.source_lease = try fs.claim(null, self.target.?.id);
                }
                if (storage.source == null) {
                    try storage.selectSource(self.target.?, try self.checkGeneration());
                }
                if (self.value == null) self.value = try fs.load(null, self.target.?.id);
                _ = try self.checkGeneration();
                if (self.new_id == null) self.new_id = try fs.newId();
                try storage.ensure(self.new_id.?);
                if (!storage.source.?.reopen) {
                    fs.setReopenLeased(null, storage.source.?.id, true, &storage.source_lease.?) catch |err| {
                        if (err == error.DurabilityUncertain) storage.source_touched = true;
                        return err;
                    };
                    storage.source_touched = true;
                }
                self.updated = try fs.saveCloneLeased(null, self.new_id.?, self.target.?.id, self.value.?.value, self.target.?.updated, &storage.lease.?, &storage.source_lease.?);
                storage.generation = self.updated;
                storage.clone_published = true;
                storage.source_touched = true;
                self.committed = true;
            },
            .resume_membership => {
                if (storage.generation != null) try fs.setReopenLeased(null, storage.id.?, true, &storage.lease.?);
                storage.retired = false;
            },
            .identity => try storage.ensure(self.id.?),
            .restore_commit => storage.releaseSource(),
            .restore_abort => try storage.abortRestore(),
            .forget => try fs.forgetIfUnchanged(null, self.target.?.id, self.target.?.updated),
            .save, .retire => {
                try storage.ensure(self.id.?);
                self.updated = try fs.saveLeased(null, self.id.?, self.value.?.value, self.reopen, storage.generation, &storage.lease.?);
                storage.generation = self.updated;
                storage.retired = self.kind == .retire;
                self.committed = true;
            },
            .abandon => {
                if (storage.source_lease != null) try storage.abortRestore();
                if (storage.generation != null) try fs.setReopenLeased(null, storage.id.?, false, &storage.lease.?);
                storage.retired = true;
            },
            .release => {
                storage.releaseSource();
                storage.releaseCurrent();
            },
        }
    }
    fn checkGeneration(self: *Job) !bool {
        var catalog = try fs.list(null);
        defer catalog.deinit();
        for (catalog.records) |record| if (sameId(record.id, self.target.?.id)) {
            if (record.updated != self.target.?.updated) return error.Conflict;
            return record.reopen;
        };
        return error.NotFound;
    }
    fn destroy(self: *Job) void {
        if (self.value) |value| value.deinit();
        if (self.catalog) |*catalog| catalog.deinit();
        a.destroy(self);
    }
};
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    if (hooks and job.delay_us != 0) c.g_usleep(@intCast(job.delay_us));
    var attempts: usize = 0;
    while (true) {
        job.perform() catch |err| {
            if (err == error.Busy and attempts < 40) {
                attempts += 1;
                c.g_usleep(25000);
                continue;
            }
            if (err == error.DurabilityUncertain and (job.kind == .save or job.kind == .retire or job.kind == .load)) {
                // Commit may already be visible. Refresh the payload, never
                // blindly retry a collision-checked insert or consumed clone.
                const stored_id = if (job.kind == .load) job.new_id else job.id;
                if (stored_id != null) if (fs.load(null, stored_id.?)) |stored| {
                    defer stored.deinit();
                    const lhs = model.encode(a, stored.value) catch null;
                    defer if (lhs) |bytes| a.free(bytes);
                    const rhs = model.encode(a, job.value.?.value) catch null;
                    defer if (rhs) |bytes| a.free(bytes);
                    if (lhs != null and rhs != null and std.mem.eql(u8, lhs.?, rhs.?)) {
                        if (fs.list(null)) |list| {
                            var catalog = list;
                            defer catalog.deinit();
                            for (catalog.records) |r| if (sameId(r.id, stored_id.?)) {
                                job.updated = r.updated;
                                job.controller.storage.generation = r.updated;
                                job.controller.storage.clone_published = job.kind == .load;
                                if (job.kind == .load) job.controller.storage.source_touched = true;
                                job.committed = true;
                                break;
                            };
                        } else |_| {}
                    }
                } else |_| {};
            }
            job.err = err;
        };
        break;
    }
    c.g_task_return_boolean(task, 1);
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, data.?);
    const self = job.controller;
    _ = c.g_task_propagate_boolean(@ptrCast(result), null);
    self.job = null;
    defer {
        job.destroy();
        self.dispatch();
        self.probe();
        self.app.release();
    }
    if (job.err) |err| {
        self.saved_hash = null;
        if (job.committed and job.kind != .load) acknowledge(self, job);
        self.retry_after = c.g_get_monotonic_time() + 5000000;
        self.changed();
        if (job.kind == .retire) {
            self.retiring = false;
            self.retirement_ready = false;
            self.retirement_error = err;
            if (self.retirement_cancelled) {
                self.retirement_cancelled = false;
                self.retirement_error = null;
                // An uncertain retirement may already have cleared membership.
                self.submit(.resume_membership, null, null) catch |failure| self.report(failure);
            }
        }
        if (job.kind == .load) self.restoreFailed(err) else self.report(err);
        if (job.finalize) self.app.automaticCloseFailed(err);
        if (job.kind == .abandon) {
            self.app.projectCloseCompleted(false);
            self.report(err);
        }
        if (job.kind == .startup and !self.closed) {
            if (self.app.snapshotDocuments().len == 0) _ = self.app.newDocument();
            self.enable();
        }
        return;
    }
    switch (job.kind) {
        .save, .retire, .load, .forget, .suppress => self.error_name = null,
        else => {},
    }
    switch (job.kind) {
        .save, .retire => {
            if (job.kind == .retire) {
                self.retiring = false;
                self.retirement_ready = true;
                if (self.retirement_cancelled) {
                    self.retirement_cancelled = false;
                    self.cancelWorkspaceChange();
                }
            }
            self.writes += 1;
            acknowledge(self, job);
            if (job.finalize) self.app.projectCloseCompleted(true);
        },
        .list, .startup => {
            if (self.catalog) |*catalog| catalog.deinit();
            self.catalog = job.catalog;
            job.catalog = null;
            if (self.closed) return;
            if (job.kind == .startup) {
                self.app.manager.?.restoreStartup(self.app, self.catalog.?.records);
            } else if (self.show_after_list) {
                self.show_after_list = false;
                self.presentProjects() catch |err| self.report(err);
            }
        },
        .load => {
            if (self.closed) return;
            const workspace = job.value.?.value.workspace;
            const path = if (workspace) |w| a.dupe(u8, w.path) catch |err| {
                self.restoreFailed(err);
                return;
            } else null;
            if (self.path) |old| a.free(old);
            self.path = path;
            self.source = if (workspace) |w| w.source else null;
            self.id = job.new_id;
            self.generation = job.updated;
            self.established = true;
            self.prepared = job.value;
            job.value = null;
            self.tryPrepared();
        },
        .restore_commit => {
            self.restore_cleanup = false;
            self.changed();
        },
        .restore_abort => {
            self.restore_cleanup = false;
            self.id = null;
            self.generation = null;
            self.established = false;
            self.source = null;
            if (self.path) |path| a.free(path);
            self.path = null;
            self.saved_hash = null;
        },
        .abandon => self.app.projectCloseCompleted(true),
        .resume_membership, .identity, .release => {},
        .forget => if (!self.closed) self.refresh(),
        .suppress => {
            self.suppression_pending = false;
            self.changed();
        },
    }
}
fn acknowledge(self: *Controller, job: *Job) void {
    if (self.id) |id| if (sameId(id, job.id.?)) {
        self.established = true;
        self.generation = job.updated;
    };
}
fn restored(context: *anyopaque, success: bool) void {
    const self = u.cast(Controller, context);
    self.restoring = false;
    if (!success) {
        self.restoreFailed(error.RestoreFailed);
        return;
    }
    if (self.app.snapshotDocuments().len == 0) _ = self.app.newDocument();
    self.restore_succeeded = true;
    self.restore_cleanup = true;
    self.submit(.restore_commit, null, null) catch |err| self.report(err);
    self.saved_hash = null;
    self.changed();
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    if (self.closed) {
        self.timer = 0;
        return 0;
    }
    self.tryPrepared();
    if (self.restore_cleanup and c.g_get_monotonic_time() >= self.retry_after) self.retryRestoreCleanup();
    if ((self.retirement_ready or self.retiring) and !self.app.browser.loading and !self.app.browser.closing_workspace) self.cancelWorkspaceChange();
    if (self.failed_restore_hash) |old| {
        const current = self.app.projectFingerprint() catch return 1;
        if (old == current) return 1;
        self.failed_restore_hash = null;
        self.changed();
    }
    if (!self.available()) return 1;
    const hash = self.app.projectFingerprint() catch |err| {
        self.report(err);
        return 1;
    };
    if (self.failed_capture_hash == hash) return 1;
    const now = c.g_get_monotonic_time();
    if (self.observed != hash) {
        self.observed = hash;
        if (self.first_change == 0) self.first_change = now;
        self.last_change = now;
    }
    if (self.first_change != 0 and (now - self.last_change >= 1000000 or now - self.first_change >= 5000000)) {
        self.capture(true, false) catch |err| self.report(err);
    }
    return 1;
}
fn activated(context: *anyopaque, id: usize) void {
    const self = u.cast(Controller, context);
    if (id >= self.mapping_len or self.closed) return;
    // Picker invokes on_closed first. Mapping lives in the controller, not in
    // the picker arena or a refreshable catalog; activation never retargets.
    switch (self.mapping[id]) {
        .buffer => |view| self.app.restoreFocus(view),
        .project => |target| if (self.picker_kind == .forget) self.requestForget(target) else self.open(target),
    }
}
fn pickerClosed(context: *anyopaque) void {
    u.cast(Controller, context).picker = null;
}
fn forgetResponse(_: ?*c.GtkDialog, response: c_int, context: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, context.?).confirmForget(response == 1);
}
fn displayPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(path)) return path;
    const out = try allocator.alloc(u8, path.len * 4);
    const hex = "0123456789abcdef";
    for (path, 0..) |byte, i| {
        out[i * 4] = '\\';
        out[i * 4 + 1] = 'x';
        out[i * 4 + 2] = hex[byte >> 4];
        out[i * 4 + 3] = hex[byte & 15];
    }
    return out;
}
fn sameId(lhs: fs.Id, rhs: fs.Id) bool {
    return std.mem.eql(u8, &lhs, &rhs);
}
fn optionalEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs) |l| return if (rhs) |r| std.mem.eql(u8, l, r) else false;
    return rhs == null;
}
