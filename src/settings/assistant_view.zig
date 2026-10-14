//! Draft configuration and explicit, cancellable model/provider operations.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const prefs = @import("../config/preferences.zig");
const cfg = @import("../agent/config.zig");
const registry = @import("../agent/model_registry.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Action = enum { download, verify, remove, test_provider, store_key, remove_key };
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    view: *View,
    action: Action,
    config: cfg.Config,
    provider: cfg.Provider,
    secret: []u8,
    session_only: bool,
    progress: std.atomic.Value(u64) = .init(0),
    failure: ?anyerror = null,
};
pub const View = struct {
    editor: *Editor,
    host: *gtk.Box,
    enabled: *gtk.Switch,
    model: *gtk.DropDown,
    custom: *gtk.Entry,
    read_pages: *gtk.Switch,
    all: *gtk.Switch,
    threads: *gtk.SpinButton,
    context: *gtk.DropDown,
    tokens: *gtk.SpinButton,
    idle: *gtk.SpinButton,
    provider: *gtk.DropDown,
    provider_names: *gtk.StringList,
    provider_kind: *gtk.DropDown,
    provider_name: *gtk.Entry,
    endpoint: *gtk.Entry,
    engine_id: *gtk.Entry,
    language: *gtk.Entry,
    provider_enabled: *gtk.Switch,
    default_provider: *gtk.Switch,
    safe: *gtk.Switch,
    secret: *gtk.PasswordEntry,
    session_key: *gtk.Switch,
    status: *gtk.Label,
    readiness: *gtk.Label,
    cancel_button: *gtk.Button,
    filling: bool = false,
    editing: bool = false,
    dead: bool = false,
    provider_index: usize = 0,
    cancel: ?*gio.Cancellable = null,
    job: ?*Job = null,
    timer: c_uint = 0,
    buttons: [6]*gtk.Button = undefined,
    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        const general = section(host, "General");
        note(general, "Off by default. Answers run on this device; submitted questions go to your selected search engines. Typing never sends a request. This experimental small model can make mistakes.");
        const enabled = toggle(general, "Enable launcher assistant");
        const read_pages = toggle(general, "Read search result pages");
        const models = section(host, "Models");
        const model = choice(models, "Selected model", &.{ registry.models[0].name, registry.models[1].name, "Custom local GGUF (compatibility checked)" });
        const custom = entry(models, "Custom GGUF absolute path", 4096);
        const readiness = w.label("", "pearl-secondary");
        readiness.setWrap(1);
        models.append(readiness.as(gtk.Widget));
        note(models, "LiquidAI LFM2.5-350M: Q4_K_M downloads 229 MB; Q8_0 downloads 379 MB. Selecting does not download it. Downloads are immediate and independent of Apply/Discard. Imported models are limited to 768 MB. Apply with the assistant disabled before testing or removing a model. Runtime: llama.cpp v0.6.0.");
        const license = gtk.LinkButton.newWithLabel(registry.license_url, "LiquidAI model license");
        models.append(license.as(gtk.Widget));
        const download = button(models, "Download selected model");
        const verify = button(models, "Verify model and test tools locally");
        const remove = button(models, "Remove selected download");
        const engines = section(host, "Search engines");
        note(engines, "Google is the default choice through your SearXNG instance. Enter its base URL and enable the Google engine there. Pearl does not choose a public instance for you. HTTP/private addresses are allowed only for the explicitly configured SearXNG endpoint.");
        const all = toggle(engines, "Search all enabled engines (maximum 3)");
        const names = gtk.StringList.new(null);
        _ = names.ref();
        const provider = gtk.DropDown.new(names.as(gio.ListModel), null);
        formRow(engines, "Edit engine", provider.as(gtk.Widget));
        const add = button(engines, "Add search engine");
        const remove_provider = button(engines, "Remove this engine");
        const provider_name = entry(engines, "Display name", 80);
        const provider_kind = choice(engines, "Connection", &.{ "Google through SearXNG", "SearXNG", "Brave Search API", "Google API (existing accounts only)" });
        const endpoint = entry(engines, "SearXNG base URL", 1024);
        endpoint.setPlaceholderText("https://search.example.org");
        const engine_id = entry(engines, "Google API search engine ID", 128);
        note(engines, "Google's direct JSON API is closed to new customers and retires January 1, 2027. The existing-account connection requires an API key and engine ID.");
        const language = entry(engines, "Search language", 16);
        const provider_enabled = toggle(engines, "Engine enabled");
        const default_provider = toggle(engines, "Use as default engine");
        const safe = toggle(engines, "Safe search");
        const secret = gtk.PasswordEntry.new();
        secret.setShowPeekIcon(1);
        formRow(engines, "API key (never included in preferences)", secret.as(gtk.Widget));
        const session_key = toggle(engines, "Keep key in Secret Service session collection only");
        const store_key = button(engines, "Save or replace key now");
        const remove_key = button(engines, "Remove saved key now");
        note(engines, "Keys use Secret Service. If it is unavailable or locked, unlock it before saving. Test sends the sample query “Pearl desktop” to this engine immediately.");
        const test_provider = button(engines, "Test connection now");
        const resources = section(host, "Resources");
        const threads = number(resources, "CPU threads", 1, 2, 1);
        const context = choice(resources, "Context tokens", &.{ "2048", "4096" });
        const tokens = number(resources, "Maximum answer tokens", 64, 512, 32);
        const idle = number(resources, "Unload after idle seconds", 15, 300, 15);
        note(resources, "Conversations stay in this session only. Disabling the assistant clears conversations and stops its processes. Close or Escape cancels work; clicking another window keeps the chat open.");
        const status = w.label("", "pearl-secondary");
        status.setWrap(1);
        status.setSelectable(1);
        host.append(status.as(gtk.Widget));
        const cancel_button = button(host, "Cancel operation");
        self.* = .{ .host = host, .editor = editor, .enabled = enabled, .model = model, .custom = custom, .read_pages = read_pages, .all = all, .threads = threads, .context = context, .tokens = tokens, .idle = idle, .provider = provider, .provider_names = names, .provider_kind = provider_kind, .provider_name = provider_name, .endpoint = endpoint, .engine_id = engine_id, .language = language, .provider_enabled = provider_enabled, .default_provider = default_provider, .safe = safe, .secret = secret, .session_key = session_key, .status = status, .readiness = readiness, .cancel_button = cancel_button, .buttons = .{ download, verify, remove, test_provider, store_key, remove_key } };
        for ([_]*gtk.Switch{ enabled, read_pages, all, provider_enabled, default_provider, safe }) |s| _ = object.Object.signals.notify.connect(s.as(object.Object), *View, changed, self, .{ .detail = "active" });
        for ([_]*gtk.DropDown{ model, context, provider_kind }) |s| _ = object.Object.signals.notify.connect(s.as(object.Object), *View, changed, self, .{ .detail = "selected" });
        for ([_]*gtk.Entry{ custom, provider_name, endpoint, engine_id, language }) |e| _ = gtk.Editable.signals.changed.connect(e.as(gtk.Editable), *View, textChanged, self, .{});
        for ([_]*gtk.SpinButton{ threads, tokens, idle }) |s| _ = gtk.SpinButton.signals.value_changed.connect(s, *View, numberChanged, self, .{});
        _ = object.Object.signals.notify.connect(provider.as(object.Object), *View, providerSelected, self, .{ .detail = "selected" });
        _ = gtk.Button.signals.clicked.connect(add, *View, addProvider, self, .{});
        _ = gtk.Button.signals.clicked.connect(remove_provider, *View, removeProvider, self, .{});
        for (self.buttons) |b| _ = gtk.Button.signals.clicked.connect(b, *View, actionClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel_button, *View, cancelClicked, self, .{});
        self.timer = glib.timeoutAdd(250, tick, self);
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.dead = true;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.cancel) |cancel| cancel.cancel();
        self.provider_names.unref();
        if (self.job == null) a.destroy(self);
    }
    fn document(self: *View, alloc: std.mem.Allocator) !prefs.Preferences {
        try prefs.boundedJson(self.editor.text(), prefs.max_bytes, 24);
        return std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
    }
    fn commit(self: *View, value: prefs.Preferences, alloc: std.mem.Allocator) !void {
        const text = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
        try self.editor.edit(text);
    }
    fn save(self: *View) void {
        if (self.filling or self.editing or !self.editor.editable()) return;
        self.editing = true;
        defer self.editing = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        var config = &value.assistant;
        config.enabled = self.enabled.getActive() != 0;
        config.model_id = switch (self.model.getSelected()) {
            0 => registry.models[0].id,
            1 => registry.models[1].id,
            else => "custom",
        };
        config.custom_model = std.mem.span(self.custom.as(gtk.Editable).getText());
        config.read_pages = self.read_pages.getActive() != 0;
        config.search_mode = if (self.all.getActive() != 0) .all else .default;
        config.cpu_threads = @intCast(self.threads.getValueAsInt());
        config.context_tokens = if (self.context.getSelected() == 0) 2048 else 4096;
        config.answer_tokens = @intCast(self.tokens.getValueAsInt());
        config.idle_unload_seconds = @intCast(self.idle.getValueAsInt());
        if (self.provider_index < config.providers.len) {
            const list = alloc.dupe(cfg.Provider, config.providers) catch return;
            const p = &list[self.provider_index];
            p.kind = @enumFromInt(self.provider_kind.getSelected());
            p.name = std.mem.span(self.provider_name.as(gtk.Editable).getText());
            p.endpoint = std.mem.span(self.endpoint.as(gtk.Editable).getText());
            p.engine_id = std.mem.span(self.engine_id.as(gtk.Editable).getText());
            p.language = std.mem.span(self.language.as(gtk.Editable).getText());
            p.enabled = self.provider_enabled.getActive() != 0;
            p.safe_search = self.safe.getActive() != 0;
            config.providers = list;
            if (self.default_provider.getActive() != 0) config.default_provider_id = p.id else if (std.mem.eql(u8, p.id, config.default_provider_id)) config.default_provider_id = "";
        }
        self.commit(value, alloc) catch |err| self.editor.error_code.set(@errorName(err));
    }
    pub fn update(self: *View) void {
        if (self.dead or self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value = self.document(alloc) catch return;
        const config = value.assistant;
        self.host.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        self.enabled.setActive(@intFromBool(config.enabled));
        self.model.setSelected(if (std.mem.eql(u8, config.model_id, registry.models[0].id)) 0 else if (std.mem.eql(u8, config.model_id, registry.models[1].id)) 1 else 2);
        fill(alloc, self.custom, config.custom_model);
        self.read_pages.setActive(@intFromBool(config.read_pages));
        self.all.setActive(@intFromBool(config.search_mode == .all));
        self.threads.setValue(@floatFromInt(config.cpu_threads));
        self.context.setSelected(if (config.context_tokens == 2048) 0 else 1);
        self.tokens.setValue(@floatFromInt(config.answer_tokens));
        self.idle.setValue(@floatFromInt(config.idle_unload_seconds));
        const current = @min(self.provider_index, config.providers.len -| 1);
        self.provider_names.splice(0, self.provider_names.as(gio.ListModel).getNItems(), null);
        for (config.providers) |p| self.provider_names.append(alloc.dupeZ(u8, p.name) catch continue);
        self.provider_index = current;
        self.provider.setSelected(@intCast(current));
        if (current < config.providers.len) {
            const p = config.providers[current];
            self.provider_kind.setSelected(@intFromEnum(p.kind));
            fill(alloc, self.provider_name, p.name);
            fill(alloc, self.endpoint, p.endpoint);
            fill(alloc, self.engine_id, p.engine_id);
            fill(alloc, self.language, p.language);
            self.provider_enabled.setActive(@intFromBool(p.enabled));
            self.default_provider.setActive(@intFromBool(std.mem.eql(u8, config.default_provider_id, p.id)));
            self.safe.setActive(@intFromBool(p.safe_search));
        }
        if (registry.find(config.model_id)) |model| {
            const filename = @import("../agent/downloads.zig").path(alloc, model) catch return;
            self.readiness.setText(if (std.c.access(filename, std.c.F_OK) == 0) "Model downloaded. It is verified again before loading." else "Model not installed. Download is optional and explicit.");
        } else self.readiness.setText("Custom GGUF: verify compatibility before use.");
        for (self.buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(self.job == null));
        self.cancel_button.as(gtk.Widget).setSensitive(@intFromBool(self.job != null));
    }
    fn providerSelected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        self.provider_index = self.provider.getSelected();
        self.secret.as(gtk.Editable).setText("");
        self.update();
    }
    fn addProvider(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.providers;
        if (old.len >= 8) return;
        const list = alloc.alloc(cfg.Provider, old.len + 1) catch return;
        @memcpy(list[0..old.len], old);
        const id = std.fmt.allocPrint(alloc, "engine-{d}", .{glib.getMonotonicTime()}) catch return;
        list[old.len] = .{ .id = id, .name = "New search engine", .kind = .searxng, .enabled = false };
        value.assistant.providers = list;
        self.provider_index = old.len;
        self.commit(value, alloc) catch return;
        self.update();
    }
    fn removeProvider(_: *gtk.Button, self: *View) callconv(.c) void {
        if (!self.editor.editable()) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.providers;
        if (self.provider_index >= old.len) return;
        const removed = old[self.provider_index];
        const list = alloc.alloc(cfg.Provider, old.len - 1) catch return;
        @memcpy(list[0..self.provider_index], old[0..self.provider_index]);
        @memcpy(list[self.provider_index..], old[self.provider_index + 1 ..]);
        value.assistant.providers = list;
        if (std.mem.eql(u8, removed.id, value.assistant.default_provider_id)) value.assistant.default_provider_id = "";
        self.provider_index = 0;
        self.commit(value, alloc) catch return;
        self.update();
    }
    fn actionClicked(button_: *gtk.Button, self: *View) callconv(.c) void {
        for (self.buttons, 0..) |b, i| if (button_ == b) {
            self.begin(@enumFromInt(i)) catch |err| self.status.setText(@errorName(err));
            return;
        };
    }
    fn begin(self: *View, action: Action) !void {
        if (self.job != null) return error.OperationInProgress;
        if (!self.editor.editable()) return error.SettingsUnavailable;
        const job = try a.create(Job);
        job.* = .{ .view = self, .action = action, .config = undefined, .provider = .{}, .secret = undefined, .session_only = self.session_key.getActive() != 0 };
        errdefer {
            job.arena.deinit();
            a.destroy(job);
        }
        const alloc = job.arena.allocator();
        job.config = (try self.document(alloc)).assistant;
        try job.config.validate();
        if (action == .remove and (job.config.enabled or self.editor.state.dirty)) return error.ApplyAssistantDisabledBeforeRemovingModel;
        if (action == .verify and (job.config.enabled or self.editor.state.dirty)) return error.ApplyAssistantDisabledBeforeTestingModel;
        if (self.provider_index < job.config.providers.len) job.provider = job.config.providers[self.provider_index] else if (@intFromEnum(action) >= @intFromEnum(Action.test_provider)) return error.SearchProviderRequired;
        job.secret = try alloc.dupe(u8, std.mem.span(self.secret.as(gtk.Editable).getText()));
        self.secret.as(gtk.Editable).setText("");
        self.cancel = gio.Cancellable.new();
        self.job = job;
        if (gio.Application.getDefault()) |app| app.hold();
        const task = gio.Task.new(null, self.cancel, done, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
        self.status.setText("Working…");
        self.update();
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        operate(job, cancel.?) catch |err| {
            job.failure = err;
        };
        std.crypto.secureZero(u8, job.secret);
        task.returnPointer(job, null);
    }
    fn operate(job: *Job, cancel: *gio.Cancellable) !void {
        const alloc = job.arena.allocator();
        switch (job.action) {
            .download => try @import("../agent/downloads.zig").install(registry.find(job.config.model_id) orelse return error.SelectDownloadableModel, cancel, &job.progress),
            .remove => try @import("../agent/downloads.zig").remove(registry.find(job.config.model_id) orelse return error.CustomModelNotManaged),
            .verify => {
                var runtime: @import("../agent/runtime.zig").Runtime = .{};
                defer runtime.stop();
                try runtime.ensure(job.config, cancel);
                try @import("../agent/model_check.zig").check(alloc, &runtime, cancel);
            },
            .test_provider => {
                _ = try @import("../agent/providers.zig").search(alloc, job.provider, "Pearl desktop", cancel);
            },
            .store_key => try @import("../agent/credentials.zig").store(job.provider.id, job.secret, job.session_only),
            .remove_key => try @import("../agent/credentials.zig").remove(job.provider.id),
        }
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
        self.status.setText(if (job.failure) |err| @errorName(err) else "Operation complete. Apply saves your configuration selection.");
        self.update();
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.cancel) |cancel| cancel.cancel();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (self.job) |job| if (job.action == .download) {
            var buffer: [96]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buffer, "Downloaded {d} MB…", .{job.progress.load(.monotonic) / 1000000}) catch return 1;
            self.status.setText(text);
        };
        if (!self.editor.editable()) if (self.cancel) |cancel| cancel.cancel();
        return 1;
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.save();
    }
    fn textChanged(_: *gtk.Editable, self: *View) callconv(.c) void {
        self.save();
    }
    fn numberChanged(_: *gtk.SpinButton, self: *View) callconv(.c) void {
        self.save();
    }
};
fn section(host: *gtk.Box, title: [:0]const u8) *gtk.Box {
    const box = w.column(10);
    box.as(gtk.Widget).addCssClass("settings-card");
    box.append(w.label(title, "settings-row-title").as(gtk.Widget));
    host.append(box.as(gtk.Widget));
    return box;
}
fn note(host: *gtk.Box, text: [:0]const u8) void {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    host.append(l.as(gtk.Widget));
}
fn formRow(host: *gtk.Box, title: [:0]const u8, widget: *gtk.Widget) void {
    const box = w.column(4);
    box.append(w.label(title, "settings-row-title").as(gtk.Widget));
    w.name(widget, title);
    box.append(widget);
    host.append(box.as(gtk.Widget));
}
fn toggle(host: *gtk.Box, title: [:0]const u8) *gtk.Switch {
    const s = gtk.Switch.new();
    s.as(gtk.Widget).setHalign(.start);
    formRow(host, title, s.as(gtk.Widget));
    return s;
}
fn entry(host: *gtk.Box, title: [:0]const u8, max: c_int) *gtk.Entry {
    const e = gtk.Entry.new();
    e.setMaxLength(max);
    formRow(host, title, e.as(gtk.Widget));
    return e;
}
fn choice(host: *gtk.Box, title: [:0]const u8, names: []const [:0]const u8) *gtk.DropDown {
    var list: [8]?[*:0]const u8 = @splat(null);
    for (names, 0..) |name, i| list[i] = name;
    const d = gtk.DropDown.newFromStrings(@ptrCast(&list));
    formRow(host, title, d.as(gtk.Widget));
    return d;
}
fn number(host: *gtk.Box, title: [:0]const u8, min: f64, max: f64, step: f64) *gtk.SpinButton {
    const s = gtk.SpinButton.newWithRange(min, max, step);
    formRow(host, title, s.as(gtk.Widget));
    return s;
}
fn button(host: *gtk.Box, title: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(title);
    host.append(b.as(gtk.Widget));
    return b;
}
fn fill(alloc: std.mem.Allocator, e: *gtk.Entry, text: []const u8) void {
    if (e.as(gtk.Widget).hasFocus() != 0 or e.as(gtk.Widget).getFocusChild() != null) return;
    e.as(gtk.Editable).setText(alloc.dupeZ(u8, text) catch return);
}
