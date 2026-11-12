//! Native Git stash workflows: named push (tracked/staged/all), list, show diff,
//! apply, pop and drop. Read-only inspection uses command.zig's locked-down
//! policy; repository writes use env.zig's write prefix/environment after the
//! Source Control disclosure, so configured hooks/signing may run as the user.
//! Async jobs run through tasks/process.zig with App.hold and cancellation/reap.
//! Worktree/index writes hold the manager file barrier. Pop applies first and
//! only drops after a successful apply AND a separate explicit confirmation; a
//! failed apply always preserves the entry. Drop is loss-producing and confirmed.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const env = @import("env.zig");
const command = @import("command.zig");
const stash = @import("stash.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = 1024 * 1024;
pub const max_visible_rows = 256;

const Phase = enum { idle, version, list, show, push, apply, drop };
const WriteKind = enum { apply, pop_apply, drop };
const DialogAction = enum { push, apply, pop_apply, pop_drop, drop };

fn isWritePhase(phase: Phase) bool {
    return phase == .push or phase == .apply or phase == .drop;
}

fn interrupted(outcome: process.Outcome) bool {
    return outcome == .cancelled or outcome == .timed_out or outcome == .signaled or outcome == .io_failed;
}

const disclosure =
    "Stash runs /usr/bin/git as your user after the Source Control disclosure, only in a trusted workspace. " ++
    "Push writes the worktree and index; apply/pop write the worktree; drop permanently deletes a stash entry. " ++
    "Repository-local Git configuration, hooks and signing can execute programs with your permissions; this is NOT a sandbox. " ++
    "Unsaved editor buffers are excluded and are never saved. Stash push refuses to run while unsaved buffers exist under the repository. " ++
    "Pop applies first and drops only after the apply succeeds and you separately confirm; a failed apply preserves the entry. " ++
    "Ignored files are never stashed; 'all' adds untracked files only.";

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .idle,
    stashes: ?stash.List = null,
    selected: ?usize = null,
    staged_ok: bool = false,
    write_kind: ?WriteKind = null,
    write_oid: ?[:0]u8 = null,
    dialog: UI,
    dialog_action: ?DialogAction = null,
    barrier: bool = false,
    window: ?u.W = null,
    list_widget: ?u.W = null,
    summary: ?u.W = null,
    overlay: ?u.W = null,
    diff_view: ?u.W = null,
    apply_button: ?u.W = null,
    pop_button: ?u.W = null,
    drop_button: ?u.W = null,
    show_button: ?u.W = null,
    rebuilding: bool = false,
    message_text: [:0]u8,
    diff_text: [:0]u8,
    diff_kind: []const u8 = "none",
    launches: u64 = 0,
    discarded: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .dialog = .{ .context = app, .respond = &answered },
            .message_text = u.z("Stash — explicit actions only"),
            .diff_text = u.z(""),
        };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.clearStashes();
        self.clearWrite();
        self.arena.deinit();
        a.free(self.message_text);
        a.free(self.diff_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.dialog_action = null;
        self.dialog.close();
        self.closeWindow();
        self.clearStashes();
        self.clearWrite();
        self.setDiff("none", "");
        if (self.job == null) self.releaseBarrier();
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null;
    }
    fn engaged(self: *const Controller) bool {
        return self.job != null or self.write_kind != null or self.dialog_action != null;
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("stash generation exhausted");
        if (self.job) |job| job.cancel();
    }
    fn clearStashes(self: *Controller) void {
        self.selected = null;
        if (self.stashes) |*list| list.deinit();
        self.stashes = null;
        self.renderRows();
    }
    fn clearWrite(self: *Controller) void {
        self.write_kind = null;
        if (self.write_oid) |oid| a.free(oid);
        self.write_oid = null;
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        const text = u.fmt("Stash: {s}. Refresh to try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn selectedEntry(self: *const Controller) ?*const stash.Entry {
        const list = &(self.stashes orelse return null);
        const index = self.selected orelse return null;
        if (index >= list.entries.len) return null;
        return &list.entries[index];
    }

    // --- public entry points -------------------------------------------------

    pub fn showStashPush(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request or confirmation to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        const body = disclosure ++ "\n\nChoose a scope and type a name, then choose Stash…. " ++
            "tracked = staged + unstaged tracked changes; staged = staged only (Git ≥ 2.35); all = tracked + untracked (never ignored).";
        self.showDialog(.push, "Stash push — name and scope", body, &.{
            "tracked — staged + unstaged tracked changes",
            "staged — staged only (requires Git ≥ 2.35)",
            "all — tracked + untracked (ignored files excluded)",
        }, true, "Stash…");
    }
    pub fn showStashList(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request or confirmation to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        self.cancel();
        self.clearWrite();
        self.refreshList();
    }
    pub fn showStashApply(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request or confirmation to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        const entry = self.selectedEntry() orelse {
            self.message("Select a stash entry to apply.");
            return;
        };
        const label = command.display(a, entry.selector, 128) catch return;
        defer a.free(label);
        const body = u.fmt("Apply {s} to the worktree. The stash entry is preserved. Unsaved buffers are never saved; the write is refused while any exist under the repository. Hooks/signing may run as your user.", .{label});
        defer a.free(body);
        self.showDialog(.apply, "Apply stash — entry preserved", body, &.{}, false, "Apply stash…");
    }
    pub fn showStashPop(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request or confirmation to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        const entry = self.selectedEntry() orelse {
            self.message("Select a stash entry to pop.");
            return;
        };
        const label = command.display(a, entry.selector, 128) catch return;
        defer a.free(label);
        const body = u.fmt("Pop applies {s} to the worktree, then asks before dropping it. If the apply fails the entry is preserved and nothing is dropped. Unsaved buffers are never saved. Hooks/signing may run as your user.", .{label});
        defer a.free(body);
        self.showDialog(.pop_apply, "Pop stash — apply, then confirm drop", body, &.{}, false, "Apply stash…");
    }
    pub fn showStashDrop(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request or confirmation to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        const entry = self.selectedEntry() orelse {
            self.message("Select a stash entry to drop.");
            return;
        };
        const label = command.display(a, entry.selector, 128) catch return;
        defer a.free(label);
        const message_slice = command.display(a, entry.message, 256) catch return;
        defer a.free(message_slice);
        const body = u.fmt("Permanently drop {s} ({s})? This deletes the stash entry and cannot be undone. No worktree file is changed.", .{ label, message_slice });
        defer a.free(body);
        self.showDialog(.drop, "Drop stash — permanent, cannot be undone", body, &.{}, false, "Drop permanently…");
    }

    fn ensureValid(self: *Controller) bool {
        if (!self.app.git.valid()) {
            // Reuse the Source Control disclosure; never queue a write without it.
            self.app.git.show();
            return false;
        }
        if (self.window == null) self.createWindow();
        return true;
    }
    fn showDialog(self: *Controller, action: DialogAction, title: [:0]const u8, body: []const u8, rows: []const []const u8, prompt: bool, accept: [:0]const u8) void {
        self.dialog_action = action;
        self.dialog.context = self;
        self.dialog.show(self.app, title, body, rows, prompt, accept);
    }
    fn answered(context: *anyopaque, accepted: bool, index: ?usize, text: []const u8) void {
        const self = u.cast(Controller, context);
        const action = self.dialog_action orelse return;
        self.dialog_action = null;
        if (self.app.closing) {
            self.clearWrite();
            return;
        }
        if (!accepted) {
            if (action == .pop_drop) self.clearWrite();
            return;
        }
        if (!self.app.git.valid()) {
            self.clearWrite();
            self.app.message("Source Control trust changed. Invoke it again.");
            return;
        }
        switch (action) {
            .push => {
                const mode: stash.Mode = switch (index orelse 0) {
                    1 => .staged,
                    2 => .all,
                    else => .tracked,
                };
                if (mode == .staged and !self.staged_ok) {
                    self.message("Stashing only staged changes requires Git 2.35 or newer.");
                    return;
                }
                if (text.len == 0) {
                    self.message("Type a stash name before stashing.");
                    return;
                }
                self.beginPush(mode, text);
            },
            .apply => self.beginWriteIntent(.apply),
            .pop_apply => self.beginWriteIntent(.pop_apply),
            .pop_drop => {
                self.write_kind = .drop;
                self.relist();
            },
            .drop => self.beginWriteIntent(.drop),
        }
    }

    // --- write planning ------------------------------------------------------

    fn beginPush(self: *Controller, mode: stash.Mode, message_text: []const u8) void {
        if (self.dirtyUnderRepo()) {
            self.message("Refused: unsaved editor buffers exist under this repository. Save or close them first; they are never saved or stashed.");
            return;
        }
        if (self.openDocumentUnderRepo()) {
            self.message("Refused: an editor document is open under this repository. Close it before the worktree is rewritten; open documents are never saved.");
            return;
        }
        const repo = self.app.git.repo() orelse return;
        self.acquireBarrier() catch |err| {
            self.failure(err);
            return;
        };
        var buf: [stash.max_args][]const u8 = undefined;
        const args = stash.pushArgs(&buf, mode, message_text) catch |err| {
            self.releaseBarrier();
            self.failure(err);
            return;
        };
        self.launchWrite(.push, repo.path, args, capture_bytes) catch |err| {
            self.releaseBarrier();
            self.failure(err);
        };
    }
    fn beginWriteIntent(self: *Controller, kind: WriteKind) void {
        const entry = self.selectedEntry() orelse {
            self.message("Select a stash entry first.");
            return;
        };
        self.clearWrite();
        self.write_kind = kind;
        self.write_oid = u.z(entry.oid);
        self.relist();
    }
    fn beginWriteAfterList(self: *Controller) void {
        const kind = self.write_kind orelse return;
        const oid = self.write_oid orelse {
            self.clearWrite();
            return;
        };
        const list = &(self.stashes orelse {
            self.clearWrite();
            return;
        });
        const entry = stash.findByOid(list, oid) orelse {
            self.clearWrite();
            self.message("The stash list changed before the write; nothing was applied or dropped. Refresh and retry.");
            return;
        };
        if (kind != .drop and self.dirtyUnderRepo()) {
            self.clearWrite();
            self.message("Refused: unsaved editor buffers exist under this repository. Save or close them first; they are never saved or stashed.");
            return;
        }
        if (kind != .drop and self.openDocumentUnderRepo()) {
            self.clearWrite();
            self.message("Refused: an editor document is open under this repository. Close it before the worktree is rewritten; open documents are never saved.");
            return;
        }
        const repo = self.app.git.repo() orelse {
            self.clearWrite();
            return;
        };
        self.acquireBarrier() catch |err| {
            self.clearWrite();
            self.failure(err);
            return;
        };
        var buf: [stash.max_args][]const u8 = undefined;
        const args = switch (kind) {
            .apply, .pop_apply => stash.applyArgs(&buf, entry.selector),
            .drop => stash.dropArgs(&buf, entry.selector),
        } catch |err| {
            self.releaseBarrier();
            self.clearWrite();
            self.failure(err);
            return;
        };
        const phase: Phase = if (kind == .drop) .drop else .apply;
        self.launchWrite(phase, repo.path, args, capture_bytes) catch |err| {
            self.releaseBarrier();
            self.clearWrite();
            self.failure(err);
        };
    }
    fn dirtyUnderRepo(self: *const Controller) bool {
        const repo = self.app.git.repo() orelse return false;
        if (self.app.manager) |manager| {
            for (manager.entries) |entry| {
                const window = entry orelse continue;
                for (window.app.snapshotDocuments()) |doc| {
                    if (doc.dirty()) {
                        if (doc.path) |path| {
                            if (command.contains(repo.path, path)) return true;
                        }
                    }
                }
            }
        } else {
            for (self.app.snapshotDocuments()) |doc| {
                if (doc.dirty()) {
                    if (doc.path) |path| {
                        if (command.contains(repo.path, path)) return true;
                    }
                }
            }
        }
        return false;
    }
    /// True when any editor document (clean or dirty) is open under the worktree.
    /// Worktree-affecting writes refuse in that case so an open buffer is never
    /// clobbered or left saving back to a rewritten pathname.
    fn openDocumentUnderRepo(self: *const Controller) bool {
        const repo = self.app.git.repo() orelse return false;
        if (self.app.manager) |manager| {
            for (manager.entries) |entry| {
                const window = entry orelse continue;
                for (window.app.snapshotDocuments()) |doc| {
                    if (doc.path) |path| {
                        if (command.contains(repo.path, path)) return true;
                    }
                }
            }
        } else {
            for (self.app.snapshotDocuments()) |doc| {
                if (doc.path) |path| {
                    if (command.contains(repo.path, path)) return true;
                }
            }
        }
        return false;
    }
    fn acquireBarrier(self: *Controller) !void {
        const manager = self.app.manager orelse return error.NoManager;
        const repo = self.app.git.repo() orelse return error.NoRepository;
        const index_path = u.fmt("{s}/index", .{repo.gitdir});
        defer a.free(index_path);
        // Manager-wide save/load/modal admission. Worktree-affecting writes are also
        // guarded by dirtyUnderRepo/openDocumentUnderRepo so open editor documents are
        // never clobbered. The index path (not the worktree root) is the barrier source:
        // a worktree root that is itself a workspace root would otherwise be refused as
        // RootMutation even though only its contents change.
        try manager.beginFileOperation(self.app, index_path, "");
        self.barrier = true;
    }
    fn releaseBarrier(self: *Controller) void {
        if (!self.barrier) return;
        self.barrier = false;
        if (self.app.manager) |manager| manager.endFileOperation(self.app);
    }

    // --- async jobs ----------------------------------------------------------

    fn refreshList(self: *Controller) void {
        self.clearStashes();
        const repo = self.app.git.repo() orelse {
            self.failure(error.NoRepository);
            return;
        };
        self.message("Reading stash list — disk/index only…");
        self.launchRead(.version, repo.path, &.{"--version"}, 16384) catch |err| self.failure(err);
    }
    fn relist(self: *Controller) void {
        self.clearStashes();
        const repo = self.app.git.repo() orelse {
            self.failure(error.NoRepository);
            return;
        };
        self.launchRead(.list, repo.path, stash.list_args, capture_bytes) catch |err| self.failure(err);
    }
    fn showDiff(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current stash request to finish.");
            return;
        }
        const entry = self.selectedEntry() orelse {
            self.message("Select a stash entry to show its diff.");
            return;
        };
        const repo = self.app.git.repo() orelse return;
        var buf: [stash.max_args][]const u8 = undefined;
        const args = stash.showArgs(&buf, entry.selector) catch |err| {
            self.failure(err);
            return;
        };
        self.setDiff("loading", "Reading immutable stash diff…");
        self.launchRead(.show, repo.path, args, capture_bytes) catch |err| self.failure(err);
    }
    fn launchRead(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize) !void {
        if (self.job != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        if (command.prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..command.prefix.len], command.prefix);
        @memcpy(argv[command.prefix.len..][0..args.len], args);
        var environment: [command.environment.len]process.Environment = undefined;
        for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
        const token = self.app.workspace.capture() orelse return error.Closed;
        self.phase = phase;
        self.job = try process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "git-stash", .request = self.launches + 1, .generation = self.generation, .workspace = token },
            .argv = argv[0 .. command.prefix.len + args.len],
            .cwd = cwd,
            .environment = &environment,
            .output_limit = limit,
            .timeout_ms = 15000,
        }, &completed, self);
        self.launches += 1;
        self.app.hold();
        self.updateButtons();
    }
    fn launchWrite(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize) !void {
        if (self.job != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        if (env.write_prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..env.write_prefix.len], env.write_prefix);
        @memcpy(argv[env.write_prefix.len..][0..args.len], args);
        var env_arena = std.heap.ArenaAllocator.init(a);
        defer env_arena.deinit();
        const environment = try env.write(env_arena.allocator());
        const token = self.app.workspace.capture() orelse return error.Closed;
        self.phase = phase;
        self.job = try process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "git-stash-write", .request = self.launches + 1, .generation = self.generation, .workspace = token },
            .argv = argv[0 .. env.write_prefix.len + args.len],
            .cwd = cwd,
            .environment = environment,
            .output_limit = limit,
            .timeout_ms = 15000,
        }, &completed, self);
        self.launches += 1;
        self.app.hold();
        self.updateButtons();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        const finishing = self.phase;
        defer self.app.release();
        defer job.destroy();
        defer {
            if (isWritePhase(finishing)) self.releaseBarrier();
        }
        std.debug.assert(self.job == job);
        self.job = null;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            if (isWritePhase(finishing) and interrupted(result.outcome)) self.refreshSourceControl();
            self.updateButtons();
            return;
        }
        if (!self.app.git.valid() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.invalidate();
            return;
        }
        self.receive(result) catch |err| self.failure(err);
        self.updateButtons();
    }
    fn receive(self: *Controller, result: process.Result) !void {
        if (self.phase == .version) {
            if (result.outcome != .success) return error.GitVersionFailed;
            self.staged_ok = stash.stagedSupported(result.stdout);
            const repo = self.app.git.repo() orelse return error.NoRepository;
            try self.launchRead(.list, repo.path, stash.list_args, capture_bytes);
            return;
        }
        if (result.outcome != .success) {
            const was_write = isWritePhase(self.phase);
            self.clearWrite();
            if (was_write and interrupted(result.outcome)) {
                const text = u.fmt("Stash {s} was interrupted ({s}). The worktree/index may be in a partial state; no result is assumed. Refresh Source Control to inspect.", .{ @tagName(self.phase), @tagName(result.outcome) });
                defer a.free(text);
                self.message(text);
                self.relist();
                self.refreshSourceControl();
                return;
            }
            const text = u.fmt("Stash {s}: {s} (exit {d}). {s}", .{
                @tagName(self.phase),
                @tagName(result.outcome),
                result.exit_code orelse -1,
                if (was_write) "The stash entry is preserved; no drop occurred." else "Refresh to retry.",
            });
            defer a.free(text);
            self.message(text);
            if (was_write) {
                self.relist();
                self.refreshSourceControl();
            }
            return;
        }
        switch (self.phase) {
            .list => {
                var parsed = try stash.parseList(a, result.stdout);
                if (parsed.entries.len > stash.max_entries) {
                    parsed.deinit();
                    return error.TooManyStashes;
                }
                self.clearStashes();
                self.stashes = parsed;
                self.renderRows();
                if (self.write_kind != null) {
                    self.beginWriteAfterList();
                } else {
                    self.updateSummary();
                }
            },
            .show => {
                switch (command.preview(result.stdout)) {
                    .binary => self.setDiff("binary", "Binary stash change — no textual diff is available."),
                    .non_utf8 => self.setDiff("non-utf8", "Non-UTF-8 stash change — text preview is unavailable."),
                    .too_large => self.setDiff("limited", "Stash diff exceeds native preview limits. No partial diff is shown."),
                    .text => self.setDiff("text", if (result.stdout.len == 0) "No tracked differences in this stash." else result.stdout),
                }
            },
            .push => {
                self.clearWrite();
                self.message("Stash created. The worktree and index were reset for the stashed paths.");
                self.relist();
                self.refreshSourceControl();
            },
            .apply => {
                const was_pop = self.write_kind == .pop_apply;
                if (was_pop) {
                    // Apply succeeded; keep the target and ask before dropping.
                    const oid = self.write_oid orelse {
                        self.clearWrite();
                        return;
                    };
                    const label = command.display(a, oid, 128) catch return;
                    defer a.free(label);
                    const body = u.fmt("Apply succeeded. Permanently drop the stash entry ({s})? This cannot be undone. Choosing Cancel keeps the entry.", .{label});
                    defer a.free(body);
                    self.showDialog(.pop_drop, "Pop — apply succeeded, confirm drop", body, &.{}, false, "Drop permanently…");
                } else {
                    self.clearWrite();
                    self.message("Stash applied. The entry is preserved.");
                    self.relist();
                    self.refreshSourceControl();
                }
            },
            .drop => {
                self.clearWrite();
                self.message("Stash entry dropped.");
                self.relist();
                self.refreshSourceControl();
            },
            .version, .idle => {},
        }
    }
    fn refreshSourceControl(self: *Controller) void {
        if (self.app.git.valid()) self.app.git.refresh();
    }

    // --- presentation --------------------------------------------------------

    fn updateSummary(self: *Controller) void {
        const list = &(self.stashes orelse return);
        const text = u.fmt("{d} stash entries · explicit actions only · pop drops only after a successful apply and a separate confirmation.", .{list.entries.len});
        defer a.free(text);
        self.message(text);
        self.updateOverlay();
    }
    fn updateOverlay(self: *Controller) void {
        const label = self.overlay orelse return;
        const text = u.fmt("Unsaved editor documents: {d} across windows (excluded; never saved). Push/apply/pop refuse while unsaved buffers exist under the repository.", .{self.app.git.dirtyCount()});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn setDiff(self: *Controller, kind: []const u8, text: []const u8) void {
        self.diff_kind = kind;
        a.free(self.diff_text);
        self.diff_text = u.z(text);
        if (self.diff_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.diff_text.ptr, @intCast(self.diff_text.len));
    }
    fn updateButtons(self: *Controller) void {
        const enabled = self.window != null and self.selected != null and !self.engaged();
        if (self.apply_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
        if (self.pop_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
        if (self.drop_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
        if (self.show_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
    }
    fn createWindow(self: *Controller) void {
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Source Control — stash");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 900, 700);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const bar = u.box(true, 8);
        u.append(box, bar);
        const push = u.button("Stash push…");
        const refresh = u.button("Refresh list");
        u.append(bar, push);
        u.append(bar, refresh);
        u.connect(push, "clicked", &pushClicked, self);
        u.connect(refresh, "clicked", &listClicked, self);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const overlay = u.label("");
        self.overlay = overlay;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, overlay), 1);
        u.append(box, overlay);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(scroll, -1, 200);
        const list = c.gtk_list_box_new().?;
        self.list_widget = list;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        u.append(box, scroll);
        u.connect(list, "row-selected", &rowSelected, self);
        const actions = u.box(true, 8);
        u.append(box, actions);
        const show = u.button("Show diff");
        const apply = u.button("Apply…");
        const pop = u.button("Pop…");
        const drop = u.button("Drop…");
        self.show_button = show;
        self.apply_button = apply;
        self.pop_button = pop;
        self.drop_button = drop;
        u.append(actions, show);
        u.append(actions, apply);
        u.append(actions, pop);
        u.append(actions, drop);
        u.connect(show, "clicked", &showClicked, self);
        u.connect(apply, "clicked", &applyClicked, self);
        u.connect(pop, "clicked", &popClicked, self);
        u.connect(drop, "clicked", &dropClicked, self);
        const diff_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(diff_scroll, 1);
        const view = c.gtk_text_view_new().?;
        self.diff_view = view;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, diff_scroll), view);
        u.append(box, diff_scroll);
        self.app.styleWindow(window);
        self.app.installTestKeys(window);
        self.updateOverlay();
        self.updateButtons();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
        self.refreshList();
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.list_widget = null;
        self.summary = null;
        self.overlay = null;
        self.diff_view = null;
        self.apply_button = null;
        self.pop_button = null;
        self.drop_button = null;
        self.show_button = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn renderRows(self: *Controller) void {
        defer self.updateButtons();
        const list = self.list_widget orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        const entries: []const stash.Entry = if (self.stashes) |snapshot| snapshot.entries else &.{};
        const end = @min(entries.len, max_visible_rows);
        for (entries[0..end]) |entry| {
            const message_slice = command.display(a, entry.message, 512) catch unreachable;
            defer a.free(message_slice);
            const text = u.fmt("{s}  {s}", .{ entry.selector, message_slice });
            defer a.free(text);
            const label = u.label(text);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
            c.gtk_widget_set_tooltip_text(label, text);
            u.margin(label, 4);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), label);
        }
        if (self.selected) |index| if (index < end) {
            c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), @intCast(index)));
        };
    }
    fn selectEntry(self: *Controller, index: usize) void {
        const list = &(self.stashes orelse return);
        if (index >= list.entries.len or !self.app.git.valid()) return;
        self.selected = index;
        self.setDiff("none", "Select Show diff to inspect this stash, or Apply / Pop / Drop.");
        self.renderRows();
        self.updateOverlay();
    }

    // --- GTK callbacks -------------------------------------------------------

    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn rowSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const selected = row orelse {
            self.selected = null;
            self.updateButtons();
            return;
        };
        const index = c.gtk_list_box_row_get_index(selected);
        if (index >= 0) self.selectEntry(@intCast(index));
    }
    fn pushClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showStashPush();
    }
    fn listClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showStashList();
    }
    fn showClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showDiff();
    }
    fn applyClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showStashApply();
    }
    fn popClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showStashPop();
    }
    fn dropClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showStashDrop();
    }

    // --- test instrumentation ------------------------------------------------

    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "stash-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "stash-accept")) {
            self.dialog.answer(true, null, value);
        } else if (std.mem.eql(u8, action, "stash-reject")) {
            self.dialog.answer(false, null, "");
        } else if (std.mem.eql(u8, action, "stash-close")) {
            self.invalidate();
        } else if (std.mem.eql(u8, action, "stash-select")) {
            self.selectEntry(std.fmt.parseInt(usize, value, 10) catch return true);
        } else if (std.mem.eql(u8, action, "stash-push")) {
            self.showStashPush();
        } else if (std.mem.eql(u8, action, "stash-list")) {
            self.showStashList();
        } else if (std.mem.eql(u8, action, "stash-show")) {
            self.showDiff();
        } else if (std.mem.eql(u8, action, "stash-apply")) {
            self.showStashApply();
        } else if (std.mem.eql(u8, action, "stash-pop")) {
            self.showStashPop();
        } else if (std.mem.eql(u8, action, "stash-drop")) {
            self.showStashDrop();
        } else return false;
        return true;
    }
    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const entries: []const stash.Entry = if (self.stashes) |list| list.entries else &.{};
        const end = @min(entries.len, max_visible_rows);
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .visible = self.window != null,
            .approved = self.app.git.approved,
            .generation = self.generation,
            .busy = self.busy(),
            .engaged = self.engaged(),
            .phase = if (self.job != null) @as(?[]const u8, @tagName(self.phase)) else null,
            .launches = self.launches,
            .discarded = self.discarded,
            .staged_ok = self.staged_ok,
            .entries = entries[0..end],
            .entry_count = entries.len,
            .selected = self.selected,
            .write_kind = if (self.write_kind) |kind| @as(?[]const u8, @tagName(kind)) else null,
            .dialog = if (self.dialog_action) |action| @as(?[]const u8, @tagName(action)) else null,
            .barrier = self.barrier,
            .diff_kind = self.diff_kind,
            .diff = self.diff_text,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_STASH %s\n", line.ptr);
    }
};
