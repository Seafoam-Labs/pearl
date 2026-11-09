//! App-owned, GTK-thread controller. Every worker has owned inputs, a cancellable
//! and an application hold; stale/cancelled callbacks are always reaped.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const chooser = @import("file_chooser");
const identity = @import("identity.zig");
const model = @import("model.zig");
const fs = @import("browser_fs.zig");
const open_target = @import("../platform/open_target.zig");
pub const Source = enum { folder, manifest };
pub const RootId = model.RootId;

/// One shared App budget across operation kinds, including cancelled workers
/// until their callbacks finish. No secondary queue: last ACCEPTED request wins.
pub const limits = struct {
    pub const in_flight = 8;
    pub const request_bytes = 128 * 1024;
    pub const path_bytes = open_target.max_target_bytes;
};

pub const Controller = struct {
    app: *App,
    model: ?model.Model = null,
    requests: identity.Scope,
    epoch: u64 = 0,
    jobs: std.ArrayList(*Work) = .empty,
    request_bytes: usize = 0,
    choosing: bool = false,
    panel: u.W,
    status: u.W,
    rows: u.W,
    selected: ?RootId = null,
    relative: []const u8 = "",
    listing: ?fs.Listing = null,
    loading: bool = false,
    scanning: bool = false,
    error_name: ?[]const u8 = null,
    closed: bool = false,
    // Isolated native tests can force a completed worker to deliver out of order.
    test_next_delay_us: c_ulong = 0,

    pub fn init(app: *App, parent: u.W) Controller {
        const panel = u.box(false, 4);
        const banner = u.label("Restricted workspace · bounded directory browser (500 entries) · no tasks or auto-execution");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, banner), 1);
        u.append(panel, banner);
        const warning = u.label("Recovery restores documents only, not workspace roots or manifests. Reopen the workspace explicitly.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, warning), 1);
        u.append(panel, warning);
        const bar = u.box(true, 4);
        u.append(panel, bar);
        inline for (.{ .{ "Roots", &rootsClicked }, .{ "Back", &backClicked }, .{ "Rescan", &rescanClicked }, .{ "Close workspace", &closeClicked } }) |item| {
            const button = u.button(item[0]);
            u.connect(button, "clicked", item[1], app);
            u.append(bar, button);
        }
        const status = u.label("");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_MIDDLE);
        u.append(panel, status);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(scroll, -1, 155);
        const rows = c.gtk_list_box_new().?;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, rows), c.GTK_SELECTION_NONE);
        c.gtk_list_box_set_activate_on_single_click(u.cast(c.GtkListBox, rows), 1);
        u.connect(rows, "row-activated", &rowActivated, app);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), rows);
        u.append(panel, scroll);
        u.append(parent, panel);
        c.gtk_widget_set_visible(panel, 0);
        return .{ .app = app, .requests = .init(), .panel = panel, .status = status, .rows = rows };
    }

    fn retireBrowse(self: *Controller) void {
        self.epoch = std.math.add(u64, self.epoch, 1) catch @panic("Browser epoch exhausted");
        self.scanning = false;
        for (self.jobs.items) |job| if (job.kind == .scan) c.g_cancellable_cancel(job.cancel);
    }
    fn clearListing(self: *Controller) void {
        if (self.listing) |*listing| listing.deinit();
        self.listing = null;
        if (self.relative.len != 0) a.free(self.relative);
        self.relative = "";
    }
    fn clearRows(self: *Controller) void {
        while (c.gtk_widget_get_first_child(self.rows)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, self.rows), child);
    }
    fn row(self: *Controller, text: []const u8, enabled: bool) void {
        const label = u.label(text);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
        const z = u.z(text);
        defer a.free(z);
        c.gtk_widget_set_tooltip_text(label, z);
        u.margin(label, 5);
        c.gtk_list_box_append(u.cast(c.GtkListBox, self.rows), label);
        c.gtk_widget_set_sensitive(c.gtk_widget_get_parent(label), @intFromBool(enabled));
    }
    pub fn roots(self: *Controller) void {
        if (self.closed) return;
        self.retireBrowse();
        self.clearListing();
        self.selected = null;
        self.clearRows();
        const snapshot = if (self.model) |*m| m else return;
        for (snapshot.roots) |root| {
            const text = u.fmt("#{d} {s} — {s} [{s}]", .{ @backingInt(root.id), root.display_name, root.lexical_path, @tagName(root.availability) });
            defer a.free(text);
            self.row(text, root.canonical_path != null);
        }
        u.setLabel(self.status, if (snapshot.roots.len == 0) "Workspace has no roots." else "Choose a root. Only direct children are read; symlinks and special files are disabled.");
        c.gtk_widget_set_visible(self.panel, 1);
    }
    pub fn closeWorkspace(self: *Controller) void {
        self.requests.invalidate();
        self.loading = false;
        self.error_name = null;
        for (self.jobs.items) |job| if (job.kind != .file or job.model_token != null) c.g_cancellable_cancel(job.cancel);
        self.retireBrowse();
        self.clearListing();
        self.selected = null;
        if (self.model) |*m| m.deinit();
        self.model = null;
        if (!self.closed) {
            self.clearRows();
            c.gtk_widget_set_visible(self.panel, 0);
            self.app.refreshWorkspaceLabels();
        }
    }
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        self.closeWorkspace();
        self.requests.close();
        for (self.jobs.items) |job| c.g_cancellable_cancel(job.cancel);
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(self.jobs.items.len == 0 and self.request_bytes == 0 and !self.choosing);
        self.jobs.deinit(a);
    }
    fn inFlight(self: *const Controller) usize {
        return self.jobs.items.len + @intFromBool(self.choosing);
    }
    fn reject(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.app.message(switch (err) {
            error.ChooserPending => "A workspace chooser is already open. Finish or cancel it before opening another; last accepted request wins.",
            error.RequestTooLarge => "Workspace/browser request not accepted: path exceeds 64 KiB. Last accepted request remains active.",
            else => "Workspace/browser busy: 8 pending operations or 128 KiB of request paths reached. Request not accepted; last accepted request wins. Retry after pending work finishes.",
        });
    }
    /// Check before allocation, holds, cancellation, or generation changes. GTK
    /// serializes admission and run(); workers never modify the accounting.
    fn admit(self: *Controller, path: []const u8, root: ?[]const u8) bool {
        if (self.closed) return false;
        if (path.len > limits.path_bytes or (if (root) |base| base.len > @import("manifest.zig").limits.path_bytes else false)) {
            self.reject(error.RequestTooLarge);
            return false;
        }
        const bytes = inputBytes(path, root);
        if (self.inFlight() >= limits.in_flight or bytes > limits.request_bytes - self.request_bytes) {
            self.reject(error.RequestBudgetExceeded);
            return false;
        }
        return true;
    }
    fn beginRequest(self: *Controller) ?identity.Token {
        if (self.closed) return null;
        self.requests.invalidate();
        for (self.jobs.items) |job| if (job.kind == .load) c.g_cancellable_cancel(job.cancel);
        self.loading = false;
        return self.requests.capture();
    }
    pub fn load(self: *Controller, source: Source, path: []const u8) void {
        if (!self.admit(path, null)) return;
        const token = self.beginRequest() orelse return;
        self.loadRequest(source, path, token);
    }
    fn loadRequest(self: *Controller, source: Source, path: []const u8, token: identity.Token) void {
        if (!self.requests.accepts(token)) return;
        self.loading = true;
        self.error_name = null;
        self.app.message("Loading workspace on a worker… Existing documents remain open.");
        const job = self.work(.load, path);
        job.source = source;
        job.request = token;
        self.run(job);
    }
    pub fn choose(self: *Controller, source: Source) void {
        if (self.closed) return;
        if (self.choosing) {
            self.reject(error.ChooserPending);
            return;
        }
        if (!self.admit("", null)) return;
        const token = self.beginRequest() orelse return;
        const choice = a.create(Choice) catch unreachable;
        choice.* = .{ .controller = self, .source = source, .token = token };
        self.choosing = true;
        c.g_application_hold(u.cast(c.GApplication, self.app.application));
        if (source == .folder) chooser.folderAsync(@ptrCast(self.app.window), @ptrCast(&chosen), choice) else chooser.openAsync(@ptrCast(self.app.window), 0, @ptrCast(&chosen), choice);
    }
    fn fail(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        const text = u.fmt("Workspace/browser: {s}. Previous workspace and documents kept. Symlinks and paths outside a root are not browsable.", .{@errorName(err)});
        defer a.free(text);
        self.app.message(text);
    }
    pub fn browse(self: *Controller, root_id: RootId, relative: []const u8) void {
        if (self.closed) return;
        const snapshot = if (self.model) |*m| m else return;
        const root = snapshot.rootById(root_id) orelse return;
        const base = root.canonical_path orelse {
            self.fail(error.UnavailableRoot);
            return;
        };
        if (!self.admit(relative, base)) return;
        const job = self.work(.scan, relative);
        job.root = u.z(base);
        job.root_id = root_id;
        job.model_token = snapshot.scope.capture();
        self.retireBrowse();
        job.epoch = self.epoch;
        self.scanning = true;
        self.error_name = null;
        u.setLabel(self.status, "Reading direct children on a worker…");
        self.run(job);
    }
    pub fn activate(self: *Controller, index: usize) void {
        if (self.closed or self.scanning) return;
        const snapshot = if (self.model) |*m| m else return;
        if (self.selected) |id| {
            const listing = self.listing orelse return;
            if (index >= listing.entries.len) return;
            const entry = listing.entries[index];
            if (entry.kind == .blocked) return;
            const relative = if (self.relative.len == 0) u.z(entry.name) else u.fmt("{s}/{s}", .{ self.relative, entry.name });
            defer a.free(relative);
            if (entry.kind == .directory) self.browse(id, relative) else {
                const root = snapshot.rootById(id) orelse return;
                const path = std.fs.path.join(a, &.{ root.canonical_path.?, relative }) catch unreachable;
                defer a.free(path);
                self.app.openExisting(path, id);
            }
        } else if (index < snapshot.roots.len) self.browse(snapshot.roots[index].id, "");
    }
    pub fn back(self: *Controller) void {
        if (self.selected) |id| {
            if (self.relative.len != 0) {
                self.browse(id, std.fs.path.dirname(self.relative) orelse "");
                return;
            }
        }
        self.roots();
    }
    pub fn rescan(self: *Controller) void {
        if (self.selected) |id| self.browse(id, self.relative) else self.roots();
    }
    pub fn hasPendingFiles(self: *const Controller) bool {
        for (self.jobs.items) |job| if (job.kind == .file and !job.delivering) return true;
        return false;
    }
    pub fn openFile(self: *Controller, path: []const u8, root_id: ?RootId) void {
        if (self.closed) return;
        var base: ?[]const u8 = null;
        var token: ?identity.Token = null;
        if (root_id) |id| {
            const snapshot = if (self.model) |*m| m else return;
            const root = snapshot.rootById(id) orelse return;
            base = root.canonical_path orelse return;
            token = snapshot.scope.capture();
        }
        // Deduplicate before checking capacity, including when the budget is full.
        // Exact input spelling and boundary identity matter, not canonical aliases.
        for (self.jobs.items) |job| {
            if (job.kind == .file and job.root_id == root_id and
                std.meta.eql(job.model_token, token) and
                self.app.workspace.accepts(job.document_token) and
                std.mem.eql(u8, job.path, path)) return;
        }
        if (!self.admit(path, base)) {
            // Match the existing-file failure path during startup: a rejected
            // argument must not look like a closed, zero-document session.
            if (self.app.snapshotDocuments().len == 0 and !self.hasPendingFiles()) _ = self.app.newDocument();
            return;
        }
        const job = self.work(.file, path);
        job.root = if (base) |root| u.z(root) else null;
        job.root_id = root_id;
        job.model_token = token;
        self.run(job);
    }
    fn work(self: *Controller, kind: Kind, path: []const u8) *Work {
        const job = a.create(Work) catch unreachable;
        job.* = .{ .controller = self, .kind = kind, .path = u.z(path), .document_token = self.app.workspace.capture().?, .cancel = c.g_cancellable_new().?, .test_delay_us = if (@import("build_options").test_hooks) self.test_next_delay_us else 0 };
        self.test_next_delay_us = 0;
        return job;
    }
    fn run(self: *Controller, job: *Work) void {
        std.debug.assert(self.inFlight() < limits.in_flight);
        const bytes = inputBytes(job.path, job.root);
        std.debug.assert(bytes <= limits.request_bytes - self.request_bytes);
        self.jobs.append(a, job) catch unreachable;
        self.request_bytes += bytes;
        c.g_application_hold(u.cast(c.GApplication, self.app.application));
        const task = c.g_task_new(null, job.cancel, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        // Never return early on cancellation: the worker still owns job storage.
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    fn acceptsModel(self: *Controller, token: identity.Token) bool {
        return if (self.model) |*m| m.scope.accepts(token) else false;
    }
    pub fn probe(self: *Controller) void {
        const Root = struct { id: u64, name: []const u8, path: []const u8, canonical: ?[]const u8, availability: model.Availability };
        var roots_list: std.ArrayList(Root) = .empty;
        defer roots_list.deinit(a);
        if (self.model) |*m| for (m.roots) |root| {
            roots_list.append(a, .{ .id = @intCast(@backingInt(root.id)), .name = root.display_name, .path = root.lexical_path, .canonical = root.canonical_path, .availability = root.availability }) catch unreachable;
        };
        const text = std.json.Stringify.valueAlloc(a, .{ .roots = roots_list.items, .status = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, self.status))), .restricted = true, .loading = self.loading, .scanning = self.scanning, .pending = self.jobs.items.len, .in_flight = self.inFlight(), .request_bytes = self.request_bytes, .choosing = self.choosing, .operation_limit = limits.in_flight, .request_byte_limit = limits.request_bytes, .selected = if (self.selected) |id| @as(?u64, @intCast(@backingInt(id))) else null, .relative = self.relative, .entries = if (self.listing) |list| list.entries else &.{}, .truncated = if (self.listing) |list| list.truncated else false, .error_name = self.error_name, .manifest = if (self.model) |m| m.manifest_path else null }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_BROWSER %s\n", z.ptr);
    }
};
fn inputBytes(path: []const u8, root: ?[]const u8) usize {
    return path.len + 1 + if (root) |base| base.len + 1 else @as(usize, 0);
}
const Kind = enum { load, scan, file };
const Work = struct {
    controller: *Controller,
    kind: Kind,
    path: [:0]u8,
    root: ?[:0]u8 = null,
    root_id: ?RootId = null,
    document_token: identity.Token,
    request: ?identity.Token = null,
    model_token: ?identity.Token = null,
    epoch: u64 = 0,
    source: Source = .folder,
    cancel: *c.GCancellable,
    result: ?model.Model = null,
    listing: ?fs.Listing = null,
    canonical: ?[:0]u8 = null,
    err: ?anyerror = null,
    test_delay_us: c_ulong = 0,
    delivering: bool = false,
    fn destroy(self: *Work) void {
        if (self.result) |*m| m.deinit();
        if (self.listing) |*listing| listing.deinit();
        if (self.canonical) |path| a.free(path);
        if (self.root) |path| a.free(path);
        a.free(self.path);
        c.g_object_unref(self.cancel);
        a.destroy(self);
    }
    fn perform(self: *Work) !void {
        if (c.g_cancellable_is_cancelled(self.cancel) != 0) return error.Cancelled;
        switch (self.kind) {
            .load => {
                const path = try fs.absolute(a, self.path);
                defer a.free(path);
                self.result = switch (self.source) {
                    .folder => try model.Model.fromFolder(a, path),
                    .manifest => try model.Model.fromManifest(a, path),
                };
            },
            .scan => self.listing = try fs.scan(a, self.root.?, self.path, self.cancel),
            .file => {
                if (self.root) |root| {
                    if (!contained(root, self.path) or self.path.len <= root.len) return error.OutsideRoot;
                    const relative = self.path[root.len + @as(usize, if (root.len == 1) 0 else 1) ..];
                    try fs.checkFile(root, relative);
                }
                self.canonical = try open_target.resolveExisting(a, self.path);
                if (self.root) |root| if (!contained(root, self.canonical.?)) return error.OutsideRoot;
            },
        }
    }
};
fn contained(root: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and (root.len == 1 or path.len == root.len or path[root.len] == '/');
}
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Work, data.?);
    job.perform() catch |err| {
        job.err = err;
    };
    if (@import("build_options").test_hooks and job.test_delay_us != 0) c.g_usleep(job.test_delay_us);
    c.g_task_return_boolean(task, 1);
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Work, data.?);
    const self = job.controller;
    defer c.g_application_release(u.cast(c.GApplication, self.app.application));
    defer {
        // Retain the slot, bytes and hold throughout callback delivery as well.
        const bytes = inputBytes(job.path, job.root);
        for (self.jobs.items, 0..) |pending, index| if (pending == job) {
            _ = self.jobs.swapRemove(index);
            break;
        };
        self.request_bytes -= bytes;
        job.destroy();
    }
    job.delivering = true;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    if (self.closed or !self.app.workspace.accepts(job.document_token)) return;
    if (job.request) |token| if (!self.requests.accepts(token)) return;
    if (job.model_token) |token| if (!self.acceptsModel(token)) return;
    if (job.kind == .scan and job.epoch != self.epoch) return;
    if (job.kind == .load) self.loading = false;
    if (job.kind == .scan) self.scanning = false;
    if (job.err) |err| {
        if (job.kind == .scan) u.setLabel(self.status, "Directory unavailable; previous listing retained. Use Rescan or Roots.");
        if (job.kind == .file) self.app.existingFailed(err) else self.fail(err);
        return;
    }
    if (c.g_cancellable_is_cancelled(job.cancel) != 0) return;
    switch (job.kind) {
        .load => {
            self.retireBrowse();
            if (self.model) |*m| m.deinit();
            self.model = job.result;
            job.result = null;
            self.error_name = null;
            self.roots();
            self.app.refreshWorkspaceLabels();
            self.app.message("Workspace opened in restricted mode. Documents kept. Recovery does not restore workspace roots; reopen the manifest explicitly.");
        },
        .scan => {
            self.clearListing();
            self.listing = job.listing;
            job.listing = null;
            self.relative = if (job.path.len == 0) "" else u.z(job.path);
            self.selected = job.root_id;
            self.clearRows();
            const root = self.model.?.rootById(job.root_id.?).?;
            for (self.listing.?.entries) |entry| {
                const text = u.fmt("#{d} {s} · {s}{s}{s}{s}", .{ @backingInt(root.id), root.display_name, self.relative, if (self.relative.len == 0) "" else "/", entry.name, switch (entry.kind) {
                    .directory => "/",
                    .file => "",
                    .blocked => " [symlink/special/unavailable — disabled]",
                } });
                defer a.free(text);
                self.row(text, entry.kind != .blocked);
            }
            const text = u.fmt("{s} — {s}/{s} · {d} entries{s}", .{ root.display_name, root.canonical_path.?, self.relative, self.listing.?.entries.len, if (self.listing.?.truncated) " · TRUNCATED at 500; not a full listing" else "" });
            defer a.free(text);
            u.setLabel(self.status, text);
        },
        .file => self.app.acceptExisting(job.canonical.?),
    }
}
const Choice = struct { controller: *Controller, source: Source, token: identity.Token };
fn chosen(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const choice = u.cast(Choice, data.?);
    const self = choice.controller;
    defer a.destroy(choice);
    // Release the chooser's reserved slot/hold before handing it to a worker.
    // This callback does not iterate the main context; App remains alive through
    // callback return even when this was the final application hold.
    self.choosing = false;
    c.g_application_release(u.cast(c.GApplication, self.app.application));
    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);
    const files: ?*c.GListModel = @ptrCast(chooser.openFinish(@ptrCast(result.?), @ptrCast(&err)));
    if (files) |list| {
        defer c.g_object_unref(list);
        if (!self.requests.accepts(choice.token)) return;
        const file = c.g_list_model_get_item(list, 0) orelse return;
        defer c.g_object_unref(file);
        const path = c.g_file_get_path(u.cast(c.GFile, file));
        defer c.g_free(path);
        if (path != null) {
            if (self.admit(std.mem.span(path), null)) self.loadRequest(choice.source, std.mem.span(path), choice.token);
        } else self.fail(error.NonLocalPath);
    }
}
fn rootsClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.roots();
}
fn backClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.back();
}
fn rescanClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.rescan();
}
fn closeClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.closeWorkspace();
}
fn rowActivated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const index = c.gtk_list_box_row_get_index(row);
    if (index >= 0) u.cast(App, data.?).browser.activate(@intCast(index));
}
