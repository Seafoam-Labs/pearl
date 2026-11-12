//! Native Git conflict workflows: list unmerged paths (ls-files -u), show the
//! base/ours/theirs stages, navigate, and resolve current/incoming/both by writing
//! the reviewed stage bytes to the worktree safely (descriptor-checked atomic
//! replace in a worker) then `git add`. Manual resolution is refused with guidance
//! to edit/save in the editor and stage. Rename/delete/binary conflicts are refused
//! as non-text. Merge/rebase/cherry-pick/revert state is read from gitdir state refs
//! (never guessed from conflict markers); continue/abort are offered explicitly.
//! Reads use command.zig's locked-down policy; writes use env.zig's write policy
//! after the Source Control disclosure. Async git jobs run through tasks/process.zig
//! with App.hold and cancellation/reap; worktree/index writes hold the manager barrier.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const env = @import("env.zig");
const command = @import("command.zig");
const status = @import("status.zig");
const conflict = @import("conflict.zig");
const os = @import("index_transaction_os.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = 1024 * 1024;
pub const max_visible_rows = 256;

const Phase = enum { idle, state, unmerged, stage, add, continue_op, abort_op };
const ConfirmAction = enum { continue_op, abort_op };
const StageSlot = enum { base, ours, theirs };

fn isWritePhase(phase: Phase) bool {
    return phase == .add or phase == .continue_op or phase == .abort_op;
}

fn interrupted(outcome: process.Outcome) bool {
    return outcome == .cancelled or outcome == .timed_out or outcome == .signaled or outcome == .io_failed;
}

const state_probes = [_]conflict.Operation{ .merge, .rebase, .cherry_pick, .revert };

const disclosure =
    "Conflicts runs /usr/bin/git as your user after the Source Control disclosure, only in a trusted workspace. " ++
    "Resolving writes the chosen stage bytes to one worktree file and stages it; continue/abort run the detected Git operation. " ++
    "Repository-local Git configuration, hooks and signing can execute programs with your permissions; this is NOT a sandbox. " ++
    "Unsaved editor buffers are excluded and are never saved; a file open in an editor cannot be overwritten. " ++
    "Rename/delete and binary conflicts are refused as non-text. Operation state is read from gitdir state files, not conflict markers.";

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    stage_arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    write_job: ?*WriteJob = null,
    generation: u64 = 1,
    phase: Phase = .idle,
    listing: ?conflict.Listing = null,
    selected: ?usize = null,
    operation: conflict.Operation = .none,
    state_probe_index: usize = 0,
    stage_fetch_step: usize = 0,
    base_bytes: ?[]const u8 = null,
    ours_bytes: ?[]const u8 = null,
    theirs_bytes: ?[]const u8 = null,
    displayed_stage: StageSlot = .ours,
    resolve_choice: conflict.Choice = .current,
    resolve_bytes: ?[]const u8 = null,
    resolve_dialog: ?u.W = null,
    confirm: UI,
    confirm_action: ?ConfirmAction = null,
    barrier: bool = false,
    window: ?u.W = null,
    list_widget: ?u.W = null,
    summary: ?u.W = null,
    overlay: ?u.W = null,
    operation_label: ?u.W = null,
    stage_view: ?u.W = null,
    continue_button: ?u.W = null,
    abort_button: ?u.W = null,
    rebuilding: bool = false,
    message_text: [:0]u8,
    stage_text: [:0]u8,
    launches: u64 = 0,
    discarded: u64 = 0,
    writes_committed: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .stage_arena = std.heap.ArenaAllocator.init(a),
            .confirm = .{ .context = app, .respond = &confirmed },
            .message_text = u.z("Conflicts — explicit actions only"),
            .stage_text = u.z(""),
        };
    }
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.job == null and self.write_job == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.clearListing();
        self.stage_arena.deinit();
        self.arena.deinit();
        a.free(self.message_text);
        a.free(self.stage_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        if (self.write_job) |wj| wj.cancel.store(true, .release);
        self.confirm_action = null;
        self.confirm.close();
        self.closeResolveDialog();
        self.closeWindow();
        self.clearListing();
        self.setStageText("");
        if (self.job == null and self.write_job == null) self.releaseBarrier();
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.write_job != null;
    }
    fn engaged(self: *const Controller) bool {
        return self.busy() or self.confirm_action != null or self.resolve_dialog != null;
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("conflict generation exhausted");
        if (self.job) |job| job.cancel();
    }
    fn clearListing(self: *Controller) void {
        self.selected = null;
        if (self.listing) |*listing| listing.deinit();
        self.listing = null;
        self.base_bytes = null;
        self.ours_bytes = null;
        self.theirs_bytes = null;
        self.resolve_bytes = null;
        _ = self.stage_arena.reset(.free_all);
        self.renderRows();
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        const text = u.fmt("Conflicts: {s}. Refresh to try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn selectedConflict(self: *const Controller) ?*const conflict.Conflict {
        const listing = &(self.listing orelse return null);
        const index = self.selected orelse return null;
        if (index >= listing.conflicts.len) return null;
        return &listing.conflicts[index];
    }

    // --- public entry points -------------------------------------------------

    pub fn showConflicts(self: *Controller) void {
        if (self.engaged()) {
            self.message("Wait for the current conflict request or review to finish.");
            return;
        }
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (self.window == null) self.createWindow();
        self.cancel();
        self.refresh();
    }
    pub fn showResolve(self: *Controller, choice: conflict.Choice) void {
        if (self.engaged()) {
            self.message("Wait for the current conflict request or review to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        const target = self.selectedConflict() orelse {
            self.message("Select a conflict to resolve.");
            return;
        };
        if (!target.kind.resolvable()) {
            self.message("Refused: this is a rename/delete/add conflict, not a simple text merge. Resolve it manually in the editor, then stage it.");
            return;
        }
        const ours = self.ours_bytes orelse {
            self.message("The current (ours) stage is unavailable; refresh the conflict.");
            return;
        };
        const theirs = self.theirs_bytes orelse {
            self.message("The incoming (theirs) stage is unavailable; refresh the conflict.");
            return;
        };
        conflict.text(ours) catch |err| {
            self.refuseNonText(err);
            return;
        };
        conflict.text(theirs) catch |err| {
            self.refuseNonText(err);
            return;
        };
        const sa = self.stage_arena.allocator();
        const chosen: []const u8 = switch (choice) {
            .current => sa.dupe(u8, ours) catch |err| {
                self.failure(err);
                return;
            },
            .incoming => sa.dupe(u8, theirs) catch |err| {
                self.failure(err);
                return;
            },
            .both => conflict.combineBoth(sa, ours, theirs) catch |err| {
                self.refuseNonText(err);
                return;
            },
        };
        self.resolve_choice = choice;
        self.resolve_bytes = chosen;
        self.showResolveDialog(target.path, chosen);
    }
    pub fn showManual(self: *Controller) void {
        if (!self.ensureValid()) return;
        self.message("Manual conflict input is not provided. Edit and save the file in the editor, then stage it (Source Control → Stage selected file).");
    }
    pub fn showContinue(self: *Controller) void {
        self.operationConfirm(.continue_op);
    }
    pub fn showAbort(self: *Controller) void {
        self.operationConfirm(.abort_op);
    }
    fn operationConfirm(self: *Controller, action: ConfirmAction) void {
        if (self.engaged()) {
            self.message("Wait for the current conflict request or review to finish.");
            return;
        }
        if (!self.ensureValid()) return;
        if (self.operation == .none) {
            self.message("No merge/rebase/cherry-pick/revert is in progress (no gitdir state file).");
            return;
        }
        const verb: []const u8 = if (action == .continue_op) "Continue" else "Abort";
        const body = u.fmt("{s} the in-progress {s}? This runs `git {s} --{s}` as your user (hooks/signing may run) and can change the worktree, index and HEAD. Unsaved buffers are never saved; the action is refused while any exist under the repository.", .{ verb, self.operation.label(), self.operation.label(), if (action == .continue_op) "continue" else "abort" });
        defer a.free(body);
        self.confirm_action = action;
        self.confirm.context = self;
        self.confirm.show(self.app, "Confirm operation", body, &.{}, false, if (action == .continue_op) "Continue…" else "Abort…");
    }
    fn refuseNonText(self: *Controller, err: anyerror) void {
        const text = u.fmt("Refused: the conflict is binary/non-text or too large ({s}). Resolve it manually; no file was written.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn ensureValid(self: *Controller) bool {
        if (!self.app.git.valid()) {
            self.app.git.show();
            return false;
        }
        if (self.window == null) self.createWindow();
        return true;
    }
    fn confirmed(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        const action = self.confirm_action orelse return;
        self.confirm_action = null;
        if (!accepted or self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.message("Source Control trust changed. Invoke it again.");
            return;
        }
        self.beginOperation(action);
    }

    // --- refresh / state detection -------------------------------------------

    fn refresh(self: *Controller) void {
        self.clearListing();
        self.operation = .none;
        self.state_probe_index = 0;
        self.message("Reading conflict state — gitdir/index only…");
        self.launchStateProbe() catch |err| self.failure(err);
    }
    fn launchStateProbe(self: *Controller) !void {
        const repo = self.app.git.repo() orelse return error.NoRepository;
        const op_probe = state_probes[self.state_probe_index];
        const ref = op_probe.stateRef() orelse return error.NoOperation;
        const args = [_][]const u8{ "rev-parse", "--verify", "--quiet", ref };
        try self.launchRead(.state, repo.path, &args, 4096);
    }
    fn launchUnmerged(self: *Controller) !void {
        const repo = self.app.git.repo() orelse return error.NoRepository;
        try self.launchRead(.unmerged, repo.path, conflict.unmerged_args, capture_bytes);
    }
    fn fetchStages(self: *Controller) void {
        self.stage_fetch_step = 0;
        self.base_bytes = null;
        self.ours_bytes = null;
        self.theirs_bytes = null;
        _ = self.stage_arena.reset(.free_all);
        self.launchNextStage();
    }
    fn launchNextStage(self: *Controller) void {
        const target = self.selectedConflict() orelse return;
        const repo = self.app.git.repo() orelse return;
        while (self.stage_fetch_step < 3) {
            const entry: ?conflict.StageEntry = switch (self.stage_fetch_step) {
                0 => target.base,
                1 => target.ours,
                2 => target.theirs,
                else => null,
            };
            if (entry) |stage| {
                var buf: [conflict.max_args][]const u8 = undefined;
                const args = conflict.catFileArgs(&buf, stage.oid) catch {
                    self.stage_fetch_step += 1;
                    continue;
                };
                self.launchRead(.stage, repo.path, args, conflict.max_file_bytes) catch |err| {
                    self.failure(err);
                    return;
                };
                return;
            }
            self.stage_fetch_step += 1;
        }
        self.displayStage();
    }

    // --- resolution write ----------------------------------------------------

    fn beginResolveWrite(self: *Controller) void {
        // Hardening: revalidate live trust/permit and selection before dispatch.
        if (!self.app.git.valid()) {
            self.closeResolveDialog();
            self.app.message("Source Control trust changed. Invoke it again.");
            return;
        }
        const target = self.selectedConflict() orelse {
            self.closeResolveDialog();
            self.message("The conflict selection changed. Refresh and review again.");
            return;
        };
        if (!target.kind.resolvable()) {
            self.closeResolveDialog();
            self.message("The selected conflict is no longer a simple text merge; resolve it manually.");
            return;
        }
        const repo = self.app.git.repo() orelse {
            self.closeResolveDialog();
            return;
        };
        const bytes = self.resolve_bytes orelse {
            self.closeResolveDialog();
            return;
        };
        conflict.text(bytes) catch |err| {
            self.closeResolveDialog();
            self.refuseNonText(err);
            return;
        };
        const manager = self.app.manager orelse {
            self.closeResolveDialog();
            self.failure(error.NoManager);
            return;
        };
        const absolute = u.fmt("{s}/{s}", .{ std.mem.trimEnd(u8, repo.path, "/"), target.path });
        defer a.free(absolute);
        // The worktree file is the barrier source: an open editor document refuses
        // the overwrite, and manager-wide save/load/modal admission is enforced.
        manager.beginFileOperation(self.app, absolute, "") catch |err| {
            self.closeResolveDialog();
            self.failure(err);
            return;
        };
        self.barrier = true;
        self.closeResolveDialog();
        self.startWriteWorker(absolute, bytes) catch |err| {
            self.releaseBarrier();
            self.failure(err);
        };
    }
    fn startWriteWorker(self: *Controller, absolute: []const u8, bytes: []const u8) !void {
        const wj = try a.create(WriteJob);
        errdefer a.destroy(wj);
        wj.* = .{
            .controller = self,
            .path = try a.dupeSentinel(u8, absolute, 0),
            .bytes = try a.dupe(u8, bytes),
        };
        self.write_job = wj;
        self.app.hold();
        wj.running = true;
        const task = c.g_task_new(null, null, &writeDone, wj).?;
        c.g_task_set_task_data(task, wj, null);
        c.g_task_run_in_thread(task, &writeWorker);
        c.g_object_unref(task);
    }
    fn launchAdd(self: *Controller) void {
        const target = self.selectedConflict() orelse {
            self.releaseBarrier();
            return;
        };
        const repo = self.app.git.repo() orelse {
            self.releaseBarrier();
            return;
        };
        var buf: [conflict.max_args][]const u8 = undefined;
        const args = conflict.addArgs(&buf, target.path) catch |err| {
            self.releaseBarrier();
            self.failure(err);
            return;
        };
        self.launchWrite(.add, repo.path, args, capture_bytes) catch |err| {
            self.releaseBarrier();
            self.failure(err);
        };
    }
    fn beginOperation(self: *Controller, action: ConfirmAction) void {
        if (self.operation == .none) return;
        if (self.dirtyUnderRepo()) {
            self.message("Refused: unsaved editor buffers exist under this repository. Save or close them first; they are never saved.");
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
        var buf: [conflict.max_args][]const u8 = undefined;
        const args = conflict.operationArgs(&buf, self.operation, action == .continue_op) catch |err| {
            self.releaseBarrier();
            self.failure(err);
            return;
        };
        const phase: Phase = if (action == .continue_op) .continue_op else .abort_op;
        self.launchWrite(phase, repo.path, args, capture_bytes) catch |err| {
            self.releaseBarrier();
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

    // --- async git jobs ------------------------------------------------------

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
            .identity = .{ .scope = "git-conflict", .request = self.launches + 1, .generation = self.generation, .workspace = token },
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
            .identity = .{ .scope = "git-conflict-write", .request = self.launches + 1, .generation = self.generation, .workspace = token },
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
        switch (self.phase) {
            .state => {
                if (result.outcome == .success) {
                    self.operation = state_probes[self.state_probe_index];
                    try self.launchUnmerged();
                    return;
                }
                self.state_probe_index += 1;
                if (self.state_probe_index < state_probes.len) {
                    try self.launchStateProbe();
                } else {
                    try self.launchUnmerged();
                }
            },
            .unmerged => {
                if (result.outcome != .success) {
                    const text = u.fmt("Reading unmerged paths: {s} (exit {d}). Refresh to retry.", .{ @tagName(result.outcome), result.exit_code orelse -1 });
                    defer a.free(text);
                    self.message(text);
                    return;
                }
                var parsed = try conflict.parseUnmerged(a, result.stdout);
                if (parsed.conflicts.len > conflict.max_entries) {
                    parsed.deinit();
                    return error.TooManyConflicts;
                }
                self.clearListing();
                self.listing = parsed;
                self.renderRows();
                self.updateOperation();
                if (parsed.conflicts.len > 0) {
                    self.selected = 0;
                    self.renderRows();
                    self.fetchStages();
                } else {
                    self.message("No unmerged paths. If an operation is in progress you may continue or abort.");
                    self.setStageText("");
                }
            },
            .stage => {
                const slot = self.stage_fetch_step;
                if (result.outcome == .success) {
                    const bytes = try self.stage_arena.allocator().dupe(u8, result.stdout);
                    switch (slot) {
                        0 => self.base_bytes = bytes,
                        1 => self.ours_bytes = bytes,
                        2 => self.theirs_bytes = bytes,
                        else => {},
                    }
                }
                self.stage_fetch_step += 1;
                self.launchNextStage();
            },
            .add => {
                if (result.outcome == .success) {
                    self.message("Conflict resolved: worktree file written and staged.");
                } else if (interrupted(result.outcome)) {
                    self.message("Staging the resolved file was interrupted; the worktree file was written but the index may be partial. Refresh Source Control to inspect.");
                } else {
                    const text = u.fmt("Staging the resolved file: {s} (exit {d}). The worktree file was written; stage it manually.", .{ @tagName(result.outcome), result.exit_code orelse -1 });
                    defer a.free(text);
                    self.message(text);
                }
                self.refresh();
                self.refreshSourceControl();
            },
            .continue_op, .abort_op => {
                if (result.outcome == .success) {
                    self.message(if (self.phase == .continue_op) "Operation continued." else "Operation aborted.");
                } else if (interrupted(result.outcome)) {
                    const text = u.fmt("git {s} was interrupted ({s}). The worktree/index/HEAD may be in a partial state; no result is assumed. Refresh Source Control to inspect.", .{ @tagName(self.phase), @tagName(result.outcome) });
                    defer a.free(text);
                    self.message(text);
                } else {
                    const text = u.fmt("git {s}: {s} (exit {d}). Resolve remaining conflicts or retry.", .{ @tagName(self.phase), @tagName(result.outcome), result.exit_code orelse -1 });
                    defer a.free(text);
                    self.message(text);
                }
                self.refresh();
                self.refreshSourceControl();
            },
            .idle => {},
        }
    }
    fn refreshSourceControl(self: *Controller) void {
        if (self.app.git.valid()) self.app.git.refresh();
    }

    // --- presentation --------------------------------------------------------

    fn updateOperation(self: *Controller) void {
        const label = self.operation_label orelse return;
        const text = u.fmt("Operation: {s} (from gitdir state files). Continue/Abort run the detected Git operation.", .{self.operation.label()});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn updateOverlay(self: *Controller) void {
        const label = self.overlay orelse return;
        const text = u.fmt("Unsaved editor documents: {d} across windows (excluded; never saved). A file open in an editor cannot be overwritten by resolution.", .{self.app.git.dirtyCount()});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn setStageText(self: *Controller, text: []const u8) void {
        a.free(self.stage_text);
        self.stage_text = u.z(text);
        if (self.stage_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.stage_text.ptr, @intCast(self.stage_text.len));
    }
    fn displayStage(self: *Controller) void {
        const bytes: ?[]const u8 = switch (self.displayed_stage) {
            .base => self.base_bytes,
            .ours => self.ours_bytes,
            .theirs => self.theirs_bytes,
        };
        const content = bytes orelse {
            self.setStageText("This stage is absent for the selected conflict (e.g. no base for a both-added conflict, or a deleted side).");
            return;
        };
        switch (command.preview(content)) {
            .binary => self.setStageText("Binary stage — no textual preview is available."),
            .non_utf8 => self.setStageText("Non-UTF-8 stage — text preview is unavailable."),
            .too_large => self.setStageText("Stage exceeds native preview limits. No partial preview is shown."),
            .text => self.setStageText(content),
        }
    }
    fn updateButtons(self: *Controller) void {
        const has_operation = self.window != null and self.operation != .none and !self.engaged();
        if (self.continue_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(has_operation));
        if (self.abort_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(has_operation));
    }
    fn createWindow(self: *Controller) void {
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Source Control — conflicts");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 960, 760);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const overlay = u.label("");
        self.overlay = overlay;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, overlay), 1);
        u.append(box, overlay);
        const op_bar = u.box(true, 8);
        u.append(box, op_bar);
        const op_label = u.label("Operation: unknown");
        self.operation_label = op_label;
        c.gtk_widget_set_hexpand(op_label, 1);
        u.append(op_bar, op_label);
        const continue_button = u.button("Continue…");
        const abort_button = u.button("Abort…");
        self.continue_button = continue_button;
        self.abort_button = abort_button;
        u.append(op_bar, continue_button);
        u.append(op_bar, abort_button);
        u.connect(continue_button, "clicked", &continueClicked, self);
        u.connect(abort_button, "clicked", &abortClicked, self);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(scroll, -1, 160);
        const list = c.gtk_list_box_new().?;
        self.list_widget = list;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        u.append(box, scroll);
        u.connect(list, "row-selected", &rowSelected, self);
        const nav = u.box(true, 8);
        u.append(box, nav);
        const previous = u.button("Previous conflict");
        const next = u.button("Next conflict");
        const refresh_button = u.button("Refresh");
        u.append(nav, previous);
        u.append(nav, next);
        u.append(nav, refresh_button);
        u.connect(previous, "clicked", &previousClicked, self);
        u.connect(next, "clicked", &nextClicked, self);
        u.connect(refresh_button, "clicked", &refreshClicked, self);
        const stage_bar = u.box(true, 8);
        u.append(box, stage_bar);
        const base_button = u.button("Base (1)");
        const ours_button = u.button("Ours (2)");
        const theirs_button = u.button("Theirs (3)");
        u.append(stage_bar, base_button);
        u.append(stage_bar, ours_button);
        u.append(stage_bar, theirs_button);
        u.connect(base_button, "clicked", &baseClicked, self);
        u.connect(ours_button, "clicked", &oursClicked, self);
        u.connect(theirs_button, "clicked", &theirsClicked, self);
        const stage_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(stage_scroll, 1);
        const view = c.gtk_text_view_new().?;
        self.stage_view = view;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, stage_scroll), view);
        u.append(box, stage_scroll);
        const resolve_bar = u.box(true, 8);
        u.append(box, resolve_bar);
        const current = u.button("Use current (ours)…");
        const incoming = u.button("Use incoming (theirs)…");
        const both = u.button("Use both…");
        const manual = u.button("Manual…");
        u.append(resolve_bar, current);
        u.append(resolve_bar, incoming);
        u.append(resolve_bar, both);
        u.append(resolve_bar, manual);
        u.connect(current, "clicked", &currentClicked, self);
        u.connect(incoming, "clicked", &incomingClicked, self);
        u.connect(both, "clicked", &bothClicked, self);
        u.connect(manual, "clicked", &manualClicked, self);
        self.app.styleWindow(window);
        self.app.installTestKeys(window);
        self.updateOverlay();
        self.updateButtons();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.list_widget = null;
        self.summary = null;
        self.overlay = null;
        self.operation_label = null;
        self.stage_view = null;
        self.continue_button = null;
        self.abort_button = null;
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
        const conflicts: []const conflict.Conflict = if (self.listing) |listing| listing.conflicts else &.{};
        const end = @min(conflicts.len, max_visible_rows);
        for (conflicts[0..end]) |target| {
            const path = command.display(a, target.path, 1024) catch unreachable;
            defer a.free(path);
            const text = u.fmt("{s}  [{s}]", .{ path, @tagName(target.kind) });
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
    fn selectConflict(self: *Controller, index: usize) void {
        const listing = &(self.listing orelse return);
        if (index >= listing.conflicts.len or !self.app.git.valid()) return;
        if (self.engaged()) return;
        self.selected = index;
        self.renderRows();
        self.fetchStages();
        self.updateOverlay();
    }
    fn navigate(self: *Controller, next: bool) void {
        const listing = &(self.listing orelse return);
        if (listing.conflicts.len == 0) return;
        const current = self.selected orelse 0;
        const index = if (next) @min(current + 1, listing.conflicts.len - 1) else current -| 1;
        self.selectConflict(index);
    }

    // --- resolve review dialog -----------------------------------------------

    fn showResolveDialog(self: *Controller, path: []const u8, bytes: []const u8) void {
        const label = status.displayLabel(a, path) catch return;
        defer a.free(label);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        const heading = u.fmt("Resolve {s} — use {s}\nFull chosen bytes below ({d} bytes). SHA-256: {s}\nThis writes exactly these bytes to the worktree file, then runs `git add`. The file must not be open in an editor. Unsaved buffers are never saved. Hooks/signing may run as your user.", .{ label, @tagName(self.resolve_choice), bytes.len, hash });
        defer a.free(heading);
        const dialog = c.gtk_dialog_new().?;
        self.resolve_dialog = dialog;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), "Review conflict resolution — full file, not hunks");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 900, 700);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Write && stage", c.GTK_RESPONSE_ACCEPT);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        const content = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?);
        u.margin(content, 12);
        const heading_label = u.label(heading);
        c.gtk_label_set_selectable(u.cast(c.GtkLabel, heading_label), 1);
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, heading_label), 1);
        u.append(content, heading_label);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        const view = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
        c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), bytes.ptr, @intCast(bytes.len));
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view);
        u.append(content, scroll);
        u.connect(dialog, "response", &resolveResponse, self);
        u.connect(dialog, "destroy", &resolveDestroyed, self);
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn closeResolveDialog(self: *Controller) void {
        const dialog = self.resolve_dialog orelse return;
        self.resolve_dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    }
    fn resolveResponse(dialog: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.resolve_dialog != u.cast(c.GtkWidget, dialog.?)) return;
        if (id == c.GTK_RESPONSE_ACCEPT) {
            self.beginResolveWrite();
        } else {
            self.closeResolveDialog();
        }
    }
    fn resolveDestroyed(widget: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.resolve_dialog != widget) return;
        self.resolve_dialog = null;
    }

    // --- GTK callbacks -------------------------------------------------------

    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn rowSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const selected = row orelse return;
        const index = c.gtk_list_box_row_get_index(selected);
        if (index >= 0) self.selectConflict(@intCast(index));
    }
    fn previousClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).navigate(false);
    }
    fn nextClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).navigate(true);
    }
    fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showConflicts();
    }
    fn continueClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showContinue();
    }
    fn abortClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showAbort();
    }
    fn baseClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        self.displayed_stage = .base;
        self.displayStage();
    }
    fn oursClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        self.displayed_stage = .ours;
        self.displayStage();
    }
    fn theirsClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        self.displayed_stage = .theirs;
        self.displayStage();
    }
    fn currentClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showResolve(.current);
    }
    fn incomingClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showResolve(.incoming);
    }
    fn bothClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showResolve(.both);
    }
    fn manualClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showManual();
    }

    // --- test instrumentation ------------------------------------------------

    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "conflict-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "conflict-show")) {
            self.showConflicts();
        } else if (std.mem.eql(u8, action, "conflict-select")) {
            self.selectConflict(std.fmt.parseInt(usize, value, 10) catch return true);
        } else if (std.mem.eql(u8, action, "conflict-accept")) {
            if (self.resolve_dialog) |dialog| {
                c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_ACCEPT);
            } else {
                self.confirm.answer(true, null, "");
            }
        } else if (std.mem.eql(u8, action, "conflict-reject")) {
            if (self.resolve_dialog) |dialog| {
                c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
            } else {
                self.confirm.answer(false, null, "");
            }
        } else if (std.mem.eql(u8, action, "conflict-resolve-current")) {
            self.showResolve(.current);
        } else if (std.mem.eql(u8, action, "conflict-resolve-incoming")) {
            self.showResolve(.incoming);
        } else if (std.mem.eql(u8, action, "conflict-resolve-both")) {
            self.showResolve(.both);
        } else if (std.mem.eql(u8, action, "conflict-continue")) {
            self.showContinue();
        } else if (std.mem.eql(u8, action, "conflict-abort")) {
            self.showAbort();
        } else if (std.mem.eql(u8, action, "conflict-close")) {
            self.invalidate();
        } else return false;
        return true;
    }
    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const conflicts: []const conflict.Conflict = if (self.listing) |listing| listing.conflicts else &.{};
        const end = @min(conflicts.len, max_visible_rows);
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
            .writes_committed = self.writes_committed,
            .operation = @tagName(self.operation),
            .conflicts = conflicts[0..end],
            .conflict_count = conflicts.len,
            .selected = self.selected,
            .displayed_stage = @tagName(self.displayed_stage),
            .base_bytes = if (self.base_bytes) |b| b.len else null,
            .ours_bytes = if (self.ours_bytes) |b| b.len else null,
            .theirs_bytes = if (self.theirs_bytes) |b| b.len else null,
            .resolve_dialog = self.resolve_dialog != null,
            .confirm = if (self.confirm_action) |action| @as(?[]const u8, @tagName(action)) else null,
            .barrier = self.barrier,
            .stage = self.stage_text,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_CONFLICT %s\n", line.ptr);
    }
};

// --- safe worktree write worker ----------------------------------------------

var write_counter: std.atomic.Value(u64) = .init(0);

const WriteJob = struct {
    controller: *Controller,
    path: [:0]u8,
    bytes: []u8,
    cancel: std.atomic.Value(bool) = .init(false),
    running: bool = false,
    err: ?anyerror = null,
    committed: bool = false,

    fn destroy(self: *WriteJob) void {
        a.free(self.path);
        a.free(self.bytes);
        a.destroy(self);
    }
};

fn writeWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const wj = u.cast(WriteJob, data.?);
    safeWriteFile(wj.path, wj.bytes, &wj.cancel) catch |err| {
        wj.err = err;
    };
    if (wj.err == null) wj.committed = true;
    c.g_task_return_boolean(task, 1);
}
fn writeDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const wj = u.cast(WriteJob, data.?);
    const self = wj.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.write_job == wj and wj.running);
    wj.running = false;
    self.write_job = null;
    const cancelled = wj.cancel.load(.acquire) or self.app.closing;
    const err = wj.err;
    const committed = wj.committed;
    wj.destroy();
    self.app.release();
    // Publication wins over cancellation: once safeWriteFile renames, the worktree
    // file is changed and must be recorded/reported even if a close raced in.
    if (committed) {
        self.writes_committed += 1;
        if (!cancelled and self.app.git.valid()) {
            // Stage the written file under the still-held barrier.
            self.launchAdd();
        } else {
            // Closing/invalid: skip staging, but the write is published. Release the
            // barrier and refresh Source Control when possible so the new disk state
            // is not mistaken for the old snapshot.
            self.releaseBarrier();
            self.message("Conflict file written; staging skipped because the workspace is closing or changed. Stage it manually.");
            self.refreshSourceControl();
        }
        self.updateButtons();
        return;
    }
    if (cancelled) {
        self.releaseBarrier();
        self.message("Conflict write cancelled before publication; the worktree file is unchanged. Refresh to confirm.");
        self.refreshSourceControl();
        self.updateButtons();
        return;
    }
    if (err) |e| {
        self.releaseBarrier();
        self.failure(e);
        self.updateButtons();
        return;
    }
    self.releaseBarrier();
    self.failure(error.NotCommitted);
    self.updateButtons();
}

/// Descriptor-checked atomic replace. Walks every parent component with
/// O_NOFOLLOW|O_DIRECTORY, refuses symlink/non-regular targets, writes a private
/// temp file, syncs, renames over the target and syncs the directory. Worker-only.
fn safeWriteFile(path: [:0]const u8, bytes: []const u8, cancel: *std.atomic.Value(bool)) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
    if (path.len == 0 or path[0] != '/') return error.UnsafePath;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.UnsafePath;
    const name = trimmed[last_slash + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafePath;
    const name_z = try a.dupeSentinel(u8, name, 0);
    defer a.free(name_z);

    var dir = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC);
    if (dir < 0) return error.UnsafeDirectory;
    var components = std.mem.tokenizeScalar(u8, trimmed[0..last_slash], '/');
    while (components.next()) |component| {
        if (cancel.load(.acquire)) {
            _ = os.close(dir);
            return error.Cancelled;
        }
        const comp_z = try a.dupeSentinel(u8, component, 0);
        defer a.free(comp_z);
        const next = os.openat(dir, comp_z, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC);
        if (next < 0) {
            _ = os.close(dir);
            return error.UnsafeDirectory;
        }
        _ = os.close(dir);
        dir = next;
    }
    defer _ = os.close(dir);

    // Inspect the existing target without following symlinks.
    var mode: c_uint = 0o644;
    var st: os.struct_stat = undefined;
    if (os.fstatat(dir, name_z, &st, os.AT_SYMLINK_NOFOLLOW) == 0) {
        if (st.st_mode & os.S_IFMT != os.S_IFREG) return error.UnsafeFile;
        mode = @intCast(st.st_mode & 0o777);
    } else if (os.__errno_location().* != os.ENOENT) {
        return error.ReadFailed;
    }

    const serial = write_counter.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrintSentinel(a, ".coral-resolve-{d}-{d}.tmp", .{ os.getpid(), serial }, 0);
    defer a.free(tmp);
    const fd = os.openat(dir, tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.TempFailed;
    var published = false;
    defer {
        if (!published) _ = os.unlinkat(dir, tmp, 0);
        _ = os.close(fd);
    }
    if (cancel.load(.acquire)) return error.Cancelled;
    var used: usize = 0;
    while (used < bytes.len) {
        const n = os.write(fd, bytes[used..].ptr, bytes.len - used);
        if (n < 0 and os.__errno_location().* == os.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        used += @intCast(n);
    }
    if (os.fchmod(fd, mode) != 0) return error.SyncFailed;
    if (os.fsync(fd) != 0) return error.SyncFailed;
    if (cancel.load(.acquire)) return error.Cancelled;
    if (os.renameat(dir, tmp, dir, name_z) != 0) return error.PublishFailed;
    published = true;
    _ = os.fsync(dir);
}
