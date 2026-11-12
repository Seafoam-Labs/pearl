//! Native worktree list/create/open/remove on the selected Source Control
//! repository. Parent owns commands and lifecycle invalidation; this module is
//! not wired into App by itself. Every command requires the existing Source
//! Control disclosure/trust (app.git.valid()); writes additionally consume a
//! separate per-operation native confirmation here.
//!
//! Create validates the requested path lexically inside the owning workspace
//! root (worktree.zig), refuses registered worktree paths, and enforces Git's
//! one-worktree-per-branch restriction before writing. Git itself refuses
//! existing non-empty paths (no overwrite); an existing EMPTY directory may be
//! used by Git without data loss. Remove is clean-only: a fresh status capture
//! must show zero changes, locked/prunable/main worktrees are refused, and
//! --force is never used. Open hands the path to a parent callback when one is
//! installed, otherwise it messages the path; non-Git roots are never touched.
//!
//! Writes use env.zig's write prefix/environment: the user's Git configuration
//! applies and configured hooks (post-checkout, …) can execute programs with
//! the user's permissions. This is NOT a sandbox. No network commands.
//!
//! Churn recapture: creating/removing a worktree inside the monitored workspace
//! root trips the parent's structural watch, which retires Source Control
//! approval and invalidates this controller. The last target captured while
//! Source Control was fully approved is retained; later commands may recapture
//! that SAME repository only while machine trust re-validates live (issue/
//! validate of a .git permit) and the current workspace model still owns it.
//! This never grants a first approval, never bypasses a revocation, and every
//! write still consumes its own native confirmation.
//!
//! Worktree writes hold the manager file-operation barrier until the job is
//! reaped, matching stash/conflict: remove barriers the target worktree path
//! as source, add barriers the new path as destination, so open documents,
//! workspace roots and manifests under the affected tree refuse the write
//! across peer windows, alongside manager-wide save/load/modal admission. A
//! discarded write result (cancellation/invalidation after launch) is never
//! silent: it surfaces a partial-state warning and refreshes Source Control
//! when still valid.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const refs = @import("refs.zig");
const worktree = @import("worktree.zig");
const env = @import("env.zig");
const UI = @import("../language/ui.zig").UI;
const RootId = @import("../workspace/model.zig").RootId;
const identity = @import("../workspace/identity.zig");

pub const capture_bytes = 1024 * 1024;
pub const small_capture_bytes = 16 * 1024;
pub const max_picker_rows = 512;
pub const probe_rows = 128;

const Phase = enum { list, branches, status, write };
const Intent = enum { none, list, branches, status, write };
const Flow = enum { none, list_pick, add_path, add_branch, add_confirm, remove_pick, remove_check, remove_confirm };
const Action = enum { none, add_existing, add_new, remove };
pub const OpenMode = enum { none, message, callback };

const Target = struct {
    root: RootId,
    owner: []const u8,
    path: []const u8,
    gitdir: []const u8,
    commondir: []const u8,
};

/// Heap-owned (survives arena resets) memory of the last fully approved
/// repository, for churn recapture only. Never a substitute for disclosure.
const Recall = struct {
    root: RootId,
    owner: [:0]u8,
    path: [:0]u8,
    gitdir: [:0]u8,
    commondir: [:0]u8,
    model_token: identity.Token,
};

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .list,
    pending: Intent = .none,
    flow: Flow = .none,
    action: Action = .none,
    ui: UI,
    target: ?Target = null,
    recall: ?Recall = null,
    worktrees: ?worktree.List = null,
    branches: ?refs.Branches = null,
    snapshot: ?status.Snapshot = null,
    picker: []const usize = &.{},
    add_path: ?[]const u8 = null,
    add_name: ?[]const u8 = null,
    add_new: bool = false,
    remove_path: ?[]const u8 = null,
    dirty: usize = 0,
    /// Parent may install a callback to open the selected worktree as a
    /// workspace; without one, Open messages the path. The callback runs on the
    /// GTK thread and must not mutate this controller reentrantly.
    open_callback: ?*const fn (context: *anyopaque, app: *App, path: []const u8) void = null,
    open_context: ?*anyopaque = null,
    opened_path: ?[:0]u8 = null,
    open_mode: OpenMode = .none,
    message_text: [:0]u8,
    error_name: ?[]const u8 = null,
    launches: u64 = 0,
    discarded: u64 = 0,
    writes: u64 = 0,
    barrier: bool = false,
    write_attempted: bool = false,
    write_action: Action = .none,
    discarded_writes: u64 = 0,

    pub fn init(app: *App) Controller {
        // Do not reach through App.git here: its parent is still being initialized.
        return .{ .app = app, .arena = std.heap.ArenaAllocator.init(a), .ui = .{ .context = app, .respond = &answered }, .message_text = u.z("Worktrees — Source Control approval required") };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.supervisor.isIdle() and !self.barrier);
        self.invalidate();
        self.supervisor.shutdown();
        self.freeRecall();
        self.arena.deinit();
        if (self.opened_path) |path| a.free(path);
        a.free(self.message_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.ui.close();
        self.clearModel();
        if (self.opened_path) |path| a.free(path);
        self.opened_path = null;
        self.open_mode = .none;
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.pending != .none;
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Worktree generation exhausted");
        self.pending = .none;
        self.flow = .none;
        self.action = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearModel(self: *Controller) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
        if (self.worktrees) |*list| list.deinit();
        self.worktrees = null;
        if (self.branches) |*branches| branches.deinit();
        self.branches = null;
        self.target = null;
        self.picker = &.{};
        self.add_path = null;
        self.add_name = null;
        self.add_new = false;
        self.remove_path = null;
        self.dirty = 0;
        _ = self.arena.reset(.free_all);
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        self.app.message(text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.pending = .none;
        self.flow = .none;
        self.action = .none;
        const text = u.fmt("Worktrees: {s}. Nothing was changed.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn gitFailure(self: *Controller, result: process.Result) void {
        self.error_name = "GitFailed";
        self.flow = .none;
        self.action = .none;
        const detail = command.display(a, result.stderr, 512) catch "";
        defer if (detail.len != 0) a.free(detail);
        const text = u.fmt("Git {s}: {s} (exit {d}). {s} No partial result was applied; nothing was forced.", .{ @tagName(self.phase), @tagName(result.outcome), result.exit_code orelse -1, detail });
        defer a.free(text);
        self.message(text);
    }

    /// Source Control disclosure/trust gate. An unapproved or restricted window
    /// is sent through the existing disclosure; no write is queued by it. After
    /// churn invalidation (a worktree write inside the monitored root), a
    /// previously approved repository may be recaptured only while live machine
    /// trust and the current workspace model confirm it.
    fn gate(self: *Controller) bool {
        if (self.app.closing) return false;
        if (self.app.git.valid()) {
            if (self.app.git.repo() == null) {
                self.message("No repository selected. Open Source Control and Refresh first.");
                return false;
            }
            return true;
        }
        if (self.recallValid()) return true;
        if (self.recall != null) {
            self.message("Source Control was invalidated by a workspace change. Trust revalidation is pending or the repository changed; retry, or reopen Source Control to review the disclosure again.");
            return false;
        }
        self.app.git.show();
        return false;
    }
    fn freeRecall(self: *Controller) void {
        if (self.recall) |r| {
            a.free(r.owner);
            a.free(r.path);
            a.free(r.gitdir);
            a.free(r.commondir);
        }
        self.recall = null;
    }
    fn rememberRecall(self: *Controller, target: Target) void {
        const model = &(self.app.browser.model orelse return);
        const token = model.scope.capture() orelse return;
        self.freeRecall();
        self.recall = .{
            .root = target.root,
            .owner = u.z(target.owner),
            .path = u.z(target.path),
            .gitdir = u.z(target.gitdir),
            .commondir = u.z(target.commondir),
            .model_token = token,
        };
    }
    /// Live machine-trust + workspace-model confirmation of the recalled
    /// repository. A revoked, verifying, closed or changed workspace fails.
    fn recallValid(self: *Controller) bool {
        const r = self.recall orelse return false;
        if (self.app.browser.closed or self.app.browser.loading or self.app.browser.choosing) return false;
        const model = &(self.app.browser.model orelse return false);
        if (!model.scope.accepts(r.model_token)) return false;
        const root = model.rootById(r.root) orelse return false;
        if (root.availability != .available) return false;
        const canonical = root.canonical_path orelse return false;
        if (!std.mem.eql(u8, canonical, r.owner)) return false;
        if (!command.contains(r.owner, r.path)) return false;
        const permit = self.app.workspace_policy.issue(.git) catch return false;
        return self.app.workspace_policy.validate(permit, .git);
    }
    fn revalidate(self: *Controller) bool {
        if (self.app.closing) return false;
        const target = self.target orelse return false;
        if (self.app.git.valid()) {
            const current = self.app.git.repo() orelse return false;
            return current.root == target.root and std.mem.eql(u8, current.owner, target.owner) and
                std.mem.eql(u8, current.path, target.path) and std.mem.eql(u8, current.gitdir, target.gitdir) and
                std.mem.eql(u8, current.commondir, target.commondir);
        }
        if (!self.recallValid()) return false;
        const r = self.recall.?;
        return r.root == target.root and std.mem.eql(u8, r.owner, target.owner) and
            std.mem.eql(u8, r.path, target.path) and std.mem.eql(u8, r.gitdir, target.gitdir) and
            std.mem.eql(u8, r.commondir, target.commondir);
    }
    fn captureTarget(self: *Controller) !void {
        const aa = self.arena.allocator();
        if (self.app.git.repo()) |repository| {
            const target: Target = .{
                .root = repository.root,
                .owner = try aa.dupe(u8, repository.owner),
                .path = try aa.dupe(u8, repository.path),
                .gitdir = try aa.dupe(u8, repository.gitdir),
                .commondir = try aa.dupe(u8, repository.commondir),
            };
            self.target = target;
            self.rememberRecall(target);
            return;
        }
        const r = self.recall orelse return error.NoRepository;
        if (!self.recallValid()) return error.Restricted;
        self.target = .{
            .root = r.root,
            .owner = try aa.dupe(u8, r.owner),
            .path = try aa.dupe(u8, r.path),
            .gitdir = try aa.dupe(u8, r.gitdir),
            .commondir = try aa.dupe(u8, r.commondir),
        };
    }
    fn startFlow(self: *Controller, flow: Flow) void {
        if (!self.gate()) return;
        self.cancel();
        self.clearModel();
        self.error_name = null;
        self.captureTarget() catch |err| return self.failure(err);
        self.flow = flow;
        self.pending = .list;
        self.drain();
    }

    pub fn showWorktrees(self: *Controller) void {
        self.startFlow(.list_pick);
    }
    pub fn showAddWorktree(self: *Controller) void {
        self.startFlow(.add_path);
    }
    pub fn showRemoveWorktree(self: *Controller) void {
        self.startFlow(.remove_pick);
    }

    fn drain(self: *Controller) void {
        if (self.job != null or self.pending == .none) return;
        const intent = self.pending;
        self.pending = .none;
        if (!self.revalidate()) {
            self.invalidate();
            return;
        }
        const target = self.target orelse return self.failure(error.NoRepository);
        switch (intent) {
            .list => self.launch(.list, target.path, &.{ "worktree", "list", "--porcelain", "-z" }, capture_bytes, false) catch |err| self.failure(err),
            .branches => self.launch(.branches, target.path, &.{ "for-each-ref", "--format=" ++ refs.branch_format, "refs/heads" }, capture_bytes, false) catch |err| self.failure(err),
            .status => self.launch(.status, self.remove_path orelse target.path, command.status_args, capture_bytes, false) catch |err| self.failure(err),
            .write => self.launchWrite() catch |err| self.failure(err),
            .none => {},
        }
    }
    fn launch(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize, write: bool) !void {
        if (!self.revalidate()) return error.Restricted;
        if (self.job != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        const prefix = if (write) env.write_prefix else command.prefix;
        if (prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..prefix.len], prefix);
        @memcpy(argv[prefix.len..][0..args.len], args);
        const token = self.app.workspace.capture() orelse return error.Closed;
        self.phase = phase;
        if (write) {
            // env.write allocates inner strings; process.start copies everything,
            // so a scratch arena owns them only until start returns.
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const environment = try env.write(scratch.allocator());
            self.job = try process.start(a, .{
                .owner = &self.supervisor,
                .authorization = .approved,
                .identity = .{ .scope = "git-worktree", .request = self.launches + 1, .generation = self.generation, .workspace = token },
                .argv = argv[0 .. prefix.len + args.len],
                .cwd = cwd,
                .environment = environment,
                .output_limit = limit,
                .timeout_ms = 15000,
            }, &completed, self);
            self.writes += 1;
        } else {
            var environment: [command.environment.len]process.Environment = undefined;
            for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
            self.job = try process.start(a, .{
                .owner = &self.supervisor,
                .authorization = .approved,
                .identity = .{ .scope = "git-worktree", .request = self.launches + 1, .generation = self.generation, .workspace = token },
                .argv = argv[0 .. prefix.len + args.len],
                .cwd = cwd,
                .environment = &environment,
                .output_limit = limit,
                .timeout_ms = 15000,
            }, &completed, self);
        }
        self.launches += 1;
        self.app.hold();
    }
    fn launchWrite(self: *Controller) !void {
        const target = self.target orelse return error.NoRepository;
        const args: []const []const u8 = switch (self.action) {
            .add_existing => &.{ "worktree", "add", "--", self.add_path orelse return error.NoSelection, self.add_name orelse return error.NoSelection },
            .add_new => &.{ "worktree", "add", "-b", self.add_name orelse return error.NoSelection, "--", self.add_path orelse return error.NoSelection },
            .remove => &.{ "worktree", "remove", "--", self.remove_path orelse return error.NoSelection },
            .none => return error.NoAction,
        };
        // The affected tree is the barrier scope: remove deletes the target
        // worktree (source), add creates the new path (destination). The
        // manager check refuses open documents, workspace roots and manifests
        // under that tree across all windows, plus concurrent saves/operations.
        switch (self.action) {
            .add_existing, .add_new => try self.acquireBarrier("", self.add_path orelse return error.NoSelection),
            .remove => try self.acquireBarrier(self.remove_path orelse return error.NoSelection, ""),
            .none => return error.NoAction,
        }
        self.launch(.write, target.path, args, small_capture_bytes, true) catch |err| {
            self.releaseBarrier();
            return err;
        };
        self.write_attempted = true;
        self.write_action = self.action;
    }
    fn acquireBarrier(self: *Controller, source: []const u8, destination: []const u8) !void {
        const manager = self.app.manager orelse return error.NoManager;
        try manager.beginFileOperation(self.app, source, destination);
        self.barrier = true;
    }
    fn releaseBarrier(self: *Controller) void {
        if (!self.barrier) return;
        self.barrier = false;
        if (self.app.manager) |manager| manager.endFileOperation(self.app);
    }
    /// A write whose result is discarded after cancellation/invalidation may
    /// have published partial or complete changes; Git is not rolled back.
    fn discardedWrite(self: *Controller) void {
        if (self.phase != .write) return;
        self.discarded_writes += 1;
        const text = u.fmt("An interrupted Git worktree write ({s}) was discarded after invalidation. It may have left partial changes; nothing was rolled back. Verify the repository before retrying.", .{@tagName(self.write_action)});
        defer a.free(text);
        self.message(text);
        if (self.app.git.valid()) self.app.git.refresh();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        defer self.app.release();
        // The barrier is held until reap: a cancelled child may still be
        // writing. Release on every delivery path, including discards.
        defer self.releaseBarrier();
        defer job.destroy();
        std.debug.assert(self.job == job);
        self.job = null;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            self.discardedWrite();
            self.drain();
            return;
        }
        if (!self.revalidate() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.invalidate();
            self.discardedWrite();
            return;
        }
        self.receive(result) catch |err| self.failure(err);
    }
    fn receive(self: *Controller, result: process.Result) !void {
        switch (self.phase) {
            .list => {
                if (result.outcome != .success) return self.gitFailure(result);
                var parsed = try worktree.parseList(a, result.stdout);
                if (self.worktrees) |*list| list.deinit();
                self.worktrees = parsed;
                switch (self.flow) {
                    .list_pick => self.showListPicker(),
                    .remove_pick => self.showRemovePicker(),
                    .add_path => {
                        if (parsed.items.len == 0 or parsed.items[0].unborn()) {
                            self.flow = .none;
                            self.message("Unborn HEAD: no commit exists yet. Create the first commit before adding worktrees.");
                            return;
                        }
                        self.showPathInput();
                    },
                    else => return error.InvalidFlow,
                }
            },
            .branches => {
                if (result.outcome != .success) return self.gitFailure(result);
                const parsed = try refs.parseBranches(a, result.stdout);
                if (self.branches) |*branches| branches.deinit();
                self.branches = parsed;
                self.showAddBranchPicker();
            },
            .status => {
                if (result.outcome != .success) return self.gitFailure(result);
                var parsed = try status.parse(a, result.stdout);
                if (parsed.entries.len > status.max_entries) {
                    parsed.deinit();
                    return error.TooManyStatusEntries;
                }
                if (self.snapshot) |*snapshot| snapshot.deinit();
                self.snapshot = parsed;
                self.dirty = parsed.entries.len;
                if (self.dirty != 0) {
                    self.flow = .none;
                    const path = command.display(a, self.remove_path orelse "", 1024) catch return self.failure(error.OutOfMemory);
                    defer a.free(path);
                    const text = u.fmt("Worktree '{s}' has {d} modified/untracked paths. Removal is clean-only: commit, clean or move them first. No --force was used; nothing was removed.", .{ path, self.dirty });
                    defer a.free(text);
                    self.message(text);
                    return;
                }
                self.showRemoveConfirm();
            },
            .write => {
                // A delivered write result (success or refusal) is a known
                // outcome; only discarded results leave uncertainty.
                self.write_attempted = false;
                if (result.outcome != .success) return self.gitFailure(result);
                switch (self.action) {
                    .add_existing, .add_new => {
                        const path = command.display(a, self.add_path orelse "", 1024) catch return self.failure(error.OutOfMemory);
                        defer a.free(path);
                        const name = command.display(a, self.add_name orelse "", 512) catch return self.failure(error.OutOfMemory);
                        defer a.free(name);
                        const text = u.fmt("Worktree created at '{s}' on branch '{s}'. Use Show worktrees → Open to open it as a workspace.", .{ path, name });
                        defer a.free(text);
                        self.message(text);
                    },
                    .remove => {
                        const path = command.display(a, self.remove_path orelse "", 1024) catch return self.failure(error.OutOfMemory);
                        defer a.free(path);
                        const text = u.fmt("Removed clean worktree '{s}'. Its branch is no longer checked out there.", .{path});
                        defer a.free(text);
                        self.message(text);
                    },
                    .none => {},
                }
                // Listings captured before the write are stale.
                if (self.worktrees) |*list| list.deinit();
                self.worktrees = null;
                if (self.branches) |*branches| branches.deinit();
                self.branches = null;
                self.flow = .none;
                self.action = .none;
            },
        }
    }

    fn dialog(self: *Controller, title: [:0]const u8, body: []const u8, rows: []const []const u8, prompt: bool, accept: ?[:0]const u8) void {
        self.ui.context = self;
        self.ui.show(self.app, title, body, rows, prompt, accept);
    }
    fn answered(context: *anyopaque, accepted: bool, index: ?usize, text: []const u8) void {
        const self = u.cast(Controller, context);
        if (self.app.closing) {
            self.invalidate();
            return;
        }
        const flow = self.flow;
        if (!accepted) {
            self.flow = .none;
            self.action = .none;
            self.message("Cancelled. Nothing was changed.");
            return;
        }
        switch (flow) {
            .list_pick => self.openPicked(index),
            .remove_pick => self.removePicked(index),
            .add_path => self.pathPicked(text),
            .add_branch => self.addBranchPicked(index, text),
            .add_confirm => self.confirmWrite(if (self.add_new) .add_new else .add_existing),
            .remove_confirm => self.confirmWrite(.remove),
            else => self.flow = .none,
        }
    }
    fn confirmWrite(self: *Controller, action: Action) void {
        if (!self.revalidate()) {
            self.invalidate();
            self.message("Workspace, trust or repository selection changed. The write was cancelled.");
            return;
        }
        self.action = action;
        self.flow = .none;
        self.pending = .write;
        self.drain();
    }
    fn pickedItem(self: *Controller, index: ?usize) ?*const worktree.Worktree {
        const list = self.worktrees orelse return null;
        const picked = index orelse return null;
        if (picked >= self.picker.len) return null;
        const item = &list.items[self.picker[picked]];
        return item;
    }
    fn openPicked(self: *Controller, index: ?usize) void {
        const item = self.pickedItem(index) orelse return self.failure(error.NoSelection);
        self.flow = .none;
        if (item.bare) {
            self.message("Bare worktrees cannot be opened as a workspace.");
            return;
        }
        self.openPath(item.path);
    }
    fn openPath(self: *Controller, path: []const u8) void {
        if (self.opened_path) |old| a.free(old);
        self.opened_path = u.z(path);
        if (self.open_callback) |callback| if (self.open_context) |context| {
            self.open_mode = .callback;
            callback(context, self.app, path);
            return;
        };
        self.open_mode = .message;
        const display = command.display(a, path, 1024) catch {
            self.message("Worktree path captured; display failed. Use Open Workspace… with the path from the probe.");
            return;
        };
        defer a.free(display);
        const text = u.fmt("Open worktree as a workspace: {s} — use Open Workspace… to open it in a new window. No workspace roots were changed.", .{display});
        defer a.free(text);
        self.message(text);
    }
    fn removePicked(self: *Controller, index: ?usize) void {
        const item = self.pickedItem(index) orelse return self.failure(error.NoSelection);
        if (item.main) {
            self.message("The main worktree cannot be removed.");
            self.showRemovePicker();
            return;
        }
        if (std.mem.eql(u8, item.path, self.target.?.path)) {
            self.message("Cannot remove the worktree Source Control is operating on. Select another repository first.");
            self.showRemovePicker();
            return;
        }
        if (item.bare) {
            self.message("Bare worktree entries cannot be removed here.");
            self.showRemovePicker();
            return;
        }
        if (item.locked) {
            const reason = command.display(a, item.lock_reason orelse "no reason given", 256) catch return self.failure(error.OutOfMemory);
            defer a.free(reason);
            const text = u.fmt("Worktree is locked ({s}). Unlock it first; no force removal is available.", .{reason});
            defer a.free(text);
            self.message(text);
            self.showRemovePicker();
            return;
        }
        if (item.prunable) {
            self.message("Worktree directory is missing (prunable). Use `git worktree prune` to clean the registration; nothing to remove here.");
            self.showRemovePicker();
            return;
        }
        const aa = self.arena.allocator();
        self.remove_path = aa.dupe(u8, item.path) catch return self.failure(error.OutOfMemory);
        self.flow = .remove_check;
        self.pending = .status;
        self.drain();
    }
    fn pathPicked(self: *Controller, text: []const u8) void {
        const target = self.target orelse return self.failure(error.NoRepository);
        const list = self.worktrees orelse return self.failure(error.NoListing);
        worktree.validatePath(target.owner, target.path, target.gitdir, target.commondir, text) catch |err| {
            const reason: []const u8 = switch (err) {
                error.NotAbsolute => "The path must be absolute.",
                error.InvalidPath => "The path must be canonical: no '.', '..', empty components, NUL or trailing '/'.",
                error.PathTooLong => "The path exceeds 4,095 bytes.",
                error.InvalidUtf8 => "The path must be valid UTF-8.",
                error.OutsideRoot => "The path must be inside the owning workspace root.",
                error.RootItself => "The workspace root itself cannot become a worktree.",
                error.RepositoryItself => "The repository itself cannot become a new worktree.",
                error.GitMetadataPath => "The path is inside Git metadata.",
                error.GitComponent => "The path contains a '.git' component.",
            };
            const body = u.fmt("{s}\nOwning root: {s}\nEnter a different absolute path inside that root.", .{ reason, target.owner });
            defer a.free(body);
            self.message(reason);
            self.dialog("Add worktree — path", body, &.{}, true, "Continue");
            return;
        };
        if (worktree.findPath(list.items, text) != null) {
            self.message("That path is already a registered worktree. Choose a different path.");
            self.showPathInput();
            return;
        }
        const aa = self.arena.allocator();
        self.add_path = aa.dupe(u8, text) catch return self.failure(error.OutOfMemory);
        self.flow = .add_branch;
        self.pending = .branches;
        self.drain();
    }
    fn addBranchPicked(self: *Controller, index: ?usize, text: []const u8) void {
        const branches = self.branches orelse return self.failure(error.NoListing);
        const list = self.worktrees orelse return self.failure(error.NoListing);
        const aa = self.arena.allocator();
        if (text.len != 0) {
            if (!refs.validName(text)) {
                self.message("Invalid branch name. Git ref-name rules apply; no leading '-', spaces, controls or '.lock' components.");
                self.showAddBranchPicker();
                return;
            }
            for (branches.items) |branch| if (!branch.remote and std.mem.eql(u8, branch.name, text)) {
                self.message("That branch already exists. Select it in the list instead of typing its name.");
                self.showAddBranchPicker();
                return;
            };
            self.add_name = aa.dupe(u8, text) catch return self.failure(error.OutOfMemory);
            self.add_new = true;
        } else {
            const picked = index orelse {
                self.message("Select an existing local branch or type a new branch name.");
                self.showAddBranchPicker();
                return;
            };
            if (picked >= self.picker.len) return self.failure(error.NoSelection);
            const branch = branches.items[self.picker[picked]];
            if (worktree.checkedOutPath(list.items, branch.ref)) |where| {
                const display = command.display(a, where, 1024) catch return self.failure(error.OutOfMemory);
                defer a.free(display);
                const body = u.fmt("Branch '{s}' is already checked out at '{s}'. Git allows a branch in only one worktree; choose another branch or create a new one.", .{ branch.name, display });
                defer a.free(body);
                self.message(body);
                self.showAddBranchPicker();
                return;
            }
            self.add_name = aa.dupe(u8, branch.name) catch return self.failure(error.OutOfMemory);
            self.add_new = false;
        }
        self.flow = .add_confirm;
        self.showAddConfirm();
    }
    fn showListPicker(self: *Controller) void {
        const list = self.worktrees orelse return self.failure(error.NoListing);
        const aa = self.arena.allocator();
        var rows: std.ArrayList([]const u8) = .empty;
        var map: std.ArrayList(usize) = .empty;
        for (list.items, 0..) |item, i| {
            if (rows.items.len == max_picker_rows) break;
            const row = self.worktreeRow(aa, item) catch return self.failure(error.OutOfMemory);
            rows.append(aa, row) catch return self.failure(error.OutOfMemory);
            map.append(aa, i) catch return self.failure(error.OutOfMemory);
        }
        self.picker = map.toOwnedSlice(aa) catch return self.failure(error.OutOfMemory);
        const body = self.pickerBody("Select a worktree to open it as a workspace. Opening hands the path to the parent (callback or message); non-Git workspace roots are never modified.") catch return self.failure(error.OutOfMemory);
        if (rows.items.len == 0) {
            self.dialog("Worktrees — none", "No worktrees are registered.", &.{}, false, null);
            return;
        }
        self.dialog("Worktrees", body, rows.items, false, "Open selected worktree");
    }
    fn showRemovePicker(self: *Controller) void {
        const list = self.worktrees orelse return self.failure(error.NoListing);
        const aa = self.arena.allocator();
        var rows: std.ArrayList([]const u8) = .empty;
        var map: std.ArrayList(usize) = .empty;
        for (list.items, 0..) |item, i| {
            if (rows.items.len == max_picker_rows) break;
            const row = self.worktreeRow(aa, item) catch return self.failure(error.OutOfMemory);
            rows.append(aa, row) catch return self.failure(error.OutOfMemory);
            map.append(aa, i) catch return self.failure(error.OutOfMemory);
        }
        self.picker = map.toOwnedSlice(aa) catch return self.failure(error.OutOfMemory);
        const body = self.pickerBody("Select a linked worktree to remove. Clean-only: modified/untracked files refuse removal; locked, prunable and main worktrees are refused. No --force is ever used.") catch return self.failure(error.OutOfMemory);
        if (rows.items.len == 0) {
            self.dialog("Remove worktree — none", "No worktrees are registered.", &.{}, false, null);
            return;
        }
        self.dialog("Remove worktree…", body, rows.items, false, "Remove selected worktree…");
    }
    fn worktreeRow(self: *Controller, aa: std.mem.Allocator, item: worktree.Worktree) ![]const u8 {
        _ = self;
        const path = try command.display(aa, item.path, 1024);
        const state: []const u8 = if (item.bare) "bare" else if (item.unborn()) "unborn" else if (item.detached) blk: {
            const oid = item.head orelse "unknown";
            break :blk try std.fmt.allocPrint(aa, "detached @ {s}", .{oid[0..@min(oid.len, 12)]});
        } else if (item.branch) |ref| try std.fmt.allocPrint(aa, "{s}", .{refs.shortName(ref) orelse ref}) else "unknown";
        return std.fmt.allocPrint(aa, "{s}  {s}{s}{s}{s}{s}", .{
            path,
            state,
            if (item.main) "  [main]" else "",
            if (item.locked) "  [locked]" else "",
            if (item.prunable) "  [prunable]" else "",
            if (item.bare) "  [bare]" else "",
        });
    }
    fn pickerBody(self: *Controller, hint: []const u8) ![]const u8 {
        const target = self.target orelse return error.NoRepository;
        const path = try command.display(a, target.path, 1024);
        defer a.free(path);
        const owner = try command.display(a, target.owner, 1024);
        defer a.free(owner);
        return std.fmt.allocPrint(self.arena.allocator(), "Repository: {s}\nOwning workspace root: {s}\n{s}", .{ path, owner, hint });
    }
    fn showPathInput(self: *Controller) void {
        const target = self.target orelse return self.failure(error.NoRepository);
        const owner = command.display(a, target.owner, 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(owner);
        const body = u.fmt("New worktree path (absolute, inside owning workspace root '{s}').\nRules: canonical components (no '.'/'..'), no '.git' component, not the root/repository itself, not inside Git metadata, not an already-registered worktree. Git refuses existing non-empty paths (no overwrite); an existing empty directory may be used.\nThe worktree is created by `git worktree add` as your user; configured hooks can execute programs.", .{owner});
        defer a.free(body);
        self.dialog("Add worktree — path", body, &.{}, true, "Continue");
    }
    fn showAddBranchPicker(self: *Controller) void {
        const branches = self.branches orelse return self.failure(error.NoListing);
        const list = self.worktrees orelse return self.failure(error.NoListing);
        const aa = self.arena.allocator();
        var rows: std.ArrayList([]const u8) = .empty;
        var map: std.ArrayList(usize) = .empty;
        for (branches.items, 0..) |branch, i| {
            if (branch.remote) continue;
            if (rows.items.len == max_picker_rows) break;
            const name = command.display(aa, branch.name, 512) catch return self.failure(error.OutOfMemory);
            const checked = worktree.checkedOutPath(list.items, branch.ref) != null;
            const row = std.fmt.allocPrint(aa, "{s} {s}  {s}{s}", .{ if (branch.current) "*" else " ", name, branch.oid[0..@min(branch.oid.len, 12)], if (checked) "  [checked out]" else "" }) catch return self.failure(error.OutOfMemory);
            rows.append(aa, row) catch return self.failure(error.OutOfMemory);
            map.append(aa, i) catch return self.failure(error.OutOfMemory);
        }
        self.picker = map.toOwnedSlice(aa) catch return self.failure(error.OutOfMemory);
        const path = command.display(a, self.add_path orelse "", 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(path);
        const body = std.fmt.allocPrint(aa, "New worktree at: {s}\nSelect an existing local branch to check out, OR type a new branch name (created at HEAD). A branch already checked out in any worktree cannot be reused.", .{path}) catch return self.failure(error.OutOfMemory);
        if (rows.items.len == 0) {
            self.flow = .none;
            self.message("No local branches exist. Create the first commit before adding worktrees.");
            return;
        }
        self.dialog("Add worktree — branch", body, rows.items, true, "Continue");
    }
    fn showAddConfirm(self: *Controller) void {
        const path = command.display(a, self.add_path orelse return self.failure(error.NoSelection), 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(path);
        const name = command.display(a, self.add_name orelse return self.failure(error.NoSelection), 512) catch return self.failure(error.OutOfMemory);
        defer a.free(name);
        const body = u.fmt("Create worktree at '{s}' on branch '{s}' ({s}).\nCommand: git {s}\nGit checks out files into the new directory and refuses existing non-empty paths; an existing empty directory may be used without data loss. A branch already checked out elsewhere is refused.\n\nThis is a repository write using your Git configuration and identity, separate from the read-only Source Control approval. Configured hooks (for example post-checkout) can execute programs with your user permissions; this is NOT a sandbox.", .{
            path,
            name,
            if (self.add_new) "new branch at HEAD" else "existing branch",
            if (self.add_new) "worktree add -b <name> -- <path>" else "worktree add -- <path> <name>",
        });
        defer a.free(body);
        self.dialog("Confirm worktree creation", body, &.{}, false, "Create worktree");
    }
    fn showRemoveConfirm(self: *Controller) void {
        self.flow = .remove_confirm;
        const path = command.display(a, self.remove_path orelse return self.failure(error.NoSelection), 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(path);
        const body = u.fmt("Remove worktree '{s}'.\nCommand: git worktree remove -- {s}\nVerified clean just now (0 changed/untracked paths); external changes can still race and Git refuses dirty removal. No --force is ever used. Git deletes that directory's files and frees its branch for other worktrees.\n\nThis is a repository write using your Git configuration and identity. Configured hooks can execute programs with your user permissions; this is NOT a sandbox.", .{ path, path });
        defer a.free(body);
        self.dialog("Confirm clean worktree removal", body, &.{}, false, "Remove clean worktree");
    }

    /// Test-only bridge. Values are zero-based picker indices or `text:…` for
    /// input dialogs; approval answers the actual visible native dialog and
    /// never grants trust or bypasses the Source Control disclosure.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!@import("build_options").test_hooks) return false;
        if (std.mem.eql(u8, action, "worktree-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "worktree-show")) {
            if (std.mem.eql(u8, value, "worktrees")) self.showWorktrees() else if (std.mem.eql(u8, value, "add")) self.showAddWorktree() else if (std.mem.eql(u8, value, "remove")) self.showRemoveWorktree();
        } else if (std.mem.eql(u8, action, "worktree-accept")) {
            self.ui.answer(true, null, "");
        } else if (std.mem.eql(u8, action, "worktree-reject")) {
            self.ui.answer(false, null, "");
        } else if (std.mem.eql(u8, action, "worktree-answer")) {
            if (std.mem.startsWith(u8, value, "text:")) {
                self.ui.answer(true, null, value["text:".len..]);
            } else if (value.len == 0) {
                self.ui.answer(true, null, "");
            } else {
                self.ui.answer(true, std.fmt.parseInt(usize, value, 10) catch return true, "");
            }
        } else if (std.mem.eql(u8, action, "worktree-open-mode")) {
            if (std.mem.eql(u8, value, "callback")) {
                self.open_callback = &recordOpen;
                self.open_context = self;
            } else {
                self.open_callback = null;
                self.open_context = null;
            }
        } else if (std.mem.eql(u8, action, "worktree-close")) {
            self.invalidate();
        } else return false;
        return true;
    }
    fn recordOpen(context: *anyopaque, _: *App, _: []const u8) void {
        const self = u.cast(Controller, context);
        self.open_mode = .callback;
    }
    pub fn probe(self: *Controller) void {
        if (!@import("build_options").test_hooks) return;
        const WorktreeProbe = struct { path: []const u8, head: ?[]const u8, branch: ?[]const u8, detached: bool, bare: bool, locked: bool, prunable: bool, main: bool, unborn: bool };
        var rows: [probe_rows]WorktreeProbe = undefined;
        const items: []const worktree.Worktree = if (self.worktrees) |list| list.items else &.{};
        const len = @min(items.len, probe_rows);
        for (items[0..len], 0..) |item, i| rows[i] = .{ .path = item.path, .head = item.head, .branch = item.branch, .detached = item.detached, .bare = item.bare, .locked = item.locked, .prunable = item.prunable, .main = item.main, .unborn = item.unborn() };
        const TargetProbe = struct { root: u64, owner: []const u8, path: []const u8, gitdir: []const u8, commondir: []const u8 };
        const target: ?TargetProbe = if (self.target) |t| .{ .root = @backingInt(t.root), .owner = t.owner, .path = t.path, .gitdir = t.gitdir, .commondir = t.commondir } else null;
        // JSON serializes raw paths as data, never as a shell command or GTK markup.
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .dialog = self.ui.window != null,
            .flow = @tagName(self.flow),
            .phase = if (self.job != null) @as(?[]const u8, @tagName(self.phase)) else null,
            .busy = self.busy(),
            .pending = @tagName(self.pending),
            .generation = self.generation,
            .launches = self.launches,
            .discarded = self.discarded,
            .writes = self.writes,
            .barrier = self.barrier,
            .write_attempted = self.write_attempted,
            .write_action = @tagName(self.write_action),
            .discarded_writes = self.discarded_writes,
            .target = target,
            .worktree_count = items.len,
            .worktrees = rows[0..len],
            .picker_rows = self.picker.len,
            .add_path = self.add_path,
            .add_name = self.add_name,
            .add_new = self.add_new,
            .remove_path = self.remove_path,
            .dirty = self.dirty,
            .action = @tagName(self.action),
            .recall = self.recall != null,
            .recaptured = self.target != null and !self.app.git.valid(),
            .opened_path = self.opened_path,
            .open_mode = @tagName(self.open_mode),
            .open_callback = self.open_callback != null,
            .@"error" = self.error_name,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_WORKTREE %s\n", line.ptr);
    }
};
