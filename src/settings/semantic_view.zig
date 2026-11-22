//! Opt-in semantic search section of the Assistant page. Draft settings follow
//! the shared editor; model downloads run in-process like chat models; index
//! operations go to the verified shell through pearlctl, which owns the index.
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
const downloads = @import("../agent/downloads.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Action = enum { download, verify, remove, index, stop, delete, setup, status };
const Job = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    action: Action,
    config: cfg.Config,
    progress: std.atomic.Value(u64) = .init(0),
    phase: std.atomic.Value(u8) = .init(0),
    failure: ?anyerror = null,
    details: [:0]const u8 = "",
    snapshot: ?Snapshot = null,
};
const Snapshot = struct {
    state: []const u8 = "disabled",
    files: u64 = 0,
    chunks: u64 = 0,
    folders: u64 = 0,
    model_installed: bool = false,
    pdf_available: bool = false,
    error_code: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    indexed: u64 = 0,
    skipped: u64 = 0,
    pending: []const u8 = "none",
    dirty: u64 = 0,
    defer_reason: []const u8 = "",
    degraded: bool = false,
    background: []const u8 = "idle_low_use",
    automatic: bool = false,
};
const Row = struct { view: *View, index: usize };
pub const View = struct {
    editor: *Editor,
    owner: *anyopaque,
    owner_idle: *const fn (*anyopaque) bool,
    expander: *gtk.Expander,
    summary: *gtk.Label,
    host: *gtk.Box,
    enabled: *gtk.Switch,
    background: *gtk.DropDown,
    model: *gtk.DropDown,
    license: *gtk.LinkButton,
    readiness: *gtk.Label,
    folders_box: *gtk.Box,
    index_status: *gtk.Label,
    status: *gtk.Label,
    cancel_button: *gtk.Button,
    buttons: [7]*gtk.Button = undefined,
    job: ?*Job = null,
    cancel: ?*gio.Cancellable = null,
    timer: c_uint = 0,
    picker: ?*gtk.FileChooserNative = null,
    dead: bool = false,
    filling: bool = false,
    editing: bool = false,
    rows: std.ArrayList(*Row) = .empty,
    shown_folders: std.ArrayList([]const u8) = .empty,
    data: std.heap.ArenaAllocator = .init(a),
    last_status: std.ArrayList(u8) = .empty,

    pub fn create(host: *gtk.Box, editor: *Editor, owner: *anyopaque, owner_idle: *const fn (*anyopaque) bool) !*View {
        const self = try a.create(View);
        const section = layout.Section.create(host, "Semantic search", "Find documents by description, entirely on this device");
        const body = section.body;
        const enabled = gtk.Switch.new();
        enabled.as(gtk.Widget).setHalign(.start);
        layout.row(body, @import("i18n").dtr("pearl", "Enable semantic search"), enabled.as(gtk.Widget));
        _ = label(body, @import("i18n").dtr("pearl", "Turning this on sets up llama.cpp if needed (a terminal opens for package-manager confirmation) and downloads the embedding model. Setup is immediate and survives Discard. Indexing and search run on this device; nothing is uploaded."));
        const background_labels = [_:null]?[*:0]const u8{ @import("i18n").dtr("pearl", "Idle or low use"), @import("i18n").dtr("pearl", "Idle only"), @import("i18n").dtr("pearl", "Manual only") };
        const background = gtk.DropDown.newFromStrings(@ptrCast(&background_labels));
        layout.wrapChoice(background);
        layout.row(body, @import("i18n").dtr("pearl", "Background indexing"), background.as(gtk.Widget));
        _ = label(body, @import("i18n").dtr("pearl", "Automatic passes run in short bursts when the computer is idle or in low use, and pause when you return. On battery they wait for idle while charging or above 50%. Index now always runs immediately."));
        var model_labels: [registry.embedding_models.len + 1:null]?[*:0]const u8 = @splat(null);
        for (registry.embedding_models, 0..) |item, i| model_labels[i] = item.name;
        const model = gtk.DropDown.newFromStrings(@ptrCast(&model_labels));
        layout.wrapChoice(model);
        layout.row(body, @import("i18n").dtr("pearl", "Embedding model"), model.as(gtk.Widget));
        const license = gtk.LinkButton.newWithLabel(registry.embedding_models[0].license_url, @import("i18n").dtr("pearl", "Embedding model license"));
        license.as(gtk.Widget).setHalign(.start);
        body.append(license.as(gtk.Widget));
        const readiness = label(body, "");
        const model_actions = layout.actions(body);
        const download = layout.button(model_actions, @import("i18n").dtr("pearl", "Download embedding model"));
        const verify = layout.button(model_actions, @import("i18n").dtr("pearl", "Verify embedding model"));
        const remove = layout.button(model_actions, @import("i18n").dtr("pearl", "Remove embedding download"));
        const setup = layout.button(model_actions, @import("i18n").dtr("pearl", "Set up now (runtime and model)"));
        const folders_card = layout.card(body, @import("i18n").dtr("pearl", "Indexed folders"));
        _ = label(folders_card, @import("i18n").dtr("pearl", "Nothing is indexed until you add a folder. The first index pass starts automatically once enabling is saved; Index now re-runs it. Hidden files, symlinks and common cache directories are skipped."));
        const folders_box = w.column(6);
        folders_card.append(folders_box.as(gtk.Widget));
        const add_folder = button(folders_card, @import("i18n").dtr("pearl", "Add folder…"));
        const index_actions = layout.actions(body);
        const index = layout.button(index_actions, @import("i18n").dtr("pearl", "Index now"));
        const stop = layout.button(index_actions, @import("i18n").dtr("pearl", "Stop indexing"));
        const delete = layout.button(index_actions, @import("i18n").dtr("pearl", "Delete index"));
        const index_status = label(body, @import("i18n").dtr("pearl", "Index status is available while Pearl is running."));
        index_status.setWrap(1);
        const status = label(body, "");
        const cancel_button = button(body, @import("i18n").dtr("pearl", "Cancel semantic operation"));
        cancel_button.as(gtk.Widget).setVisible(0);
        _ = label(body, @import("i18n").dtr("pearl", "Semantic search uses the runtime and acceleration selected above. PDF indexing requires Poppler (pdftotext); text documents work without it. The index stays in your user data directory and is never exported."));
        self.* = .{
            .editor = editor,
            .owner = owner,
            .owner_idle = owner_idle,
            .expander = section.expander,
            .summary = section.summary,
            .host = body,
            .enabled = enabled,
            .background = background,
            .model = model,
            .license = license,
            .readiness = readiness,
            .folders_box = folders_box,
            .index_status = index_status,
            .status = status,
            .cancel_button = cancel_button,
            .buttons = .{ download, verify, remove, index, stop, delete, setup },
        };
        _ = object.Object.signals.notify.connect(enabled.as(object.Object), *View, changed, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(background.as(object.Object), *View, changed, self, .{ .detail = "selected" });
        _ = object.Object.signals.notify.connect(model.as(object.Object), *View, changed, self, .{ .detail = "selected" });
        for (self.buttons) |b| _ = gtk.Button.signals.clicked.connect(b, *View, actionClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(add_folder, *View, addFolder, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel_button, *View, cancelClicked, self, .{});
        self.timer = glib.timeoutAdd(1000, tick, self);
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.dead = true;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        if (self.cancel) |cancel| cancel.cancel();
        if (self.picker) |picker| {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
            self.picker = null;
        }
        self.clearRows();
        self.rows.deinit(a);
        self.shown_folders.deinit(a);
        self.data.deinit();
        self.last_status.deinit(a);
        if (self.job == null) a.destroy(self);
    }
    fn clearRows(self: *View) void {
        for (self.rows.items) |row| a.destroy(row);
        self.rows.clearRetainingCapacity();
        while (self.folders_box.as(gtk.Widget).getFirstChild()) |child| self.folders_box.remove(child);
    }
    fn document(self: *View, alloc: std.mem.Allocator) !prefs.Preferences {
        try prefs.boundedJson(self.editor.text(), prefs.max_bytes, 24);
        var value = try std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
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
        const was_enabled = value.assistant.semantic.enabled;
        value.assistant.semantic.enabled = self.enabled.getActive() != 0;
        value.assistant.semantic.background = @fromBackingInt(@intCast(self.background.getSelected()));
        const selected = self.model.getSelected();
        if (selected < registry.embedding_models.len) value.assistant.semantic.model_id = registry.embedding_models[selected].id;
        self.commit(value, alloc) catch |err| self.editor.error_code.set(@errorName(err));
        // Enabling is the consent moment: set up the runtime and model now,
        // as immediate operations independent of Apply/Discard.
        if (!was_enabled and value.assistant.semantic.enabled) {
            self.begin(.setup) catch |err| self.status.setText(@errorName(err));
        }
    }
    pub fn update(self: *View) void {
        if (self.dead or self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value = self.document(alloc) catch return;
        const semantic = value.assistant.semantic;
        self.enabled.setActive(@intFromBool(semantic.enabled));
        self.background.setSelected(@backingInt(semantic.background));
        var selected: u32 = 0;
        for (registry.embedding_models, 0..) |model, i| {
            if (std.mem.eql(u8, model.id, semantic.model_id)) selected = @intCast(i);
        }
        self.model.setSelected(selected);
        const model = registry.embedding_models[selected];
        self.license.setUri(model.license_url);
        const filename = downloads.path(alloc, model) catch return;
        self.readiness.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {d} MB · {s}", .{ model.name, model.bytes / 1000000, if (std.c.access(filename, std.c.F_OK) == 0) @as([]const u8, "downloaded; verified again before loading") else "not installed; download is explicit" }, 0) catch "Embedding model");
        var folders_changed = self.shown_folders.items.len != semantic.folders.len;
        if (!folders_changed) for (semantic.folders, 0..) |folder, i| {
            if (!std.mem.eql(u8, self.shown_folders.items[i], folder)) folders_changed = true;
        };
        if (folders_changed) {
            self.clearRows();
            self.shown_folders.clearRetainingCapacity();
            self.data.deinit();
            self.data = .init(a);
            const data_alloc = self.data.allocator();
            for (semantic.folders, 0..) |folder, i| {
                self.shown_folders.append(a, data_alloc.dupe(u8, folder) catch continue) catch continue;
                const row = w.row(8);
                const text = gtk.Label.new(data_alloc.dupeSentinel(u8, folder, 0) catch continue);
                text.setXalign(0);
                text.as(gtk.Widget).setHexpand(1);
                text.setEllipsize(.middle);
                row.append(text.as(gtk.Widget));
                const remove_button = w.wrappingButton(@import("i18n").dtr("pearl", "Remove"));
                const row_data = a.create(Row) catch continue;
                row_data.* = .{ .view = self, .index = i };
                self.rows.append(a, row_data) catch {
                    a.destroy(row_data);
                    continue;
                };
                _ = gtk.Button.signals.clicked.connect(remove_button, *Row, folderRemove, row_data, .{});
                row.append(remove_button.as(gtk.Widget));
                self.folders_box.append(row.as(gtk.Widget));
            }
        }
        self.summary.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {d} folder(s)", .{ if (semantic.enabled) @as([]const u8, "On in draft") else "Off", semantic.folders.len }, 0) catch "Semantic search");
        self.host.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        const available = self.job == null and self.owner_idle(self.owner);
        for (self.buttons) |b| b.as(gtk.Widget).setSensitive(@intFromBool(available));
        // The package transaction owns its terminal and cannot be cancelled;
        // the model download phase can.
        const cancellable = self.job != null and self.job.?.action != .status and !(self.job.?.action == .setup and self.job.?.phase.load(.monotonic) == 0);
        self.cancel_button.as(gtk.Widget).setVisible(@intFromBool(cancellable));
        self.cancel_button.as(gtk.Widget).setSensitive(@intFromBool(cancellable));
    }
    fn folderRemove(_: *gtk.Button, row: *Row) callconv(.c) void {
        const self = row.view;
        if (self.dead or !self.editor.editable()) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.semantic.folders;
        if (row.index >= old.len) return;
        const list = alloc.alloc([]const u8, old.len - 1) catch return;
        @memcpy(list[0..row.index], old[0..row.index]);
        @memcpy(list[row.index..], old[row.index + 1 ..]);
        value.assistant.semantic.folders = list;
        self.commit(value, alloc) catch return;
        self.update();
    }
    fn addFolder(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.picker != null or !self.editor.editable()) return;
        const parent = object.ext.cast(gtk.Window, self.host.as(gtk.Widget).getRoot().?).?;
        const picker = gtk.FileChooserNative.new(@import("i18n").dtr("pearl", "Choose a folder to index"), parent, .select_folder, @import("i18n").dtr("pearl", "Choose"), @import("i18n").dtr("pearl", "Cancel"));
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
        if (response != @backingInt(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = picker.as(gtk.FileChooser).getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.semantic.folders;
        if (old.len >= 16) {
            self.status.setText(@import("i18n").dtr("pearl", "At most 16 folders can be indexed."));
            return;
        }
        const folder = std.mem.span(path);
        for (old) |existing| if (std.mem.eql(u8, existing, folder)) return;
        const list = alloc.alloc([]const u8, old.len + 1) catch return;
        @memcpy(list[0..old.len], old);
        list[old.len] = alloc.dupe(u8, folder) catch return;
        value.assistant.semantic.folders = list;
        self.commit(value, alloc) catch return;
        self.update();
    }
    fn actionClicked(button_: *gtk.Button, self: *View) callconv(.c) void {
        for (self.buttons, 0..) |b, i| if (button_ == b) {
            self.begin(@fromBackingInt(@intCast(i))) catch |err| self.status.setText(@errorName(err));
            return;
        };
    }
    fn begin(self: *View, action: Action) !void {
        if (self.job != null) return error.OperationInProgress;
        if (!self.editor.editable()) return error.SettingsUnavailable;
        if (!self.owner_idle(self.owner)) return error.OperationInProgress;
        const job = try a.create(Job);
        job.* = .{ .action = action, .config = undefined };
        errdefer {
            job.arena.deinit();
            a.destroy(job);
        }
        const alloc = job.arena.allocator();
        job.config = (try self.document(alloc)).assistant;
        try job.config.semantic.validate();
        if (action == .remove and (job.config.semantic.enabled or self.editor.state.dirty)) return error.DisableSemanticSearchBeforeRemovingModel;
        if (action == .download or action == .verify or action == .remove) {
            if (registry.findEmbedding(job.config.semantic.model_id) == null) return error.SelectEmbeddingModel;
        }
        self.cancel = gio.Cancellable.new();
        self.job = job;
        if (gio.Application.getDefault()) |app| app.hold();
        const task = gio.Task.new(null, self.cancel, done, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
        self.status.setText(if (action == .setup) @import("i18n").dtr("pearl", "Setting up semantic search… If llama.cpp must be installed, complete the package manager prompts in the terminal; setup continues until the terminal exits.") else @import("i18n").dtr("pearl", "Working…"));
        self.update();
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
        switch (job.action) {
            .download => {
                const model = registry.findEmbedding(job.config.semantic.model_id) orelse return error.SelectEmbeddingModel;
                try downloads.install(model, cancel, &job.progress);
                job.details = try std.fmt.allocPrintSentinel(alloc, "Downloaded and verified {s}", .{model.name}, 0);
            },
            .verify => {
                const model = registry.findEmbedding(job.config.semantic.model_id) orelse return error.SelectEmbeddingModel;
                const filename = try downloads.path(alloc, model);
                _ = try downloads.verify(filename, model, cancel);
                job.details = try std.fmt.allocPrintSentinel(alloc, "Verified {s} · SHA256 matches the pinned revision", .{model.name}, 0);
            },
            .remove => {
                const model = registry.findEmbedding(job.config.semantic.model_id) orelse return error.SelectEmbeddingModel;
                try downloads.remove(model);
                job.details = try std.fmt.allocPrintSentinel(alloc, "Removed {s}", .{model.name}, 0);
            },
            .index => {
                _ = try ctl(alloc, "index", cancel);
                job.details = "Indexing started in Pearl. Progress appears below.";
            },
            .stop => {
                _ = try ctl(alloc, "stop", cancel);
                job.details = "Stop requested.";
            },
            .delete => {
                _ = try ctl(alloc, "delete", cancel);
                job.details = "Index deleted. Run Index now to rebuild it.";
            },
            .setup => {
                job.phase.store(0, .monotonic);
                const setup = try @import("../agent/runtime_install.zig").ensureEmbedding(alloc, job.config, cancel);
                job.phase.store(1, .monotonic);
                const model = registry.findEmbedding(job.config.semantic.model_id) orelse return error.SelectEmbeddingModel;
                const path = try downloads.path(alloc, model);
                if (std.c.access(path, std.c.F_OK) != 0) {
                    try downloads.install(model, cancel, &job.progress);
                }
                job.details = try std.fmt.allocPrintSentinel(alloc, "Semantic search is set up · {s}{s}", .{ model.name, if (setup.installed) @as([]const u8, " · runtime installed") else " · runtime reused" }, 0);
            },
            .status => {
                const stdout = try ctl(alloc, "status", cancel);
                const reply = try std.json.parseFromSliceLeaky(struct { ok: bool, result: ?Snapshot = null }, alloc, stdout, .{ .ignore_unknown_fields = true });
                if (!reply.ok) return error.SemanticControlUnavailable;
                job.snapshot = reply.result;
            },
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
        if (job.action == .status) {
            if (job.snapshot) |snapshot| self.showStatus(snapshot) else self.index_status.setText(@import("i18n").dtr("pearl", "Pearl is not running. Start Pearl to index and search."));
            self.update();
            return;
        }
        self.status.setText(if (job.failure) |err| switch (err) {
            error.SemanticControlUnavailable => @import("i18n").dtr("pearl", "Pearl must be running to control the index. Start Pearl and retry."),
            error.ModelNotInstalled => @import("i18n").dtr("pearl", "Download the embedding model first."),
            error.NoSemanticFolders => @import("i18n").dtr("pearl", "Add at least one folder before indexing."),
            error.IndexBusy => @import("i18n").dtr("pearl", "Indexing is already running. Stop it first."),
            error.DisableSemanticSearchBeforeRemovingModel => @import("i18n").dtr("pearl", "Disable semantic search and Apply before removing its model."),
            error.RuntimeEmbeddingUnsupported => @import("i18n").dtr("pearl", "This llama-server build does not support embeddings. Update the runtime in Runtime & acceleration."),
            error.NotAnEmbeddingModel => @import("i18n").dtr("pearl", "The selected file is not an EmbeddingGemma 2 text backbone."),
            error.AssistantRuntimeNotInstalled => @import("i18n").dtr("pearl", "Runtime missing after setup. Use Set up runtime in Runtime & acceleration, then retry."),
            error.RuntimeInstallationUnsupportedDistribution => @import("i18n").dtr("pearl", "Automatic installation supports Devario and Arch-based systems. Install llama.cpp with your distribution's package manager, then retry Set up now."),
            error.RuntimePackageManagerUnavailable => @import("i18n").dtr("pearl", "Package manager unavailable. Devario requires /usr/bin/shelly; Arch requires /usr/bin/pacman and /usr/bin/sudo."),
            error.RuntimeInstallTerminalUnavailable => @import("i18n").dtr("pearl", "Setup needs a terminal: foot, Ghostty, kitty, alacritty, konsole or xterm. Install one and retry."),
            error.RuntimePackageInstallationFailed => @import("i18n").dtr("pearl", "Installation failed or was cancelled. Check the package manager's repository, network or database-lock error, then retry Set up now."),
            else => @errorName(err),
        } else job.details);
        if (job.action == .setup and job.failure == null) {
            // If enabling was already saved, start the first index pass now;
            // otherwise the shell starts it when Apply delivers the preference.
            const alloc = job.arena.allocator();
            const committed = std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.current orelse self.editor.base orelse "{}", .{}) catch null;
            const draft_enabled = self.enabled.getActive() != 0;
            if (committed) |c| {
                if (draft_enabled and c.assistant.semantic.enabled and c.assistant.semantic.folders.len > 0) {
                    self.begin(.index) catch |err| self.status.setText(@errorName(err));
                } else if (draft_enabled) {
                    self.status.setText(@import("i18n").dtr("pearl", "Setup complete. Apply & save to start indexing."));
                }
            }
        }
        self.update();
    }
    fn showStatus(self: *View, snapshot: Snapshot) void {
        var buffer: [640]u8 = undefined;
        var pending_buffer: [192]u8 = undefined;
        const pdf_note: []const u8 = if (!snapshot.pdf_available) " · PDF indexing requires Poppler (pdftotext)" else "";
        const degraded_note: []const u8 = if (snapshot.degraded) " · degraded watching; periodic rescans cover changes" else "";
        const busy = std.mem.eql(u8, snapshot.state, "indexing") or std.mem.eql(u8, snapshot.state, "paused");
        const pending_note: []const u8 = if (busy or std.mem.eql(u8, snapshot.pending, "none"))
            ""
        else if (std.mem.eql(u8, snapshot.background, "manual"))
            " · Manual only: run Index now"
        else
            std.mem.printSentinel(&pending_buffer, " · {d} changes pending · waiting for {s}", .{ snapshot.dirty, reasonText(snapshot.defer_reason) }, 0) catch "";
        const text: []const u8 = if (busy)
            std.mem.printSentinel(&buffer, "{s} {d}/{d} files · {d} indexed · {d} skipped{s}{s}", .{ if (std.mem.eql(u8, snapshot.state, "paused")) @as([]const u8, "Paused (assistant is answering) ·") else if (snapshot.automatic) "Indexing in background (pauses when you return)…" else "Indexing…", snapshot.done, snapshot.total, snapshot.indexed, snapshot.skipped, pdf_note, degraded_note }, 0) catch return
        else if (std.mem.eql(u8, snapshot.state, "ready"))
            std.mem.printSentinel(&buffer, "Ready · {d} passages from {d} files{s}{s}{s}", .{ snapshot.chunks, snapshot.files, pdf_note, degraded_note, pending_note }, 0) catch return
        else if (std.mem.eql(u8, snapshot.state, "failed"))
            std.mem.printSentinel(&buffer, "Indexing failed: {s}. Retry Index now.", .{snapshot.error_code}, 0) catch return
        else if (std.mem.eql(u8, snapshot.state, "setup"))
            std.mem.printSentinel(&buffer, "{s}{s}", .{ if (!snapshot.model_installed) @import("i18n").dtr("pearl", "Not indexed. Download the embedding model, add folders, then Index now.") else @import("i18n").dtr("pearl", "Not indexed. Add folders and run Index now."), pending_note }, 0) catch return
        else
            @import("i18n").dtr("pearl", "Semantic search is off in the saved preferences.");
        if (std.mem.eql(u8, self.last_status.items, text)) return;
        self.last_status.clearRetainingCapacity();
        self.last_status.appendSlice(a, text) catch return;
        self.index_status.setText(a.dupeSentinel(u8, text, 0) catch return);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (self.dead) return 0;
        if (self.job) |job| {
            if (job.action == .download or (job.action == .setup and job.phase.load(.monotonic) == 1)) {
                var buffer: [96]u8 = undefined;
                const text = std.mem.printSentinel(&buffer, "Downloading embedding model… {d} MB", .{job.progress.load(.monotonic) / 1000000}, 0) catch return 1;
                self.status.setText(text);
            } else if (job.action == .setup) {
                self.status.setText(@import("i18n").dtr("pearl", "Setting up the runtime… Complete any package manager prompts in the terminal."));
            }
            return 1;
        }
        if (!self.editor.editable()) return 1;
        // Poll the shell only while the section is open; the CLI call is local.
        if (self.expander.getExpanded() != 0) self.begin(.status) catch {};
        return 1;
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.cancel) |cancel| cancel.cancel();
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.save();
    }
};
fn reasonText(reason: []const u8) []const u8 {
    const map = .{
        .{ "battery", "charging or 50% battery" },
        .{ "not_idle", "idle" },
        .{ "typing", "typing to stop" },
        .{ "load", "lower CPU load" },
        .{ "inhibited", "inhibitors to clear" },
        .{ "quiet_interval", "the next quiet window" },
        .{ "login_grace", "the session to settle" },
        .{ "memory", "more free memory" },
        .{ "power_saver", "power saver to turn off" },
        .{ "locked", "unlock" },
        .{ "chat_busy", "the assistant to finish" },
        .{ "sleep_pending", "sleep to be cancelled" },
        .{ "idle_unavailable", "idle notifications (unavailable)" },
        .{ "events_active", "changes to settle" },
        .{ "no_folders", "folders" },
        .{ "model_missing", "the model download" },
        .{ "breather", "the next burst" },
        .{ "nothing_pending", "changes" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, reason, pair[0])) return pair[1];
    }
    return "a quiet window";
}
fn label(host: *gtk.Box, text: [:0]const u8) *gtk.Label {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    host.append(l.as(gtk.Widget));
    return l;
}
fn button(host: *gtk.Box, title: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(title);
    b.as(gtk.Widget).addCssClass("settings-value");
    b.as(gtk.Widget).setHalign(.start);
    host.append(b.as(gtk.Widget));
    return b;
}
/// Index state lives in the shell; Settings reaches it through the same
/// verified CLI channel the assistant controls use.
fn ctl(alloc: std.mem.Allocator, operation: [:0]const u8, cancel: *gio.Cancellable) ![]const u8 {
    var buffer: [4096]u8 = undefined;
    const own = try @import("distribution.zig").executable(&buffer);
    const exe = if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_CTL") != null)
        try alloc.dupeSentinel(u8, std.mem.span(glib.getenv("PEARL_TEST_CTL").?), 0)
    else
        try std.fmt.allocPrintSentinel(alloc, "{s}/pearlctl{s}", .{ std.fs.path.dirname(own).?, if (@import("distribution.zig").isGit(own)) "-git" else "" }, 0);
    const result = try @import("../config/helper_process.zig").run(alloc, &.{ exe, "semantic", operation }, null, cancel, 10000);
    if (!result.success) return error.SemanticControlUnavailable;
    return result.stdout;
}
