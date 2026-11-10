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
const explorer = @import("explorer.zig");
const watch = @import("explorer_watch.zig");
pub const Source = enum { folder, manifest };
pub const RootId = model.RootId;
const SearchActivation = @import("search_controller.zig").Activation;

/// One shared App budget across operation kinds, including cancelled workers
/// until their callbacks finish. Load/file admission has no secondary queue;
/// live scans retain at most one coalesced reload flag per bounded directory.
pub const limits = struct {
    pub const in_flight = 8;
    pub const request_bytes = 128 * 1024;
    pub const path_bytes = open_target.max_target_bytes;
};

pub const Controller = struct {
    app: *App,
    model: ?model.Model = null,
    // Resolved on the load worker, never by synchronous GTK-thread I/O.
    manifest_canonical: ?[:0]u8 = null,
    requests: identity.Scope,
    epoch: u64 = 0,
    jobs: std.ArrayList(*Work) = .empty,
    request_bytes: usize = 0,
    choosing: bool = false,
    panel: u.W,
    status: u.W,
    policy_status: u.W,
    rows: u.W,
    selected: ?RootId = null,
    relative: []const u8 = "",
    tree: explorer.Tree = .{},
    policy: ?*explorer.Policy = null,
    policy_pending: bool = false,
    manifest_first: i64 = 0,
    manifest_last: i64 = 0,
    manifest_generation: u64 = 0,
    view: explorer.View,
    watches: watch.Watches = .{ .changed = directoryChanged },
    source: c_uint = 0,
    render_pending: bool = false,
    rendering: bool = false,
    scans_started: usize = 0,
    resets: usize = 0,
    overflows: usize = 0,
    watches_dirty: bool = false,
    watch_running: bool = false,
    watch_seen: u64 = 0,
    pending_load: ?*Work = null,
    loading: bool = false,
    scanning: bool = false,
    error_name: ?[]const u8 = null,
    closed: bool = false,
    closing_workspace: bool = false,
    // Isolated native tests can force a completed worker to deliver out of order.
    test_next_delay_us: c_ulong = 0,
    test_drain: bool = false,
    test_last_tick: i64 = 0,
    test_max_tick_us: i64 = 0,

    pub fn init(app: *App, parent: u.W) Controller {
        const panel = u.box(false, 0);
        c.gtk_widget_add_css_class(panel, "explorer-panel");
        c.gtk_widget_set_focusable(panel, 1);
        c.gtk_widget_set_vexpand(panel, 1);
        const bar = u.box(true, 2);
        c.gtk_widget_add_css_class(bar, "explorer-toolbar");
        u.append(panel, bar);
        inline for (.{ .{ "go-home-symbolic", "Roots", &rootsClicked }, .{ "go-previous-symbolic", "Back", &backClicked }, .{ "view-refresh-symbolic", "Rescan", &rescanClicked } }) |item| {
            const button = u.icon(item[0], item[1]);
            c.gtk_widget_add_css_class(button, "flat");
            u.connect(button, "clicked", item[2], app);
            u.append(bar, button);
        }
        const create = u.icon("document-new-symbolic", "New file…");
        c.gtk_widget_add_css_class(create, "flat");
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, create), "win.workspace-create-file");
        u.append(bar, create);
        const spacer = u.box(true, 0);
        c.gtk_widget_set_hexpand(spacer, 1);
        u.append(bar, spacer);
        const menu = c.gtk_menu_button_new().?;
        c.gtk_widget_add_css_class(menu, "explorer-menu");
        c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, menu), "view-more-symbolic");
        c.gtk_widget_set_tooltip_text(menu, "Explorer actions and safety information");
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, menu), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), @as([*:0]const u8, "Explorer actions and safety information"), @as(c_int, -1));
        const popover = c.gtk_popover_new().?;
        c.gtk_widget_add_css_class(popover, "explorer-actions");
        const actions = u.box(false, 2);
        c.gtk_popover_set_child(u.cast(c.GtkPopover, popover), actions);
        c.gtk_menu_button_set_popover(u.cast(c.GtkMenuButton, menu), popover);
        u.append(bar, menu);
        inline for (.{ .{ "Open Folder…", "win.open-folder" }, .{ "Workspace…", "win.open-workspace" }, .{ "New directory…", "win.workspace-create-directory" }, .{ "Rename…", "win.workspace-rename" }, .{ "Move…", "win.workspace-move" }, .{ "Delete…", "win.workspace-delete" } }) |item| {
            const button = u.button(item[0]);
            c.gtk_widget_add_css_class(button, "flat");
            c.gtk_widget_set_tooltip_text(button, if (std.mem.eql(u8, item[0], "Delete…")) "Delete permanently… · requires review; no trash or undo" else item[0]);
            u.connect(button, "clicked", &closeActions, popover);
            c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, button), item[1]);
            u.append(actions, button);
        }
        inline for (.{ .{ "Reset tree", &resetClicked }, .{ "Close workspace", &closeClicked } }) |item| {
            const button = u.button(item[0]);
            c.gtk_widget_add_css_class(button, "flat");
            c.gtk_widget_set_tooltip_text(button, item[0]);
            u.connect(button, "clicked", &closeActions, popover);
            u.connect(button, "clicked", item[1], app);
            u.append(actions, button);
        }
        u.append(actions, c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?);
        const banner = u.label("Restricted explorer · no auto-execution");
        const warning = u.label("256-entry page windows; 64 directories / 8 resident pages. Load more replaces the page; Rescan restarts.\nRecovery restores documents only, not workspace roots or manifests. Reopen the workspace explicitly.\nFile changes require review. Delete is permanent; no trash or undo.");
        for ([_]u.W{ banner, warning }) |label| {
            c.gtk_widget_add_css_class(label, "explorer-safety");
            c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 32);
            u.append(actions, label);
        }
        const status = u.label("");
        c.gtk_widget_add_css_class(status, "panel-status");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_END);
        u.connect(status, "notify::label", &statusChanged, null);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_min_content_height(u.cast(c.GtkScrolledWindow, scroll), 40);
        const view = explorer.View.init();
        const rows = view.widget;
        u.connect(rows, "activate", &rowActivated, app);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), rows);
        u.append(panel, scroll);
        u.append(panel, status);
        u.append(parent, panel);
        u.setLabel(status, "Open a folder or workspace to browse files.");
        return .{ .app = app, .requests = .init(), .panel = panel, .status = status, .policy_status = banner, .rows = rows, .view = view };
    }

    fn retireBrowse(self: *Controller) void {
        self.epoch = std.math.add(u64, self.epoch, 1) catch @panic("Browser epoch exhausted");
        self.scanning = false;
        for (self.jobs.items) |job| if (job.kind == .scan) c.g_cancellable_cancel(job.cancel);
    }
    pub fn attach(self: *Controller) void {
        self.view.connect();
        u.connect(self.view.selection, "notify::selected", &selectionChanged, self);
        self.watches.context = self;
        self.watches.init();
        self.watch_running = true;
        self.app.hold();
        const task = c.g_task_new(null, null, &watchDone, self).?;
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &watchWorker);
        c.g_object_unref(task);
        self.source = c.g_timeout_add(25, &pump, self);
    }
    fn clearListing(self: *Controller) void {
        self.watches.clear();
        self.clearTree();
    }
    fn clearTree(self: *Controller) void {
        self.tree.deinit();
        if (self.policy) |policy| policy.unref();
        self.policy = null;
        self.policy_pending = false;
        self.manifest_first = 0;
        self.manifest_last = 0;
        if (self.relative.len != 0) a.free(self.relative);
        self.relative = "";
    }
    fn clearRows(self: *Controller) void {
        const focus = c.gtk_window_get_focus(u.cast(c.GtkWindow, self.app.window));
        // GtkListView can leave GtkRoot.focus on an unparented list item when
        // its model is emptied. Park it before splicing, not after destruction.
        if (@import("../workbench/dock.zig").inside(focus, self.rows)) _ = c.gtk_widget_grab_focus(self.panel);
        self.view.clear();
        self.tree.rows.clearRetainingCapacity();
    }
    pub fn roots(self: *Controller) void {
        if (self.closed) return;
        self.selected = null;
        if (self.relative.len != 0) a.free(self.relative);
        self.relative = "";
        const snapshot = if (self.model) |*m| m else return;
        for (snapshot.roots) |root| _ = self.tree.ensure(root.id, "");
        self.render();
        c.gtk_widget_set_visible(self.panel, 1);
    }
    pub fn resetTree(self: *Controller) void {
        if (self.closed or self.model == null) return;
        if (self.policy_pending) {
            self.rescan();
            return;
        }
        self.test_drain = false;
        self.retireBrowse();
        self.clearListing();
        self.policy = explorer.Policy.create(self.model.?.exclude);
        self.selected = null;
        self.roots();
        self.watches_dirty = true;
        self.app.message("Explorer state reset: directory slots released. Workspace root IDs and documents are unchanged.");
    }
    pub fn closeWorkspace(self: *Controller) void {
        if (!self.closed and !self.closing_workspace and self.app.editingFrozen()) return;
        if (!self.closed and (self.app.rejectFileOperationBarrier() or self.app.workspaceOperationBusy() or self.app.quitting)) return;
        if (!self.closed and self.app.manager != null) {
            const ready = self.app.projects.beforeWorkspaceChange(null) catch |err| {
                self.closing_workspace = false;
                self.fail(err);
                return;
            };
            if (!ready) {
                self.closing_workspace = true;
                return;
            }
        }
        self.closing_workspace = false;
        self.app.workspace_search.invalidate("Stale — workspace closed. Open a workspace and refresh.");
        self.requests.invalidate();
        self.cancelWaitingLoad();
        self.test_drain = false;
        self.loading = false;
        self.error_name = null;
        for (self.jobs.items) |job| if (job.kind != .file or job.model_token != null) c.g_cancellable_cancel(job.cancel);
        self.retireBrowse();
        self.clearListing();
        self.selected = null;
        // Keep root/manifest protection visible in the manager until a closing
        // App's holds drain. No closed browser can publish or browse this model.
        if (!self.closed) {
            if (self.model) |*m| m.deinit();
            self.model = null;
            if (self.manifest_canonical) |path| a.free(path);
            self.manifest_canonical = null;
        }
        self.app.workspace_policy.modelChanged();
        if (!self.closed) {
            self.clearRows();
            u.setLabel(self.status, "Open a folder or workspace to browse files.");
            self.app.refreshWorkspaceLabels();
            if (self.app.manager != null) self.app.projects.workspaceChanged();
        }
    }
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        if (self.source != 0) _ = c.g_source_remove(self.source);
        self.source = 0;
        self.closeWorkspace();
        self.requests.close();
        self.watches.stop();
        for (self.jobs.items) |job| c.g_cancellable_cancel(job.cancel);
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(self.jobs.items.len == 0 and self.request_bytes == 0 and !self.choosing);
        self.jobs.deinit(a);
        std.debug.assert(!self.watch_running);
        self.watches.deinit();
        if (self.model) |*m| m.deinit();
        self.model = null;
        if (self.manifest_canonical) |path| a.free(path);
        self.manifest_canonical = null;
    }
    fn inFlight(self: *const Controller) usize {
        return self.jobs.items.len + @intFromBool(self.choosing);
    }
    fn reject(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.app.message(switch (err) {
            error.ChooserPending => "A workspace chooser is already open. Finish or cancel it before opening another; last accepted request wins.",
            error.ExplorerNodeLimit => "Explorer directory-state limit (64) reached. Existing pages remain usable; Reset tree releases directory state without closing documents or changing root IDs.",
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
        if (self.closed or self.app.editingFrozen()) return null;
        if (self.app.manager != null) self.app.projects.cancelWorkspaceChange();
        self.requests.invalidate();
        self.cancelWaitingLoad();
        for (self.jobs.items) |job| if (job.kind == .load) c.g_cancellable_cancel(job.cancel);
        self.loading = false;
        return self.requests.capture();
    }
    pub fn load(self: *Controller, source: Source, path: []const u8) void {
        if (self.app.editingFrozen()) return;
        if (self.app.rejectFileOperationBarrier() or self.app.workspaceOperationBusy() or self.app.quitting) return;
        if (self.app.manager) |manager| if (manager.quitting) return;
        if (!self.admit(path, null)) return;
        const token = self.beginRequest() orelse return;
        self.app.dock.show(.explorer);
        self.loadRequest(source, path, token);
    }
    /// Explicit session restore uses the ordinary watched load/policy pipeline.
    /// Completion is delivered exactly once, including stale/cancelled loads.
    pub fn loadSession(self: *Controller, source: Source, path: []const u8, context: *anyopaque, completion: *const fn (*anyopaque, ?anyerror) void) !identity.Token {
        if (self.app.fileOperationBarrier() or self.app.workspaceOperationBusy()) return error.FileOperationBusy;
        if (self.model != null or self.loading or self.choosing) return error.ActiveWorkspace;
        if (!self.admit(path, null)) return error.Busy;
        const token = self.beginRequest() orelse return error.Closing;
        self.app.workspace_policy.invalidate();
        self.loading = true;
        self.error_name = null;
        const job = self.work(.load, path);
        job.source = source;
        job.request = token;
        job.session_context = context;
        job.session_completion = completion;
        self.run(job);
        return token;
    }
    fn loadRequest(self: *Controller, source: Source, path: []const u8, token: identity.Token) void {
        if (self.app.rejectFileOperationBarrier() or self.app.workspaceOperationBusy()) return;
        if (!self.requests.accepts(token)) return;
        self.app.workspace_policy.invalidate();
        self.loading = true;
        self.error_name = null;
        self.app.message("Loading workspace on a worker… Existing documents remain open.");
        const job = self.work(.load, path);
        job.source = source;
        job.request = token;
        self.run(job);
    }
    pub fn choose(self: *Controller, source: Source) void {
        if (self.closed or self.app.rejectFileOperationBarrier() or self.app.workspaceOperationBusy()) return;
        if (self.choosing) {
            self.reject(error.ChooserPending);
            return;
        }
        if (!self.admit("", null)) return;
        const token = self.beginRequest() orelse return;
        self.app.dock.show(.explorer);
        const choice = a.create(Choice) catch unreachable;
        choice.* = .{ .controller = self, .source = source, .token = token };
        self.choosing = true;
        self.app.hold();
        if (source == .folder) chooser.folderAsync(@ptrCast(self.app.window), @ptrCast(&chosen), choice) else chooser.openAsync(@ptrCast(self.app.window), 0, @ptrCast(&chosen), choice);
        self.app.transients(false);
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
        const base = root.canonical_path orelse root.lexical_path;
        if (self.tree.find(root_id, relative)) |existing| if (self.tree.nodes.items[existing].busy) return;
        if (!self.admit(relative, base)) return;
        const index = self.tree.ensure(root_id, relative) orelse {
            self.reject(error.ExplorerNodeLimit);
            return;
        };
        const node = &self.tree.nodes.items[index];
        node.expanded = true;
        if (!node.accessed) {
            node.accessed = true;
            self.rebuildWatches(&self.model.?);
            self.requirePolicyRefresh();
        }
        if (node.page != null and !node.queued) {
            self.focusNode(index);
            self.render();
        } else self.scanNode(index, true);
    }
    fn setCurrent(self: *Controller, index: usize) void {
        const node = self.tree.nodes.items[index];
        const path = if (node.relative.len == 0) "" else u.z(node.relative);
        if (self.relative.len != 0) a.free(self.relative);
        self.relative = path;
        self.selected = node.root;
    }
    fn focusNode(self: *Controller, index: usize) void {
        self.setCurrent(index);
        const node = self.tree.nodes.items[index];
        const selected = self.tree.selected_path orelse "";
        const descendant = self.tree.selected_root == node.root and (node.relative.len == 0 or (selected.len > node.relative.len and std.mem.startsWith(u8, selected, node.relative) and selected[node.relative.len] == '/'));
        if (!descendant) self.tree.select(node.root, node.relative);
    }
    fn current(self: *Controller) ?usize {
        return self.tree.find(self.selected orelse return null, self.relative);
    }
    fn scanNode(self: *Controller, index: usize, navigate: bool) void {
        const node = &self.tree.nodes.items[index];
        if (node.busy) return;
        const snapshot = if (self.model) |*m| m else return;
        const root = snapshot.rootById(node.root) orelse return;
        const base = root.canonical_path orelse root.lexical_path;
        if (!self.admit(node.relative, base)) return;

        const job = self.work(.scan, node.relative);
        job.root = u.z(base);
        job.root_id = node.root;
        job.model_token = snapshot.scope.capture();
        job.epoch = self.epoch;
        job.node = index;
        job.navigate = navigate or node.navigate_pending;
        node.navigate_pending = false;
        job.watch_generation = self.watches.generation;
        job.watch_ready = self.watches.ready();
        job.node_generation = node.generation;
        job.continuation = node.continuation;
        job.policy = self.policy.?.ref();
        node.busy = true;
        self.scans_started += 1;
        node.queued = false;
        node.first_event = 0;
        node.last_event = 0;
        self.scanning = true;
        self.error_name = null;
        self.run(job);
        self.render();
    }
    pub fn more(self: *Controller) void {
        if (self.current()) |index| self.moreNode(index);
    }
    fn moreNode(self: *Controller, index: usize) void {
        const node = &self.tree.nodes.items[index];
        if (node.busy) return;
        if (!node.complete or node.page == null) {
            self.setCurrent(index);
            self.scanNode(index, false);
        }
    }
    pub fn activate(self: *Controller, index: usize) void {
        if (self.closed) return;
        const snapshot = if (self.model) |*m| m else return;
        if (self.current()) |node| {
            self.activateEntry(node, index);
        } else if (index < snapshot.roots.len) self.browse(snapshot.roots[index].id, "");
    }
    fn activateEntry(self: *Controller, index: usize, entry_index: usize) void {
        const node = self.tree.nodes.items[index];
        const page = node.page orelse return;
        if (entry_index >= page.entries.len) return;
        const entry = page.entries[entry_index];
        if (entry.kind == .blocked) {
            self.fail(error.UnavailableOrSymlink);
            return;
        }
        const relative = if (node.relative.len == 0) u.z(entry.name) else u.fmt("{s}/{s}", .{ node.relative, entry.name });
        defer a.free(relative);
        self.tree.select(node.root, relative);
        if (entry.kind == .directory) self.browse(node.root, relative) else {
            const root = self.model.?.rootById(node.root) orelse return;
            const path = std.fs.path.join(a, &.{ root.canonical_path orelse root.lexical_path, relative }) catch unreachable;
            defer a.free(path);
            self.app.openExisting(path, node.root);
        }
    }
    pub fn activateVisible(self: *Controller, index: usize) void {
        if (index >= self.tree.rows.items.len) return;
        const row = self.tree.rows.items[index];
        if (row.more) {
            self.moreNode(row.node);
            return;
        }
        if (row.entry) |entry_index| {
            self.activateEntry(row.node, entry_index);
            return;
        }
        const node = &self.tree.nodes.items[row.node];
        if (node.expanded) {
            node.expanded = false;
            self.focusNode(row.node);
            self.render();
        } else self.browse(node.root, node.relative);
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
    pub fn testWatchStorm(self: *Controller) void {
        if (!@import("build_options").test_hooks) return;
        if (self.model) |*snapshot| {
            for (0..64) |_| {
                self.watches.test_delay_us = 750000;
                self.rebuildWatches(snapshot);
            }
            self.requirePolicyRefresh();
        }
    }
    pub fn rescan(self: *Controller) void {
        // Both constructors reread every folder config on the worker. Never
        // reuse a folder workspace's old settings snapshot on explicit Rescan.
        if (self.model) |snapshot| {
            if (snapshot.manifest_path) |path| self.load(.manifest, path) else if (snapshot.roots.len != 0) self.load(.folder, snapshot.roots[0].lexical_path);
        }
    }
    fn invalidateLoaded(self: *Controller) void {
        self.app.workspace_policy.invalidate();
        self.app.workspace_search.invalidate("Stale — workspace contents or monitoring changed. Refresh required.");
        for (self.tree.nodes.items) |*node| node.invalidate();
        for (self.jobs.items) |job| if (job.kind == .scan) c.g_cancellable_cancel(job.cancel);
        self.render_pending = true;
    }
    fn requirePolicyRefresh(self: *Controller) void {
        if (self.model) |snapshot| if (snapshot.manifest_path != null) {
            self.policy_pending = true;
            self.app.workspace_search.invalidate("Stale — workspace policy is being refreshed.");
            const now = c.g_get_monotonic_time();
            if (self.manifest_first == 0) self.manifest_first = now;
            self.manifest_last = now;
        };
    }
    fn rebuildWatches(self: *Controller, candidate: *const model.Model) void {
        self.invalidateLoaded();
        self.watches.begin();
        const retain = if (self.model) |*current_model| sameModel(current_model, candidate) else false;
        if (retain) {
            for (self.tree.nodes.items, 0..) |node, i| if (node.accessed or node.relative.len == 0) self.watchNode(i);
        } else {
            for (candidate.roots, 0..) |root, i| self.watchRoot(root.canonical_path orelse root.lexical_path, i);
        }
        _ = self.watches.submit(candidate.manifest_path);
        self.watches_dirty = false;
    }
    fn watchRoot(self: *Controller, base: []const u8, index: usize) void {
        self.watches.add(base, index, null);
        var child = base;
        while (std.fs.path.dirname(child)) |parent| {
            self.watches.add(parent, index, std.fs.path.basename(child));
            child = parent;
        }
    }
    fn watchNode(self: *Controller, index: usize) void {
        const node = self.tree.nodes.items[index];
        const root = self.model.?.rootById(node.root) orelse return;
        const base = root.canonical_path orelse root.lexical_path;
        const path = std.fs.path.join(a, &.{ base, node.relative }) catch unreachable;
        defer a.free(path);
        self.watches.add(path, index, null);
        // Watch the ancestor chain too: an unavailable root may have multiple
        // missing parents, or an existing ancestor can be renamed/replaced.
        if (node.relative.len == 0) self.watchRoot(base, index);
        // Direct navigation through an unopened ancestor still needs policy watches.
        var ancestor = std.fs.path.dirname(node.relative);
        while (ancestor) |part| {
            const parent = std.fs.path.join(a, &.{ base, part }) catch unreachable;
            defer a.free(parent);
            self.watches.add(parent, index, null);
            ancestor = std.fs.path.dirname(part);
        }
    }
    fn render(self: *Controller) void {
        if (self.closed) return;
        self.rendering = true;
        defer self.rendering = false;
        const window = u.cast(c.GtkWindow, self.app.window);
        const had_list_focus = @import("../workbench/dock.zig").inside(c.gtk_window_get_focus(window), self.rows);
        defer if (had_list_focus and c.gtk_window_get_focus(window) == self.panel and c.gtk_widget_get_mapped(self.rows) != 0) {
            // Preserve list focus, never take it from an editor/query or reopen
            // a hidden dock when a watcher publishes a new page.
            _ = c.gtk_widget_grab_focus(self.rows);
        };
        self.clearRows();
        if (self.model) |snapshot| for (snapshot.roots) |root| {
            if (self.tree.find(root.id, "")) |i| {
                const label = u.fmt("#{d} {s} — {s}{s}{s}", .{ @backingInt(root.id), root.display_name, root.lexical_path, if (!self.tree.nodes.items[i].accessed and root.availability != .available) " · initial status: " else "", if (!self.tree.nodes.items[i].accessed and root.availability != .available) @tagName(root.availability) else "" });
                defer a.free(label);
                self.renderNode(i, 0, label);
            }
        };
        const text = u.fmt("{s}{s} · {d}/64 directories · {d}/8 resident pages · 256 entries/page · Load more replaces the page; Rescan restarts.", .{ if (self.loading or !self.watches.ready()) "Registering watches / validating policy… " else if (self.policy_pending) "Policy unavailable — repair manifest and Rescan. " else if (self.scanPending()) "Reading… " else "", if (self.watches.failed) "WATCH UNAVAILABLE/LIMIT — use Rescan" else "Live directory watches", self.tree.nodes.items.len, self.tree.pages() });
        defer a.free(text);
        u.setLabel(self.status, text);
    }
    fn appendRow(self: *Controller, row: explorer.Row, depth: usize, text: []const u8) void {
        self.tree.rows.append(a, row) catch unreachable;
        const label = u.fmt("{s}{s}", .{ @as([]const u8, "                                                                ")[0..@min(depth * 2, 64)], text });
        defer a.free(label);
        self.view.append(label);
        if (self.tree.selected_path) |selected| {
            const node = self.tree.nodes.items[row.node];
            if (node.root == self.tree.selected_root and !row.more) {
                const path = if (row.entry) |i| std.fs.path.join(a, &.{ node.relative, node.page.?.entries[i].name }) catch unreachable else u.z(node.relative);
                defer a.free(path);
                if (std.mem.eql(u8, selected, path)) c.gtk_single_selection_set_selected(self.view.selection, @intCast(self.tree.rows.items.len - 1));
            }
        }
    }
    fn renderNode(self: *Controller, index: usize, depth: usize, name: []const u8) void {
        const node = self.tree.nodes.items[index];
        const title = u.fmt("{s} {s}/{s}", .{ if (node.expanded) "▾" else "▸", name, if (node.err) |err| err else "" });
        defer a.free(title);
        self.appendRow(.{ .node = index }, depth, title);
        if (!node.expanded) return;
        if (node.page) |page| for (page.entries, 0..) |entry, i| {
            const path = if (node.relative.len == 0) u.z(entry.name) else u.fmt("{s}/{s}", .{ node.relative, entry.name });
            defer a.free(path);
            if (entry.kind == .directory) if (self.tree.find(node.root, path)) |child| {
                self.renderNode(child, depth + 1, entry.name);
                continue;
            };
            const text = u.fmt("{s}{s}{s}", .{ if (entry.kind == .directory) "▸ " else "", entry.name, if (entry.kind == .blocked) " [disabled]" else "" });
            defer a.free(text);
            self.appendRow(.{ .node = index, .entry = i }, depth + 1, text);
        };
        if (!node.complete or node.page == null) self.appendRow(.{ .node = index, .more = true }, depth + 1, if (node.busy) "Reading…" else if (node.page == null and node.continuation != null) "Load more (previous page evicted)" else "Load more / retry");
    }
    pub fn hasPendingOperations(self: *const Controller) bool {
        if (self.loading or self.choosing or self.pending_load != null or self.closing_workspace) return true;
        // Include stale/cancelled and delivering jobs until they are reaped.
        for (self.jobs.items) |job| if (job.kind != .scan) return true;
        return false;
    }
    pub fn hasPendingFiles(self: *const Controller) bool {
        for (self.jobs.items) |job| if (job.kind == .file and !job.delivering) return true;
        return false;
    }
    pub fn openFile(self: *Controller, path: []const u8, root_id: ?RootId) void {
        _ = self.openFileRequest(path, root_id, null, false);
    }
    pub fn openSearchFile(self: *Controller, path: []const u8, root_id: RootId, activation: SearchActivation, overlay: bool) bool {
        if (self.policy_pending or !self.app.workspace_search.validActivation(activation)) return false;
        return self.openFileRequest(path, root_id, activation, overlay);
    }
    fn openFileRequest(self: *Controller, path: []const u8, root_id: ?RootId, search_activation: ?SearchActivation, overlay: bool) bool {
        if (self.closed or self.app.editingFrozen() or self.app.rejectFileOperationBarrier() or self.app.workspaceOperationBusy()) return false;
        var base: ?[]const u8 = null;
        var token: ?identity.Token = null;
        if (root_id) |id| {
            const snapshot = if (self.model) |*m| m else return false;
            const root = snapshot.rootById(id) orelse return false;
            base = root.canonical_path orelse root.lexical_path;
            token = snapshot.scope.capture();
        }
        // Deduplicate before checking capacity, including when the budget is full.
        // Exact input spelling and boundary identity matter, not canonical aliases.
        for (self.jobs.items) |job| {
            if (job.kind == .file and job.root_id == root_id and std.meta.eql(job.search_activation, search_activation) and
                std.meta.eql(job.model_token, token) and
                self.app.workspace.accepts(job.document_token) and
                std.mem.eql(u8, job.path, path)) return true;
        }
        if (!self.admit(path, base)) {
            // Match the existing-file failure path during startup: a rejected
            // argument must not look like a closed, zero-document session.
            if (self.app.snapshotDocuments().len == 0 and !self.hasPendingFiles()) _ = self.app.newDocument();
            return false;
        }
        const job = self.work(.file, path);
        job.search_activation = search_activation;
        job.search_overlay = overlay;
        if (@import("build_options").test_hooks and search_activation != null) {
            if (self.app.workspace_search.test_activation_delay_us != 0) job.test_delay_us = @intCast(self.app.workspace_search.test_activation_delay_us);
            job.test_search_fail = self.app.workspace_search.test_activation_fail;
            self.app.workspace_search.test_activation_delay_us = 0;
            self.app.workspace_search.test_activation_fail = false;
        }
        if (search_activation != null) job.policy = if (self.policy) |policy| policy.ref() else explorer.Policy.create(self.model.?.exclude);
        job.root = if (base) |root| u.z(root) else null;
        job.root_id = root_id;
        job.model_token = token;
        self.run(job);
        return true;
    }
    fn work(self: *Controller, kind: Kind, path: []const u8) *Work {
        const job = a.create(Work) catch unreachable;
        job.* = .{ .controller = self, .kind = kind, .path = u.z(path), .document_token = self.app.workspace.capture().?, .cancel = c.g_cancellable_new().?, .manifest_generation = self.manifest_generation, .test_delay_us = if (@import("build_options").test_hooks) self.test_next_delay_us else 0 };
        self.test_next_delay_us = 0;
        return job;
    }
    fn run(self: *Controller, job: *Work) void {
        std.debug.assert(self.inFlight() < limits.in_flight);
        const bytes = inputBytes(job.path, job.root);
        std.debug.assert(bytes <= limits.request_bytes - self.request_bytes);
        self.jobs.append(a, job) catch unreachable;
        self.request_bytes += bytes;
        self.app.hold();
        self.dispatch(job);
    }
    fn dispatch(_: *Controller, job: *Work) void {
        job.delivering = false;
        const task = c.g_task_new(null, job.cancel, &done, job).?;
        c.g_task_set_task_data(task, job, null);
        // Never return early on cancellation: the worker still owns job storage.
        c.g_task_run_in_thread(task, &worker);
        c.g_object_unref(task);
    }
    fn reap(self: *Controller, job: *Work) void {
        for (self.jobs.items, 0..) |pending, index| if (pending == job) {
            _ = self.jobs.swapRemove(index);
            break;
        };
        self.request_bytes -= inputBytes(job.path, job.root);
        if (job.session_completion) |completion| completion(job.session_context.?, if (job.published) null else job.err orelse error.StaleWorkspace);
        job.destroy();
        self.app.release();
    }
    fn cancelWaitingLoad(self: *Controller) void {
        if (self.pending_load) |job| {
            self.pending_load = null;
            self.reap(job);
        }
    }
    fn prepareLoadWatches(self: *Controller, job: *Work) void {
        if (job.candidate) |*candidate| candidate.deinit();
        job.candidate = job.result;
        job.result = null;
        job.stage = .waiting_watch;
        job.test_delay_us = 0;
        self.pending_load = job;
        self.policy_pending = true;
        self.app.workspace_search.invalidate("Stale — workspace model is being refreshed.");
        self.manifest_first = 0;
        self.rebuildWatches(&job.candidate.?);
    }
    fn pollWatches(self: *Controller) void {
        self.watches.poll();
        if (self.watches.ready() and self.watch_seen != self.watches.generation) {
            self.watch_seen = self.watches.generation;
            // No page acquired before registration can survive the install gap.
            self.invalidateLoaded();
        }
    }
    fn progressLoad(self: *Controller) void {
        if (self.app.fileOperationBarrier()) return;
        const job = self.pending_load orelse return;
        if (!self.watches.ready()) return;
        if (job.stage == .waiting_watch) {
            if (self.watches_dirty) {
                self.rebuildWatches(&job.candidate.?);
                return;
            }
            job.watch_generation = self.watches.generation;
            job.manifest_generation = self.manifest_generation;
            job.stage = .validate;
            self.pending_load = null;
            self.dispatch(job);
        } else if (job.stage == .waiting_barrier) {
            if (self.watches_dirty or job.watch_generation != self.watches.generation or job.manifest_generation != self.manifest_generation) {
                self.prepareLoadWatches(job);
                return;
            }
            const drained = self.watches.barrier_done >= job.barrier;
            // Unavailable monitoring uses the visible manual-Rescan fallback;
            // it is not a successful notification-queue drain.
            const unavailable = self.watches.failed and self.watches.barrier_failed >= job.barrier;
            if (!drained and !unavailable) return;
            if (self.app.manager != null) {
                const ready = self.app.projects.beforeWorkspaceChange(&job.result.?) catch |err| {
                    self.pending_load = null;
                    self.loading = false;
                    job.err = err;
                    self.fail(err);
                    self.reap(job);
                    return;
                };
                if (!ready) return;
            }
            self.pending_load = null;
            self.publishLoad(job);
            self.reap(job);
        }
    }
    fn publishLoad(self: *Controller, job: *Work) void {
        if (self.app.fileOperationBarrier()) {
            self.loading = false;
            job.err = error.FileOperationBusy;
            return;
        }

        std.mem.swap(?[:0]u8, &self.manifest_canonical, &job.canonical);
        job.published = true;
        self.app.workspace_search.invalidate("Stale — workspace model changed. Refresh to search the current roots.");
        self.loading = false;
        self.policy_pending = false;
        self.manifest_first = 0;
        self.manifest_last = 0;
        self.error_name = null;
        if (self.model) |*previous| if (sameModel(previous, &job.result.?)) {
            const candidate = &job.result.?;
            for (@constCast(candidate.roots), previous.roots) |*root, old| root.id = old.id;
            // Transfer the full immutable policy, retaining routing/root IDs and
            // editor documents. The retired snapshot is destroyed with the job.
            std.mem.swap([]const model.Root, &previous.roots, &candidate.roots);
            std.mem.swap([]const []const u8, &previous.exclude, &candidate.exclude);
            std.mem.swap(model.settings.Config, &previous.workspace_settings, &candidate.workspace_settings);
            std.mem.swap([32]u8, &previous.policy_fingerprint, &candidate.policy_fingerprint);
            if (self.policy) |policy| policy.unref();
            self.policy = explorer.Policy.create(previous.exclude);
            self.invalidateLoaded();
            self.app.workspace_policy.modelChanged();
            if (self.app.manager != null) self.app.projects.cancelWorkspaceChange();
            self.render();
            return;
        };
        self.retireBrowse();
        self.clearTree();
        if (self.model) |*m| m.deinit();
        self.model = job.result;
        job.result = null;
        self.policy = explorer.Policy.create(self.model.?.exclude);
        self.roots();
        self.app.workspace_policy.modelChanged();
        self.app.refreshWorkspaceLabels();
        if (self.app.manager != null) self.app.projects.workspaceChanged();
        self.app.scheduleCheckpoint();
        self.app.message("Workspace opened in restricted mode. Documents kept. Recent Projects opens independent project windows; automatic sessions retain this window's tabs and layout.");
    }
    fn acceptsModel(self: *Controller, token: identity.Token) bool {
        return if (self.model) |*m| m.scope.accepts(token) else false;
    }
    fn scanPending(self: *const Controller) bool {
        if (self.manifest_first != 0 or self.watches_dirty or !self.watches.ready()) return true;
        for (self.tree.nodes.items) |node| if (node.busy or (node.queued and !self.policy_pending)) return true;
        return false;
    }
    pub fn probe(self: *Controller) void {
        const Root = struct { id: u64, name: []const u8, path: []const u8, canonical: ?[]const u8, availability: model.Availability };
        var roots_list: std.ArrayList(Root) = .empty;
        defer roots_list.deinit(a);
        if (self.model) |*m| for (m.roots) |root| {
            roots_list.append(a, .{ .id = @intCast(@backingInt(root.id)), .name = root.display_name, .path = root.lexical_path, .canonical = root.canonical_path, .availability = root.availability }) catch unreachable;
        };
        const Directory = struct { root: u64, path: []const u8, expanded: bool, busy: bool, queued: bool, entries: usize, complete: bool, generation: u64, err: ?[]const u8 };
        var directories: std.ArrayList(Directory) = .empty;
        defer directories.deinit(a);
        for (self.tree.nodes.items) |n| directories.append(a, .{ .root = @intCast(@backingInt(n.root)), .path = n.relative, .expanded = n.expanded, .busy = n.busy, .queued = n.queued, .entries = if (n.page) |p| p.entries.len else 0, .complete = n.complete, .generation = n.generation, .err = n.err }) catch unreachable;
        const queued_watches = self.watches.queued();
        const index = self.current();
        const node: ?explorer.Node = if (index) |i| self.tree.nodes.items[i] else null;
        const entries: []const fs.Entry = if (node) |n| if (n.page) |page| page.entries else &.{} else &.{};
        const text = std.json.Stringify.valueAlloc(a, .{ .roots = roots_list.items, .status = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, self.status))), .restricted = self.app.workspace_policy.policy.state != .trusted, .loading = self.loading, .scanning = self.scanPending(), .pending = self.jobs.items.len, .in_flight = self.inFlight(), .request_bytes = self.request_bytes, .choosing = self.choosing, .operation_limit = limits.in_flight, .request_byte_limit = limits.request_bytes, .selected = if (self.selected) |id| @as(?u64, @intCast(@backingInt(id))) else null, .relative = self.relative, .entries = entries, .truncated = false, .complete = if (node) |n| n.complete else false, .offset = if (node) |n| n.offset else 0, .visible_rows = self.tree.rows.items.len, .resident_pages = self.tree.pages(), .resident_bytes = self.tree.bytes(), .node_count = self.tree.nodes.items.len, .live_widgets = self.view.live_widgets, .peak_widgets = self.view.peak_widgets, .watches = self.watches.count, .watch_worker_limit = @as(usize, 1), .watch_queue_depth = queued_watches.count, .watch_queued_bytes = queued_watches.bytes, .watch_plan_byte_limit = watch.byte_limit, .watch_generation = self.watches.generation, .watch_ready = self.watches.ready(), .watch_worker_busy = self.watches.worker_busy.load(.acquire), .watch_builds = self.watches.builds.load(.monotonic), .watch_fallback = self.watches.failed, .selected_path = self.tree.selected_path, .loop_gap_us = self.test_max_tick_us, .draining = self.test_drain, .scans_started = self.scans_started, .resets = self.resets, .overflows = self.overflows, .directories = directories.items, .error_name = self.error_name, .manifest = if (self.model) |m| m.manifest_path else null }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_BROWSER %s\n", z.ptr);
    }
};
fn sameModel(x: *const model.Model, y: *const model.Model) bool {
    if (x.roots.len != y.roots.len) return false;
    if (!std.mem.eql(u8, x.manifest_path orelse "", y.manifest_path orelse "")) return false;
    for (x.roots, y.roots) |left, right| {
        if (!std.mem.eql(u8, left.lexical_path, right.lexical_path) or !std.mem.eql(u8, left.display_name, right.display_name)) return false;
        // Availability changes alone do not replace declared root identity. Keep
        // the original boundary; never retarget it to a different canonical root.
        if (left.canonical_path) |old| if (right.canonical_path) |new| if (!std.mem.eql(u8, old, new)) return false;
    }

    return true;
}
fn sameWatchRoots(x: *const model.Model, y: *const model.Model) bool {
    if (!sameModel(x, y)) return false;
    for (x.roots, y.roots) |left, right| if (!std.mem.eql(u8, left.canonical_path orelse "", right.canonical_path orelse "")) return false;
    return true;
}
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
    search_activation: ?SearchActivation = null,
    search_overlay: bool = false,
    document_token: identity.Token,
    request: ?identity.Token = null,
    model_token: ?identity.Token = null,
    epoch: u64 = 0,
    source: Source = .folder,
    manifest_generation: u64 = 0,
    cancel: *c.GCancellable,
    result: ?model.Model = null,
    candidate: ?model.Model = null,
    stage: enum { initial, waiting_watch, validate, waiting_barrier } = .initial,
    watch_generation: u64 = 0,
    watch_ready: bool = false,
    barrier: u64 = 0,
    listing: ?fs.Page = null,
    node: usize = 0,
    navigate: bool = false,
    node_generation: u64 = 0,
    continuation: ?fs.Continuation = null,
    policy: ?*explorer.Policy = null,
    canonical: ?[:0]u8 = null,
    err: ?anyerror = null,
    test_delay_us: c_ulong = 0,
    test_search_fail: bool = false,
    delivering: bool = false,
    session_context: ?*anyopaque = null,
    session_completion: ?*const fn (*anyopaque, ?anyerror) void = null,
    published: bool = false,
    fn destroy(self: *Work) void {
        if (self.policy) |policy| policy.unref();
        if (self.result) |*m| m.deinit();
        if (self.candidate) |*m| m.deinit();
        if (self.listing) |*listing| listing.deinit();
        if (self.canonical) |path| a.free(path);
        if (self.root) |path| a.free(path);
        a.free(self.path);
        c.g_object_unref(self.cancel);
        a.destroy(self);
    }
    fn perform(self: *Work) !void {
        if (c.g_cancellable_is_cancelled(self.cancel) != 0) return error.Cancelled;
        if (@import("build_options").test_hooks and self.test_search_fail) return error.TestSearchOpenFailed;
        switch (self.kind) {
            .load => {
                const path = try fs.absolute(a, self.path);
                defer a.free(path);
                self.result = switch (self.source) {
                    .folder => try model.Model.fromFolder(a, path),
                    .manifest => try model.Model.fromManifest(a, path),
                };
                if (self.canonical) |previous| a.free(previous);
                self.canonical = null;
                if (self.source == .manifest) {
                    const canonical = try @import("manifest_fs.zig").canonical(a, path);
                    defer a.free(canonical);
                    self.canonical = try a.dupeSentinel(u8, canonical, 0);
                }
            },
            .scan => self.listing = try fs.scanPage(a, self.root.?, self.path, self.policy.?.patterns, self.continuation, self.cancel),
            .file => {
                var checked: ?fs.CheckedDirectory = null;
                defer if (checked) |*directory| directory.deinit();
                var policy_work: fs.Work = .{};
                if (self.root) |root| {
                    if (!contained(root, self.path) or self.path.len <= root.len) return error.OutsideRoot;
                    const relative = self.path[root.len + @as(usize, if (root.len == 1) 0 else 1) ..];
                    if (self.search_activation != null) {
                        checked = try fs.CheckedDirectory.open(a, root, std.fs.path.dirname(relative) orelse "", self.policy.?.patterns, null, self.cancel, &policy_work);
                        if (!try checked.?.allowsOverlay(std.fs.path.basename(relative), &policy_work)) return error.OutsideRoot;
                    }
                    if (!self.search_overlay) try fs.checkFile(root, relative);
                }
                // A deleted dirty file is an existing document, not a request to
                // create/reload a missing file. Its safe parents/policy were checked.
                self.canonical = if (self.search_overlay) u.z(self.path) else try open_target.resolveExisting(a, self.path);
                if (checked) |*directory| try directory.validate(&policy_work);
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
    if (@import("build_options").test_hooks and job.session_completion != null and job.stage == .initial) {
        const gate = c.g_getenv("CORAL_TEST_SESSION_LOAD_PAUSE");
        if (gate != null and c.g_file_test(gate, c.G_FILE_TEST_EXISTS) != 0) {
            // Session preflight has passed, but the normal workspace pipeline
            // has not published. Let native tests mutate documents in this gap.
            c.g_print("CORAL_SESSION_WORKSPACE_LOAD_PAUSED\n");
            for (0..1000) |_| {
                if (c.g_cancellable_is_cancelled(job.cancel) != 0 or c.g_file_test(gate, c.G_FILE_TEST_EXISTS) == 0) break;
                c.g_usleep(10_000);
            }
        }
    }
    c.g_task_return_boolean(task, 1);
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Work, data.?);
    const self = job.controller;
    var retained = false;
    defer if (!retained) self.reap(job);
    job.delivering = true;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    if (self.closed or !self.app.workspace.accepts(job.document_token)) return;
    if (job.kind == .file and (self.app.editingFrozen() or self.app.rejectFileOperationBarrier())) return;
    if (job.request) |token| if (!self.requests.accepts(token)) return;
    if (job.model_token) |token| if (!self.acceptsModel(token)) return;
    if (job.kind == .scan and job.epoch != self.epoch) return;
    self.pollWatches();
    // Gate both success and error delivery before either can affect the current
    // navigation. Query identity alone cannot distinguish A then B activations.
    if (job.search_activation) |activation| if (!self.app.workspace_search.acceptActivationCompletion(activation)) return;
    if (job.kind == .scan) {
        const node = &self.tree.nodes.items[job.node];
        node.busy = false;
        self.scanning = false;
        for (self.tree.nodes.items) |n| {
            if (n.busy or n.queued) self.scanning = true;
        }
        if (node.generation != job.node_generation or !job.watch_ready or !self.watches.ready() or job.watch_generation != self.watches.generation or self.policy_pending) {
            node.navigate_pending = node.navigate_pending or job.navigate;
            if (!node.queued) node.invalidate();
            return;
        }
    }
    if (job.err) |err| {
        if (job.kind == .load) {
            self.loading = false;
            self.app.workspace_policy.modelFailed(err);
        }
        if (job.kind == .scan) {
            const node = &self.tree.nodes.items[job.node];
            node.clear();
            node.err = @errorName(err);
            self.render();
        }
        if (job.search_activation != null) self.app.workspace_search.invalidate("Search activation rejected: target or policy changed. Refresh required.");
        if (job.kind == .file) self.app.existingFailed(err) else self.fail(err);
        if (job.kind == .load and self.policy_pending) self.render();
        return;
    }
    if (c.g_cancellable_is_cancelled(job.cancel) != 0) return;
    switch (job.kind) {
        .load => {
            retained = true;
            if (job.stage == .initial or self.watches_dirty or job.watch_generation != self.watches.generation or job.manifest_generation != self.manifest_generation or !sameWatchRoots(&job.candidate.?, &job.result.?)) {
                self.prepareLoadWatches(job);
            } else {
                job.stage = .waiting_barrier;
                job.barrier = self.watches.barrier();
                self.pending_load = job;
            }
        },
        .scan => {
            const node = &self.tree.nodes.items[job.node];
            const page = job.listing.?;
            if (page.status == .reset_required) {
                // Never mix cookies/generations, including an empty incomplete page.
                self.resets += 1;
                directoryChanged(self, job.node);
                node.first_event = c.g_get_monotonic_time();
                node.last_event = node.first_event;
                self.scanning = true;
                self.render();
                return;
            }
            node.offset = if (job.continuation != null) node.next_offset else 0;
            node.next_offset = node.offset + page.entries.len;
            self.tree.install(job.node, page);
            job.listing = null;
            if (@import("build_options").test_hooks and self.test_drain) {
                const text = std.json.Stringify.valueAlloc(a, .{ .entries = page.entries, .complete = page.complete, .offset = node.offset }, .{}) catch unreachable;
                defer a.free(text);
                const z = u.z(text);
                defer a.free(z);
                c.g_print("CORAL_EXPLORER_PAGE %s\n", z.ptr);
            }
            // Background refresh must not steal selection from another directory/file.
            if (job.navigate) self.focusNode(job.node);
            self.render();
        },
        .file => if (job.search_activation) |activation| self.app.workspace_search.acceptOpen(job.canonical.?, activation) else self.app.acceptExisting(job.canonical.?),
    }
}
const Choice = struct { controller: *Controller, source: Source, token: identity.Token };
fn chosen(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const choice = u.cast(Choice, data.?);
    const self = choice.controller;
    defer a.destroy(choice);
    // Release the reserved slot before handing it to a worker, but retain the
    // exact App until this callback has consumed the chooser result.
    self.choosing = false;
    defer self.app.release();
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
fn closeActions(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    c.gtk_popover_popdown(u.cast(c.GtkPopover, data.?));
}
fn statusChanged(label: ?*c.GtkLabel, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    c.gtk_widget_set_tooltip_text(u.cast(c.GtkWidget, label.?), c.gtk_label_get_text(label));
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
fn resetClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.resetTree();
}
fn closeClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.closeWorkspace();
}
fn selectionChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.closed or self.rendering) return;
    const index = c.gtk_single_selection_get_selected(self.view.selection);
    if (index >= self.tree.rows.items.len) return;
    const row = self.tree.rows.items[index];
    if (row.more) return;
    const node = self.tree.nodes.items[row.node];
    // Watch invalidation can precede the next batched render by one source tick.
    const page = node.page orelse return;
    if (row.entry == null or row.entry.? >= page.entries.len or page.entries[row.entry.?].kind == .directory) return;
    // Expander activation should not erase a selected descendant when hiding it.
    const path = std.fs.path.join(a, &.{ node.relative, page.entries[row.entry.?].name }) catch unreachable;
    defer a.free(path);
    self.tree.select(node.root, path);
}
fn rowActivated(_: ?*c.GtkListView, index: c_uint, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).browser.activateVisible(index);
}
fn directoryChanged(data: ?*anyopaque, index: usize) void {
    const self = u.cast(Controller, data.?);
    if (self.closed) return;
    self.app.workspace_policy.recheck();
    self.app.workspace_search.invalidate("Stale — workspace watch event. Refresh to search current contents.");
    if (index == watch.overflow_index) {
        self.overflows += 1;
        const now = c.g_get_monotonic_time();
        for (self.tree.nodes.items) |*node| {
            node.invalidate();
            node.first_event = now;
            node.last_event = now;
        }
        for (self.jobs.items) |job| if (job.kind == .scan) c.g_cancellable_cancel(job.cancel);
        if (self.model) |snapshot| if (snapshot.manifest_path != null) directoryChanged(self, std.math.maxInt(usize));
        self.watches_dirty = true;
        self.render_pending = true;
        self.app.message("Directory event queue lost notifications. Rebuilding watches and refreshing accessed directories; unopened directories remain lazy.");
        return;
    }
    if (index == std.math.maxInt(usize)) {
        const now = c.g_get_monotonic_time();
        if (self.manifest_first == 0) self.manifest_first = now;
        self.manifest_last = now;
        self.manifest_generation +%= 1;
        self.policy_pending = true;
        for (self.tree.nodes.items) |*node| node.invalidate();
        for (self.jobs.items) |job| if (job.kind == .scan) c.g_cancellable_cancel(job.cancel);
        self.render_pending = true;
        self.watches_dirty = true;
        return;
    }
    if (index >= self.tree.nodes.items.len) return;
    const parent = self.tree.nodes.items[index];
    const now = c.g_get_monotonic_time();
    for (self.tree.nodes.items, 0..) |*node, i| {
        if (node.root != parent.root or !(std.mem.eql(u8, node.relative, parent.relative) or parent.relative.len == 0 or (std.mem.startsWith(u8, node.relative, parent.relative) and node.relative.len > parent.relative.len and node.relative[parent.relative.len] == '/'))) continue;
        if (node.first_event == 0) node.first_event = now;
        node.last_event = now;
        if (!node.queued) node.invalidate();
        for (self.jobs.items) |job| if (job.kind == .scan and job.node == i) c.g_cancellable_cancel(job.cancel);
    }
    self.render_pending = true;
    self.watches_dirty = self.watches_dirty or self.watches.rearm;
}
fn watchWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    u.cast(Controller, data.?).watches.run();
    c.g_task_return_boolean(task, 1);
}
fn watchDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    self.watch_running = false;
    self.app.release();
}
fn pump(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    if (self.closing_workspace and !self.closed) self.closeWorkspace();
    if (self.closed) return 0;
    const now = c.g_get_monotonic_time();
    self.pollWatches();
    self.progressLoad();
    if (self.render_pending) {
        self.render_pending = false;
        self.render();
    }
    if (self.watches_dirty and !self.loading) {
        if (self.model) |*snapshot| {
            self.rebuildWatches(snapshot);
            self.requirePolicyRefresh();
        } else self.watches_dirty = false;
    }
    if (!self.app.fileOperationBarrier() and !self.app.workspaceOperationBusy() and self.watches.ready() and self.manifest_first != 0 and !self.loading and !self.choosing and self.inFlight() < limits.in_flight and (now - self.manifest_last >= 100000 or now - self.manifest_first >= 500000)) {
        self.manifest_first = 0;
        if (self.model) |snapshot| if (snapshot.manifest_path) |path| self.load(.manifest, path);
    }
    if (@import("build_options").test_hooks) {
        if (self.test_last_tick != 0) self.test_max_tick_us = @max(self.test_max_tick_us, now - self.test_last_tick);
        self.test_last_tick = now;
        if (self.test_drain) if (self.current()) |index| {
            const node = self.tree.nodes.items[index];
            if (!node.busy and !node.queued) {
                if (node.complete) self.test_drain = false else self.moreNode(index);
            }
        };
    }
    self.scanning = false;
    for (self.tree.nodes.items, 0..) |node, i| {
        if (node.busy or (node.queued and !self.policy_pending)) self.scanning = true;
        if (!node.queued or node.busy or self.policy_pending or !self.watches.ready()) continue;
        if (node.first_event != 0 and now - node.last_event < 100000 and now - node.first_event < 500000) continue;
        if (self.inFlight() >= limits.in_flight) break;
        self.scanNode(i, false);
        // One admission per GTK source dispatch; no unbounded GTask fan-out.
        break;
    }
    return 1;
}
