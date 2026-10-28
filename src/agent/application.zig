//! Native conversation frontend, with I/O and inference on one worker.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const wire = @import("../aqueous/transport.zig");
const protocol = @import("protocol.zig");
const controller = @import("controller.zig");
const Config = @import("config.zig").Config;
const RuntimeModule = @import("runtime.zig");
const Runtime = RuntimeModule.Runtime;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Conversation = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    turns: std.ArrayList(controller.Turn) = .empty,
    sources: []controller.Source = &.{},
    bytes: usize = 0,
    fn clear(self: *Conversation) void {
        self.arena.deinit();
        self.* = .{};
    }
    fn append(self: *Conversation, question: []const u8, answer: []const u8, sources: []const controller.Source) !void {
        var replacement: Conversation = .{};
        errdefer replacement.clear();
        const alloc = replacement.arena.allocator();
        const source_json = try std.json.Stringify.valueAlloc(alloc, sources, .{});
        if (source_json.len + question.len + answer.len > 128 * 1024) return error.ConversationTooLarge;
        replacement.sources = try std.json.parseFromSliceLeaky([]controller.Source, alloc, source_json, .{});
        var first = self.turns.items.len - @min(self.turns.items.len, 19);
        var bytes = source_json.len + question.len + answer.len;
        for (self.turns.items[first..]) |turn| bytes += turn.question.len + turn.answer.len;
        while (bytes > 128 * 1024 and first < self.turns.items.len) : (first += 1) bytes -= self.turns.items[first].question.len + self.turns.items[first].answer.len;
        for (self.turns.items[first..]) |turn| try replacement.turns.append(alloc, .{ .question = try alloc.dupe(u8, turn.question), .answer = try alloc.dupe(u8, turn.answer) });
        try replacement.turns.append(alloc, .{ .question = try alloc.dupe(u8, question), .answer = try alloc.dupe(u8, answer) });
        replacement.bytes = bytes;
        self.clear();
        self.* = replacement;
    }
};
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    owner: *App,
    config: Config,
    question: []const u8,
    history: []const controller.Turn,
    sources: []const controller.Source,
    conversation: usize,
    generation: u64,
    result: ?controller.Answer = null,
    failure: ?anyerror = null,
};
const App = struct {
    app: *gtk.Application,
    transport: wire.Transport = undefined,
    config_arena: std.heap.ArenaAllocator = .init(a),
    config: Config = .{},
    window: ?*gtk.Window = null,
    css: ?*gtk.CssProvider = null,
    body: *gtk.Box = undefined,
    scroll: *gtk.ScrolledWindow = undefined,
    composer: *gtk.TextView = undefined,
    status: *gtk.Label = undefined,
    model_label: *gtk.Label = undefined,
    compute_label: *gtk.Label = undefined,
    compute_details: *gtk.Label = undefined,
    send: *gtk.Button = undefined,
    stop_button: *gtk.Button = undefined,
    previous: *gtk.Button = undefined,
    runtime: Runtime = .{},
    conversations: [5]Conversation = @splat(.{}),
    current: usize = 0,
    count: usize = 0,
    cancel: ?*gio.Cancellable = null,
    job: ?*Job = null,
    phase: std.atomic.Value(controller.Phase) = .init(.preparing),
    live: @import("sse.zig").Live = .{},
    live_revision: u64 = 0,
    partial: ?*gtk.Label = null,
    generation: u64 = 0,
    last_request: u64 = 0,
    timer: c_uint = 0,
    unload: c_uint = 0,
    deadline: c_uint = 0,
    suspended: bool = true,
    exiting: bool = false,
    composing: bool = false,
    erase_cancelled: bool = false,
    last_error: []const u8 = "",
    compute_dirty: bool = false,
    cpu_once: bool = false,
    cpu_button: *gtk.Button = undefined,
    fn cancelWork(self: *App) void {
        self.generation += 1;
        if (self.cancel) |cancel| cancel.cancel() else self.runtime.stop();
        self.compute_dirty = true;
        if (self.unload != 0) _ = glib.Source.remove(self.unload);
        self.unload = 0;
    }
    fn shutdown(self: *App) void {
        self.exiting = true;
        self.cancelWork();
        if (self.window) |win| win.as(gtk.Widget).setVisible(0);
        if (self.job == null) self.app.as(gio.Application).quit();
    }
    fn activate(_: *gio.Application, self: *App) callconv(.c) void {
        gtk.Widget.setDefaultDirection(if (@import("i18n").rtl()) .rtl else .ltr);
        self.app.as(gio.Application).hold();
        const socket = gio.Socket.newFromFd(3, null) orelse {
            self.shutdown();
            return;
        };
        self.transport.adopt(socket) catch {
            self.shutdown();
            return;
        };
        self.timer = glib.timeoutAdd(200, tick, self);
    }
    fn event(context: *anyopaque, value: wire.Event) void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (value) {
            .failed => self.shutdown(),
            .connected, .sent => {},
            .frame => |bytes| {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const req = protocol.parse(arena.allocator(), bytes) catch {
                    self.shutdown();
                    return;
                };
                if (@import("build_options").test_hooks and req.op == .test_state) {
                    self.reply(.{ .id = req.id, .state = .{ .visible = if (self.window) |win| win.as(gtk.Widget).getVisible() != 0 else false, .busy = self.job != null, .suspended = self.suspended, .runtime = self.job != null or self.runtime.process != null, .conversations = self.count, .turns = self.conversations[self.current].turns.items, .sources = self.conversations[self.current].sources.len, .status = if (self.window != null) std.mem.span(self.status.getText()) else "", .error_code = self.last_error, .draft_chars = if (self.window != null) @intCast(self.composer.getBuffer().getCharCount()) else 0 } });
                    return;
                }
                self.handle(req) catch |err| {
                    self.reply(.{ .id = req.id, .ok = false, .err = @errorName(err) });
                    return;
                };
                self.reply(.{ .id = req.id });
            },
        }
    }
    fn reply(self: *App, value: protocol.Reply) void {
        var response = value;
        if (response.id != 0) {
            response.compute = self.computeStatus();
            self.compute_dirty = false;
        }
        const bytes = std.json.Stringify.valueAlloc(a, response, .{}) catch return;
        defer a.free(bytes);
        const frame = std.fmt.allocPrint(a, "{s}\n", .{bytes}) catch return;
        defer a.free(frame);
        self.transport.send(frame) catch self.shutdown();
    }
    fn handle(self: *App, req: protocol.Request) !void {
        if (req.id <= self.last_request) return; // idempotent handoff
        self.last_request = req.id;
        if (req.config) |cfg| {
            var next = std.heap.ArenaAllocator.init(a);
            errdefer next.deinit();
            const json = try std.json.Stringify.valueAlloc(next.allocator(), cfg, .{});
            const before = try std.json.Stringify.valueAlloc(next.allocator(), self.config, .{});
            if (req.op == .configure and !std.mem.eql(u8, before, json)) self.cancelWork();
            const copied = try std.json.parseFromSliceLeaky(Config, next.allocator(), json, .{});
            self.config_arena.deinit();
            self.config_arena = next;
            self.config = copied;
            if (!cfg.enabled) {
                self.shutdown();
                return;
            }
        }
        switch (req.op) {
            .release_runtime => {
                if (self.job != null) return error.AssistantBusy;
                self.runtime.stop();
            },
            .test_state, .test_submit, .test_hide => {
                if (!@import("build_options").test_hooks) return error.Unsupported;
                if (self.window == null) return error.Unavailable;
                if (req.op == .test_submit) try self.start(req.question);
                if (req.op == .test_hide) _ = close(self.window.?, self);
            },
            .configure => {},
            .@"suspend" => {
                self.suspended = true;
                self.cancelWork();
                if (self.window) |win| win.as(gtk.Widget).setVisible(0);
            },
            .stop => self.cancelWork(),
            .clear => {
                self.cancelWork();
                self.erase_cancelled = true;
                for (&self.conversations) |*conv| conv.clear();
                self.count = 0;
                self.current = 0;
                if (self.window != null) {
                    self.composer.getBuffer().setText("", 0);
                    self.render();
                    self.status.setText(@import("i18n").dtr("pearl-agent", "Conversation history cleared."));
                }
            },
            .ask, .@"resume" => {
                self.suspended = false;
                if (!self.config.enabled) return error.AssistantDisabled;
                if (self.window == null) self.createWindow();
                if (req.activation.len > 0) self.window.?.setStartupId(try self.config_arena.allocator().dupeSentinel(u8, req.activation, 0));
                self.window.?.present();
                if (req.op == .ask) {
                    if (self.job != null) return error.AssistantBusy;
                    self.newConversation();
                    self.start(req.question) catch |err| self.showError(err, req.question);
                }
                _ = self.composer.as(gtk.Widget).grabFocus();
            },
        }
        if (self.window != null) {
            if (req.palette) |palette| try self.style(palette);
            self.updateControls();
        }
    }
    fn createWindow(self: *App) void {
        const win = gtk.ApplicationWindow.new(self.app).as(gtk.Window);
        self.window = win;
        win.setTitle(@import("i18n").dtr("pearl-agent", "Pearl Assistant"));
        win.as(gtk.Widget).addCssClass("pearl-root");
        win.as(gtk.Widget).addCssClass("pearl-agent");
        self.css = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(win.as(gtk.Widget).getDisplay(), self.css.?.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        self.style(@import("../theme/theme.zig").dark) catch {};
        win.setDefaultSize(440, 560);
        win.as(gtk.Widget).setSizeRequest(320, 400);
        const header = gtk.HeaderBar.new();
        const title = w.column(2);
        title.append(w.label(@import("i18n").dtr("pearl-agent", "Pearl Assistant"), "title").as(gtk.Widget));
        self.model_label = w.label(@import("i18n").dtr("pearl-agent", "LFM2.5-350M · On device"), "dim-label");
        self.model_label.setEllipsize(.end);
        self.model_label.setMaxWidthChars(22);
        title.append(self.model_label.as(gtk.Widget));
        header.setTitleWidget(title.as(gtk.Widget));
        self.previous = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "History"));
        header.packStart(self.previous.as(gtk.Widget));
        const fresh = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "New"));
        header.packEnd(fresh.as(gtk.Widget));
        win.setTitlebar(header.as(gtk.Widget));
        const root = w.column(8);
        root.as(gtk.Widget).setMarginStart(12);
        root.as(gtk.Widget).setMarginEnd(12);
        root.as(gtk.Widget).setMarginBottom(12);
        self.scroll = gtk.ScrolledWindow.new();
        self.scroll.setPolicy(.never, .automatic);
        self.scroll.as(gtk.Widget).setVexpand(1);
        self.body = w.column(12);
        self.scroll.setChild(self.body.as(gtk.Widget));
        root.append(self.scroll.as(gtk.Widget));
        self.status = w.label(@import("i18n").dtr("pearl-agent", "Ask a question to search your configured engine."), "dim-label");
        self.status.setWrap(1);
        root.append(self.status.as(gtk.Widget));
        self.compute_label = w.label(@import("i18n").dtr("pearl-agent", "Model unloaded"), "dim-label");
        self.compute_label.setWrap(1);
        const compute_button = gtk.MenuButton.new();
        compute_button.setChild(self.compute_label.as(gtk.Widget));
        const popover = gtk.Popover.new();
        self.compute_details = w.label(@import("i18n").dtr("pearl-agent", "Model unloaded"), "dim-label");
        self.compute_details.setWrap(1);
        self.compute_details.setWrapMode(.word_char);
        self.compute_details.setMaxWidthChars(42);
        self.compute_details.setSelectable(1);
        popover.setChild(self.compute_details.as(gtk.Widget));
        compute_button.setPopover(popover);
        root.append(compute_button.as(gtk.Widget));
        self.cpu_button = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "Use CPU once"));
        self.cpu_button.as(gtk.Widget).setVisible(0);
        root.append(self.cpu_button.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.cpu_button, *App, cpuClicked, self, .{});
        self.composer = gtk.TextView.new();
        self.composer.setWrapMode(.word_char);
        self.composer.setAcceptsTab(0);
        self.composer.as(gtk.Widget).setSizeRequest(-1, 64);
        w.name(self.composer.as(gtk.Widget), @import("i18n").dtr("pearl-agent", "Ask a follow-up; Enter sends, Shift+Enter adds a line"));
        const input_scroll = gtk.ScrolledWindow.new();
        input_scroll.setPolicy(.never, .automatic);
        input_scroll.setMaxContentHeight(120);
        input_scroll.setPropagateNaturalHeight(1);
        input_scroll.setChild(self.composer.as(gtk.Widget));
        root.append(input_scroll.as(gtk.Widget));
        const actions = w.row(8);
        const settings = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "Settings"));
        actions.append(settings.as(gtk.Widget));
        self.stop_button = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "Stop"));
        actions.append(self.stop_button.as(gtk.Widget));
        self.send = gtk.Button.newWithLabel(@import("i18n").dtr("pearl-agent", "Send"));
        self.send.as(gtk.Widget).addCssClass("suggested-action");
        self.send.as(gtk.Widget).setHexpand(1);
        self.send.as(gtk.Widget).setHalign(.end);
        actions.append(self.send.as(gtk.Widget));
        root.append(actions.as(gtk.Widget));
        const privacy = w.label(@import("i18n").dtr("pearl-agent", "Answers on device · Web search online · Session only"), "dim-label");
        privacy.setWrap(1);
        root.append(privacy.as(gtk.Widget));
        win.setChild(root.as(gtk.Widget));
        _ = gtk.Window.signals.close_request.connect(win, *App, close, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.send, *App, sendClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.stop_button, *App, stopClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(fresh, *App, newClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.previous, *App, historyClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(settings, *App, settingsClicked, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *App, key, self, .{});
        self.composer.as(gtk.Widget).addController(keys.as(gtk.EventController));
        _ = gtk.TextView.signals.preedit_changed.connect(self.composer, *App, preedit, self, .{});
        self.render();
    }
    fn preedit(_: *gtk.TextView, text: [*:0]const u8, self: *App) callconv(.c) void {
        self.composing = text[0] != 0;
    }
    fn style(self: *App, palette: @import("../theme/theme.zig").Palette) !void {
        const sheet = try @import("../theme/theme.zig").scopedCss(a, @embedFile("agent_style"), "pearl-agent", palette);
        defer a.free(sheet);
        self.css.?.loadFromString(sheet);
    }
    fn key(_: *gtk.EventControllerKey, value: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *App) callconv(.c) c_int {
        if (self.composing) return 0;
        if (value == gdk.KEY_Escape) {
            if (self.job != null) self.cancelWork() else self.window.?.as(gtk.Widget).setVisible(0);
            return 1;
        }
        if ((value == gdk.KEY_Return or value == gdk.KEY_KP_Enter) and !modifiers.shift_mask) {
            self.submit();
            return 1;
        }
        return 0;
    }
    fn close(_: *gtk.Window, self: *App) callconv(.c) c_int {
        self.cancelWork();
        self.window.?.as(gtk.Widget).setVisible(0);
        return 1;
    }
    fn sendClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.submit();
    }
    fn stopClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.cancelWork();
        self.status.setText(@import("i18n").dtr("pearl-agent", "Stopped. Your question is preserved; Send retries it."));
    }
    fn cpuClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.cpu_once = true;
        self.submit();
    }
    fn settingsClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        self.reply(.{ .id = 0, .settings = true });
    }
    fn newClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        if (self.job != null) {
            self.status.setText(@import("i18n").dtr("pearl-agent", "Stop the current answer before starting a new chat."));
            return;
        }
        self.newConversation();
    }
    fn historyClicked(_: *gtk.Button, self: *App) callconv(.c) void {
        if (self.job == null and self.count > 1) {
            self.current = (self.current + self.count - 1) % self.count;
            self.render();
        }
    }
    fn newConversation(self: *App) void {
        self.current = if (self.count < 5) self.count else (self.current + 1) % 5;
        self.count = @min(5, self.count + 1);
        self.conversations[self.current].clear();
        self.render();
    }
    fn submit(self: *App) void {
        if (self.job != null or self.suspended) return;
        var start_: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        self.composer.getBuffer().getBounds(&start_, &end);
        const value = self.composer.getBuffer().getText(&start_, &end, 0);
        defer glib.free(value);
        const question = std.mem.trim(u8, std.mem.span(value), " \t\r\n");
        if (question.len == 0) return;
        if (self.count == 0) self.newConversation();
        self.start(question) catch |err| self.showError(err, question);
    }
    fn start(self: *App, question: []const u8) !void {
        if (question.len > 2048) return error.QuestionTooLong;
        self.last_error = "";
        if (self.job != null) return error.AssistantBusy;
        self.erase_cancelled = false;
        if (self.unload != 0) _ = glib.Source.remove(self.unload);
        self.unload = 0;
        const job = try a.create(Job);
        job.* = .{ .owner = self, .config = undefined, .question = undefined, .history = undefined, .sources = undefined, .conversation = self.current, .generation = self.generation };
        errdefer {
            job.arena.deinit();
            a.destroy(job);
        }
        const alloc = job.arena.allocator();
        job.config = try std.json.parseFromSliceLeaky(Config, alloc, try std.json.Stringify.valueAlloc(alloc, self.config, .{}), .{});
        if (self.cpu_once) {
            job.config.compute.mode = .cpu;
            self.cpu_once = false;
        }
        self.cpu_button.as(gtk.Widget).setVisible(0);
        job.question = try alloc.dupe(u8, question);
        const conv = &self.conversations[self.current];
        job.history = try std.json.parseFromSliceLeaky([]controller.Turn, alloc, try std.json.Stringify.valueAlloc(alloc, conv.turns.items, .{}), .{});
        job.sources = try std.json.parseFromSliceLeaky([]controller.Source, alloc, try std.json.Stringify.valueAlloc(alloc, conv.sources, .{}), .{});
        self.cancel = gio.Cancellable.new();
        self.job = job;
        self.phase.store(.preparing, .monotonic);
        self.live.put("");
        self.render();
        self.bubble(question, true);
        self.partial = w.label("", "pearl-agent-answer");
        self.partial.?.setWrap(1);
        self.partial.?.setWrapMode(.word_char);
        self.partial.?.setSelectable(1);
        self.body.append(self.partial.?.as(gtk.Widget));
        self.composer.getBuffer().setText("", 0);
        self.updateControls();
        self.deadline = glib.timeoutAdd(90000, timedOut, self);
        const task = gio.Task.new(null, self.cancel, completed, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        job.result = controller.run(job.arena.allocator(), &job.owner.runtime, job.config, job.question, job.history, job.sources, cancel.?, &job.owner.phase, &job.owner.live) catch |err| blk: {
            job.failure = err;
            break :blk null;
        };
        task.returnPointer(job, null);
    }
    fn completed(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(data.?));
        const job: *Job = @ptrCast(@alignCast(object.ext.cast(gio.Task, result).?.propagatePointer(null).?));
        defer {
            job.arena.deinit();
            a.destroy(job);
        }
        const cancelled = self.cancel.?.isCancelled() != 0 or job.generation != self.generation;
        self.cancel.?.unref();
        self.cancel = null;
        self.job = null;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (cancelled) {
            self.runtime.stop();
            if (!self.erase_cancelled) self.showError(error.Cancelled, job.question);
        } else if (job.failure) |err| self.showError(err, job.question) else if (job.result) |answer| {
            self.conversations[job.conversation].append(job.question, answer.text, answer.sources) catch |err| {
                self.showError(err, job.question);
                self.runtime.stop();
                self.updateControls();
                return;
            };
            self.render();
            self.status.setText(if (answer.warning.len > 0) @import("i18n").dtr("pearl-agent", "Some selected searches failed; available results are shown.") else if (answer.summarized) @import("i18n").dtr("pearl-agent", "Answer complete. Check the sources for important details.") else @import("i18n").dtr("pearl-agent", "Search results available; summary unavailable."));
        }
        if (self.exiting) {
            self.app.as(gio.Application).quit();
            return;
        }
        if (self.suspended) self.runtime.stop() else self.unload = glib.timeoutAdd(@as(c_uint, self.config.idle_unload_seconds) * 1000, unloadRuntime, self);
        self.updateControls();
    }
    fn showError(self: *App, err: anyerror, question: []const u8) void {
        std.log.scoped(.ui).warn("event=assistant-answer-failed code={s}", .{@errorName(err)});
        self.last_error = @errorName(err);
        const message: [:0]const u8 = switch (err) {
            error.ModelNotInstalled => "Download the selected model in Settings, then Send to retry.",
            error.AssistantRuntimeNotInstalled => "Install the runtime with Settings → Runtime & acceleration → Set up runtime (install if needed), then Apply and retry.",
            error.RuntimeCapabilityMissing, error.RuntimeAuthenticationMissing, error.ModelToolsIncompatible => "This runtime/model did not pass compatibility checks. Choose another runtime or model in Settings.",
            error.RuntimeReasoningUnsupported => "This thinking model needs a newer runtime with reasoning-format support. Update llama.cpp or choose an Instruct model in Settings.",
            error.AssistantRuntimeBusy => "Another local model test or answer is using the runtime. Stop it or wait, then retry.",
            error.GpuUnavailableOrMemoryInsufficient, error.GpuOffloadUnverified, error.GpuRuntimeCapabilityMissing, error.AmbiguousGpuDevice => "The selected GPU could not be used. Choose a device or enable CPU fallback in Settings, then retry.",
            error.SystemMemoryPressure => "Available memory is too low for the selected shared-memory GPU. Close other applications or select CPU in Settings, then retry.",
            error.RuntimeCheckTimedOut, error.HelperTimedOut => "The local runtime check timed out. Retry or select another runtime in Settings.",
            error.SearchUnavailable, error.SearchEndpointRequired, error.SearchProviderRequired => "Configure and test a search engine in Settings, then retry.",
            error.Cancelled => "Stopped. Your question is preserved; Send retries it.",
            error.QuestionTooLong, error.QuestionExceedsContext => "This question is too long. Shorten it and retry.",
            error.ModelChecksumMismatch, error.InvalidModelFile => "Model verification failed. Download the model again in Settings.",
            else => "The answer could not be completed. Check Settings or try a shorter question.",
        };
        if (self.window == null) return;
        self.status.setText(message);
        self.cpu_button.as(gtk.Widget).setVisible(@intFromBool(self.config.compute.mode == .gpu and !self.config.compute.fallback() and (RuntimeModule.recoverable(err) or err == error.AmbiguousGpuDevice)));
        // Do not replace a follow-up the user has already started typing.
        if (self.composer.getBuffer().getCharCount() == 0) {
            const text = a.dupeSentinel(u8, question, 0) catch return;
            defer a.free(text);
            self.composer.getBuffer().setText(text, @intCast(text.len));
        }
    }
    fn bubble(self: *App, text: []const u8, user: bool) void {
        const label = gtk.Label.new(null);
        const value = a.dupeSentinel(u8, text, 0) catch return;
        defer a.free(value);
        label.setText(value);
        label.setWrap(1);
        label.setWrapMode(.word_char);
        label.setSelectable(1);
        label.setXalign(0);
        label.as(gtk.Widget).addCssClass(if (user) "pearl-agent-question" else "pearl-agent-answer");
        self.body.append(label.as(gtk.Widget));
    }
    fn render(self: *App) void {
        if (self.window == null) return;
        const adj = self.scroll.getVadjustment();
        const bottom = adj.getValue() + adj.getPageSize() >= adj.getUpper() - 24;
        while (self.body.as(gtk.Widget).getFirstChild()) |child| self.body.remove(child);
        self.partial = null;
        const conv = &self.conversations[self.current];
        if (conv.turns.items.len == 0) self.bubble("Ask a question here or in Super+Space. Answers use your configured search engine. This small local model can make mistakes.", false);
        for (conv.turns.items) |turn| {
            self.bubble(turn.question, true);
            self.bubble(turn.answer, false);
        }
        if (conv.sources.len > 0) {
            const expander = gtk.Expander.new("Sources consulted");
            const sources = w.column(4);
            for (conv.sources) |source| {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const label = std.fmt.allocPrintSentinel(arena.allocator(), "[{d}] {s}", .{ source.id, source.title }, 0) catch continue;
                const url = arena.allocator().dupeSentinel(u8, source.url, 0) catch continue;
                const link = gtk.LinkButton.newWithLabel(url, label);
                if (object.ext.cast(gtk.Label, link.as(gtk.Button).getChild().?)) |l| {
                    l.setWrap(1);
                    l.setWrapMode(.word_char);
                }
                sources.append(link.as(gtk.Widget));
            }
            expander.setChild(sources.as(gtk.Widget));
            self.body.append(expander.as(gtk.Widget));
        }
        if (bottom) _ = glib.idleAdd(scrollBottom, self);
        self.updateControls();
    }
    fn scrollBottom(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.window != null) {
            const adj = self.scroll.getVadjustment();
            adj.setValue(@max(0, adj.getUpper() - adj.getPageSize()));
        }
        return 0;
    }
    fn updateControls(self: *App) void {
        self.publishCompute();
        self.send.as(gtk.Widget).setSensitive(@intFromBool(self.job == null and !self.suspended));
        self.stop_button.as(gtk.Widget).setSensitive(@intFromBool(self.job != null));
        self.previous.as(gtk.Widget).setSensitive(@intFromBool(self.job == null and self.count > 1));
        const model = @import("model_registry.zig").find(self.config.model_id);
        self.model_label.setText(if (model) |m| m.name else @import("i18n").dtr("pearl-agent", "Custom model · On device"));
        if (self.job != null) {
            self.compute_label.setText(@import("i18n").dtr("pearl-agent", "Local inference…"));
            self.compute_details.setText(@import("i18n").dtr("pearl-agent", "Runtime and device details update when the current operation completes."));
            return;
        }
        var buffer: [2048]u8 = undefined;
        const text = if (self.runtime.process == null) "Model unloaded" else if (self.runtime.device) |d| std.mem.printSentinel(&buffer, "GPU · {s} · {s} · {d} layers", .{ @tagName(d.backend), d.description, self.runtime.offload_layers }, 0) catch "GPU" else if (self.runtime.fallback_reason.len > 0) "CPU · fallback" else "CPU · local inference";
        self.compute_label.setText(text);
        if (self.runtime.process != null) {
            const detail = std.fmt.allocPrintSentinel(a, "{s}\n{s}\n{s}\nHost memory: no Pearl limit", .{ self.runtime.executable, self.runtime.version, self.runtime.fallback_reason }, 0) catch return;
            defer a.free(detail);
            self.compute_label.as(gtk.Widget).setTooltipText(detail);
            self.compute_details.setText(detail);
        } else {
            self.compute_label.as(gtk.Widget).setTooltipText(null);
            self.compute_details.setText(@import("i18n").dtr("pearl-agent", "Model unloaded; the conversation remains available."));
        }
    }
    fn publishCompute(self: *App) void {
        self.compute_dirty = true;
    }
    fn computeStatus(self: *App) protocol.ComputeStatus {
        const busy = self.job != null;
        return if (busy) .{ .busy = true } else .{ .loaded = self.runtime.process != null, .gpu = self.runtime.gpu, .backend = if (self.runtime.device) |d| d.backend else .auto, .layers = self.runtime.offload_layers, .fallback = self.runtime.fallback_reason.len > 0 };
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        if (self.compute_dirty and self.transport.output == null) {
            self.compute_dirty = false;
            self.reply(.{ .id = 0, .compute = self.computeStatus() });
        }
        if (self.job != null and self.window != null) self.status.setText(switch (self.phase.load(.monotonic)) {
            .preparing => @import("i18n").dtr("pearl-agent", "Preparing local model…"),
            .checking => @import("i18n").dtr("pearl-agent", "Checking runtime and preparing local model…"),
            .fallback => @import("i18n").dtr("pearl-agent", "GPU unavailable. Continuing on CPU with your search results…"),
            .deciding => @import("i18n").dtr("pearl-agent", "Working on your question…"),
            .searching => @import("i18n").dtr("pearl-agent", "Searching configured engines…"),
            .reading => @import("i18n").dtr("pearl-agent", "Reading a source page…"),
            .answering => @import("i18n").dtr("pearl-agent", "Checking the answer and sources…"),
        });
        if (self.job != null) if (self.partial) |partial| {
            var buffer: [16384]u8 = undefined;
            if (self.live.copy(&buffer, &self.live_revision)) |text| {
                const value = a.dupeSentinel(u8, text, 0) catch return 1;
                defer a.free(value);
                partial.setText(value);
                if (text.len > 0) self.status.setText(@import("i18n").dtr("pearl-agent", "Writing a draft… sources will be checked when complete."));
            }
        };
        return 1;
    }
    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.cancelWork();
        return 0;
    }
    fn unloadRuntime(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.unload = 0;
        self.runtime.stop();
        if (self.window != null) self.updateControls() else self.publishCompute();
        return 0;
    }
};
pub fn run() !u8 {
    const git = @import("build_options").git_variant;
    const application = gtk.Application.new(if (git) "org.aqueous.Pearl.Git.Agent" else "org.aqueous.Pearl.Agent", .{ .non_unique = true });
    defer application.unref();
    var state: App = .{ .app = application };
    state.transport = wire.Transport.init(&state, App.event);
    state.transport.secure = true;
    state.transport.framer.limit = 32768;
    defer {
        if (state.timer != 0) _ = glib.Source.remove(state.timer);
        if (state.unload != 0) _ = glib.Source.remove(state.unload);
        state.transport.deinit();
        state.runtime.stop();
        state.config_arena.deinit();
        for (&state.conversations) |*conv| conv.clear();
        if (state.window) |win| win.destroy();
        if (state.css) |css| css.unref();
    }
    _ = gio.Application.signals.activate.connect(application.as(gio.Application), *App, App.activate, &state, .{});
    return @intCast(application.as(gio.Application).run(0, null));
}
