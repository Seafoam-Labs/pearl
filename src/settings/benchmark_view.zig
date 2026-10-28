//! Native, draft-only model comparison. Jobs own no GTK objects off-thread.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const layout = @import("assistant_layout.zig");
const benchmark = @import("../agent/benchmark.zig");
const registry = @import("../agent/model_registry.zig");
const cfg = @import("../agent/config.zig");
const prefs = @import("../config/preferences.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Action = enum { compare, stop_compare, download };
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    action: Action,
    config: cfg.Config,
    options: benchmark.Options,
    progress: benchmark.Progress = .{},
    failure: ?anyerror = null,
    run: ?benchmark.Run = null,
};
const Row = struct { view: *View, index: usize };
pub const RowControls = struct { index: usize, use: *gtk.Button, show: *gtk.Button, eligible: bool };
pub const View = struct {
    editor: *Editor,
    owner: *anyopaque,
    owner_idle: *const fn (*anyopaque) bool,
    expander: *gtk.Expander,
    section_summary: *gtk.Label,
    host: *gtk.Box,
    hardware_label: *gtk.Label,
    candidates: [registry.models.len]*gtk.CheckButton,
    installed: [registry.models.len]*gtk.Label,
    mode: *gtk.DropDown,
    detail: *gtk.DropDown,
    sort: *gtk.DropDown,
    start: *gtk.Button,
    stop_start: *gtk.Button,
    download: *gtk.Button,
    cancel_button: *gtk.Button,
    skip_button: *gtk.Button = undefined,
    refresh: *gtk.Button,
    export_button: *gtk.Button,
    delete_button: *gtk.Button,
    history: *gtk.DropDown,
    history_names: *gtk.StringList,
    summary: *gtk.Label,
    status: *gtk.Label,
    results: *gtk.Box,
    details: *gtk.Label,
    job: ?*Job = null,
    cancel: ?*gio.Cancellable = null,
    timer: c_uint = 0,
    dead: bool = false,
    filling: bool = false,
    loaded: bool = false,
    report: ?benchmark.Run = null,
    ids: []const []const u8 = &.{},
    data: std.heap.ArenaAllocator = .init(a),
    rows: std.heap.ArenaAllocator = .init(a),
    picker: ?*gtk.FileChooserNative = null,
    exported: ?[]u8 = null,
    shown_completed: u32 = 0,
    row_controls: std.ArrayList(RowControls) = .empty,

    pub fn create(host: *gtk.Box, editor: *Editor, owner: *anyopaque, owner_idle: *const fn (*anyopaque) bool) !*View {
        const self = try a.create(View);
        const section = layout.Section.create(host, "Compare models", "Choose models, compare local performance and review saved results");
        const expander = section.expander;
        const body = section.body;
        const hardware = layout.Section.create(body, "This computer", "Hardware, available memory and selected runtime");
        const hardware_label = label(hardware.body, "Expand to review this computer and saved comparisons.");
        _ = label(body, "Choose models to compare on this computer. Downloads are separate and explicit. Tests use local sample evidence and do not send searches or use your conversations.");
        var checks: [registry.models.len]*gtk.CheckButton = undefined;
        var installed: [registry.models.len]*gtk.Label = undefined;
        for (registry.models, 0..) |model, i| {
            const candidate = layout.card(body, "");
            checks[i] = gtk.CheckButton.newWithLabel(model.name);
            if (checks[i].getChild()) |child| if (object.ext.cast(gtk.Label, child)) |text| {
                text.setWrap(1);
                text.setWrapMode(.word_char);
            };
            checks[i].setActive(@intFromBool(i >= 2));
            candidate.append(checks[i].as(gtk.Widget));
            installed[i] = label(candidate, "");
            const license = gtk.LinkButton.newWithLabel(model.license_url, "Model license");
            license.as(gtk.Widget).setHalign(.start);
            candidate.append(license.as(gtk.Widget));
        }
        const summary = label(body, "");
        const mode = choice(body, @import("i18n").dtr("pearl", "Hardware to compare"), &.{ "CPU", "Current configuration", "Compare CPU and GPU" });
        const detail = choice(body, @import("i18n").dtr("pearl", "Comparison depth"), &.{ "Quick · model profiles", "Detailed · threads and contexts" });
        _ = label(body, "Warm-up + three measured repetitions per fixture. Detailed comparisons take longer. Current configuration includes your thread and token settings. Comparisons start immediately; you can cancel.");
        const actions = layout.actions(body);
        const download = layout.button(actions, "Download selected missing models");
        const start = layout.button(actions, "Compare installed selections");
        const stop_start = layout.button(actions, "Stop answer and benchmark");
        stop_start.as(gtk.Widget).setVisible(0);
        const job_actions = layout.actions(body);
        const cancel_button = layout.button(job_actions, "Cancel comparison or download");
        cancel_button.as(gtk.Widget).setSensitive(0);
        const status = label(body, "No comparison running.");
        const saved = layout.card(body, "Saved results");
        const refresh = button(saved, "Refresh saved results and availability");
        const history_names = gtk.StringList.new(null);
        _ = history_names.ref();
        const history = gtk.DropDown.new(history_names.as(gio.ListModel), null);
        layout.wrapChoice(history);
        layout.row(saved, "Comparison history", history.as(gtk.Widget));
        const sort = choice(saved, @import("i18n").dtr("pearl", "Sort results"), &.{ "Completion time", "Memory use", "Model name" });
        const methodology = layout.Section.create(saved, "How comparisons work", "Workload, suggestions and measurement limits");
        _ = label(methodology.body, "Suggestions compare successful results within the same context workload. Balanced chooses the lowest memory within 20% of the fastest median or its observed range, whichever is larger. Fixture checks are limited; inspect the sample answers before choosing. Memory estimates are advisory. Download size is separate from runtime RAM.");
        const results = w.column(8);
        saved.append(results.as(gtk.Widget));
        const details = label(saved, "Select Show samples to inspect a result.");
        details.setSelectable(1);
        const history_actions = layout.actions(saved);
        const export_button = layout.button(history_actions, "Export selected comparison…");
        const delete_button = layout.button(history_actions, "Delete selected comparison");
        self.* = .{ .editor = editor, .owner = owner, .owner_idle = owner_idle, .expander = expander, .section_summary = section.summary, .host = body, .hardware_label = hardware_label, .candidates = checks, .installed = installed, .mode = mode, .detail = detail, .sort = sort, .start = start, .stop_start = stop_start, .download = download, .cancel_button = cancel_button, .refresh = refresh, .export_button = export_button, .delete_button = delete_button, .history = history, .history_names = history_names, .summary = summary, .status = status, .results = results, .details = details };
        self.skip_button = layout.button(job_actions, "Skip current configuration");
        self.skip_button.as(gtk.Widget).setSensitive(0);
        _ = gtk.Button.signals.clicked.connect(self.skip_button, *View, clicked, self, .{});
        _ = object.Object.signals.notify.connect(status.as(object.Object), *View, statusChanged, self, .{ .detail = "label" });
        _ = object.Object.signals.notify.connect(expander.as(object.Object), *View, expanded, self, .{ .detail = "expanded" });
        for (checks) |check| _ = gtk.CheckButton.signals.toggled.connect(check, *View, selected, self, .{});
        for ([_]*gtk.Button{ start, stop_start, download, cancel_button, refresh, export_button, delete_button }) |b| _ = gtk.Button.signals.clicked.connect(b, *View, clicked, self, .{});
        _ = object.Object.signals.notify.connect(sort.as(object.Object), *View, sorted, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(history.as(object.Object), *View, historyChanged, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(mode.as(object.Object), *View, optionsChanged, self, .{ .detail = "selected" });
        self.timer = glib.timeoutAdd(250, tick, self);
        return self;
    }
    pub fn busy(self: *View) bool {
        return self.job != null;
    }
    pub fn destroy(self: *View) void {
        self.dead = true;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        if (self.cancel) |cancel| cancel.cancel();
        if (self.picker) |picker| {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
        }
        if (self.exported) |bytes| a.free(bytes);
        self.history_names.unref();
        self.rows.deinit();
        self.data.deinit();
        if (self.job == null) a.destroy(self);
    }
    fn document(self: *View, alloc: std.mem.Allocator) !prefs.Preferences {
        return prefs.parse(alloc, self.editor.text());
    }
    fn options(self: *View) benchmark.Options {
        var result: benchmark.Options = .{ .mode = @fromBackingInt(@intCast(self.mode.getSelected())), .detailed = self.detail.getSelected() == 1 };
        for (self.candidates, 0..) |check, i| result.selected[i] = check.getActive() != 0;
        return result;
    }
    fn expanded(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.expander.getExpanded() != 0 and !self.loaded) self.reload() catch |err| self.fail(err);
    }
    fn selected(_: *gtk.CheckButton, self: *View) callconv(.c) void {
        self.availability() catch |err| self.fail(err);
    }
    fn optionsChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.loaded) self.availability() catch |err| self.fail(err);
    }
    fn sorted(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (!self.filling) self.render() catch |err| self.fail(err);
    }
    fn historyChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        self.loadSelected() catch |err| self.fail(err);
    }
    fn fail(self: *View, err: anyerror) void {
        self.status.setText(@errorName(err));
        self.expander.setExpanded(1);
    }
    fn statusChanged(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.section_summary.setText(self.status.getText());
    }
    fn availability(self: *View) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const host = try benchmark.hardware(alloc);
        const config = (try self.document(alloc)).assistant;
        const executable = @import("../agent/runtime_probe.zig").resolve(alloc, config.runtime) catch "Runtime unavailable";
        self.hardware_label.setText(try std.fmt.allocPrintSentinel(alloc, "{s} · {s}\n{d} allowed CPU threads · {d} physical cores\nAvailable RAM: {s} MiB · Runtime: {s}\n{s}", .{ host.cpu, host.architecture, host.logical, host.physical, if (host.available_mib) |n| try std.fmt.allocPrint(alloc, "{d}", .{n}) else "unavailable", executable, host.power }, 0));
        var pending: u64 = 0;
        var count: usize = 0;
        for (registry.models, 0..) |model, i| {
            const exists = std.c.access(try @import("../agent/downloads.zig").path(alloc, model), std.c.F_OK) == 0;
            const context = if (self.mode.getSelected() == 1 and config.context_tokens != 0) config.context_tokens else model.context_tokens;
            const estimate = model.bytes / (1024 * 1024) * 2 + context / 16 + 256;
            self.installed[i].setText(try std.fmt.allocPrintSentinel(alloc, "{s} · rough RAM planning estimate: {d} MiB at {d} context tokens; actual use varies by runtime.", .{ if (exists) "Installed" else "Not installed", estimate, context }, 0));
            if (self.candidates[i].getActive() != 0) {
                if (exists) count += 1 else pending += model.bytes;
            }
        }
        self.summary.setText(try std.fmt.allocPrintSentinel(alloc, "{d} selected models installed · pending downloads: {d:.2} GB. Runtime RAM is greater than download size and is measured during testing. GPU discovery occurs when comparison starts.", .{ count, @as(f64, @floatFromInt(pending)) / 1e9 }, 0));
    }
    fn reload(self: *View) !void {
        self.loaded = true;
        self.filling = true;
        defer self.filling = false;
        clear(self.results);
        _ = self.rows.reset(.free_all);
        self.row_controls = .empty;
        _ = self.data.reset(.free_all);
        self.report = null;
        self.ids = try benchmark.history(self.data.allocator());
        self.history_names.splice(0, self.history_names.as(gio.ListModel).getNItems(), null);
        for (self.ids) |id| self.history_names.append(try self.data.allocator().dupeSentinel(u8, id, 0));
        self.history.setSelected(0);
        try self.loadSelected();
        try self.availability();
    }
    fn loadSelected(self: *View) !void {
        self.report = null;
        const index = self.history.getSelected();
        if (index < self.ids.len) self.report = try benchmark.load(self.data.allocator(), self.ids[index]);
        try self.render();
    }
    fn render(self: *View) !void {
        clear(self.results);
        _ = self.rows.reset(.free_all);
        self.row_controls = .empty;
        const alloc = self.rows.allocator();
        self.details.setText(@import("i18n").dtr("pearl", "Select Show samples to inspect answers, settings and telemetry. GPU memory and separate reasoning throughput are unavailable unless reported; RAM is sampled process-tree RSS plus OS high-water information, which may miss brief child peaks."));
        const run = self.report orelse {
            _ = label(self.results, "No saved comparisons.");
            return;
        };
        const host = try benchmark.hardware(alloc);
        _ = label(self.results, try std.fmt.allocPrintSentinel(alloc, "Comparison {s} · {s}\nCPU: {s} · background load: {s}", .{ run.id, if (self.job != null and run.state == .interrupted) "running (saved checkpoint)" else @tagName(run.state), run.hardware.cpu, run.hardware.load }, 0));
        const stale = try alloc.alloc(bool, run.results.len);
        const reasons = try alloc.alloc(?[]const u8, run.results.len);
        for (run.results, 0..) |result, i| {
            reasons[i] = benchmark.staleReason(alloc, run, result, host);
            stale[i] = reasons[i] != null;
        }
        const order = try alloc.alloc(usize, run.results.len);
        for (order, 0..) |*item, i| item.* = i;
        std.mem.sort(usize, order, Sort{ .results = run.results, .mode = self.sort.getSelected() }, Sort.less);
        for (order) |index| {
            const result = run.results[index];
            const summary = benchmark.summarize(result);
            const rec = benchmark.recommend(run.results, result.group, stale);
            const tags = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ if (rec.fastest == index) "Fastest successful · " else "", if (rec.memory == index) "Lowest memory · " else "", if (rec.balanced == index) "Balanced" else "" });
            const model = registry.find(result.settings.model_id);
            const result_card = layout.card(self.results, "");
            const metrics = w.flow(3);
            metrics.setHomogeneous(1);
            result_card.append(metrics.as(gtk.Widget));
            const actions = w.column(6);
            actions.append(cell(try std.fmt.allocPrintSentinel(alloc, "{s}\n{s} · threads {d} · context {d} · generation {d}\n{s}\n{s}", .{ if (model) |m| m.name else result.settings.model_id, @tagName(result.settings.compute.mode), result.settings.threads, result.settings.context, result.settings.generation, tags, reasons[index] orelse (if (result.successful()) "Checks passed" else if (result.error_code.len > 0) result.error_code else "Incomplete or failed samples; inspect details") }, 0)));
            metrics.insert(actions.as(gtk.Widget), -1);
            metrics.insert(cell(try std.fmt.allocPrintSentinel(alloc, "Answer time (ms)\nFirst visible: {s}\nComplete median: {s}\nRange: {s}\n{d} measured samples", .{ if (summary.first_ms) |ms| try std.fmt.allocPrint(alloc, "{d:.0}", .{ms}) else "unavailable", if (summary.measured > 0) try std.fmt.allocPrint(alloc, "{d:.0}", .{summary.median_ms}) else "unavailable", if (summary.measured > 0) try std.fmt.allocPrint(alloc, "{d:.0}–{d:.0}", .{ summary.min_ms, summary.max_ms }) else "unavailable", summary.measured }, 0)), -1);
            metrics.insert(cell(try std.fmt.allocPrintSentinel(alloc, "Actual backend: {s}\nPeak RSS: {s} MiB\n{d}/{d} checks\nInitial GPU offload: {d} layers", .{ result.actualCompute(), if (result.peak_rss_kib) |rss| try std.fmt.allocPrint(alloc, "{d:.0}", .{@as(f64, @floatFromInt(rss)) / 1024}) else "unavailable", summary.passed, summary.measured, result.offload_layers }, 0)), -1);
            const row_actions = layout.actions(result_card);
            const use = layout.button(row_actions, "Use this configuration");
            use.as(gtk.Widget).setSensitive(@intFromBool(!stale[index] and result.successful() and self.job == null and self.editor.editable()));
            const show = layout.button(row_actions, "Show samples");
            _ = label(result_card, "Use updates the draft; Apply & save persists it.");
            const context = try alloc.create(Row);
            context.* = .{ .view = self, .index = index };
            _ = gtk.Button.signals.clicked.connect(use, *Row, adopt, context, .{});
            _ = gtk.Button.signals.clicked.connect(show, *Row, showSamples, context, .{});
            try self.row_controls.append(alloc, .{ .index = index, .use = use, .show = show, .eligible = !stale[index] and result.successful() });
        }
    }
    const Sort = struct {
        results: []const benchmark.Result,
        mode: u32,
        fn less(self: Sort, x: usize, y: usize) bool {
            const left = self.results[x];
            const right = self.results[y];
            return switch (self.mode) {
                1 => (left.peak_rss_kib orelse std.math.maxInt(u64)) < (right.peak_rss_kib orelse std.math.maxInt(u64)),
                2 => std.mem.order(u8, left.settings.model_id, right.settings.model_id) == .lt,
                else => if (left.successful() != right.successful()) left.successful() else benchmark.summarize(left).median_ms < benchmark.summarize(right).median_ms,
            };
        }
    };
    fn adopt(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        self.adoptResult(row.index) catch |err| self.fail(err);
    }
    fn adoptResult(self: *View, index: usize) !void {
        if (self.job != null or !self.editor.editable() or !self.owner_idle(self.owner)) return error.OperationInProgress;
        const run = self.report orelse return error.BenchmarkNotFound;
        if (index >= run.results.len or !run.results[index].successful()) return error.BenchmarkNotSuccessful;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        if (benchmark.staleReason(alloc, run, run.results[index], try benchmark.hardware(alloc))) |reason| {
            self.status.setText(try alloc.dupeSentinel(u8, reason, 0));
            return;
        }
        var value = try self.document(alloc);
        run.results[index].settings.adopt(&value.assistant);
        try self.editor.edit(try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 }));
        self.status.setText(@import("i18n").dtr("pearl", "Configuration added to your draft. Apply saves it; Discard restores your prior settings."));
    }
    fn showSamples(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        const run = self.report orelse return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        // Export contains all fields; this view keeps question/answer pairs readable.
        const result = run.results[row.index];
        var text: std.ArrayList(u8) = .empty;
        text.appendSlice(alloc, std.fmt.allocPrint(alloc, "Runtime: {s}\nChecksum: {s}\nVerification {d:.0} ms · load and compatibility {d:.0} ms\nOS high-water sum: {?d} KiB · {d} memory samples\nGroup: {s}\n", .{ result.runtime_version, result.model_hash, result.verification_ms, result.load_ms, result.high_water_kib, result.memory_samples, result.group }) catch return) catch return;
        for (result.samples) |sample| {
            const question = for (benchmark.fixtures) |fixture| {
                if (std.mem.eql(u8, fixture.id, sample.fixture)) break if (sample.followup) fixture.followup else fixture.question;
            } else sample.fixture;
            text.appendSlice(alloc, std.fmt.allocPrint(alloc, "\n{s} · {s} · {s} · {s}\n{s}\n{s}\n{d:.0} ms · {s} · searches {d}, reads {d}\nTokens reported by runtime: input {?d}, generated including reasoning {?d}, reasoning {?d}; telemetry {d}/{d} requests\nInput time {?d} ms · generation time {?d} ms\n{s} {s}\n", .{ sample.fixture, if (sample.followup) "Follow-up" else "Question", if (sample.warmup) "Warm-up" else "Measured", @tagName(sample.outcome), question, sample.answer, sample.complete_ms, if (sample.gpu) "GPU" else "CPU", sample.searches, sample.reads, sample.tokens.prompt, sample.tokens.generated, sample.tokens.reasoning, sample.tokens.reported_requests, sample.tokens.requests, sample.tokens.prompt_ms, sample.tokens.generation_ms, sample.fallback, sample.error_code }) catch return) catch return;
            text.appendSlice(alloc, std.fmt.allocPrint(alloc, "Prompt throughput: {s} tokens/s · generation including reasoning: {s} tokens/s. Separate visible/reasoning throughput unavailable.\n", .{ if (sample.tokens.rate(true)) |rate| std.fmt.allocPrint(alloc, "{d:.1}", .{rate}) catch return else "unavailable", if (sample.tokens.rate(false)) |rate| std.fmt.allocPrint(alloc, "{d:.1}", .{rate}) catch return else "unavailable" }) catch return) catch return;
        }
        self.details.setText(alloc.dupeSentinel(u8, text.items, 0) catch return);
    }
    fn clicked(b: *gtk.Button, self: *View) callconv(.c) void {
        if (b == self.skip_button) {
            if (self.job) |job| job.progress.skip.store(true, .monotonic);
            self.status.setText(@import("i18n").dtr("pearl", "Skipping this configuration after any current file verification completes…"));
            return;
        }
        if (b == self.cancel_button) {
            if (self.cancel) |cancel| cancel.cancel();
            return;
        }
        if (b == self.refresh) {
            self.reload() catch |err| self.fail(err);
            return;
        }
        if (b == self.export_button) {
            self.exportResult() catch |err| self.fail(err);
            return;
        }
        if (b == self.delete_button) {
            if (self.job != null) return;
            if (self.report) |run| benchmark.remove(self.data.allocator(), run.id) catch |err| {
                self.fail(err);
                return;
            };
            self.reload() catch |err| self.fail(err);
            return;
        }
        self.begin(if (b == self.download) .download else if (b == self.stop_start) .stop_compare else .compare) catch |err| self.fail(err);
    }
    fn begin(self: *View, action: Action) !void {
        if (self.job != null or !self.owner_idle(self.owner)) return error.OperationInProgress;
        if (!self.editor.editable()) return error.SettingsUnavailable;
        const job = try a.create(Job);
        job.* = .{ .action = action, .config = undefined, .options = self.options() };
        errdefer {
            job.arena.deinit();
            a.destroy(job);
        }
        const alloc = job.arena.allocator();
        job.config = (try self.document(alloc)).assistant;
        var selected_count: usize = 0;
        for (registry.models, 0..) |model, i| {
            if (action != .download and std.c.access(try @import("../agent/downloads.zig").path(alloc, model), std.c.F_OK) != 0) job.options.selected[i] = false;
            if (job.options.selected[i]) selected_count += 1;
        }
        if (selected_count == 0) return error.SelectInstalledBenchmarkModels;
        self.cancel = gio.Cancellable.new();
        self.job = job;
        self.shown_completed = 0;
        self.stop_start.as(gtk.Widget).setVisible(0);
        if (gio.Application.getDefault()) |app| app.hold();
        const task = gio.Task.new(null, self.cancel, done, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
        self.sensitivity();
        self.render() catch |err| self.fail(err);
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        operate(job, cancel.?) catch |err| {
            job.failure = err;
        };
        task.returnPointer(job, null);
    }
    fn operate(job: *Job, cancel: *gio.Cancellable) !void {
        const alloc = job.arena.allocator();
        if (job.action == .download) {
            for (registry.models, 0..) |model, i| {
                if (!job.options.selected[i]) continue;
                if (std.c.access(try @import("../agent/downloads.zig").path(alloc, model), std.c.F_OK) == 0) continue;
                job.progress.candidate.store(i, .monotonic);
                try @import("../agent/downloads.zig").install(model, cancel, &job.progress.download_bytes);
            }
            return;
        }
        const control = @import("../agent/control.zig");
        const status = try control.command(alloc, "status", cancel);
        if (status.busy and job.action != .stop_compare) return error.AnswerInProgress;
        if (job.action == .stop_compare) _ = try control.command(alloc, "cancel", cancel);
        // Wait for shell's asynchronous release, without taking over a new answer.
        for (0..40) |i| {
            const state = try control.command(alloc, "status", cancel);
            if (!state.busy) {
                _ = try control.command(alloc, "release", cancel);
                break;
            }
            if (i == 39) return error.AnswerInProgress;
            if (cancel.isCancelled() != 0) return error.Cancelled;
            glib.usleep(50000);
        }
        glib.usleep(100000);
        job.run = try benchmark.execute(alloc, job.config, job.options, cancel, &job.progress);
    }
    fn done(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data.?));
        const job: *Job = @ptrCast(@alignCast(object.ext.cast(gio.Task, result).?.propagatePointer(null).?));
        defer {
            job.arena.deinit();
            a.destroy(job);
            if (gio.Application.getDefault()) |app| app.release();
        }
        self.cancel.?.unref();
        self.cancel = null;
        self.job = null;
        if (self.dead) {
            a.destroy(self);
            return;
        }
        self.reload() catch |err| self.fail(err);
        if (job.failure) |err| {
            if (err == error.AnswerInProgress) {
                self.status.setText(@import("i18n").dtr("pearl", "An answer is running. Leave it running, or choose Stop answer and benchmark."));
                self.stop_start.as(gtk.Widget).setVisible(1);
            } else self.fail(err);
        } else self.status.setText(if (job.run) |run| if (run.state == .cancelled) @import("i18n").dtr("pearl", "Comparison cancelled. Completed results are saved.") else @import("i18n").dtr("pearl", "Comparison finished. Inspect results and samples, then choose a configuration.") else @import("i18n").dtr("pearl", "Downloads complete. Select Compare to start testing."));
        self.sensitivity();
    }
    fn sensitivity(self: *View) void {
        const available = self.job == null and self.editor.editable() and self.owner_idle(self.owner);
        for ([_]*gtk.Widget{ self.start.as(gtk.Widget), self.stop_start.as(gtk.Widget), self.download.as(gtk.Widget), self.mode.as(gtk.Widget), self.detail.as(gtk.Widget), self.history.as(gtk.Widget), self.refresh.as(gtk.Widget), self.delete_button.as(gtk.Widget) }) |widget| widget.setSensitive(@intFromBool(available));
        for (self.candidates) |check| check.as(gtk.Widget).setSensitive(@intFromBool(available));
        self.export_button.as(gtk.Widget).setSensitive(@intFromBool(self.report != null and self.picker == null));
        for (self.row_controls.items) |row| row.use.as(gtk.Widget).setSensitive(@intFromBool(available and row.eligible));
        self.cancel_button.as(gtk.Widget).setSensitive(@intFromBool(self.job != null));
        self.skip_button.as(gtk.Widget).setSensitive(@intFromBool(if (self.job) |job| job.action != .download else false));
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.sensitivity();
        if (self.job) |job| {
            if (!self.editor.editable()) self.cancel.?.cancel();
            var buffer: [256]u8 = undefined;
            const text = if (job.action == .download) std.mem.printSentinel(&buffer, "Downloading {s}: {d} MB…", .{ registry.models[@min(job.progress.candidate.load(.monotonic), registry.models.len - 1)].id, job.progress.download_bytes.load(.monotonic) / 1000000 }, 0) else std.mem.printSentinel(&buffer, "{s} · configuration {d}/{d} · sample {d}/{d} · {s} · completed {d}.", .{ registry.models[@min(job.progress.model_index.load(.monotonic), registry.models.len - 1)].id, job.progress.candidate.load(.monotonic) + 1, job.progress.total.load(.monotonic), job.progress.sample.load(.monotonic), benchmark.fixtures.len * 8, @tagName(job.progress.phase.load(.monotonic)), job.progress.completed.load(.monotonic) }, 0);
            self.status.setText(text catch "Working…");
            const completed = job.progress.completed.load(.monotonic);
            if (completed != self.shown_completed) {
                self.shown_completed = completed;
                self.reload() catch |err| self.fail(err);
            }
        }
        return 1;
    }
    fn exportResult(self: *View) !void {
        if (self.picker != null) return;
        const run = self.report orelse return error.BenchmarkNotFound;
        const bytes = try std.json.Stringify.valueAlloc(a, run, .{ .whitespace = .indent_2 });
        self.exported = bytes;
        const parent = object.ext.cast(gtk.Window, self.host.as(gtk.Widget).getRoot().?).?;
        const picker = gtk.FileChooserNative.new("Export model comparison", parent, .save, "Export", "Cancel");
        picker.as(gtk.FileChooser).setCurrentName("pearl-model-comparison.json");
        self.picker = picker;
        _ = gtk.NativeDialog.signals.response.connect(picker.as(gtk.NativeDialog), *View, exportedFile, self, .{});
        picker.as(gtk.NativeDialog).show();
    }
    fn exportedFile(_: *gtk.NativeDialog, response: c_int, self: *View) callconv(.c) void {
        const picker = self.picker orelse return;
        self.picker = null;
        defer {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
            if (self.exported) |bytes| a.free(bytes);
            self.exported = null;
        }
        if (response != @backingInt(gtk.ResponseType.accept)) return;
        const file = picker.as(gtk.FileChooser).getFile() orelse return;
        defer file.unref();
        const filename = file.getPath() orelse {
            self.status.setText(@import("i18n").dtr("pearl", "Choose a local export file."));
            return;
        };
        defer glib.free(filename);
        @import("../config/io.zig").atomic(std.mem.span(filename), self.exported.?, false) catch |err| {
            self.fail(err);
            return;
        };
        const message = std.fmt.allocPrintSentinel(a, "Comparison exported to {s}", .{filename}, 0) catch return;
        defer a.free(message);
        self.status.setText(message);
    }
};
fn clear(box: *gtk.Box) void {
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
}
fn label(box: *gtk.Box, text: [:0]const u8) *gtk.Label {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    l.setWrapMode(.word_char);
    box.append(l.as(gtk.Widget));
    return l;
}
fn cell(text: [:0]const u8) *gtk.Widget {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    l.setWrapMode(.word_char);
    l.setMaxWidthChars(28);
    l.as(gtk.Widget).setValign(.start);
    return l.as(gtk.Widget);
}
fn button(box: *gtk.Box, text: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(text);
    box.append(b.as(gtk.Widget));
    return b;
}
fn choice(box: *gtk.Box, title: [:0]const u8, names: []const [:0]const u8) *gtk.DropDown {
    var list: [5]?[*:0]const u8 = @splat(null);
    for (names, 0..) |name, i| list[i] = name;
    const d = gtk.DropDown.newFromStrings(@ptrCast(&list));
    layout.wrapChoice(d);
    layout.row(box, title, d.as(gtk.Widget));
    return d;
}
