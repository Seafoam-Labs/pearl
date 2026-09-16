//! Normal-window live-service controls and owner-scoped transient prompts.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const gdk = @import("gdk4");
const glib = @import("glib2");
const object = @import("gobject2");
const e = @import("../aqueous/entities.zig");
const ui = @import("live_protocol.zig");
const nav = @import("../desktop/settings_navigation.zig");
const Editor = @import("editor.zig").Editor;
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const Prompt = struct { service: []const u8, serial: []const u8, kind: []const u8, title: []const u8, challenge: []const u8, secret: bool, editable: bool };
const Page = struct { summary: []const u8, pending: bool, truncated: bool, rows: []const ui.Row, offset: []const u8, next_offset: ?[]const u8 = null, prompt: ?Prompt = null };
const Binding = struct { view: *View, spec: ui.Control, widget: *gtk.Widget, id: []const u8, signal: c_ulong };
pub const View = struct {
    editor: *Editor,
    route: nav.Route,
    window: *gtk.Window,
    host: *gtk.Box,
    context: *anyopaque,
    invalidate: *const fn (*anyopaque, nav.Route) void,
    arena: std.heap.ArenaAllocator,
    bindings: std.ArrayList(*Binding) = .empty,
    shown: ?[64]u8 = null,
    filling: bool = false,
    prompt: ?*gtk.Dialog = null,
    secret: ?*gtk.PasswordEntry = null,
    prompt_serial: u64 = 0,
    prompt_service: enum { network, bluetooth } = .network,
    prompt_message: ?*gtk.Label = null,
    next_offset: ?u64 = null,
    offset: u64 = 0,
    pub fn create(host: *gtk.Box, window: *gtk.Window, editor: *Editor, route: nav.Route, context: *anyopaque, invalidate: *const fn (*anyopaque, nav.Route) void) !*View {
        const self = try a.create(View);
        self.* = .{ .editor = editor, .route = route, .window = window, .host = host, .context = context, .invalidate = invalidate, .arena = .init(a) };
        host.append(w.label("Loading service state…", "pearl-secondary").as(gtk.Widget));
        return self;
    }
    fn clear(self: *View) void {
        self.invalidate(self.context, self.route);
        for (self.bindings.items) |binding| object.signalHandlerDisconnect(binding.widget.as(object.Object), binding.signal);
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        self.bindings.clearRetainingCapacity();
        self.arena.deinit();
        self.arena = .init(a);
    }
    pub fn destroy(self: *View) void {
        self.closePrompt();
        self.clear();
        self.bindings.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn closePrompt(self: *View) void {
        if (self.secret) |entry| entry.as(gtk.Editable).setText("");
        self.secret = null;
        if (self.prompt) |dialog| {
            self.prompt = null;
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        self.prompt_serial = 0;
        self.prompt_message = null;
    }
    pub fn update(self: *View) void {
        if (self.editor.target.page != self.route or !self.editor.online or self.editor.state.locked or self.editor.suspended) {
            self.closePrompt();
            self.shown = null;
            self.host.as(gtk.Widget).setSensitive(0);
            return;
        }
        self.host.as(gtk.Widget).setSensitive(1);
        if (self.editor.needs_snapshot) return;
        const bytes = self.editor.live orelse return;
        const digest = @import("editor_protocol.zig").digest(bytes);
        if (self.shown) |shown| if (std.mem.eql(u8, &shown, &digest)) return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return;
        const data = e.read(Page, alloc, value) catch return;
        self.showPrompt(data.prompt);
        var focused: @import("../services/policy.zig").Text(1024) = .{};
        var focused_text: @import("../services/policy.zig").Text(128) = .{};
        var focused_params: ?[64]u8 = null;
        var cursor: c_int = 0;
        if (self.window.getFocus()) |focus| for (self.bindings.items) |binding| {
            if (focus == binding.widget or focus.isAncestor(binding.widget) != 0) {
                focused.set(binding.id);
                if (binding.spec.kind == .number) {
                    const editable = object.ext.cast(gtk.SpinButton, binding.widget).?.as(gtk.Editable);
                    focused_text.set(std.mem.span(editable.getText()));
                    cursor = editable.getPosition();
                    focused_params = @import("editor_protocol.zig").digest(binding.spec.params);
                }
                break;
            }
        };
        self.filling = true;
        defer self.filling = false;
        self.clear();
        self.shown = digest;
        const arena = self.arena.allocator();
        const page = e.read(Page, arena, std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return) catch return;
        self.offset = std.fmt.parseInt(u64, page.offset, 10) catch 0;
        self.next_offset = if (page.next_offset) |offset| std.fmt.parseInt(u64, offset, 10) catch null else null;
        self.host.append(w.label(arena.dupeZ(u8, page.summary) catch return, "pearl-secondary").as(gtk.Widget));
        if (page.pending) self.host.append(w.label("Request in progress…", "pearl-secondary").as(gtk.Widget));
        if (page.truncated) self.host.append(w.label("The service reported more items than it can expose. This list is incomplete.", "pearl-secondary").as(gtk.Widget));
        for (page.rows) |row| {
            const card = w.column(4);
            card.as(gtk.Widget).addCssClass("settings-card");
            card.as(gtk.Widget).addCssClass("settings-live-card");
            card.append(w.label(arena.dupeZ(u8, row.title) catch continue, "pearl-card-title").as(gtk.Widget));
            if (row.detail.len > 0) card.append(w.label(arena.dupeZ(u8, row.detail) catch continue, "pearl-secondary").as(gtk.Widget));
            const actions = w.flow(3);
            actions.setHomogeneous(0);
            actions.as(gtk.Widget).addCssClass("settings-live-actions");
            for (row.controls) |spec| {
                const binding = arena.create(Binding) catch continue;
                const label = arena.dupeZ(u8, spec.label) catch continue;
                const widget = switch (spec.kind) {
                    .button => w.wrappingButton(label).as(gtk.Widget),
                    .number => gtk.SpinButton.newWithRange(spec.min, spec.max, if (std.mem.eql(u8, spec.field, "position")) 1000000 else 1).as(gtk.Widget),
                    .choice => blk: {
                        const names = arena.alloc(?[*:0]const u8, spec.choices.len + 1) catch continue;
                        for (spec.choices, 0..) |choice, i| names[i] = arena.dupeZ(u8, choice.label) catch "";
                        names[spec.choices.len] = null;
                        break :blk gtk.DropDown.newFromStrings(@ptrCast(names.ptr)).as(gtk.Widget);
                    },
                };
                w.name(widget, arena.dupeZ(u8, std.fmt.allocPrint(arena, "{s}: {s}", .{ row.title, spec.label }) catch continue) catch continue);
                widget.setSensitive(@intFromBool(spec.enabled));
                if (spec.kind == .number) object.ext.cast(gtk.SpinButton, widget).?.setValue(spec.value);
                if (spec.kind == .choice) for (spec.choices, 0..) |choice, i| {
                    if ((std.fmt.parseFloat(f64, choice.value) catch -1) == spec.value) object.ext.cast(gtk.DropDown, widget).?.setSelected(@intCast(i));
                };
                binding.* = .{ .view = self, .spec = spec, .widget = widget, .id = std.fmt.allocPrint(arena, "{s}/{s}", .{ row.id, spec.id }) catch continue, .signal = 0 };
                binding.signal = switch (spec.kind) {
                    .button => gtk.Button.signals.clicked.connect(object.ext.cast(gtk.Button, widget).?, *Binding, clicked, binding, .{}),
                    .number => gtk.SpinButton.signals.value_changed.connect(object.ext.cast(gtk.SpinButton, widget).?, *Binding, numbered, binding, .{}),
                    .choice => object.Object.signals.notify.connect(widget.as(object.Object), *Binding, selected, binding, .{ .detail = "selected" }),
                };
                self.bindings.append(a, binding) catch {
                    object.signalHandlerDisconnect(widget.as(object.Object), binding.signal);
                    continue;
                };
                if (spec.kind == .number or spec.kind == .choice) {
                    const field = w.column(4);
                    field.append(w.label(arena.dupeZ(u8, spec.label) catch continue, "pearl-secondary").as(gtk.Widget));
                    field.append(widget);
                    actions.insert(field.as(gtk.Widget), -1);
                } else actions.insert(widget, -1);
            }
            card.append(actions.as(gtk.Widget));
            self.host.append(card.as(gtk.Widget));
        }
        const pagination = w.row(8);
        const previous = w.wrappingButton("Previous items");
        const next = w.wrappingButton("More items");
        previous.as(gtk.Widget).setSensitive(@intFromBool(self.offset > 0));
        next.as(gtk.Widget).setSensitive(@intFromBool(self.next_offset != null));
        _ = gtk.Button.signals.clicked.connect(previous, *View, previousClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(next, *View, nextClicked, self, .{});
        pagination.append(previous.as(gtk.Widget));
        pagination.append(next.as(gtk.Widget));
        self.host.append(pagination.as(gtk.Widget));
        pagination.as(gtk.Widget).setVisible(@intFromBool(self.offset > 0 or self.next_offset != null));
        if (focused.len > 0) for (self.bindings.items) |binding| {
            if (std.mem.eql(u8, focused.slice(), binding.id)) {
                if (focused_params) |params| if (binding.spec.kind == .number and std.mem.eql(u8, &params, &@import("editor_protocol.zig").digest(binding.spec.params))) {
                    const editable = object.ext.cast(gtk.SpinButton, binding.widget).?.as(gtk.Editable);
                    editable.setText(focused_text.z());
                    editable.setPosition(cursor);
                };
                _ = binding.widget.grabFocus();
                break;
            }
        };
    }
    fn issue(binding: *Binding) void {
        const self = binding.view;
        if (self.filling) return;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        var params = std.json.parseFromSliceLeaky(std.json.Value, alloc, binding.spec.params, .{}) catch return;
        switch (binding.spec.kind) {
            .number => {
                const scale: f64 = if (binding.spec.op == .@"media.action" and std.mem.eql(u8, binding.spec.field, "position")) 1_000_000 else 1;
                const value = object.ext.cast(gtk.SpinButton, binding.widget).?.getValue() * scale;
                params.object.put(alloc, binding.spec.field, .{ .integer = @intFromFloat(@min(9007199254740991, @max(-9007199254740991, value))) }) catch return;
            },
            .choice => {
                const index = object.ext.cast(gtk.DropDown, binding.widget).?.getSelected();
                if (index >= binding.spec.choices.len) return;
                const number = std.fmt.parseInt(i64, binding.spec.choices[index].value, 10) catch return;
                params.object.put(alloc, binding.spec.field, .{ .integer = number }) catch return;
            },
            .button => {},
        }
        self.editor.liveAction(binding.spec.op, params) catch |err| self.editor.error_code.set(@errorName(err));
    }
    fn clicked(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        issue(binding);
    }
    fn numbered(_: *gtk.SpinButton, binding: *Binding) callconv(.c) void {
        issue(binding);
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, binding: *Binding) callconv(.c) void {
        issue(binding);
    }
    fn nextClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.next_offset) |offset| self.editor.livePage(offset);
    }
    fn previousClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.editor.livePage(self.offset -| 16);
    }
    fn showPrompt(self: *View, value: ?Prompt) void {
        const data = value orelse {
            self.closePrompt();
            return;
        };
        const serial = std.fmt.parseInt(u64, data.serial, 10) catch return;
        if (self.prompt_serial == serial and self.prompt != null) {
            if (self.prompt_message) |label| {
                const text = std.fmt.allocPrintSentinel(a, "{s}\n{s}", .{ data.title, data.challenge }, 0) catch return;
                defer a.free(text);
                label.setText(text);
            }
            return;
        }
        self.closePrompt();
        self.prompt_serial = serial;
        self.prompt_service = if (std.mem.eql(u8, data.service, "network")) .network else .bluetooth;
        const dialog = gtk.Dialog.new();
        _ = dialog.ref();
        self.prompt = dialog;
        dialog.as(gtk.Window).setTitle(if (self.prompt_service == .network) "Network authentication" else "Bluetooth pairing");
        dialog.as(gtk.Window).setTransientFor(self.window);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setDefaultSize(420, 220);
        const content = dialog.getContentArea();
        content.as(gtk.Widget).setMarginStart(20);
        content.as(gtk.Widget).setMarginEnd(20);
        content.as(gtk.Widget).setMarginTop(20);
        content.as(gtk.Widget).setMarginBottom(20);
        const text = std.fmt.allocPrintSentinel(a, "{s}\n{s}", .{ data.title, data.challenge }, 0) catch return;
        defer a.free(text);
        self.prompt_message = w.label(text, null);
        content.append(self.prompt_message.?.as(gtk.Widget));
        if (data.secret) {
            const entry = gtk.PasswordEntry.new();
            entry.setShowPeekIcon(0);
            self.secret = entry;
            _ = gtk.PasswordEntry.signals.activate.connect(entry, *View, passwordActivated, self, .{});
            w.name(entry.as(gtk.Widget), "Password, PIN or passkey");
            content.append(entry.as(gtk.Widget));
        }
        _ = dialog.addButton("Cancel", @intFromEnum(gtk.ResponseType.cancel));
        if (data.editable) _ = dialog.addButton("Confirm", @intFromEnum(gtk.ResponseType.accept));
        _ = gtk.Dialog.signals.response.connect(dialog, *View, answered, self, .{});
        dialog.as(gtk.Window).present();
        if (self.secret) |entry| _ = entry.as(gtk.Widget).grabFocus();
    }
    fn passwordActivated(_: *gtk.PasswordEntry, self: *View) callconv(.c) void {
        if (self.prompt) |dialog| dialog.response(@intFromEnum(gtk.ResponseType.accept));
    }
    fn answered(_: *gtk.Dialog, response: c_int, self: *View) callconv(.c) void {
        var memory: [32768]u8 = undefined;
        defer std.crypto.secureZero(u8, &memory);
        var scratch = std.heap.FixedBufferAllocator.init(&memory);
        const alloc = scratch.allocator();
        const text = if (self.secret) |entry| std.mem.span(entry.as(gtk.Editable).getText()) else "";
        if (text.len > 1024) {
            if (self.prompt_message) |label| label.setText("The answer is too long. Please try again.");
            if (self.secret) |entry| entry.as(gtk.Editable).setText("");
            return;
        }
        const serial = self.prompt_serial;
        const encoded = std.json.Stringify.valueAlloc(alloc, .{ .service = self.prompt_service, .prompt = @import("editor_protocol.zig").num(serial), .accept = response == @intFromEnum(gtk.ResponseType.accept), .text = text }, .{}) catch return;
        defer std.crypto.secureZero(u8, encoded);
        const params = std.json.parseFromSliceLeaky(std.json.Value, alloc, encoded, .{}) catch return;
        self.editor.liveAction(.@"prompt.answer", params) catch |err| {
            self.editor.error_code.set(@errorName(err));
            if (self.prompt_message) |label| label.setText("The answer could not be sent. Please try again.");
            if (self.secret) |entry| entry.as(gtk.Editable).setText("");
            return;
        };
        self.closePrompt();
        self.shown = null;
    }
};
pub fn launchNetworkEditor(window: *gtk.Window) !void {
    const app = @import("giounix2").DesktopAppInfo.new("nm-connection-editor.desktop") orelse return error.NetworkEditorMissing;
    defer app.unref();
    const context = window.as(gtk.Widget).getDisplay().getAppLaunchContext();
    defer context.unref();
    var err: ?*glib.Error = null;
    defer if (err) |value| value.free();
    if (app.as(gio.AppInfo).launch(null, context.as(gio.AppLaunchContext), &err) == 0) return error.NetworkEditorLaunchFailed;
}
