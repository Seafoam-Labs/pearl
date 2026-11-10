//! UI-thread capture and lifecycle adapter for the descriptor-relative store.
//! Filesystem work after startup is confined to GTask workers. Restored paths
//! are deliberately never rebound: Save As is the user's conflict decision.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const Document = @import("../document.zig").Document;
const groups = @import("../editor_groups.zig");
const recovery = @import("recovery.zig");
const offsets = @import("recovery_offsets.zig");
const scroll = @import("recovery_scroll.zig");
const hooks = @import("build_options").test_hooks;
const log = std.log.scoped(.recovery);

pub const Controller = struct {
    application: *c.GApplication,
    app: ?*App = null,
    store: ?*recovery.Store = null,
    discovery: ?recovery.Discovery = null,
    next: usize = 0,
    startup_error: ?anyerror = null,
    timer: c_uint = 0,
    first_change: i64 = 0,
    closing: bool = false,
    resolved: bool = false,
    saves: usize = 0,
    holds: usize = 0,
    opening: bool = false,
    failed: bool = false,
    dialog: ?u.W = null,
    claim: ?*Work = null,
    transferred: bool = false,
    awaiting_checkpoint: bool = false,
    ready: *const fn (*App) void,

    /// Called before App.create presents the window. No implicit mkdir of state
    /// home, canonicalization, or fallback to an insecure temporary directory.
    pub fn init(application: *c.GApplication, ready: *const fn (*App) void) Controller {
        var self: Controller = .{ .application = application, .ready = ready };
        self.discovery = recovery.discover(null) catch |err| blk: {
            self.startup_error = err;
            break :blk null;
        };
        self.store = recovery.Store.open(.{ .before_checkpoint_commit = if (hooks) &testBeforeCommit else null }) catch |err| blk: {
            self.startup_error = err;
            break :blk null;
        };
        return self;
    }

    fn hold(self: *Controller) void {
        self.holds += 1;
        c.g_application_hold(self.application);
    }
    fn release(self: *Controller) void {
        std.debug.assert(self.holds > 0);
        self.holds -= 1;
        c.g_application_release(self.application);
    }
    pub fn drained(self: *Controller) bool {
        return self.closing and self.holds == 0 and !self.opening and self.store == null and self.claim == null and self.saves == 0;
    }
    /// Only process startup discovers candidates. Later windows open a distinct
    /// journal off GTK and never rediscover journals the user kept for later.
    pub fn attachNew(self: *Controller, app: *App) void {
        self.app = app;
        app.recovery_context = self;
        app.recovery_checkpoint = &changed;
        u.connect(self.application, "window-removed", &windowRemoved, self);
        self.opening = true;
        // New project restores wait for their independent recovery journal.
        // No worker-owned store is inspected while initialization is running.
        app.recovery_suspended = true;
        self.hold();
        const task = c.g_task_new(null, null, &opened, self).?;
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &openWorker);
        c.g_object_unref(task);
    }
    pub fn attach(self: *Controller, app: *App) void {
        self.app = app;
        app.recovery_context = self;
        app.recovery_checkpoint = &changed;
        app.recovery_suspended = true;
        u.connect(self.application, "window-removed", &windowRemoved, self);
        if (self.startup_error) |err| self.report(err);
        self.nextCandidate();
    }

    pub fn deinit(self: *Controller) void {
        // All worker callbacks own application holds; g_application_run must
        // remain alive until they finish, including coalesced save callbacks.
        std.debug.assert(self.drained());
        if (self.discovery) |list| list.deinit();
        _ = c.g_signal_handlers_disconnect_matched(self.application, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
    }

    fn report(self: *Controller, err: anyerror) void {
        self.failed = true;
        log.err("event=recovery-failed error={s}; recovery journal retained", .{@errorName(err)});
        const text = switch (err) {
            error.MissingStateHome => "Recovery is unavailable: the state-home directory must already exist. Create XDG_STATE_HOME (or ~/.local/state), owned by you and not writable by other users, then restart Coral.",
            error.UnsafeDirectory => "Recovery is unavailable: the state directory is unsafe or contains a symlink. Use a real directory owned by you, not writable by other users. Existing recovery data has been kept.",
            error.TooLarge => "Recovery checkpoint rejected: limit is 4 MiB per document, 8 MiB total, 128 documents, 64 groups and 256 views. Save your work explicitly; the previous recovery checkpoint has been kept.",

            error.UnsupportedLayout => "This recovery layout is not supported by this version of Coral. The original recovery data has been kept.",
            error.CorruptManifest, error.UnsupportedVersion, error.InvalidUtf8, error.InvalidSnapshot => "Recovery data is corrupt or unsupported. It has been kept. Choose Keep for later, or explicitly Discard it.",
            error.DurabilityUncertain => "Recovery could not confirm disk durability. Save your work explicitly; the recovery journal has been kept.",
            else => "Recovery failed. Save your work explicitly; existing recovery data has been kept. See the recovery error in the application log.",
        };
        if (self.app) |app| app.message(text);
        if (hooks) c.g_print("CORAL_RECOVERY_ERROR %s\n", @errorName(err).ptr);
    }

    fn nextCandidate(self: *Controller) void {
        if (self.closing) return;
        if (self.discovery) |list| {
            while (self.next < list.entries.len) {
                const candidate = list.entries[self.next];
                self.next += 1;
                if (candidate.state == .unsafe) {
                    self.report(error.UnsafeDirectory);
                    continue;
                }
                const work = a.create(Work) catch {
                    self.report(error.OutOfMemory);
                    break;
                };
                work.* = .{ .controller = self, .id = candidate.id };
                self.claim = work;

                self.run(work, .load);
                return;
            }
        }
        if (self.app) |app| {
            app.recovery_suspended = false;
            self.ready(app);
            if (self.startup_error) |err| self.report(err);
            app.checkpoint();
        }
    }

    fn prompt(self: *Controller, transferred: bool) void {
        const app = self.app orelse return;
        self.transferred = transferred;
        // Only an actual decision suppresses automatic reopening. Empty journals
        // and failed/contended claims never reach this presentation boundary.
        app.recovery_claimed = true;
        const dialog = c.gtk_dialog_new().?;
        _ = c.g_object_ref_sink(dialog);
        self.dialog = dialog;
        c.gtk_window_set_application(u.cast(c.GtkWindow, dialog), u.cast(c.GtkApplication, self.application));
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), if (transferred) "Recovery copied safely" else "Recover interrupted session");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, app.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        app.styleWindow(dialog);
        c.gtk_window_set_destroy_with_parent(u.cast(c.GtkWindow, dialog), 1);
        const label = u.label(if (transferred)
            "The recovered unsaved copies have a durable checkpoint in this session. Keep the original recovery for later, or explicitly discard it?"
        else if (self.claim.?.snapshot != null)
            "An interrupted session was found. Restore its documents as unsaved copies (original files are never overwritten), keep it for later, or discard its recovery data?"
        else
            "This session could not be read. Keep the recovery data for later, or explicitly discard it? No source files will be changed.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        c.gtk_widget_set_size_request(label, 440, -1);
        u.margin(label, 18);
        u.append(c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?, label);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Keep for later", 0);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Discard", 2);
        if (!transferred and self.claim.?.snapshot != null) _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Restore", 1);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), 0);
        u.connect(dialog, "response", &response, self);
        if (hooks) {
            const keys = c.gtk_event_controller_key_new().?;
            c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
            u.connect(keys, "key-pressed", &testKey, self);
            c.gtk_widget_add_controller(dialog, keys);
            c.g_print("CORAL_RECOVERY_PROMPT %s\n", @as([*:0]const u8, if (transferred) "transferred" else if (self.claim.?.snapshot != null) "restore" else "unreadable"));
        }
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }

    fn run(self: *Controller, work: *Work, operation: Operation) void {
        work.operation = operation;
        work.err = null;
        self.hold();
        const task = c.g_task_new(null, null, &workDone, work).?;
        c.g_task_set_task_data(task, work, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }

    /// GTK-thread snapshot shared with explicit session checkpoints. No I/O.
    pub fn captureApp(app: *App) !*recovery.OwnedSnapshot {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const source = app.snapshotDocuments();
        if (source.len > recovery.limits.documents) return error.TooLarge;
        const docs = try alloc.alloc(recovery.Document, source.len);
        var bytes: usize = 0;
        for (source, docs) |doc, *out| {
            if (doc.loading or doc.pending != null) return error.Loading;
            // A cheap character bound prevents copying an arbitrarily large
            // buffer; the exact UTF-8 byte caps are checked before ownership.
            if (c.gtk_text_buffer_get_char_count(doc.buffer) > recovery.limits.document_bytes) return error.TooLarge;
            const text = u.bufferText(doc.buffer);
            defer a.free(text);
            bytes += text.len;
            if (text.len > recovery.limits.document_bytes or bytes > recovery.limits.text_bytes) return error.TooLarge;
            out.* = .{ .id = doc.id, .text = try alloc.dupe(u8, text), .path = doc.path, .saved_etag = doc.etag, .dirty = doc.dirty(), .bom = doc.bom, .newline = switch (doc.newline) {
                .lf => .lf,
                .crlf => .crlf,
                .mixed => .mixed,
            }, .revision = doc.revision };
        }
        const source_groups = try app.snapshotGroups(alloc);
        const source_views = try app.snapshotViews(alloc);
        if (source_groups.len > recovery.limits.groups or source_views.len > recovery.limits.views) return error.TooLarge;
        const layout = try alloc.alloc(recovery.Group, source_groups.len);
        const views = try alloc.alloc(recovery.View, source_views.len);
        // Wire order is tab order, not the order canonical views were created.
        std.mem.sort(groups.ViewState, source_views, {}, struct {
            fn less(_: void, lhs: groups.ViewState, rhs: groups.ViewState) bool {
                return if (lhs.group_id == rhs.group_id) lhs.page < rhs.page else lhs.group_id < rhs.group_id;
            }
        }.less);
        var active: ?[]const u8 = null;
        for (source_groups, layout, 0..) |group, *out, i| {
            out.* = .{ .path = try std.fmt.allocPrint(alloc, "root/{d}", .{i}) };
            if (group.active) active = out.path;
            for (source_views) |view| if (view.group_id == group.id and view.selected) {
                out.active_view = view.id;
            };
        }
        for (source_views, views) |view, *out| {
            var group_path: []const u8 = undefined;
            for (source_groups, layout) |group, wire| if (group.id == view.group_id) {
                group_path = wire.path;
                break;
            };
            var text: []const u8 = undefined;
            for (docs) |doc| if (doc.id == view.document_id) {
                text = doc.text;
                break;
            };
            var position: ?scroll.Position = null;
            for (app.views.items) |native| if (native.id == view.id) {
                position = scroll.capture(native.widget, view.scroll_x, view.scroll_y);
                break;
            };
            for (app.excerpts.items) |pane| if (pane.id == view.id) {
                position = scroll.capture(pane.editor.widget, view.scroll_x, view.scroll_y);
                break;
            };
            const captured = position orelse return error.InvalidSnapshot;
            out.* = .{ .id = view.id, .document_id = view.document_id, .group_path = group_path, .scroll_line = captured.line, .scroll_x = captured.x, .excerpt_start = view.excerpt_start, .excerpt_end = view.excerpt_end };
            const presented = try @import("recovery_model.zig").presentationText(text, out.*);
            out.anchor = offsets.byteAtChar(presented, view.bound);
            out.cursor = offsets.byteAtChar(presented, view.insertion);
        }
        return recovery.OwnedSnapshot.create(.{ .documents = docs, .groups = layout, .views = views, .active_group = active });
    }

    fn save(self: *Controller) void {
        if (self.closing or self.opening or self.store == null) return;
        const snapshot = captureApp(self.app orelse return) catch |err| {
            if (err == error.Loading) {
                self.timer = c.g_timeout_add(250, &debounced, self);
                return;
            }
            self.report(err);
            if (self.awaiting_checkpoint) {
                self.awaiting_checkpoint = false;
                self.run(self.claim.?, .release);
            }
            return;
        };
        self.hold();
        self.saves += 1;
        self.store.?.saveAsync(snapshot, &saved, self) catch |err| {
            self.saves -= 1;
            snapshot.deinit();
            self.release();
            self.report(err);
            if (self.awaiting_checkpoint) {
                self.awaiting_checkpoint = false;
                self.run(self.claim.?, .release);
            }
        };
    }

    fn finish(self: *Controller, resolved: bool) void {
        if (self.closing) return;
        self.closing = true;
        self.resolved = resolved;
        if (self.timer != 0) {
            _ = c.g_source_remove(self.timer);
            self.timer = 0;
        }
        // An earlier failed write may still have an undelivered callback while
        // the latest write succeeds. Do not authorize removal before observing
        // every result. Each accepted save holds the application across this gap.
        if (self.saves == 0 and !self.opening) self.closeStore();
    }

    fn closeStore(self: *Controller) void {
        if (self.store) |store| {
            self.hold();
            store.closeAsync(if (self.resolved and !self.failed) .remove_after_resolution else .keep, &closed, self) catch |err| {
                // Allocation failure cannot be recovered by destroying an open
                // Store. Keep its lock until process exit, but do not hang exit.
                self.release();
                self.report(err);
                self.store = null;
            };
        }
    }

    fn restore(self: *Controller) !void {
        const app = self.app.?;
        const snapshot = self.claim.?.snapshot.?.value;
        try restoreApp(app, snapshot, null);
        app.message("Recovered as unsaved copies. Original files were not changed; use Save As to choose where to save. The original recovery is retained until you explicitly discard it.");
    }

    /// Optional document states are supplied only by the explicit session verifier.
    /// Recovery always passes null and continues restoring pathless dirty copies.
    pub fn restoreApp(app: *App, snapshot: recovery.Snapshot, states: ?[]const App.RestoreDocument) !void {
        if (states) |items| if (items.len != snapshot.documents.len) return error.InvalidSnapshot;
        // Validate all semantic constraints before changing the live workspace.
        try offsets.validateRestore(snapshot);
        const document_map = try a.alloc(*Document, snapshot.documents.len);
        defer a.free(document_map);
        const group_map = try a.alloc(u64, snapshot.groups.len);
        defer a.free(group_map);
        const view_map = try a.alloc(u64, snapshot.views.len);
        defer a.free(view_map);
        const suspended = app.recovery_suspended;
        app.recovery_suspended = true;
        defer app.recovery_suspended = suspended;
        for (snapshot.documents, document_map, 0..) |doc, *out, index| {
            out.* = try app.restoreDocument(if (states) |items| items[index] else .{ .text = doc.text, .dirty = true, .bom = doc.bom, .newline = switch (doc.newline) {
                .lf => .lf,
                .crlf => .crlf,
                .mixed => .mixed,
                .cr => return error.UnsupportedLineEnding,
            } });
        }
        for (snapshot.groups, group_map, 0..) |_, *out, i| {
            out.* = if (i == 0 and app.snapshotDocuments().len == snapshot.documents.len) app.activeGroupId() else try app.createGroup();
        }
        for (snapshot.views, view_map) |view, *out| {
            var document: *Document = undefined;
            var text: []const u8 = undefined;
            for (snapshot.documents, document_map) |doc, mapped| if (doc.id == view.document_id) {
                document = mapped;
                text = doc.text;
                break;
            };
            var group_id: u64 = undefined;
            for (snapshot.groups, group_map) |group, mapped| if (std.mem.eql(u8, group.path, view.group_path)) {
                group_id = mapped;
                break;
            };
            const presented = try @import("recovery_model.zig").presentationText(text, view);
            out.* = try app.restoreView(document, group_id, .{ .id = view.id, .document_id = document.id, .group_id = group_id, .page = 0, .active = false, .selected = false, .insertion = try offsets.charAtByte(presented, view.cursor), .bound = try offsets.charAtByte(presented, view.anchor), .scroll_x = view.scroll_x, .scroll_y = 0, .excerpt_start = if (view.excerpt_start) |start| @intCast(start) else null, .excerpt_end = if (view.excerpt_end) |end| @intCast(end) else null });
            try scroll.restore(app.activeWidget().?, .{ .line = view.scroll_line, .x = view.scroll_x });
        }
        for (snapshot.groups) |group| if (group.active_view) |id| {
            for (snapshot.views, view_map) |view, mapped| if (view.id == id) {
                app.restoreFocus(mapped);
                break;
            };
        };
        if (snapshot.active_group) |path| for (snapshot.groups, group_map) |group, mapped| {
            if (std.mem.eql(u8, group.path, path)) {
                app.focusGroup(mapped);
                break;
            }
        };
    }
};

fn openWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    // GTK does not access store/startup_error until opening completes.
    self.store = recovery.Store.open(.{ .before_checkpoint_commit = if (hooks) &testBeforeCommit else null }) catch |err| blk: {
        self.startup_error = err;
        break :blk null;
    };
    c.g_task_return_boolean(task, 1);
}
fn opened(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    defer self.release();
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    self.opening = false;
    if (self.closing) {
        if (self.startup_error) |err| self.report(err);
        self.closeStore();
    } else {
        if (self.startup_error) |err| self.report(err);
        if (self.app) |app| {
            app.recovery_suspended = false;
            self.ready(app);
            app.checkpoint();
        }
    }
}
fn changed(data: ?*anyopaque, app: *App) void {
    const self = u.cast(Controller, data.?);
    if (self.closing or self.opening) return;
    if (hooks) app.test_checkpoint_count += 1;
    // App emits its final synchronous observer notification before destroying
    // the window, after every canonical document was saved/discarded/closed.
    if (app.snapshotDocuments().len == 0) {
        // Automatic startup may be loading a catalog or a prepared snapshot.
        // An empty intermediate window is not a resolved recovery journal.
        if (app.quitting or app.closing) self.finish(true);
        return;
    }
    if (self.store == null) return;
    const now = c.g_get_monotonic_time();
    if (self.first_change == 0) self.first_change = now;
    if (self.timer != 0) _ = c.g_source_remove(self.timer);
    // Trailing-edge debounce with a two-second ceiling under continuous typing.
    self.timer = c.g_timeout_add(if (now - self.first_change >= 2_000_000) 1 else 350, &debounced, self);
}
fn debounced(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    self.timer = 0;
    self.first_change = 0;
    self.save();
    return 0;
}
fn saved(data: ?*anyopaque, result: recovery.Result) void {
    const self = u.cast(Controller, data.?);
    defer {
        self.saves -= 1;
        if (self.closing and self.saves == 0) self.closeStore();
        self.release();
    }
    switch (result) {
        .checkpoint => |status| {
            if (status != .durable) {
                self.report(error.DurabilityUncertain);
            } else {
                if (hooks) c.g_print("CORAL_RECOVERY_DURABLE\n");
                if (self.awaiting_checkpoint and !self.closing) {
                    self.awaiting_checkpoint = false;
                    self.prompt(true);
                }
                return;
            }
        },
        .failed => |err| self.report(err),
        .coalesced => return,
        .closed => unreachable,
    }
    if (self.awaiting_checkpoint) {
        self.awaiting_checkpoint = false;
        self.run(self.claim.?, .release);
    }
}
fn closed(data: ?*anyopaque, result: recovery.Result) void {
    const self = u.cast(Controller, data.?);
    defer self.release();
    if (result == .failed) self.report(result.failed);
    self.store.?.destroy();
    self.store = null;
    if (hooks) c.g_print("CORAL_RECOVERY_CLOSED\n");
}
fn windowRemoved(_: ?*c.GtkApplication, window: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    const app = self.app orelse return;
    if (window != u.cast(c.GtkWindow, app.window)) return;
    self.app = null;
    app.recovery_context = null;
    app.recovery_checkpoint = null;
    self.finish(false);
    if (self.dialog) |dialog| {
        self.dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
        c.g_object_unref(dialog);
        if (self.claim) |work| self.run(work, .release);
    } else if (self.awaiting_checkpoint) {
        self.awaiting_checkpoint = false;
        if (self.claim) |work| self.run(work, .release);
    }
}
fn response(_: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    const dialog = self.dialog orelse return;
    self.dialog = null;
    c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    c.g_object_unref(dialog);
    const work = self.claim.?;
    if (id == 1 and !self.transferred and work.snapshot != null and self.store != null) {
        self.restore() catch |err| {
            self.report(err);
            self.run(work, .release);
            return;
        };
        self.awaiting_checkpoint = true;
        self.save();
    } else {
        if (id == 1 and self.store == null) self.report(error.RecoveryUnavailable);
        self.run(work, if (id == 2) .discard else .release);
    }
}
fn testKey(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, _: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    if (!hooks) return 0;
    const self = u.cast(Controller, data.?);
    const id: c_int = switch (key) {
        c.GDK_KEY_F8 => 1,
        c.GDK_KEY_F9 => 0,
        c.GDK_KEY_F10 => 2,
        else => return 0,
    };
    if (self.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), id);
    return 1;
}
fn testBeforeCommit() void {
    if (!hooks) return;
    const gate = c.g_getenv("CORAL_TEST_RECOVERY_PAUSE");
    if (gate == null or c.g_file_test(gate, c.G_FILE_TEST_EXISTS) == 0) return;
    c.g_print("CORAL_RECOVERY_BEFORE_COMMIT\n");
    // Bounded even if a failed test forgets to remove its gate. This never runs
    // in production builds and never blocks the GTK thread.
    for (0..1000) |_| {
        if (c.g_file_test(gate, c.G_FILE_TEST_EXISTS) == 0) break;
        c.g_usleep(10_000);
    }
}
const Operation = enum { load, release, discard };
const Work = struct {
    controller: *Controller,
    id: recovery.SessionId,
    operation: Operation = .load,
    journal: ?recovery.Claim = null,
    snapshot: ?*recovery.OwnedSnapshot = null,
    err: ?anyerror = null,
};
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
    const work = u.cast(Work, data.?);
    perform(work) catch |err| {
        work.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn perform(work: *Work) !void {
    switch (work.operation) {
        .load => {
            work.journal = try recovery.Claim.claim(null, work.id);
            if (try work.journal.?.removeIfEmpty()) {
                work.journal.?.release();
                work.journal = null;
                return;
            }
            work.snapshot = try work.journal.?.load();
        },
        .release, .discard => {
            defer if (work.journal) |*journal| {
                journal.release();
                work.journal = null;
            };
            if (work.snapshot) |snapshot| {
                snapshot.deinit();
                work.snapshot = null;
            }
            if (work.operation == .discard) if (work.journal) |*journal| try journal.discard(.user_approved);
        },
    }
}
fn workDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const work = u.cast(Work, data.?);
    const self = work.controller;
    defer self.release();
    _ = c.g_task_propagate_boolean(@ptrCast(result), null);
    if (work.err) |err| self.report(err);
    if (work.operation == .load and work.journal != null) {
        if (self.closing) self.run(work, .release) else self.prompt(false);
        return;
    }
    self.claim = null;
    a.destroy(work);
    self.nextCandidate();
}
