//! Shared native per-display brightness controls for the compact flyout.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const Power = @import("../services/power.zig").Power;
const Idle = @import("../platform/wayland/idle.zig").Idle;
pub const View = struct {
    owner: @import("../services/view_ownership.zig").Owner,
    power: *Power,
    idle: ?*Idle,
    picker: *gtk.DropDown,
    scale: *gtk.Scale,
    value: *gtk.Label,
    status: *gtk.Label,
    screen: *gtk.Button,
    updating: bool = false,
    signature: u64 = 0,
    connections: [3]c_ulong = @splat(0),
    pub fn create(host: *gtk.Box, power: *Power, idle: ?*Idle) !*View {
        const owner = try power.acquireView();
        errdefer power.releaseView(owner);
        const self = try std.heap.c_allocator.create(View);
        const card = w.card();
        card.append(w.label(@import("i18n").dtr("pearl", "Brightness"), "pearl-card-title").as(gtk.Widget));
        const picker = gtk.DropDown.new(null, null);
        picker.as(gtk.Widget).setHexpand(1);
        w.name(picker.as(gtk.Widget), @import("i18n").dtr("pearl", "Display"));
        card.append(picker.as(gtk.Widget));
        const slider = w.row(10);
        slider.append(w.icon("pearl-display-brightness-symbolic").as(gtk.Widget));
        const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
        scale.setDrawValue(0);
        scale.setDigits(0);
        scale.as(gtk.Widget).setHexpand(1);
        w.name(scale.as(gtk.Widget), @import("i18n").dtr("pearl", "Display brightness"));
        slider.append(scale.as(gtk.Widget));
        const value = w.label("", "pearl-secondary");
        value.as(gtk.Widget).setHexpand(0);
        slider.append(value.as(gtk.Widget));
        card.append(slider.as(gtk.Widget));
        const status = w.label("", "pearl-secondary");
        status.setWrap(1);
        card.append(status.as(gtk.Widget));
        const screen = w.wrappingButton(@import("i18n").dtr("pearl", "Turn off display"));
        card.append(screen.as(gtk.Widget));
        screen.as(gtk.Widget).setVisible(@intFromBool(idle != null));
        host.append(card.as(gtk.Widget));
        self.* = .{ .owner = owner, .power = power, .idle = idle, .picker = picker, .scale = scale, .value = value, .status = status, .screen = screen };
        @import("focus_state.zig").tag(self.scale.as(gtk.Widget), "quick-brightness", .{});
        self.connections[0] = object.Object.signals.notify.connect(picker.as(object.Object), *View, selected, self, .{ .detail = "selected" });
        self.connections[1] = gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *View, changed, self, .{});
        self.connections[2] = gtk.Button.signals.clicked.connect(screen, *View, screenClicked, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.power.releaseView(self.owner);
        object.signalHandlerDisconnect(self.picker.as(object.Object), self.connections[0]);
        object.signalHandlerDisconnect(self.scale.as(object.Object), self.connections[1]);
        object.signalHandlerDisconnect(self.screen.as(object.Object), self.connections[2]);
        std.heap.c_allocator.destroy(self);
    }
    pub fn update(self: *View) void {
        self.updating = true;
        defer self.updating = false;
        var hash = std.hash.Wyhash.init(0);
        for (self.power.displays.slice()) |d| {
            hash.update(d.id.slice());
            hash.update(d.name.slice());
            hash.update(d.output.slice());
        }
        const signature = hash.final();
        if (signature != self.signature) {
            const names = gtk.StringList.new(null);
            defer names.unref();
            for (self.power.displays.slice()) |d| {
                var buf: [300]u8 = undefined;
                names.append(std.mem.printSentinel(&buf, "{s}{s}{s}", .{ d.name.slice(), if (d.output.len != 0 and !std.mem.eql(u8, d.name.slice(), d.output.slice())) " · " else "", if (!std.mem.eql(u8, d.name.slice(), d.output.slice())) d.output.slice() else "" }, 0) catch d.name.z());
            }
            self.picker.setModel(names.as(gio.ListModel));
            self.signature = signature;
        }
        for (self.power.displays.slice(), 0..) |d, i| if (std.mem.eql(u8, d.id.slice(), self.power.selected_display.slice())) {
            self.picker.setSelected(@intCast(i));
        };
        const d = self.power.selectedDisplay();
        var awake = true;
        if (self.idle) |idle| {
            const output = if (d) |device| idle.findOutput(device.output.slice()) else null;
            self.screen.as(gtk.Widget).setSensitive(@intFromBool(output != null and output.?.power != null and output.?.mode != null and idle.notifier != null and idle.seat != null and self.power.session_active and !self.power.preparing));
            awake = output == null or output.?.mode != .off;
            self.screen.setLabel(if (awake) @import("i18n").dtr("pearl", "Turn off display") else @import("i18n").dtr("pearl", "Restore display"));
        }
        self.scale.as(gtk.Widget).setSensitive(@intFromBool(self.power.brightnessAvailable() and awake));
        if (d) |device| {
            if (device.wanted) |wanted| self.scale.as(gtk.Range).setValue(@floatFromInt(wanted)) else if (!device.pending) self.scale.as(gtk.Range).setValue(@floatFromInt(device.percent()));
            var buf: [32]u8 = undefined;
            self.value.setText(if (device.maximum == 0) "—" else std.mem.printSentinel(&buf, "{d:.0}%", .{self.scale.as(gtk.Range).getValue()}, 0) catch "");
        } else self.value.setText("—");
        var status_buffer: [512]u8 = undefined;
        self.status.setText(if (if (d) |device| device.write_error else null) |err| std.mem.printSentinel(&status_buffer, "{s}", .{err}, 0) catch "" else if (!awake) @import("i18n").dtr("pearl", "Screen is off. Move the mouse or press a key to wake.") else if (d) |device| if (device.reason) |reason| std.mem.printSentinel(&status_buffer, "{s}", .{reason}, 0) catch "" else if (device.pending or device.wanted != null) @import("i18n").dtr("pearl", "Applying brightness…") else if (!self.power.brightnessAvailable()) @import("i18n").dtr("pearl", "Brightness unavailable · an active session is required") else @import("i18n").dtr("pearl", "Changes apply to the selected display") else @import("i18n").dtr("pearl", "No supported display brightness controls"));
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        if (self.updating) return;
        const index = self.picker.getSelected();
        if (index < self.power.displays.len) self.power.selectDisplay(self.power.displays.items[index].id.slice()) catch {};
    }
    fn changed(range: *gtk.Range, self: *View) callconv(.c) void {
        if (!self.updating) self.power.setBrightness(@intFromFloat(range.getValue())) catch {};
    }
    fn screenClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        const idle = self.idle orelse return;
        const d = self.power.selectedDisplay() orelse return;
        if (!self.power.session_active or self.power.preparing) return;
        const output = idle.findOutput(d.output.slice()) orelse return;
        idle.setOutputOff(d.output.slice(), output.mode != .off) catch {
            self.power.err = "Display power control is unavailable.";
        };
        self.update();
    }
};
