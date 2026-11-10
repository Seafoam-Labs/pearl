//! GTK-thread registry. Entries (including closing windows) have stable storage
//! and are reaped only on a later main-loop turn, after both ownership domains drain.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const App = @import("app.zig").App;
const Recovery = @import("workspace/recovery_controller.zig").Controller;
const Settings = @import("platform/settings.zig").Settings;
const trust = @import("workspace/trust.zig");

pub const limit = 16;
pub const save_limit = 16;
pub const save_path_limit = 4095;
const Revocation = struct { scope: trust.Fingerprint, generation: u64 };
const SaveReservation = struct { window: u64, document: u64, path: []const u8 };
const Entry = struct { app: *App, recovery: Recovery };
pub const Manager = struct {
    application: *c.GtkApplication,
    settings: Settings,
    width: c_int,
    height: c_int,
    entries: [limit]?*Entry = @splat(null),
    next_id: u64 = 1,
    first_created: bool = false,
    quitting: bool = false,
    quit_waiting: ?u64 = null,
    source: c_uint = 0,
    // One explicit shared session slot, not a per-window session registry.
    // Admission is serialized: the last accepted save owns the resulting slot.
    session_owner: ?u64 = null,
    // GTK-thread admission through the mutation worker's completion callback.
    file_operation_owner: ?u64 = null,
    preferences_running: bool = false,
    preferences_pending: ?Settings = null,
    initial: *const fn (*App) void,
    // Never evict revocations: a new window must not restore a failed removal
    // from disk. Explicit approval acknowledges a generation in that owner only.
    revocations: [trust.limits.records]Revocation = undefined,
    revocation_count: usize = 0,
    revocation_generation: u64 = 0,
    revocation_saturated: bool = false,
    saves: [save_limit]?SaveReservation = @splat(null),

    pub fn deinit(self: *Manager) void {
        for (self.entries) |entry| std.debug.assert(entry == null);
        for (self.saves) |save| std.debug.assert(save == null);
        std.debug.assert(!self.preferences_running and self.preferences_pending == null);
        std.debug.assert(self.file_operation_owner == null);
        if (self.source != 0) _ = c.g_source_remove(self.source);
    }
    pub fn find(self: *Manager, id: u64) ?*App {
        for (self.entries) |entry| if (entry) |e| {
            if (e.app.window_id == id) return e.app;
        };
        return null;
    }
    pub fn activate(self: *Manager) void {
        for (self.entries) |entry| if (entry) |e| {
            if (!e.app.closing) {
                c.gtk_window_present(u.cast(c.GtkWindow, e.app.window));
                return;
            }
        };
        if (!self.first_created) self.create(null);
    }
    pub fn create(self: *Manager, requester: ?*App) void {
        if (self.file_operation_owner != null) {
            if (requester) |app| app.message("New Window is unavailable while a workspace file operation is applying. Retry after it finishes.");
            return;
        }
        if (self.quitting) {
            if (requester) |app| app.message("New Window is unavailable while Quit All is in progress.");
            return;
        }
        var slot: ?usize = null;
        for (self.entries, 0..) |entry, i| if (entry == null) {
            slot = i;
            break;
        };
        const index = slot orelse {
            if (requester) |app| app.message("Coral allows 16 live or draining windows. Wait for a closing window to finish before creating another.");
            return;
        };
        const first = !self.first_created;
        self.first_created = true;
        const id = self.next_id;
        self.next_id = std.math.add(u64, id, 1) catch @panic("Window IDs exhausted");
        const entry = u.a.create(Entry) catch unreachable;
        // The registry hold also covers recovery initialization and the deferred reap.
        c.g_application_hold(u.cast(c.GApplication, self.application));
        entry.recovery = if (first) Recovery.init(u.cast(c.GApplication, self.application), self.initial) else .{ .application = u.cast(c.GApplication, self.application), .ready = &emptyWindow };
        entry.app = App.create(self.application, self.settings, self.width, self.height, self, id);
        self.entries[index] = entry;
        if (first) entry.recovery.attach(entry.app) else entry.recovery.attachNew(entry.app);
        if (self.source == 0) self.source = c.g_timeout_add(10, &pump, self);
    }
    pub fn cycle(self: *Manager, from: u64, previous: bool) void {
        var chosen: ?*App = null;
        var wrap: ?*App = null;
        for (self.entries) |entry| if (entry) |e| {
            const app = e.app;
            if (app.closing) continue;
            if (wrap == null or (if (previous) app.window_id > wrap.?.window_id else app.window_id < wrap.?.window_id)) wrap = app;
            if (if (previous) app.window_id < from else app.window_id > from) {
                if (chosen == null or (if (previous) app.window_id > chosen.?.window_id else app.window_id < chosen.?.window_id)) chosen = app;
            }
        };
        if (chosen orelse wrap) |app| c.gtk_window_present(u.cast(c.GtkWindow, app.window));
    }
    pub fn quitAll(self: *Manager, requester: *App) void {
        if (self.quitting) return;
        self.quitting = true;
        self.quit_waiting = requester.window_id;
        requester.quit();
    }
    pub fn cancelQuit(self: *Manager, id: u64) void {
        if (self.quit_waiting != id) return;
        self.quitting = false;
        self.quit_waiting = null;
    }
    fn continueQuit(self: *Manager) void {
        if (!self.quitting) return;
        if (self.quit_waiting) |id| if (self.find(id)) |app| {
            if (!app.closing) return;
        };
        self.quit_waiting = null;
        // Stable creation order, regardless of slots freed by previous windows.
        var next: ?*App = null;
        for (self.entries) |entry| if (entry) |e| {
            if (!e.app.closing and (next == null or e.app.window_id < next.?.window_id)) next = e.app;
        };
        if (next) |app| {
            self.quit_waiting = app.window_id;
            c.gtk_window_present(u.cast(c.GtkWindow, app.window));
            app.quit();
        }
    }
    pub fn revocationGeneration(self: *const Manager, scope: trust.Fingerprint) u64 {
        for (self.revocations[0..self.revocation_count]) |entry| if (trust.same(entry.scope, scope)) return entry.generation;
        return 0;
    }
    pub fn revokeWorkspace(self: *Manager, scope: trust.Fingerprint) void {
        self.revocation_generation = std.math.add(u64, self.revocation_generation, 1) catch @panic("Revocation generation exhausted");
        var index: usize = 0;
        while (index < self.revocation_count and !trust.same(self.revocations[index].scope, scope)) : (index += 1) {}
        if (index < self.revocations.len) {
            if (index == self.revocation_count) self.revocation_count += 1;
            self.revocations[index] = .{ .scope = scope, .generation = self.revocation_generation };
        } else self.revocation_saturated = true;
        // First invalidate ALL matching live owners, then start persistence.
        // No worker result or GTK callback can interleave these two passes.
        for (self.entries) |entry| if (entry) |e| {
            if (e.app.closing) continue;
            if (e.app.workspace_policy.currentScope()) |other| if (trust.same(scope, other)) e.app.workspace_policy.revokeLocal();
        };
        for (self.entries) |entry| if (entry) |e| {
            if (e.app.closing) continue;
            if (e.app.workspace_policy.currentScope()) |other| if (trust.same(scope, other)) e.app.workspace_policy.pump();
        };
    }
    pub fn scopeCleanupPending(self: *Manager, scope: trust.Fingerprint) bool {
        // Include draining owners: their stale approvals/removals can still write.
        for (self.entries) |entry| if (entry) |e| {
            if (e.app.workspace_policy.scopeCleanupPending(scope)) return true;
        };
        return false;
    }
    /// No I/O or GTK reentry between this check and acquiring the barrier. Include
    /// draining windows: cancelled work and bound documents still belong to them.
    pub fn checkFileOperation(self: *Manager, owner: *App, source_abs: []const u8, destination_abs: []const u8) !void {
        if (owner.manager != self or self.find(owner.window_id) != owner) return error.NoManager;
        if (self.quitting or owner.closing or owner.quitting) return error.Closing;
        if (self.file_operation_owner != null) return error.OperationPending;
        if (self.session_owner != null) return error.WorkspaceBusy;
        for (self.saves) |save| if (save != null) return error.WorkspaceBusy;
        for (self.entries) |entry| if (entry) |e| {
            const app = e.app;
            // The owner's operation dialog is the confirmation being admitted,
            // not a competing modal. Other windows' dialogs must finish first.
            if (app.dialog != null or app.file_open_choosers != 0 or
                (app != owner and app.openDialogs())) return error.DialogPending;
            if (app.quitting or app.closing_group != null or app.recovery_suspended or e.recovery.claim != null or
                app.pending_file_loads != 0 or app.browser.hasPendingOperations() or
                app.session.work != null) return error.WorkspaceBusy;
            for (app.snapshotDocuments()) |doc| {
                if (doc.busy or doc.loading or doc.pending != null) return error.WorkspaceBusy;
                // Clean documents are just as bound as dirty ones. Never leave an
                // editor saving back to a renamed/deleted/replaced pathname.
                if (doc.path) |path| if (affectsPath(source_abs, destination_abs, path)) return error.OpenDocument;
            }
            if (app.browser.model) |snapshot| {
                for (snapshot.roots) |root| {
                    // Unavailable roots can hide a physical alias through symlinked
                    // ancestors. '..' spellings also depend on traversed directories
                    // absent from the canonical endpoint. Without a complete physical
                    // dependency snapshot, fail closed rather than guess protection.
                    if (root.canonical_path == null or hasParentComponent(root.lexical_path)) return error.WorkspaceBusy;
                    if (affectsPath(source_abs, destination_abs, root.lexical_path)) return error.RootMutation;
                    if (root.canonical_path) |path| if (affectsPath(source_abs, destination_abs, path)) return error.RootMutation;
                }
                if (snapshot.manifest_path) |path| {
                    if (hasParentComponent(path)) return error.WorkspaceBusy;
                    if (affectsPath(source_abs, destination_abs, path)) return error.ProtectedManifest;
                    const canonical = app.browser.manifest_canonical orelse return error.WorkspaceBusy;
                    if (affectsPath(source_abs, destination_abs, canonical)) return error.ProtectedManifest;
                }
            }
        };
    }
    pub fn beginFileOperation(self: *Manager, owner: *App, source_abs: []const u8, destination_abs: []const u8) !void {
        try self.checkFileOperation(owner, source_abs, destination_abs);
        self.file_operation_owner = owner.window_id;
    }
    pub fn endFileOperation(self: *Manager, owner: *App) void {
        std.debug.assert(self.file_operation_owner == owner.window_id);
        self.file_operation_owner = null;
    }
    /// GTK-thread admission only, using saveTo's already canonicalized spelling.
    /// This is NOT an atomic filesystem compare-and-swap against other processes
    /// or concurrent external symlink/rename changes; GIO etags still apply.
    pub fn reserveSave(self: *Manager, window: u64, document: u64, path: []const u8) !usize {
        if (self.file_operation_owner != null) return error.FileOperationBusy;
        if (path.len > save_path_limit) return error.SavePathTooLong;
        var free: ?usize = null;
        for (self.saves, 0..) |reservation, i| {
            if (reservation) |save| {
                if (std.mem.eql(u8, path, save.path)) return error.SaveDestinationBusy;
            } else if (free == null) free = i;
        }
        const slot = free orelse return error.SaveLimit;
        self.saves[slot] = .{ .window = window, .document = document, .path = try u.a.dupe(u8, path) };
        return slot;
    }
    pub fn releaseSave(self: *Manager, slot: usize) void {
        const reservation = self.saves[slot].?;
        u.a.free(reservation.path);
        self.saves[slot] = null;
    }
    pub fn savePreferences(self: *Manager, settings: Settings) void {
        // Only the user layer is broadcast, never repository Effective settings.
        // Native GTK's provider is display-wide; all windows share this preference.
        self.settings = settings;
        for (self.entries) |entry| if (entry) |e| {
            if (!e.app.closing) e.app.receivePreferences(settings);
        };
        self.preferences_pending = settings;
        self.startPreferencesSave();
    }
    fn startPreferencesSave(self: *Manager) void {
        if (self.preferences_running) return;
        const settings = self.preferences_pending orelse return;
        self.preferences_pending = null;
        const job = u.a.create(PreferencesSave) catch unreachable;
        job.* = .{ .manager = self, .settings = settings };
        self.preferences_running = true;
        c.g_application_hold(u.cast(c.GApplication, self.application));
        const task = c.g_task_new(null, null, &preferencesSaved, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &preferencesWorker);
        c.g_object_unref(task);
    }
    pub fn probe(self: *Manager) void {
        if (!@import("build_options").test_hooks) return;
        const Window = struct { id: u64, active: bool, scope: []const u8, closing: bool, holds: usize, recovery_holds: usize, recovery_opening: bool, quitting: bool };
        var windows: [limit]Window = undefined;
        var count: usize = 0;
        var live: usize = 0;
        var holds: usize = 0;
        for (self.entries) |entry| if (entry) |e| {
            windows[count] = .{ .id = e.app.window_id, .active = c.gtk_window_is_active(u.cast(c.GtkWindow, e.app.window)) != 0, .scope = e.app.scope_class, .closing = e.app.closing, .holds = e.app.holds, .recovery_holds = e.recovery.holds, .recovery_opening = e.recovery.opening, .quitting = e.app.quitting };
            count += 1;
            if (!e.app.closing) live += 1;
            holds += e.app.holds + e.recovery.holds;
        };
        var saves: [save_limit]SaveReservation = undefined;
        var save_count: usize = 0;
        for (self.saves) |reservation| if (reservation) |save| {
            saves[save_count] = save;
            save_count += 1;
        };
        const json = std.json.Stringify.valueAlloc(u.a, .{ .saves = saves[0..save_count], .save_limit = save_limit, .revoked_scopes = self.revocation_count, .revocation_limit = trust.limits.records, .revocation_saturated = self.revocation_saturated, .windows = windows[0..count], .live = live, .closing = count - live, .holds = holds, .quitting = self.quitting, .limit = limit, .session_owner = self.session_owner, .file_operation_owner = self.file_operation_owner, .preferences_pending = self.preferences_running or self.preferences_pending != null }, .{}) catch return;
        defer u.a.free(json);
        const line = u.z(json);
        defer u.a.free(line);
        c.g_print("CORAL_WINDOWS %s\n", line.ptr);
    }
};
// Empty source/destination means creation/deletion, never the filesystem root.
// Compare components, not string prefixes: /work/a must not cover /work/ab.
// Only protected spellings may contain redundant separators or '.' components;
// operation spellings are left untouched for the backend's strict validation.
fn containsPath(operation: []const u8, protected: []const u8) bool {
    if (operation.len == 0 or protected.len == 0) return false;
    if (operation[0] != '/' or protected[0] != '/') return false;
    var prefix = std.mem.tokenizeScalar(u8, operation, '/');
    var path = std.mem.tokenizeScalar(u8, protected, '/');
    while (prefix.next()) |part| {
        const next = while (path.next()) |component| {
            if (!std.mem.eql(u8, component, ".")) break component;
        } else return false;
        if (!std.mem.eql(u8, part, next)) return false;
    }
    return true;
}
fn affectsPath(source: []const u8, destination: []const u8, protected: []const u8) bool {
    return containsPath(source, protected) or containsPath(destination, protected);
}
fn hasParentComponent(path: []const u8) bool {
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}

test "file operation protection uses component boundaries and optional endpoints" {
    const expect = std.testing.expect;
    try expect(affectsPath("/work/a", "", "/work/a"));
    try expect(affectsPath("/work/a", "", "/work/a/nested/file"));
    try expect(affectsPath("", "/work/a", "/work/a/nested/file"));
    try expect(!affectsPath("/work/a", "", "/work/ab/file"));
    try expect(!affectsPath("/work/a/file", "", "/work/a"));
    try expect(!affectsPath("", "", "/work/a"));
    try expect(containsPath("/", "/work/a"));
    try expect(containsPath("/work/a", "/work//./a/file"));
    try expect(!containsPath("/work/a", "/other/work/a"));
    try expect(hasParentComponent("/work/../offline"));
    try expect(!hasParentComponent("/work/.../offline"));
}

test "file operation admission covers peer and draining documents, roots, manifests and pending work" {
    const expectError = std.testing.expectError;
    var manager: Manager = .{ .application = undefined, .settings = undefined, .width = 0, .height = 0, .initial = undefined };
    var apps: [2]App = undefined;
    var entries: [2]Entry = undefined;
    for (&apps, &entries, 0..) |*app, *entry, i| {
        // Admission is deliberately metadata-only: no GTK objects or disk I/O.
        app.manager = &manager;
        app.window_id = i + 1;
        app.closing = false;
        app.quitting = false;
        app.closing_group = null;
        app.dialog = null;
        app.file_open_choosers = 0;
        app.pending_file_loads = 0;
        app.recovery_suspended = false;
        app.workspace_operations = .init(app);
        app.browser.model = null;
        app.browser.loading = false;
        app.browser.choosing = false;
        app.browser.pending_load = null;
        app.browser.jobs = .empty;
        app.browser.manifest_canonical = null;
        app.session.work = null;
        app.documents.entries = .empty;
        entry.* = .{ .app = app, .recovery = .{ .application = undefined, .ready = undefined } };
        manager.entries[i] = entry;
    }
    const owner = &apps[0];
    const peer = &apps[1];
    try manager.beginFileOperation(owner, "/work/a", "/work/b");
    try std.testing.expectEqual(owner.window_id, manager.file_operation_owner.?);
    try expectError(error.OperationPending, manager.beginFileOperation(peer, "/other/a", "/other/b"));
    try expectError(error.FileOperationBusy, manager.reserveSave(peer.window_id, 1, "/unrelated"));
    manager.endFileOperation(owner);
    try std.testing.expect(manager.file_operation_owner == null);

    var doc: @import("document.zig").Document = undefined;
    doc.path = try std.testing.allocator.dupeSentinel(u8, "/work/a/clean.txt", 0);
    defer std.testing.allocator.free(doc.path.?);
    doc.busy = false;
    doc.loading = false;
    doc.pending = null;
    var docs = [_]*@import("document.zig").Document{&doc};
    peer.documents.entries.items = &docs;
    try expectError(error.OpenDocument, manager.checkFileOperation(owner, "/work/a", ""));
    try expectError(error.OpenDocument, manager.checkFileOperation(owner, "", "/work/a"));
    peer.closing = true;
    try expectError(error.OpenDocument, manager.checkFileOperation(owner, "/work/a", ""));
    try manager.checkFileOperation(owner, "/work/ab", "");
    doc.busy = true;
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/unrelated", ""));
    doc.busy = false;
    peer.documents.entries = .empty;
    peer.pending_file_loads = 1;
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/unrelated", ""));
    peer.pending_file_loads = 0;
    peer.file_open_choosers = 1;
    try expectError(error.DialogPending, manager.checkFileOperation(owner, "/unrelated", ""));
    peer.file_open_choosers = 0;
    manager.session_owner = peer.window_id;
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/unrelated", ""));
    manager.session_owner = null;

    const model = @import("workspace/model.zig");
    peer.browser.model = .{ .allocator = std.testing.allocator, .scope = model.identity.Scope.init(), .roots = &.{.{ .id = @fromBackingInt(@intCast(1)), .display_name = "Nested", .lexical_path = "/work/a/nested", .canonical_path = "/work/a/nested", .availability = .available }}, .manifest_path = "/work/config/active.json" };
    peer.browser.manifest_canonical = try std.testing.allocator.dupeSentinel(u8, "/physical/config/active.json", 0);
    defer std.testing.allocator.free(peer.browser.manifest_canonical.?);
    try expectError(error.RootMutation, manager.checkFileOperation(owner, "/work/a", ""));
    try expectError(error.RootMutation, manager.checkFileOperation(owner, "", "/work/a/nested"));
    try expectError(error.ProtectedManifest, manager.checkFileOperation(owner, "/work/config", ""));
    try expectError(error.ProtectedManifest, manager.checkFileOperation(owner, "", "/physical/config/active.json"));
    try manager.checkFileOperation(owner, "/work/ab", "/work/ac");

    // A symlinked lexical ancestor can alias a not-directory/missing root without
    // any '..'. No physical identity means no safe process-local protection.
    var protected_roots = [_]model.Root{.{ .id = @fromBackingInt(@intCast(2)), .display_name = "Alias", .lexical_path = "/alias/unavailable", .canonical_path = null, .availability = .not_directory }};
    peer.browser.model.?.roots = &protected_roots;
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/work/unavailable", ""));
    protected_roots[0].availability = .missing;
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "", "/work/unavailable"));
    protected_roots[0].availability = .available;
    protected_roots[0].canonical_path = "/work";
    protected_roots[0].lexical_path = "/alias/sub/..";
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/work/sub", ""));
    protected_roots[0].lexical_path = "/alias";
    peer.browser.model.?.manifest_path = "/alias/sub/../active.json";
    try expectError(error.WorkspaceBusy, manager.checkFileOperation(owner, "/work/sub", ""));
}

fn emptyWindow(app: *App) void {
    _ = app.newDocument();
}
fn pump(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Manager, data.?);
    self.continueQuit();
    var remaining: usize = 0;
    for (&self.entries) |*slot| if (slot.*) |entry| {
        if (entry.app.closing and entry.app.holds == 0 and entry.recovery.drained()) {
            entry.recovery.deinit();
            entry.app.deinit();
            u.a.destroy(entry);
            slot.* = null;
            c.g_application_release(u.cast(c.GApplication, self.application));
        } else remaining += 1;
    };
    if (remaining != 0) return 1;
    self.source = 0;
    return 0;
}
const PreferencesSave = struct { manager: *Manager, settings: Settings, err: ?anyerror = null };
fn preferencesWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(PreferencesSave, data.?);
    job.settings.save() catch |err| {
        job.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn preferencesSaved(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(PreferencesSave, data.?);
    const self = job.manager;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    self.preferences_running = false;
    if (job.err) |err| {
        std.log.scoped(.config).err("event=preferences-save-failed error={s}", .{@errorName(err)});
        const text = u.fmt("Could not save {s}/coral/preferences.ini: {s}. Check directory permissions.", .{ std.mem.span(c.g_get_user_config_dir()), @errorName(err) });
        defer u.a.free(text);
        for (self.entries) |entry| if (entry) |e| {
            e.app.message(text);
        };
    }
    u.a.destroy(job);
    self.startPreferencesSave();
    c.g_application_release(u.cast(c.GApplication, self.application));
}
