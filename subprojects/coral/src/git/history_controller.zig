//! M4 native history workflows: bounded file history log, commit diff, blame
//! porcelain, and GitHub/GitLab/Codeberg blob permalinks opened only after a
//! separate external-link confirmation. There is no PR API.
//!
//! Like the remote controller, this requires the parent Source Control
//! disclosure (app.git.valid()) and a selected repository (app.git.repo()). All
//! Git inspection uses command.zig's locked-down read-only policy; no network or
//! repository writes occur here. The only outward action is launching a validated
//! https permalink in the user's default browser, and only after explicit consent.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("../tasks/process.zig");
const command = @import("command.zig");
const history = @import("history.zig");
const remote = @import("remote.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = 1024 * 1024;
pub const inspect_timeout_ms = 15_000;
const output_budget = 64 * 1024;

const Phase = enum { log, blame, diff, remote };
const Intent = enum { none, history, blame, diff, permalink };

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    generation: u64 = 1,
    phase: Phase = .log,
    pending: Intent = .none,
    window: ?u.W = null,
    summary: ?u.W = null,
    log_list: ?u.W = null,
    output_label: ?u.W = null,
    output_view: ?u.W = null,
    blame_button: ?u.W = null,
    diff_button: ?u.W = null,
    permalink_button: ?u.W = null,
    rebuilding: bool = false,
    message_text: [:0]u8,
    output_text: [:0]u8,
    output_kind: []const u8 = "none",
    file_path: ?[]const u8 = null,
    log: ?history.Log = null,
    selected_commit: ?usize = null,
    blame: ?history.Blame = null,
    selected_line: ?usize = null,
    remote_url: ?[]const u8 = null,
    permalink: ?[]u8 = null,
    external_approval: UI,
    launches: u64 = 0,
    discarded: u64 = 0,
    jobs_reaped: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .external_approval = .{ .context = app, .respond = &externalAnswered },
            .message_text = u.z("History — open Source Control first"),
            .output_text = u.z(""),
        };
    }
    pub fn deinit(self: *Controller) void {
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
        self.external_approval.close();
        self.closeWindow();
        self.clearResults();
        self.setFile(null);
        self.setOutput("none", "");
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("Git history generation exhausted");
        self.pending = .none;
        if (self.job) |job| job.cancel();
    }
    fn clearResults(self: *Controller) void {
        self.selected_commit = null;
        self.selected_line = null;
        if (self.log) |*value| value.deinit();
        self.log = null;
        if (self.blame) |*value| value.deinit();
        self.blame = null;
        if (self.permalink) |value| a.free(value);
        self.permalink = null;
        self.setRemoteUrl(null);
        _ = self.arena.reset(.free_all);
        self.renderLog();
    }
    fn setFile(self: *Controller, path: ?[]const u8) void {
        if (self.file_path) |old| a.free(old);
        self.file_path = if (path) |p| a.dupe(u8, p) catch null else null;
    }
    fn setRemoteUrl(self: *Controller, url: ?[]const u8) void {
        if (self.remote_url) |old| a.free(old);
        self.remote_url = if (url) |p| a.dupe(u8, p) catch null else null;
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        self.pending = .none;
        const text = u.fmt("Git history: {s}. Try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn setOutput(self: *Controller, kind: []const u8, text: []const u8) void {
        self.output_kind = kind;
        a.free(self.output_text);
        self.output_text = u.z(text);
        if (self.output_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.output_text.ptr, @intCast(self.output_text.len));
        if (self.output_label) |label| u.setLabel(label, "Git output (read-only)");
    }
    fn ready(self: *Controller) bool {
        return !self.app.closing and self.app.git.valid() and self.app.git.repo() != null;
    }
    /// Derive a repository-relative path from the active document. Lexical only.
    fn resolveFile(self: *Controller) ?[]const u8 {
        const repository = self.app.git.repo() orelse return null;
        const doc = self.app.active() orelse return null;
        const path = doc.path orelse return null;
        if (!command.contains(repository.path, path)) return null;
        var rel = path[repository.path.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (!history.validRelPath(rel)) return null;
        return rel;
    }
    fn ensureFile(self: *Controller) bool {
        if (self.file_path != null) return true;
        const rel = self.resolveFile() orelse return false;
        self.setFile(rel);
        return self.file_path != null;
    }
    fn selectedOid(self: *Controller) ?[]const u8 {
        const index = self.selected_commit orelse return null;
        const value = self.log orelse return null;
        if (index >= value.entries.len) return null;
        return value.entries[index].oid;
    }

    pub fn showHistory(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository first.");
            return;
        }
        if (self.window == null) self.createWindow();
        self.cancel();
        self.clearResults();
        if (!self.ensureFile()) {
            self.message("Open a file inside the selected repository to view its history.");
            return;
        }
        self.message("Reading file history — read-only…");
        self.setOutput("loading", "Loading commit log…");
        self.pending = .history;
        self.drain();
    }
    pub fn showBlame(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository first.");
            return;
        }
        if (self.window == null) self.createWindow();
        if (!self.ensureFile()) {
            self.message("Open a file inside the selected repository to blame.");
            return;
        }
        self.cancel();
        self.message("Reading blame — read-only, bounded…");
        self.setOutput("loading", "Loading blame porcelain…");
        self.pending = .blame;
        self.drain();
    }
    pub fn showCommitDiff(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository first.");
            return;
        }
        if (self.selectedOid() == null) {
            self.message("Select a commit from the file history first.");
            return;
        }
        if (self.window == null) self.createWindow();
        self.cancel();
        self.message("Reading commit diff — read-only…");
        self.setOutput("loading", "Loading commit diff…");
        self.pending = .diff;
        self.drain();
    }
    pub fn showPermalink(self: *Controller) void {
        if (self.app.closing) return;
        if (!self.app.git.valid()) {
            self.app.git.show();
            return;
        }
        if (!self.ready()) {
            self.app.message("Open Source Control and select a repository first.");
            return;
        }
        if (self.selectedOid() == null) {
            self.message("Select a commit from the file history first.");
            return;
        }
        if (!self.ensureFile()) {
            self.message("Open a file inside the selected repository first.");
            return;
        }
        if (self.remote_url == null) {
            self.cancel();
            self.pending = .permalink;
            self.drain();
        } else self.buildPermalinkNow();
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
            .history => self.startHistory() catch |err| self.failure(err),
            .blame => self.startBlame() catch |err| self.failure(err),
            .diff => self.startDiff() catch |err| self.failure(err),
            .permalink => self.startRemote() catch |err| self.failure(err),
            .none => {},
        }
    }
    fn startHistory(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const path = self.file_path orelse return error.NoFile;
        const args = try history.logArgs(self.arena.allocator(), path, history.max_log_entries);
        try self.launch(.log, repository.path, args, capture_bytes);
    }
    fn startBlame(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const path = self.file_path orelse return error.NoFile;
        const rev = self.selectedOid() orelse "HEAD";
        const args = try history.blameArgs(self.arena.allocator(), rev, path);
        try self.launch(.blame, repository.path, args, capture_bytes);
    }
    fn startDiff(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        const oid = self.selectedOid() orelse return error.NoSelection;
        const args = try history.commitDiffArgs(self.arena.allocator(), oid);
        try self.launch(.diff, repository.path, args, capture_bytes);
    }
    fn startRemote(self: *Controller) !void {
        const repository = self.app.git.repo() orelse return error.NoRepository;
        try self.launch(.remote, repository.path, remote.listArgs(), 65536);
    }
    fn launch(self: *Controller, phase: Phase, cwd: []const u8, args: []const []const u8, limit: usize) !void {
        if (!self.ready()) return error.Restricted;
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
            .identity = .{ .scope = "git-history", .request = self.launches + 1, .generation = self.generation, .workspace = token },
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
        if (result.outcome != .success) {
            const text = u.fmt("Git {s}: {s} (exit {d}). No partial result is shown.", .{ @tagName(self.phase), @tagName(result.outcome), result.exit_code orelse -1 });
            defer a.free(text);
            self.message(text);
            self.setOutput("error", "Git did not produce a complete result.");
            return;
        }
        switch (self.phase) {
            .log => {
                const value = try history.parseLog(a, result.stdout);
                if (self.log) |*old| old.deinit();
                self.log = value;
                self.selected_commit = if (value.entries.len > 0) 0 else null;
                self.renderLog();
                const text = u.fmt("{d} commits for {s}. Select a commit for its diff or permalink.", .{ value.entries.len, self.file_path orelse "" });
                defer a.free(text);
                self.message(text);
            },
            .blame => {
                const value = try history.parseBlame(a, result.stdout);
                if (self.blame) |*old| old.deinit();
                self.blame = value;
                self.selected_line = if (value.lines.len > 0) 0 else null;
                self.renderBlameOutput();
                const text = u.fmt("Blame: {d} lines (bounded).", .{value.lines.len});
                defer a.free(text);
                self.message(text);
            },
            .diff => {
                switch (command.preview(result.stdout)) {
                    .binary => self.setOutput("binary", "Binary change — no textual diff is available."),
                    .non_utf8 => self.setOutput("non-utf8", "Non-UTF-8 change — text preview is unavailable."),
                    .too_large => self.setOutput("limited", "Diff exceeds native preview limits. No partial diff is shown."),
                    .text => self.setOutput("text", if (result.stdout.len == 0) "No differences for this commit." else result.stdout),
                }
                self.message("Commit diff loaded (read-only).");
            },
            .remote => {
                var list = try remote.parseRemotes(a, result.stdout);
                defer list.deinit();
                var chosen: ?[]const u8 = null;
                for (list.remotes) |entry| {
                    if (std.mem.eql(u8, entry.name, "origin")) {
                        chosen = entry.fetch_url;
                        break;
                    }
                }
                if (chosen == null and list.remotes.len > 0) chosen = list.remotes[0].fetch_url;
                if (chosen) |url| {
                    self.setRemoteUrl(url);
                    self.buildPermalinkNow();
                } else self.message("No remote is configured; a permalink cannot be built.");
            },
        }
    }
    fn buildPermalinkNow(self: *Controller) void {
        const oid = self.selectedOid() orelse {
            self.message("Select a commit first.");
            return;
        };
        const path = self.file_path orelse {
            self.message("No file selected.");
            return;
        };
        const url_remote = self.remote_url orelse {
            self.message("No remote URL is available.");
            return;
        };
        const line = if (self.selected_line) |index| blk: {
            if (self.blame) |value| {
                if (index < value.lines.len) break :blk value.lines[index].line_no;
            }
            break :blk @as(usize, 1);
        } else @as(usize, 1);
        const url = history.buildPermalink(a, url_remote, oid, path, line) catch |err| {
            const text = u.fmt("Permalink unavailable: {s}. Only GitHub/GitLab/Codeberg https remotes are supported.", .{@errorName(err)});
            defer a.free(text);
            self.message(text);
            return;
        };
        if (self.permalink) |old| a.free(old);
        self.permalink = url;
        self.external_approval.context = self;
        self.external_approval.show(self.app, "Open external link?", url, &.{}, false, "Open in default browser");
    }
    fn externalAnswered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        if (!accepted or self.app.closing or !self.ready()) return;
        const url = self.permalink orelse return;
        history.validateHttpsUrl(url) catch {
            self.message("Refusing to open an invalid URL.");
            return;
        };
        const target = u.z(url);
        defer a.free(target);
        if (c.g_app_info_launch_default_for_uri(target, null, null) == 0) {
            self.message("Could not open the external link.");
        } else self.message("Opened permalink in the default browser.");
    }

    fn updateActions(self: *Controller) void {
        const enabled = self.ready() and self.job == null and self.pending == .none;
        const has_commit = self.selectedOid() != null;
        if (self.blame_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and self.file_path != null));
        if (self.diff_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and has_commit));
        if (self.permalink_button) |button| c.gtk_widget_set_sensitive(button, @intFromBool(enabled and has_commit and self.file_path != null));
    }
    fn selectCommit(self: *Controller, index: usize) void {
        if (self.log) |value| {
            if (index < value.entries.len) {
                self.selected_commit = index;
                self.updateActions();
            }
        }
    }
    fn renderLog(self: *Controller) void {
        const list = self.log_list orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        if (self.log) |value| {
            for (value.entries) |entry| {
                const subject = command.display(a, entry.subject, 512) catch unreachable;
                defer a.free(subject);
                const author = command.display(a, entry.author, 256) catch unreachable;
                defer a.free(author);
                const text = u.fmt("{s}  {s}  ({s}, {s})", .{ entry.oid[0..@min(entry.oid.len, 12)], subject, author, entry.date });
                defer a.free(text);
                const label = u.label(text);
                c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
                c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
                c.gtk_widget_set_tooltip_text(label, text);
                u.margin(label, 4);
                c.gtk_list_box_append(u.cast(c.GtkListBox, list), label);
            }
        }
        if (self.selected_commit) |index| {
            c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), @intCast(index)));
        }
        self.updateActions();
    }
    fn renderBlameOutput(self: *Controller) void {
        const value = self.blame orelse {
            self.setOutput("none", "");
            return;
        };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        for (value.lines) |line| {
            if (out.items.len >= output_budget) break;
            const text = u.fmt("{d} {s} {s}: {s}\n", .{ line.line_no, line.oid[0..@min(line.oid.len, 12)], line.author, line.text });
            defer a.free(text);
            appendSanitized(&out, text, output_budget) catch break;
        }
        self.setOutput("blame", out.items);
    }

    fn createWindow(self: *Controller) void {
        if (self.window != null) return;
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Source Control — history, blame, permalink");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 960, 720);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const actions = u.box(true, 8);
        u.append(box, actions);
        const refresh = u.button("Reload history");
        u.append(actions, refresh);
        u.connect(refresh, "clicked", &historyClicked, self);
        const blame = u.button("Blame file");
        const diff = u.button("Commit diff");
        const permalink = u.button("Permalink…");
        self.blame_button = blame;
        self.diff_button = diff;
        self.permalink_button = permalink;
        u.append(actions, blame);
        u.append(actions, diff);
        u.append(actions, permalink);
        u.connect(blame, "clicked", &blameClicked, self);
        u.connect(diff, "clicked", &diffClicked, self);
        u.connect(permalink, "clicked", &permalinkClicked, self);
        u.append(box, u.label("File history (select a commit)"));
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(scroll, -1, 200);
        const list = c.gtk_list_box_new().?;
        self.log_list = list;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, list), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        u.append(box, scroll);
        u.connect(list, "row-selected", &commitSelected, self);
        const output_label = u.label("Git output (read-only)");
        self.output_label = output_label;
        u.append(box, output_label);
        const output_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(output_scroll, 1);
        const view = c.gtk_text_view_new().?;
        self.output_view = view;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, view), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, view), c.GTK_WRAP_NONE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, output_scroll), view);
        u.append(box, output_scroll);
        self.app.styleWindow(window);
        self.app.installTestKeys(window);
        self.updateActions();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.summary = null;
        self.log_list = null;
        self.output_label = null;
        self.output_view = null;
        self.blame_button = null;
        self.diff_button = null;
        self.permalink_button = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn commitSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const selected = row orelse {
            self.selected_commit = null;
            self.updateActions();
            return;
        };
        const index = c.gtk_list_box_row_get_index(selected);
        if (index >= 0) self.selectCommit(@intCast(index));
    }
    fn historyClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showHistory();
    }
    fn blameClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showBlame();
    }
    fn diffClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showCommitDiff();
    }
    fn permalinkClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).showPermalink();
    }

    /// Test-only bridge. External acceptance answers the actual confirmation
    /// dialog; it never bypasses the parent Source Control permit.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "git-history-probe")) self.probe() else if (std.mem.eql(u8, action, "git-history-close")) self.invalidate() else if (std.mem.eql(u8, action, "git-history-file")) self.setFile(value) else if (std.mem.eql(u8, action, "git-history-show")) self.showHistory() else if (std.mem.eql(u8, action, "git-history-blame")) self.showBlame() else if (std.mem.eql(u8, action, "git-history-diff")) self.showCommitDiff() else if (std.mem.eql(u8, action, "git-history-permalink")) self.showPermalink() else if (std.mem.eql(u8, action, "git-history-select")) self.selectCommit(std.fmt.parseInt(usize, value, 10) catch return true) else if (std.mem.eql(u8, action, "git-history-line")) {
            self.selected_line = std.fmt.parseInt(usize, value, 10) catch return true;
        } else if (std.mem.eql(u8, action, "git-history-external-accept")) self.external_approval.answer(true, null, "") else if (std.mem.eql(u8, action, "git-history-external-reject")) self.external_approval.answer(false, null, "") else return false;
        return true;
    }
    pub fn probe(self: *Controller) void {
        if (!hooks) return;
        const LogProbe = struct { oid: []const u8, author: []const u8, date: []const u8, subject: []const u8 };
        var entries: [history.max_log_entries]LogProbe = undefined;
        var count: usize = 0;
        if (self.log) |value| {
            for (value.entries) |entry| {
                entries[count] = .{ .oid = entry.oid, .author = entry.author, .date = entry.date, .subject = entry.subject };
                count += 1;
            }
        }
        const blame_count = if (self.blame) |value| value.lines.len else 0;
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
            .file = self.file_path,
            .log = entries[0..count],
            .selected_commit = self.selected_commit,
            .blame_lines = blame_count,
            .selected_line = self.selected_line,
            .remote_url = self.remote_url,
            .permalink = self.permalink,
            .external_disclosure = self.external_approval.window != null,
            .output_kind = self.output_kind,
            .output = self.output_text,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_GIT_HISTORY %s\n", line.ptr);
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
