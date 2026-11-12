//! Native M5 tasks: a bounded task picker, run/stop/restart, captured output and
//! a problem list with file/line/message/severity. Definitions come from the
//! workspace `.coral/tasks.json` (task.zig); output is captured by the supervised
//! tasks/process.zig boundary (not a PTY) and classified by matcher.zig.
//!
//! Executable workspace content is gated twice: the workspace trust permit
//! (.tasks) AND an explicit per-run review of the exact argv/cwd/environment.
//! Neither is an OS sandbox; a reviewed command runs with the user's permissions.
//! Async jobs use App.hold/release, generation/workspace tokens and the process
//! supervisor's cancellation/reaping. Tasks do not take the manager file barrier:
//! they are not assumed to mutate workspace files, but the trust gate still
//! applies. Navigation is delegated to a parent-supplied callback (open file/line).
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const process = @import("process.zig");
const task = @import("task.zig");
const matcher = @import("matcher.zig");
const trust = @import("../workspace/trust.zig");
const identity = @import("../workspace/identity.zig");
const UI = @import("../language/ui.zig").UI;
const hooks = @import("build_options").test_hooks;

pub const capture_bytes = task.limits.output_bytes;
pub const max_problems = matcher.limits.problems;
pub const max_tasks = task.limits.tasks;
pub const max_visible_problems = 256;

const Phase = enum { idle, loading, running };
const DialogAction = enum { trust, run };

const disclosure =
    "Tasks run workspace-defined commands as your user, only in a trusted workspace and only after you review the exact command. " ++
    "Definitions are read from .coral/tasks.json in each workspace root: an absolute executable, literal argv (no shell), a root-relative working directory and a complete environment allowlist. " ++
    "Each run shows the exact argv, working directory and environment for approval before anything executes. " ++
    "A task can read/write files and access the network with your permissions; workspace trust is NOT an OS sandbox and does not contain a reviewed command. " ++
    "Output is captured (bounded 1 MiB) and matched into at most 1000 problems; nothing is executed to produce problems. " ++
    "Stop cancels and reaps the process group. At most 64 tasks are loaded.";

/// Parent-supplied navigation: open `path` at 1-based `line`/`column` (column 0
/// when unknown). The controller resolves relative problem paths against the
/// task's working directory before calling. The parent owns the actual open.
pub const Navigate = *const fn (context: ?*anyopaque, path: []const u8, line: u32, column: u32) void;

pub const Controller = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    supervisor: process.Supervisor = .{},
    job: ?*process.Job = null,
    load_job: ?*LoadJob = null,
    generation: u64 = 1,
    phase: Phase = .idle,
    permit: ?trust.Permit = null,
    approved: bool = false,
    dialog: UI,
    dialog_action: ?DialogAction = null,
    definitions: ?task.Definitions = null,
    selected: ?usize = null,
    run_index: ?usize = null,
    run_cwd: ?[:0]u8 = null,
    restart_pending: bool = false,
    problems: ?matcher.Problems = null,
    selected_problem: ?usize = null,
    output_text: [:0]u8,
    output_kind: []const u8 = "none",
    message_text: [:0]u8,
    navigate: ?Navigate = null,
    navigate_context: ?*anyopaque = null,
    navigate_path: ?[:0]u8 = null,
    navigate_line: u32 = 0,
    navigate_column: u32 = 0,
    window: ?u.W = null,
    picker: ?u.W = null,
    problems_widget: ?u.W = null,
    output_view: ?u.W = null,
    summary: ?u.W = null,
    run_button: ?u.W = null,
    stop_button: ?u.W = null,
    restart_button: ?u.W = null,
    rebuilding: bool = false,
    launches: u64 = 0,
    discarded: u64 = 0,

    pub fn init(app: *App) Controller {
        return .{
            .app = app,
            .arena = std.heap.ArenaAllocator.init(a),
            .dialog = .{ .context = app, .respond = &answered },
            .output_text = u.z(""),
            .message_text = u.z("Tasks — trust and per-run review required"),
        };
    }
    pub fn deinit(self: *Controller) void {
        // App holds keep this controller alive until every cancelled job is reaped.
        std.debug.assert(self.job == null and self.load_job == null and self.supervisor.isIdle());
        self.invalidate();
        self.supervisor.shutdown();
        self.clearDefinitions();
        self.clearProblems();
        self.clearRunCwd();
        self.clearNavigate();
        self.arena.deinit();
        a.free(self.output_text);
        a.free(self.message_text);
    }
    pub fn invalidate(self: *Controller) void {
        self.cancel();
        self.approved = false;
        self.permit = null;
        self.dialog_action = null;
        self.dialog.close();
        self.closeWindow();
        self.clearDefinitions();
        self.clearProblems();
        self.clearRunCwd();
        self.setOutput("none", "");
    }
    pub fn busy(self: *const Controller) bool {
        return self.job != null or self.load_job != null;
    }
    pub fn valid(self: *Controller) bool {
        return !self.app.closing and self.approved and self.window != null and
            (if (self.permit) |permit| self.app.workspace_policy.validate(permit, .tasks) else false);
    }
    fn cancel(self: *Controller) void {
        self.generation = std.math.add(u64, self.generation, 1) catch @panic("tasks generation exhausted");
        self.restart_pending = false;
        if (self.job) |job| job.cancel();
    }
    fn clearDefinitions(self: *Controller) void {
        self.selected = null;
        if (self.definitions) |*defs| defs.deinit();
        self.definitions = null;
        self.renderTasks();
    }
    fn clearProblems(self: *Controller) void {
        self.selected_problem = null;
        if (self.problems) |*p| p.deinit();
        self.problems = null;
        self.renderProblems();
    }
    fn clearRunCwd(self: *Controller) void {
        if (self.run_cwd) |cwd| a.free(cwd);
        self.run_cwd = null;
    }
    fn clearNavigate(self: *Controller) void {
        if (self.navigate_path) |p| a.free(p);
        self.navigate_path = null;
        self.navigate_line = 0;
        self.navigate_column = 0;
    }
    fn message(self: *Controller, text: []const u8) void {
        a.free(self.message_text);
        self.message_text = u.z(text);
        if (self.summary) |label| u.setLabel(label, text);
    }
    fn failure(self: *Controller, err: anyerror) void {
        const text = u.fmt("Tasks: {s}. Reload to try again.", .{@errorName(err)});
        defer a.free(text);
        self.message(text);
    }
    fn selectedTask(self: *const Controller) ?*const task.Definition {
        const defs = &(self.definitions orelse return null);
        const index = self.selected orelse return null;
        if (index >= defs.tasks.len) return null;
        return &defs.tasks[index];
    }

    // --- public entry points -------------------------------------------------

    pub fn show(self: *Controller) void {
        if (self.app.closing) return;
        if (self.window) |window| {
            if (!self.valid()) {
                self.invalidate();
            } else {
                c.gtk_window_present(u.cast(c.GtkWindow, window));
                return;
            }
        }
        self.permit = self.app.workspace_policy.issue(.tasks) catch {
            self.app.message("Tasks are restricted. Trust the workspace before running tasks.");
            return;
        };
        self.dialog_action = .trust;
        self.dialog.context = self;
        self.dialog.show(self.app, "Tasks — subprocess disclosure", disclosure, &.{}, false, "Continue to tasks");
    }
    fn answered(context: *anyopaque, accepted: bool, _: ?usize, _: []const u8) void {
        const self = u.cast(Controller, context);
        const action = self.dialog_action orelse return;
        self.dialog_action = null;
        if (self.app.closing) return;
        switch (action) {
            .trust => {
                if (!accepted) return;
                const permit = self.permit orelse return;
                if (!self.app.workspace_policy.validate(permit, .tasks)) {
                    self.app.message("Workspace trust changed. Invoke Tasks again.");
                    return;
                }
                self.approved = true;
                self.createWindow();
                self.loadDefinitions();
            },
            .run => {
                const index = self.run_index orelse return;
                if (!accepted) return;
                if (!self.valid()) {
                    self.app.message("Workspace trust changed. Invoke Tasks again.");
                    return;
                }
                self.launch(index);
            },
        }
    }

    pub fn run(self: *Controller) void {
        if (!self.valid()) {
            self.show();
            return;
        }
        if (self.busy()) {
            self.message("Wait for the current task or load to finish.");
            return;
        }
        const index = self.selected orelse {
            self.message("Select a task to run.");
            return;
        };
        self.showRunReview(index);
    }
    pub fn stop(self: *Controller) void {
        if (self.job) |job| {
            self.restart_pending = false;
            job.cancel();
            self.message("Stopping task — cancelling and reaping the process group…");
        }
    }
    pub fn restart(self: *Controller) void {
        if (!self.valid()) {
            self.show();
            return;
        }
        const index = self.selected orelse self.run_index orelse {
            self.message("Select a task to restart.");
            return;
        };
        self.run_index = index;
        if (self.job) |job| {
            self.restart_pending = true;
            job.cancel();
            self.message("Restarting task — cancelling the current run…");
            return;
        }
        if (self.load_job != null) {
            self.message("Wait for the task list to finish loading.");
            return;
        }
        self.showRunReview(index);
    }
    fn showRunReview(self: *Controller, index: usize) void {
        const defs = &(self.definitions orelse return);
        if (index >= defs.tasks.len) return;
        const def = defs.tasks[index];
        self.run_index = index;
        const argv_json = std.json.Stringify.valueAlloc(a, def.argv, .{}) catch return;
        defer a.free(argv_json);
        const env_json = std.json.Stringify.valueAlloc(a, def.env, .{}) catch return;
        defer a.free(env_json);
        const matcher_name = if (def.matcher) |kind| matcher.kindName(kind) else "none";
        const body = std.fmt.allocPrintSentinel(a, "Run task \"{s}\" as your user?\n\nExecutable/argv: {s}\nWorking directory: {s}\nEnvironment allowlist: {s}\nProblem matcher: {s}\n\n" ++
            "This is the exact command that will execute. It has your user permissions and can read/write files and access the network. " ++
            "Workspace trust is NOT an OS sandbox. No shell is used; argv elements are literal. Stop cancels and reaps the process group.", .{ def.name, argv_json, def.cwd, env_json, matcher_name }, 0) catch return;
        defer a.free(body);
        self.dialog_action = .run;
        self.dialog.context = self;
        self.dialog.show(self.app, "Tasks — review exact command", body, &.{}, false, "Run task");
    }

    // --- definition loading (worker) -----------------------------------------

    fn loadDefinitions(self: *Controller) void {
        if (self.load_job != null) return;
        const model = if (self.app.browser.model) |*m| m else {
            self.failure(error.NoWorkspace);
            return;
        };
        const token = self.app.workspace.capture() orelse return;
        const permit = self.permit orelse return;
        const job = a.create(LoadJob) catch return;
        var arena = std.heap.ArenaAllocator.init(a);
        const alloc = arena.allocator();
        var roots: std.ArrayList([]const u8) = .empty;
        for (model.roots) |root| {
            const path = root.canonical_path orelse continue;
            const owned = alloc.dupe(u8, path) catch {
                arena.deinit();
                a.destroy(job);
                return;
            };
            roots.append(alloc, owned) catch {
                arena.deinit();
                a.destroy(job);
                return;
            };
        }
        const root_slice = roots.toOwnedSlice(alloc) catch {
            arena.deinit();
            a.destroy(job);
            return;
        };
        job.* = .{
            .owner = self,
            .generation = self.generation,
            .workspace = token,
            .permit = permit,
            .arena = arena,
            .roots = root_slice,
        };
        self.load_job = job;
        self.phase = .loading;
        self.message("Loading task definitions — disk only…");
        self.app.hold();
        const gtask = c.g_task_new(null, null, &loadDone, job) orelse {
            self.load_job = null;
            self.phase = .idle;
            self.app.release();
            job.destroy();
            return;
        };
        c.g_task_set_task_data(gtask, job, null);
        c.g_task_run_in_thread(gtask, &loadWorker);
        c.g_object_unref(gtask);
        self.updateButtons();
    }
    fn setDefinitions(self: *Controller, defs: task.Definitions) void {
        self.clearDefinitions();
        self.definitions = defs;
        self.renderTasks();
        const text = u.fmt("{d} task(s) loaded. Select a task, then Run to review the exact command.", .{defs.tasks.len});
        defer a.free(text);
        self.message(text);
    }

    // --- run jobs ------------------------------------------------------------

    fn launch(self: *Controller, index: usize) void {
        if (self.job != null) return;
        const defs = &(self.definitions orelse return);
        if (index >= defs.tasks.len) return;
        const def = defs.tasks[index];
        const token = self.app.workspace.capture() orelse return;
        var environment: [task.limits.env]process.Environment = undefined;
        if (def.env.len > environment.len) return;
        for (def.env, environment[0..def.env.len]) |entry, *out| out.* = .{ .name = entry.name, .value = entry.value };
        self.clearProblems();
        self.setOutput("running", "");
        self.clearRunCwd();
        self.run_cwd = u.z(def.cwd);
        self.run_index = index;
        self.phase = .running;
        self.job = process.start(a, .{
            .owner = &self.supervisor,
            .authorization = .approved,
            .identity = .{ .scope = "coral-tasks", .request = self.launches + 1, .generation = self.generation, .workspace = token },
            .argv = def.argv,
            .cwd = def.cwd,
            .environment = environment[0..def.env.len],
            .output_limit = capture_bytes,
            .timeout_ms = task.limits.timeout_ms,
        }, &completed, self) catch |err| {
            self.phase = .idle;
            self.failure(err);
            self.updateButtons();
            return;
        };
        self.launches += 1;
        self.app.hold();
        const text = u.fmt("Running task \"{s}\"…", .{def.name});
        defer a.free(text);
        self.message(text);
        self.updateButtons();
    }
    fn completed(job: *process.Job, result: process.Result, data: ?*anyopaque) void {
        const self = u.cast(Controller, data.?);
        defer self.app.release();
        defer job.destroy();
        std.debug.assert(self.job == job);
        self.job = null;
        if (result.identity.generation != self.generation) {
            self.discarded += 1;
            self.afterRun();
            return;
        }
        if (!self.valid() or !self.app.workspace.accepts(result.identity.workspace.?)) {
            self.discarded += 1;
            self.invalidate();
            return;
        }
        self.receive(result);
        self.afterRun();
    }
    fn receive(self: *Controller, result: process.Result) void {
        const parts: []const []const u8 = if (result.stdout.len != 0 and result.stderr.len != 0)
            &.{ result.stdout, "\n", result.stderr }
        else
            &.{ result.stdout, result.stderr };
        const combined = std.mem.concat(a, u8, parts) catch {
            self.setOutput("limited", "Output exceeded the display budget.");
            return;
        };
        defer a.free(combined);
        const displayed = displayBytes(a, combined, capture_bytes) catch {
            self.setOutput("limited", "Output could not be displayed.");
            return;
        };
        defer a.free(displayed);
        self.setOutput(@tagName(result.outcome), displayed);
        if (self.run_index) |index| {
            const defs = &(self.definitions orelse return);
            if (index < defs.tasks.len) {
                if (defs.tasks[index].matcher) |kind| {
                    self.clearProblems();
                    self.problems = matcher.parse(a, kind, combined) catch null;
                    self.renderProblems();
                }
            }
        }
        const text = u.fmt("Task finished: {s} (exit {d}). {d} problem(s).", .{
            @tagName(result.outcome),
            result.exit_code orelse -1,
            if (self.problems) |p| p.items.len else 0,
        });
        defer a.free(text);
        self.message(text);
    }
    fn afterRun(self: *Controller) void {
        self.phase = .idle;
        self.updateButtons();
        if (self.restart_pending) {
            self.restart_pending = false;
            if (self.valid()) {
                if (self.run_index) |index| self.showRunReview(index);
            }
        }
    }

    // --- presentation --------------------------------------------------------

    fn setOutput(self: *Controller, kind: []const u8, text: []const u8) void {
        self.output_kind = kind;
        a.free(self.output_text);
        self.output_text = u.z(text);
        if (self.output_view) |view| c.gtk_text_buffer_set_text(c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, view)), self.output_text.ptr, @intCast(self.output_text.len));
    }
    fn updateButtons(self: *Controller) void {
        const idle = self.window != null and !self.busy();
        if (self.run_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(idle and self.selected != null));
        if (self.restart_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(self.window != null and (self.selected != null or self.run_index != null)));
        if (self.stop_button) |b| c.gtk_widget_set_sensitive(b, @intFromBool(self.job != null));
    }
    fn createWindow(self: *Controller) void {
        const window = c.gtk_window_new().?;
        self.window = window;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Tasks");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, window), u.cast(c.GtkWindow, self.app.window));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), 980, 720);
        u.connect(window, "close-request", &closeRequested, self);
        const box = u.box(false, 8);
        u.margin(box, 12);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), box);
        const bar = u.box(true, 8);
        u.append(box, bar);
        const run_btn = u.button("Run…");
        const stop_btn = u.button("Stop");
        const restart_btn = u.button("Restart");
        const reload = u.button("Reload");
        self.run_button = run_btn;
        self.stop_button = stop_btn;
        self.restart_button = restart_btn;
        u.append(bar, run_btn);
        u.append(bar, stop_btn);
        u.append(bar, restart_btn);
        u.append(bar, reload);
        u.connect(run_btn, "clicked", &runClicked, self);
        u.connect(stop_btn, "clicked", &stopClicked, self);
        u.connect(restart_btn, "clicked", &restartClicked, self);
        u.connect(reload, "clicked", &reloadClicked, self);
        const summary = u.label(self.message_text);
        self.summary = summary;
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, summary), 1);
        u.append(box, summary);
        const picker_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(picker_scroll, -1, 140);
        const picker = c.gtk_list_box_new().?;
        self.picker = picker;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, picker), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, picker_scroll), picker);
        u.append(box, picker_scroll);
        u.connect(picker, "row-selected", &taskSelected, self);
        const problems_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_size_request(problems_scroll, -1, 160);
        const problems = c.gtk_list_box_new().?;
        self.problems_widget = problems;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, problems), c.GTK_SELECTION_SINGLE);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, problems_scroll), problems);
        u.append(box, problems_scroll);
        u.connect(problems, "row-selected", &problemSelected, self);
        u.connect(problems, "row-activated", &problemActivated, self);
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
        self.renderTasks();
        self.renderProblems();
        self.updateButtons();
        c.gtk_window_present(u.cast(c.GtkWindow, window));
    }
    fn closeWindow(self: *Controller) void {
        const window = self.window orelse return;
        self.window = null;
        self.picker = null;
        self.problems_widget = null;
        self.output_view = null;
        self.summary = null;
        self.run_button = null;
        self.stop_button = null;
        self.restart_button = null;
        self.rebuilding = true;
        _ = c.g_signal_handlers_disconnect_matched(window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_window_destroy(u.cast(c.GtkWindow, window));
        self.rebuilding = false;
    }
    fn renderTasks(self: *Controller) void {
        defer self.updateButtons();
        const list = self.picker orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        const defs = &(self.definitions orelse return);
        for (defs.tasks) |def| {
            const text = u.fmt("{s}  —  {s}", .{ def.name, def.argv[0] });
            defer a.free(text);
            const label = u.label(text);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
            c.gtk_widget_set_tooltip_text(label, text);
            u.margin(label, 4);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), label);
        }
        if (self.selected) |index| if (index < defs.tasks.len) {
            c.gtk_list_box_select_row(u.cast(c.GtkListBox, list), c.gtk_list_box_get_row_at_index(u.cast(c.GtkListBox, list), @intCast(index)));
        };
    }
    fn renderProblems(self: *Controller) void {
        const list = self.problems_widget orelse return;
        self.rebuilding = true;
        defer self.rebuilding = false;
        while (c.gtk_widget_get_first_child(list)) |child| c.gtk_list_box_remove(u.cast(c.GtkListBox, list), child);
        const problems = &(self.problems orelse return);
        const end = @min(problems.items.len, max_visible_problems);
        for (problems.items[0..end]) |problem| {
            const file = displayBytes(a, problem.file, 512) catch continue;
            defer a.free(file);
            const msg = displayBytes(a, problem.message, 512) catch continue;
            defer a.free(msg);
            const text = u.fmt("{s}  {s}:{d}:{d}  {s}", .{ matcher.severityName(problem.severity), file, problem.line, problem.column, msg });
            defer a.free(text);
            const label = u.label(text);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
            c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 110);
            c.gtk_widget_set_tooltip_text(label, text);
            u.margin(label, 4);
            c.gtk_list_box_append(u.cast(c.GtkListBox, list), label);
        }
    }
    fn selectTask(self: *Controller, index: usize) void {
        const defs = &(self.definitions orelse return);
        if (index >= defs.tasks.len or !self.valid()) return;
        self.selected = index;
        self.renderTasks();
    }
    fn navigateToProblem(self: *Controller, index: usize) void {
        const problems = &(self.problems orelse return);
        if (index >= problems.items.len) return;
        const problem = problems.items[index];
        const cwd = self.run_cwd orelse return;
        const path: [:0]u8 = if (problem.file.len != 0 and problem.file[0] == '/')
            u.z(problem.file)
        else blk: {
            const joined = std.fs.path.join(a, &.{ cwd, problem.file }) catch return;
            defer a.free(joined);
            break :blk u.z(joined);
        };
        self.clearNavigate();
        self.navigate_path = path;
        self.navigate_line = problem.line;
        self.navigate_column = problem.column;
        if (self.navigate) |navigate| {
            navigate(self.navigate_context, path, problem.line, problem.column);
        }
    }

    // --- GTK callbacks -------------------------------------------------------

    fn closeRequested(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
        u.cast(Controller, data.?).invalidate();
        return 1;
    }
    fn taskSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const selected = row orelse {
            self.selected = null;
            self.updateButtons();
            return;
        };
        const index = c.gtk_list_box_row_get_index(selected);
        if (index >= 0) self.selectTask(@intCast(index));
    }
    fn problemSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (self.rebuilding) return;
        const selected = row orelse {
            self.selected_problem = null;
            return;
        };
        const index = c.gtk_list_box_row_get_index(selected);
        if (index >= 0) self.selected_problem = @intCast(index);
    }
    fn problemActivated(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        const index = c.gtk_list_box_row_get_index(row);
        if (index >= 0) self.navigateToProblem(@intCast(index));
    }
    fn runClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).run();
    }
    fn stopClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).stop();
    }
    fn restartClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        u.cast(Controller, data.?).restart();
    }
    fn reloadClicked(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Controller, data.?);
        if (!self.valid()) {
            self.show();
            return;
        }
        if (self.busy()) {
            self.message("Wait for the current task or load to finish.");
            return;
        }
        self.loadDefinitions();
    }

    // --- test instrumentation ------------------------------------------------

    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!hooks) return false;
        if (std.mem.eql(u8, action, "tasks-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "tasks-show")) {
            self.show();
        } else if (std.mem.eql(u8, action, "tasks-run")) {
            self.run();
        } else if (std.mem.eql(u8, action, "tasks-stop")) {
            self.stop();
        } else if (std.mem.eql(u8, action, "tasks-restart")) {
            self.restart();
        } else if (std.mem.eql(u8, action, "tasks-reload")) {
            reloadClicked(null, self);
        } else if (std.mem.eql(u8, action, "tasks-accept")) {
            self.dialog.answer(true, null, value);
        } else if (std.mem.eql(u8, action, "tasks-reject")) {
            self.dialog.answer(false, null, "");
        } else if (std.mem.eql(u8, action, "tasks-select")) {
            self.selectTask(std.fmt.parseInt(usize, value, 10) catch return true);
        } else if (std.mem.eql(u8, action, "tasks-navigate")) {
            self.navigateToProblem(std.fmt.parseInt(usize, value, 10) catch return true);
        } else if (std.mem.eql(u8, action, "tasks-close")) {
            self.invalidate();
        } else return false;
        return true;
    }
    pub fn probe(self: *const Controller) void {
        if (!hooks) return;
        const defs: []const task.Definition = if (self.definitions) |d| d.tasks else &.{};
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(a);
        for (defs) |def| names.append(a, def.name) catch return;
        const problems: []const matcher.Problem = if (self.problems) |p| p.items else &.{};
        const ProblemView = struct { file: []const u8, line: u32, column: u32, severity: []const u8, message: []const u8 };
        var problem_views: std.ArrayList(ProblemView) = .empty;
        defer problem_views.deinit(a);
        const end = @min(problems.len, max_visible_problems);
        for (problems[0..end]) |problem| {
            problem_views.append(a, .{
                .file = problem.file,
                .line = problem.line,
                .column = problem.column,
                .severity = matcher.severityName(problem.severity),
                .message = problem.message,
            }) catch return;
        }
        const bytes = std.json.Stringify.valueAlloc(a, .{
            .window = self.app.window_id,
            .visible = self.window != null,
            .approved = self.approved,
            .generation = self.generation,
            .busy = self.busy(),
            .loading = self.load_job != null,
            .phase = @tagName(self.phase),
            .launches = self.launches,
            .discarded = self.discarded,
            .tasks = names.items,
            .task_count = defs.len,
            .selected = self.selected,
            .run_index = self.run_index,
            .problems = problem_views.items,
            .problem_count = problems.len,
            .problems_truncated = if (self.problems) |p| p.truncated else false,
            .selected_problem = self.selected_problem,
            .output_kind = self.output_kind,
            .output_bytes = self.output_text.len,
            .dialog = if (self.dialog_action) |action| @as(?[]const u8, @tagName(action)) else null,
            .restart_pending = self.restart_pending,
            .navigate_path = self.navigate_path,
            .navigate_line = self.navigate_line,
            .navigate_column = self.navigate_column,
            .status = self.message_text,
        }, .{}) catch return;
        defer a.free(bytes);
        const line = u.z(bytes);
        defer a.free(line);
        c.g_print("CORAL_TASKS %s\n", line.ptr);
    }
};

// --- definition load worker --------------------------------------------------

const LoadJob = struct {
    owner: *Controller,
    generation: u64,
    workspace: identity.Token,
    permit: trust.Permit,
    arena: std.heap.ArenaAllocator,
    roots: []const []const u8,
    result: ?task.Definitions = null,
    err: ?anyerror = null,

    fn run(self: *LoadJob) void {
        self.result = task.loadRoots(a, self.roots) catch |err| {
            self.err = err;
            return;
        };
    }
    fn destroy(self: *LoadJob) void {
        if (self.result) |*result| result.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
};

fn loadWorker(gtask: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: ?*c.GCancellable) callconv(.c) void {
    const job = u.cast(LoadJob, data.?);
    job.run();
    c.g_task_return_boolean(gtask, 1);
}
fn loadDone(_: ?*c.GObject, res: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const job = u.cast(LoadJob, data.?);
    _ = c.g_task_propagate_boolean(u.cast(c.GTask, res.?), null);
    const self = job.owner;
    std.debug.assert(self.load_job == job);
    self.load_job = null;
    defer {
        job.destroy();
        self.app.release();
    }
    if (self.app.closing or job.generation != self.generation or
        !self.app.workspace.accepts(job.workspace) or !self.app.workspace_policy.validate(job.permit, .tasks))
    {
        self.discarded += 1;
        self.phase = .idle;
        self.updateButtons();
        return;
    }
    if (job.err) |err| {
        self.phase = .idle;
        self.failure(err);
        self.updateButtons();
        return;
    }
    const result = job.result orelse {
        self.phase = .idle;
        self.updateButtons();
        return;
    };
    job.result = null; // transfer ownership to the controller
    self.setDefinitions(result);
    self.phase = .idle;
    self.updateButtons();
}

// --- bounded display escaping ------------------------------------------------

/// Escape control bytes and bound presentation length for GTK plain-text widgets.
/// Valid UTF-8 is preserved (control characters hex-escaped); invalid UTF-8 is
/// hex-escaped byte-wise. Never mutates the input. This is display only.
fn displayBytes(allocator: std.mem.Allocator, bytes: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789abcdef";
    const valid = std.unicode.utf8ValidateSlice(bytes);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        var scratch: [4]u8 = undefined;
        var chunk: []const u8 = undefined;
        if (b < 0x20 and b != '\n' and b != '\t') {
            scratch = [_]u8{ '\\', 'x', hex[b >> 4], hex[b & 15] };
            chunk = &scratch;
            i += 1;
        } else if (b >= 0x80) {
            if (valid) {
                const width = std.unicode.utf8ByteSequenceLength(b) catch 1;
                const end = @min(i + width, bytes.len);
                chunk = bytes[i..end];
                i = end;
            } else {
                scratch = [_]u8{ '\\', 'x', hex[b >> 4], hex[b & 15] };
                chunk = &scratch;
                i += 1;
            }
        } else {
            scratch[0] = b;
            chunk = scratch[0..1];
            i += 1;
        }
        if (out.items.len + chunk.len + 3 > limit) {
            if (out.items.len + 3 <= limit) try out.appendSlice(allocator, "...");
            break;
        }
        try out.appendSlice(allocator, chunk);
    }
    return out.toOwnedSlice(allocator);
}
