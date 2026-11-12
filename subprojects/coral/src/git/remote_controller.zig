//! M4 native remote workflows: list remotes and explicitly approved
//! fetch/pull/push (including a distinct force-with-lease confirmation).
//!
//! This controller never runs Git on its own authority: it requires the parent
//! Source Control disclosure (app.git.valid()) and a selected repository
//! (app.git.repo()). Inspection uses command.zig's locked-down read-only policy;
//! fetch/pull/push use env.zig's network prefix/environment ONLY after a separate
//! credential-helper disclosure, because those helpers may execute programs and
//! access secrets. Push is never backgrounded. One active job per controller;
//! App.hold keeps it alive until every cancelled job is reaped.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const command = @import("command.zig");
const env = @import("env.zig");
const remote = @import("remote.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = 1024 * 1024;
pub const inspect_timeout_ms = 15_000;
pub const network_timeout_ms = 120_000;
const output_budget = 64 * 1024;

const Phase = enum { remotes, branch, upstream, fetch, pull, push };
const Intent = enum { none, remotes, fetch, pull, push };
const Policy = enum { inspect, network };
const Op = enum { fetch, pull, push, force_push };

const network_disclosure =
    "This Git network operation runs /usr/bin/git as your user, in addition to the Source Control disclosure. " ++
    "Unlike read-only inspection it uses your Git identity and configured credential/askpass helpers, which may " ++
    "execute programs and access secrets (tokens, SSH keys). It contacts the configured remote and transfers " ++
    "repository data. Repository-local configuration and hooks can still have side effects. This is NOT a sandbox.";
const force_disclosure =
    "Force push with lease updates the remote ref only if it still matches the value your repository last fetched " ++
    "(--force-with-lease). If someone else pushed since, Git refuses. This can still discard remote commits that your " ++
    "lease knows about. Coral never uses plain --force. Confirm this force push explicitly.";

fn opDisclosure(op: Op) []const u8 {
    return switch (op) {
        .fetch => network_disclosure ++ "\n\nFetch downloads objects and updates remote-tracking refs; it does not change your working tree.",
        .pull => network_disclosure ++ "\n\nPull also writes your working tree and HEAD using the selected mode (ff-only by default; merge/rebase are explicit). ff-only refuses non-fast-forward updates.",
        .push => network_disclosure ++ "\n\nPush publishes your local commits to the selected remote.",
        .force_push => network_disclosure ++ "\n\nForce push may overwrite remote refs. A separate confirmation follows; Coral uses --force-with-lease.",
    };
}

fn scopeFor(phase: Phase) []const u8 {
    return switch (phase) {
        .remotes => "git-remote/remotes",
        .branch => "git-remote/branch",
        .upstream => "git-remote/upstream",
        .fetch => "git-remote/fetch",
        .pull => "git-remote/pull",
        .push => "git-remote/push",
    };
}

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .remotes,
    pending: Intent = .none,
    window: ?u.W = null,
    picker: ?u.W = null,
    mode_picker: ?u.W = null,
    upstream_check: ?u.W = null,
    summary: ?u.W = null,
    output_label: ?u.W = null,
    output_view: ?u.W = null,
    fetch_button: ?u.W = null,
    pull_button: ?u.W = null,
    push_button: ?u.W = null,
    force_button: ?u.W = null,
    rebuilding: bool = false,
    message_text: [:0]u8,
    output_text: [:0]u8,
    output_kind: []const u8 = "none",
    remotes: ?remote.RemoteList = null,
    selected_remote: ?usize = null,
    branch: ?[]const u8 = null,
    upstream: ?remote.Upstream = null,
    pull_mode: remote.PullMode = .ff_only,
    push_force: bool = false,
    push_set_upstream: bool = false,
    network_approval: UI,
    force_approval: UI,
    pending_op: ?Op = null,
    /// Resolved target captured when the disclosure is shown, so the approved
    /// action launches exactly the remote/refspec the user consented to.
    op_remote: ?[]const u8 = null,
    op_ref: ?[]const u8 = null,
    barrier_held: bool = false,
    launches: u64 = 0,
    discarded: u64 = 0,
    jobs_reaped: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .network_approval = .{ .context = app, .respond = &networkAnswered },
            .force_approval = .{ .context = app, .respond = &forceAnswered },
            .message_text = u.z("Remotes — open Source Control first"),
            .output_text = u.z(""),
        };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.arena.deinit();
        a.free(self.message_text);
        a.free(self.output_text);
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null;
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.pending_op = null;
        self.network_approval.close();
        self.force_approval.close();
        self.closeWindow();
        self.clearModel();
        self.setOutput("none", "");
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Git remote generation exhausted");
        self.pending = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearModel(self: *Controller) void {
        self.selected_remote = null;
        self.branch = null;
        self.upstream = null;
        self.op_remote = null;
        self.op_ref = null;
        if (self.remotes) |*list| list.deinit();
        self.remotes = null;
        _ = self.arena.reset(.free_all);
        self.renderRemotes();
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        self.pending = .none;
        const hint = switch (err) {
            error.OperationPending, error.FileOperationBusy, error.WorkspaceBusy, error.DialogPending, error.OpenDocument, error.RootMutation, error.ProtectedManifest, error.NoManager => " A workspace file operation or open document conflicts; retry after it finishes.",
            else => "",
        };
        const text = u.fmt("Git remote: {s}.{s} Refresh to try again.", .{ @errorName(err), hint });
        defer a.free(text);
        self.message(text);
    }
    fn setOutput(self: *Controller, kind: []const u8, text: []const u8) void {
        self.output_kind = kind;
        a.free(self.output_text);
        self.output_text = u.z(text);
        if (self.output_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.output_text.ptr, @intCast(self.output_text.len));
        if (self.output_label) |label| u.setLabel(label, "Git output (stdout/stderr, read-only)");
    }
    /// Source Control disclosure + a selected repository are prerequisites.
    fn ready(self: *Controller) bool {
        return !self.app.closing and self.app.git.valid() and self.app.git.repo() != null;
    }

    pub fn showRemotes(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            // Require the parent Source Control disclosure; never bypass it.
            self.app.git.show();
            return;
        }
        if (self.window) |window| {
            if (!self.ready()) {
                self.invalidate();
            } else {
                c.gtk_window_present(u.cast(c.GtkWindow, window));
                return;
            }
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository before managing remotes.");
            return;
        }
        self.createWindow();
        self.refreshRemotes();
    }
    pub fn refreshRemotes(self: *Controller) void {
        if (!self.ready()) {
            self.showRemotes();
            return;
        }
        self.cancel();
        self.clearModel();
        self.message("Reading remotes — read-only; no network…");
        self.setOutput("none", "Remotes load from local configuration only.");
        self.pending = .remotes;
        self.drain();
    }
    fn drain(self: *Controller) void {
        defer self.updateActions();
        if (self.job != null or self.pending == .none) return;
        const intent = self.pending;
        self.pending = .none;
        if (!self.ready()) {
            self.invalidate();
            return;
        }
        switch (intent) {
            .remotes => self.startRemotes() catch |err| self.failure(err),
            .fetch => self.startFetch() catch |err| self.failure(err),
            .pull => self.startPull() catch |err| self.failure(err),
            .push => self.startPush() catch |err| self.failure(err),
            .none => {},
        }
    }
    fn startRemotes(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        try self.launch(.remotes, repository.path, remote.listArgs(), 65536, .inspect, inspect_timeout_ms);
    }
    fn startBranch(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        try self.launch(.branch, repository.path, remote.branchArgs(), 16384, .inspect, inspect_timeout_ms);
    }
    fn startUpstream(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        try self.launch(.upstream, repository.path, remote.upstreamArgs(), 16384, .inspect, inspect_timeout_ms);
    }
    fn targetRemote(self: *Controller) []const u8 {
        if (self.selected_remote) |index| {
            if (self.remotes) |list| {
                if (index < list.remotes.len) return list.remotes[index].name;
            }
        }
        if (self.upstream) |up| return up.remote;
        return "origin";
    }
    /// Pull may follow the configured upstream branch; push never uses this.
    fn pullBranch(self: *Controller) ?[]const u8 {
        if (self.upstream) |up| return up.branch;
        return self.branch;
    }
    fn startFetch(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const name = self.op_remote orelse self.targetRemote();
        const args = try remote.fetchArgs(a, name, null);
        defer a.free(args);
        self.message("Fetching — credential helpers may run…");
        // Fetch is ref-only: it never rewrites the worktree or HEAD, so it does
        // not take the file-operation barrier.
        try self.launch(.fetch, repository.path, args, capture_bytes, .network, network_timeout_ms);
    }
    fn startPull(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const name = self.op_remote orelse self.targetRemote();
        const branch = self.op_ref orelse self.pullBranch() orelse return error.NoBranch;
        // Pull rewrites the worktree and HEAD: hold the Manager file-operation
        // barrier for the whole async job, released on completion/cancel.
        try self.acquireBarrier(repository.gitdir);
        errdefer self.releaseBarrier();
        const args = try remote.pullArgs(a, name, branch, self.pull_mode);
        defer a.free(args);
        self.message("Pulling — credential helpers may run; working tree may change…");
        try self.launch(.pull, repository.path, args, capture_bytes, .network, network_timeout_ms);
    }
    fn startPush(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const name = self.op_remote orelse self.targetRemote();
        const refspec = self.op_ref orelse return error.NoBranch;
        // Push publishes refs and may run hooks; serialize it against file work.
        try self.acquireBarrier(repository.gitdir);
        errdefer self.releaseBarrier();
        const args = try remote.pushArgs(a, name, refspec, .{ .force = self.push_force, .set_upstream = self.push_set_upstream });
        defer a.free(args);
        self.message(if (self.push_force) "Force pushing with lease…" else "Pushing — credential helpers may run…");
        try self.launch(.push, repository.path, args, capture_bytes, .network, network_timeout_ms);
    }
    /// Hold the Manager file-operation barrier scoped to this repository. The
    /// admission source is a git-dir path (like the other Git write controllers):
    /// checkFileOperation rejects a worktree-root source as RootMutation and any
    /// open document beneath it, yet the barrier still serializes against every
    /// window's saves/renames while the network write runs. No-op for test Apps
    /// without a manager.
    fn acquireBarrier(self: *Controller, gitdir: []const u8) !void {
        const manager = self.app.manager orelse return;
        const source = try std.fmt.allocPrint(a, "{s}/HEAD", .{gitdir});
        defer a.free(source);
        try manager.beginFileOperation(self.app, source, "");
        self.barrier_held = true;
    }
    fn releaseBarrier(self: *Controller) void {
        if (!self.barrier_held) return;
        self.barrier_held = false;
        if (self.app.manager) |manager| manager.endFileOperation(self.app);
    }

    fn launch(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize, policy: Policy, timeout_ms: u32) !void {
        if (!self.ready()) return error.Restricted;
        if (self.job != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        const prefix = switch (policy) {
            .inspect => command.prefix,
            .network => env.network_prefix,
        };
        if (prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..prefix.len], prefix);
        @memcpy(argv[prefix.len..][0..args.len], args);
        const token = self.app.workspace.capture() orelse return error.Closed;
        self.phase = phase;
        const identity: process.Identity = .{ .scope = scopeFor(phase), .request = self.launches + 1, .generation = self.generation, .workspace = token };
        self.job = switch (policy) {
            .inspect => blk: {
                var environment: [command.environment.len]process.Environment = undefined;
                for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
                break :blk try process.start(a, .{
                    .owner = &self.supervisor,
                    .authorization = .approved,
                    .identity = identity,
                    .argv = argv[0 .. prefix.len + args.len],
                    .cwd = cwd,
                    .environment = &environment,
                    .output_limit = limit,
                    .timeout_ms = timeout_ms,
                }, &completed, self);
            },
            .network => blk: {
                const environment = try env.network(a);
                defer a.free(environment);
                break :blk try process.start(a, .{
                    .owner = &self.supervisor,
                    .authorization = .approved,
                    .identity = identity,
                    .argv = argv[0 .. prefix.len + args.len],
                    .cwd = cwd,
                    .environment = environment,
                    .output_limit = limit,
                    .timeout_ms = timeout_ms,
                }, &completed, self);
            },
        };
        self.launches += 1;
        self.app.hold();
        self.updateActions();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        defer self.app.release();
        defer job.destroy();
        defer self.releaseBarrier();
        std.debug.assert(self.job == job);
        self.job = null;
        self.jobs_reaped += 1;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            self.warnAttemptedWrite(result);
            self.drain();
            return;
        }
        if (!self.ready() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.warnAttemptedWrite(result);
            self.invalidate();
            return;
        }
        self.receive(result) catch |err| self.failure(err);
    }
    /// A cancelled/superseded network WRITE may leave partial state even though
    /// its result is generation-discarded. Surface a warning through the global
    /// notice (the controller window may already be closed) and refresh Source
    /// Control while it is still valid. Read-only fetch/inspection is ignored.
    fn warnAttemptedWrite(self: *Controller, result: process.Result) void {
        const is_write = std.mem.eql(u8, result.identity.scope, scopeFor(.pull)) or
            std.mem.eql(u8, result.identity.scope, scopeFor(.push));
        if (!is_write or result.outcome == .spawn_failed) return;
        if (result.outcome != .success) {
            self.app.message("A Git pull/push was interrupted; the repository or remote may be partially updated. Source Control was refreshed — inspect before retrying.");
        }
        if (self.app.git.valid()) self.app.git.refresh();
    }
    fn receive(self: *Controller, result: process.Result) !void {
        switch (self.phase) {
            .remotes => {
                if (result.outcome != .success) return self.operationFailure("remote list", result);
                const list = try remote.parseRemotes(a, result.stdout);
                if (self.remotes) |*old| old.deinit();
                self.remotes = list;
                self.selected_remote = if (list.remotes.len > 0) 0 else null;
                self.renderRemotes();
                try self.startBranch();
            },
            .branch => {
                if (result.outcome == .success) {
                    const parsed = try remote.parseBranch(result.stdout);
                    self.branch = try self.arena.allocator().dupe(u8, parsed);
                } else self.branch = null;
                try self.startUpstream();
            },
            .upstream => {
                if (result.outcome == .success) {
                    self.upstream = remote.parseUpstreamRef(self.arena.allocator(), result.stdout) catch null;
                } else self.upstream = null;
                self.updateSummary();
            },
            .fetch => self.receiveNetwork("Fetch", result),
            .pull => {
                self.receiveNetwork("Pull", result);
                if (result.outcome == .success) {
                    self.message("Pull complete. Source Control status was refreshed.");
                    if (self.app.git.valid()) self.app.git.refresh();
                }
            },
            .push => self.receiveNetwork("Push", result),
        }
    }
    fn operationFailure(self: *Controller, verb: []const u8, result: process.Result) void {
        const text = u.fmt("Git {s}: {s} (exit {d}). No partial result is shown.", .{ verb, @tagName(result.outcome), result.exit_code orelse -1 });
        defer a.free(text);
        self.message(text);
        self.setNetworkOutput("error", result);
    }
    fn receiveNetwork(self: *Controller, verb: []const u8, result: process.Result) void {
        switch (result.outcome) {
            .cancelled => {
                const text = u.fmt("{s} cancelled.", .{verb});
                defer a.free(text);
                self.message(text);
                self.setOutput("cancelled", "Cancelled. The remote or working tree may have partially updated; inspect before retrying.");
                if ((self.phase == .pull or self.phase == .push) and self.app.git.valid()) self.app.git.refresh();
                return;
            },
            .success => {
                const text = u.fmt("{s} complete.", .{verb});
                defer a.free(text);
                self.message(text);
                self.setNetworkOutput("text", result);
            },
            else => {
                const text = u.fmt("{s} failed ({s}, exit {d}). Git reports authentication/signing errors on stderr below.", .{ verb, @tagName(result.outcome), result.exit_code orelse -1 });
                defer a.free(text);
                self.message(text);
                self.setNetworkOutput("error", result);
            },
        }
    }
    /// Bounded, control-sanitized stdout/stderr for the read-only output view.
    fn setNetworkOutput(self: *Controller, kind: []const u8, result: process.Result) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        appendSanitized(&out, "stderr:\n", output_budget) catch {};
        appendSanitized(&out, result.stderr, output_budget) catch {};
        appendSanitized(&out, "\nstdout:\n", output_budget) catch {};
        appendSanitized(&out, result.stdout, output_budget) catch {};
        self.setOutput(kind, out.items);
    }

    pub fn showFetch(self: *Controller) void {
        self.requestNetwork(.fetch);
    }
    pub fn showPull(self: *Controller) void {
        self.requestNetwork(.pull);
    }
    pub fn showPush(self: *Controller) void {
        self.requestNetwork(.push);
    }
    pub fn showForcePush(self: *Controller) void {
        self.requestNetwork(.force_push);
    }
    fn requestNetwork(self: *Controller, op: Op) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository first.");
            return;
        }
        if (self.job != null or self.pending != .none) {
            self.message("Wait for the current Git request to finish before another network operation.");
            return;
        }
        if (self.remotes == null) {
            self.message("Refresh remotes before a network operation.");
            return;
        }
        const is_write = op == .pull or op == .push or op == .force_push;
        if (is_write and self.app.fileOperationBarrier()) {
            self.message("A workspace file operation is applying. Retry after it finishes.");
            return;
        }
        // Resolve and freeze the exact target so the disclosure shows precisely
        // what will run and the approved launch cannot drift to another ref.
        const ar = self.arena.allocator();
        const remote_name = self.targetRemote();
        var ref: []const u8 = "";
        const detail: [:0]u8 = switch (op) {
            .fetch => u.fmt("Remote: {s}. Downloads refs into remote-tracking branches; the working tree and HEAD are unchanged.", .{remote_name}),
            .pull => blk: {
                const branch = self.pullBranch() orelse {
                    self.message("No branch is available to pull. Check out a branch first.");
                    return;
                };
                ref = branch;
                break :blk u.fmt("Remote: {s} · branch: {s} · mode: {s}. Rewrites the working tree and HEAD.", .{ remote_name, branch, @tagName(self.pull_mode) });
            },
            .push, .force_push => blk: {
                const refspec = remote.pushRefspec(ar, self.branch) catch |err| {
                    self.message(switch (err) {
                        error.DetachedHead => "Cannot push: detached HEAD. Check out a local branch first.",
                        error.UnbornHead => "Cannot push: unborn HEAD (no commits yet). Create a commit first.",
                        error.InvalidBranch => "Cannot push: the current branch name is not a valid ref.",
                        error.OutOfMemory => "Cannot push: out of memory.",
                    });
                    return;
                };
                ref = refspec;
                break :blk u.fmt("Remote: {s} · refspec: {s} (current local branch {s}).", .{ remote_name, refspec, self.branch.? });
            },
        };
        defer a.free(detail);
        self.op_remote = ar.dupe(u8, remote_name) catch {
            self.message("Out of memory.");
            return;
        };
        self.op_ref = ar.dupe(u8, ref) catch {
            self.message("Out of memory.");
            return;
        };
        self.pending_op = op;
        self.network_approval.context = self;
        const accept: [:0]const u8 = switch (op) {
            .fetch => "Fetch",
            .pull => "Pull",
            .push => "Push",
            .force_push => "Continue to force-push review",
        };
        const body = u.fmt("{s}\n\n{s}", .{ opDisclosure(op), detail });
        defer a.free(body);
        self.network_approval.show(self.app, "Git network — credential disclosure", body, &.{}, false, accept);
    }
    fn networkAnswered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        const op = self.pending_op orelse return;
        self.pending_op = null;
        if (!accepted or self.app.closing or !self.ready()) return;
        if (op == .force_push) {
            // Distinct, explicit force-push confirmation after the network
            // disclosure, naming the exact remote and refspec to be overwritten.
            self.force_approval.context = self;
            const detail = u.fmt("Remote: {s} · refspec: {s}.", .{ self.op_remote orelse "?", self.op_ref orelse "?" });
            defer a.free(detail);
            const body = u.fmt("{s}\n\n{s}", .{ force_disclosure, detail });
            defer a.free(body);
            self.force_approval.show(self.app, "Force push — distinct confirmation", body, &.{}, false, "Force push with lease");
            return;
        }
        self.beginOp(op);
    }
    fn forceAnswered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        if (!accepted or self.app.closing or !self.ready()) return;
        self.beginOp(.force_push);
    }
    fn beginOp(self: *Controller, op: Op) void {
        self.cancel();
        self.push_force = op == .force_push;
        self.pending = switch (op) {
            .fetch => .fetch,
            .pull => .pull,
            .push, .force_push => .push,
        };
        self.setOutput("loading", "Running Git network operation…");
        self.drain();
    }

    fn updateActions(self: *Controller) void {
        const enabled = self.ready() and self.job == null and self.pending == .none and self.remotes != null;
        const push_ok = self.branch != null and !std.mem.eql(u8, self.branch.?, "HEAD");
        if (self.fetch_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled));
        if (self.pull_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and self.pullBranch() != null));
        if (self.push_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and push_ok));
        if (self.force_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and push_ok));
    }
    fn updateSummary(self: *Controller) void {
        const branch = self.branch orelse "(detached/unborn)";
        const up_remote = if (self.upstream) |up| up.remote else "none";
        const up_branch = if (self.upstream) |up| up.branch else "none";
        const count = if (self.remotes) |list| list.remotes.len else 0;
        const text = u.fmt("{d} remotes · branch {s} · upstream {s}/{s} · pull mode {s}. Network operations require a separate credential disclosure; push is explicit only.", .{ count, branch, up_remote, up_branch, @tagName(self.pull_mode) });
        defer a.free(text);
        self.message(text);
        self.updateActions();
    }
    fn selectRemote(self: *Controller, index: usize) void {
        if (self.remotes) |list| {
            if (index < list.remotes.len) {
                self.selected_remote = index;
                self.updateSummary();
            }
        }
    }

    fn createWindow(self: *Controller) void {
        if (self.window != null) return;
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Source Control — remotes, fetch/pull/push");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 900, 680);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const bar = u.box(true, 8);
        u.append(box, bar);
        u.append(bar, u.label("Remote"));
        const picker = c.gtk_combo_box_text_new().?;
        self.picker = picker;
        c.gtk_widget_set_hexpand(picker, 1);
        u.append(bar, picker);
        u.connect(picker, "changed", &remoteChanged, self);
        const refresh = u.button("Refresh remotes");
        u.append(bar, refresh);
        u.connect(refresh, "clicked", &refreshClicked, self);
        const options = u.box(true, 8);
        u.append(box, options);
        u.append(options, u.label("Pull mode"));
        const mode = c.gtk_combo_box_text_new().?;
        self.mode_picker = mode;
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "ff-only (default)");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "merge");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "rebase");
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, mode), 0);
        u.append(options, mode);
        u.connect(mode, "changed", &modeChanged, self);
        const upstream = c.gtk_check_button_new_with_label("Push: set upstream (-u)");
        self.upstream_check = upstream;
        u.append(options, upstream);
        u.connect(upstream, "toggled", &upstreamToggled, self);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const actions = u.box(true, 8);
        u.append(box, actions);
        const fetch = u.button("Fetch…");
        const pull = u.button("Pull…");
        const push = u.button("Push…");
        const force = u.button("Force push (with lease)…");
        self.fetch_button = fetch;
        self.pull_button = pull;
        self.push_button = push;
        self.force_button = force;
        u.append(actions, fetch);
        u.append(actions, pull);
        u.append(actions, push);
        u.append(actions, force);
        u.connect(fetch, "clicked", &fetchClicked, self);
        u.connect(pull, "clicked", &pullClicked, self);
        u.connect(push, "clicked", &pushClicked, self);
        u.connect(force, "clicked", &forceClicked, self);
        const output_label = u.label("Git output (stdout/stderr, read-only)");
        self.output_label = output_label;
        u.append(box, output_label);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        const view = c.gtk_text_view_new().?;
        self.output_view = view;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view);
        u.append(box, scroll);
        self.app.styleWindow(window);
        self.app.installTestKeys(window);
        self.updateActions();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.picker = null;
        self.mode_picker = null;
        self.upstream_check = null;
        self.summary = null;
        self.output_label = null;
        self.output_view = null;
        self.fetch_button = null;
        self.pull_button = null;
        self.push_button = null;
        self.force_button = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn renderRemotes(self: *Controller) void {
        const picker = self.picker orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        c.gtk_combo_box_text_remove_all(u.cast(c.GtkComboBoxText, picker));
        if (self.remotes) |list| {
            for (list.remotes) |entry| {
                const name = command.display(a, entry.name, 256) catch unreachable;
                defer a.free(name);
                const url = command.display(a, entry.fetch_url, 512) catch unreachable;
                defer a.free(url);
                const text = u.fmt("{s}  {s}", .{ name, url });
                defer a.free(text);
                c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, picker), text);
            }
        }
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, picker), if (self.selected_remote) |index| @intCast(index) else -1);
    }
    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn remoteChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const index = c.gtk_combo_box_get_active(picker);
        if (index >= 0) self.selectRemote(@intCast(index));
    }
    fn modeChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const index = c.gtk_combo_box_get_active(picker);
        self.pull_mode = switch (index) {
            1 => .merge,
            2 => .rebase,
            else => .ff_only,
        };
        self.updateSummary();
    }
    fn upstreamToggled(button: ?*c.GtkCheckButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        self.push_set_upstream = c.gtk_check_button_get_active(button) != 0;
    }
    fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).refreshRemotes();
    }
    fn fetchClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showFetch();
    }
    fn pullClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showPull();
    }
    fn pushClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showPush();
    }
    fn forceClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showForcePush();
    }

    /// Test-only bridge. Approval answers the actual disclosure dialogs; it never
    /// grants trust or bypasses the parent Source Control permit.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "git-remote-probe")) self.probe() else if (std.mem.eql(u8, action, "git-remote-accept")) self.network_approval.answer(true, null, "") else if (std.mem.eql(u8, action, "git-remote-reject")) self.network_approval.answer(false, null, "") else if (std.mem.eql(u8, action, "git-remote-force-accept")) self.force_approval.answer(true, null, "") else if (std.mem.eql(u8, action, "git-remote-force-reject")) self.force_approval.answer(false, null, "") else if (std.mem.eql(u8, action, "git-remote-close")) self.invalidate() else if (std.mem.eql(u8, action, "git-remote-refresh")) self.refreshRemotes() else if (std.mem.eql(u8, action, "git-remote-select")) self.selectRemote(std.fmt.parseInt(usize, value, 10) catch return true) else if (std.mem.eql(u8, action, "git-remote-mode")) {
            self.pull_mode = if (std.mem.eql(u8, value, "merge")) .merge else if (std.mem.eql(u8, value, "rebase")) .rebase else .ff_only;
        } else if (std.mem.eql(u8, action, "git-remote-upstream")) self.push_set_upstream = std.mem.eql(u8, value, "1") else if (std.mem.eql(u8, action, "git-remote-fetch")) self.showFetch() else if (std.mem.eql(u8, action, "git-remote-pull")) self.showPull() else if (std.mem.eql(u8, action, "git-remote-push")) self.showPush() else if (std.mem.eql(u8, action, "git-remote-force-push")) self.showForcePush() else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const RemoteProbe = struct { name: []const u8, fetch_url: []const u8, push_url: []const u8 };
        var remotes: [remote.max_remotes]RemoteProbe = undefined;
        var count: usize = 0;
        if (self.remotes) |list| {
            for (list.remotes) |entry| {
                remotes[count] = .{ .name = entry.name, .fetch_url = entry.fetch_url, .push_url = entry.push_url };
                count += 1;
            }
        }
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .visible = self.window != null,
            .git_valid = self.app.git.valid(),
            .generation = self.generation,
            .busy = self.job != null,
            .pending = @tagName(self.pending),
            .phase = if (self.job != null) @as(?[]const u8, @tagName(self.phase)) else null,
            .launches = self.launches,
            .discarded = self.discarded,
            .jobs_reaped = self.jobs_reaped,
            .remotes = remotes[0..count],
            .selected_remote = self.selected_remote,
            .branch = self.branch,
            .upstream_remote = if (self.upstream) |up| up.remote else null,
            .upstream_branch = if (self.upstream) |up| up.branch else null,
            .pull_mode = @tagName(self.pull_mode),
            .push_force = self.push_force,
            .push_set_upstream = self.push_set_upstream,
            .op_remote = self.op_remote,
            .op_ref = self.op_ref,
            .barrier_held = self.barrier_held,
            .network_disclosure = self.network_approval.window != null,
            .force_disclosure = self.force_approval.window != null,
            .output_kind = self.output_kind,
            .output = self.output_text,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_REMOTE %s\n", line.ptr);
    }
};

fn appendSanitized(out: *std.ArrayList(u8), bytes: []const u8, limit: usize) !void {
    for (bytes) |ch| {
        if (out.items.len >= limit) {
            try out.appendSlice(a, "...");
            return;
        }
        if (ch == '\n' or ch == '\t' or (ch >= 32 and ch != 127)) {
            try out.append(a, ch);
        } else try out.append(a, ' ');
    }
}
