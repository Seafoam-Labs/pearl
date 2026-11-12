//! M4 UI-parity Project Diff: a multi-file window with editable current-side
//! excerpts, unified/split/word rendering, gutter markers, hunk navigation and
//! reviewed hunk OR change-line-selection staging/unstaging.
//!
//! Discovery and trust are inherited from the parent Source Control controller
//! (app.git): this window never runs Git on its own authority and never bypasses
//! the Source Control disclosure. Read-only per-file diffs use command.zig's
//! locked-down policy through a private process.Supervisor. Index changes reuse
//! the strict index_transaction backend (prepare/apply) through one-shot GTask
//! workers and a separate native before/after review; no worktree file is ever
//! written and no commit is made.
//!
//! Editable current-side excerpts bind to REAL open Documents through the shared
//! editor History (app.history), exactly like app.openExcerpt. Edits stay unsaved
//! in the document buffer; staging always uses the captured disk/index snapshot,
//! so the window warns that unsaved edits are excluded and offers Save through a
//! parent-set callback. The original side is always a read-only GtkSourceView.
//!
//! The parent owns commands and lifecycle invalidation and may set the excerpt
//! callbacks below. No startup work, watchers, saves, checkout or network.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const status = @import("status.zig");
const command = @import("command.zig");
const hunk = @import("hunk.zig");
const render = @import("diff_render.zig");
const backend = @import("index_transaction.zig");
const tx = @import("../editor/transactions.zig");
const excerpt_model = @import("../editor/excerpt.zig");
const ExcerptEditor = @import("../editor/excerpt_editor.zig").Editor;
const model = @import("../workspace/model.zig");
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = 1024 * 1024;
pub const max_files = render.max_files;
pub const inspect_timeout_ms = 15_000;

const Phase = enum { diff };
const Intent = enum { none, diff };
const Side = enum { original, current, both };
const MutState = enum { idle, preparing, confirming, applying, retiring, succeeded, cancelled, failed };
const MutPhase = enum { prepare, apply, retire };

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .diff,
    pending: Intent = .none,

    // Parent-set excerpt callbacks. The parent routes these to app.history,
    // checkpointing and Save; resolve/history are handled internally so the
    // window also works without extra wiring.
    callback_context: ?*anyopaque = null,
    save_document: ?*const fn (?*anyopaque, u64) void = null,
    edit_committed: ?*const fn (?*anyopaque) void = null,
    edit_failed: ?*const fn (?*anyopaque, anyerror) void = null,

    window: ?u.W = null,
    file_picker: ?u.W = null,
    mode_picker: ?u.W = null,
    side_picker: ?u.W = null,
    staged_picker: ?u.W = null,
    summary: ?u.W = null,
    warning: ?u.W = null,
    hunk_label: ?u.W = null,
    selection_entry: ?u.W = null,
    diff_view: ?u.W = null,
    split_box: ?u.W = null,
    split_old: ?u.W = null,
    split_new: ?u.W = null,
    excerpt_box: ?u.W = null,
    excerpt_header: ?u.W = null,
    stage_hunk_button: ?u.W = null,
    unstage_hunk_button: ?u.W = null,
    stage_sel_button: ?u.W = null,
    unstage_sel_button: ?u.W = null,
    save_button: ?u.W = null,
    rebuilding: bool = false,

    files: std.ArrayList([]const u8) = .empty,
    selected_file: ?usize = null,
    diff_bytes: []const u8 = "",
    file_diff: ?render.FileDiff = null,
    hunk_refs: std.ArrayList(hunk.HunkRef) = .empty,
    selected_hunk: ?usize = null,
    selected_lines: std.ArrayList(hunk.LineRange) = .empty,
    mode: render.Mode = .unified,
    side: Side = .both,
    staged: bool = false,
    excerpt: ?*ExcerptEditor = null,
    excerpt_document: ?u64 = null,
    diff_kind: []const u8 = "none",

    mutation: ?*MutJob = null,
    mutation_state: MutState = .idle,
    mutation_dialog: ?u.W = null,
    mutation_review: [:0]u8,
    mutation_error: ?[]const u8 = null,
    mutation_committed: bool = false,

    message_text: [:0]u8,
    launches: u64 = 0,
    discarded: u64 = 0,
    jobs_reaped: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .message_text = u.z("Project Diff — open Source Control first"),
            .mutation_review = u.z(""),
        };
    }
    pub fn deinit(self: *Controller) void {
        std.debug.assert(self.job == null and self.supervisor.isIdle() and self.mutation == null);
        self.invalidate();
        self.supervisor.shutdown();
        self.destroyExcerpt();
        self.files.deinit(a);
        self.hunk_refs.deinit(a);
        self.selected_lines.deinit(a);
        self.arena.deinit();
        a.free(self.message_text);
        a.free(self.mutation_review);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.cancelMutation();
        self.closeWindow();
        self.clearModel();
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Project Diff generation exhausted");
        self.pending = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearModel(self: *Controller) void {
        self.destroyExcerpt();
        self.selected_file = null;
        self.selected_hunk = null;
        self.file_diff = null;
        self.diff_bytes = "";
        self.files.clearRetainingCapacity();
        self.hunk_refs.clearRetainingCapacity();
        self.selected_lines.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
        self.renderFiles();
        self.updateHunkLabel();
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        self.pending = .none;
        const text = u.fmt("Project Diff: {s}. Refresh to try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }

    /// Source Control disclosure, a selected repository and a status snapshot are
    /// prerequisites; this window never grants trust or runs Git independently.
    fn ready(self: *Controller) bool {
        return !self.app.closing and self.app.git.valid() and self.app.git.repo() != null and self.app.git.snapshot != null;
    }
    pub fn valid(self: *Controller) bool {
        return self.ready() and self.window != null;
    }

    pub fn show(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
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
            self.app.message("Open Source Control and select a repository before opening Project Diff.");
            return;
        }
        self.createWindow();
        self.refresh();
    }
    pub fn refresh(self: *Controller) void {
        if (!self.ready()) {
            self.show();
            return;
        }
        self.cancel();
        self.clearModel();
        self.loadFiles();
        self.message("Project Diff — disk/index only; unsaved buffers are excluded and never saved.");
        if (self.files.items.len > 0) {
            self.selected_file = 0;
            self.renderFiles();
            self.loadDiff();
        } else {
            self.setDiff("none", "No changed files in the current Source Control snapshot.");
        }
        self.updateWarning();
    }
    fn loadFiles(self: *Controller) void {
        const snapshot = self.app.git.snapshot orelse return;
        for (snapshot.entries) |entry| {
            if (self.files.items.len >= max_files) break;
            // Only ordinary/rename paths with a textual comparison side; untracked,
            // ignored, unmerged and submodule entries are not editable diffs.
            if (entry.kind == .untracked or entry.kind == .ignored or entry.kind == .unmerged or entry.submodule) continue;
            if (entry.index == '.' and entry.worktree == '.') continue;
            self.files.append(a, self.arena.allocator().dupe(u8, entry.path) catch continue) catch continue;
        }
    }
    fn selectedPath(self: *Controller) ?[]const u8 {
        const index = self.selected_file orelse return null;
        if (index >= self.files.items.len) return null;
        return self.files.items[index];
    }
    fn repository(self: *Controller) ?*const @import("controller.zig").Repository {
        return self.app.git.repo();
    }

    fn loadDiff(self: *Controller) void {
        self.pending = .diff;
        self.drain();
    }
    fn drain(self: *Controller) void {
        defer self.updateActions();
        if (self.job != null or self.mutation != null or self.pending == .none) return;
        const intent = self.pending;
        self.pending = .none;
        if (!self.ready()) {
            self.invalidate();
            return;
        }
        switch (intent) {
            .diff => self.startDiff() catch |err| self.failure(err),
            .none => {},
        }
    }
    fn startDiff(self: *Controller) !void {
        const repo = self.repository() orelse return error.NoRepository;
        const path = self.selectedPath() orelse return error.NoSelection;
        self.setDiff("loading", "Reading immutable Git diff… unsaved buffers are excluded.");
        var args: [24][]const u8 = undefined;
        @memcpy(args[0..command.diff_args.len], command.diff_args);
        var len = command.diff_args.len;
        // Match the backend's regenerated direction exactly: staging compares
        // index->disk (unstaged diff); unstaging compares HEAD->index (staged
        // diff). A combined HEAD diff would not match either hunk digest.
        if (self.staged) {
            args[len] = "--cached";
            len += 1;
        }
        args[len] = "--";
        len += 1;
        args[len] = path;
        len += 1;
        try self.launch(repo.path, args[0..len], capture_bytes);
    }
    fn launch(self: *Controller, cwd: []const u8, args: []const []const u8, limit: usize) !void {
        if (!self.ready()) return error.Restricted;
        if (self.job != null) return error.Busy;
        var argv: [64][]const u8 = undefined;
        if (command.prefix.len + args.len > argv.len) return error.InvalidArguments;
        @memcpy(argv[0..command.prefix.len], command.prefix);
        @memcpy(argv[command.prefix.len..][0..args.len], args);
        var environment: [command.environment.len]process.Environment = undefined;
        for (command.environment, &environment) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
        const token = self.app.workspace.capture() orelse return error.Closed;
        self.phase = .diff;
        self.job = try process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "git-project-diff", .request = self.launches + 1, .generation = self.generation, .workspace = token },
            .argv = argv[0 .. command.prefix.len + args.len],
            .cwd = cwd,
            .environment = &environment,
            .output_limit = limit,
            .timeout_ms = inspect_timeout_ms,
        }, &completed, self);
        self.launches += 1;
        self.app.hold();
        self.updateActions();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        defer self.app.release();
        defer job.destroy();
        std.debug.assert(self.job == job);
        self.job = null;
        self.jobs_reaped += 1;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            self.drain();
            return;
        }
        if (!self.ready() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.invalidate();
            return;
        }
        self.receive(result) catch |err| self.failure(err);
    }
    fn receive(self: *Controller, result: process.Result) !void {
        if (result.outcome != .success and result.outcome != .nonzero) {
            self.setDiff("error", "Git did not produce a complete diff. Refresh to retry.");
            return;
        }
        const owned = try self.arena.allocator().dupe(u8, result.stdout);
        self.diff_bytes = owned;
        self.hunk_refs.clearRetainingCapacity();
        self.selected_hunk = null;
        self.selected_lines.clearRetainingCapacity();
        self.destroyExcerpt();
        const parsed = render.parse(self.arena.allocator(), owned) catch {
            self.file_diff = null;
            self.setDiff("error", "Diff exceeds the multi-file parse budget.");
            return;
        };
        self.file_diff = if (parsed.files.len > 0) parsed.files[0] else null;
        // Hunk refs come from the strict single-file parser, matching the backend.
        const single = hunk.parse(a, owned) catch null;
        if (single) |p| {
            for (p.hunks, 0..) |h, i| {
                if (i >= render.max_hunks) break;
                self.hunk_refs.append(a, .{ .ordinal = i, .digest = hunk.digest(h) }) catch break;
            }
            if (self.hunk_refs.items.len > 0) self.selected_hunk = 0;
        }
        self.renderDiff();
        self.updateHunkLabel();
        self.updateWarning();
        self.updateActions();
    }

    pub fn selectFile(self: *Controller, index: usize) void {
        if (!self.ready() or index >= self.files.items.len) return;
        self.cancel();
        self.selected_file = index;
        self.renderFiles();
        self.loadDiff();
    }
    pub fn setMode(self: *Controller, mode: render.Mode) void {
        self.mode = mode;
        self.renderDiff();
    }
    pub fn setSide(self: *Controller, side: Side) void {
        self.side = side;
        self.renderDiff();
    }
    pub fn setStaged(self: *Controller, staged: bool) void {
        if (!self.ready()) return;
        self.cancel();
        self.staged = staged;
        self.loadDiff();
    }
    pub fn nextHunk(self: *Controller) void {
        if (self.hunk_refs.items.len == 0) return;
        const current = self.selected_hunk orelse 0;
        self.selected_hunk = @min(current + 1, self.hunk_refs.items.len - 1);
        self.selected_lines.clearRetainingCapacity();
        self.updateHunkLabel();
        self.renderDiff();
        self.updateActions();
    }
    pub fn previousHunk(self: *Controller) void {
        if (self.hunk_refs.items.len == 0) return;
        const current = self.selected_hunk orelse 0;
        self.selected_hunk = if (current == 0) 0 else current - 1;
        self.selected_lines.clearRetainingCapacity();
        self.updateHunkLabel();
        self.renderDiff();
        self.updateActions();
    }
    fn currentHunk(self: *Controller) ?hunk.Hunk {
        const index = self.selected_hunk orelse return null;
        const file = self.file_diff orelse return null;
        if (file.kind != .text or index >= file.hunks.len) return null;
        return file.hunks[index];
    }
    fn updateHunkLabel(self: *Controller) void {
        const label = self.hunk_label orelse return;
        const text = if (self.selected_hunk) |index|
            u.fmt("Hunk {d}/{d}", .{ index + 1, self.hunk_refs.items.len })
        else
            u.fmt("No hunks ({d})", .{self.hunk_refs.items.len});
        defer a.free(text);
        u.setLabel(label, text);
    }

    // -- Selection staging ----------------------------------------------------

    /// Parse a "start:end,start:end" change-line range list for the current hunk.
    pub fn selectLines(self: *Controller, value: []const u8) void {
        self.selected_lines.clearRetainingCapacity();
        const h = self.currentHunk() orelse return;
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const start = std.fmt.parseInt(usize, trimmed[0..colon], 10) catch continue;
            const end = std.fmt.parseInt(usize, trimmed[colon + 1 ..], 10) catch continue;
            self.selected_lines.append(a, .{ .start = start, .end = end }) catch continue;
        }
        hunk.validateSelection(h, self.selected_lines.items) catch {
            self.selected_lines.clearRetainingCapacity();
            self.message("Invalid selection: ranges must be non-empty, sorted, non-overlapping and within the hunk's change-lines.");
            return;
        };
        self.updateActions();
    }
    pub fn stageHunk(self: *Controller) void {
        self.requestMutation(.stage_hunk, false);
    }
    pub fn unstageHunk(self: *Controller) void {
        self.requestMutation(.unstage_hunk, false);
    }
    pub fn stageSelection(self: *Controller) void {
        self.requestMutation(.stage_hunk, true);
    }
    pub fn unstageSelection(self: *Controller) void {
        self.requestMutation(.unstage_hunk, true);
    }

    fn requestMutation(self: *Controller, action: backend.Action, use_selection: bool) void {
        if (!self.valid()) {
            self.show();
            return;
        }
        if (self.job != null or self.pending != .none or self.mutation != null) {
            self.message("Wait for the current Git request or review before requesting an index change.");
            return;
        }
        // Staging applies to the unstaged (index->disk) diff; unstaging to the
        // staged (HEAD->index) diff. The displayed side must match the action so
        // the captured hunk digest matches the backend's regenerated diff.
        const wants_stage = action == .stage_hunk;
        if (wants_stage == self.staged) {
            self.message(if (wants_stage) "Switch to the Unstaged diff (index → disk) before staging." else "Switch to the Staged diff (HEAD → index) before unstaging.");
            return;
        }
        const repo = self.repository() orelse return;
        const path = self.selectedPath() orelse {
            self.message("Select a changed file before requesting an index change.");
            return;
        };
        const hunk_index = self.selected_hunk orelse {
            self.message("Select a hunk before requesting a hunk or selection change.");
            return;
        };
        if (hunk_index >= self.hunk_refs.items.len) return;
        const ref = self.hunk_refs.items[hunk_index];
        var selection: ?backend.Selection = null;
        if (use_selection) {
            const h = self.currentHunk() orelse return;
            hunk.validateSelection(h, self.selected_lines.items) catch {
                self.message("Select valid change-line ranges (e.g. 0:2,3:4) before staging a selection.");
                return;
            };
            selection = .{ .ordinal = ref.ordinal, .ranges = self.selected_lines.items };
        }
        const absolute = std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, repo.path, "/"), path }) catch return;
        defer a.free(absolute);
        self.beginMutation(.{
            .root = repo.path,
            .gitdir = repo.gitdir,
            .commondir = repo.commondir,
            .path = path,
            .action = action,
            .hunk = ref,
            .selection = selection,
        }, repo.root, absolute) catch |err| self.abortMutation(err);
    }

    // -- Rendering ------------------------------------------------------------

    fn setDiff(self: *Controller, kind: []const u8, text: []const u8) void {
        self.diff_kind = kind;
        if (self.diff_view) |view| {
            const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view));
            c.gtk_text_buffer_set_text(buffer, text.ptr, @intCast(text.len));
        }
    }
    fn renderDiff(self: *Controller) void {
        if (self.staged_picker) |p| {
            const active: c_int = if (self.staged) 1 else 0;
            if (c.gtk_combo_box_get_active(u.cast(c.GtkComboBox, p)) != active) {
                self.rebuilding = true;
                c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, p), active);
                self.rebuilding = false;
            }
        }
        const file = self.file_diff orelse {
            self.setDiff("none", "Select a changed file.");
            return;
        };
        self.diff_kind = @tagName(file.kind);
        switch (self.mode) {
            .unified, .word => self.renderUnifiedView(file),
            .split => self.renderSplitView(file),
        }
        self.renderExcerpt();
    }
    fn renderUnifiedView(self: *Controller, file: render.FileDiff) void {
        self.showUnifiedWidgets(true);
        const view = self.diff_view orelse return;
        const buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view));
        c.gtk_text_buffer_set_text(buffer, "", 0);
        const lines = render.renderUnified(self.arena.allocator(), file, self.mode) catch {
            self.setDiff("error", "Render exceeds the display budget.");
            return;
        };
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        for (lines) |line| {
            text.appendSlice(a, line.text) catch return;
            text.append(a, '\n') catch return;
        }
        c.gtk_text_buffer_set_text(buffer, text.items.ptr, @intCast(text.items.len));
        self.applyLineTags(buffer, lines);
    }
    fn renderSplitView(self: *Controller, file: render.FileDiff) void {
        self.showUnifiedWidgets(false);
        const old_view = self.split_old orelse return;
        const new_view = self.split_new orelse return;
        const view = render.renderSplit(self.arena.allocator(), file, self.mode) catch {
            self.setDiff("error", "Render exceeds the display budget.");
            return;
        };
        const old_buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, old_view));
        const new_buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, new_view));
        c.gtk_text_buffer_set_text(old_buffer, "", 0);
        c.gtk_text_buffer_set_text(new_buffer, "", 0);
        var old_text: std.ArrayList(u8) = .empty;
        defer old_text.deinit(a);
        var new_text: std.ArrayList(u8) = .empty;
        defer new_text.deinit(a);
        var old_lines: std.ArrayList(render.RenderLine) = .empty;
        defer old_lines.deinit(a);
        var new_lines: std.ArrayList(render.RenderLine) = .empty;
        defer new_lines.deinit(a);
        for (view.rows) |row| {
            if (row.old) |ol| {
                old_text.appendSlice(a, ol.text) catch return;
                old_text.append(a, '\n') catch return;
                old_lines.append(a, ol) catch return;
            }
            if (row.new) |nl| {
                new_text.appendSlice(a, nl.text) catch return;
                new_text.append(a, '\n') catch return;
                new_lines.append(a, nl) catch return;
            }
        }
        c.gtk_text_buffer_set_text(old_buffer, old_text.items.ptr, @intCast(old_text.items.len));
        c.gtk_text_buffer_set_text(new_buffer, new_text.items.ptr, @intCast(new_text.items.len));
        self.applyLineTags(old_buffer, old_lines.items);
        self.applyLineTags(new_buffer, new_lines.items);
    }
    fn showUnifiedWidgets(self: *Controller, unified: bool) void {
        if (self.diff_view) |w| c.gtk_widget_set_visible(w, @intFromBool(unified));
        if (self.split_box) |w| c.gtk_widget_set_visible(w, @intFromBool(!unified));
    }
    fn applyLineTags(self: *Controller, buffer: *c.GtkTextBuffer, lines: []const render.RenderLine) void {
        _ = self;
        const added_tag = c.gtk_text_buffer_create_tag(buffer, "pd-added", "background", "#e6ffec", @as(?*anyopaque, null)).?;
        const removed_tag = c.gtk_text_buffer_create_tag(buffer, "pd-removed", "background", "#ffebe9", @as(?*anyopaque, null)).?;
        const word_tag = c.gtk_text_buffer_create_tag(buffer, "pd-word", "weight", @as(c_int, 700), @as(?*anyopaque, null)).?;
        for (lines, 0..) |line, i| {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            if (c.gtk_text_buffer_get_iter_at_line(buffer, &start, @intCast(i)) == 0) continue;
            end = start;
            if (c.gtk_text_iter_get_line(&end) != @as(c_int, @intCast(i))) continue;
            _ = c.gtk_text_iter_forward_to_line_end(&end);
            const tag = switch (line.tag) {
                .added => added_tag,
                .removed => removed_tag,
                else => null,
            };
            if (tag) |tg| c.gtk_text_buffer_apply_tag(buffer, tg, &start, &end);
            for (line.words) |w| {
                var ws = start;
                var we = start;
                _ = c.gtk_text_iter_forward_chars(&ws, @intCast(std.unicode.utf8CountCodepoints(line.text[0..w.start]) catch 0));
                _ = c.gtk_text_iter_forward_chars(&we, @intCast(std.unicode.utf8CountCodepoints(line.text[0..w.end]) catch 0));
                c.gtk_text_buffer_apply_tag(buffer, word_tag, &ws, &we);
            }
        }
    }

    // -- Editable current-side excerpt ----------------------------------------

    fn destroyExcerpt(self: *Controller) void {
        if (self.excerpt) |editor| {
            if (self.excerpt_box) |box| c.gtk_box_remove(u.cast(c.GtkBox, box), editor.root);
            editor.destroy();
        }
        self.excerpt = null;
        self.excerpt_document = null;
    }
    fn renderExcerpt(self: *Controller) void {
        self.destroyExcerpt();
        const box = self.excerpt_box orelse return;
        const header = self.excerpt_header orelse return;
        const path = self.selectedPath() orelse {
            u.setLabel(header, "Current side — select a file");
            return;
        };
        // The side toggle chooses which file side the lower pane shows. The
        // original side is always read-only; the current side binds to a real
        // open Document for editable excerpts when one is available.
        if (self.side == .original) {
            u.setLabel(header, "Original side — read-only (captured snapshot)");
            self.appendReadOnly(box, self.originalSideText());
            return;
        }
        const repo = self.repository() orelse return;
        const absolute = std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, repo.path, "/"), path }) catch return;
        defer a.free(absolute);
        // Bind to a real open Document when present; otherwise the current side
        // stays read-only and the parent may open the file via Save/Open.
        var document: ?*@import("../document.zig").Document = null;
        for (self.app.snapshotDocuments()) |d| {
            if (d.path) |dp| if (std.mem.eql(u8, dp, absolute)) {
                document = d;
                break;
            };
        }
        const d = document orelse {
            u.setLabel(header, "Current side — read-only (open the file to edit excerpts)");
            self.appendReadOnly(box, self.currentSideText());
            return;
        };
        const h = self.currentHunk();
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const range = excerptRange(text, h) orelse {
            u.setLabel(header, "Current side — read-only (hunk region not present in the buffer)");
            self.appendReadOnly(box, self.currentSideText());
            return;
        };
        const target = self.targetFor(d);
        var excerpt = excerpt_model.Excerpt.init(a, target, range, false, .{}) catch {
            u.setLabel(header, "Current side — read-only (excerpt unavailable)");
            self.appendReadOnly(box, self.currentSideText());
            return;
        };
        const header_text = u.fmt("Current side · {s} (editable; unsaved edits are excluded from staging)", .{path});
        defer a.free(header_text);
        const editor = ExcerptEditor.create(a, excerpt, header_text, .{
            .context = self,
            .resolve = &resolveExcerpt,
            .history = &self.app.history,
            .committed = &onExcerptCommitted,
            .failed = &onExcerptFailed,
        }) catch {
            excerpt.deinit();
            u.setLabel(header, "Current side — read-only (editor unavailable)");
            self.appendReadOnly(box, self.currentSideText());
            return;
        };
        self.excerpt = editor;
        self.excerpt_document = d.id;
        u.setLabel(header, header_text);
        c.gtk_widget_set_vexpand(editor.root, 1);
        c.gtk_box_append(u.cast(c.GtkBox, box), editor.root);
        self.updateWarning();
    }
    fn currentSideText(self: *Controller) []const u8 {
        return self.sideText('+');
    }
    fn originalSideText(self: *Controller) []const u8 {
        return self.sideText('-');
    }
    fn sideText(self: *Controller, change_tag: u8) []const u8 {
        const file = self.file_diff orelse return "";
        if (file.kind != .text) return "";
        // Reconstruct one side from the captured diff for a read-only fallback.
        var out: std.ArrayList(u8) = .empty;
        for (file.hunks) |h| {
            for (h.lines) |l| {
                if (l.tag == ' ' or l.tag == change_tag) {
                    out.appendSlice(a, l.text) catch return out.items;
                    out.append(a, '\n') catch return out.items;
                }
            }
        }
        return out.items;
    }
    fn appendReadOnly(self: *Controller, box: u.W, text: []const u8) void {
        _ = self;
        const buffer = c.gtk_source_buffer_new(null).?;
        c.gtk_text_buffer_set_text(u.cast(c.GtkTextBuffer, buffer), text.ptr, @intCast(text.len));
        const view = c.gtk_source_view_new_with_buffer(buffer).?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_widget_set_vexpand(view, 1);
        c.gtk_box_append(u.cast(c.GtkBox, box), view);
    }
    fn targetFor(self: *Controller, d: *@import("../document.zig").Document) tx.Target {
        return .{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = d.revision, .busy = d.loading or d.pending != null, .writable = !self.app.editingFrozen() };
    }
    fn resolveExcerpt(context: ?*anyopaque, id: u64) ?tx.Target {
        const self = u.cast(Controller, context.?);
        for (self.app.snapshotDocuments()) |d| if (d.id == id) return self.targetFor(d);
        return null;
    }
    fn onExcerptCommitted(context: ?*anyopaque) void {
        const self = u.cast(Controller, context.?);
        self.updateWarning();
        if (self.edit_committed) |cb| cb(self.callback_context);
    }
    fn onExcerptFailed(context: ?*anyopaque, err: anyerror) void {
        const self = u.cast(Controller, context.?);
        if (self.edit_failed) |cb| cb(self.callback_context, err);
        const text = u.fmt("Excerpt edit refused: {s}", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn updateWarning(self: *Controller) void {
        const label = self.warning orelse return;
        var dirty: usize = 0;
        for (self.app.snapshotDocuments()) |d| if (d.dirty()) {
            dirty += 1;
        };
        const text = u.fmt("Unsaved editor documents: {d} (excluded from staging; never saved). Staging uses the captured disk/index snapshot. Save to include your edits.", .{dirty});
        defer a.free(text);
        u.setLabel(label, text);
    }
    pub fn saveCurrent(self: *Controller) void {
        const id = self.excerpt_document orelse {
            self.message("Open the file in an editable excerpt before saving.");
            return;
        };
        if (self.save_document) |cb| {
            cb(self.callback_context, id);
        } else {
            self.app.message("Project Diff: no Save handler is wired by the parent.");
        }
        self.updateWarning();
    }

    fn updateActions(self: *Controller) void {
        const enabled = self.valid() and self.selected_file != null and self.job == null and self.pending == .none and self.mutation == null;
        const hunk_enabled = enabled and self.selected_hunk != null and self.file_diff != null and self.file_diff.?.kind == .text;
        if (self.stage_hunk_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(hunk_enabled));
        if (self.unstage_hunk_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(hunk_enabled));
        const sel_enabled = hunk_enabled and self.selected_lines.items.len > 0;
        if (self.stage_sel_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(sel_enabled));
        if (self.unstage_sel_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(sel_enabled));
        if (self.save_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(self.excerpt_document != null));
    }

    // -- Window ---------------------------------------------------------------

    fn createWindow(self: *Controller) void {
        if (self.window != null) return;
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Project Diff — editable excerpts, hunk and selection staging");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 1000, 800);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);

        const bar = u.box(true, 8);
        u.append(box, bar);
        u.append(bar, u.label("File"));
        const picker = c.gtk_combo_box_text_new().?;
        self.file_picker = picker;
        c.gtk_widget_set_hexpand(picker, 1);
        u.append(bar, picker);
        u.connect(picker, "changed", &fileChanged, self);
        const refresh_button = u.button("Refresh");
        u.append(bar, refresh_button);
        u.connect(refresh_button, "clicked", &refreshClicked, self);
        const mode = c.gtk_combo_box_text_new().?;
        self.mode_picker = mode;
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "Unified");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "Split");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, mode), "Word");
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, mode), 0);
        u.append(bar, mode);
        u.connect(mode, "changed", &modeChanged, self);
        const side = c.gtk_combo_box_text_new().?;
        self.side_picker = side;
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, side), "Original");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, side), "Current");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, side), "Both");
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, side), 2);
        u.append(bar, side);
        u.connect(side, "changed", &sideChanged, self);
        const staged_picker = c.gtk_combo_box_text_new().?;
        self.staged_picker = staged_picker;
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, staged_picker), "Unstaged diff (index → disk)");
        c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, staged_picker), "Staged diff (HEAD → index)");
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, staged_picker), 0);
        u.append(bar, staged_picker);
        u.connect(staged_picker, "changed", &stagedChanged, self);

        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const warning = u.label("");
        self.warning = warning;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, warning), 1);
        u.append(box, warning);

        const hunk_bar = u.box(true, 8);
        u.append(box, hunk_bar);
        const prev = u.button("Previous hunk");
        const next = u.button("Next hunk");
        u.append(hunk_bar, prev);
        u.append(hunk_bar, next);
        u.connect(prev, "clicked", &prevHunkClicked, self);
        u.connect(next, "clicked", &nextHunkClicked, self);
        self.hunk_label = u.label("No hunks");
        u.append(hunk_bar, self.hunk_label.?);
        const stage_hunk = u.button("Stage hunk…");
        const unstage_hunk = u.button("Unstage hunk…");
        self.stage_hunk_button = stage_hunk;
        self.unstage_hunk_button = unstage_hunk;
        u.append(hunk_bar, stage_hunk);
        u.append(hunk_bar, unstage_hunk);
        u.connect(stage_hunk, "clicked", &stageHunkClicked, self);
        u.connect(unstage_hunk, "clicked", &unstageHunkClicked, self);

        const sel_bar = u.box(true, 8);
        u.append(box, sel_bar);
        u.append(sel_bar, u.label("Selection (change-line ranges)"));
        const entry = c.gtk_entry_new().?;
        self.selection_entry = entry;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, entry), "e.g. 0:2,3:4");
        u.append(sel_bar, entry);
        u.connect(entry, "activate", &selectionActivate, self);
        const stage_sel = u.button("Stage selection…");
        const unstage_sel = u.button("Unstage selection…");
        self.stage_sel_button = stage_sel;
        self.unstage_sel_button = unstage_sel;
        u.append(sel_bar, stage_sel);
        u.append(sel_bar, unstage_sel);
        u.connect(stage_sel, "clicked", &stageSelClicked, self);
        u.connect(unstage_sel, "clicked", &unstageSelClicked, self);
        const save = u.button("Save current file");
        self.save_button = save;
        u.append(sel_bar, save);
        u.connect(save, "clicked", &saveClicked, self);

        // Rendered diff (read-only): unified view or split pair.
        const diff_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(diff_scroll, 1);
        const view = c.gtk_source_view_new_with_buffer(c.gtk_source_buffer_new(null).?).?;
        self.diff_view = view;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_source_view_set_show_line_numbers(u.cast(c.GtkSourceView, view), 1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, diff_scroll), view);
        u.append(box, diff_scroll);
        const split = u.box(true, 8);
        self.split_box = split;
        const old_scroll = c.gtk_scrolled_window_new().?;
        const new_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(old_scroll, 1);
        c.gtk_widget_set_vexpand(new_scroll, 1);
        const old_view = c.gtk_source_view_new_with_buffer(c.gtk_source_buffer_new(null).?).?;
        const new_view = c.gtk_source_view_new_with_buffer(c.gtk_source_buffer_new(null).?).?;
        self.split_old = old_view;
        self.split_new = new_view;
        for ([_]*c.GtkWidget{ old_view, new_view }) |v| {
            c.gtk_text_view_set_editable(u.cast(c.GtkTextView, v), 0);
            c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, v), 1);
        }
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, old_scroll), old_view);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, new_scroll), new_view);
        u.append(split, old_scroll);
        u.append(split, new_scroll);
        u.append(box, split);

        // Editable current-side excerpt pane (original side stays read-only above).
        const excerpt_header = u.label("Current side");
        self.excerpt_header = excerpt_header;
        u.append(box, excerpt_header);
        const excerpt_box = u.box(false, 0);
        self.excerpt_box = excerpt_box;
        c.gtk_widget_set_vexpand(excerpt_box, 1);
        u.append(box, excerpt_box);

        self.app.styleWindow(window);
        self.app.installTestKeys(window);
        self.updateWarning();
        self.updateActions();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.destroyExcerpt();
        self.window = null;
        self.file_picker = null;
        self.mode_picker = null;
        self.side_picker = null;
        self.staged_picker = null;
        self.summary = null;
        self.warning = null;
        self.hunk_label = null;
        self.selection_entry = null;
        self.diff_view = null;
        self.split_box = null;
        self.split_old = null;
        self.split_new = null;
        self.excerpt_box = null;
        self.excerpt_header = null;
        self.stage_hunk_button = null;
        self.unstage_hunk_button = null;
        self.stage_sel_button = null;
        self.unstage_sel_button = null;
        self.save_button = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn renderFiles(self: *Controller) void {
        const picker = self.file_picker orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        c.gtk_combo_box_text_remove_all(u.cast(c.GtkComboBoxText, picker));
        for (self.files.items) |path| {
            const label = command.display(a, path, 1024) catch continue;
            defer a.free(label);
            const label_z = u.z(label);
            defer a.free(label_z);
            c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, picker), label_z.ptr);
        }
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, picker), if (self.selected_file) |index| @intCast(index) else -1);
    }

    // -- Mutation backend (reuses index_transaction prepare/apply) ------------

    fn beginMutation(self: *Controller, req: backend.Request, root_id: model.RootId, absolute: []const u8) !void {
        const snapshot = if (self.app.browser.model) |*value| value else return error.WorkspaceChanged;
        const token = snapshot.scope.capture() orelse return error.WorkspaceChanged;
        const workspace = self.app.workspace.capture() orelse return error.WorkspaceChanged;
        const job = try a.create(MutJob);
        errdefer a.destroy(job);
        job.* = .{
            .controller = self,
            .root = u.z(req.root),
            .gitdir = u.z(req.gitdir),
            .commondir = u.z(req.commondir),
            .path = u.z(req.path),
            .absolute = u.z(absolute),
            .index_path = u.fmt("{s}/index", .{req.gitdir}),
            .root_id = root_id,
            .action = req.action,
            .hunk = req.hunk,
            .selection = if (req.selection) |s| .{ .ordinal = s.ordinal, .ranges = a.dupe(hunk.LineRange, s.ranges) catch return error.OutOfMemory } else null,
            .generation = self.generation,
            .token = token,
            .workspace = workspace,
        };
        errdefer job.destroyFields();
        try self.checkMutation(job);
        self.mutation = job;
        self.mutation_error = null;
        self.mutation_committed = false;
        self.app.hold();
        self.mutation_state = .preparing;
        self.dispatchMutation(.prepare);
    }
    fn checkMutation(self: *Controller, job: *const MutJob) !void {
        if (self.app.closing or !self.app.git.valid() or self.app.git.generation != job.generation or job.cancel.load(.acquire)) return error.RequestChanged;
        if (!self.app.workspace.accepts(job.workspace)) return error.WorkspaceChanged;
        const snapshot = if (self.app.browser.model) |*value| value else return error.WorkspaceChanged;
        if (!snapshot.scope.accepts(job.token)) return error.WorkspaceChanged;
        const repo = self.repository() orelse return error.WorkspaceChanged;
        if (repo.root != job.root_id) return error.SelectionChanged;
        const path = self.selectedPath() orelse return error.SelectionChanged;
        if (!std.mem.eql(u8, path, job.path)) return error.SelectionChanged;
        const manager = self.app.manager orelse return error.NoManager;
        for (self.app.snapshotDocuments()) |doc| {
            if (doc.path) |dp| if (std.mem.eql(u8, dp, job.absolute)) {
                if (doc.busy or doc.loading or doc.pending != null or doc.pending_reload) return error.DocumentPending;
            };
        }
        try manager.checkFileOperation(self.app, job.index_path, "");
    }
    fn dispatchMutation(self: *Controller, phase: MutPhase) void {
        const job = self.mutation.?;
        std.debug.assert(!job.running);
        job.phase = phase;
        job.running = true;
        job.err = null;
        self.updateActions();
        const task = c.g_task_new(null, null, &mutDone, job).?;
        c.g_task_set_task_data(task, job, null);
        c.g_task_run_in_thread(task, &mutWorker);
        c.g_object_unref(task);
    }
    fn showMutationReview(self: *Controller) !void {
        const p = &self.mutation.?.prepared.?;
        const before = try previewBytes(p.before);
        defer a.free(before);
        const after = try previewBytes(p.after);
        defer a.free(after);
        const is_sel = self.mutation.?.selection != null;
        const heading = u.fmt("{s} {s}: {s}\nRepository: {s}\n{s}. Unsaved editor documents are excluded and NEVER saved; staging uses the captured disk/index snapshot. This changes only this path in the index; no commit or worktree write.\nComplete captured before/after bytes below. SHA-256 digests identify the original bytes.", .{
            if (p.action == .stage_hunk) "Stage" else "Unstage",
            if (is_sel) "selected change-lines" else "selected hunk",
            p.path,
            self.mutation.?.root,
            if (is_sel) "SELECTION, NOT THE WHOLE HUNK" else "ONE HUNK, NOT THE WHOLE FILE",
        });
        defer a.free(heading);
        a.free(self.mutation_review);
        self.mutation_review = u.fmt("{s}\n\nBEFORE — INDEX ({d} bytes):\n{s}\n\nAFTER — INDEX ({d} bytes):\n{s}", .{ heading, p.before.len, before, p.after.len, after });
        const dialog = c.gtk_dialog_new().?;
        self.mutation_dialog = dialog;
        self.mutation_state = .confirming;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), if (is_sel) "Review selection index change" else "Review hunk index change");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.window.?));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 900, 720);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "_Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), if (p.action == .stage_hunk) "_Stage reviewed change" else "_Unstage reviewed change", c.GTK_RESPONSE_ACCEPT);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        const content = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)).?);
        u.margin(content, 12);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        const view = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.mutation_review.ptr, @intCast(self.mutation_review.len));
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), view);
        u.append(content, scroll);
        u.connect(dialog, "response", &mutResponse, self);
        self.app.styleWindow(dialog);
        self.app.installTestKeys(dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn respondMutation(self: *Controller, accept: bool) void {
        if (self.mutation_dialog == null or self.mutation_state != .confirming) return;
        const job = self.mutation orelse return;
        if (!accept) {
            self.cancelMutation();
            return;
        }
        self.checkMutation(job) catch |err| {
            self.abortMutation(err);
            return;
        };
        self.app.manager.?.beginFileOperation(self.app, job.index_path, "") catch |err| {
            self.abortMutation(err);
            return;
        };
        job.barrier = true;
        job.attempted = true;
        self.closeMutationDialog();
        self.mutation_state = .applying;
        self.dispatchMutation(.apply);
    }
    fn closeMutationDialog(self: *Controller) void {
        const dialog = self.mutation_dialog orelse return;
        self.mutation_dialog = null;
        _ = c.g_signal_handlers_disconnect_matched(dialog, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, dialog));
    }
    fn abortMutation(self: *Controller, err: anyerror) void {
        self.mutation_error = @errorName(err);
        self.closeMutationDialog();
        if (!self.app.closing) {
            const text = u.fmt("Project Diff index change refused: {s}. No index change was published.", .{@errorName(err)});
            defer a.free(text);
            self.message(text);
        }
        if (self.mutation) |job| {
            job.outcome = .failed;
            job.cancel.store(true, .release);
            if (!job.running) self.retireMutation();
        } else self.mutation_state = .failed;
    }
    fn cancelMutation(self: *Controller) void {
        if (self.mutation) |job| job.cancel.store(true, .release);
        self.closeMutationDialog();
        const job = self.mutation orelse return;
        if (job.outcome != .failed) job.outcome = .cancelled;
        if (!job.running) self.retireMutation();
    }
    fn retireMutation(self: *Controller) void {
        const job = self.mutation.?;
        std.debug.assert(!job.running);
        if (job.prepared != null) {
            self.mutation_state = .retiring;
            self.dispatchMutation(.retire);
        } else self.finishMutation();
    }
    fn finishMutation(self: *Controller) void {
        const job = self.mutation.?;
        std.debug.assert(!job.running and job.prepared == null);
        if (job.barrier) {
            self.app.manager.?.endFileOperation(self.app);
            job.barrier = false;
        }
        self.closeMutationDialog();
        self.mutation_state = job.outcome;
        const should_refresh = job.attempted;
        self.mutation = null;
        job.destroyFields();
        a.destroy(job);
        self.app.release();
        self.updateActions();
        if (should_refresh and self.app.git.valid()) {
            self.app.git.refresh();
            self.refresh();
        }
    }

    // -- Callbacks ------------------------------------------------------------

    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn fileChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const index = c.gtk_combo_box_get_active(picker);
        if (index >= 0) self.selectFile(@intCast(index));
    }
    fn modeChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        self.setMode(switch (c.gtk_combo_box_get_active(picker)) {
            1 => .split,
            2 => .word,
            else => .unified,
        });
    }
    fn sideChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        self.setSide(switch (c.gtk_combo_box_get_active(picker)) {
            0 => .original,
            1 => .current,
            else => .both,
        });
    }
    fn stagedChanged(picker: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        self.setStaged(c.gtk_combo_box_get_active(picker) == 1);
    }
    fn refreshClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).refresh();
    }
    fn prevHunkClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).previousHunk();
    }
    fn nextHunkClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).nextHunk();
    }
    fn stageHunkClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).stageHunk();
    }
    fn unstageHunkClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).unstageHunk();
    }
    fn stageSelClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).stageSelection();
    }
    fn unstageSelClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).unstageSelection();
    }
    fn saveClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).saveCurrent();
    }
    fn selectionActivate(entry: ?*c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        self.selectLines(u.entryText(u.cast(c.GtkWidget, entry.?)));
    }
    fn mutResponse(dialog: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.mutation_dialog != u.cast(c.GtkWidget, dialog.?)) return;
        self.respondMutation(id == c.GTK_RESPONSE_ACCEPT);
    }

    /// Test-only bridge. The parent dispatches these actions; approval answers
    /// only the currently visible native review dialog, never grants trust.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "project-diff-probe")) self.probe() else if (std.mem.eql(u8, action, "project-diff-show")) self.show() else if (std.mem.eql(u8, action, "project-diff-close")) self.invalidate() else if (std.mem.eql(u8, action, "project-diff-refresh")) self.refresh() else if (std.mem.eql(u8, action, "project-diff-select-file")) self.selectFile(std.fmt.parseInt(usize, value, 10) catch return true) else if (std.mem.eql(u8, action, "project-diff-mode")) {
            self.setMode(if (std.mem.eql(u8, value, "split")) .split else if (std.mem.eql(u8, value, "word")) .word else .unified);
        } else if (std.mem.eql(u8, action, "project-diff-side")) {
            self.setSide(if (std.mem.eql(u8, value, "original")) .original else if (std.mem.eql(u8, value, "current")) .current else .both);
        } else if (std.mem.eql(u8, action, "project-diff-staged")) {
            self.setStaged(std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "staged"));
        } else if (std.mem.eql(u8, action, "project-diff-next-hunk")) self.nextHunk() else if (std.mem.eql(u8, action, "project-diff-prev-hunk")) self.previousHunk() else if (std.mem.eql(u8, action, "project-diff-stage-hunk")) self.stageHunk() else if (std.mem.eql(u8, action, "project-diff-unstage-hunk")) self.unstageHunk() else if (std.mem.eql(u8, action, "project-diff-stage-selection")) self.stageSelection() else if (std.mem.eql(u8, action, "project-diff-unstage-selection")) self.unstageSelection() else if (std.mem.eql(u8, action, "project-diff-select-lines")) self.selectLines(value) else if (std.mem.eql(u8, action, "project-diff-save")) self.saveCurrent() else if (std.mem.eql(u8, action, "project-diff-accept")) {
            if (self.mutation_dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_ACCEPT);
        } else if (std.mem.eql(u8, action, "project-diff-reject")) {
            if (self.mutation_dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        } else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .visible = self.window != null,
            .git_valid = self.app.git.valid(),
            .generation = self.generation,
            .busy = self.job != null,
            .pending = @tagName(self.pending),
            .launches = self.launches,
            .discarded = self.discarded,
            .jobs_reaped = self.jobs_reaped,
            .files = self.files.items,
            .file_count = self.files.items.len,
            .selected_file = self.selected_file,
            .mode = @tagName(self.mode),
            .side = @tagName(self.side),
            .staged = self.staged,
            .hunk_count = self.hunk_refs.items.len,
            .selected_hunk = self.selected_hunk,
            .selected_lines = self.selected_lines.items,
            .diff_kind = self.diff_kind,
            .excerpt_document = self.excerpt_document,
            .excerpt_editable = if (self.excerpt) |e| c.gtk_text_view_get_editable(u.cast(c.GtkTextView, e.widget)) != 0 else false,
            .mutation_state = @tagName(self.mutation_state),
            .mutation_busy = self.mutation != null,
            .mutation_dialog = self.mutation_dialog != null,
            .mutation_err = self.mutation_error,
            .mutation_committed = self.mutation_committed,
            .mutation_review = self.mutation_review,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_PROJECT_DIFF %s\n", line.ptr);
    }
};

/// Map a hunk's new-side line span to a UTF-8 byte range in the current buffer.
fn excerptRange(text: []const u8, h: ?hunk.Hunk) ?excerpt_model.Range {
    const hh = h orelse return .{ .start = 0, .end = text.len };
    if (hh.new_count == 0) {
        const start = lineStart(text, hh.new_start) orelse return null;
        return .{ .start = start, .end = start };
    }
    const start = lineStart(text, hh.new_start) orelse return null;
    const end = lineStart(text, hh.new_start + hh.new_count) orelse text.len;
    return .{ .start = start, .end = end };
}
/// Byte offset of 1-based line `no` (clamped to EOF). Returns null only for no==0.
fn lineStart(text: []const u8, no: usize) ?usize {
    if (no == 0) return null;
    var line: usize = 1;
    var i: usize = 0;
    while (line < no and i < text.len) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return i;
}

fn previewBytes(bytes: []const u8) ![]u8 {
    if (bytes.len > backend.max_file_bytes) return error.PreviewTooLarge;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        if (count > 4000 or line.len > 2048) return error.PreviewTooLarge;
        const escaped = try status.displayLabel(a, line);
        defer a.free(escaped);
        try out.appendSlice(a, escaped);
        try out.appendSlice(a, "\\n\n");
        if (out.items.len > backend.max_file_bytes) return error.PreviewTooLarge;
    }
    return out.toOwnedSlice(a);
}

const MutJob = struct {
    controller: *Controller,
    root: [:0]u8,
    gitdir: [:0]u8,
    commondir: [:0]u8,
    path: [:0]u8,
    absolute: [:0]u8,
    index_path: [:0]u8,
    root_id: model.RootId,
    action: backend.Action,
    hunk: ?backend.HunkRef = null,
    selection: ?backend.Selection = null,
    generation: u64,
    token: @import("../workspace/identity.zig").Token,
    workspace: @import("../workspace/identity.zig").Token,
    cancel: backend.Cancel = .init(false),
    prepared: ?backend.Prepared = null,
    err: ?anyerror = null,
    phase: MutPhase = .prepare,
    running: bool = false,
    barrier: bool = false,
    attempted: bool = false,
    outcome: MutState = .cancelled,
    result: backend.Outcome = .{ .committed = false },

    fn destroyFields(self: *MutJob) void {
        inline for (.{ "root", "gitdir", "commondir", "path", "absolute", "index_path" }) |field| a.free(@field(self, field));
        if (self.selection) |s| a.free(s.ranges);
    }
    fn perform(self: *MutJob) !void {
        switch (self.phase) {
            .prepare => self.prepared = try backend.prepare(a, .{
                .root = self.root,
                .gitdir = self.gitdir,
                .commondir = self.commondir,
                .path = self.path,
                .action = self.action,
                .hunk = self.hunk,
                .selection = self.selection,
            }, &self.cancel),
            .apply => {
                defer self.clearPrepared();
                self.result = try backend.apply(&self.prepared.?, &self.cancel);
            },
            .retire => self.clearPrepared(),
        }
    }
    fn clearPrepared(self: *MutJob) void {
        if (self.prepared) |*p| p.deinit();
        self.prepared = null;
    }
};

fn mutWorker(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(MutJob, data.?);
    job.perform() catch |err| {
        job.err = err;
    };
    c.g_task_return_boolean(task, 1);
}
fn mutDone(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(MutJob, data.?);
    const self = job.controller;
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, result.?), null);
    std.debug.assert(self.mutation == job and job.running);
    job.running = false;
    self.jobs_reaped += 1;
    if (job.phase == .retire) {
        self.finishMutation();
        return;
    }
    if (job.result.committed) {
        job.outcome = .succeeded;
        self.mutation_committed = true;
        self.mutation_error = null;
        if (!self.app.closing) self.app.message("Project Diff index change committed. No commit or worktree file was written.");
        self.finishMutation();
        return;
    }
    if (job.cancel.load(.acquire) or self.app.closing) {
        self.retireMutation();
        return;
    }
    if (job.err) |err| {
        self.abortMutation(err);
        return;
    }
    if (job.phase == .apply) {
        self.abortMutation(error.NotCommitted);
        return;
    }
    self.checkMutation(job) catch |err| {
        self.abortMutation(err);
        return;
    };
    self.showMutationReview() catch |err| self.abortMutation(err);
}
