//! M4 native commit/uncommit workflows. Read-only preparation runs as supervised
//! tasks/process.zig jobs under the locked-down command.zig policy; the reviewed
//! write (commit -F - with message stdin, add -u, CAS update-ref HEAD) runs in a
//! GTask worker using env.zig's write prefix/environment, so configured hooks and
//! signing may execute after disclosure. Every operation requires the Source
//! Control disclosure (app.git.valid) and a full review via language/ui.zig.
//!
//! Default commit is staged-only. A separate explicit command stages tracked
//! changes (git add -u) and then reviews the resulting staged set before commit.
//! Uncommit is a soft-equivalent CAS update-ref preserving index and worktree; initial, merge
//! and published HEAD are refused. No network command, no shell, no hard reset.
//! The parent owns commands and lifecycle invalidation and wires this later.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const identity = @import("../workspace/identity.zig");
const model = @import("../workspace/model.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const commit = @import("commit.zig");
const conflict = @import("conflict.zig");
const env = @import("env.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const max_review_bytes = 256 * 1024;

const State = enum { idle, preparing, confirming, applying, succeeded, cancelled, failed };
const Kind = enum { commit, uncommit, stage_tracked };
const Phase = enum { status, operation, name_status, stat, parents, ancestor };
const Confirm = enum { commit, uncommit, stage };
const Apply = enum { stage, commit, uncommit };

const commit_disclosure =
    "This runs git commit -F - with your message on stdin (no shell, no -a, no --allow-empty). " ++
    "Only the staged index is committed; unstaged and untracked changes are preserved. " ++
    "Hooks (pre-commit, prepare-commit-msg, commit-msg, post-commit) and GPG/SSH signing may execute configured programs with your user permissions and may have side effects. This is NOT a sandbox. Git itself requests no network access.";
const uncommit_disclosure =
    "Hooks may execute configured programs with your user permissions; this is NOT a sandbox. No network access is requested. This is not a rollback of file contents: the index and worktree are kept exactly as they are.";
const stage_disclosure =
    "Clean filters may execute configured programs with your user permissions; this is NOT a sandbox. No network access is requested. Untracked files are never added.";

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    worker: ?*Worker = null,
    state: State = .idle,
    kind: Kind = .commit,
    phase: Phase = .status,
    confirm: Confirm = .commit,
    staged: bool = false,
    generation: u64 = 1,
    git_generation: u64 = 0,
    workspace: ?identity.Token = null,
    scope_token: ?identity.Token = null,
    request_token: ?identity.Token = null,
    root_id: model.RootId = undefined,
    repo_path: []const u8 = "",
    repo_owner: []const u8 = "",
    repo_gitdir: []const u8 = "",
    repo_commondir: []const u8 = "",
    index_path: []const u8 = "",
    snapshot: ?status.Snapshot = null,
    staged_files: []commit.StagedFile = &.{},
    staged_bytes: []const u8 = "",
    stat_summary: []const u8 = "",
    head_oid: []const u8 = "",
    parent_oid: []const u8 = "",
    published: ?bool = null,
    operation: conflict.Operation = .none,
    operation_index: usize = 0,
    operation_checks: []const conflict.Operation = &.{},
    review: UI,
    error_name: ?[]const u8 = null,
    committed: bool = false,
    status_text: [:0]u8,
    launches: u64 = 0,
    discarded: u64 = 0,
    jobs_started: u64 = 0,
    jobs_reaped: u64 = 0,
    delay_us: u64 = 0,

    pub fn init(app: *App) Controller {
        // Do not reach through App.git here: its parent may still be initializing.
        return .{ .app = app, .arena = std.heap.ArenaAllocator.init(a), .review = .{ .context = app, .respond = &answered }, .status_text = u.z("") };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job/worker is reaped.
        std.debug.assert(self.job == null and self.worker == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.clearSnapshot();
        self.arena.deinit();
        a.free(self.status_text);
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.worker != null;
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
    }
    fn cancel(self: *Controller) void {
        // Publish cancellation before touching GTK surfaces. A running worker keeps
        // its borrowed arena snapshots until it is reaped; only it can publish.
        self.generation +|= 1;
        if (self.job) |job| job.cancel();
        self.review.close();
        if (self.worker) |worker| {
            worker.cancel.store(true, .release);
            if (worker.outcome != .failed) worker.outcome = .cancelled;
            if (!worker.running) self.finishWorker();
        } else {
            self.clearPrepare();
            if (self.state != .idle) self.state = .cancelled;
        }
    }

    pub fn showCommit(self: *Controller) void {
        self.request(.commit);
    }
    pub fn showUncommit(self: *Controller) void {
        self.request(.uncommit);
    }
    pub fn showStageTrackedCommit(self: *Controller) void {
        self.request(.stage_tracked);
    }
    fn request(self: *Controller, kind: Kind) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            // Disclosure never queues a write nor approves a future review.
            self.app.git.show();
            return;
        }
        if (self.busy() or self.review.window != null) {
            self.app.message("A commit/uncommit review is already pending. Finish or cancel it before requesting another.");
            return;
        }
        self.begin(kind) catch |err| self.abort(err);
    }
    fn begin(self: *Controller, kind: Kind) !void {
        self.cancel();
        self.clearPrepare();
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const ar = self.arena.allocator();
        self.repo_path = try ar.dupe(u8, repository.path);
        self.repo_owner = try ar.dupe(u8, repository.owner);
        self.repo_gitdir = try ar.dupe(u8, repository.gitdir);
        self.repo_commondir = try ar.dupe(u8, repository.commondir);
        self.root_id = repository.root;
        self.index_path = try std.fmt.allocPrint(ar, "{s}/index", .{repository.gitdir});
        self.git_generation = self.app.git.generation;
        self.workspace = self.app.workspace.capture() orelse return error.WorkspaceChanged;
        const snapshot = if (self.app.browser.model) |*m| m else return error.WorkspaceChanged;
        self.scope_token = snapshot.scope.capture() orelse return error.WorkspaceChanged;
        self.request_token = self.app.browser.requests.capture() orelse return error.WorkspaceChanged;
        self.kind = kind;
        self.staged = false;
        self.committed = false;
        self.error_name = null;
        try self.startPrepare();
    }
    fn startPrepare(self: *Controller) !void {
        self.clearSnapshot();
        self.staged_files = &.{};
        self.staged_bytes = "";
        self.stat_summary = "";
        self.head_oid = "";
        self.parent_oid = "";
        self.published = null;
        self.operation = .none;
        self.operation_index = 0;
        self.operation_checks = &.{};
        self.state = .preparing;
        self.setStatus("Preparing commit review — read-only Git inspection…");
        try self.launch(.status, commit.status_args, commit.max_capture);
    }

    fn launch(self: *Controller, phase: Phase, args: []const []const u8, limit: usize) !void {
        if (!self.admitReadOnly()) return error.Restricted;
        if (self.job != null or self.worker != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        if (command.prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..command.prefix.len], command.prefix);
        @memcpy(argv[command.prefix.len..][0..args.len], args);
        var environment: [command.environment.len]process.Environment = undefined;
        for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
        self.phase = phase;
        self.job = try process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "git-commit-read", .request = self.launches + 1, .generation = self.generation, .workspace = self.workspace },
            .argv = argv[0 .. command.prefix.len + args.len],
            .cwd = self.repo_path,
            .environment = &environment,
            .output_limit = limit,
            .timeout_ms = 15000,
        }, &completed, self);
        self.launches += 1;
        self.app.hold();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        defer self.app.release();
        defer job.destroy();
        std.debug.assert(self.job == job);
        self.job = null;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            return;
        }
        if (!self.admitReadOnly() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.invalidate();
            return;
        }
        self.receive(result) catch |err| self.abort(err);
    }
    fn receive(self: *Controller, result: process.Result) !void {
        if (result.outcome != .success) {
            // merge-base --is-ancestor exits 1 when HEAD is NOT an ancestor (unpublished).
            if (self.phase == .ancestor and result.outcome == .nonzero and result.exit_code == 1) {
                self.published = false;
                try self.showUncommitReview();
                return;
            }
            // rev-parse --verify --quiet exits 1 when the state ref is absent.
            if (self.phase == .operation and result.outcome == .nonzero and result.exit_code == 1) {
                self.operation_index += 1;
                try self.startOperationCheck();
                return;
            }
            self.error_name = "GitFailed";
            self.state = .failed;
            const text = u.fmt("Commit preparation ({s}) failed: {s} (exit {d}). No write was attempted.", .{ @tagName(self.phase), @tagName(result.outcome), result.exit_code orelse -1 });
            defer a.free(text);
            self.setStatus(text);
            if (!self.app.closing) self.app.message(text);
            return;
        }
        switch (self.phase) {
            .status => {
                const parsed = try status.parse(a, result.stdout);
                self.clearSnapshot();
                self.snapshot = parsed;
                const counts = commit.counts(&parsed);
                if (self.kind == .uncommit) {
                    if (parsed.head == null or std.mem.eql(u8, parsed.head.?, "(initial)")) return error.InitialCommit;
                    self.operation_checks = &commit.operation_order;
                    self.operation_index = 0;
                    self.operation = .none;
                    try self.startOperationCheck();
                } else if (self.kind == .stage_tracked and !self.staged) {
                    if (counts.unmerged != 0) return error.UnmergedConflict;
                    if (counts.unstaged == 0) return error.NothingToStage;
                    try self.showStageReview();
                } else {
                    if (counts.unmerged != 0) return error.UnmergedConflict;
                    self.operation_checks = &.{conflict.Operation.merge};
                    self.operation_index = 0;
                    self.operation = .none;
                    try self.startOperationCheck();
                }
            },
            .operation => {
                self.operation = self.operation_checks[self.operation_index];
                try self.operationDone();
            },
            .name_status => {
                const ar = self.arena.allocator();
                self.staged_bytes = try ar.dupe(u8, result.stdout);
                self.staged_files = try commit.parseNameStatus(ar, result.stdout);
                if (self.staged_files.len == 0) return error.EmptyStaged;
                try self.launch(.stat, commit.stat_args, commit.max_capture);
            },
            .stat => {
                self.stat_summary = try self.arena.allocator().dupe(u8, try commit.parseStatSummary(result.stdout));
                try self.showCommitReview();
            },
            .parents => {
                const snapshot = self.snapshot orelse return error.NoSnapshot;
                const parsed = try commit.parseParents(self.arena.allocator(), result.stdout);
                if (parsed.parents.len != 1) return error.InitialOrMergeCommit;
                if (snapshot.head == null or !std.mem.eql(u8, snapshot.head.?, parsed.head)) return error.StaleSnapshot;
                self.head_oid = parsed.head;
                self.parent_oid = parsed.parents[0];
                if (snapshot.upstream) |upstream| {
                    const args = commit.ancestorArgs(upstream);
                    try self.launch(.ancestor, &args, 1024);
                } else {
                    self.published = null;
                    try self.showUncommitReview();
                }
            },
            .ancestor => {
                // Exit 0: HEAD is an ancestor of upstream, i.e. already published.
                self.published = true;
                return error.PublishedHead;
            },
        }
    }

    fn startOperationCheck(self: *Controller) !void {
        if (self.operation_index >= self.operation_checks.len) {
            try self.operationDone();
            return;
        }
        var buf: [4][]const u8 = undefined;
        const args = commit.operationArgs(&buf, self.operation_checks[self.operation_index]);
        try self.launch(.operation, args, 1024);
    }
    fn operationDone(self: *Controller) !void {
        if (self.kind == .uncommit) {
            // Refuse uncommit while a merge/rebase/cherry-pick/revert is in progress.
            if (self.operation != .none) return error.OperationInProgress;
            try self.launch(.parents, commit.parents_args, 16384);
        } else {
            try self.launch(.name_status, commit.name_status_args, commit.max_capture);
        }
    }
    fn showCommitReview(self: *Controller) !void {
        const snapshot = self.snapshot orelse return error.NoSnapshot;
        const repo = try command.display(a, self.repo_path, 512);
        defer a.free(repo);
        const branch = try command.display(a, snapshot.branch orelse "(detached)", 256);
        defer a.free(branch);
        const head_raw = snapshot.head orelse "unknown";
        const head = try command.display(a, head_raw[0..@min(head_raw.len, 12)], 64);
        defer a.free(head);
        const upstream = try command.display(a, snapshot.upstream orelse "none", 256);
        defer a.free(upstream);
        const summary = try command.display(a, self.stat_summary, 1024);
        defer a.free(summary);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(a);
        for (self.staged_files) |file| {
            const label = try command.display(a, file.path, 1024);
            defer a.free(label);
            try list.appendSlice(a, &.{ file.status, ' ', ' ' });
            try list.appendSlice(a, label);
            try list.append(a, '\n');
            if (list.items.len > max_review_bytes) return error.ReviewTooLarge;
        }
        const counts = commit.counts(&snapshot);
        const merge_note: []const u8 = if (self.operation == .merge) "\nA merge is in progress (MERGE_HEAD present): this commit will create a merge commit.\n" else "";
        const body = u.fmt(
            "Commit staged changes — review\nRepository: {s}\nBranch: {s} · HEAD: {s} · upstream: {s}\n" ++
                "Staged files: {d} (exact list below). Retained unstaged tracked changes: {d} (NOT committed). Untracked files are never committed.{s}\n\n" ++
                "{s}\n\nStaged files:\n{s}\n{s}",
            .{ repo, branch, head, upstream, self.staged_files.len, counts.unstaged, merge_note, summary, list.items, commit_disclosure },
        );
        defer a.free(body);
        if (body.len > max_review_bytes) return error.ReviewTooLarge;
        self.confirm = .commit;
        self.state = .confirming;
        self.review.context = self;
        self.setStatus("Review the exact staged set, enter a message, then commit.");
        self.review.show(self.app, "Commit staged changes — review", body, &.{}, true, "Commit reviewed staged changes");
    }
    fn showUncommitReview(self: *Controller) !void {
        const snapshot = self.snapshot orelse return error.NoSnapshot;
        const repo = try command.display(a, self.repo_path, 512);
        defer a.free(repo);
        const branch = try command.display(a, snapshot.branch orelse "(detached)", 256);
        defer a.free(branch);
        const head = try command.display(a, self.head_oid, 128);
        defer a.free(head);
        const parent = try command.display(a, self.parent_oid[0..@min(self.parent_oid.len, 12)], 64);
        defer a.free(parent);
        const upstream = try command.display(a, snapshot.upstream orelse "none", 256);
        defer a.free(upstream);
        const published = if (self.published) |p| (if (p) "published" else "not published (HEAD is not an ancestor of upstream)") else "no upstream configured";
        const body = u.fmt(
            "Uncommit HEAD — soft reset review\nRepository: {s}\nBranch: {s} · HEAD: {s} · parent: {s}\nUpstream: {s} — {s}\n\n" ++
                "This runs a compare-and-swap update-ref of HEAD to the reviewed parent commit. It moves the current branch back one commit and KEEPS the index and worktree exactly as they are; the uncommitted changes remain staged. It NEVER hard-resets and no file bytes change. If HEAD changed since review, it refuses.\n\n" ++
                "Initial commits, merge commits and published HEAD are refused. {s}",
            .{ repo, branch, head, parent, upstream, published, uncommit_disclosure },
        );
        defer a.free(body);
        if (body.len > max_review_bytes) return error.ReviewTooLarge;
        self.confirm = .uncommit;
        self.state = .confirming;
        self.review.context = self;
        self.setStatus("Confirm the soft reset. Index and worktree are preserved.");
        self.review.show(self.app, "Uncommit HEAD — soft reset", body, &.{}, false, "Uncommit HEAD (keep index/worktree)");
    }
    fn showStageReview(self: *Controller) !void {
        const snapshot = self.snapshot orelse return error.NoSnapshot;
        const counts = commit.counts(&snapshot);
        const repo = try command.display(a, self.repo_path, 512);
        defer a.free(repo);
        const branch = try command.display(a, snapshot.branch orelse "(detached)", 256);
        defer a.free(branch);
        const body = u.fmt(
            "Stage tracked changes, then commit — staging review\nRepository: {s}\nBranch: {s}\n\n" ++
                "This runs git add -u: it stages ALL tracked modifications and deletions across the repository. Untracked files are NOT added. After staging, a separate commit review shows the exact staged set before any commit.\n\n" ++
                "Tracked unstaged changes to stage: {d}.\n\n{s}",
            .{ repo, branch, counts.unstaged, stage_disclosure },
        );
        defer a.free(body);
        if (body.len > max_review_bytes) return error.ReviewTooLarge;
        self.confirm = .stage;
        self.state = .confirming;
        self.review.context = self;
        self.setStatus("Confirm staging tracked changes; a commit review follows.");
        self.review.show(self.app, "Stage tracked changes (git add -u)", body, &.{}, false, "Stage tracked changes");
    }
    fn answered(context: *anyopaque, accepted: bool, _: ?usize, text: []const u8) void {
        const self = u.cast(Controller, context);
        if (self.state != .confirming) return;
        if (!accepted) {
            self.cancel();
            return;
        }
        switch (self.confirm) {
            .commit => {
                commit.validateMessage(text) catch |err| {
                    self.abort(err);
                    return;
                };
                self.startApply(.commit, text) catch |err| self.abort(err);
            },
            .uncommit => self.startApply(.uncommit, "") catch |err| self.abort(err),
            .stage => self.startApply(.stage, "") catch |err| self.abort(err),
        }
    }

    fn startApply(self: *Controller, phase: Apply, message: []const u8) !void {
        try self.admit();
        const ar = self.arena.allocator();
        // The disclosed write policy: env.zig write prefix + complete allowlist.
        const write_env = try env.write(ar);
        const environment = try ar.alloc(commit.Environment, write_env.len);
        for (write_env, 0..) |entry, i| environment[i] = .{ .name = entry.name, .value = entry.value };
        const expected_head: ?[]const u8 = if (self.kind == .uncommit) self.head_oid else blk: {
            const snapshot = self.snapshot orelse break :blk null;
            const head = snapshot.head orelse break :blk null;
            break :blk if (std.mem.eql(u8, head, "(initial)")) null else head;
        };
        const worker = try a.create(Worker);
        worker.* = .{
            .controller = self,
            .apply = phase,
            .root = self.repo_path,
            .gitdir = self.repo_gitdir,
            .message = if (message.len == 0) "" else try ar.dupe(u8, message),
            .expected_head = expected_head,
            .staged_bytes = self.staged_bytes,
            .parent_oid = self.parent_oid,
            .upstream = if (self.snapshot) |s| s.upstream else null,
            .environment = environment,
            .generation = self.git_generation,
            .workspace = self.workspace.?,
        };
        errdefer worker.destroy();
        try self.app.manager.?.beginFileOperation(self.app, self.index_path, "");
        worker.barrier = true;
        worker.attempted = true;
        self.worker = worker;
        self.app.hold();
        self.state = .applying;
        self.setStatus("Applying reviewed Git write…");
        self.dispatchWorker();
    }
    fn dispatchWorker(self: *Controller) void {
        const worker = self.worker.?;
        std.debug.assert(!worker.running);
        worker.running = true;
        worker.err = null;
        self.jobs_started += 1;
        if (hooks and self.delay_us != 0) {
            worker.delay_us = @min(self.delay_us, 2_000_000);
            self.delay_us = 0;
        }
        // No GCancellable: cancellation must not skip worker reaping or deliver an
        // early callback while the worker still owns the write transaction.
        const task = c.g_task_new(null, null, &workerDone, worker).?;
        c.g_task_set_task_data(task, worker, null);
        c.g_task_run_in_thread(task, &workerRun);
        c.g_object_unref(task);
    }
    fn finishWorker(self: *Controller) void {
        const worker = self.worker.?;
        std.debug.assert(!worker.running);
        if (worker.barrier) {
            self.app.manager.?.endFileOperation(self.app);
            worker.barrier = false;
        }
        self.review.close();
        self.state = worker.outcome;
        const attempted = worker.attempted;
        const continue_commit = attempted and worker.outcome == .succeeded and self.kind == .stage_tracked and !self.staged;
        self.worker = null;
        worker.destroy();
        self.app.release();
        if (continue_commit) {
            // Staging succeeded: re-prepare and review the exact staged set before commit.
            self.staged = true;
            self.committed = false;
            self.error_name = null;
            self.startPrepare() catch |err| self.abort(err);
            return;
        }
        self.clearPrepare();
        // A write attempt invalidates the Source Control snapshot, even on failure.
        if (attempted and self.app.git.valid()) self.app.git.refresh();
    }
    fn abort(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.generation +|= 1;
        if (self.job) |job| job.cancel();
        self.review.close();
        if (!self.app.closing) {
            const text = u.fmt("Commit operation refused: {s}. No write was published. Resolve the state and request a new review.", .{@errorName(err)});
            defer a.free(text);
            self.app.message(text);
            self.setStatus(text);
        }
        if (self.worker) |worker| {
            worker.outcome = .failed;
            worker.cancel.store(true, .release);
            if (!worker.running) self.finishWorker();
        } else {
            self.clearPrepare();
            self.state = .failed;
        }
    }

    fn admitReadOnly(self: *Controller) bool {
        if (self.app.closing or self.app.quitting or !self.app.git.valid()) return false;
        if (self.app.git.generation != self.git_generation) return false;
        const workspace = self.workspace orelse return false;
        if (!self.app.workspace.accepts(workspace)) return false;
        return self.repoMatches();
    }
    fn admit(self: *Controller) !void {
        if (self.app.closing or self.app.quitting or self.app.git.window == null or !self.app.git.approved or
            self.app.git.generation != self.git_generation) return error.RequestChanged;
        const permit = self.app.git.permit orelse return error.Restricted;
        if (!self.app.workspace_policy.validate(permit, .git)) return error.Restricted;
        const workspace = self.workspace orelse return error.WorkspaceChanged;
        if (!self.app.workspace.accepts(workspace) or self.app.browser.closed or self.app.browser.loading or self.app.browser.choosing) return error.WorkspaceChanged;
        const snapshot = if (self.app.browser.model) |*m| m else return error.WorkspaceChanged;
        const scope_token = self.scope_token orelse return error.WorkspaceChanged;
        const request_token = self.request_token orelse return error.WorkspaceChanged;
        if (!snapshot.scope.accepts(scope_token) or !self.app.browser.requests.accepts(request_token)) return error.WorkspaceChanged;
        const root = snapshot.rootById(self.root_id) orelse return error.WorkspaceChanged;
        if (root.availability != .available or !std.mem.eql(u8, root.canonical_path orelse return error.WorkspaceChanged, self.repo_owner)) return error.WorkspaceChanged;
        if (!self.repoMatches()) return error.SelectionChanged;
        if (self.app.git.job != null or self.app.git.mutation.busy()) return error.SelectionChanged;
        const manager = self.app.manager orelse return error.NoManager;
        try manager.checkFileOperation(self.app, self.index_path, "");
    }
    fn repoMatches(self: *Controller) bool {
        const repository = self.app.git.repo() orelse return false;
        return repository.root == self.root_id and
            std.mem.eql(u8, repository.path, self.repo_path) and
            std.mem.eql(u8, repository.owner, self.repo_owner) and
            std.mem.eql(u8, repository.gitdir, self.repo_gitdir) and
            std.mem.eql(u8, repository.commondir, self.repo_commondir);
    }

    fn clearSnapshot(self: *Controller) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }
    fn clearPrepare(self: *Controller) void {
        self.clearSnapshot();
        _ = self.arena.reset(.free_all);
        self.repo_path = "";
        self.repo_owner = "";
        self.repo_gitdir = "";
        self.repo_commondir = "";
        self.index_path = "";
        self.staged_files = &.{};
        self.staged_bytes = "";
        self.stat_summary = "";
        self.head_oid = "";
        self.parent_oid = "";
        self.published = null;
        self.operation = .none;
        self.operation_index = 0;
        self.operation_checks = &.{};
    }
    fn setStatus(self: *Controller, text: []const u8) void {
        a.free(self.status_text);
        self.status_text = u.z(text);
    }

    /// Test-only bridge. commit-accept answers the visible review dialog (value is
    /// the commit message for a commit review); it never grants trust or bypasses a
    /// permit. commit-show/uncommit-show/stage-show request the actual workflows.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "commit-probe")) self.probe() else if (std.mem.eql(u8, action, "commit-accept")) self.review.answer(true, null, value) else if (std.mem.eql(u8, action, "commit-reject")) self.review.answer(false, null, "") else if (std.mem.eql(u8, action, "commit-close")) self.invalidate() else if (std.mem.eql(u8, action, "commit-show")) self.showCommit() else if (std.mem.eql(u8, action, "commit-uncommit-show")) self.showUncommit() else if (std.mem.eql(u8, action, "commit-stage-show")) self.showStageTrackedCommit() else if (std.mem.eql(u8, action, "commit-delay")) {
            self.delay_us = @as(u64, @min(std.fmt.parseInt(u64, value, 10) catch return true, 2000)) * 1000;
        } else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const snapshot = self.snapshot;
        const counts = if (snapshot) |*s| commit.counts(s) else commit.Counts{ .staged = 0, .unstaged = 0, .unmerged = 0 };
        // JSON serializes raw paths as data, never as a shell command or GTK markup.
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .state = @tagName(self.state),
            .kind = @tagName(self.kind),
            .confirm = @tagName(self.confirm),
            .phase = if (self.job != null) @as(?[]const u8, @tagName(self.phase)) else null,
            .busy = self.busy(),
            .review = self.review.window != null,
            .generation = self.generation,
            .git_generation = self.git_generation,
            .launches = self.launches,
            .discarded = self.discarded,
            .jobs_started = self.jobs_started,
            .jobs_reaped = self.jobs_reaped,
            .committed = self.committed,
            .staged = self.staged,
            .@"error" = self.error_name,
            .repository = self.repo_path,
            .owner = self.repo_owner,
            .head = if (snapshot) |s| s.head else null,
            .branch = if (snapshot) |s| s.branch else null,
            .upstream = if (snapshot) |s| s.upstream else null,
            .head_oid = self.head_oid,
            .parent_oid = self.parent_oid,
            .published = self.published,
            .operation = @tagName(self.operation),
            .staged_count = counts.staged,
            .unstaged_count = counts.unstaged,
            .unmerged_count = counts.unmerged,
            .staged_files = self.staged_files,
            .stat_summary = self.stat_summary,
            .status = self.status_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_COMMIT %s\n", line.ptr);
    }
};

const Worker = struct {
    controller: *Controller,
    apply: Apply,
    // Borrowed from the controller arena/snapshot, stable until the worker is reaped.
    root: []const u8,
    gitdir: []const u8,
    message: []const u8,
    expected_head: ?[]const u8,
    staged_bytes: []const u8,
    parent_oid: []const u8,
    upstream: ?[]const u8,
    environment: []const commit.Environment,
    generation: u64,
    workspace: identity.Token,
    cancel: commit.Cancel = .init(false),
    running: bool = false,
    barrier: bool = false,
    attempted: bool = false,
    delay_us: u64 = 0,
    err: ?anyerror = null,
    outcome: State = .cancelled,
    committed: bool = false,

    fn destroy(self: *Worker) void {
        std.debug.assert(!self.running and !self.barrier);
        a.destroy(self);
    }
    fn perform(self: *Worker) !void {
        var remaining = self.delay_us;
        while (remaining != 0 and !self.cancel.load(.acquire)) {
            const slice = @min(remaining, 10_000);
            c.g_usleep(@intCast(slice));
            remaining -= slice;
        }
        const policy = commit.WritePolicy{ .prefix = env.write_prefix, .environment = self.environment };
        switch (self.apply) {
            .stage => {
                try commit.recheckStage(a, self.root, &self.cancel, self.expected_head);
                try commit.applyStage(a, self.root, &self.cancel, policy);
            },
            .commit => {
                try commit.recheckCommit(a, self.root, &self.cancel, self.expected_head, self.staged_bytes);
                try commit.applyCommit(a, self.root, &self.cancel, policy, self.message);
            },
            .uncommit => {
                try commit.recheckUncommit(a, self.root, self.gitdir, &self.cancel, self.expected_head.?, self.parent_oid, self.upstream);
                try commit.applyUncommit(a, self.root, &self.cancel, policy, self.parent_oid, self.expected_head.?);
            },
        }
        self.committed = true;
    }
};
fn workerRun(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const worker = u.cast(Worker, data.?);
    worker.perform() catch |err| {
        worker.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn workerDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const worker = u.cast(Worker, data.?);
    const self = worker.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.worker == worker and worker.running);
    worker.running = false;
    self.jobs_reaped += 1;
    // Publication wins over every invalidation/cancellation race, including close.
    if (worker.committed) {
        worker.outcome = .succeeded;
        self.committed = true;
        self.error_name = null;
        if (!self.app.closing) {
            const text = switch (worker.apply) {
                .commit => "Commit created from the reviewed staged index. Unstaged and untracked changes were preserved.",
                .uncommit => "HEAD uncommitted via soft reset. Index and worktree were preserved.",
                .stage => "Tracked changes staged (git add -u). Review the staged set before committing.",
            };
            self.app.message(text);
            self.setStatus(text);
        }
        self.finishWorker();
        return;
    }
    if (worker.cancel.load(.acquire) or self.app.closing) {
        self.finishWorker();
        return;
    }
    if (worker.err) |err| {
        self.abort(err);
        return;
    }
    self.abort(error.NotCommitted);
}
