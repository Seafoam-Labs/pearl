//! Explicit, single-slot workspace checkpoints, independent of crash recovery.
//! No startup restore or quit-time save. One operation owns an application hold
//! until its worker and (for restore) normal workspace-load callback are reaped.
//! Missing manifests abort restore with saved-root diagnostics; saved roots are
//! not a fallback manifest. Missing folders stay unavailable in the normal model.
//! Restore never creates workspace directories or imports trust from the slot.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const model = @import("session_model.zig");
const fs = @import("session_fs.zig");
const recovery = @import("recovery_model.zig");
const snapshots = @import("recovery_controller.zig").Controller;
const identity = @import("identity.zig");
const codec = @import("../platform/codec.zig");
const hooks = @import("build_options").test_hooks;

pub const Operation = enum { save, restore };
const Verification = enum { copy, verified, conflict, unavailable };
pub const State = struct {
    busy: bool = false,
    operation: ?Operation = null,
    status: enum { idle, running, saved, restored, failed, stale } = .idle,
    error_name: ?[]const u8 = null,
    documents: usize = 0,
    groups: usize = 0,
    views: usize = 0,
    bound: usize = 0,
    copies: usize = 0,
    conflicts: usize = 0,
    unavailable: usize = 0,
    unavailable_roots: usize = 0,
};

pub const Controller = struct {
    app: *App,
    work: ?*Work = null,
    closed: bool = false,
    state: State = .{},
    test_next_delay_us: u64 = 0,

    pub fn shutdown(self: *Controller) void {
        // Do not delete, replace, or save the explicit checkpoint on close.
        self.closed = true;
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(self.work == null);
    }
    pub fn testState(self: *const Controller) State {
        var state = self.state;
        state.busy = self.work != null;
        return state;
    }
    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const json = std.json.Stringify.valueAlloc(a, self.testState(), .{}) catch return;
        defer a.free(json);
        const line = u.z(json);
        defer a.free(line);
        c.g_print("CORAL_SESSION %s\n", line.ptr);
    }
    fn ready(self: *Controller, operation: Operation) !void {
        const app = self.app;
        if (self.closed or app.closing or app.quitting) return error.Closing;
        if (app.recovery_suspended or app.dialog != null or app.closing_group != null or
            app.browser.loading or app.browser.choosing or app.browser.hasPendingFiles() or
            @import("../editor/transactions.zig").isApplying() or app.history.active) return error.Loading;
        if (operation == .restore and app.browser.model != null) return error.ActiveWorkspace;
        for (app.snapshotDocuments()) |doc| if (doc.busy or doc.pending != null) return error.Loading;
    }
    pub fn start(self: *Controller, operation: Operation) void {
        if (self.work != null) {
            if (!self.closed) self.app.message("A workspace session operation is already running. Wait for it to finish.");
            self.probe();
            return;
        }
        self.state = .{ .operation = operation, .status = .running };
        self.begin(operation) catch |err| self.report(err, null);
    }
    fn begin(self: *Controller, operation: Operation) !void {
        try self.ready(operation);
        const work = try a.create(Work);
        errdefer a.destroy(work);
        work.* = .{ .controller = self, .operation = operation, .request = self.app.browser.requests.capture().?, .document_token = self.app.workspace.capture().?, .delay_us = if (hooks) self.test_next_delay_us else 0 };
        self.test_next_delay_us = 0;
        if (operation == .save) {
            // Flush presentation projections exactly as normal recovery does.
            self.app.checkpoint();
            const snapshot = try snapshots.captureApp(self.app);
            defer snapshot.deinit();
            var roots: std.ArrayList(model.Root) = .empty;
            defer roots.deinit(a);
            var workspace: ?model.Workspace = null;
            if (self.app.browser.model) |*current| {
                for (current.roots) |root| try roots.append(a, .{ .path = root.lexical_path, .name = root.display_name });
                workspace = .{ .source = if (current.manifest_path != null) .manifest else .folder, .path = current.manifest_path orelse current.roots[0].lexical_path, .roots = roots.items };
            }
            work.value = try model.Owned.create(.{ .snapshot = snapshot.value, .workspace = workspace });
        }
        self.work = work;
        c.g_application_hold(u.cast(c.GApplication, self.app.application));
        const task = c.g_task_new(null, null, &done, work).?;
        c.g_task_set_task_data(task, work, null);
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
        self.app.message(if (operation == .save) "Saving explicit workspace session…" else "Loading explicit workspace session… Existing documents will be kept.");
    }
    fn accepts(self: *Controller, work: *Work) bool {
        return !self.closed and !self.app.closing and !self.app.quitting and
            self.app.workspace.accepts(work.document_token) and self.app.browser.requests.accepts(work.request);
    }
    fn reap(self: *Controller, work: *Work) void {
        if (work.value) |value| value.deinit();
        self.work = null;
        a.destroy(work);
        self.probe();
        c.g_application_release(u.cast(c.GApplication, self.app.application));
    }
    fn report(self: *Controller, err: anyerror, workspace: ?model.Workspace) void {
        self.state.status = if (err == error.StaleWorkspace or err == error.Closing) .stale else .failed;
        self.state.error_name = @errorName(err);
        std.log.scoped(.session).warn("event=session-failed error={s}", .{@errorName(err)});
        if (!self.closed and !self.app.closing) {
            const explanation = switch (err) {
                error.ActiveWorkspace => "Close the active workspace first (documents are kept), then explicitly Restore Workspace Session. No workspace was replaced.",
                error.Loading => "Finish startup recovery, pending file/workspace operations and dialogs before saving or restoring a workspace session.",
                error.NotFound => "No readable saved workspace session or workspace manifest was found. The checkpoint is not discarded.",
                error.Busy => "The workspace session slot or workspace loader is busy. Retry after the other operation finishes.",
                error.DurabilityUncertain => "Workspace session durability could not be confirmed. The slot may contain the new checkpoint; do not assume the previous checkpoint is intact. Save documents explicitly.",
                error.TooLarge => "Workspace session rejected: existing plus restored state must fit 128 documents, 64 groups, 256 views, 4 MiB per document and 8 MiB of text. Existing documents are kept.",
                error.StaleWorkspace, error.Closing => "Workspace changed or closed while the session operation was running. Its completion was not applied to this workspace.",
                else => "Workspace session could not be saved or restored safely. Existing documents and the explicit checkpoint are kept; see the error below.",
            };
            const roots = if (workspace) |value| std.json.Stringify.valueAlloc(a, value.roots, .{}) catch null else null;
            defer if (roots) |text| a.free(text);
            const text = u.fmt("{s}\nError: {s}.{s}{s}", .{ explanation, @errorName(err), if (workspace != null) "\nSaved roots (no fallback workspace or directories are created): " else "", roots orelse "" });
            defer a.free(text);
            self.app.message(text);
        }
        if (self.work == null) self.probe();
    }
    fn preflight(self: *Controller, snapshot: recovery.Snapshot) !void {
        try @import("recovery_offsets.zig").validateRestore(snapshot);
        const existing = try snapshots.captureApp(self.app);
        defer existing.deinit();
        const current = existing.value;
        if (current.documents.len + snapshot.documents.len > recovery.limits.documents or
            current.groups.len + snapshot.groups.len > recovery.limits.groups or
            current.views.len + snapshot.views.len > recovery.limits.views) return error.TooLarge;
        var bytes: usize = 0;
        for (current.documents) |doc| bytes += doc.text.len;
        for (snapshot.documents) |doc| bytes += doc.text.len;
        if (bytes > recovery.limits.text_bytes) return error.TooLarge;
    }
    fn restore(self: *Controller, work: *Work) !void {
        const app = self.app;
        // Workspace loading is now finished; recheck document operations/caps
        // because users may have edited or opened documents while the worker ran.
        try self.ready(.save);
        const value = work.value.?.value;
        const snapshot = value.snapshot;
        try self.preflight(snapshot);
        const states = try a.alloc(App.RestoreDocument, snapshot.documents.len);
        defer a.free(states);
        self.state.documents = snapshot.documents.len;
        self.state.groups = snapshot.groups.len;
        self.state.views = snapshot.views.len;
        for (snapshot.documents, states, 0..) |doc, *state, i| {
            var verification = work.verification[i];
            if (verification == .verified) {
                if (app.documents.findPath(doc.path.?) != null) verification = .conflict;
                for (states[0..i]) |previous| if (previous.path) |path| {
                    if (std.mem.eql(u8, path, doc.path.?)) verification = .conflict;
                };
            }
            const bound = verification == .verified;
            state.* = .{ .text = doc.text, .path = if (bound) doc.path else null, .etag = if (bound) doc.saved_etag else null, .dirty = !bound, .bom = doc.bom, .newline = switch (doc.newline) {
                .lf => .lf,
                .crlf => .crlf,
                .mixed => .mixed,
                .cr => return error.UnsupportedLineEnding,
            }, .external_changed = !bound and doc.path != null };
            if (bound) self.state.bound += 1 else self.state.copies += 1;
            if (verification == .conflict) self.state.conflicts += 1;
            if (verification == .unavailable) self.state.unavailable += 1;
        }
        // Prepare diagnostics before committing documents. A formatting failure
        // must never turn an otherwise successful restore into a rollback.
        if (app.browser.model) |*current| for (current.roots) |root| {
            if (root.availability != .available) self.state.unavailable_roots += 1;
        };
        const roots = if (value.workspace) |workspace| try std.json.Stringify.valueAlloc(a, workspace.roots, .{}) else null;
        defer if (roots) |text| a.free(text);
        const text = try std.fmt.allocPrint(a, "Workspace session restored: {d} verified clean files, {d} unsaved copies ({d} conflicts, {d} unavailable files). Existing documents kept; no files written. Copies require Save As. {d} unavailable roots.{s}{s}", .{ self.state.bound, self.state.copies, self.state.conflicts, self.state.unavailable, self.state.unavailable_roots, if (self.state.unavailable_roots != 0) " Saved roots: " else "", if (self.state.unavailable_roots != 0) roots orelse "" else "" });
        defer a.free(text);
        {
            const documents_before = app.snapshotDocuments().len;
            const groups_before = app.groups.items.items.len;
            const focus_before = app.activeViewId();
            errdefer app.rollbackSessionRestore(documents_before, groups_before, focus_before);
            try snapshots.restoreApp(app, snapshot, states);
        }
        app.scheduleCheckpoint(); // crash recovery only, never the explicit slot
        self.state.status = .restored;
        app.message(text);
    }
};

const Work = struct {
    controller: *Controller,
    operation: Operation,
    request: identity.Token,
    document_token: identity.Token,
    value: ?*model.Owned = null,
    verification: [recovery.limits.documents]Verification = @splat(.copy),
    err: ?anyerror = null,
    delay_us: u64 = 0,
};

fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
    const work = u.cast(Work, data.?);
    if (hooks and work.delay_us != 0) c.g_usleep(@intCast(work.delay_us));
    perform(work) catch |err| {
        work.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn perform(work: *Work) !void {
    switch (work.operation) {
        .save => try fs.save(null, work.value.?.value),
        .restore => {
            work.value = try fs.load(null);
            const snapshot = work.value.?.value.snapshot;
            try @import("recovery_offsets.zig").validateRestore(snapshot);
            for (snapshot.documents, 0..) |doc, i| {
                if (doc.dirty or doc.path == null) continue;
                work.verification[i] = verify(doc) catch .unavailable;
            }
        },
    }
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const work = u.cast(Work, data.?);
    const self = work.controller;
    _ = c.g_task_propagate_boolean(@ptrCast(result), null);
    var retained = false;
    defer if (!retained) self.reap(work);
    if (!self.accepts(work)) {
        self.report(error.StaleWorkspace, null);
        return;
    }
    if (work.err) |err| {
        self.report(err, null);
        return;
    }
    if (work.operation == .save) {
        self.state.status = .saved;
        self.state.documents = work.value.?.value.snapshot.documents.len;
        self.state.groups = work.value.?.value.snapshot.groups.len;
        self.state.views = work.value.?.value.snapshot.views.len;
        self.app.message("Workspace session saved explicitly. It survives graceful exit; later edits and Discard do not replace it. Restore Workspace Session is always explicit.");
        return;
    }
    self.ready(.restore) catch |err| {
        self.report(err, null);
        return;
    };
    const value = work.value.?.value;
    self.preflight(value.snapshot) catch |err| {
        self.report(err, value.workspace);
        return;
    };
    if (value.workspace) |workspace| {
        work.request = self.app.browser.loadSession(if (workspace.source == .folder) .folder else .manifest, workspace.path, work, &workspaceLoaded) catch |err| {
            self.report(err, workspace);
            return;
        };
        retained = true;
    } else self.restore(work) catch |err| self.report(err, null);
}
fn workspaceLoaded(context: *anyopaque, err: ?anyerror) void {
    const work = u.cast(Work, context);
    const self = work.controller;
    defer self.reap(work);
    const workspace = work.value.?.value.workspace;
    if (!self.accepts(work)) {
        // A successful publish can race a quit request too. Retire only our
        // installation, never a workspace selected by a newer request.
        if (err == null) closeRestoredWorkspace(work);
        self.report(error.StaleWorkspace, workspace);
        return;
    }
    if (err) |failure| {
        self.report(failure, workspace);
        return;
    }
    self.restore(work) catch |failure| {
        closeRestoredWorkspace(work);
        self.report(failure, workspace);
    };
}

fn closeRestoredWorkspace(work: *Work) void {
    const browser = &work.controller.app.browser;
    // loadSession admits only an empty workspace. Its successful callback owns
    // the published model while this token is current; closing keeps documents
    // and refreshes settings/trust back to the no-workspace state.
    if (browser.requests.accepts(work.request)) browser.closeWorkspace();
}

/// Worker-only, read-only verification. Pin a nonblocking regular descriptor,
/// compare bounded decoded contents AND the saved GIO etag. Never replace the
/// saved etag with a new baseline. Monitoring/conditional save handles later edits.
fn verify(doc: recovery.Document) !Verification {
    const saved_etag = doc.saved_etag orelse return .conflict;
    const path = try @import("../platform/open_target.zig").resolveExisting(a, doc.path.?);
    defer a.free(path);
    if (!std.mem.eql(u8, path, doc.path.?)) return .conflict;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return error.Unavailable;
    defer _ = std.c.close(fd);
    var stat: c.GStatBuf = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.Unavailable;
    const cap = recovery.limits.document_bytes * 2 + 3;
    if (stat.st_size < 0 or stat.st_size > cap) return .conflict;
    var proc_buffer: [64]u8 = undefined;
    const proc_path = try std.fmt.bufPrintSentinel(&proc_buffer, "/proc/self/fd/{d}", .{fd}, 0);
    const file = c.g_file_new_for_path(proc_path).?;
    defer c.g_object_unref(file);
    if (c.g_file_is_native(file) == 0) return error.Unavailable;
    const stream = c.g_file_read(file, null, null) orelse return error.Unavailable;
    defer {
        _ = c.g_input_stream_close(@ptrCast(stream), null, null);
        c.g_object_unref(stream);
    }
    const attributes = "etag::value,standard::size,time::changed,time::changed-nsec";
    const before = c.g_file_input_stream_query_info(stream, attributes, null, null) orelse return error.Unavailable;
    defer c.g_object_unref(before);
    const etag = c.g_file_info_get_etag(before) orelse return error.Unavailable;
    if (!std.mem.eql(u8, std.mem.span(etag), saved_etag)) return .conflict;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buffer, @min(buffer.len, cap + 1 - bytes.items.len));
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.Unavailable;
        }
        if (n == 0) break;
        try bytes.appendSlice(a, buffer[0..@intCast(n)]);
        if (bytes.items.len > cap) return .conflict;
    }
    const after = c.g_file_input_stream_query_info(stream, attributes, null, null) orelse return error.Unavailable;
    defer c.g_object_unref(after);
    if (c.g_strcmp0(etag, c.g_file_info_get_etag(after)) != 0 or
        c.g_file_info_get_size(before) != c.g_file_info_get_size(after) or
        c.g_file_info_get_attribute_uint64(before, "time::changed") != c.g_file_info_get_attribute_uint64(after, "time::changed") or
        c.g_file_info_get_attribute_uint32(before, "time::changed-nsec") != c.g_file_info_get_attribute_uint32(after, "time::changed-nsec")) return .conflict;
    const decoded = codec.decode(a, bytes.items) catch return .conflict;
    defer a.free(decoded.text);
    if (!std.mem.eql(u8, decoded.text, doc.text) or decoded.bom != doc.bom or !std.mem.eql(u8, @tagName(decoded.newline), @tagName(doc.newline))) return .conflict;
    return .verified;
}
