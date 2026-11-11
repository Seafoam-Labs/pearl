//! First M4 increment: explicit, read-only native Source Control, not dock parity.
//! Parent owns App.git, .git trust capability, commands and lifecycle invalidation.
//! No startup work, watchers, saves, index mutation, network commands or checkout.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const trust = @import("../workspace/trust.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const UI = @import("../language/ui.zig").UI;
const RootId = @import("../workspace/model.zig").RootId;
pub const max_repositories = 8;
pub const max_entries = 10000;
pub const capture_bytes = 1024 * 1024;
pub const page_rows = 128;
const max_candidates = trust.limits.roots + 1;
const Candidate = struct { root: RootId, owner: []const u8, cwd: []const u8 };
const Repository = struct { root: RootId, owner: []const u8, path: []const u8, gitdir: []const u8 = "", commondir: []const u8 = "" };
const Phase = enum { version, root, gitdir, commondir, status, diff };
const Intent = enum { none, refresh, status, diff };
const disclosure =
    "Source Control runs /usr/bin/git as your user, only after you continue in a trusted workspace. " ++
    "It reads repository metadata, the index and files on disk. Unsaved editor buffers are excluded and are never saved.\n\n" ++
    "Coral requests no index writes, hooks or network access. System/global Git config, prompts, external diff and textconv are disabled. " ++
    "Repository-local Git configuration and clean filters can still execute programs with your user permissions. This is NOT a sandbox; such programs can have side effects.\n\n" ++
    "First M4 increment: explicit refresh only, at most 8 repositories, 1 MiB status capture / 10,000 entries, " ++
    "128 visible rows per page. Discovery checks workspace roots and the active file's parent, not every nested directory. " ++
    "Repositories outside their owning root are rejected. Submodule contents are not inspected.";

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .version,
    pending: Intent = .none,
    permit: ?trust.Permit = null,
    approved: bool = false,
    approval: UI,
    candidates: [max_candidates]Candidate = undefined,
    candidate_count: usize = 0,
    candidate_index: usize = 0,
    repositories: [max_repositories]Repository = undefined,
    repository_count: usize = 0,
    selected_repository: ?usize = null,
    building: ?Repository = null,
    skipped: usize = 0,
    outside: usize = 0,
    discovery_failures: usize = 0,
    remaining_bytes: usize = 4 * capture_bytes,
    snapshot: ?status.Snapshot = null,
    selected_file: ?usize = null,
    page: usize = 0,
    staged: bool = false,
    window: ?u.W = null,
    repository_picker: ?u.W = null,
    list: ?u.W = null,
    summary: ?u.W = null,
    overlay: ?u.W = null,
    page_label: ?u.W = null,
    diff_label: ?u.W = null,
    diff_view: ?u.W = null,
    rebuilding: bool = false,
    message_text: [:0]u8,
    diff_text: [:0]u8,
    diff_kind: []const u8 = "none",
    launches: u64 = 0,
    discarded: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{ .app = app, .arena = std.heap.ArenaAllocator.init(a), .approval = .{ .context = app, .respond = &answered }, .message_text = u.z("Source Control — explicit refresh only"), .diff_text = u.z("") };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.arena.deinit();
        a.free(self.message_text);
        a.free(self.diff_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.approved = false;
        self.permit = null;
        self.approval.close();
        self.closeWindow();
        self.clearModel();
        self.setDiff("none", "");
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Git generation exhausted");
        self.pending = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearSnapshot(self: *Controller) void {
        self.selected_file = null;
        self.page = 0;
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
        self.renderRows();
    }
    fn clearModel(self: *Controller) void {
        self.clearSnapshot();
        self.repository_count = 0;
        self.selected_repository = null;
        self.candidate_count = 0;
        self.candidate_index = 0;
        self.building = null;
        _ = self.arena.reset(.free_all);
        self.renderRepositories();
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        self.pending = .none;
        const text = u.fmt("Source Control: {s}. Refresh to try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn valid(self: *Controller) bool {
        return !self.app.closing and self.approved and self.window != null and
            (if (self.permit) |permit| self.app.workspace_policy.validate(permit, .git) else false);
    }
    pub fn show(self: *Controller) void {
        if (self.app.closing) return;
        if (self.window) |window| {
            if (!self.valid()) {
                self.invalidate();
            } else {
                self.updateOverlay();
                c.gtk_window_present(u.cast(c.GtkWindow, window));
                return;
            }
        }
        self.permit = self.app.workspace_policy.issue(.git) catch {
            self.app.message("Source Control is restricted. Trust the workspace before running Git.");
            return;
        };
        self.approval.context = self;
        self.approval.show(self.app, "Source Control — subprocess disclosure", disclosure, &.{}, false, "Continue with read-only Git");
    }
    fn answered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        if (!accepted or self.app.closing) return;
        const permit = self.permit orelse return;
        if (!self.app.workspace_policy.validate(permit, .git)) {
            self.app.message("Workspace trust changed. Invoke Source Control again.");
            return;
        }
        self.approved = true;
        self.createWindow();
        self.refresh();
    }
    pub fn refresh(self: *Controller) void {
        if (!self.valid()) {
            self.show();
            return;
        }
        self.cancel();
        self.clearModel();
        self.setDiff("none", "Select a changed file, then choose Unstaged Diff or Staged Diff.");
        self.skipped = 0;
        self.outside = 0;
        self.discovery_failures = 0;
        self.remaining_bytes = 4 * capture_bytes;
        self.message("Discovering repositories — disk/index only; no unsaved buffers…");
        self.updateOverlay();
        self.pending = .refresh;
        self.drain();
    }
    fn drain(self: *Controller) void {
        if (self.job != null or self.pending == .none) return;
        const intent = self.pending;
        self.pending = .none;
        if (!self.valid()) {
            self.invalidate();
            return;
        }
        switch (intent) {
            .refresh => self.beginDiscovery() catch |err| self.failure(err),
            .status => self.startStatus() catch |err| self.failure(err),
            .diff => self.startDiff() catch |err| self.failure(err),
            .none => {},
        }
    }
    fn own(self: *Controller, bytes: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, bytes);
    }
    fn beginDiscovery(self: *Controller) !void {
        const model = &(self.app.browser.model orelse return error.NoWorkspace);
        // The model's paths and open documents are already canonical. No realpath,
        // directory traversal, or other filesystem work takes place on GTK's thread.
        for (model.roots) |root| {
            if (root.availability != .available) continue;
            const path = root.canonical_path orelse continue;
            if (self.candidate_count >= max_candidates - 1) return error.TooManyRoots;
            const owned = try self.own(path);
            self.candidates[self.candidate_count] = .{ .root = root.id, .owner = owned, .cwd = owned };
            self.candidate_count += 1;
        }
        if (self.app.active()) |doc| if (doc.path) |path| {
            if (try model.ownerOfCanonicalPath(path)) |root_id| {
                const root = model.rootById(root_id).?;
                const parent = std.fs.path.dirname(path) orelse root.canonical_path.?;
                var duplicate = false;
                for (self.candidates[0..self.candidate_count]) |candidate| {
                    if (std.mem.eql(u8, candidate.cwd, parent)) duplicate = true;
                }
                if (!duplicate) {
                    self.candidates[self.candidate_count] = .{ .root = root_id, .owner = try self.own(root.canonical_path.?), .cwd = try self.own(parent) };
                    self.candidate_count += 1;
                }
            }
        };
        if (self.candidate_count == 0) return error.NoAvailableWorkspaceRoot;
        // A root can disappear after the model snapshot. Version detection must
        // not prevent discovery of the other still-available roots.
        try self.launch(.version, "/", &.{"--version"}, 16384);
    }
    fn discoverNext(self: *Controller) !void {
        self.building = null;
        if (self.candidate_index == self.candidate_count) {
            self.renderRepositories();
            if (self.repository_count == 0) {
                const text = u.fmt("No supported repository found. Outside-root: {d}; failed candidates: {d}. Open a repository root or a file inside a nested repository, then Refresh.", .{ self.outside, self.discovery_failures });
                defer a.free(text);
                self.message(text);
                return;
            }
            self.selected_repository = 0;
            self.renderRepositories();
            try self.startStatus();
            return;
        }
        try self.launch(.root, self.candidates[self.candidate_index].cwd, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel" }, 16384);
    }
    fn nextCandidate(self: *Controller) !void {
        self.candidate_index += 1;
        try self.discoverNext();
    }
    fn repo(self: *Controller) ?*const Repository {
        const index = self.selected_repository orelse return null;
        if (index >= self.repository_count) return null;
        return &self.repositories[index];
    }
    fn startStatus(self: *Controller) !void {
        const repository = self.repo() orelse return error.NoRepository;
        self.message("Reading Git status — disk/index only…");
        try self.launch(.status, repository.path, command.status_args, capture_bytes);
    }
    fn launch(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize) !void {
        if (!self.valid()) return error.Restricted;
        if (self.job != null) return error.Busy;
        if (self.remaining_bytes == 0) return error.OutputBudgetExceeded;
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
            .identity = .{ .scope = "git-read-only", .request = self.launches + 1, .generation = self.generation, .workspace = token },
            .argv = argv[0 .. command.prefix.len + args.len],
            .cwd = cwd,
            .environment = &environment,
            .output_limit = @min(limit, self.remaining_bytes),
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
            self.drain();
            return;
        }
        if (!self.valid() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            // Parent invalidation normally closes the surface earlier. Also fail
            // closed at delivery if its workspace/policy changed in the meantime.
            self.invalidate();
            return;
        }
        self.remaining_bytes -|= result.stdout.len + result.stderr.len;
        self.receive(result) catch |err| self.failure(err);
    }
    fn receive(self: *Controller, result: process.Result) !void {
        if (result.outcome != .success) {
            // A non-repository, bare repository, or inaccessible candidate does
            // not prevent discovery of the remaining roots. Never parse partial
            // capture as a complete status or diff.
            if (self.phase == .root or self.phase == .gitdir or self.phase == .commondir) {
                self.discovery_failures += 1;
                try self.nextCandidate();
                return;
            }
            const text = u.fmt("Git {s}: {s} (exit {d}). No partial result is shown. Refresh to retry.", .{ @tagName(self.phase), @tagName(result.outcome), result.exit_code orelse -1 });
            defer a.free(text);
            self.message(text);
            self.setDiff("error", "Git did not produce a complete result.");
            return;
        }
        switch (self.phase) {
            .version => {
                if (!command.supportedVersion(result.stdout)) return error.Git231OrNewerRequired;
                try self.discoverNext();
            },
            .root => {
                const path = try command.outputPath(result.stdout);
                const candidate = self.candidates[self.candidate_index];
                if (!command.contains(candidate.owner, path)) {
                    self.outside += 1;
                    try self.nextCandidate();
                    return;
                }
                for (self.repositories[0..self.repository_count]) |existing| if (std.mem.eql(u8, existing.path, path)) {
                    try self.nextCandidate();
                    return;
                };
                if (self.repository_count == max_repositories) {
                    self.skipped += 1;
                    try self.nextCandidate();
                    return;
                }
                self.building = .{ .root = candidate.root, .owner = candidate.owner, .path = try self.own(path) };
                try self.launch(.gitdir, self.building.?.path, &.{ "rev-parse", "--absolute-git-dir" }, 16384);
            },
            .gitdir => {
                self.building.?.gitdir = try self.own(try command.outputPath(result.stdout));
                try self.launch(.commondir, self.building.?.path, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, 16384);
            },
            .commondir => {
                self.building.?.commondir = try self.own(try command.outputPath(result.stdout));
                self.repositories[self.repository_count] = self.building.?;
                self.repository_count += 1;
                try self.nextCandidate();
            },
            .status => {
                var parsed = try status.parse(a, result.stdout);
                if (parsed.entries.len > max_entries) {
                    parsed.deinit();
                    return error.TooManyStatusEntries;
                }
                self.clearSnapshot();
                self.snapshot = parsed;
                self.renderRows();
                self.updateSummary();
            },
            .diff => {
                switch (command.preview(result.stdout)) {
                    .binary => self.setDiff("binary", "Binary change — no editable or textual diff is available in this first increment."),
                    .non_utf8 => self.setDiff("non-utf8", "Non-UTF-8 change — text preview is unavailable; no file has been edited."),
                    .too_large => self.setDiff("limited", "Diff exceeds native preview limits (256 KiB, 4,000 lines or 2,048 bytes per line). No partial diff is shown."),
                    .text => self.setDiff("text", if (result.stdout.len == 0) "No differences for this side. Status may have changed on disk; Refresh to update it." else result.stdout),
                }
                self.updateSummary();
            },
        }
    }
    fn selectRepository(self: *Controller, index: usize) void {
        if (index >= self.repository_count or !self.valid()) return;
        self.cancel();
        self.selected_repository = index;
        self.clearSnapshot();
        self.setDiff("none", "Select a changed file, then choose a diff side.");
        self.remaining_bytes = capture_bytes;
        self.renderRepositories();
        self.pending = .status;
        self.drain();
    }
    fn selectFile(self: *Controller, index: usize) void {
        const snapshot = self.snapshot orelse return;
        if (index >= snapshot.entries.len or !self.valid()) return;
        self.cancel();
        self.selected_file = index;
        self.page = index / page_rows;
        self.setDiff("none", "Selection changed. Choose Unstaged Diff (index → disk) or Staged Diff (HEAD → index).");
        self.renderRows();
        self.updateOverlay();
    }
    pub fn showDiff(self: *Controller, staged: bool) void {
        if (!self.valid()) {
            self.show();
            return;
        }
        if (self.selected_file == null) {
            self.message("Select a changed file before requesting a diff.");
            return;
        }
        self.cancel();
        self.staged = staged;
        self.remaining_bytes = capture_bytes;
        self.updateOverlay();
        self.setDiff("loading", "Reading immutable Git diff… Unsaved buffers are excluded.");
        self.pending = .diff;
        self.drain();
    }
    fn startDiff(self: *Controller) !void {
        const repository = self.repo() orelse return error.NoRepository;
        const snapshot = self.snapshot orelse return error.RefreshRequired;
        const entry = snapshot.entries[self.selected_file orelse return error.NoSelection];
        if (entry.kind == .untracked or entry.kind == .ignored) {
            self.setDiff("untracked", "Untracked/ignored path — not an index/HEAD comparison. This increment does not fabricate a text diff or read untracked contents.");
            return;
        }
        if (entry.kind == .unmerged) {
            self.setDiff("conflict", "Unmerged conflict — multiple index stages. Conflict editing and combined diffs are not supported in this increment.");
            return;
        }
        if (entry.submodule) {
            self.setDiff("submodule", "Submodule change — submodule contents are excluded from this read-only view.");
            return;
        }
        const side = if (self.staged) entry.index else entry.worktree;
        if (side == '.' or side == ' ') {
            self.setDiff("unchanged", "The selected status snapshot has no change on this side. Refresh if disk or index state changed.");
            return;
        }
        var args: [24][]const u8 = undefined;
        @memcpy(args[0..command.diff_args.len], command.diff_args);
        var len = command.diff_args.len;
        if (self.staged) {
            args[len] = "--cached";
            len += 1;
        }
        args[len] = "--";
        args[len + 1] = entry.path;
        len += 2;
        if (entry.original_path) |original| {
            args[len] = original;
            len += 1;
        }
        try self.launch(.diff, repository.path, args[0..len], capture_bytes);
    }
    fn updateSummary(self: *Controller) void {
        const snapshot = self.snapshot orelse return;
        const branch = command.display(a, snapshot.branch orelse "(detached/unborn)", 512) catch return;
        defer a.free(branch);
        const upstream = command.display(a, snapshot.upstream orelse "none", 256) catch return;
        defer a.free(upstream);
        const head = snapshot.head orelse "unknown";
        const text = u.fmt("{s} · HEAD {s} · upstream {s} · {d} changes · ahead {d}, behind {d} · skipped {d}, outside-root {d}, failed candidates {d}. Explicit Refresh only; renames shown as add/delete; submodule contents excluded.", .{ branch, head[0..@min(head.len, 12)], upstream, snapshot.entries.len, snapshot.ahead, snapshot.behind, self.skipped, self.outside, self.discovery_failures });
        defer a.free(text);
        self.message(text);
        self.updateOverlay();
    }
    fn dirtyCount(self: *Controller) usize {
        var count: usize = 0;
        for (self.app.documents.entries.items) |doc| if (doc.dirty()) {
            count += 1;
        };
        return count;
    }
    fn updateOverlay(self: *Controller) void {
        const label = self.overlay orelse return;
        const text = u.fmt("Unsaved editor documents: {d} (excluded; never saved). Counts update on interaction. Read-only Git snapshots are not atomic with external disk/index changes.", .{self.dirtyCount()});
        defer a.free(text);
        u.setLabel(label, text);
    }
    fn setDiff(self: *Controller, kind: []const u8, text: []const u8) void {
        self.diff_kind = kind;
        a.free(self.diff_text);
        self.diff_text = u.z(text);
        if (self.diff_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.diff_text.ptr, @intCast(self.diff_text.len));
        if (self.diff_label) |label| u.setLabel(label, if (self.staged) "Staged Diff — HEAD → index (read-only)" else "Unstaged Diff — index → disk (read-only)");
    }
    fn createWindow(self: *Controller) void {
        if (self.window != null) return;
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Source Control — read-only · first M4 increment");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 960, 760);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const bar = u.box(true, 8);
        u.append(box, bar);
        u.append(bar, u.label("Repository / workspace root"));
        const picker = c.gtk_combo_box_text_new().?;
        self.repository_picker = picker;
        c.gtk_widget_set_hexpand(picker, 1);
        u.append(bar, picker);
        u.connect(picker, "changed", &repositoryChanged, self);
        const refresh_button = u.button("Refresh");
        u.append(bar, refresh_button);
        u.connect(refresh_button, "clicked", &refreshClicked, self);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const overlay = u.label("");
        self.overlay = overlay;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, overlay), 1);
        u.append(box, overlay);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(scroll, -1, 190);
        const list = c.gtk_list_box_new().?;
        self.list = list;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        u.append(box, scroll);
        u.connect(list, "row-selected", &fileSelected, self);
        const actions = u.box(true, 8);
        u.append(box, actions);
        const previous = u.button("Previous page");
        const next = u.button("Next page");
        u.append(actions, previous);
        u.append(actions, next);
        u.connect(previous, "clicked", &previousClicked, self);
        u.connect(next, "clicked", &nextClicked, self);
        self.page_label = u.label("No files");
        u.append(actions, self.page_label.?);
        const unstaged = u.button("Unstaged Diff");
        const staged = u.button("Staged Diff");
        u.append(actions, unstaged);
        u.append(actions, staged);
        u.connect(unstaged, "clicked", &unstagedClicked, self);
        u.connect(staged, "clicked", &stagedClicked, self);
        const diff_label = u.label("Immutable diff — select a file and a side");
        self.diff_label = diff_label;
        u.append(box, diff_label);
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
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.repository_picker = null;
        self.list = null;
        self.summary = null;
        self.overlay = null;
        self.page_label = null;
        self.diff_label = null;
        self.diff_view = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn renderRepositories(self: *Controller) void {
        const picker = self.repository_picker orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        c.gtk_combo_box_text_remove_all(u.cast(c.GtkComboBoxText, picker));
        for (self.repositories[0..self.repository_count]) |repository| {
            const path = command.display(a, repository.path, 512) catch unreachable;
            defer a.free(path);
            const root = command.display(a, repository.owner, 512) catch unreachable;
            defer a.free(root);
            const text = u.fmt("{s}  [root: {s}]", .{ path, root });
            defer a.free(text);
            c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, picker), text);
        }
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, picker), if (self.selected_repository) |index| @intCast(index) else -1);
    }
    fn renderRows(self: *Controller) void {
        const list = self.list orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        const entries: []const status.Entry = if (self.snapshot) |snapshot| snapshot.entries else &.{};
        const start = @min(self.page * page_rows, entries.len);
        const end = @min(start + page_rows, entries.len);
        for (entries[start..end]) |entry| {
            const path = command.display(a, entry.path, 1024) catch unreachable;
            defer a.free(path);
            const text = u.fmt("{c}{c}  {s}{s}", .{ entry.index, entry.worktree, path, if (entry.kind == .unmerged) "  [conflict]" else if (entry.kind == .untracked) "  [untracked]" else if (entry.submodule) "  [submodule]" else "" });
            defer a.free(text);
            const label = u.label(text);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
            c.gtk_widget_set_tooltip_text(label, text);
            u.margin(label, 4);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), label);
        }
        if (self.selected_file) |index| if (index >= start and index < end) {
            c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), @intCast(index - start)));
        };
        if (self.page_label) |label| {
            const text = u.fmt("{d}–{d} / {d} · index/worktree", .{ if (entries.len == 0) @as(usize, 0) else start + 1, end, entries.len });
            defer a.free(text);
            u.setLabel(label, text);
        }
    }
    fn changePage(self: *Controller, next: bool) void {
        const snapshot = self.snapshot orelse return;
        if (next) {
            if ((self.page + 1) * page_rows >= snapshot.entries.len) return;
            self.page += 1;
        } else {
            if (self.page == 0) return;
            self.page -= 1;
        }
        self.cancel();
        self.selected_file = null;
        self.setDiff("none", "Select a file on this page.");
        self.renderRows();
        self.updateOverlay();
    }
    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn repositoryChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const index = c.gtk_combo_box_get_active(picker);
        if (index >= 0) self.selectRepository(@intCast(index));
    }
    fn fileSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const index = c.gtk_list_box_row_get_index(row orelse return);
        if (index >= 0) self.selectFile(self.page * page_rows + @as(usize, @intCast(index)));
    }
    fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).refresh();
    }
    fn unstagedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showDiff(false);
    }
    fn stagedClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showDiff(true);
    }
    fn previousClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).changePage(false);
    }
    fn nextClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).changePage(true);
    }

    /// Test-only bridge. Selection values are zero-based indices; git-select also
    /// accepts "repo:N" / "file:N". Approval answers the actual disclosure dialog,
    /// never grants trust or bypasses a permit. No fixture mutates Git state.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!@import("build_options").test_hooks) return false;
        if (std.mem.eql(u8, action, "git-probe")) self.probe() else if (std.mem.eql(u8, action, "git-accept")) self.approval.answer(true, null, "") else if (std.mem.eql(u8, action, "git-reject")) self.approval.answer(false, null, "") else if (std.mem.eql(u8, action, "git-close")) self.invalidate() else if (std.mem.eql(u8, action, "git-select-repo")) self.selectRepository(std.fmt.parseInt(usize, value, 10) catch return true) else if (std.mem.eql(u8, action, "git-select-file")) self.selectFile(std.fmt.parseInt(usize, value, 10) catch return true) else if (std.mem.eql(u8, action, "git-select")) {
            if (std.mem.startsWith(u8, value, "repo:")) self.selectRepository(std.fmt.parseInt(usize, value[5..], 10) catch return true) else if (std.mem.startsWith(u8, value, "file:")) self.selectFile(std.fmt.parseInt(usize, value[5..], 10) catch return true);
        } else if (std.mem.eql(u8, action, "git-page")) self.changePage(std.mem.eql(u8, value, "next")) else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!@import("build_options").test_hooks) return;
        const RepoProbe = struct { root: u64, owner: []const u8, path: []const u8, gitdir: []const u8, commondir: []const u8 };
        var repositories: [max_repositories]RepoProbe = undefined;
        for (self.repositories[0..self.repository_count], 0..) |repository, i| repositories[i] = .{ .root = @backingInt(repository.root), .owner = repository.owner, .path = repository.path, .gitdir = repository.gitdir, .commondir = repository.commondir };
        const entries: []const status.Entry = if (self.snapshot) |snapshot| snapshot.entries else &.{};
        const begin = @min(self.page * page_rows, entries.len);
        const end = @min(begin + page_rows, entries.len);
        // JSON serializes raw paths as data, never as a shell command or GTK markup.
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .visible = self.window != null,
            .disclosure = self.approval.window != null,
            .approved = self.approved,
            .generation = self.generation,
            .busy = self.job != null,
            .pending = @tagName(self.pending),
            .phase = if (self.job != null) @as(?[]const u8, @tagName(self.phase)) else null,
            .launches = self.launches,
            .discarded = self.discarded,
            .repositories = repositories[0..self.repository_count],
            .selected_repository = self.selected_repository,
            .entries = entries[begin..end],
            .entry_count = entries.len,
            .visible_rows = end - begin,
            .page = self.page,
            .selected_file = self.selected_file,
            .head = if (self.snapshot) |snapshot| snapshot.head else null,
            .branch = if (self.snapshot) |snapshot| snapshot.branch else null,
            .upstream = if (self.snapshot) |snapshot| snapshot.upstream else null,
            .dirty_documents = self.dirtyCount(),
            .staged = self.staged,
            .diff_kind = self.diff_kind,
            .diff = self.diff_text,
            .status = self.message_text,
            .outside = self.outside,
            .skipped = self.skipped,
            .discovery_failures = self.discovery_failures,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT %s\n", line.ptr);
    }
};
