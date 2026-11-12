//! Native branch/tag workflows on the selected Source Control repository.
//! Parent owns commands and lifecycle invalidation; this module is not wired
//! into App by itself. Every command requires the existing Source Control
//! disclosure/trust (app.git.valid()); repository writes additionally consume a
//! separate per-operation native confirmation here, because the read-only
//! inspection approval does not cover checkout or ref writes.
//!
//! Writes use env.zig's write prefix/environment: the user's Git configuration
//! and identity apply, and configured hooks (reference-transaction,
//! post-checkout, …) can execute programs with the user's permissions. This is
//! NOT a sandbox. No force checkout, no silent discard, no network commands.
//! Dirty worktrees block switch/delete with an explicit stash/cancel choice;
//! stash itself is a separate increment and is never executed here.
//!
//! Churn recapture: a repository write inside the monitored workspace root can
//! trip the parent's structural watch, which retires Source Control approval
//! and invalidates this controller. The last target captured while Source
//! Control was fully approved is retained; later commands may recapture that
//! SAME repository only while machine trust re-validates live (issue/validate
//! of a .git permit) and the current workspace model still owns it. This never
//! grants a first approval, never bypasses a revocation, and every write still
//! consumes its own native confirmation.
//!
//! Worktree-changing writes (switch) and branch deletion hold the manager
//! file-operation barrier until the job is reaped, matching stash/conflict:
//! manager-wide save/load/modal admission plus protection of open documents,
//! nested roots and manifests across peer windows. A discarded write result
//! (cancellation/invalidation after launch) is never silent: it surfaces a
//! partial-state warning and refreshes Source Control when still valid.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const refs = @import("refs.zig");
const env = @import("env.zig");
const UI = @import("../language/ui.zig").UI;
const RootId = @import("../workspace/model.zig").RootId;
const identity = @import("../workspace/identity.zig");

pub const capture_bytes = 1024 * 1024;
pub const small_capture_bytes = 16 * 1024;
pub const max_picker_rows = 512;
pub const probe_rows = 128;

const Phase = enum { status, branches, tags, merged, write };
const Intent = enum { none, status, branches, tags, merged, write };
const Flow = enum {
    none,
    switch_pick,
    delete_pick,
    tags_pick,
    create_branch_name,
    create_branch_confirm,
    create_tag_name,
    create_tag_confirm,
    switch_check,
    switch_confirm,
    delete_check,
    delete_confirm,
    delete_force,
    dirty_choice,
};
const Action = enum { none, switch_branch, create_branch, delete_branch, delete_branch_force, create_tag };

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
    phase: Phase = .branches,
    pending: Intent = .none,
    flow: Flow = .none,
    action: Action = .none,
    ui: UI,
    target: ?Target = null,
    recall: ?Recall = null,
    branches: ?refs.Branches = null,
    tags: ?refs.Tags = null,
    snapshot: ?status.Snapshot = null,
    picker: []const usize = &.{},
    selection: ?[]const u8 = null,
    selection_ref: ?[]const u8 = null,
    merged: bool = false,
    dirty: usize = 0,
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
        return .{ .app = app, .arena = std.heap.ArenaAllocator.init(a), .ui = .{ .context = app, .respond = &answered }, .message_text = u.z("Branches and tags — Source Control approval required") };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.supervisor.isIdle() and !self.barrier);
        self.invalidate();
        self.supervisor.shutdown();
        self.freeRecall();
        self.arena.deinit();
        a.free(self.message_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.ui.close();
        self.clearModel();
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.pending != .none;
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Refs generation exhausted");
        self.pending = .none;
        self.flow = .none;
        self.action = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearModel(self: *Controller) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
        if (self.branches) |*branches| branches.deinit();
        self.branches = null;
        if (self.tags) |*tags| tags.deinit();
        self.tags = null;
        self.target = null;
        self.picker = &.{};
        self.selection = null;
        self.selection_ref = null;
        self.merged = false;
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
        const text = u.fmt("Branches/tags: {s}. Nothing was changed.", .{@errorName(err)});
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
    /// churn invalidation, a previously approved repository may be recaptured
    /// only while live machine trust and the current workspace model confirm it.
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
    fn startFlow(self: *Controller, flow: Flow, intent: Intent) void {
        if (!self.gate()) return;
        self.cancel();
        self.clearModel();
        self.error_name = null;
        self.captureTarget() catch |err| return self.failure(err);
        self.flow = flow;
        self.pending = intent;
        self.drain();
    }

    pub fn showBranches(self: *Controller) void {
        self.startFlow(.switch_pick, .status);
    }
    pub fn showSwitchBranch(self: *Controller) void {
        self.startFlow(.switch_pick, .status);
    }
    pub fn showDeleteBranch(self: *Controller) void {
        self.startFlow(.delete_pick, .status);
    }
    pub fn showTags(self: *Controller) void {
        self.startFlow(.tags_pick, .tags);
    }
    pub fn showCreateBranch(self: *Controller) void {
        if (!self.gate()) return;
        self.cancel();
        self.clearModel();
        self.error_name = null;
        self.captureTarget() catch |err| return self.failure(err);
        self.flow = .create_branch_name;
        self.showNameInput("Create branch — name", "New branch name (created at current HEAD; no checkout). Git ref-name rules apply; the name is passed as a literal argument, never through a shell.");
    }
    pub fn showCreateTag(self: *Controller) void {
        if (!self.gate()) return;
        self.cancel();
        self.clearModel();
        self.error_name = null;
        self.captureTarget() catch |err| return self.failure(err);
        self.flow = .create_tag_name;
        self.showNameInput("Create lightweight tag — name", "New lightweight tag name (created at current HEAD; no message, annotation or signing). Git ref-name rules apply; the name is passed as a literal argument, never through a shell.");
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
            .status => self.launch(.status, target.path, command.status_args, capture_bytes, false) catch |err| self.failure(err),
            .branches => self.launch(.branches, target.path, &.{ "for-each-ref", "--format=" ++ refs.branch_format, "refs/heads", "refs/remotes" }, capture_bytes, false) catch |err| self.failure(err),
            .tags => self.launch(.tags, target.path, &.{ "for-each-ref", "--format=" ++ refs.tag_format, "refs/tags" }, capture_bytes, false) catch |err| self.failure(err),
            .merged => self.launch(.merged, target.path, &.{ "merge-base", "--is-ancestor", self.selection_ref orelse return self.failure(error.NoSelection), "HEAD" }, small_capture_bytes, false) catch |err| self.failure(err),
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
                .identity = .{ .scope = "git-refs", .request = self.launches + 1, .generation = self.generation, .workspace = token },
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
                .identity = .{ .scope = "git-refs", .request = self.launches + 1, .generation = self.generation, .workspace = token },
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
        const name = self.selection orelse return error.NoSelection;
        const args: []const []const u8 = switch (self.action) {
            .switch_branch => &.{ "switch", "--", name },
            .create_branch => &.{ "branch", "--", name },
            .delete_branch => &.{ "branch", "-d", "--", name },
            .delete_branch_force => &.{ "branch", "-D", "--", name },
            .create_tag => &.{ "tag", "--", name },
            .none => return error.NoAction,
        };
        switch (self.action) {
            // Switch rewrites worktree files; deletion is ref-only but barriers
            // the repository for safety. The barrier source is the index path
            // (stash pattern): a repo.path source would make checkFileOperation
            // refuse RootMutation whenever a workspace root IS the repository,
            // because it treats the source as a rename/deletion scope. The
            // explicit tree guard below supplies the affected-tree protection
            // for open documents, nested roots and manifests instead.
            .switch_branch, .delete_branch, .delete_branch_force => {
                try self.guardTree(target.path);
                const index_path = u.fmt("{s}/index", .{target.gitdir});
                defer a.free(index_path);
                try self.acquireBarrier(index_path, "");
            },
            // Ref-only creation at HEAD: no worktree or index bytes change.
            .create_branch, .create_tag => {},
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
    /// Affected-tree protection across every window: an open document bound
    /// under the tree refuses the write (clean documents are bound too), a
    /// nested workspace root or the manifest inside the tree refuses it. The
    /// tree root itself survives a content-only switch/delete, so equality is
    /// allowed; manager-wide admission is enforced by the barrier itself.
    fn guardTree(self: *Controller, tree: []const u8) !void {
        const manager = self.app.manager orelse return error.NoManager;
        for (manager.entries) |entry| {
            const window = entry orelse continue;
            const app = window.app;
            for (app.snapshotDocuments()) |doc| {
                if (doc.path) |path| if (command.contains(tree, path)) return error.OpenDocument;
            }
            if (app.browser.model) |snapshot| {
                for (snapshot.roots) |root| {
                    if (!std.mem.eql(u8, root.lexical_path, tree) and command.contains(tree, root.lexical_path)) return error.RootMutation;
                    if (root.canonical_path) |canonical| {
                        if (!std.mem.eql(u8, canonical, tree) and command.contains(tree, canonical)) return error.RootMutation;
                    }
                }
                if (snapshot.manifest_path) |manifest| if (command.contains(tree, manifest)) return error.ProtectedManifest;
            }
            if (app.browser.manifest_canonical) |manifest| if (command.contains(tree, manifest)) return error.ProtectedManifest;
        }
    }
    /// A write whose result is discarded after cancellation/invalidation may
    /// have published partial or complete changes; Git is not rolled back.
    fn discardedWrite(self: *Controller) void {
        if (self.phase != .write) return;
        self.discarded_writes += 1;
        const text = u.fmt("An interrupted Git write ({s}) was discarded after invalidation. It may have left partial changes; nothing was rolled back. Verify the repository before retrying.", .{@tagName(self.write_action)});
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
            // Fail closed at delivery if trust, workspace or the selected
            // repository changed while the job ran.
            self.invalidate();
            self.discardedWrite();
            return;
        }
        self.receive(result) catch |err| self.failure(err);
    }
    fn receive(self: *Controller, result: process.Result) !void {
        switch (self.phase) {
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
                switch (self.flow) {
                    .switch_pick, .delete_pick => {
                        self.pending = .branches;
                        self.drain();
                    },
                    .create_branch_confirm => self.showCreateConfirm(false),
                    .create_tag_confirm => self.showCreateConfirm(true),
                    .switch_check => {
                        if (self.dirty != 0) self.showDirtyChoice("Switching branches") else self.showSwitchConfirm();
                    },
                    .delete_check => {
                        if (self.dirty != 0) {
                            self.showDirtyChoice("Deleting a branch");
                        } else {
                            self.pending = .merged;
                            self.drain();
                        }
                    },
                    else => return error.InvalidFlow,
                }
            },
            .branches => {
                if (result.outcome != .success) return self.gitFailure(result);
                const parsed = try refs.parseBranches(a, result.stdout);
                if (self.branches) |*branches| branches.deinit();
                self.branches = parsed;
                self.showBranchPicker();
            },
            .tags => {
                if (result.outcome != .success) return self.gitFailure(result);
                const parsed = try refs.parseTags(a, result.stdout);
                if (self.tags) |*tags| tags.deinit();
                self.tags = parsed;
                self.showTagPicker();
            },
            .merged => {
                if (result.outcome == .success) {
                    self.merged = true;
                } else if (result.outcome == .nonzero and result.exit_code == 1) {
                    self.merged = false;
                } else return self.gitFailure(result);
                if (self.merged) self.showDeleteConfirm() else self.showDeleteForce();
            },
            .write => {
                // A delivered write result (success or refusal) is a known
                // outcome; only discarded results leave uncertainty.
                self.write_attempted = false;
                if (result.outcome != .success) return self.gitFailure(result);
                const name = self.selection orelse "";
                const text: []const u8 = switch (self.action) {
                    .switch_branch => "Switched worktree to the selected branch. No force was used.",
                    .create_branch => "Created branch at HEAD. No checkout occurred.",
                    .delete_branch => "Deleted merged branch.",
                    .delete_branch_force => "Force-deleted unmerged branch after separate confirmation.",
                    .create_tag => "Created lightweight tag at HEAD.",
                    .none => "Git write completed.",
                };
                const done = u.fmt("{s} ({s})", .{ text, name });
                defer a.free(done);
                self.message(done);
                // Ref listings captured before the write are stale.
                if (self.branches) |*branches| branches.deinit();
                self.branches = null;
                if (self.tags) |*tags| tags.deinit();
                self.tags = null;
                const switched = self.action == .switch_branch;
                self.flow = .none;
                self.action = .none;
                // A switch changes worktree files: the parent Source Control
                // status/diff must not keep looking current. Only refresh a
                // still-valid parent; churn may have retired its approval.
                if (switched and self.app.git.valid()) self.app.git.refresh();
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
            .switch_pick => self.branchPicked(index, false),
            .delete_pick => self.branchPicked(index, true),
            .tags_pick => self.flow = .none,
            .create_branch_name => self.namePicked(text, .create_branch_confirm),
            .create_tag_name => self.namePicked(text, .create_tag_confirm),
            .create_branch_confirm => self.confirmWrite(.create_branch),
            .create_tag_confirm => self.confirmWrite(.create_tag),
            .switch_confirm => self.confirmWrite(.switch_branch),
            .delete_confirm => self.confirmWrite(.delete_branch),
            .delete_force => {
                const name = self.selection orelse return self.failure(error.NoSelection);
                if (!std.mem.eql(u8, text, name)) {
                    self.message("Force confirmation text did not match the branch name. Nothing was deleted.");
                    self.showDeleteForce();
                    return;
                }
                self.confirmWrite(.delete_branch_force);
            },
            .dirty_choice => {
                self.flow = .none;
                self.message("Stash is not part of this increment. Use the Git stash command (for example `git stash push`) in a terminal, then retry. Nothing was discarded or changed.");
            },
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
    fn branchPicked(self: *Controller, index: ?usize, delete: bool) void {
        const branches = self.branches orelse return self.failure(error.NoListing);
        const picked = index orelse return self.failure(error.NoSelection);
        if (picked >= self.picker.len) return self.failure(error.NoSelection);
        const branch = branches.items[self.picker[picked]];
        if (delete and branch.remote) return self.failure(error.InvalidSelection);
        if (!delete and branch.remote) {
            self.flow = .none;
            self.message("Remote-tracking branches cannot be switched to directly. Create a local branch instead.");
            return;
        }
        if (branch.current) {
            self.flow = .none;
            const text = u.fmt("Already on branch {s}. Nothing to do.", .{branch.name});
            defer a.free(text);
            self.message(text);
            return;
        }
        const aa = self.arena.allocator();
        self.selection = aa.dupe(u8, branch.name) catch return self.failure(error.OutOfMemory);
        self.selection_ref = aa.dupe(u8, branch.ref) catch return self.failure(error.OutOfMemory);
        self.flow = if (delete) .delete_check else .switch_check;
        self.pending = .status;
        self.drain();
    }
    fn namePicked(self: *Controller, text: []const u8, next: Flow) void {
        if (!refs.validName(text)) {
            self.message("Invalid name. Use Git ref-name rules: no spaces, controls, ~ ^ : ? * [ \\, no '..', '@{', leading '-'/'.'/'/', trailing '/'/'.' or '.lock' components.");
            self.showNameInput(if (next == .create_branch_confirm) "Create branch — name" else "Create lightweight tag — name", "Enter a valid name. It is passed to Git as a literal argument, never through a shell.");
            return;
        }
        const aa = self.arena.allocator();
        self.selection = aa.dupe(u8, text) catch return self.failure(error.OutOfMemory);
        self.flow = next;
        self.pending = .status;
        self.drain();
    }
    fn showNameInput(self: *Controller, title: [:0]const u8, body: []const u8) void {
        self.dialog(title, body, &.{}, true, "Continue");
    }
    fn headText(self: *Controller) [:0]u8 {
        const snapshot = self.snapshot orelse return u.z("HEAD unknown");
        switch (refs.headState(snapshot.head, snapshot.branch)) {
            .unborn => return u.z("unborn HEAD (no commits yet)"),
            .detached => {
                const oid = snapshot.head orelse "unknown";
                return u.fmt("detached HEAD at {s}", .{oid[0..@min(oid.len, 12)]});
            },
            .branch => {
                const name = command.display(a, snapshot.branch orelse "unknown", 512) catch return u.z("HEAD unknown");
                defer a.free(name);
                const oid = snapshot.head orelse "unknown";
                return u.fmt("branch {s} at {s}", .{ name, oid[0..@min(oid.len, 12)] });
            },
            .unknown => return u.z("HEAD unknown"),
        }
    }
    fn showBranchPicker(self: *Controller) void {
        const branches = self.branches orelse return self.failure(error.NoListing);
        const delete = self.flow == .delete_pick;
        const aa = self.arena.allocator();
        var rows: std.ArrayList([]const u8) = .empty;
        var map: std.ArrayList(usize) = .empty;
        for (branches.items, 0..) |branch, i| {
            if (delete and branch.remote) continue;
            if (rows.items.len == max_picker_rows) break;
            const name = command.display(aa, branch.name, 512) catch return self.failure(error.OutOfMemory);
            const upstream = if (branch.upstream) |ref| refs.shortName(ref) orelse ref else null;
            const track: []const u8 = if (branch.track.gone) " [gone]" else if (branch.track.ahead != 0 or branch.track.behind != 0) blk: {
                break :blk std.fmt.allocPrint(aa, " [ahead {d}, behind {d}]", .{ branch.track.ahead, branch.track.behind }) catch return self.failure(error.OutOfMemory);
            } else "";
            const row = std.fmt.allocPrint(aa, "{s} {s}  {s}{s}{s}{s}", .{
                if (branch.current) "*" else " ",
                name,
                branch.oid[0..@min(branch.oid.len, 12)],
                if (upstream) |up| std.fmt.allocPrint(aa, "  upstream {s}", .{up}) catch return self.failure(error.OutOfMemory) else "",
                track,
                if (branch.remote) "  [remote]" else "",
            }) catch return self.failure(error.OutOfMemory);
            rows.append(aa, row) catch return self.failure(error.OutOfMemory);
            map.append(aa, i) catch return self.failure(error.OutOfMemory);
        }
        self.picker = map.toOwnedSlice(aa) catch return self.failure(error.OutOfMemory);
        const head = self.headText();
        defer a.free(head);
        const path = command.display(a, self.target.?.path, 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(path);
        const shown = if (branches.items.len > rows.items.len) std.fmt.allocPrint(aa, " Showing first {d} of {d}; type to filter.", .{ rows.items.len, branches.items.len }) catch return self.failure(error.OutOfMemory) else "";
        const body = std.fmt.allocPrint(aa, "Repository: {s}\nHEAD: {s}\n{s}{s}", .{
            path,
            head,
            if (delete) "Select a local branch to delete. The current branch cannot be deleted. Unmerged branches require a separate force confirmation." else "Select a branch. Local branches can be switched to; remote-tracking rows are informational. Dirty worktrees block switching.",
            shown,
        }) catch return self.failure(error.OutOfMemory);
        if (rows.items.len == 0) {
            self.dialog(if (delete) "Delete branch — none" else "Branches — none", "No matching branches exist (unborn HEAD has none). Nothing to do.", &.{}, false, null);
            return;
        }
        self.dialog(if (delete) "Delete branch…" else "Branches — local, remote and upstream", body, rows.items, false, if (delete) "Delete selected branch…" else "Switch to selected branch…");
    }
    fn showTagPicker(self: *Controller) void {
        const tags = self.tags orelse return self.failure(error.NoListing);
        const aa = self.arena.allocator();
        var rows: std.ArrayList([]const u8) = .empty;
        for (tags.items) |tag| {
            if (rows.items.len == max_picker_rows) break;
            const name = command.display(aa, tag.name, 512) catch return self.failure(error.OutOfMemory);
            const row = std.fmt.allocPrint(aa, "{s}  {s}  {s}", .{ name, tag.oid[0..@min(tag.oid.len, 12)], if (tag.lightweight) "[lightweight]" else "[annotated]" }) catch return self.failure(error.OutOfMemory);
            rows.append(aa, row) catch return self.failure(error.OutOfMemory);
        }
        const path = command.display(a, self.target.?.path, 1024) catch return self.failure(error.OutOfMemory);
        defer a.free(path);
        const body = std.fmt.allocPrint(aa, "Repository: {s}\nTags are listed read-only. Create lightweight tags with the Create tag command; annotated tags, signing and tag deletion are not part of this increment.", .{path}) catch return self.failure(error.OutOfMemory);
        if (rows.items.len == 0) {
            self.dialog("Tags — none", "No tags exist in this repository.", &.{}, false, null);
            return;
        }
        self.dialog("Tags", body, rows.items, false, null);
    }
    fn showCreateConfirm(self: *Controller, tag: bool) void {
        const snapshot = self.snapshot orelse return self.failure(error.NoStatus);
        if (refs.headState(snapshot.head, snapshot.branch) == .unborn) {
            self.flow = .none;
            self.message("Unborn HEAD: no commit exists yet. Create the first commit before creating branches or tags.");
            return;
        }
        const name = command.display(a, self.selection orelse return self.failure(error.NoSelection), 512) catch return self.failure(error.OutOfMemory);
        defer a.free(name);
        const head = self.headText();
        defer a.free(head);
        const body = u.fmt("{s} '{s}' at current HEAD ({s}).\nCommand: git {s} -- {s}\nNo checkout; worktree files are unchanged.\n\nThis is a repository write using your Git configuration and identity, separate from the read-only Source Control approval. Configured hooks (for example reference-transaction) can execute programs with your user permissions; this is NOT a sandbox. Cancel keeps everything unchanged.", .{
            if (tag) "Create lightweight tag" else "Create branch",
            name,
            head,
            if (tag) "tag" else "branch",
            name,
        });
        defer a.free(body);
        self.dialog(if (tag) "Confirm lightweight tag creation" else "Confirm branch creation", body, &.{}, false, if (tag) "Create lightweight tag" else "Create branch");
    }
    fn showSwitchConfirm(self: *Controller) void {
        self.flow = .switch_confirm;
        const name = command.display(a, self.selection orelse return self.failure(error.NoSelection), 512) catch return self.failure(error.OutOfMemory);
        defer a.free(name);
        const head = self.headText();
        defer a.free(head);
        const body = u.fmt("Switch worktree to branch '{s}' (currently {s}).\nCommand: git switch -- {s}\nChecked-out files are updated to that branch. The worktree was just verified clean; external changes can still race, and Git refuses to overwrite local modifications. No --force or --discard-changes is ever used.\n\nThis is a repository write using your Git configuration and identity, separate from the read-only Source Control approval. Configured hooks (for example post-checkout) can execute programs with your user permissions; this is NOT a sandbox.", .{ name, head, name });
        defer a.free(body);
        self.dialog("Confirm branch switch — no force", body, &.{}, false, "Switch branch");
    }
    fn showDeleteConfirm(self: *Controller) void {
        self.flow = .delete_confirm;
        const name = command.display(a, self.selection orelse return self.failure(error.NoSelection), 512) catch return self.failure(error.OutOfMemory);
        defer a.free(name);
        const body = u.fmt("Delete branch '{s}' (verified merged into current HEAD).\nCommand: git branch -d -- {s}\nSafe delete: Git still refuses if the branch is not fully merged. No worktree files change.\n\nThis is a repository write using your Git configuration and identity. Configured hooks (for example reference-transaction) can execute programs with your user permissions; this is NOT a sandbox.", .{ name, name });
        defer a.free(body);
        self.dialog("Confirm branch deletion", body, &.{}, false, "Delete branch");
    }
    fn showDeleteForce(self: *Controller) void {
        self.flow = .delete_force;
        const name = command.display(a, self.selection orelse return self.failure(error.NoSelection), 512) catch return self.failure(error.OutOfMemory);
        defer a.free(name);
        const head = self.headText();
        defer a.free(head);
        const body = u.fmt("SEPARATE FORCE CONFIRMATION.\nBranch '{s}' is NOT merged into {s}. Force deletion permanently loses its unique commits; they may become unreachable.\nCommand: git branch -D -- {s}\nThe safe-delete approval does not cover this. Type the exact branch name below to confirm force deletion; anything else cancels.", .{ name, head, name });
        defer a.free(body);
        self.dialog("Force delete UNMERGED branch — separate confirmation", body, &.{}, true, "Force delete unmerged branch");
    }
    fn showDirtyChoice(self: *Controller, operation: []const u8) void {
        self.flow = .dirty_choice;
        const body = u.fmt("{s} is blocked: the worktree has {d} changed/untracked paths (fresh status). Proceeding could lose work. Coral never discards, forces or silently stashes.\n\nCancel, or stash your changes first with the Git stash command. Stash workflows are a separate increment and are NOT executed by this dialog. No files, refs or index entries were changed.", .{ operation, self.dirty });
        defer a.free(body);
        self.dialog("Dirty worktree — explicit choice required", body, &.{}, false, "Use stash command");
    }

    /// Test-only bridge. Values are zero-based picker indices or `text:…` for
    /// input dialogs; approval answers the actual visible native dialog and
    /// never grants trust or bypasses the Source Control disclosure.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!@import("build_options").test_hooks) return false;
        if (std.mem.eql(u8, action, "refs-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "refs-show")) {
            if (std.mem.eql(u8, value, "branches")) self.showBranches() else if (std.mem.eql(u8, value, "switch-branch")) self.showSwitchBranch() else if (std.mem.eql(u8, value, "delete-branch")) self.showDeleteBranch() else if (std.mem.eql(u8, value, "tags")) self.showTags() else if (std.mem.eql(u8, value, "create-branch")) self.showCreateBranch() else if (std.mem.eql(u8, value, "create-tag")) self.showCreateTag();
        } else if (std.mem.eql(u8, action, "refs-accept")) {
            self.ui.answer(true, null, "");
        } else if (std.mem.eql(u8, action, "refs-reject")) {
            self.ui.answer(false, null, "");
        } else if (std.mem.eql(u8, action, "refs-answer")) {
            if (std.mem.startsWith(u8, value, "text:")) {
                self.ui.answer(true, null, value["text:".len..]);
            } else if (value.len == 0) {
                self.ui.answer(true, null, "");
            } else {
                self.ui.answer(true, std.fmt.parseInt(usize, value, 10) catch return true, "");
            }
        } else if (std.mem.eql(u8, action, "refs-close")) {
            self.invalidate();
        } else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!@import("build_options").test_hooks) return;
        const BranchProbe = struct { name: []const u8, ref: []const u8, oid: []const u8, upstream: ?[]const u8, ahead: usize, behind: usize, gone: bool, current: bool, remote: bool };
        var branch_rows: [probe_rows]BranchProbe = undefined;
        const branches: []const refs.Branch = if (self.branches) |listing| listing.items else &.{};
        const branch_len = @min(branches.len, probe_rows);
        for (branches[0..branch_len], 0..) |branch, i| branch_rows[i] = .{ .name = branch.name, .ref = branch.ref, .oid = branch.oid, .upstream = branch.upstream, .ahead = branch.track.ahead, .behind = branch.track.behind, .gone = branch.track.gone, .current = branch.current, .remote = branch.remote };
        const TagProbe = struct { name: []const u8, ref: []const u8, oid: []const u8, lightweight: bool };
        var tag_rows: [probe_rows]TagProbe = undefined;
        const tags: []const refs.Tag = if (self.tags) |listing| listing.items else &.{};
        const tag_len = @min(tags.len, probe_rows);
        for (tags[0..tag_len], 0..) |tag, i| tag_rows[i] = .{ .name = tag.name, .ref = tag.ref, .oid = tag.oid, .lightweight = tag.lightweight };
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
            .head = if (self.snapshot) |snapshot| snapshot.head else null,
            .branch = if (self.snapshot) |snapshot| snapshot.branch else null,
            .head_state = @tagName(refs.headState(if (self.snapshot) |snapshot| snapshot.head else null, if (self.snapshot) |snapshot| snapshot.branch else null)),
            .dirty = self.dirty,
            .branch_count = branches.len,
            .branches = branch_rows[0..branch_len],
            .tag_count = tags.len,
            .tags = tag_rows[0..tag_len],
            .picker_rows = self.picker.len,
            .selection = self.selection,
            .selection_ref = self.selection_ref,
            .merged = self.merged,
            .action = @tagName(self.action),
            .recall = self.recall != null,
            .recaptured = self.target != null and !self.app.git.valid(),
            .@"error" = self.error_name,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_REFS %s\n", line.ptr);
    }
};
