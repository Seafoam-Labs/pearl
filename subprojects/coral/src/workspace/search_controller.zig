//! GTK-owned search routing and snapshots. One active session, one latest query,
//! one batch in transit. A GTask turn owns the session until its callback reaps it;
//! cancellation never frees worker inputs. Workers never touch App/GTK widgets.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const Document = @import("../document.zig").Document;
const identity = @import("identity.zig");
const search = @import("search.zig");
const View = @import("search_view.zig").View;
const hooks = @import("build_options").test_hooks;

pub const limits = struct {
    pub const documents = 4096;
    pub const overlay_count = 128;
    pub const overlay_bytes = 4 * 1024 * 1024;
    pub const file_bytes = 1024 * 1024;
    pub const metadata_bytes = 1024 * 1024;
    pub const results = 1024;
    pub const debounce_us = 150000;
};
// An omitted overlay must still shadow disk. The backend checks size before
// inspecting content, so all omitted buffers share this immutable sentinel.
const omitted_overlay: [limits.file_bytes + 1]u8 = @splat(0);
const Revision = struct { id: u64, revision: u64, path: ?[]const u8, dirty: bool };
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    refs: usize = 1,
    token: identity.Token,
    document_scope: identity.Token,
    generation: u64,
    inputs: search.Inputs,
    revisions: []const Revision,
    overlay_bytes: usize = 0,
    omitted: usize = 0,
    unavailable_roots: usize = 0,
    fn unref(self: *Snapshot) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Activation = struct { generation: u64, serial: u64 };
const Navigation = struct {
    activation: Activation,
    // Owned independently of streamed results: replacements can reorder/remove
    // this result while its root-bound open or initial load is still in flight.
    result: search.Result,
    group: u64,
    document: ?u64 = null,

    fn deinit(self: *Navigation) void {
        a.free(self.result.relative_path);
        a.free(self.result.preview);
    }
};

pub const Controller = struct {
    app: *App,
    view: View,
    present: ?*const fn (*App, search.Mode) void = null,
    dismiss: ?*const fn (*App, bool) void = null,
    mode: search.Mode = .quick_open,
    query: []const u8 = "",
    generation: u64 = 1,
    snapshot: ?*Snapshot = null,
    active: ?*Job = null,
    pending: bool = false,
    due: i64 = 0,
    source: c_uint = 0,
    closed: bool = false,
    stale: bool = true,
    status: search.Status = .cancelled,
    reasons: search.Reasons = .{},
    progress: search.Progress = .{},
    error_name: ?[]const u8 = null,
    results: std.ArrayList(search.Result) = .empty,
    render_pending: bool = false,
    rows_dirty: bool = false,
    navigation: ?Navigation = null,
    committing_document: ?u64 = null,
    started: u64 = 0,
    reaped: u64 = 0,
    cancelled: u64 = 0,
    discarded: u64 = 0,
    batches: u64 = 0,
    activations: u64 = 0,
    activation_serial: u64 = 0,
    discarded_activations: u64 = 0,
    test_delay_us: u64 = 0,
    test_activation_delay_us: u64 = 0,
    test_activation_fail: bool = false,
    max_snapshot_us: i64 = 0,
    max_tick_us: i64 = 0,
    last_tick: i64 = 0,

    pub fn init(app: *App, parent: u.W) Controller {
        return .{ .app = app, .view = View.init(parent, &app.workspace_search, &queryChanged, &activateRow, &refreshClicked, &closeClicked) };
    }
    pub fn attach(self: *Controller) void {
        self.view.attach();
        self.source = c.g_timeout_add(25, &pump, self);
    }
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.invalidate("Search closed.");
        self.closed = true;
        if (self.source != 0) _ = c.g_source_remove(self.source);
        self.source = 0;
    }
    pub fn deinit(self: *Controller) void {
        self.shutdown();
        std.debug.assert(self.active == null);
        self.view.deinit();
        self.results.deinit(a);
        if (self.query.len != 0) a.free(self.query);
    }
    pub fn show(self: *Controller, mode: search.Mode) void {
        if (self.closed) return;
        self.mode = mode;
        if (self.present) |present| present(self.app, mode);
        self.view.show(mode);
        self.refresh();
    }
    pub fn hide(self: *Controller) void {
        if (self.closed) return;
        self.invalidate("Search cancelled.");
        if (self.dismiss) |dismiss| dismiss(self.app, true) else {
            c.gtk_widget_set_visible(self.view.panel, 0);
            self.app.focusEditor();
        }
    }
    pub fn setQuery(self: *Controller, mode: search.Mode, text: []const u8) void {
        if (self.closed) return;
        self.mode = mode;
        if (self.present) |present| present(self.app, mode);
        self.view.show(mode);
        self.view.setQuery(text);
        self.refresh();
    }
    pub fn refresh(self: *Controller) void {
        if (self.closed) return;
        self.invalidate("Waiting for query…");
        const text = u.entryText(self.view.entry);
        if (self.query.len != 0) a.free(self.query);
        self.query = "";
        if (text.len > 1024 or !std.unicode.utf8ValidateSlice(text)) {
            self.error_name = "InvalidQuery";
            u.setLabel(self.view.status, "Query must be valid UTF-8 and at most 1024 bytes.");
            return;
        }
        if (text.len != 0) self.query = u.z(text);
        if (self.mode == .text and text.len == 0) {
            u.setLabel(self.view.status, "Type literal text to search workspace files. No files are changed.");
            return;
        }
        self.pending = true;
        self.due = c.g_get_monotonic_time() + limits.debounce_us;
    }
    pub fn invalidate(self: *Controller, message: []const u8) void {
        if (self.closed) return;
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Search generation exhausted");
        self.pending = false;
        self.stale = true;
        self.status = .cancelled;
        self.clearNavigation();
        self.error_name = null;
        if (self.active) |job| if (c.g_cancellable_is_cancelled(job.cancel) == 0) {
            self.cancelled += 1;
            c.g_cancellable_cancel(job.cancel);
        };
        if (self.snapshot) |snapshot| snapshot.unref();
        self.snapshot = null;
        self.clearResults();
        self.view.clear();
        self.rows_dirty = false;
        self.render_pending = false;
        u.setLabel(self.view.status, message);
    }
    pub fn documentChanged(self: *Controller, document: *Document) void {
        if (self.committing_document == document.id) return;
        // No automatic restart on editor typing. Query typing/Refresh starts a
        // fresh snapshot; a completed result set is invalidated just like a scan.
        if (self.snapshot != null or self.pending or self.active != null)
            self.invalidate("Stale — document changed. Refresh or edit the query to search again.");
    }
    fn capturedDocument(self: *Controller, id: u64) bool {
        const snapshot = self.snapshot orelse return false;
        for (snapshot.revisions) |revision| if (revision.id == id) return true;
        return false;
    }
    pub fn loadStarted(self: *Controller, document: *Document) void {
        // Loading is a revision transition, even before GTK changes the buffer.
        // Never wait for a reload of a document named by the search snapshot.
        if (self.capturedDocument(document.id) or self.pending) {
            self.invalidate("Stale — document load started. Refresh after loading finishes.");
        } else if (self.navigation) |nav| if (nav.document == document.id) {
            self.invalidate("Stale — search target started another load. Refresh required.");
        };
    }
    pub fn beforeLoad(self: *Controller, document: *Document) void {
        // Only an initial load into a pristine document absent from the snapshot
        // can bypass edit invalidation. This also lets a superseded activation's
        // initial load finish without invalidating its successor. No captured
        // revision is advanced or exempted to make a reload look current.
        if (!self.capturedDocument(document.id) and document.revision == 0 and !document.dirty() and
            c.gtk_text_buffer_get_char_count(document.buffer) == 0 and self.validGeneration(self.generation))
        {
            self.committing_document = document.id;
            return;
        }
        self.documentChanged(document);
    }
    pub fn afterLoad(self: *Controller, document: *Document) void {
        self.committing_document = null;
        self.navigate(document);
    }
    pub fn loadSettled(self: *Controller, document_id: u64) void {
        const nav = self.navigation orelse return;
        if (nav.document != document_id) return;
        if (self.app.documents.get(document_id)) |document| {
            if (document.loading or document.pending != null) return;
        }
        self.invalidate("Search target did not finish loading. Refresh before trying again.");
    }
    fn clearNavigation(self: *Controller) void {
        if (self.navigation) |*nav| nav.deinit();
        self.navigation = null;
    }
    fn beginNavigation(self: *Controller, result: search.Result, group: u64) Activation {
        self.clearNavigation();
        self.activation_serial = std.math.add(u64, self.activation_serial, 1) catch @panic("Search activation serial exhausted");
        const activation: Activation = .{ .generation = self.generation, .serial = self.activation_serial };
        var owned = result;
        owned.relative_path = u.z(result.relative_path);
        owned.preview = u.z(result.preview);
        self.navigation = .{ .activation = activation, .result = owned, .group = group };
        return activation;
    }
    pub fn validActivation(self: *Controller, activation: Activation) bool {
        const nav = self.navigation orelse return false;
        return std.meta.eql(nav.activation, activation) and self.validGeneration(activation.generation);
    }
    pub fn acceptActivationCompletion(self: *Controller, activation: Activation) bool {
        if (self.validActivation(activation)) return true;
        self.discarded_activations += 1;
        return false;
    }
    fn clearResults(self: *Controller) void {
        self.rows_dirty = true;
        for (self.results.items) |result| {
            a.free(result.relative_path);
            a.free(result.preview);
        }
        self.results.clearRetainingCapacity();
    }
    fn validSnapshot(self: *Controller, snapshot: *const Snapshot) bool {
        if (self.closed or self.app.closing or self.app.browser.policy_pending or self.generation != snapshot.generation or !self.app.workspace.accepts(snapshot.document_scope)) return false;
        const model = if (self.app.browser.model) |*m| m else return false;
        if (!model.scope.accepts(snapshot.token)) return false;
        const documents = self.app.snapshotDocuments();
        for (snapshot.revisions, 0..) |revision, i| {
            const document = if (i < documents.len and documents[i].id == revision.id) documents[i] else self.app.documents.get(revision.id) orelse return false;
            if (document.loading or document.pending != null or document.revision != revision.revision or document.dirty() != revision.dirty) return false;
            if (revision.path) |path| {
                if (document.path == null or !std.mem.eql(u8, document.path.?, path)) return false;
            } else if (document.path != null) return false;
        }
        return true;
    }
    pub fn validGeneration(self: *Controller, generation: u64) bool {
        if (generation != self.generation or self.stale) return false;
        return if (self.snapshot) |snapshot| self.validSnapshot(snapshot) else false;
    }
    fn capture(self: *Controller) !*Snapshot {
        const model = if (self.app.browser.model) |*m| m else return error.NoWorkspace;
        if (self.app.browser.policy_pending) return error.PolicyPending;
        const docs = self.app.snapshotDocuments();
        if (docs.len > limits.documents) return error.TooManyDocuments;
        const snapshot = try a.create(Snapshot);
        snapshot.* = .{ .arena = .init(a), .token = model.scope.capture().?, .document_scope = self.app.workspace.capture().?, .generation = self.generation, .inputs = undefined, .revisions = &.{} };
        errdefer snapshot.unref();
        const alloc = snapshot.arena.allocator();
        var roots: std.ArrayList(search.Root) = .empty;
        for (model.roots) |root| {
            if (root.canonical_path) |path| {
                try roots.append(alloc, .{ .id = root.id, .canonical_path = try alloc.dupe(u8, path) });
            } else snapshot.unavailable_roots += 1;
        }
        if (roots.items.len == 0) return error.NoAvailableRoots;
        const excludes = try alloc.alloc([]const u8, model.exclude.len);
        for (model.exclude, 0..) |pattern, i| excludes[i] = try alloc.dupe(u8, pattern);
        const revisions = try alloc.alloc(Revision, docs.len);
        var overlays: std.ArrayList(search.Overlay) = .empty;
        var metadata_bytes: usize = 0;
        var copied: usize = 0;
        var inspected: usize = 0;
        for (docs, 0..) |document, i| {
            const path = document.path;
            if (path) |p| {
                if (p.len > limits.metadata_bytes - metadata_bytes) return error.DocumentPathBudget;
                metadata_bytes += p.len;
            }
            revisions[i] = .{ .id = document.id, .revision = document.revision, .path = if (path) |p| try alloc.dupe(u8, p) else null, .dirty = document.dirty() };
            if (path == null) continue;
            const root_id = (try model.ownerOfCanonicalPath(path.?)) orelse continue;
            if (document.loading or document.pending != null) return error.DocumentLoading;
            if (!document.dirty()) continue;
            const base = model.rootById(root_id).?.canonical_path.?;
            const offset = base.len + @as(usize, if (base.len == 1) 0 else 1);
            if (path.?.len <= offset) continue;
            var text: []const u8 = &omitted_overlay;
            const chars: usize = @intCast(c.gtk_text_buffer_get_char_count(document.buffer));
            // First bound GTK's allocation by scalar count, then inspect actual
            // bytes. Temporary GTK text is <=4 MiB; retained payload <=4 MiB.
            if (copied < limits.overlay_count and inspected < limits.overlay_bytes and chars <= limits.file_bytes and chars <= limits.overlay_bytes - snapshot.overlay_bytes) {
                copied += 1;
                var start: c.GtkTextIter = undefined;
                var end: c.GtkTextIter = undefined;
                c.gtk_text_buffer_get_bounds(document.buffer, &start, &end);
                const raw = c.gtk_text_buffer_get_slice(document.buffer, &start, &end, 1);
                defer c.g_free(raw);
                const bytes = std.mem.span(raw);
                inspected += bytes.len;
                if (bytes.len <= limits.file_bytes and bytes.len <= limits.overlay_bytes - snapshot.overlay_bytes) {
                    text = try alloc.dupe(u8, bytes);
                    snapshot.overlay_bytes += bytes.len;
                }
            }
            if (text.ptr == &omitted_overlay) snapshot.omitted += 1;
            try overlays.append(alloc, .{ .root_id = root_id, .relative_path = try alloc.dupe(u8, path.?[offset..]), .document_id = document.id, .revision = document.revision, .text = text });
        }
        snapshot.revisions = revisions;
        snapshot.inputs = .{ .mode = self.mode, .query = try alloc.dupe(u8, self.query), .roots = roots.items, .excludes = excludes, .overlays = overlays.items, .limits = .{ .results = limits.results } };
        return snapshot;
    }
    fn startSession(self: *Controller) void {
        std.debug.assert(self.active == null);
        self.pending = false;
        const began = c.g_get_monotonic_time();
        const snapshot = self.capture() catch |err| {
            self.error_name = @errorName(err);
            self.status = .failed;
            const message = u.fmt("Search unavailable: {s}. Refresh after resolving this condition.", .{@errorName(err)});
            defer a.free(message);
            u.setLabel(self.view.status, message);
            return;
        };
        self.max_snapshot_us = @max(self.max_snapshot_us, c.g_get_monotonic_time() - began);
        self.snapshot = snapshot;
        self.stale = false;
        self.status = .running;
        self.reasons = .{};
        self.progress = .{};
        const job = a.create(Job) catch unreachable;
        snapshot.refs += 1;
        job.* = .{ .controller = self, .snapshot = snapshot, .cancel = c.g_cancellable_new().?, .batch = search.Batch.init(a), .delay_us = if (hooks) self.test_delay_us else 0 };
        self.test_delay_us = 0;
        self.active = job;
        self.started += 1;
        self.app.hold();
        self.render_pending = true;
        dispatch(job);
    }
    fn consume(self: *Controller, batch: *const search.Batch) void {
        self.batches += 1;
        self.status = batch.status;
        self.reasons = batch.reasons;
        self.progress = batch.progress;
        if (batch.failure) |err| self.error_name = @errorName(err);

        const replacement_changed = batch.delivery == .replace and !sameResults(self.results.items, batch.results);
        if (batch.discard_previous or replacement_changed) self.clearResults();
        if (batch.discard_previous or batch.status == .failed or batch.status == .reset_required) {
            self.clearResults();
            self.stale = true;
            self.clearNavigation();
        } else if (batch.delivery == .append or replacement_changed) {
            self.rows_dirty = self.rows_dirty or batch.results.len != 0;
            for (batch.results) |result| {
                if (self.results.items.len == limits.results) break;
                var owned = result;
                owned.relative_path = u.z(result.relative_path);
                owned.preview = u.z(result.preview);
                self.results.append(a, owned) catch unreachable;
            }
        }
        self.render_pending = true;
        // A displayed rank must never activate a different, not-yet-rendered path.
        if (replacement_changed or self.stale) self.render();
    }
    fn renderRows(self: *Controller) void {
        // Stable indices are session-result indices, not list/header positions.
        const selected_row = c.gtk_single_selection_get_selected(self.view.list.selection);
        const selected = if (selected_row < self.view.rows.items.len) self.view.rows.items[selected_row] else null;
        self.view.clear();
        var order: [limits.results]usize = undefined;
        for (0..self.results.items.len) |i| order[i] = i;
        if (self.mode == .text) std.mem.sort(usize, order[0..self.results.items.len], self, resultLessThan);
        var last_root: ?search.RootId = null;
        var last_path: ?[]const u8 = null;
        for (order[0..self.results.items.len]) |i| {
            const result = self.results.items[i];
            const model = if (self.app.browser.model) |*m| m else break;
            const root = model.rootById(result.root_id) orelse continue;
            if (self.mode == .text) {
                if (last_root != result.root_id) {
                    const title = u.fmt("{s} — {s} [root {d}]", .{ root.display_name, root.canonical_path orelse root.lexical_path, @backingInt(root.id) });
                    defer a.free(title);
                    self.view.append(title, null);
                    last_path = null;
                }
                if (last_path == null or !std.mem.eql(u8, last_path.?, result.relative_path)) self.view.append(result.relative_path, null);
                const line = u.fmt("    {d}:{d}  {s}{s}", .{ result.line + 1, result.column + 1, result.preview, if (result.source == .overlay) "  [unsaved]" else "" });
                defer a.free(line);
                self.view.append(line, i);
            } else {
                const line = u.fmt("{s} — {s} ({s}) [root {d}]{s}", .{ result.relative_path, root.display_name, root.canonical_path orelse root.lexical_path, @backingInt(root.id), if (result.source == .overlay) " [unsaved]" else "" });
                defer a.free(line);
                self.view.append(line, i);
            }
            last_root = result.root_id;
            last_path = result.relative_path;
        }
        self.view.selectFirst();
        if (selected) |index| if (self.mode == .text) for (self.view.rows.items, 0..) |item, row| {
            if (item == index) {
                c.gtk_single_selection_set_selected(self.view.list.selection, @intCast(row));
                break;
            }
        };
    }
    fn render(self: *Controller) void {
        self.render_pending = false;
        if (self.rows_dirty) {
            self.rows_dirty = false;
            self.renderRows();
        }
        var reasons: std.ArrayList(u8) = .empty;
        defer reasons.deinit(a);
        var iterator = self.reasons.iterator();
        while (iterator.next()) |reason| {
            if (reasons.items.len != 0) reasons.appendSlice(a, ", ") catch unreachable;
            reasons.appendSlice(a, @tagName(reason)) catch unreachable;
        }
        const missing = if (self.snapshot) |s| s.unavailable_roots else 0;
        if (missing != 0) {
            if (reasons.items.len != 0) reasons.appendSlice(a, ", ") catch unreachable;
            reasons.appendSlice(a, "unavailable_roots") catch unreachable;
        }
        const label = u.fmt("{s} · {d} results · {d} files · {d} bytes{s}{s}{s}{s} · Snapshot: Refresh for unmonitored changes", .{
            if (self.stale) "Stale — Refresh required" else if (self.status == .complete and missing != 0) "Incomplete — unavailable roots" else switch (self.status) {
                .running => "Searching (partial)",
                .complete => "Complete",
                .incomplete => "Incomplete",
                .cancelled => "Cancelled (partial)",
                .reset_required => "Stale — Refresh required",
                .failed => "Failed — Refresh required",
            },
            self.results.items.len,
            self.progress.files,
            self.progress.scanned_bytes,
            if (reasons.items.len != 0) " · omissions: " else "",
            reasons.items,
            if (self.error_name != null) " · " else "",
            self.error_name orelse "",
        });
        defer a.free(label);
        u.setLabel(self.view.status, label);
        c.gtk_widget_set_tooltip_text(self.view.status, label);
    }
    pub fn activate(self: *Controller, index: usize) void {
        if (!self.validGeneration(self.generation) or index >= self.results.items.len) {
            self.invalidate("Stale — refresh before opening a search result.");
            return;
        }
        const result = self.results.items[index];
        const activation = self.beginNavigation(result, self.app.activeGroupId());
        if (result.source == .overlay) {
            const document = self.app.documents.get(result.source.overlay.document_id) orelse return;
            if (document.revision != result.source.overlay.revision) {
                self.invalidate("Stale — unsaved document changed.");
                return;
            }
            self.navigation.?.document = document.id;
        }
        const root = self.app.browser.model.?.rootById(result.root_id) orelse return;
        const path = std.fs.path.join(a, &.{ root.canonical_path.?, result.relative_path }) catch unreachable;
        defer a.free(path);
        if (self.app.documents.findPath(path)) |document| if (document.loading or document.pending != null) {
            self.invalidate("Search target is loading. Refresh after loading finishes.");
            return;
        };
        if (!self.app.browser.openSearchFile(path, result.root_id, activation, result.source == .overlay)) self.clearNavigation();
    }
    pub fn acceptOpen(self: *Controller, canonical: []const u8, activation: Activation) void {
        if (!self.validActivation(activation)) return;
        const nav = self.navigation.?;
        const result = nav.result;
        const root = self.app.browser.model.?.rootById(result.root_id) orelse return;
        const expected = std.fs.path.join(a, &.{ root.canonical_path.?, result.relative_path }) catch unreachable;
        defer a.free(expected);
        if (!std.mem.eql(u8, canonical, expected)) {
            self.invalidate("Search target changed. Refresh required.");
            return;
        }
        if (self.app.groups.get(nav.group) == null) {
            self.clearNavigation();
            return;
        }
        if (self.app.documents.findPath(canonical)) |document| {
            if (document.loading or document.pending != null) {
                self.invalidate("Search target is loading. Refresh after loading finishes.");
                return;
            }
            self.navigation.?.document = document.id;
            self.navigate(document);
        } else {
            self.app.focusGroup(nav.group);
            self.app.acceptExisting(canonical);
            if (!self.validActivation(activation)) return;
            if (self.app.documents.findPath(canonical)) |document| {
                self.navigation.?.document = document.id;
            }
        }
    }
    fn navigate(self: *Controller, document: *Document) void {
        var nav = self.navigation orelse return;
        if (nav.document != document.id or !self.validActivation(nav.activation)) return;
        if (document.loading or document.pending != null) return;
        self.navigation = null;
        defer nav.deinit();
        self.app.navigateSearch(document, nav.group, nav.result, self.mode, self.query) catch |err| {
            self.invalidate("Search location changed or is unavailable. Refresh required.");
            self.error_name = @errorName(err);
            return;
        };
        self.activations += 1;
        // Do not invalidate the generation/navigation when dismissing a
        // committed Quick Open. Explicit cancellation goes through hide().
        if (self.mode == .quick_open) {
            if (self.dismiss) |dismiss| dismiss(self.app, false) else c.gtk_widget_set_visible(self.view.panel, 0);
        }
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        var reasons: std.ArrayList([]const u8) = .empty;
        defer reasons.deinit(a);
        var it = self.reasons.iterator();
        while (it.next()) |reason| reasons.append(a, @tagName(reason)) catch unreachable;
        const text = std.json.Stringify.valueAlloc(a, .{
            .mode = self.mode,
            .query = self.query,
            .generation = self.generation,
            .workspace = if (self.snapshot) |s| @as(?u64, @backingInt(s.token.workspace)) else null,
            .workspace_generation = if (self.snapshot) |s| @as(?u64, s.token.generation) else null,
            .status = self.status,
            .stale = self.stale,
            .complete = self.status == .complete and !self.stale and (if (self.snapshot) |s| s.unavailable_roots == 0 else false),
            .visible = c.gtk_widget_is_visible(self.view.panel) != 0,
            .pending = self.pending,
            .active = self.active != null,
            .recursive_monitoring = false,
            .watch_fallback = self.app.browser.watches.failed,
            .worker_limit = @as(usize, 1),
            .pending_limit = @as(usize, 1),
            .mailbox_limit = @as(usize, 1),
            .started = self.started,
            .reaped = self.reaped,
            .cancelled = self.cancelled,
            .discarded = self.discarded,
            .batches = self.batches,
            .activations = self.activations,
            .navigation_pending = self.navigation != null,
            .activation_serial = self.activation_serial,
            .discarded_activations = self.discarded_activations,
            .navigation_activation = if (self.navigation) |nav| @as(?Activation, nav.activation) else null,
            .navigation_result = if (self.navigation) |nav| @as(?search.Result, nav.result) else null,
            .selected_index = self.view.selected(),
            .rows = self.view.rows.items.len,
            .holds = @as(usize, @intFromBool(self.active != null)),
            .results = self.results.items,
            .progress = self.progress,
            .reasons = reasons.items,
            .error_name = self.error_name,
            .document_revisions = if (self.snapshot) |s| s.revisions else &.{},
            .overlay_bytes = if (self.snapshot) |s| s.overlay_bytes else 0,
            .omitted_overlays = if (self.snapshot) |s| s.omitted else 0,
            .unavailable_roots = if (self.snapshot) |s| s.unavailable_roots else 0,
            .overlay_byte_limit = limits.overlay_bytes,
            .overlay_count_limit = limits.overlay_count,
            .document_limit = limits.documents,
            .result_limit = limits.results,
            .live_widgets = self.view.list.live_widgets,
            .peak_widgets = self.view.list.peak_widgets,
            .snapshot_us = self.max_snapshot_us,
            .loop_gap_us = self.max_tick_us,
            .label = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, self.view.status))),
        }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_SEARCH %s\n", z.ptr);
    }
};
const Job = struct {
    controller: *Controller,
    snapshot: *Snapshot,
    cancel: *c.GCancellable,
    session: ?search.Session = null,
    batch: search.Batch,
    delay_us: u64 = 0,
    err: ?anyerror = null,
    retiring: bool = false,
};
fn dispatch(job: *Job) void {
    const task = c.g_task_new(null, job.cancel, &done, job).?;
    c.g_task_set_task_data(task, job, null);
    c.g_task_run_in_thread(task, &worker);
    c.g_object_unref(task);
}
fn worker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(Job, data.?);
    defer c.g_task_return_boolean(task, 1);
    defer if (job.retiring or job.err != null or job.batch.status != .running) {
        if (job.session) |*session| session.deinit();
        job.session = null;
    };
    if (job.retiring) return;
    if (hooks and job.delay_us != 0) {
        c.g_usleep(@intCast(job.delay_us));
        job.delay_us = 0;
    }
    if (c.g_cancellable_is_cancelled(job.cancel) != 0) {
        job.batch.status = .cancelled;
        return;
    }
    if (job.session == null) job.session = search.Session.init(a, job.snapshot.inputs, job.cancel) catch |err| {
        job.err = err;
        return;
    };
    job.session.?.next(&job.batch) catch |err| {
        job.err = err;
    };
}
fn done(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(Job, data.?);
    const self = job.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    const valid = self.validSnapshot(job.snapshot) and c.g_cancellable_is_cancelled(job.cancel) == 0;
    if (!job.retiring and valid) {
        if (job.err) |err| {
            self.clearResults();
            self.clearNavigation();
            self.stale = true;
            self.status = .failed;
            self.error_name = @errorName(err);
            self.render_pending = true;
            self.render();
        } else self.consume(&job.batch);
        if (job.err == null and job.batch.status == .running) {
            dispatch(job);
            return;
        }
    } else if (!job.retiring) {
        self.discarded += 1;
        if (!self.closed and self.generation == job.snapshot.generation) self.invalidate("Stale — workspace or document changed. Refresh required.");
    }
    // Even descriptor retirement stays off GTK. Keep the same slot and hold
    // through this final worker turn if cancellation raced a running batch.
    if (job.session != null) {
        job.retiring = true;
        dispatch(job);
        return;
    }
    job.batch.deinit();
    job.snapshot.unref();
    c.g_object_unref(job.cancel);
    a.destroy(job);
    self.active = null;
    self.reaped += 1;
    self.app.release();
}
fn pump(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    if (self.closed) return 0;
    const now = c.g_get_monotonic_time();
    if (hooks) {
        if (self.last_tick != 0) self.max_tick_us = @max(self.max_tick_us, now - self.last_tick);
        self.last_tick = now;
    }
    if (self.snapshot) |snapshot| if (!self.validSnapshot(snapshot)) self.invalidate("Stale — workspace or document changed. Refresh required.");
    if (self.pending and self.active == null and now >= self.due) self.startSession();
    if (self.render_pending) self.render();
    return 1;
}
fn sameResults(left: []const search.Result, right: []const search.Result) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| {
        if (l.root_id != r.root_id or l.score != r.score or !std.meta.eql(l.source, r.source) or !std.mem.eql(u8, l.relative_path, r.relative_path)) return false;
    }
    return true;
}
fn resultLessThan(self: *Controller, left: usize, right: usize) bool {
    const l = self.results.items[left];
    const r = self.results.items[right];
    if (l.root_id != r.root_id) return @backingInt(l.root_id) < @backingInt(r.root_id);
    const order = std.mem.order(u8, l.relative_path, r.relative_path);
    if (order != .eq) return order == .lt;
    if (l.line != r.line) return l.line < r.line;
    return l.column < r.column;
}
fn queryChanged(data: *anyopaque) void {
    u.cast(Controller, data).refresh();
}
fn activateRow(data: *anyopaque, index: usize) void {
    u.cast(Controller, data).activate(index);
}
fn refreshClicked(data: *anyopaque) void {
    u.cast(Controller, data).refresh();
}
fn closeClicked(data: *anyopaque) void {
    u.cast(Controller, data).hide();
}

// Narrow GTK fixtures for the parent-owned widget root. No workers, timers or
// filesystem operations are started; these exercise the actual routing methods.
const RoutingFixture = struct {
    app: App = undefined,
    root: u.W = undefined,

    fn init(self: *RoutingFixture) !void {
        try std.testing.expect(c.gtk_init_check() != 0);
        self.app.closing = false;
        self.app.workspace = .init();
        self.app.documents = .init(a);
        self.app.browser.policy_pending = false;
        self.app.browser.model = .{ .allocator = a, .scope = .init(), .roots = &.{}, .manifest_path = null };
        self.root = u.box(false, 0);
        _ = c.g_object_ref_sink(self.root);
        self.app.workspace_search = Controller.init(&self.app, self.root);
        self.app.workspace_search.view.attach();
        try self.snapshot(null);
    }
    fn snapshot(self: *RoutingFixture, document: ?*Document) !void {
        const controller = &self.app.workspace_search;
        if (controller.snapshot) |old| old.unref();
        controller.snapshot = null;
        const snapshot_value = try a.create(Snapshot);
        snapshot_value.* = .{ .arena = .init(a), .token = self.app.browser.model.?.scope.capture().?, .document_scope = self.app.workspace.capture().?, .generation = controller.generation, .inputs = undefined, .revisions = &.{} };
        errdefer snapshot_value.unref();
        if (document) |doc| {
            const revisions = try snapshot_value.arena.allocator().alloc(Revision, 1);
            revisions[0] = .{ .id = doc.id, .revision = doc.revision, .path = doc.path, .dirty = doc.dirty() };
            snapshot_value.revisions = revisions;
        }
        controller.snapshot = snapshot_value;
        controller.stale = false;
    }
    fn deinit(self: *RoutingFixture) void {
        self.app.workspace_search.deinit();
        c.g_object_unref(self.root);
        self.app.documents.deinit();
        self.app.browser.model.?.deinit();
        self.app.workspace.close();
    }
};
const fixture_a: search.Result = .{ .root_id = @fromBackingInt(1), .relative_path = "a.txt", .preview = "A preview", .source = .disk };
const fixture_b: search.Result = .{ .root_id = @fromBackingInt(1), .relative_path = "b.txt", .preview = "B preview", .source = .disk };

pub fn validateStreamingNavigationGtk() !void {
    var fixture: RoutingFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const self = &fixture.app.workspace_search;
    self.mode = .text;
    // Borrowed literal batches are input-only fixtures, not owned backend batches.
    const first: search.Batch = .{ .allocator = a, .results = &.{fixture_a}, .delivery = .append };
    self.consume(&first);
    _ = self.beginNavigation(self.results.items[0], 1);
    const more: search.Batch = .{ .allocator = a, .results = &.{fixture_b}, .delivery = .append };
    self.consume(&more);
    const final: search.Batch = .{ .allocator = a, .results = &.{fixture_a}, .delivery = .append, .status = .complete };
    self.consume(&final);
    try std.testing.expectEqual(@as(usize, 3), self.results.items.len);
    try std.testing.expectEqual(search.Status.complete, self.status);
    try std.testing.expectEqualStrings("a.txt", self.navigation.?.result.relative_path);
    self.mode = .quick_open;
    const replacement: search.Batch = .{ .allocator = a, .results = &.{fixture_b}, .delivery = .replace, .status = .complete };
    self.consume(&replacement);
    try std.testing.expectEqual(@as(usize, 1), self.results.items.len);
    try std.testing.expectEqualStrings("b.txt", self.results.items[0].relative_path);
    try std.testing.expectEqualStrings("a.txt", self.navigation.?.result.relative_path);
    try std.testing.expectEqualStrings("A preview", self.navigation.?.result.preview);
    try std.testing.expectEqual(search.Status.complete, self.status);
}

pub fn validateActivationRoutingGtk() !void {
    var fixture: RoutingFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const self = &fixture.app.workspace_search;
    const first = self.beginNavigation(fixture_a, 1);
    const second = self.beginNavigation(fixture_b, 1);
    try std.testing.expectEqual(first.generation, second.generation);
    try std.testing.expect(second.serial > first.serial);
    // Browser Work uses this same gate BEFORE both success and failure delivery.
    try std.testing.expect(!self.acceptActivationCompletion(first));
    self.acceptOpen("/late/a.txt", first);
    try std.testing.expect(!self.acceptActivationCompletion(first));
    try std.testing.expectEqual(@as(u64, 2), self.discarded_activations);
    try std.testing.expect(self.validActivation(second));
    try std.testing.expectEqualStrings("b.txt", self.navigation.?.result.relative_path);
    try std.testing.expect(!self.stale);
    self.clearNavigation();
    try std.testing.expect(!self.acceptActivationCompletion(second));
    const third = self.beginNavigation(fixture_a, 1);
    try std.testing.expect(third.serial > second.serial);
    self.invalidate("fixture cancellation");
    try std.testing.expect(!self.acceptActivationCompletion(third));
}

pub fn validateReloadRoutingGtk() !void {
    var fixture: RoutingFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const self = &fixture.app.workspace_search;
    const document = try fixture.app.documents.create(null);
    document.path = u.z("/fixture/a.txt");
    try fixture.snapshot(document);
    const generation = self.generation;
    try std.testing.expect(self.validGeneration(generation));
    document.loading = true;
    try std.testing.expect(!self.validGeneration(generation));
    document.loading = false;
    document.pending = .{ .text = try a.dupe(u8, "awaiting load decision"), .bom = false, .newline = .lf };
    try std.testing.expect(!self.validGeneration(generation));
    a.free(document.pending.?.text);
    document.pending = null;
    _ = self.beginNavigation(fixture_a, 1);
    self.navigation.?.document = document.id;
    self.loadStarted(document);
    try std.testing.expect(self.stale and self.navigation == null and self.snapshot == null);
    try std.testing.expect(self.generation != generation);
    self.beforeLoad(document);
    try std.testing.expect(self.committing_document == null);

    // A superseded initial load may finish, but never changes the revisions
    // captured by the still-current activation or invalidates its navigation.
    try fixture.snapshot(document);
    const fresh = try fixture.app.documents.create(null);
    self.loadStarted(fresh);
    _ = self.beginNavigation(fixture_a, 1);
    self.navigation.?.document = fresh.id;
    const second = self.beginNavigation(fixture_b, 1);
    self.navigation.?.document = document.id;
    self.beforeLoad(fresh);
    try std.testing.expectEqual(@as(?u64, fresh.id), self.committing_document);
    c.gtk_text_buffer_set_text(fresh.buffer, "initial load", -1);
    self.documentChanged(fresh);
    self.afterLoad(fresh);
    try std.testing.expect(self.validActivation(second));
    document.revision += 1;
    try std.testing.expect(!self.validActivation(second));
    self.beforeLoad(document);
    try std.testing.expect(self.committing_document == null and self.stale);
}
