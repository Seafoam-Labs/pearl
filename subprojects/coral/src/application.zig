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
    /// GTK-thread admission only, using saveTo's already canonicalized spelling.
    /// This is NOT an atomic filesystem compare-and-swap against other processes
    /// or concurrent external symlink/rename changes; GIO etags still apply.
    pub fn reserveSave(self: *Manager, window: u64, document: u64, path: []const u8) !usize {
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
        const json = std.json.Stringify.valueAlloc(u.a, .{ .saves = saves[0..save_count], .save_limit = save_limit, .revoked_scopes = self.revocation_count, .revocation_limit = trust.limits.records, .revocation_saturated = self.revocation_saturated, .windows = windows[0..count], .live = live, .closing = count - live, .holds = holds, .quitting = self.quitting, .limit = limit, .session_owner = self.session_owner, .preferences_pending = self.preferences_running or self.preferences_pending != null }, .{}) catch return;
        defer u.a.free(json);
        const line = u.z(json);
        defer u.a.free(line);
        c.g_print("CORAL_WINDOWS %s\n", line.ptr);
    }
};
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
