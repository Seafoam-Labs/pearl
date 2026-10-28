//! Retained Sound controls. Only inventory/default changes rebuild widgets;
//! volume, mute and stream routing updates preserve focus and slider gestures.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const ui = @import("live_protocol.zig");
const policy = @import("../services/policy.zig");
const w = @import("../ui/components/widgets.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;

pub const Control = struct { id: []const u8, widget: *gtk.Widget };
const Connection = struct { obj: *object.Object, id: c_ulong };
const Action = struct { view: *View, write: policy.Write, popover: ?*gtk.Popover = null };
const Row = struct {
    view: *View,
    device: ui.SoundDevice,
    key: policy.Key,
    detail: *gtk.Label,
    scale: *gtk.Scale,
    number: *gtk.SpinButton,
    mute: *gtk.Button,
    desired_mute: ?bool = null,
    target: ?*gtk.DropDown = null,
    targets: []const u32 = &.{},
    use_default: ?*Action = null,
    default_button: ?*gtk.Button = null,
};

pub const View = struct {
    editor: *Editor,
    window: *gtk.Window,
    root: *gtk.Box,
    status: *gtk.Label,
    body: *gtk.Box,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(*Row) = .empty,
    controls: std.ArrayList(Control) = .empty,
    connections: std.ArrayList(Connection) = .empty,
    expanders: [2]?*gtk.Expander = .{ null, null },
    generation: u64 = 0,
    lease: u64,
    filling: bool = false,
    initialized: bool = false,
    queue: policy.Queue = .{},
    timer: c_uint = 0,
    deadline: i64 = 0,

    pub fn create(host: *gtk.Box, window: *gtk.Window, editor: *Editor) !*View {
        const self = try a.create(View);
        const root = w.column(20);
        root.as(gtk.Widget).addCssClass("sound-view");
        const status = w.label("", "pearl-secondary");
        root.append(status.as(gtk.Widget));
        const body = w.column(22);
        root.append(body.as(gtk.Widget));
        self.* = .{ .editor = editor, .window = window, .root = root, .body = body, .status = status, .arena = .init(a), .lease = editor.view };
        host.append(root.as(gtk.Widget));
        return self;
    }

    pub fn cancel(self: *View) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        self.queue.len = 0;
    }

    fn clear(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.clearRetainingCapacity();
        while (self.body.as(gtk.Widget).getFirstChild()) |child| self.body.remove(child);
        self.rows.clearRetainingCapacity();
        self.controls.clearRetainingCapacity();
        self.expanders = .{ null, null };
        self.arena.deinit();
        self.arena = .init(a);
    }

    pub fn destroy(self: *View) void {
        self.cancel();
        self.clear();
        self.rows.deinit(a);
        self.controls.deinit(a);
        self.connections.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    fn remember(self: *View, widget: anytype, signal: c_ulong) !void {
        try self.connections.append(a, .{ .obj = widget.as(object.Object), .id = signal });
    }

    fn control(self: *View, id: []const u8, widget: *gtk.Widget) !void {
        try self.controls.append(a, .{ .id = try self.arena.allocator().dupe(u8, id), .widget = widget });
    }

    fn action(self: *View, host: *gtk.Box, label: [:0]const u8, id: []const u8, write: policy.Write, popover: ?*gtk.Popover) !*Action {
        const binding = try self.arena.allocator().create(Action);
        binding.* = .{ .view = self, .write = write, .popover = popover };
        const button = w.wrappingButton(label);
        object.ext.cast(gtk.Label, button.getChild().?).?.setMaxWidthChars(28);
        host.append(button.as(gtk.Widget));
        try self.remember(button, gtk.Button.signals.clicked.connect(button, *Action, actionClicked, binding, .{}));
        try self.control(id, button.as(gtk.Widget));
        return binding;
    }

    fn card() *gtk.Box {
        const box = w.column(12);
        box.as(gtk.Widget).addCssClass("sound-card");
        return box;
    }

    fn menu(label: ?[:0]const u8) struct { button: *gtk.MenuButton, popover: *gtk.Popover, box: *gtk.Box } {
        const button = gtk.MenuButton.new();
        if (label) |text| button.setLabel(text) else button.setLabel(@import("i18n").dtr("pearl", "•••"));
        const popover = gtk.Popover.new();
        const box = w.column(8);
        box.as(gtk.Widget).addCssClass("sound-menu");
        // Large device inventories must not create a screen-height popup.
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setMaxContentHeight(320);
        scroll.setPropagateNaturalHeight(1);
        scroll.setPropagateNaturalWidth(1);
        scroll.setChild(box.as(gtk.Widget));
        popover.setChild(scroll.as(gtk.Widget));
        button.setPopover(popover);
        return .{ .button = button, .popover = popover, .box = box };
    }

    fn addRow(self: *View, host: *gtk.Box, device: ui.SoundDevice, snapshot: ui.Sound) !void {
        const alloc = self.arena.allocator();
        const row = try alloc.create(Row);
        const box = w.column(10);
        box.as(gtk.Widget).addCssClass("sound-device");
        host.append(box.as(gtk.Widget));
        const head = w.flow(2);
        head.setHomogeneous(0);
        head.setColumnSpacing(16);
        const labels = w.column(3);
        labels.as(gtk.Widget).setHexpand(1);
        labels.append(w.label(try alloc.dupeSentinel(u8, device.label, 0), "settings-row-title").as(gtk.Widget));
        const detail = w.label("", "pearl-secondary");
        labels.append(detail.as(gtk.Widget));
        head.insert(labels.as(gtk.Widget), -1);
        box.append(head.as(gtk.Widget));
        const line = w.row(10);
        const mute = w.iconButton("pearl-audio-volume-high-symbolic", @import("i18n").dtr("pearl", "Mute"));
        mute.as(gtk.Widget).addCssClass("sound-mute");
        line.append(mute.as(gtk.Widget));
        const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
        scale.setDrawValue(0);
        scale.setDigits(0);
        scale.as(gtk.Range).setValue(@floatFromInt(device.volume));
        scale.as(gtk.Widget).setHexpand(1);
        line.append(scale.as(gtk.Widget));
        const number = gtk.SpinButton.newWithRange(0, 100, 1);
        number.setValue(@floatFromInt(device.volume));
        number.as(gtk.Editable).setWidthChars(3);
        number.as(gtk.Editable).setMaxWidthChars(3);
        number.as(gtk.Widget).addCssClass("sound-percent");
        line.append(number.as(gtk.Widget));
        const percent = w.label(@import("i18n").dtr("pearl", "%"), "pearl-secondary");
        percent.as(gtk.Widget).setHexpand(0);
        line.append(percent.as(gtk.Widget));
        box.append(line.as(gtk.Widget));
        row.* = .{ .view = self, .device = device, .key = .{ .generation = self.generation, .kind = device.kind, .index = device.index }, .detail = detail, .scale = scale, .number = number, .mute = mute };
        row.device.label = try alloc.dupe(u8, device.label);
        try self.rows.append(a, row);
        inline for (.{ .{ "volume", number.as(gtk.Widget) }, .{ "slider", scale.as(gtk.Widget) }, .{ "mute", mute.as(gtk.Widget) } }) |entry| {
            try self.control(try std.fmt.allocPrint(alloc, "{s}:{d}/{s}", .{ @tagName(device.kind), device.index, entry[0] }), entry[1]);
            w.name(entry[1], try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ device.label, if (std.mem.eql(u8, entry[0], "mute")) "Mute" else "Volume" }, 0));
        }
        try self.remember(scale, gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *Row, scaled, row, .{}));
        try self.remember(number, gtk.SpinButton.signals.value_changed.connect(number, *Row, numbered, row, .{}));
        try self.remember(mute, gtk.Button.signals.clicked.connect(mute, *Row, muted, row, .{}));
        const hardware = device.kind == .sink or device.kind == .source;
        if (hardware and !device.is_default) {
            const actions = w.column(0);
            _ = try self.action(actions, @import("i18n").dtr("pearl", "Use by default"), try std.fmt.allocPrint(alloc, "{s}:{d}/default", .{ @tagName(device.kind), device.index }), .{ .key = row.key, .default = true }, null);
            head.insert(actions.as(gtk.Widget), -1);
        } else {
            const popup = menu(if (hardware) @import("i18n").dtr("pearl", "Change device") else null);
            popup.button.as(gtk.Widget).setHalign(.end);
            w.name(popup.button.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s}: {s}", .{ device.label, if (hardware) "Change device" else "Routing options" }, 0));
            try self.control(try std.fmt.allocPrint(alloc, "{s}:{d}/menu", .{ @tagName(device.kind), device.index }), popup.button.as(gtk.Widget));
            head.insert(popup.button.as(gtk.Widget), -1);
            if (hardware) {
                for (snapshot.devices) |target| if (target.kind == device.kind) {
                    _ = try self.action(popup.box, try alloc.dupeSentinel(u8, target.label, 0), try std.fmt.allocPrint(alloc, "{s}:{d}/default", .{ @tagName(target.kind), target.index }), .{ .key = .{ .generation = self.generation, .kind = target.kind, .index = target.index }, .default = true }, popup.popover);
                    popup.box.as(gtk.Widget).getLastChild().?.setSensitive(@intFromBool(!target.is_default));
                };
            } else {
                row.use_default = try self.action(popup.box, @import("i18n").dtr("pearl", "Move to default"), try std.fmt.allocPrint(alloc, "{s}:{d}/default", .{ @tagName(device.kind), device.index }), .{ .key = row.key }, popup.popover);
                row.default_button = object.ext.cast(gtk.Button, popup.box.as(gtk.Widget).getLastChild().?).?;
                popup.box.append(w.label(@import("i18n").dtr("pearl", "Choose device"), "pearl-secondary").as(gtk.Widget));
                var names: std.ArrayList(?[*:0]const u8) = .empty;
                var targets: std.ArrayList(u32) = .empty;
                for (snapshot.devices) |target| if (target.kind == targetKind(device.kind)) {
                    try names.append(alloc, try alloc.dupeSentinel(u8, target.label, 0));
                    try targets.append(alloc, target.index);
                };
                try names.append(alloc, null);
                const selector = gtk.DropDown.newFromStrings(@ptrCast(names.items.ptr));
                const factory = gtk.SignalListItemFactory.new();
                _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, choiceSetup, null, .{});
                _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, choiceBind, null, .{});
                selector.setFactory(factory.as(gtk.ListItemFactory));
                selector.setListFactory(factory.as(gtk.ListItemFactory));
                factory.unref();
                popup.box.append(selector.as(gtk.Widget));
                w.name(selector.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "{s}: Device", .{device.label}, 0));
                row.target = selector;
                row.targets = targets.items;
                try self.control(try std.fmt.allocPrint(alloc, "{s}:{d}/target", .{ @tagName(device.kind), device.index }), selector.as(gtk.Widget));
                try self.remember(selector, object.Object.signals.notify.connect(selector.as(object.Object), *Row, selected, row, .{ .detail = "selected" }));
            }
        }
    }

    fn rebuild(self: *View, snapshot: ui.Sound) !void {
        var expanded = [2]bool{ false, false };
        for (self.expanders, 0..) |expander, i| if (expander) |e| {
            expanded[i] = e.getExpanded() != 0;
        };
        var focused: policy.Text(128) = .{};
        if (self.window.getFocus()) |focus| for (self.controls.items) |c| {
            if (focus == c.widget or focus.isAncestor(c.widget) != 0) {
                focused.set(c.id);
                break;
            }
        };
        self.clear();
        const alloc = self.arena.allocator();
        for ([_]policy.Kind{ .sink, .source }, 0..) |kind, section| {
            const group = w.column(12);
            self.body.append(group.as(gtk.Widget));
            group.append(w.label(if (kind == .sink) @import("i18n").dtr("pearl", "Output") else @import("i18n").dtr("pearl", "Input"), "pearl-section-title").as(gtk.Widget));
            const main = card();
            group.append(main.as(gtk.Widget));
            var total: usize = 0;
            var default: ?ui.SoundDevice = null;
            for (snapshot.devices) |device| if (device.kind == kind) {
                total += 1;
                if (device.is_default) default = device;
            };
            if (default) |device| try self.addRow(main, device, snapshot) else main.append(w.label(if (kind == .sink) @import("i18n").dtr("pearl", "No default output device") else @import("i18n").dtr("pearl", "No default input device"), "pearl-secondary").as(gtk.Widget));
            if (total == 0) main.append(w.label(if (kind == .sink) @import("i18n").dtr("pearl", "Connect speakers or headphones to play sound.") else @import("i18n").dtr("pearl", "Connect a microphone to record sound."), "pearl-secondary").as(gtk.Widget));
            const others = total - @as(usize, if (default != null) 1 else 0);
            if (others > 0) {
                const expander = gtk.Expander.new(try std.fmt.allocPrintSentinel(alloc, "{s} ({d})", .{ if (kind == .sink) "Other output devices" else "Other input devices", others }, 0));
                const list = w.column(16);
                expander.setChild(list.as(gtk.Widget));
                expander.setExpanded(@intFromBool(expanded[section] or default == null));
                self.expanders[section] = expander;
                main.append(expander.as(gtk.Widget));
                try self.control(if (kind == .sink) "sound/other-outputs" else "sound/other-inputs", expander.as(gtk.Widget));
                for (snapshot.devices) |device| if (device.kind == kind and !device.is_default) try self.addRow(list, device, snapshot);
            }
        }
        const apps = w.column(12);
        self.body.append(apps.as(gtk.Widget));
        apps.append(w.label(@import("i18n").dtr("pearl", "Applications"), "pearl-section-title").as(gtk.Widget));
        const list = card();
        apps.append(list.as(gtk.Widget));
        var count: usize = 0;
        for (snapshot.devices) |device| if (device.kind == .playback or device.kind == .recording) {
            try self.addRow(list, device, snapshot);
            count += 1;
        };
        if (count == 0) list.append(w.label(@import("i18n").dtr("pearl", "Applications appear here when they play or record audio."), "pearl-secondary").as(gtk.Widget));
        if (focused.len > 0) for (self.controls.items) |c| if (std.mem.eql(u8, c.id, focused.slice()) and c.widget.getVisible() != 0) {
            _ = c.widget.grabFocus();
            break;
        };
    }

    pub fn update(self: *View, snapshot: ui.Sound) void {
        const generation = std.fmt.parseInt(u64, snapshot.generation, 10) catch return;
        var different = !self.initialized or generation != self.generation or self.rows.items.len != snapshot.devices.len;
        if (!different) for (snapshot.devices) |device| {
            const row = self.find(device.kind, device.index) orelse {
                different = true;
                break;
            };
            if (row.device.is_default != device.is_default or !std.mem.eql(u8, row.device.label, device.label)) {
                different = true;
                break;
            }
        };
        if (generation != self.generation or !snapshot.ready) self.cancel();
        self.generation = generation;
        self.filling = true;
        defer self.filling = false;
        if (different) {
            self.rebuild(snapshot) catch {
                self.status.setText(@import("i18n").dtr("pearl", "Unable to display sound controls."));
                return;
            };
            self.initialized = true;
        }
        var buffer: [1024]u8 = undefined;
        const status = if (snapshot.error_message.len > 0) snapshot.error_message else if (!snapshot.ready) "Audio service unavailable. Reconnecting…" else if (snapshot.truncated) "Some audio devices could not be listed." else if (snapshot.pending) "Applying changes…" else "";
        self.status.setText(std.mem.printSentinel(&buffer, "{s}", .{status}, 0) catch "Audio unavailable");
        self.status.as(gtk.Widget).setVisible(@intFromBool(status.len > 0));
        self.body.as(gtk.Widget).setSensitive(@intFromBool(snapshot.ready));
        for (snapshot.devices) |device| {
            const row = self.find(device.kind, device.index) orelse continue;
            row.device.volume = device.volume;
            row.device.muted = device.muted;
            row.device.target = device.target;
            row.device.writable = device.writable;
            var queued = false;
            for (self.queue.items[0..self.queue.len]) |write| if (std.meta.eql(write.key, row.key)) {
                queued = true;
                break;
            };
            if (!queued and !snapshot.pending and self.editor.live_command == null) {
                row.number.setValue(@floatFromInt(device.volume));
                row.scale.as(gtk.Range).setValue(@floatFromInt(device.volume));
                row.desired_mute = null;
            }
            for ([_]*gtk.Widget{ row.number.as(gtk.Widget), row.scale.as(gtk.Widget), row.mute.as(gtk.Widget) }) |widget| widget.setSensitive(@intFromBool(device.writable));
            row.mute.setChild(w.icon(if (device.muted) "pearl-audio-volume-muted-symbolic" else if (targetKind(device.kind) == .source) "pearl-microphone-symbolic" else "pearl-audio-volume-high-symbolic").as(gtk.Widget));
            const mute_name = std.mem.printSentinel(&buffer, "{s}: {s}", .{ device.label, if (device.muted) "Unmute" else "Mute" }, 0) catch "Mute";
            w.name(row.mute.as(gtk.Widget), mute_name);
            row.mute.as(gtk.Widget).setTooltipText(mute_name);
            if (device.muted) row.mute.as(gtk.Widget).addCssClass("sound-muted") else row.mute.as(gtk.Widget).removeCssClass("sound-muted");
            const hardware = device.kind == .sink or device.kind == .source;
            var route: []const u8 = "Device unavailable";
            var default: ?u32 = null;
            for (snapshot.devices) |target| if (target.kind == targetKind(device.kind)) {
                if (target.index == device.target) route = target.label;
                if (target.is_default) default = target.index;
            };
            const detail = if (hardware) (if (device.is_default) (if (device.kind == .sink) "Default output" else "Default input") else (if (device.kind == .sink) "Output device" else "Input device")) else (if (device.kind == .playback) "Output" else "Input");
            row.detail.setText(std.mem.printSentinel(&buffer, "{s}{s}{s}{s}{s}", .{ detail, if (hardware) "" else " · ", if (hardware) "" else route, if (device.muted) " · Muted" else "", if (!device.writable) " · Volume unavailable" else "" }, 0) catch "Audio");
            if (row.target) |selector| {
                var selected_index: c_uint = gtk.INVALID_LIST_POSITION;
                for (row.targets, 0..) |target, i| if (target == device.target) {
                    selected_index = @intCast(i);
                    break;
                };
                selector.setSelected(selected_index);
                selector.as(gtk.Widget).setSensitive(@intFromBool(row.targets.len > 0));
            }
            if (row.use_default) |action_binding| {
                action_binding.write.move = default;
                row.default_button.?.as(gtk.Widget).setSensitive(@intFromBool(default != null and default.? != device.target));
            }
        }
    }

    fn find(self: *View, kind: policy.Kind, index: u32) ?*Row {
        for (self.rows.items) |row| if (row.key.kind == kind and row.key.index == index) return row;
        return null;
    }

    fn enqueue(self: *View, write: policy.Write) void {
        if (self.filling) return;
        self.queue.put(write) catch {
            self.editor.error_code.set("Busy");
            return;
        };
        self.deadline = glib.getMonotonicTime() + 5_000_000;
        if (self.timer == 0) self.timer = glib.timeoutAdd(100, dispatch, self);
    }

    fn dispatch(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        if (!self.editor.online or self.editor.suspended or self.editor.state.locked or self.editor.target.page != .sound or self.editor.view != self.lease or glib.getMonotonicTime() > self.deadline) {
            self.queue.len = 0;
            self.timer = 0;
            return 0;
        }
        if (self.editor.live_command != null) return 1;
        const write = self.queue.take() orelse {
            self.timer = 0;
            return 0;
        };
        // Inventory changes can invalidate queued gestures without a reconnect.
        if (write.key.generation != self.generation or self.find(write.key.kind, write.key.index) == null) return 1;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const bytes = std.json.Stringify.valueAlloc(alloc, .{ .generation = @import("editor_protocol.zig").num(write.key.generation), .kind = write.key.kind, .device = write.key.index, .volume = write.volume, .mute = write.mute, .make_default = if (write.default) @as(?bool, true) else null, .target = write.move }, .{ .emit_null_optional_fields = false }) catch return 1;
        const params = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return 1;
        self.editor.liveAction(.@"audio.set", params) catch |err| {
            if (err == error.Busy) self.queue.put(write) catch {} else self.editor.error_code.set(@errorName(err));
            return 1;
        };
        self.editor.error_code = .{};
        return 1;
    }

    fn scaled(range: *gtk.Range, row: *Row) callconv(.c) void {
        if (row.view.filling) return;
        row.view.filling = true;
        row.number.setValue(range.getValue());
        row.view.filling = false;
        row.view.enqueue(.{ .key = row.key, .volume = @intFromFloat(range.getValue()) });
    }
    fn numbered(number: *gtk.SpinButton, row: *Row) callconv(.c) void {
        if (row.view.filling) return;
        row.view.filling = true;
        row.scale.as(gtk.Range).setValue(number.getValue());
        row.view.filling = false;
        row.view.enqueue(.{ .key = row.key, .volume = @intFromFloat(number.getValue()) });
    }
    fn muted(_: *gtk.Button, row: *Row) callconv(.c) void {
        const desired = !(row.desired_mute orelse row.device.muted);
        row.desired_mute = desired;
        row.view.enqueue(.{ .key = row.key, .mute = desired });
    }
    fn actionClicked(_: *gtk.Button, action_binding: *Action) callconv(.c) void {
        action_binding.view.enqueue(action_binding.write);
        if (action_binding.popover) |popover| popover.popdown();
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, row: *Row) callconv(.c) void {
        if (row.view.filling) return;
        const index = row.target.?.getSelected();
        if (index < row.targets.len) row.view.enqueue(.{ .key = row.key, .move = row.targets[index] });
    }
    fn choiceSetup(_: *gtk.SignalListItemFactory, obj: *object.Object, _: ?*anyopaque) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const label = w.label("", null);
        label.setMaxWidthChars(24);
        label.setEllipsize(.end);
        item.setChild(label.as(gtk.Widget));
    }
    fn choiceBind(_: *gtk.SignalListItemFactory, obj: *object.Object, _: ?*anyopaque) callconv(.c) void {
        const item = object.ext.cast(gtk.ListItem, obj).?;
        const label = object.ext.cast(gtk.Label, item.getChild().?).?;
        const text = object.ext.cast(gtk.StringObject, item.getItem().?).?.getString();
        label.setText(text);
        label.as(gtk.Widget).setTooltipText(text);
    }
};

fn targetKind(kind: policy.Kind) policy.Kind {
    return if (kind == .source or kind == .recording) .source else .sink;
}
