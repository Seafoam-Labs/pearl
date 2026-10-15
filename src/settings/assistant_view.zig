//! Draft configuration and explicit, cancellable model/provider operations.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const layout = @import("assistant_layout.zig");
const prefs = @import("../config/preferences.zig");
const cfg = @import("../agent/config.zig");
const registry = @import("../agent/model_registry.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Action = enum { download, verify, remove, test_provider, store_key, remove_key, discover, runtime_check, benchmark, setup_runtime, apply_status, apply_stop };
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
    details: []const u8 = "",
    devices: []const @import("../agent/compute.zig").Device = &.{},
    busy: bool = false,
    selected_runtime: ?cfg.RuntimeConfig = null,
};
pub const View = struct {
    editor: *Editor,
    host: *gtk.Box,
    enabled: *gtk.Switch,
    model: *gtk.DropDown,
    model_license: *gtk.LinkButton,
    custom: *gtk.Entry,
    read_pages: *gtk.Switch,
    all: *gtk.Switch,
    threads: *gtk.SpinButton,
    context: *gtk.SpinButton,
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
    runtime_source: *gtk.DropDown,
    runtime_path: *gtk.Entry,
    compute_mode: layout.ComputeChoice,
    model_options: layout.Section,
    runtime_options: layout.Section,
    engines_section: layout.Section,
    resources_section: layout.Section,
    enable_summary: *gtk.Label,
    runtime_summary: *gtk.Label,
    model_status: *gtk.Label,
    runtime_status: *gtk.Label,
    provider_status: *gtk.Label,
    provider_editor: *gtk.Box,
    credentials: *gtk.Box,
    legacy_notice: *gtk.Label,
    gpu_options: *gtk.Box,
    custom_runtime: *gtk.Box,
    operation: *gtk.Box,
    comparison_status: *gtk.Label,
    local_cancels: [3]*gtk.Button,
    last_action: ?Action = null,
    checked_fingerprint: ?u64 = null,
    backend: *gtk.DropDown,
    device: *gtk.DropDown,
    device_names: *gtk.StringList,
    device_arena: std.heap.ArenaAllocator = .init(a),
    devices: []const @import("../agent/compute.zig").Device = &.{},
    fallback: *gtk.Switch,
    layers: *gtk.SpinButton,
    gpu_memory: *gtk.SpinButton,
    runtime_details: *gtk.Label,
    picker: ?*gtk.FileChooserNative = null,
    apply_dialog: ?*gtk.Dialog = null,
    cancel_button: *gtk.Button,
    filling: bool = false,
    editing: bool = false,
    dead: bool = false,
    provider_index: usize = 0,
    cancel: ?*gio.Cancellable = null,
    job: ?*Job = null,
    timer: c_uint = 0,
    buttons: [10]*gtk.Button = undefined,
    comparison: ?*@import("benchmark_view.zig").View = null,
    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        host.as(gtk.Widget).addCssClass("assistant-view");
        host.setSpacing(16);
        const operation = section(host, "Current operation");
        const status = statusLabel(operation);
        const comparison_status = statusLabel(operation);
        const cancel_button = button(operation, "Cancel operation");
        const general = section(host, "");
        const enabled = toggle(general, "Launcher assistant");
        const enable_summary = statusLabel(general);
        note(general, "Answers run locally. Submitted questions go to your search engine; typing sends nothing. Experimental: check answers and their sources.");
        const models = section(host, "Model");
        var model_labels: [registry.models.len + 1][:0]const u8 = undefined;
        for (registry.models, 0..) |item, i| model_labels[i] = item.name;
        model_labels[registry.models.len] = "Custom local GGUF (compatibility checked)";
        const model = choice(models, "Selected model", &model_labels);
        const model_options = layout.Section.create(models, "Model options", "License, downloads, custom file and comparisons");
        const custom = entry(model_options.body, "Custom GGUF absolute path", 4096);
        const readiness = w.label("", "pearl-secondary");
        readiness.setWrap(1);
        models.append(readiness.as(gtk.Widget));
        note(model_options.body, "Selection never downloads a model. Changing models resets context and generation tokens to its automatic profile.");
        note(model_options.body, "Downloads and removal are immediate and independent of Apply/Discard. Local GGUF files have no Pearl size limit. Disable and Apply before removing a model.");
        const license = gtk.LinkButton.newWithLabel(registry.license_url, "Selected model license");
        model_options.body.append(license.as(gtk.Widget));
        const model_actions = layout.actions(model_options.body);
        const download = layout.button(model_actions, "Download selected model");
        const verify = button(models, "Verify model and test tools locally");
        const remove = layout.button(model_actions, "Remove selected download");
        const benchmark = layout.button(model_actions, "Compare models on CPU and GPU…");
        const model_status = statusLabel(models);
        const model_cancel = button(models, "Cancel model operation");
        models.reorderChildAfter(model_options.expander.as(gtk.Widget), model_cancel.as(gtk.Widget));
        const runtime_section = section(host, "Runtime & acceleration");
        const runtime_summary = statusLabel(runtime_section);
        const compute_mode = layout.ComputeChoice.create(runtime_section);
        const runtime_options = layout.Section.create(runtime_section, "Runtime setup & checks", "Select a runtime, discover devices or check compatibility");
        const runtime_body = runtime_options.body;
        const runtime_source = choice(runtime_body, "Runtime source", &.{ "System installation", "Pearl runtime package", "Custom executable" });
        const custom_runtime = w.column(8);
        runtime_body.append(custom_runtime.as(gtk.Widget));
        const runtime_path = entry(custom_runtime, "Custom llama-server absolute path", 4096);
        const browse = button(custom_runtime, "Browse for llama-server…");
        note(runtime_body, "Setup reuses a compatible runtime or installs llama.cpp with Shelly on Devario and pacman on Arch. Complete authentication and package confirmation in the terminal.");
        note(runtime_body, "Packages install immediately; Apply saves the runtime selection. Closing Settings does not stop installation. Setup includes ggml-vulkan for Automatic/Vulkan or ggml-cuda for CUDA.");
        const runtime_actions = layout.actions(runtime_body);
        const setup_runtime = layout.button(runtime_actions, "Set up runtime (install if needed)");
        const discover = layout.button(runtime_actions, "Discover runtime and GPU devices");
        const runtime_check = layout.button(runtime_actions, "Check runtime and model now");
        const runtime_details = w.label("Runtime not checked. Discovery and testing run only when requested.", "pearl-secondary");
        runtime_details.setWrap(1);
        runtime_details.setWrapMode(.word_char);
        runtime_details.setSelectable(1);
        runtime_body.append(runtime_details.as(gtk.Widget));
        const gpu_options = w.column(12);
        runtime_body.append(gpu_options.as(gtk.Widget));
        const backend = choice(gpu_options, "GPU backend", &.{ "Automatic", "Vulkan", "CUDA" });
        const device_names = gtk.StringList.new(null);
        _ = device_names.ref();
        device_names.append("Automatic device selection");
        const device = gtk.DropDown.new(device_names.as(gio.ListModel), null);
        layout.wrapChoice(device);
        formRow(gpu_options, "GPU device", device.as(gtk.Widget));
        const fallback = toggle(gpu_options, "Use CPU if the selected GPU is unavailable");
        const advanced = gtk.Expander.new("Advanced memory and layer offload");
        const advanced_body = w.column(8);
        const layers = number(advanced_body, "GPU layers (0 = automatic)", 0, 1024, 1);
        const gpu_memory = number(advanced_body, "GPU memory target MiB (0 = automatic)", 0, 1048576, 128);
        note(advanced_body, "GPU memory targets are estimates, not hard VRAM caps. Integrated GPUs share system RAM. Pearl has no host RAM cap; available hardware and operating-system limits determine what can run.");
        advanced.setChild(advanced_body.as(gtk.Widget));
        gpu_options.append(advanced.as(gtk.Widget));
        note(runtime_body, "Checks use draft settings and a local model/tool test, without searches or Apply. Stop any current answer first; the idle model unloads before testing.");
        const runtime_status = statusLabel(runtime_section);
        const runtime_cancel = button(runtime_section, "Cancel runtime check");
        const engines_section = layout.Section.create(host, "Search engines", "Choose the default engine and edit connections");
        const engines = engines_section.body;
        const all = toggle(engines, "Search all enabled engines (maximum 3)");
        const names = gtk.StringList.new(null);
        _ = names.ref();
        const provider = gtk.DropDown.new(names.as(gio.ListModel), null);
        layout.wrapChoice(provider);
        formRow(engines, "Edit engine", provider.as(gtk.Widget));
        const engine_actions = layout.actions(engines);
        const add = layout.button(engine_actions, "Add search engine");
        const remove_provider = layout.button(engine_actions, "Remove this engine");
        const provider_editor = w.column(12);
        engines.append(provider_editor.as(gtk.Widget));
        const provider_name = entry(provider_editor, "Display name", 80);
        const provider_kind = choice(provider_editor, "Connection", &.{ "Google through SearXNG", "SearXNG", "Brave Search API", "Google API (existing accounts only)", "Bing (no setup required)" });
        const endpoint = entry(provider_editor, "SearXNG base URL", 1024);
        endpoint.setPlaceholderText("https://search.example.org");
        const engine_id = entry(provider_editor, "Google API search engine ID", 128);
        const legacy_notice = statusLabel(provider_editor);
        legacy_notice.setText("Google's direct JSON API is closed to new customers and retires January 1, 2027. Existing accounts require an API key and engine ID.");
        const language = entry(provider_editor, "Search language", 16);
        const provider_enabled = toggle(provider_editor, "Engine enabled");
        const default_provider = toggle(provider_editor, "Use as default engine");
        const safe = toggle(provider_editor, "Safe search");
        const credentials = w.column(12);
        provider_editor.append(credentials.as(gtk.Widget));
        const secret = gtk.PasswordEntry.new();
        secret.setShowPeekIcon(1);
        formRow(credentials, "API key (never included in preferences)", secret.as(gtk.Widget));
        const session_key = toggle(credentials, "Keep key in Secret Service session collection only");
        note(credentials, "Keys use Secret Service. Unlock it before saving. Saving or removing a key happens immediately, separately from Apply.");
        const key_actions = layout.actions(credentials);
        const store_key = layout.button(key_actions, "Save or replace key now");
        const remove_key = layout.button(key_actions, "Remove saved key now");
        note(provider_editor, "Test sends “Pearl desktop” to the selected engine immediately. Bing needs no account, API key or server setup.");
        const test_provider = button(provider_editor, "Test connection now");
        const provider_status = statusLabel(engines);
        const provider_cancel = button(engines, "Cancel engine operation");
        // Comparison is one sibling section; all shortcuts reveal this instance.
        const comparison_host = w.column(0);
        host.append(comparison_host.as(gtk.Widget));
        const resources_section = layout.Section.create(host, "Resources & behavior", "Automatic model profile and idle unload");
        const resources = resources_section.body;
        const read_pages = toggle(resources, "Read search result pages");
        const threads = number(resources, "CPU threads (0 = runtime automatic)", 0, std.math.maxInt(c_int), 1);
        const context = number(resources, "Context tokens (0 = model profile)", 0, std.math.maxInt(c_int), 1024);
        const tokens = number(resources, "Generation tokens (0 = model profile)", 0, std.math.maxInt(c_int), 128);
        note(resources, "Generation tokens include reasoning for thinking models. Context must leave room for the question, evidence and generation. Explicit thread counts are passed to the runtime without a Pearl hardware cap.");
        const idle = number(resources, "Unload after idle seconds", 15, 300, 15);
        note(resources, "Conversations stay in this session only. Disabling the assistant clears conversations and stops its processes. Close or Escape cancels work; clicking another window keeps the chat open.");
        self.* = .{ .host = host, .editor = editor, .enabled = enabled, .model = model, .model_license = license, .custom = custom, .read_pages = read_pages, .all = all, .threads = threads, .context = context, .tokens = tokens, .idle = idle, .provider = provider, .provider_names = names, .provider_kind = provider_kind, .provider_name = provider_name, .endpoint = endpoint, .engine_id = engine_id, .language = language, .provider_enabled = provider_enabled, .default_provider = default_provider, .safe = safe, .secret = secret, .session_key = session_key, .status = status, .readiness = readiness, .cancel_button = cancel_button, .runtime_source = runtime_source, .runtime_path = runtime_path, .compute_mode = compute_mode, .backend = backend, .device = device, .device_names = device_names, .fallback = fallback, .layers = layers, .gpu_memory = gpu_memory, .runtime_details = runtime_details, .buttons = .{ download, verify, remove, test_provider, store_key, remove_key, discover, runtime_check, benchmark, setup_runtime }, .model_options = model_options, .runtime_options = runtime_options, .engines_section = engines_section, .resources_section = resources_section, .enable_summary = enable_summary, .runtime_summary = runtime_summary, .model_status = model_status, .runtime_status = runtime_status, .provider_status = provider_status, .provider_editor = provider_editor, .credentials = credentials, .legacy_notice = legacy_notice, .gpu_options = gpu_options, .custom_runtime = custom_runtime, .operation = operation, .comparison_status = comparison_status, .local_cancels = .{ model_cancel, runtime_cancel, provider_cancel } };
        for ([_]*gtk.Switch{ enabled, read_pages, all, provider_enabled, default_provider, safe, fallback }) |s| _ = object.Object.signals.notify.connect(s.as(object.Object), *View, changed, self, .{ .detail = "active" });
        for ([_]*gtk.DropDown{ model, provider_kind, runtime_source, backend }) |s| _ = object.Object.signals.notify.connect(s.as(object.Object), *View, changed, self, .{ .detail = "selected" });
        for (compute_mode.buttons) |b| _ = gtk.CheckButton.signals.toggled.connect(b, *View, computeChanged, self, .{});
        self.compute_mode.connectKeys();
        for ([_]*gtk.Entry{ custom, provider_name, endpoint, engine_id, language, runtime_path }) |e| _ = gtk.Editable.signals.changed.connect(e.as(gtk.Editable), *View, textChanged, self, .{});
        for ([_]*gtk.SpinButton{ threads, context, tokens, idle, layers, gpu_memory }) |s| _ = gtk.SpinButton.signals.value_changed.connect(s, *View, numberChanged, self, .{});
        _ = object.Object.signals.notify.connect(provider.as(object.Object), *View, providerSelected, self, .{ .detail = "selected" });
        _ = gtk.Button.signals.clicked.connect(add, *View, addProvider, self, .{});
        _ = gtk.Button.signals.clicked.connect(remove_provider, *View, removeProvider, self, .{});
        for (self.buttons) |b| _ = gtk.Button.signals.clicked.connect(b, *View, actionClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel_button, *View, cancelClicked, self, .{});
        for (self.local_cancels) |b| _ = gtk.Button.signals.clicked.connect(b, *View, cancelClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(browse, *View, browseClicked, self, .{});
        _ = object.Object.signals.notify.connect(device.as(object.Object), *View, deviceSelected, self, .{ .detail = "selected" });
        self.comparison = try @import("benchmark_view.zig").View.create(comparison_host, editor, self, comparisonAvailable);
        self.timer = glib.timeoutAdd(250, tick, self);
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.dead = true;
        if (self.comparison) |comparison| comparison.destroy();
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.cancel) |cancel| cancel.cancel();
        self.provider_names.unref();
        self.device_names.unref();
        self.device_arena.deinit();
        if (self.picker) |picker| {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
        }
        if (self.apply_dialog) |dialog| {
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        if (self.job == null) a.destroy(self);
    }
    fn document(self: *View, alloc: std.mem.Allocator) !prefs.Preferences {
        try prefs.boundedJson(self.editor.text(), prefs.max_bytes, 24);
        var value = try std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
        // Drafts may be temporarily invalid, so preserve migration without
        // invoking Preferences.validate() and preventing further editing.
        const raw = try std.json.parseFromSliceLeaky(std.json.Value, alloc, self.editor.text(), .{});
        if (raw == .object) if (raw.object.get("assistant")) |assistant| {
            if (assistant == .object and !assistant.object.contains("runtime")) value.assistant.runtime.source = .packaged;
        };
        return value;
    }
    fn commit(self: *View, value: prefs.Preferences, alloc: std.mem.Allocator) !void {
        const text = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
        try self.editor.edit(text);
    }
    fn save(self: *View) void {
        if (self.filling or self.editing or !self.editor.editable()) return;
        self.editing = true;
        defer {
            self.editing = false;
            self.update();
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        var config = &value.assistant;
        config.enabled = self.enabled.getActive() != 0;
        const selected_model = registry.selected(self.model.getSelected());
        const model_changed = !std.mem.eql(u8, config.model_id, selected_model);
        config.model_id = selected_model;
        config.custom_model = std.mem.span(self.custom.as(gtk.Editable).getText());
        config.runtime.source = @enumFromInt(self.runtime_source.getSelected());
        config.runtime.executable = std.mem.span(self.runtime_path.as(gtk.Editable).getText());
        config.compute.mode = @enumFromInt(self.compute_mode.getSelected());
        config.compute.backend = @enumFromInt(self.backend.getSelected());
        config.compute.allow_cpu_fallback = self.fallback.getActive() != 0;
        config.compute.offload_layers = if (self.layers.getValueAsInt() == 0) null else @intCast(self.layers.getValueAsInt());
        config.compute.gpu_memory_target_mib = if (self.gpu_memory.getValueAsInt() == 0) null else @intCast(self.gpu_memory.getValueAsInt());
        config.read_pages = self.read_pages.getActive() != 0;
        config.search_mode = if (self.all.getActive() != 0) .all else .default;
        config.cpu_threads = @intCast(self.threads.getValueAsInt());
        config.context_tokens = if (model_changed) 0 else @intCast(self.context.getValueAsInt());
        config.answer_tokens = if (model_changed) 0 else @intCast(self.tokens.getValueAsInt());
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
        if (model_changed and std.mem.eql(u8, selected_model, "custom")) self.model_options.expander.setExpanded(1);
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
        config.validate() catch |err| switch (err) {
            error.AbsoluteRuntimePathRequired, error.SelectGpuDevice, error.InvalidOffloadLayers, error.InvalidGpuMemoryTarget => self.runtime_options.expander.setExpanded(1),
            error.AbsoluteModelPathRequired, error.UnknownAssistantModel => self.model_options.expander.setExpanded(1),
            error.InvalidAssistantContext, error.InvalidAssistantBudget => self.resources_section.expander.setExpanded(1),
            else => self.engines_section.expander.setExpanded(1),
        };
        const fingerprint = runtimeFingerprint(alloc, config) catch return;
        if (self.checked_fingerprint) |checked| if (checked != fingerprint) {
            self.checked_fingerprint = null;
            self.runtime_details.setText("Not checked for this draft. Check the runtime and model before use.");
        };
        const committed = std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.current orelse self.editor.base orelse "{}", .{}) catch prefs.Preferences{};
        self.enable_summary.setText(if (config.enabled != committed.assistant.enabled)
            (if (config.enabled) "On in draft · Apply & save to enable" else "Off in draft · Apply & save to disable")
        else if (config.enabled) "On · Open with Super + Space" else "Off · Configure the assistant before enabling it");
        const runtime_name = switch (config.runtime.source) {
            .system => "System installation",
            .packaged => "Pearl runtime package",
            .custom => "Custom executable",
        };
        self.runtime_summary.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ runtime_name, if (self.checked_fingerprint != null) "Check details available below" else "Not checked for this draft" }, 0) catch "Not checked for this draft");
        self.custom_runtime.as(gtk.Widget).setVisible(@intFromBool(config.runtime.source == .custom));
        self.gpu_options.as(gtk.Widget).setVisible(@intFromBool(config.compute.mode != .cpu));
        layout.showRow(self.custom.as(gtk.Widget), std.mem.eql(u8, config.model_id, "custom"));
        self.resources_section.summary.setText(std.fmt.allocPrintSentinel(alloc, "{s} · Unload after {d} seconds · Read result pages {s}", .{ if (config.cpu_threads == 0 and config.context_tokens == 0 and config.answer_tokens == 0) @as([]const u8, "Automatic model profile") else "Custom resource settings", config.idle_unload_seconds, if (config.read_pages) "on" else "off" }, 0) catch "Resource settings");
        var engine_count: usize = 0;
        var default_name: []const u8 = "No default engine";
        for (config.providers) |p| {
            if (p.enabled) engine_count += 1;
            if (std.mem.eql(u8, p.id, config.default_provider_id)) default_name = p.name;
        }
        if (self.last_action == null or !providerAction(self.last_action.?)) self.engines_section.summary.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {d} enabled · {s}", .{ default_name, engine_count, if (config.search_mode == .all) "Search all enabled (maximum 3)" else "Default engine only" }, 0) catch "Search engines");
        self.host.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        self.enabled.setActive(@intFromBool(config.enabled));
        self.model.setSelected(registry.selection(config.model_id));
        fill(alloc, self.custom, config.custom_model);
        self.runtime_source.setSelected(@intFromEnum(config.runtime.source));
        fill(alloc, self.runtime_path, config.runtime.executable);
        self.compute_mode.setSelected(@intFromEnum(config.compute.mode));
        self.backend.setSelected(@intFromEnum(config.compute.backend));
        self.fallback.setActive(@intFromBool(config.compute.allow_cpu_fallback));
        self.fallback.as(gtk.Widget).setSensitive(@intFromBool(config.compute.mode == .gpu));
        fillNumber(self.layers, config.compute.offload_layers orelse 0);
        fillNumber(self.gpu_memory, config.compute.gpu_memory_target_mib orelse 0);
        self.device_names.splice(0, self.device_names.as(gio.ListModel).getNItems(), null);
        self.device_names.append("Automatic device selection");
        var selected: u32 = 0;
        for (self.devices, 0..) |d, i| {
            const label = std.fmt.allocPrintSentinel(alloc, "{s} · {s}{s}", .{ d.description, @tagName(d.backend), if (d.ambiguous) " · ambiguous identity" else if (d.shared) " · shared/unknown memory" else "" }, 0) catch continue;
            self.device_names.append(label);
            if (std.mem.eql(u8, config.compute.device_id, d.id)) selected = @intCast(i + 1);
        }
        if (selected == 0 and config.compute.device_id.len > 0) {
            self.device_names.append("Saved device · discover to check availability");
            selected = @intCast(self.devices.len + 1);
        }
        self.device.setSelected(selected);
        self.read_pages.setActive(@intFromBool(config.read_pages));
        self.all.setActive(@intFromBool(config.search_mode == .all));
        fillNumber(self.threads, config.cpu_threads);
        fillNumber(self.context, config.context_tokens);
        fillNumber(self.tokens, config.answer_tokens);
        fillNumber(self.idle, config.idle_unload_seconds);
        const current = @min(self.provider_index, config.providers.len -| 1);
        var names_changed = self.provider_names.as(gio.ListModel).getNItems() != config.providers.len;
        if (!names_changed) for (config.providers, 0..) |p, i| {
            if (!std.mem.eql(u8, std.mem.span(self.provider_names.getString(@intCast(i)).?), p.name)) names_changed = true;
        };
        if (names_changed) {
            self.provider_names.splice(0, self.provider_names.as(gio.ListModel).getNItems(), null);
            for (config.providers) |p| self.provider_names.append(alloc.dupeZ(u8, p.name) catch continue);
        }
        self.provider_index = current;
        self.provider.setSelected(@intCast(current));
        self.provider_editor.as(gtk.Widget).setVisible(@intFromBool(current < config.providers.len));
        if (current < config.providers.len) {
            const p = config.providers[current];
            self.provider_kind.setSelected(@intFromEnum(p.kind));
            fill(alloc, self.provider_name, p.name);
            fill(alloc, self.endpoint, p.endpoint);
            fill(alloc, self.engine_id, p.engine_id);
            fill(alloc, self.language, p.language);
            self.endpoint.as(gtk.Widget).setSensitive(@intFromBool(p.kind == .google or p.kind == .searxng));
            self.engine_id.as(gtk.Widget).setSensitive(@intFromBool(p.kind == .google_legacy));
            const needs_key = p.kind == .brave or p.kind == .google_legacy;
            layout.showRow(self.endpoint.as(gtk.Widget), p.kind == .google or p.kind == .searxng);
            layout.showRow(self.engine_id.as(gtk.Widget), p.kind == .google_legacy);
            self.credentials.as(gtk.Widget).setVisible(@intFromBool(needs_key));
            self.legacy_notice.as(gtk.Widget).setVisible(@intFromBool(p.kind == .google_legacy));
            self.secret.as(gtk.Widget).setSensitive(@intFromBool(needs_key));
            self.session_key.as(gtk.Widget).setSensitive(@intFromBool(needs_key));
            self.provider_enabled.setActive(@intFromBool(p.enabled));
            self.default_provider.setActive(@intFromBool(std.mem.eql(u8, config.default_provider_id, p.id)));
            self.safe.setActive(@intFromBool(p.safe_search));
        }
        if (registry.find(config.model_id)) |model| {
            self.model_license.setUri(model.license_url);
            self.model_license.as(gtk.Widget).setVisible(1);
            const filename = @import("../agent/downloads.zig").path(alloc, model) catch return;
            self.readiness.setText(std.fmt.allocPrintSentinel(alloc, "{s}\nContext: {d} tokens · Generation: {d} tokens{s}", .{ if (std.c.access(filename, std.c.F_OK) == 0) @as([]const u8, "Model downloaded. It is verified again before loading.") else "Model not installed. Download is optional and explicit.", config.contextTokens(), config.answerTokens(), if (model.reasoning) @as([]const u8, " · Includes reasoning") else "" }, 0) catch "Model selected");
        } else {
            self.model_license.as(gtk.Widget).setVisible(0);
            self.readiness.setText("Custom GGUF: verify compatibility before use.");
        }
        const available = self.job == null and (if (self.comparison) |comparison| !comparison.busy() else true);
        for (self.buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(available));
        const needs_key = current < config.providers.len and (config.providers[current].kind == .brave or config.providers[current].kind == .google_legacy);
        self.buttons[@intFromEnum(Action.store_key)].as(gtk.Widget).setSensitive(@intFromBool(available and needs_key));
        self.buttons[@intFromEnum(Action.remove_key)].as(gtk.Widget).setSensitive(@intFromBool(available and needs_key));
        self.feedback();
    }
    fn providerSelected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling) return;
        self.provider_index = self.provider.getSelected();
        self.secret.as(gtk.Editable).setText("");
        self.update();
    }
    fn deviceSelected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.filling or !self.editor.editable()) return;
        const index = self.device.getSelected();
        if (index > self.devices.len) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var value = self.document(arena.allocator()) catch return;
        value.assistant.compute.device_id = if (index == 0) "" else self.devices[index - 1].id;
        self.commit(value, arena.allocator()) catch return;
    }
    fn browseClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.picker != null or !self.editor.editable()) return;
        const parent = object.ext.cast(gtk.Window, self.host.as(gtk.Widget).getRoot().?).?;
        const picker = gtk.FileChooserNative.new("Choose llama-server", parent, .open, "Choose", "Cancel");
        self.picker = picker;
        _ = gtk.NativeDialog.signals.response.connect(picker.as(gtk.NativeDialog), *View, picked, self, .{});
        picker.as(gtk.NativeDialog).show();
    }
    fn picked(_: *gtk.NativeDialog, response: c_int, self: *View) callconv(.c) void {
        const picker = self.picker orelse return;
        self.picker = null;
        defer {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
        }
        if (response != @intFromEnum(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = picker.as(gtk.FileChooser).getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.runtime_path.as(gtk.Editable).setText(path);
        self.runtime_source.setSelected(@intFromEnum(cfg.RuntimeSource.custom));
    }
    pub fn requestApply(self: *View) void {
        self.begin(.apply_status) catch |err| self.status.setText(@errorName(err));
    }
    pub fn diagnostic(self: *View) struct { busy: bool, devices: usize, runtime: []const u8, status: []const u8, apply_prompt: bool } {
        return .{ .busy = self.job != null, .devices = self.devices.len, .runtime = std.mem.span(self.runtime_details.getText()), .status = std.mem.span(self.status.getText()), .apply_prompt = self.apply_dialog != null };
    }
    fn confirmApply(self: *View) void {
        if (self.apply_dialog != null) return;
        const dialog = gtk.Dialog.new();
        _ = dialog.ref();
        self.apply_dialog = dialog;
        dialog.as(gtk.Window).setTransientFor(object.ext.cast(gtk.Window, self.host.as(gtk.Widget).getRoot().?).?);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setTitle("Stop the current answer?");
        note(dialog.getContentArea(), "Applying these settings stops the current answer and unloads its model. Your conversation stays available.");
        _ = dialog.addButton("Keep editing", @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton("Stop & apply", @intFromEnum(gtk.ResponseType.accept));
        _ = gtk.Dialog.signals.response.connect(dialog, *View, applyResponse, self, .{});
        dialog.as(gtk.Window).present();
    }
    fn applyResponse(dialog: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        self.apply_dialog = null;
        dialog.as(gtk.Window).destroy();
        dialog.unref();
        if (response == @intFromEnum(gtk.ResponseType.accept)) self.begin(.apply_stop) catch |err| self.status.setText(@errorName(err));
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
            if (i == @intFromEnum(Action.benchmark)) {
                if (self.comparison) |comparison| {
                    comparison.mode.setSelected(2);
                    comparison.expander.setExpanded(1);
                    _ = comparison.expander.as(gtk.Widget).grabFocus();
                }
                return;
            }
            self.begin(@enumFromInt(i)) catch |err| {
                self.status.setText(@errorName(err));
                self.revealOperation();
            };
            return;
        };
    }
    fn begin(self: *View, action: Action) !void {
        self.last_action = action;
        if (self.comparison) |comparison| if (comparison.busy()) return error.OperationInProgress;
        if (self.job != null) return error.OperationInProgress;
        if (!self.editor.editable()) return error.SettingsUnavailable;
        if (action == .verify or action == .runtime_check or action == .discover or action == .setup_runtime) self.checked_fingerprint = null;
        const job = try a.create(Job);
        job.* = .{ .view = self, .action = action, .config = undefined, .provider = .{}, .secret = undefined, .session_only = self.session_key.getActive() != 0 };
        errdefer {
            job.arena.deinit();
            a.destroy(job);
        }
        const alloc = job.arena.allocator();
        job.config = (try self.document(alloc)).assistant;
        if (action == .discover or action == .setup_runtime) {
            var checking = job.config;
            checking.compute.mode = .cpu;
            if (action == .setup_runtime) checking.runtime = .{};
            try checking.validate();
        } else try job.config.validate();
        if (action == .remove and (job.config.enabled or self.editor.state.dirty)) return error.ApplyAssistantDisabledBeforeRemovingModel;
        if (self.provider_index < job.config.providers.len) job.provider = job.config.providers[self.provider_index] else if (action == .test_provider or action == .store_key or action == .remove_key) return error.SearchProviderRequired;
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
        self.status.setText(if (action == .setup_runtime) "Checking installed runtimes… If installation is needed, complete the package manager prompts in the terminal. Setup continues until the terminal exits." else "Working…");
        self.update();
    }
    fn comparisonAvailable(context: *anyopaque) bool {
        const self: *View = @ptrCast(@alignCast(context));
        return !self.dead and self.job == null;
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
            .setup_runtime => {
                _ = try @import("../agent/control.zig").command(alloc, "release", cancel);
                const setup = try @import("../agent/runtime_install.zig").ensure(alloc, job.config, cancel);
                job.selected_runtime = setup.runtime;
                job.devices = setup.info.devices;
                job.details = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s} · {d} GPU device(s). Check runtime and model now to verify the selected model. GPU execution requires a detected device and working driver.", .{ setup.info.executable, setup.info.version, if (setup.installed) "Runtime installed and capabilities checked" else "Using compatible installed runtime", setup.info.devices.len });
            },
            .download => try @import("../agent/downloads.zig").install(registry.find(job.config.model_id) orelse return error.SelectDownloadableModel, cancel, &job.progress),
            .remove => try @import("../agent/downloads.zig").remove(registry.find(job.config.model_id) orelse return error.CustomModelNotManaged),
            .discover => {
                const info = try @import("../agent/runtime_probe.zig").inspect(alloc, job.config.runtime, true, cancel);
                job.devices = info.devices;
                job.details = try std.fmt.allocPrint(alloc, "{s}\n{s}\nRuntime found · {d} GPU device(s) · model test required", .{ info.executable, info.version, info.devices.len });
            },
            .apply_status => job.busy = (try @import("../agent/control.zig").command(alloc, "status", cancel)).busy,
            .apply_stop => {
                _ = try @import("../agent/control.zig").command(alloc, "cancel", cancel);
            },
            .benchmark => return error.UseModelComparison,
            .verify, .runtime_check => {
                _ = try @import("../agent/control.zig").command(alloc, "release", cancel);
                var runtime: @import("../agent/runtime.zig").Runtime = .{};
                defer runtime.stop();
                // Let the shell deliver its idle-release command. The runtime's
                // exclusive lock is authoritative if a concurrent answer wins.
                for (0..20) |i| {
                    runtime.ensure(job.config, cancel) catch |err| {
                        if (err != error.AssistantRuntimeBusy or i == 19) return err;
                        glib.usleep(50000);
                        continue;
                    };
                    break;
                }
                job.details = try std.fmt.allocPrint(alloc, "{s}\n{s}\nCompatible · {s}\n{s}", .{ runtime.executable, runtime.version, if (runtime.gpu) "GPU offload verified" else "CPU", runtime.fallback_reason });
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
        if (job.failure == null) {
            if (job.selected_runtime) |runtime| {
                // Preserve edits made while the package manager was open.
                // Only adopt setup's selection if that selection is unchanged.
                const alloc = job.arena.allocator();
                if (self.document(alloc)) |value_| {
                    var value = value_;
                    const unchanged = value.assistant.runtime.source == job.config.runtime.source and std.mem.eql(u8, value.assistant.runtime.executable, job.config.runtime.executable);
                    const different = value.assistant.runtime.source != runtime.source or !std.mem.eql(u8, value.assistant.runtime.executable, runtime.executable);
                    if (unchanged and different) {
                        value.assistant.runtime = runtime;
                        self.commit(value, alloc) catch |err| {
                            job.failure = err;
                        };
                        if (job.failure == null) job.config.runtime = runtime;
                    }
                } else |err| job.failure = err;
            }
            if (job.action == .discover or job.action == .setup_runtime) {
                self.device_arena.deinit();
                self.device_arena = .init(a);
                const alloc = self.device_arena.allocator();
                self.devices = std.json.parseFromSliceLeaky([]const @import("../agent/compute.zig").Device, alloc, std.json.Stringify.valueAlloc(alloc, job.devices, .{}) catch "[]", .{}) catch &.{};
            }
            if (job.details.len > 0) {
                const alloc = job.arena.allocator();
                const current = self.document(alloc) catch null;
                const tested_json = std.json.Stringify.valueAlloc(alloc, job.config, .{}) catch "";
                const current_json = if (current) |value| std.json.Stringify.valueAlloc(alloc, value.assistant, .{}) catch "" else "invalid";
                self.runtime_details.setText(if (std.mem.eql(u8, tested_json, current_json)) alloc.dupeZ(u8, job.details) catch "Check completed" else "The tested draft has changed. Check the new selection before use.");
                self.checked_fingerprint = runtimeFingerprint(alloc, job.config) catch null;
            }
            if (job.action == .apply_status) {
                if (job.busy) self.confirmApply() else self.editor.act(.apply);
            } else if (job.action == .apply_stop) self.editor.act(.apply);
        }
        self.status.setText(if (job.failure) |err| switch (err) {
            error.AssistantRuntimeNotInstalled => "Runtime missing. Use Set up runtime (install if needed).",
            error.RuntimeInstallationUnsupportedDistribution => "Automatic installation supports Devario and Arch-based systems. Install llama.cpp with your distribution's package manager, then discover the runtime.",
            error.RuntimePackageManagerUnavailable => "Package manager unavailable. Devario requires /usr/bin/shelly; Arch requires /usr/bin/pacman and /usr/bin/sudo.",
            error.RuntimeInstallTerminalUnavailable => "Setup needs a terminal: foot, Ghostty, kitty, alacritty, konsole or xterm. Install one and retry.",
            error.RuntimePackageInstallationFailed => "Installation failed or was cancelled. Check the package manager's repository, network or database-lock error, then retry Set up runtime. No repository was added or version pinned.",
            error.RuntimeCapabilityMissing => "This runtime lacks required capabilities. Use Set up runtime to install the repository version. If it still fails, your repository needs a compatible llama.cpp update.",
            error.RuntimeReasoningUnsupported => "This thinking model needs a runtime with reasoning-format support. Update llama.cpp or choose an Instruct model.",
            else => @errorName(err),
        } else "Operation complete. Apply saves your configuration selection.");
        if (job.failure != null and (job.action == .runtime_check or job.action == .verify or job.action == .discover or job.action == .setup_runtime)) self.runtime_details.setText("Compatibility not confirmed. Review the operation error and retry setup or the runtime check.");
        if (providerAction(job.action)) {
            const message = std.fmt.allocPrintSentinel(job.arena.allocator(), "{s}: {s}", .{ job.provider.name, std.mem.span(self.status.getText()) }, 0) catch "Engine operation finished";
            self.status.setText(message);
        }
        if (job.failure != null) self.revealOperation();
        self.update();
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.cancel) |cancel| cancel.cancel();
        if (self.comparison) |comparison| if (comparison.cancel) |cancel| cancel.cancel();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (self.job) |job| if (job.action == .download) {
            var buffer: [96]u8 = undefined;
            const text = std.fmt.bufPrintZ(&buffer, "Downloaded {d} MB…", .{job.progress.load(.monotonic) / 1000000}) catch return 1;
            self.status.setText(text);
        };
        if (!self.editor.editable()) if (self.cancel) |cancel| cancel.cancel();
        self.feedback();
        return 1;
    }
    fn computeChanged(button_: *gtk.CheckButton, self: *View) callconv(.c) void {
        if (button_.getActive() != 0) self.save();
    }
    fn revealOperation(self: *View) void {
        const action = self.last_action orelse return;
        if (providerAction(action)) self.engines_section.expander.setExpanded(1) else switch (action) {
            .download, .remove => self.model_options.expander.setExpanded(1),
            .verify, .runtime_check, .discover, .setup_runtime => self.runtime_options.expander.setExpanded(1),
            else => {},
        }
    }
    fn feedback(self: *View) void {
        const text = self.status.getText();
        const comparing = if (self.comparison) |comparison| comparison.busy() else false;
        if (comparing) self.comparison_status.setText(self.comparison.?.status.getText());
        self.comparison_status.as(gtk.Widget).setVisible(@intFromBool(comparing));
        self.status.as(gtk.Widget).setVisible(@intFromBool(!comparing));
        self.operation.as(gtk.Widget).setVisible(@intFromBool(text[0] != 0 or comparing));
        const cancellable = if (self.job) |job| job.action != .setup_runtime else comparing;
        self.cancel_button.as(gtk.Widget).setVisible(@intFromBool(cancellable));
        self.cancel_button.as(gtk.Widget).setSensitive(@intFromBool(cancellable));
        for (self.local_cancels, 0..) |b, i| {
            const active = if (self.job) |job| job.action != .setup_runtime and i == operationSection(job.action) else false;
            b.as(gtk.Widget).setVisible(@intFromBool(active));
            b.as(gtk.Widget).setSensitive(@intFromBool(active));
        }
        if (self.last_action) |action| {
            const local = if (providerAction(action)) self.provider_status else switch (action) {
                .download, .verify, .remove => self.model_status,
                else => self.runtime_status,
            };
            if (!std.mem.eql(u8, std.mem.span(local.getText()), std.mem.span(text))) local.setText(text);
            if (providerAction(action)) self.engines_section.summary.setText(text) else if (action == .runtime_check or action == .discover or action == .setup_runtime) self.runtime_options.summary.setText(text);
        }
        for ([_]*gtk.Label{ self.model_status, self.runtime_status, self.provider_status }) |label| label.as(gtk.Widget).setVisible(@intFromBool(label.getText()[0] != 0));
        const available = self.job == null and !comparing;
        for (self.buttons, 0..) |b, i| {
            if (i == @intFromEnum(Action.store_key) or i == @intFromEnum(Action.remove_key)) continue;
            b.as(gtk.Widget).setSensitive(@intFromBool(available));
        }
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
    return layout.card(host, title);
}
fn note(host: *gtk.Box, text: [:0]const u8) void {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    host.append(l.as(gtk.Widget));
}
fn formRow(host: *gtk.Box, title: [:0]const u8, widget: *gtk.Widget) void {
    layout.row(host, title, widget);
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
    e.as(gtk.Editable).setWidthChars(14);
    e.as(gtk.Editable).setMaxWidthChars(22);
    formRow(host, title, e.as(gtk.Widget));
    return e;
}
fn choice(host: *gtk.Box, title: [:0]const u8, names: []const [:0]const u8) *gtk.DropDown {
    var list: [8]?[*:0]const u8 = @splat(null);
    for (names, 0..) |name, i| list[i] = name;
    const d = gtk.DropDown.newFromStrings(@ptrCast(&list));
    layout.wrapChoice(d);
    if (std.mem.eql(u8, title, "Selected model")) {
        w.name(d.as(gtk.Widget), title);
        host.append(d.as(gtk.Widget));
    } else formRow(host, title, d.as(gtk.Widget));
    return d;
}
fn number(host: *gtk.Box, title: [:0]const u8, min: f64, max: f64, step: f64) *gtk.SpinButton {
    const s = gtk.SpinButton.newWithRange(min, max, step);
    formRow(host, title, s.as(gtk.Widget));
    return s;
}
fn fillNumber(spin: *gtk.SpinButton, value: u32) void {
    // Setting even the same value replaces text that has not yet been committed
    // by Return or focus loss. Editor status refreshes must preserve that input.
    if (spin.getValueAsInt() != value) spin.setValue(@floatFromInt(value));
}
fn button(host: *gtk.Box, title: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(title);
    b.as(gtk.Widget).addCssClass("settings-value");
    b.as(gtk.Widget).setHalign(.start);
    host.append(b.as(gtk.Widget));
    return b;
}
fn fill(alloc: std.mem.Allocator, e: *gtk.Entry, text: []const u8) void {
    if (e.as(gtk.Widget).hasFocus() != 0 or e.as(gtk.Widget).getFocusChild() != null) return;
    if (!std.mem.eql(u8, std.mem.span(e.as(gtk.Editable).getText()), text)) e.as(gtk.Editable).setText(alloc.dupeZ(u8, text) catch return);
}
fn statusLabel(host: *gtk.Box) *gtk.Label {
    const label = w.label("", "pearl-secondary");
    label.setSelectable(1);
    host.append(label.as(gtk.Widget));
    return label;
}
fn providerAction(action: Action) bool {
    return action == .test_provider or action == .store_key or action == .remove_key;
}
fn operationSection(action: Action) usize {
    return if (providerAction(action)) 2 else switch (action) {
        .download, .verify, .remove => 0,
        else => 1,
    };
}
fn runtimeFingerprint(alloc: std.mem.Allocator, config: cfg.Config) !u64 {
    const text = try std.json.Stringify.valueAlloc(alloc, .{ config.model_id, config.custom_model, config.runtime, config.compute, config.cpu_threads, config.context_tokens, config.answer_tokens }, .{});
    return std.hash.Wyhash.hash(0, text);
}
