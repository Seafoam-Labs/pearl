//! M4 Source Control dock panel: read-only status inspection plus explicitly
//! reviewed section/selected index staging, rendered inside the workbench dock.
//! The parent owns commands, lifecycle invalidation and wiring (app/commands).
//!
//! Read path: one supervised tasks/process.zig job per refresh under the locked
//! command.zig policy. Repository discovery stays with git/controller.zig; this
//! panel reuses app.git.repo() and never traverses the filesystem on GTK's
//! thread. No watchers, no startup work, no automatic refresh.
//!
//! Write path: every Stage all/Unstage all/Stage selected/Unstage selected
//! requires a separate native review (language/ui.zig) of the exact literal Git
//! argv and path set, then the shared manager barrier on the repository index
//! path, then a GTask worker using env.zig's write prefix/environment. The
//! worker rechecks HEAD (compare-and-swap against the reviewed snapshot), refuses
//! in-progress merge/rebase/cherry-pick/revert and unmerged conflicts, and
//! compares a fresh status capture's target path set byte-for-byte with the
//! reviewed set before applying. No shell, no inherited environment, no network,
//! no commit and no worktree write from this dock. Dirty buffers are excluded and
//! never saved; staging reads disk/index bytes only.
//!
//! Limits (documented for acceptance): 1 MiB status capture / 10,000 entries,
//! 128 visible file rows per page (plus at most 128 tree directory rows and 3
//! section headers), 1,024 explicit paths / 128 KiB argv per write, 256 KiB
//! review text, 15 s process timeouts. Untracked bulk staging names explicit
//! paths; tracked bulk staging uses `add -u --` and bulk unstaging uses
//! `reset --` (whole index) whose reviewed staged set is rechecked exactly.
//! Conflicts are shown but every write is refused while any unmerged entry
//! exists. Submodule contents are never inspected; gitlink changes stage like
//! other tracked changes. The commit button delegates to the reviewed commit
//! workflow (app.git_commit.showCommit) unless the parent wires on_commit.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const identity = @import("../workspace/identity.zig");
const model = @import("../workspace/model.zig");
const trust = @import("../workspace/trust.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const commit = @import("commit.zig");
const env = @import("env.zig");
const tx = @import("index_transaction.zig");
const git_controller = @import("controller.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const max_entries = status.max_entries;
pub const capture_bytes = status.max_input_bytes;
pub const page_rows = 128;
pub const max_review_bytes = 256 * 1024;
pub const max_write_paths = 1024;
pub const max_write_argv_bytes = 128 * 1024;
/// File rows plus worst-case one directory row per file and three headers.
const max_list_rows = page_rows * 2 + 3;

pub const Section = enum { staged, unstaged, untracked };
const State = enum { idle, reading, confirming, applying, succeeded, cancelled, failed };
const WriteKind = enum { stage_unstaged, stage_untracked, unstage_staged, stage_selected, unstage_selected };
const DisplayRow = struct { section: Section, entry: usize };

const disclosure =
    "The Source Control dock runs /usr/bin/git as your user, only after you continue in a trusted workspace. " ++
    "It reads repository metadata, the index and files on disk. Unsaved editor buffers are excluded and are never saved.\n\n" ++
    "Refresh is read-only inspection, not authorization to write. Stage all/Unstage all and Stage/Unstage selected require a separate review of the exact literal Git argv and path set before any index change. " ++
    "Section staging uses git add -u (tracked unstaged), git add -- <paths> (untracked) and git reset (staged); selected writes name one path. No commits, saves, checkout or network access are performed by this dock. " ++
    "System/global Git config, prompts, external diff and textconv are disabled for inspection. Repository-local Git configuration and clean filters can still execute programs with your user permissions. This is NOT a sandbox.\n\n" ++
    "Writes are refused while conflicts or merge/rebase/cherry-pick/revert operations are in progress, and recheck HEAD plus the exact reviewed path set immediately before applying. " ++
    "M4 limits: explicit refresh only, 1 MiB status capture / 10,000 entries, 128 visible file rows per page, 1,024 explicit paths / 128 KiB argv per write, 256 KiB review text. " ++
    "Repository discovery is owned by the Source Control window; submodule contents are not inspected.";

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    worker: ?*Worker = null,
    state: State = .idle,
    generation: u64 = 1,
    git_generation: u64 = 0,
    workspace: ?identity.Token = null,
    scope_token: ?identity.Token = null,
    request_token: ?identity.Token = null,
    permit: ?trust.Permit = null,
    approved: bool = false,
    approval: UI,
    review: UI,
    // Repository copied from app.git.repo() at refresh; arena-owned.
    root_id: model.RootId = undefined,
    repo_path: []const u8 = "",
    repo_owner: []const u8 = "",
    repo_gitdir: []const u8 = "",
    repo_commondir: []const u8 = "",
    index_path: []const u8 = "",
    snapshot: ?status.Snapshot = null,
    // Display model: entry indices per section, sorted by path, flattened in
    // section order. Tree/flat only changes rendering, never this order.
    display: std.ArrayList(DisplayRow) = .empty,
    staged: std.ArrayList(usize) = .empty,
    unstaged: std.ArrayList(usize) = .empty,
    untracked: std.ArrayList(usize) = .empty,
    unmerged_count: usize = 0,
    selected: ?usize = null,
    page: usize = 0,
    tree: bool = false,
    // Pending reviewed write (arena-owned; borrowed by the worker until reaped).
    write_kind: WriteKind = .stage_unstaged,
    write_args: []const []const u8 = &.{},
    write_paths: []const []const u8 = &.{},
    expected_head: ?[]const u8 = null,
    committed: bool = false,
    error_name: ?[]const u8 = null,
    status_text: [:0]u8,
    launches: u64 = 0,
    discarded: u64 = 0,
    jobs_started: u64 = 0,
    jobs_reaped: u64 = 0,
    // Widgets (owned by the dock slot; destroyed with the window).
    root: ?u.W = null,
    repo_label: ?u.W = null,
    mode_button: ?u.W = null,
    message_entry: ?u.W = null,
    commit_button: ?u.W = null,
    status_label: ?u.W = null,
    dirty_label: ?u.W = null,
    list: ?u.W = null,
    stage_button: ?u.W = null,
    unstage_button: ?u.W = null,
    page_label: ?u.W = null,
    rebuilding: bool = false,
    row_entries: [max_list_rows]?usize = @splat(null),
    row_count: usize = 0,
    /// Parent wiring: receives the dock's commit message text. When null, the
    /// commit button delegates to app.git_commit.showCommit(), whose own review
    /// prompts for and validates the message.
    on_commit: ?*const fn (context: *anyopaque, message: []const u8) void = null,
    commit_context: ?*anyopaque = null,

    pub fn init(app: *App) Controller {
        // Do not reach through App.git here: its parent is still initializing.
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .approval = .{ .context = app, .respond = &disclosureAnswered },
            .review = .{ .context = app, .respond = &reviewAnswered },
            .status_text = u.z("Source Control dock — explicit refresh only. Staging requires a separate review; unsaved buffers are excluded and never saved."),
        };
    }
    /// Call before the dock slot/window is destroyed. App holds keep this
    /// controller alive until every cancelled job/worker is reaped.
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.job == null and self.worker == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.disconnectWidgets();
        self.clearModel();
        self.arena.deinit();
        a.free(self.status_text);
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.worker != null;
    }
    /// Keyboard target for win.focus-source-control once the panel is attached.
    pub fn focusWidget(self: *Controller) ?u.W {
        return self.message_entry;
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.approved = false;
        self.permit = null;
        self.approval.close();
        // A running worker still borrows arena snapshots; it clears on reap.
        if (self.worker == null) self.clearModel();
        self.setStatus("Source Control dock invalidated. Refresh to run Git again.");
        self.render();
    }
    fn cancel(self: *Controller) void {
        // Publish cancellation before touching GTK surfaces. Only the worker's
        // committed result can override it.
        self.generation +|= 1;
        if (self.job) |job| job.cancel();
        self.review.close();
        if (self.worker) |worker| {
            worker.cancel.store(true, .release);
            if (worker.outcome != .failed) worker.outcome = .cancelled;
            if (!worker.running) self.finishWorker();
        } else self.state = .cancelled;
    }

    // --- Read-only status ---------------------------------------------------

    pub fn refresh(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.permitted()) {
            // Disclosure never queues a write nor approves a future review.
            self.permit = self.app.workspace_policy.issue(.git) catch {
                self.app.message("Source Control is restricted. Trust the workspace before running Git.");
                return;
            };
            self.approval.context = self;
            self.approval.show(self.app, "Source Control dock — subprocess disclosure", disclosure, &.{}, false, "Continue with read-only Git");
            return;
        }
        if (self.worker != null and self.worker.?.running) {
            self.setStatus("Wait for the current index write to finish before refreshing.");
            return;
        }
        self.cancel();
        self.clearModel();
        const repository = self.app.git.repo() orelse {
            self.setStatus("No repository discovered yet. Open Git: Source Control… and Refresh there first; this dock reuses its repository discovery.");
            self.render();
            return;
        };
        self.beginStatus(repository) catch |err| self.abort(err);
    }
    fn permitted(self: *Controller) bool {
        if (self.app.closing or self.app.quitting or !self.approved) return false;
        const permit = self.permit orelse return false;
        return self.app.workspace_policy.validate(permit, .git);
    }
    fn beginStatus(self: *Controller, repository: *const git_controller.Repository) !void {
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
        self.state = .reading;
        self.setStatus("Reading Git status — disk/index only; unsaved buffers excluded…");
        self.render();
        try self.launchStatus();
    }
    fn launchStatus(self: *Controller) !void {
        if (!self.permitted()) return error.Restricted;
        if (self.job != null or self.worker != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        if (command.prefix.len + command.status_args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..command.prefix.len], command.prefix);
        @memcpy(argv[command.prefix.len..][0..command.status_args.len], command.status_args);
        var environment: [command.environment.len]process.Environment = undefined;
        for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
        self.job = try process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "git-panel-read", .request = self.launches + 1, .generation = self.generation, .workspace = self.workspace },
            .argv = argv[0 .. command.prefix.len + command.status_args.len],
            .cwd = self.repo_path,
            .environment = &environment,
            .output_limit = capture_bytes,
            .timeout_ms = 15000,
        }, &statusCompleted, self);
        self.launches += 1;
        self.app.hold();
    }
    fn statusCompleted(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
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
            // Parent invalidation normally clears the surface earlier. Also fail
            // closed at delivery if the workspace/policy changed in the meantime.
            self.invalidate();
            return;
        }
        self.receiveStatus(result) catch |err| self.abort(err);
    }
    fn receiveStatus(self: *Controller, result: process.Result) !void {
        if (result.outcome != .success) {
            self.state = .failed;
            const text = u.fmt("Git status: {s} (exit {d}). No partial result is shown. Refresh to retry.", .{ @tagName(result.outcome), result.exit_code orelse -1 });
            defer a.free(text);
            self.setStatus(text);
            self.render();
            return;
        }
        var parsed = try status.parse(a, result.stdout);
        if (parsed.entries.len > max_entries) {
            parsed.deinit();
            return error.TooManyStatusEntries;
        }
        self.clearSnapshot();
        self.snapshot = parsed;
        try self.rebuildDisplay();
        self.state = .idle;
        self.error_name = null;
        self.render();
        self.updateSummary();
    }
    fn admitReadOnly(self: *Controller) bool {
        if (!self.permitted()) return false;
        if (self.app.git.generation != self.git_generation) return false;
        const workspace = self.workspace orelse return false;
        if (!self.app.workspace.accepts(workspace)) return false;
        return self.repoMatches();
    }
    fn repoMatches(self: *Controller) bool {
        const repository = self.app.git.repo() orelse return false;
        return repository.root == self.root_id and
            std.mem.eql(u8, repository.path, self.repo_path) and
            std.mem.eql(u8, repository.owner, self.repo_owner) and
            std.mem.eql(u8, repository.gitdir, self.repo_gitdir) and
            std.mem.eql(u8, repository.commondir, self.repo_commondir);
    }

    // --- Reviewed index writes ----------------------------------------------

    pub fn stageAll(self: *Controller, section: Section) void {
        if (section == .staged) return;
        self.requestWrite(if (section == .untracked) .stage_untracked else .stage_unstaged);
    }
    pub fn unstageAll(self: *Controller) void {
        self.requestWrite(.unstage_staged);
    }
    pub fn stageSelected(self: *Controller) void {
        self.requestWrite(.stage_selected);
    }
    pub fn unstageSelected(self: *Controller) void {
        self.requestWrite(.unstage_selected);
    }
    fn requestWrite(self: *Controller, kind: WriteKind) void {
        if (self.app.closing) return;
        if (!self.permitted()) {
            // Disclosure never queues a write nor approves a future review.
            self.refresh();
            return;
        }
        if (self.busy() or self.review.window != null or self.approval.window != null) {
            self.setStatus("Finish or cancel the current Git request or review before requesting an index change.");
            return;
        }
        if (self.app.git.job != null or self.app.git.mutation.busy() or self.app.git_commit.busy()) {
            self.setStatus("Another Git operation is in progress. Wait for it before requesting an index change.");
            return;
        }
        self.beginWrite(kind) catch |err| self.abort(err);
    }
    fn beginWrite(self: *Controller, kind: WriteKind) !void {
        const snapshot = self.snapshot orelse return error.RefreshRequired;
        if (self.unmerged_count != 0) return error.UnmergedConflict;
        if (!self.repoMatches() or self.app.git.generation != self.git_generation) return error.SelectionChanged;
        const ar = self.arena.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        var args: std.ArrayList([]const u8) = .empty;
        switch (kind) {
            .stage_unstaged => {
                for (self.unstaged.items) |d| {
                    const entry = snapshot.entries[self.display.items[d].entry];
                    if (entry.kind == .unmerged) return error.UnmergedConflict;
                    try paths.append(ar, entry.path);
                }
                if (paths.items.len == 0) return error.NothingToStage;
                // No pathspec: the whole tracked tree. The worker rechecks that
                // the current unstaged set still equals the reviewed set.
                try args.appendSlice(ar, &.{ "add", "-u", "--" });
            },
            .stage_untracked => {
                for (self.untracked.items) |d| try paths.append(ar, snapshot.entries[self.display.items[d].entry].path);
                if (paths.items.len == 0) return error.NothingToStage;
                try args.appendSlice(ar, &.{ "add", "--" });
                for (paths.items) |path| try args.append(ar, path);
            },
            .unstage_staged => {
                for (self.staged.items) |d| try paths.append(ar, snapshot.entries[self.display.items[d].entry].path);
                if (paths.items.len == 0) return error.NothingToUnstage;
                // Whole-index mixed reset (never --hard). The worker rechecks
                // that the current staged set still equals the reviewed set, so
                // the write cannot unstage paths outside the review.
                try args.appendSlice(ar, &.{ "reset", "--" });
            },
            .stage_selected, .unstage_selected => {
                const sel = self.selected orelse return error.NoSelection;
                if (sel >= self.display.items.len) return error.NoSelection;
                const entry = snapshot.entries[self.display.items[sel].entry];
                if (entry.kind == .unmerged) return error.UnmergedConflict;
                if (kind == .stage_selected) {
                    if (!(entry.kind == .untracked or entry.worktree != '.')) return error.NothingToStage;
                    try args.appendSlice(ar, &.{ "add", "--" });
                } else {
                    if (!((entry.kind == .ordinary or entry.kind == .rename) and entry.index != '.')) return error.NothingToUnstage;
                    try args.appendSlice(ar, &.{ "reset", "--" });
                }
                try paths.append(ar, entry.path);
                try args.append(ar, entry.path);
                if (entry.original_path) |original| {
                    try paths.append(ar, original);
                    try args.append(ar, original);
                }
            },
        }
        var argv_bytes: usize = 0;
        for (args.items) |arg| argv_bytes += arg.len + 1;
        if (paths.items.len > max_write_paths or argv_bytes > max_write_argv_bytes) return error.WriteBudgetExceeded;
        self.write_kind = kind;
        self.write_args = try args.toOwnedSlice(ar);
        self.write_paths = try paths.toOwnedSlice(ar);
        self.expected_head = blk: {
            const head = snapshot.head orelse break :blk null;
            break :blk if (std.mem.eql(u8, head, "(initial)")) null else head;
        };
        self.committed = false;
        try self.showWriteReview();
    }
    fn showWriteReview(self: *Controller) !void {
        const snapshot = self.snapshot orelse return error.RefreshRequired;
        const repo = try command.display(a, self.repo_path, 512);
        defer a.free(repo);
        const branch = try command.display(a, snapshot.branch orelse "(detached/unborn)", 256);
        defer a.free(branch);
        var argv_text: std.ArrayList(u8) = .empty;
        defer argv_text.deinit(a);
        for (env.write_prefix) |arg| {
            const escaped = try command.display(a, arg, 512);
            defer a.free(escaped);
            try argv_text.appendSlice(a, escaped);
            try argv_text.append(a, ' ');
        }
        for (self.write_args) |arg| {
            const escaped = try command.display(a, arg, 4096);
            defer a.free(escaped);
            try argv_text.appendSlice(a, escaped);
            try argv_text.append(a, ' ');
        }
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(a);
        for (self.write_paths) |path| {
            const label = try command.display(a, path, 1024);
            defer a.free(label);
            try list.appendSlice(a, label);
            try list.append(a, '\n');
            if (list.items.len > max_review_bytes) return error.ReviewTooLarge;
        }
        const action: []const u8 = switch (self.write_kind) {
            .stage_unstaged => "Stage all unstaged tracked changes (git add -u)",
            .stage_untracked => "Stage all untracked paths (git add -- <paths>)",
            .unstage_staged => "Unstage all staged paths (git reset, whole index)",
            .stage_selected => "Stage selected path (git add -- <path>)",
            .unstage_selected => "Unstage selected path (git reset -- <path>)",
        };
        const staging = self.write_kind == .stage_unstaged or self.write_kind == .stage_untracked or self.write_kind == .stage_selected;
        const body = u.fmt(
            "{s} — Source Control dock index review\nRepository: {s}\nBranch: {s}\n\n" ++
                "Exact command (literal argv, no shell):\n{s}\n\nReviewed paths ({d}):\n{s}\n" ++
                "Unsaved editor documents across windows: {d} (at review creation). Dirty buffers are excluded and NEVER saved; staging reads disk/index bytes only.\n" ++
                "This changes only the index: no commit, no worktree file write, no network access. Clean filters may execute configured programs with your user permissions; this is NOT a sandbox.\n" ++
                "Immediately before applying, the write rechecks HEAD, refuses in-progress merge/rebase/cherry-pick/revert and unmerged conflicts, and requires the current target path set to match this review byte-for-byte. Any change refuses the write.\n",
            .{ action, repo, branch, argv_text.items, self.write_paths.len, list.items, self.app.git.dirtyCount() },
        );
        defer a.free(body);
        if (body.len > max_review_bytes) return error.ReviewTooLarge;
        self.state = .confirming;
        self.review.context = self;
        self.setStatus("Review the exact index change, then accept or cancel.");
        self.review.show(self.app, "Review index change — Source Control dock", body, &.{}, false, if (staging) "Stage reviewed index change" else "Unstage reviewed index change");
        self.render();
    }
    fn reviewAnswered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        if (self.state != .confirming) return;
        if (!accepted) {
            self.cancel();
            self.setStatus("Index change cancelled. Nothing was written.");
            self.render();
            return;
        }
        self.startApply() catch |err| self.abort(err);
    }
    fn startApply(self: *Controller) !void {
        try self.admit();
        const ar = self.arena.allocator();
        // The disclosed write policy: env.zig write prefix + complete allowlist.
        const write_env = try env.write(ar);
        const environment = try ar.alloc(commit.Environment, write_env.len);
        for (write_env, 0..) |entry, i| environment[i] = .{ .name = entry.name, .value = entry.value };
        const worker = try a.create(Worker);
        worker.* = .{
            .controller = self,
            .kind = self.write_kind,
            .root = self.repo_path,
            .gitdir = self.repo_gitdir,
            .args = self.write_args,
            .paths = self.write_paths,
            .expected_head = self.expected_head,
            .environment = environment,
        };
        errdefer worker.destroy();
        // The index path (not a worktree file) keeps manager-wide save/load/modal
        // admission and the shared editor/operation barrier while allowing dirty
        // buffers, exactly like the selected-path index transaction.
        try self.app.manager.?.beginFileOperation(self.app, self.index_path, "");
        worker.barrier = true;
        worker.attempted = true;
        self.worker = worker;
        self.app.hold();
        self.state = .applying;
        self.setStatus("Applying reviewed Git index write…");
        self.render();
        self.dispatchWorker();
    }
    /// Full GTK-thread re-admission at acceptance; mirrors the commit workflow.
    fn admit(self: *Controller) !void {
        if (self.app.closing or self.app.quitting or !self.approved) return error.RequestChanged;
        if (self.app.git.generation != self.git_generation) return error.RequestChanged;
        const permit = self.permit orelse return error.Restricted;
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
        if (self.app.git.job != null or self.app.git.mutation.busy() or self.app.git_commit.busy()) return error.SelectionChanged;
        if (self.job != null or self.worker != null) return error.Busy;
        const manager = self.app.manager orelse return error.NoManager;
        try manager.checkFileOperation(self.app, self.index_path, "");
    }
    fn dispatchWorker(self: *Controller) void {
        const worker = self.worker.?;
        std.debug.assert(!worker.running);
        worker.running = true;
        worker.err = null;
        self.jobs_started += 1;
        // No GCancellable: cancellation must not skip worker reaping or deliver
        // an early callback while the worker still owns the write transaction.
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
        self.worker = null;
        worker.destroy();
        self.app.release();
    }
    fn abort(self: *Controller, err: anyerror) void {
        self.error_name = @errorName(err);
        self.generation +|= 1;
        if (self.job) |job| job.cancel();
        self.review.close();
        const attempted = self.worker != null;
        if (self.worker) |worker| {
            worker.outcome = .failed;
            worker.cancel.store(true, .release);
            if (!worker.running) self.finishWorker();
        } else self.state = .failed;
        // An attempted write invalidates the snapshot even on failure; a refused
        // request keeps the current read-only view.
        if (attempted and self.worker == null) self.clearModel();
        if (!self.app.closing) {
            const text = u.fmt("Source Control dock refused: {s}. No index change was published. Resolve the state and request a new review.", .{@errorName(err)});
            defer a.free(text);
            self.app.message(text);
            self.setStatus(text);
        }
        self.render();
    }

    // --- Commit delegation ----------------------------------------------------

    fn requestCommit(self: *Controller) void {
        if (self.app.closing) return;
        const message = if (self.message_entry) |entry| u.entryText(entry) else "";
        if (self.on_commit) |callback| {
            callback(self.commit_context orelse self, message);
            return;
        }
        // The reviewed commit workflow prompts for and validates the message in
        // its own review; the parent may wire on_commit to consume this entry.
        self.app.git_commit.showCommit();
    }

    // --- Display model --------------------------------------------------------

    fn clearSnapshot(self: *Controller) void {
        self.selected = null;
        self.page = 0;
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }
    fn clearModel(self: *Controller) void {
        std.debug.assert(self.worker == null);
        self.clearSnapshot();
        _ = self.arena.reset(.free_all);
        self.repo_path = "";
        self.repo_owner = "";
        self.repo_gitdir = "";
        self.repo_commondir = "";
        self.index_path = "";
        self.display = .empty;
        self.staged = .empty;
        self.unstaged = .empty;
        self.untracked = .empty;
        self.unmerged_count = 0;
        self.write_args = &.{};
        self.write_paths = &.{};
        self.expected_head = null;
        self.workspace = null;
        self.scope_token = null;
        self.request_token = null;
        self.render();
    }
    fn rebuildDisplay(self: *Controller) !void {
        const ar = self.arena.allocator();
        self.display.clearRetainingCapacity();
        self.staged.clearRetainingCapacity();
        self.unstaged.clearRetainingCapacity();
        self.untracked.clearRetainingCapacity();
        self.unmerged_count = 0;
        self.selected = null;
        self.page = 0;
        const snapshot = self.snapshot orelse return;
        for (snapshot.entries, 0..) |entry, i| {
            switch (entry.kind) {
                .untracked => try self.untracked.append(ar, i),
                .unmerged => {
                    try self.unstaged.append(ar, i);
                    self.unmerged_count += 1;
                },
                .ordinary, .rename => {
                    if (entry.index != '.') try self.staged.append(ar, i);
                    if (entry.worktree != '.') try self.unstaged.append(ar, i);
                },
                .ignored => {},
            }
        }
        for ([_]*std.ArrayList(usize){ &self.staged, &self.unstaged, &self.untracked }) |list| {
            std.mem.sort(usize, list.items, snapshot.entries, lessThanEntryPath);
        }
        for (self.staged.items) |i| try self.display.append(ar, .{ .section = .staged, .entry = i });
        for (self.unstaged.items) |i| try self.display.append(ar, .{ .section = .unstaged, .entry = i });
        for (self.untracked.items) |i| try self.display.append(ar, .{ .section = .untracked, .entry = i });
    }
    fn selectedEntry(self: *Controller) ?status.Entry {
        const sel = self.selected orelse return null;
        if (sel >= self.display.items.len) return null;
        const snapshot = self.snapshot orelse return null;
        return snapshot.entries[self.display.items[sel].entry];
    }
    pub fn select(self: *Controller, index: ?usize) void {
        if (index) |i| {
            if (i >= self.display.items.len) return;
            self.selected = i;
            self.page = i / page_rows;
        } else self.selected = null;
        self.renderRows();
        self.updateActions();
    }
    pub fn changePage(self: *Controller, next: bool) void {
        const total = self.display.items.len;
        if (next) {
            if ((self.page + 1) * page_rows >= total) return;
            self.page += 1;
        } else {
            if (self.page == 0) return;
            self.page -= 1;
        }
        self.selected = null;
        self.renderRows();
        self.updateActions();
    }
    pub fn setTree(self: *Controller, tree: bool) void {
        self.tree = tree;
        if (self.mode_button) |button| c.gtk_button_set_label(u.cast(c.GtkButton, button), if (tree) "Flat view" else "Tree view");
        self.renderRows();
    }
    fn canWrite(self: *Controller) bool {
        return self.permitted() and self.snapshot != null and self.unmerged_count == 0 and
            self.job == null and self.worker == null and self.review.window == null and self.approval.window == null;
    }

    // --- Widgets ---------------------------------------------------------------

    /// Build the panel into the dock's source_control_slot. Call only once the
    /// controller is at its stable address. No Git work starts here.
    pub fn attach(self: *Controller, slot: u.W) void {
        if (self.root != null or self.app.closing) return;
        const root = u.box(false, 6);
        u.margin(root, 8);
        c.gtk_widget_set_vexpand(root, 1);
        self.root = root;
        const header = u.box(true, 6);
        u.append(root, header);
        const repo_label = u.label("No repository — refresh after Source Control discovery");
        self.repo_label = repo_label;
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, repo_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_hexpand(repo_label, 1);
        u.append(header, repo_label);
        const mode_button = u.button("Tree view");
        self.mode_button = mode_button;
        u.connect(mode_button, "clicked", &modeClicked, self);
        u.append(header, mode_button);
        const refresh_button = u.button("Refresh");
        u.connect(refresh_button, "clicked", &refreshClicked, self);
        u.append(header, refresh_button);
        const commit_bar = u.box(true, 6);
        u.append(root, commit_bar);
        const entry = c.gtk_entry_new().?;
        self.message_entry = entry;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, entry), "Commit message (staged changes only)…");
        c.gtk_widget_set_hexpand(entry, 1);
        u.append(commit_bar, entry);
        const commit_button = u.button("Commit staged…");
        self.commit_button = commit_button;
        u.connect(commit_button, "clicked", &commitClicked, self);
        u.append(commit_bar, commit_button);
        const status_label = u.label(self.status_text);
        self.status_label = status_label;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, status_label), 1);
        u.append(root, status_label);
        const dirty_label = u.label("");
        self.dirty_label = dirty_label;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, dirty_label), 1);
        u.append(root, dirty_label);
        const list = c.gtk_list_box_new().?;
        self.list = list;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_set_vexpand(list, 1);
        u.append(root, list);
        u.connect(list, "row-selected", &rowSelected, self);
        const actions = u.box(true, 6);
        u.append(root, actions);
        const stage_button = u.button("Stage selected");
        self.stage_button = stage_button;
        u.connect(stage_button, "clicked", &stageSelectedClicked, self);
        u.append(actions, stage_button);
        const unstage_button = u.button("Unstage selected");
        self.unstage_button = unstage_button;
        u.connect(unstage_button, "clicked", &unstageSelectedClicked, self);
        u.append(actions, unstage_button);
        const previous = u.button("Previous page");
        u.connect(previous, "clicked", &previousClicked, self);
        u.append(actions, previous);
        const next = u.button("Next page");
        u.connect(next, "clicked", &nextClicked, self);
        u.append(actions, next);
        self.page_label = u.label("No rows");
        u.append(actions, self.page_label.?);
        u.append(slot, root);
        self.render();
    }
    fn disconnectWidgets(self: *Controller) void {
        if (self.root) |root| self.disconnectTree(root);
        self.root = null;
        self.repo_label = null;
        self.mode_button = null;
        self.message_entry = null;
        self.commit_button = null;
        self.status_label = null;
        self.dirty_label = null;
        self.list = null;
        self.stage_button = null;
        self.unstage_button = null;
        self.page_label = null;
    }
    fn disconnectTree(self: *Controller, widget: u.W) void {
        _ = c.g_signal_handlers_disconnect_matched(widget, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        var child = c.gtk_widget_get_first_child(widget);
        while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) self.disconnectTree(w);
    }
    fn render(self: *Controller) void {
        self.renderRows();
        self.updateActions();
        self.updateRepoLabel();
        self.updateDirtyLabel();
    }
    fn renderRows(self: *Controller) void {
        const list = self.list orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        self.row_count = 0;
        const total = self.display.items.len;
        const start = @min(self.page * page_rows, total);
        const end = @min(start + page_rows, total);
        var current_section: ?Section = null;
        var current_dir: ?[]const u8 = null;
        for (self.display.items[start..end], start..) |row, display_index| {
            if (current_section != row.section) {
                current_section = row.section;
                current_dir = null;
                self.appendSectionHeader(row.section);
            }
            const entry = self.snapshot.?.entries[row.entry];
            if (self.tree) {
                const dir = std.fs.path.dirname(entry.path) orelse "";
                if (current_dir == null or !std.mem.eql(u8, current_dir.?, dir)) {
                    current_dir = dir;
                    self.appendDirectoryRow(dir);
                }
            }
            self.appendFileRow(display_index, entry);
        }
        if (self.page_label) |label| {
            const text = u.fmt("{d}–{d} / {d} rows · {d} entries", .{ if (total == 0) @as(usize, 0) else start + 1, end, total, if (self.snapshot) |s| s.entries.len else @as(usize, 0) });
            defer a.free(text);
            u.setLabel(label, text);
        }
        if (self.selected) |sel| {
            for (self.row_entries[0..self.row_count], 0..) |maybe, i| {
                if (maybe != null and maybe.? == sel) {
                    c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), @intCast(i)));
                    break;
                }
            }
        }
    }
    fn pushRow(self: *Controller, row: u.W, display_index: ?usize) void {
        std.debug.assert(self.row_count < max_list_rows);
        c.gtk_list_box_append(u.cast(c.GtkListBox, self.list.?), row);
        self.row_entries[self.row_count] = display_index;
        self.row_count += 1;
    }
    fn appendSectionHeader(self: *Controller, section: Section) void {
        const count = switch (section) {
            .staged => self.staged.items.len,
            .unstaged => self.unstaged.items.len,
            .untracked => self.untracked.items.len,
        };
        const row = c.gtk_list_box_row_new().?;
        c.gtk_list_box_row_set_selectable(u.cast(c.GtkListBoxRow, row), 0);
        const box = u.box(true, 6);
        u.margin(box, 4);
        const title = u.fmt("{s} ({d})", .{ sectionTitle(section), count });
        defer a.free(title);
        const label = u.label(title);
        c.gtk_widget_set_hexpand(label, 1);
        u.append(box, label);
        const button = u.button(if (section == .staged) "Unstage all" else "Stage all");
        const enabled = self.canWrite() and count > 0;
        c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
        if (!enabled and self.unmerged_count != 0) c.gtk_widget_set_tooltip_text(button, "Resolve conflicts before staging or unstaging.");
        u.connect(button, "clicked", switch (section) {
            .staged => &unstageAllClicked,
            .unstaged => &stageUnstagedClicked,
            .untracked => &stageUntrackedClicked,
        }, self);
        u.append(box, button);
        c.gtk_list_box_row_set_child(u.cast(c.GtkListBoxRow, row), box);
        self.pushRow(row, null);
    }
    fn appendDirectoryRow(self: *Controller, dir: []const u8) void {
        const row = c.gtk_list_box_row_new().?;
        c.gtk_list_box_row_set_selectable(u.cast(c.GtkListBoxRow, row), 0);
        const escaped = command.display(a, dir, 1024) catch unreachable;
        defer a.free(escaped);
        const text = if (dir.len == 0) u.fmt("(repository root)", .{}) else u.fmt("{s}/", .{escaped});
        defer a.free(text);
        const label = u.label(text);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_margin_start(label, 8);
        c.gtk_widget_set_margin_top(label, 2);
        c.gtk_widget_set_margin_bottom(label, 2);
        c.gtk_list_box_row_set_child(u.cast(c.GtkListBoxRow, row), label);
        self.pushRow(row, null);
    }
    fn appendFileRow(self: *Controller, display_index: usize, entry: status.Entry) void {
        const shown = if (self.tree) std.fs.path.basename(entry.path) else entry.path;
        const path = command.display(a, shown, 1024) catch unreachable;
        defer a.free(path);
        const suffix: []const u8 = if (entry.kind == .unmerged) "  [conflict]" else if (entry.kind == .untracked) "  [untracked]" else if (entry.submodule) "  [submodule]" else "";
        const text = u.fmt("{c}{c}  {s}{s}", .{ entry.index, entry.worktree, path, suffix });
        defer a.free(text);
        const label = u.label(text);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
        c.gtk_widget_set_tooltip_text(label, text);
        u.margin(label, 4);
        if (self.tree) {
            var depth: usize = 0;
            for (entry.path) |ch| {
                if (ch == '/') depth += 1;
            }
            c.gtk_widget_set_margin_start(label, @intCast(12 + 8 * @min(depth, 8)));
        }
        const row = c.gtk_list_box_row_new().?;
        c.gtk_list_box_row_set_child(u.cast(c.GtkListBoxRow, row), label);
        self.pushRow(row, display_index);
    }
    fn updateActions(self: *Controller) void {
        const entry = self.selectedEntry();
        const can_stage = self.canWrite() and entry != null and
            (entry.?.kind == .untracked or (entry.?.kind != .unmerged and entry.?.worktree != '.'));
        const can_unstage = self.canWrite() and entry != null and entry.?.kind != .unmerged and
            (entry.?.kind == .ordinary or entry.?.kind == .rename) and entry.?.index != '.';
        if (self.stage_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(can_stage));
        if (self.unstage_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(can_unstage));
        if (self.commit_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(!self.app.closing));
    }
    fn updateRepoLabel(self: *Controller) void {
        const label = self.repo_label orelse return;
        if (self.repo_path.len == 0) {
            u.setLabel(label, "No repository — refresh after Source Control discovery");
            return;
        }
        const path = command.display(a, self.repo_path, 512) catch return;
        defer a.free(path);
        const text = u.fmt("Repository: {s}", .{path});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn updateDirtyLabel(self: *Controller) void {
        const label = self.dirty_label orelse return;
        const text = u.fmt("Unsaved editor documents: {d} across windows (excluded; never saved). Counts update on interaction.", .{self.app.git.dirtyCount()});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn updateSummary(self: *Controller) void {
        const snapshot = self.snapshot orelse return;
        const branch = command.display(a, snapshot.branch orelse "(detached/unborn)", 256) catch return;
        defer a.free(branch);
        const head = snapshot.head orelse "unknown";
        const text = u.fmt("{s} · HEAD {s} · staged {d} · unstaged {d} · untracked {d} · conflicts {d} · {d} entries. Explicit refresh only; unsaved buffers excluded.", .{ branch, head[0..@min(head.len, 12)], self.staged.items.len, self.unstaged.items.len, self.untracked.items.len, self.unmerged_count, snapshot.entries.len });
        defer a.free(text);
        self.setStatus(text);
    }
    fn setStatus(self: *Controller, text: []const u8) void {
        a.free(self.status_text);
        self.status_text = u.z(text);
        if (self.status_label) |label| u.setLabel(label, text);
    }

    // --- Test bridge -----------------------------------------------------------

    /// Test-only bridge. Selection values are zero-based display-row indices
    /// ("none" clears). Accept/reject answer the actual disclosure or review
    /// dialogs; they never grant trust or bypass a permit.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "panel-probe")) self.probe() else if (std.mem.eql(u8, action, "panel-refresh")) self.refresh() else if (std.mem.eql(u8, action, "panel-accept")) self.approval.answer(true, null, "") else if (std.mem.eql(u8, action, "panel-reject")) self.approval.answer(false, null, "") else if (std.mem.eql(u8, action, "panel-review-accept")) self.review.answer(true, null, "") else if (std.mem.eql(u8, action, "panel-review-reject")) self.review.answer(false, null, "") else if (std.mem.eql(u8, action, "panel-stage-all")) self.stageAll(if (std.mem.eql(u8, value, "untracked")) .untracked else .unstaged) else if (std.mem.eql(u8, action, "panel-unstage-all")) self.unstageAll() else if (std.mem.eql(u8, action, "panel-stage-selected")) self.stageSelected() else if (std.mem.eql(u8, action, "panel-unstage-selected")) self.unstageSelected() else if (std.mem.eql(u8, action, "panel-select")) {
            if (std.mem.eql(u8, value, "none")) self.select(null) else self.select(std.fmt.parseInt(usize, value, 10) catch return true);
        } else if (std.mem.eql(u8, action, "panel-tree-flat")) {
            if (std.mem.eql(u8, value, "tree")) self.setTree(true) else if (std.mem.eql(u8, value, "flat")) self.setTree(false) else self.setTree(!self.tree);
        } else if (std.mem.eql(u8, action, "panel-page")) self.changePage(std.mem.eql(u8, value, "next")) else if (std.mem.eql(u8, action, "panel-commit")) self.requestCommit() else if (std.mem.eql(u8, action, "panel-close")) self.invalidate() else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const snapshot = self.snapshot;
        const entries: []const status.Entry = if (snapshot) |s| s.entries else &.{};
        const total = self.display.items.len;
        const start = @min(self.page * page_rows, total);
        const end = @min(start + page_rows, total);
        const Row = struct { section: []const u8, entry: usize, path: []const u8, index: u8, worktree: u8, kind: []const u8 };
        var rows: [page_rows]Row = undefined;
        for (self.display.items[start..end], 0..) |d, i| {
            const entry = entries[d.entry];
            rows[i] = .{ .section = @tagName(d.section), .entry = d.entry, .path = entry.path, .index = entry.index, .worktree = entry.worktree, .kind = @tagName(entry.kind) };
        }
        // JSON serializes raw paths as data, never as a shell command or GTK markup.
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .attached = self.root != null,
            .approved = self.approved,
            .disclosure = self.approval.window != null,
            .review = self.review.window != null,
            .state = @tagName(self.state),
            .busy = self.busy(),
            .generation = self.generation,
            .git_generation = self.git_generation,
            .launches = self.launches,
            .discarded = self.discarded,
            .jobs_started = self.jobs_started,
            .jobs_reaped = self.jobs_reaped,
            .repository = self.repo_path,
            .owner = self.repo_owner,
            .gitdir = self.repo_gitdir,
            .head = if (snapshot) |s| s.head else null,
            .branch = if (snapshot) |s| s.branch else null,
            .upstream = if (snapshot) |s| s.upstream else null,
            .entry_count = entries.len,
            .staged_count = self.staged.items.len,
            .unstaged_count = self.unstaged.items.len,
            .untracked_count = self.untracked.items.len,
            .unmerged_count = self.unmerged_count,
            .display_rows = total,
            .page = self.page,
            .visible_rows = end - start,
            .rows = rows[0 .. end - start],
            .selected = self.selected,
            .selected_entry = if (self.selected) |sel| (if (sel < total) @as(?usize, self.display.items[sel].entry) else null) else null,
            .tree = self.tree,
            .write_kind = if (self.state == .confirming or self.state == .applying) @as(?[]const u8, @tagName(self.write_kind)) else null,
            .write_path_count = self.write_paths.len,
            .barrier = if (self.worker) |w| w.barrier else false,
            .committed = self.committed,
            .dirty_documents = self.app.git.dirtyCount(),
            .@"error" = self.error_name,
            .status = self.status_text,
            .commit_wired = self.on_commit != null,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_PANEL %s\n", line.ptr);
    }
};

fn sectionTitle(section: Section) []const u8 {
    return switch (section) {
        .staged => "Staged",
        .unstaged => "Unstaged",
        .untracked => "Untracked",
    };
}
fn lessThanEntryPath(entries: []const status.Entry, lhs: usize, rhs: usize) bool {
    return std.mem.lessThan(u8, entries[lhs].path, entries[rhs].path);
}
fn lessThanSlice(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
fn cancelled(cancel: *commit.Cancel) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
}

const Worker = struct {
    controller: *Controller,
    kind: WriteKind,
    // Borrowed from the controller arena, stable until the worker is reaped.
    root: []const u8,
    gitdir: []const u8,
    args: []const []const u8,
    paths: []const []const u8,
    expected_head: ?[]const u8,
    environment: []const commit.Environment,
    cancel: commit.Cancel = .init(false),
    running: bool = false,
    barrier: bool = false,
    attempted: bool = false,
    err: ?anyerror = null,
    outcome: State = .cancelled,
    committed: bool = false,

    fn destroy(self: *Worker) void {
        std.debug.assert(!self.running and !self.barrier);
        a.destroy(self);
    }
    fn perform(self: *Worker) !void {
        try self.recheck();
        const policy = commit.WritePolicy{ .prefix = env.write_prefix, .environment = self.environment };
        const r = try commit.runWrite(a, self.root, &self.cancel, policy, self.args, "", commit.write_output_bytes, commit.write_timeout_ms);
        a.free(r.bytes);
        self.committed = true;
    }
    /// Worker-only read-only revalidation under the locked-down policy. HEAD
    /// must not have moved; no conflict may exist; section writes require the
    /// current target path set to match the review byte-for-byte, selected
    /// writes require the selected path to still carry the reviewed side.
    fn recheck(self: *Worker) !void {
        try cancelled(&self.cancel);
        try commit.recheckHead(a, self.root, &self.cancel, self.expected_head);
        const r = try tx.runGit(a, self.root, null, null, null, null, &self.cancel, command.status_args, "", capture_bytes, false);
        defer a.free(r.bytes);
        if (r.code != 0) return error.GitFailed;
        var snapshot = try status.parse(a, r.bytes);
        defer snapshot.deinit();
        if (snapshot.entries.len > max_entries) return error.TooManyStatusEntries;
        var current: std.ArrayList([]const u8) = .empty;
        defer current.deinit(a);
        for (snapshot.entries) |entry| {
            if (entry.kind == .unmerged) return error.UnmergedConflict;
            const include = switch (self.kind) {
                .stage_unstaged, .stage_selected => (entry.kind == .ordinary or entry.kind == .rename) and entry.worktree != '.',
                .stage_untracked => entry.kind == .untracked,
                .unstage_staged, .unstage_selected => (entry.kind == .ordinary or entry.kind == .rename) and entry.index != '.',
            };
            if (include) try current.append(a, entry.path);
        }
        if (self.kind == .stage_selected or self.kind == .unstage_selected) {
            // A selected write touches only its path; other section members may
            // change freely, but the reviewed side must still be present.
            for (self.paths) |rev| {
                var found = false;
                for (current.items) |cur| {
                    if (std.mem.eql(u8, cur, rev)) found = true;
                }
                if (!found) return error.StaleSnapshot;
            }
        } else {
            const reviewed = try a.dupe([]const u8, self.paths);
            defer a.free(reviewed);
            std.mem.sort([]const u8, current.items, {}, lessThanSlice);
            std.mem.sort([]const u8, reviewed, {}, lessThanSlice);
            if (current.items.len != reviewed.len) return error.StaleSnapshot;
            for (current.items, reviewed) |cur, rev| {
                if (!std.mem.eql(u8, cur, rev)) return error.StaleSnapshot;
            }
        }
        // Refuse to discard merge/rebase/cherry-pick/revert state with a bulk
        // index write; conflicts were already refused above.
        if (try commit.detectOperation(a, self.root, self.gitdir, &self.cancel) != .none) return error.OperationInProgress;
        try cancelled(&self.cancel);
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
        const attempted = worker.attempted;
        if (!self.app.closing) self.app.message("Reviewed index change applied. No commit or worktree file was written.");
        self.finishWorker();
        if (!self.app.closing) {
            // The write invalidated both snapshots; reload under the same permit.
            if (self.permitted()) self.refresh() else self.clearModel();
            if (attempted and self.app.git.valid()) self.app.git.refresh();
        }
        return;
    }
    if (worker.cancel.load(.acquire) or self.app.closing) {
        const attempted = worker.attempted;
        self.finishWorker();
        self.clearModel();
        if (!self.app.closing) {
            self.setStatus("Index write cancelled. Refresh to reload status.");
            if (attempted and self.app.git.valid()) self.app.git.refresh();
        }
        return;
    }
    if (worker.err) |err| {
        self.abort(err);
        return;
    }
    self.abort(error.NotCommitted);
}
fn disclosureAnswered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
    const self = u.cast(Controller, context);
    if (!accepted or self.app.closing) return;
    const permit = self.permit orelse return;
    if (!self.app.workspace_policy.validate(permit, .git)) {
        self.app.message("Workspace trust changed. Invoke Source Control refresh again.");
        return;
    }
    self.approved = true;
    self.refresh();
}
fn rowSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.rebuilding) return;
    const r = row orelse {
        self.selected = null;
        self.updateActions();
        return;
    };
    const index = c.gtk_list_box_row_get_index(r);
    if (index < 0 or index >= self.row_count) return;
    self.selected = self.row_entries[@intCast(index)];
    self.updateActions();
}
fn modeClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    self.setTree(!self.tree);
}
fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).refresh();
}
fn commitClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).requestCommit();
}
fn stageSelectedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).stageSelected();
}
fn unstageSelectedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).unstageSelected();
}
fn stageUnstagedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).stageAll(.unstaged);
}
fn stageUntrackedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).stageAll(.untracked);
}
fn unstageAllClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).unstageAll();
}
fn previousClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).changePage(false);
}
fn nextClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(Controller, data.?).changePage(true);
}

// --- Tests ------------------------------------------------------------------
// The repository test confines every Git write to a private /tmp fixture with a
// hermetic environment (no host config, identity or signing), mirroring
// git/commit_test.zig. No host repository is ever written.

const os = @import("index_transaction_os.zig");
const t = std.testing;

test "display model classifies sections, sorts paths and keeps conflicts visible" {
    var panel: Controller = .{
        .app = undefined,
        .arena = std.heap.ArenaAllocator.init(t.allocator),
        .approval = .{ .context = undefined, .respond = undefined },
        .review = .{ .context = undefined, .respond = undefined },
        .status_text = u.z(""),
    };
    defer panel.arena.deinit();
    defer a.free(panel.status_text);
    var snapshot: status.Snapshot = .{
        .arena = std.heap.ArenaAllocator.init(t.allocator),
        .entries = undefined,
        .head = null,
        .branch = null,
        .upstream = null,
        .ahead = 0,
        .behind = 0,
    };
    var entries: [6]status.Entry = .{
        .{ .path = "m.txt", .original_path = null, .index = 'M', .worktree = 'M', .kind = .ordinary, .submodule = false },
        .{ .path = "a.txt", .original_path = null, .index = 'A', .worktree = '.', .kind = .ordinary, .submodule = false },
        .{ .path = "d.txt", .original_path = null, .index = '.', .worktree = 'D', .kind = .ordinary, .submodule = false },
        .{ .path = "u.txt", .original_path = null, .index = '?', .worktree = '?', .kind = .untracked, .submodule = false },
        .{ .path = "c.txt", .original_path = null, .index = 'U', .worktree = 'U', .kind = .unmerged, .submodule = false },
        .{ .path = "z.txt", .original_path = null, .index = '.', .worktree = 'M', .kind = .ordinary, .submodule = false },
    };
    snapshot.entries = &entries;
    defer snapshot.deinit();
    panel.snapshot = snapshot;
    try panel.rebuildDisplay();
    // MM appears in both sections; conflicts stay visible under Unstaged.
    try t.expectEqualSlices(usize, &.{ 1, 0 }, panel.staged.items);
    try t.expectEqualSlices(usize, &.{ 4, 2, 0, 5 }, panel.unstaged.items);
    try t.expectEqualSlices(usize, &.{3}, panel.untracked.items);
    try t.expectEqual(@as(usize, 1), panel.unmerged_count);
    try t.expectEqual(@as(usize, 7), panel.display.items.len);
    try t.expectEqual(Section.staged, panel.display.items[0].section);
    try t.expectEqual(Section.unstaged, panel.display.items[2].section);
    try t.expectEqual(Section.untracked, panel.display.items[6].section);
    // Paging is bounded to 128 file rows regardless of entry count.
    try t.expectEqual(@as(usize, 128), page_rows);
    try t.expectEqual(@as(usize, 10_000), max_entries);
}

const TestFixture = struct {
    root: [:0]u8,
    gitdir: [:0]u8,
    fd: c_int,
    cancel: commit.Cancel = .init(false),
    env: []commit.Environment,

    fn init() !TestFixture {
        var template = "/tmp/coral-panel-test-XXXXXX".* ++ [_]u8{0};
        if (os.mkdtemp(&template) == null) return error.FixtureFailed;
        errdefer _ = os.rmdir(&template);
        const root = try t.allocator.dupeSentinel(u8, std.mem.sliceTo(&template, 0), 0);
        errdefer t.allocator.free(root);
        const gitdir = try std.fmt.allocPrintSentinel(t.allocator, "{s}/.git", .{root}, 0);
        errdefer t.allocator.free(gitdir);
        const fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC);
        if (fd < 0) return error.FixtureFailed;
        errdefer {
            removeChildren(fd);
            _ = os.close(fd);
        }
        const environment = try hermeticEnv(root);
        errdefer freeEnv(environment);
        var f = TestFixture{ .root = root, .gitdir = gitdir, .fd = fd, .env = environment };
        try f.git(&.{ "init", "-q", "--initial-branch=main" });
        try f.git(&.{ "config", "user.name", "Coral fixture" });
        try f.git(&.{ "config", "user.email", "coral-fixture@invalid" });
        try f.git(&.{ "config", "commit.gpgsign", "false" });
        return f;
    }
    fn deinit(f: *TestFixture) void {
        removeChildren(f.fd);
        _ = os.close(f.fd);
        _ = os.rmdir(f.root);
        freeEnv(f.env);
        t.allocator.free(f.gitdir);
        t.allocator.free(f.root);
    }
    fn outputAllow(f: *TestFixture, args: []const []const u8, allow_one: bool) ![]const u8 {
        const r = try tx.runGit(t.allocator, f.root, null, null, null, null, &f.cancel, args, "", capture_bytes, allow_one);
        return r.bytes;
    }
    fn git(f: *TestFixture, args: []const []const u8) !void {
        const bytes = try f.outputAllow(args, false);
        t.allocator.free(bytes);
    }
    fn write(f: *TestFixture, name: [:0]const u8, bytes: []const u8) !void {
        const fd = os.openat(f.fd, name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC | os.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.FixtureFailed;
        defer _ = os.close(fd);
        if (os.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.FixtureFailed;
    }
    fn snapshot(f: *TestFixture) !status.Snapshot {
        const bytes = try f.outputAllow(command.status_args, false);
        defer t.allocator.free(bytes);
        return status.parse(t.allocator, bytes);
    }
    fn head(f: *TestFixture) !?[]const u8 {
        return commit.headOid(t.allocator, f.root, &f.cancel);
    }
    fn baseline(f: *TestFixture) !void {
        try f.write("tracked", "one\n");
        try f.write("other", "two\n");
        try f.git(&.{ "add", "--", "tracked", "other" });
        const policy = commit.WritePolicy{ .prefix = env.write_prefix, .environment = f.env };
        try commit.applyCommit(t.allocator, f.root, &f.cancel, policy, "fixture baseline");
    }
    /// Mirror of the panel's section classification for reviewed path sets.
    fn sectionPaths(snap: *const status.Snapshot, section: Section) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(t.allocator);
        for (snap.entries) |entry| {
            const include = switch (section) {
                .staged => (entry.kind == .ordinary or entry.kind == .rename) and entry.index != '.',
                .unstaged => ((entry.kind == .ordinary or entry.kind == .rename) and entry.worktree != '.') or entry.kind == .unmerged,
                .untracked => entry.kind == .untracked,
            };
            if (include) try list.append(t.allocator, entry.path);
        }
        std.mem.sort([]const u8, list.items, {}, lessThanSlice);
        return list.toOwnedSlice(t.allocator);
    }
    fn worker(f: *TestFixture, kind: WriteKind, args: []const []const u8, paths: []const []const u8, expected_head: ?[]const u8) Worker {
        // perform/recheck never dereference the controller; GTK admission is
        // exercised by the parent's widget acceptance, not this backend test.
        return .{
            .controller = undefined,
            .kind = kind,
            .root = f.root,
            .gitdir = f.gitdir,
            .args = args,
            .paths = paths,
            .expected_head = expected_head,
            .environment = f.env,
        };
    }
};
fn hermeticEnv(root: []const u8) ![]commit.Environment {
    var list: std.ArrayList(commit.Environment) = .empty;
    errdefer list.deinit(t.allocator);
    const entries = [_]commit.Environment{
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
        .{ .name = "HOME", .value = root },
        .{ .name = "LC_ALL", .value = "C" },
        .{ .name = "LANG", .value = "C" },
        .{ .name = "TZ", .value = "UTC" },
        .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" },
        .{ .name = "GIT_CONFIG_SYSTEM", .value = "/dev/null" },
        .{ .name = "GIT_CONFIG_GLOBAL", .value = "/dev/null" },
        .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
        .{ .name = "GIT_EDITOR", .value = "true" },
        .{ .name = "GIT_NO_REPLACE_OBJECTS", .value = "1" },
    };
    for (entries) |e| try list.append(t.allocator, .{ .name = e.name, .value = try t.allocator.dupe(u8, e.value) });
    return list.toOwnedSlice(t.allocator);
}
fn freeEnv(environment: []commit.Environment) void {
    for (environment) |e| t.allocator.free(e.value);
    t.allocator.free(environment);
}
fn removeChildren(fd: c_int) void {
    const dir = os.fdopendir(os.dup(fd)) orelse return;
    defer _ = os.closedir(dir);
    while (os.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = os.openat(fd, name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC);
        if (child >= 0) {
            removeChildren(child);
            _ = os.close(child);
            _ = os.unlinkat(fd, name, os.AT_REMOVEDIR);
        } else _ = os.unlinkat(fd, name, 0);
    }
}

test "panel worker applies reviewed section argv and refuses stale or conflicted reviews" {
    var f = try TestFixture.init();
    defer f.deinit();
    try f.baseline();
    const head = (try f.head()).?;
    defer t.allocator.free(head);

    // tracked: unstaged modification; staged: newly added; untracked: new file.
    try f.write("tracked", "changed\n");
    try f.write("staged", "new\n");
    try f.git(&.{ "add", "--", "staged" });
    try f.write("untracked", "new\n");

    var snap = try f.snapshot();
    defer snap.deinit();
    const unstaged = try TestFixture.sectionPaths(&snap, .unstaged);
    defer t.allocator.free(unstaged);
    const staged = try TestFixture.sectionPaths(&snap, .staged);
    defer t.allocator.free(staged);
    const untracked = try TestFixture.sectionPaths(&snap, .untracked);
    defer t.allocator.free(untracked);
    try t.expectEqualStrings("tracked", unstaged[0]);
    try t.expectEqualStrings("staged", staged[0]);
    try t.expectEqualStrings("untracked", untracked[0]);

    // A stale review (target set changed on disk) must refuse before writing.
    var stale = TestFixture.worker(&f, .stage_unstaged, &.{ "add", "-u", "--" }, unstaged, head);
    try f.write("other", "external change\n");
    try t.expectError(error.StaleSnapshot, stale.perform());
    try t.expect(!stale.committed);
    // A moved HEAD must refuse as well.
    var wrong_head = TestFixture.worker(&f, .stage_unstaged, &.{ "add", "-u", "--" }, unstaged, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try t.expectError(error.StaleSnapshot, wrong_head.perform());

    // Restore the reviewed state, then stage all tracked unstaged changes.
    try f.write("other", "two\n");
    var stage_unstaged = TestFixture.worker(&f, .stage_unstaged, &.{ "add", "-u", "--" }, unstaged, head);
    try stage_unstaged.perform();
    try t.expect(stage_unstaged.committed);
    var after = try f.snapshot();
    defer after.deinit();
    for (after.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "tracked")) try t.expectEqual(@as(u8, 'M'), entry.index);
        if (std.mem.eql(u8, entry.path, "tracked")) try t.expectEqual(@as(u8, '.'), entry.worktree);
        if (std.mem.eql(u8, entry.path, "untracked")) try t.expectEqual(@as(u8, '?'), entry.index);
    }

    // Unstage all: whole-index reset, reviewed staged set rechecked exactly.
    const staged_now = try TestFixture.sectionPaths(&after, .staged);
    defer t.allocator.free(staged_now);
    try t.expectEqual(@as(usize, 2), staged_now.len);
    var unstage = TestFixture.worker(&f, .unstage_staged, &.{ "reset", "--" }, staged_now, head);
    try unstage.perform();
    var reset = try f.snapshot();
    defer reset.deinit();
    const staged_after_reset = try TestFixture.sectionPaths(&reset, .staged);
    defer t.allocator.free(staged_after_reset);
    try t.expectEqual(@as(usize, 0), staged_after_reset.len);
    for (reset.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "tracked")) try t.expectEqual(@as(u8, 'M'), entry.worktree);
    }

    // Stage all untracked with explicit paths, then unstage one selected path.
    const untracked_now = try TestFixture.sectionPaths(&reset, .untracked);
    defer t.allocator.free(untracked_now);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(t.allocator);
    try args.appendSlice(t.allocator, &.{ "add", "--" });
    for (untracked_now) |path| try args.append(t.allocator, path);
    var stage_untracked = TestFixture.worker(&f, .stage_untracked, args.items, untracked_now, head);
    try stage_untracked.perform();
    var added = try f.snapshot();
    defer added.deinit();
    const untracked_after_add = try TestFixture.sectionPaths(&added, .untracked);
    defer t.allocator.free(untracked_after_add);
    try t.expectEqual(@as(usize, 0), untracked_after_add.len);
    var unstage_selected = TestFixture.worker(&f, .unstage_selected, &.{ "reset", "--", "untracked" }, &.{"untracked"}, head);
    try unstage_selected.perform();
    var selected = try f.snapshot();
    defer selected.deinit();
    const untracked_again = try TestFixture.sectionPaths(&selected, .untracked);
    defer t.allocator.free(untracked_again);
    try t.expectEqual(@as(usize, 1), untracked_again.len);
    try t.expectEqualStrings("untracked", untracked_again[0]);

    // Conflicts refuse every write: divergent merge leaves an unmerged entry.
    try f.git(&.{ "checkout", "-q", "-b", "side" });
    try f.write("tracked", "side\n");
    try f.git(&.{ "add", "--", "tracked" });
    const policy = commit.WritePolicy{ .prefix = env.write_prefix, .environment = f.env };
    try commit.applyCommit(t.allocator, f.root, &f.cancel, policy, "side");
    try f.git(&.{ "checkout", "-q", "main" });
    try f.write("tracked", "main\n");
    try f.git(&.{ "add", "--", "tracked" });
    try commit.applyCommit(t.allocator, f.root, &f.cancel, policy, "main");
    const head_main = (try f.head()).?;
    defer t.allocator.free(head_main);
    const merge = try f.outputAllow(&.{ "merge", "side" }, true);
    t.allocator.free(merge);
    var conflicted = try f.snapshot();
    defer conflicted.deinit();
    var conflict_unmerged = false;
    for (conflicted.entries) |entry| {
        if (entry.kind == .unmerged) conflict_unmerged = true;
    }
    try t.expect(conflict_unmerged);
    var refused = TestFixture.worker(&f, .stage_unstaged, &.{ "add", "-u", "--" }, &.{"tracked"}, head_main);
    try t.expectError(error.UnmergedConflict, refused.perform());
    try t.expect(!refused.committed);
}
