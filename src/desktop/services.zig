const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Audio = @import("../services/audio.zig");
const Power = @import("../services/power.zig").Power;
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const chargeState = @import("text.zig").chargeState;
const presentation = @import("../services/power_presentation.zig");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
const focus_state = @import("focus_state.zig");
const Connection = struct { object: *object.Object, id: c_ulong };
const Row = struct { view: *Sound, key: Audio.Key, title: *gtk.Label, scale: *gtk.Scale, mute: *gtk.Button, route: *gtk.Button, muted: bool = false };
pub const Sound = struct {
    audio: *Audio.Audio,
    devices: *gtk.Box,
    audio_status: *gtk.Label,
    state_icon: *gtk.Image,
    rows: [128]Row = undefined,
    count: usize = 0,
    updating: bool = false,
    connections: std.ArrayList(Connection) = .empty,
    row_connections: std.ArrayList(Connection) = .empty,
    pub fn create(host: *gtk.Box, audio: *Audio.Audio) !*Sound {
        const self = try a.create(Sound);
        self.* = .{ .audio = audio, .devices = undefined, .audio_status = undefined, .state_icon = undefined };
        const root = host;
        const sound = w.card();
        root.append(sound.as(gtk.Widget));
        sound.append(w.label(@import("i18n").dtr("pearl", "Sound"), "pearl-card-title").as(gtk.Widget));
        const state_row = w.row(10);
        state_row.as(gtk.Widget).addCssClass("pearl-state");
        self.state_icon = w.icon("pearl-emblem-ok-symbolic");
        self.state_icon.as(gtk.Widget).addCssClass("pearl-state-icon");
        state_row.append(self.state_icon.as(gtk.Widget));
        self.audio_status = w.label("", "pearl-secondary");
        self.audio_status.setWrap(1);
        state_row.append(self.audio_status.as(gtk.Widget));
        sound.append(state_row.as(gtk.Widget));
        self.devices = w.column(12);
        const expander = gtk.Expander.new(@import("i18n").dtr("pearl", "Output, input and applications"));
        const expander_label = w.label(@import("i18n").dtr("pearl", "Output, input and applications"), "pearl-section-title");
        expander.setLabelWidget(expander_label.as(gtk.Widget));
        focus_state.tag(expander.as(gtk.Widget), "audio-expander", .{});
        expander.setChild(self.devices.as(gtk.Widget));
        expander.setExpanded(1);
        sound.append(expander.as(gtk.Widget));
        self.update();
        return self;
    }
    fn remember(self: *Sound, obj: *object.Object, id: c_ulong, row: bool) void {
        const list = if (row) &self.row_connections else &self.connections;
        list.append(a, .{ .object = obj, .id = id }) catch @panic("OOM");
    }
    fn disconnect(list: *std.ArrayList(Connection)) void {
        for (list.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        list.clearRetainingCapacity();
    }
    pub fn destroy(self: *Sound) void {
        disconnect(&self.connections);
        disconnect(&self.row_connections);
        self.connections.deinit(a);
        self.row_connections.deinit(a);
        a.destroy(self);
    }
    fn rebuild(self: *Sound) void {
        disconnect(&self.row_connections);
        while (self.devices.as(gtk.Widget).getFirstChild()) |child| self.devices.remove(child);
        self.count = self.audio.count;
        for (self.audio.devices[0..self.count], 0..) |d, i| {
            const row = &self.rows[i];
            const box = w.column(6);
            box.as(gtk.Widget).addCssClass("pearl-row-card");
            self.devices.append(box.as(gtk.Widget));
            const head = w.row(10);
            box.append(head.as(gtk.Widget));
            head.append(w.icon(if (d.key.kind == .source or d.key.kind == .recording) "pearl-microphone-symbolic" else "pearl-audio-volume-high-symbolic").as(gtk.Widget));
            const title = w.label(d.label.z(), null);
            title.setEllipsize(.end);
            title.setXalign(0);
            head.append(title.as(gtk.Widget));
            const mute = w.iconButton("pearl-audio-volume-high-symbolic", @import("i18n").dtr("pearl", "Mute"));
            head.append(mute.as(gtk.Widget));
            const controls = w.row(8);
            box.append(controls.as(gtk.Widget));
            const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
            scale.setDrawValue(0);
            scale.setDigits(0);
            scale.as(gtk.Widget).setHexpand(1);
            controls.append(scale.as(gtk.Widget));
            const route = w.wrappingButton(if (d.key.kind == .sink or d.key.kind == .source) @import("i18n").dtr("pearl", "Set default") else @import("i18n").dtr("pearl", "Move to default"));
            route.as(gtk.Widget).addCssClass("pearl-pill");
            controls.append(route.as(gtk.Widget));
            for ([_]*gtk.Widget{ scale.as(gtk.Widget), mute.as(gtk.Widget), route.as(gtk.Widget) }, 0..) |widget, control| focus_state.tag(widget, "audio:{d}:{s}:{d}:{d}", .{ d.key.generation, @tagName(d.key.kind), d.key.index, control });
            row.* = .{ .view = self, .key = d.key, .title = title, .scale = scale, .mute = mute, .route = route };
            self.remember(scale.as(object.Object), gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *Row, volumeChanged, row, .{}), true);
            self.remember(mute.as(object.Object), gtk.Button.signals.clicked.connect(mute, *Row, muteClicked, row, .{}), true);
            self.remember(route.as(object.Object), gtk.Button.signals.clicked.connect(route, *Row, routeClicked, row, .{}), true);
        }
    }
    pub fn update(self: *Sound) void {
        self.updating = true;
        defer self.updating = false;
        var different = self.count != self.audio.count;
        if (!different) for (self.audio.devices[0..self.count], self.rows[0..self.count]) |d, r| {
            if (!std.meta.eql(d.key, r.key)) {
                different = true;
                break;
            }
        };
        if (different) self.rebuild();
        var buffer: [1024]u8 = undefined;
        const sound_text = if (!self.audio.ready) @import("i18n").dtr("pearl", "Audio unavailable") else if (self.audio.count == 0) @import("i18n").dtr("pearl", "No audio devices") else std.mem.printSentinel(&buffer, "{s}: {s}\n{s}: {s}{s}", .{ @import("i18n").dtr("pearl", "Output"), if (self.audio.default(.sink)) |d| d.label.slice() else "—", @import("i18n").dtr("pearl", "Input"), if (self.audio.default(.source)) |d| d.label.slice() else "—", if (self.audio.active != null or self.audio.queue.len > 0 or self.audio.feedback != null) @import("i18n").dtr("pearl", " · Applying…") else "" }, 0) catch "Audio";
        self.audio_status.setText(sound_text);
        if (self.audio.err) |message| self.audio_status.setText(std.mem.printSentinel(&buffer, "{s}", .{message}, 0) catch "Audio unavailable");
        self.state_icon.setFromIconName(if (self.audio.err != null or !self.audio.ready) "pearl-dialog-warning-symbolic" else "pearl-emblem-ok-symbolic");
        for (self.rows[0..self.count], self.audio.devices[0..self.count]) |*row, d| {
            const kind = if (d.key.kind == .sink) @import("i18n").dtr("pearl", "Output") else if (d.key.kind == .source) @import("i18n").dtr("pearl", "Input") else if (d.key.kind == .playback) @import("i18n").dtr("pearl", "Playback") else @import("i18n").dtr("pearl", "Recording");
            row.title.setText(std.mem.printSentinel(&buffer, "{s} · {s}", .{ kind, d.label.slice() }, 0) catch d.label.z());
            row.scale.as(gtk.Widget).setTooltipText(row.title.getText());
            const pending = self.audio.active != null or self.audio.queue.len > 0 or self.audio.feedback != null;
            if (!pending) row.scale.as(gtk.Range).setValue(@floatFromInt(d.volume));
            row.scale.as(gtk.Widget).setSensitive(@intFromBool(d.writable));
            if (row.muted != d.mute) {
                row.muted = d.mute;
                row.mute.setChild(w.icon(if (d.mute) "pearl-audio-volume-muted-symbolic" else "pearl-audio-volume-high-symbolic").as(gtk.Widget));
                const mute_name = if (d.mute) @import("i18n").dtr("pearl", "Unmute") else @import("i18n").dtr("pearl", "Mute");
                row.mute.as(gtk.Widget).setTooltipText(mute_name);
                w.name(row.mute.as(gtk.Widget), mute_name);
            }
            const device = if (d.key.kind == .sink or d.key.kind == .playback) self.audio.default(.sink) else self.audio.default(.source);
            const is_default = if (device) |target| target.key.index == d.key.index and target.key.kind == d.key.kind else false;
            row.route.as(gtk.Widget).setSensitive(@intFromBool(!is_default and (d.key.kind == .sink or d.key.kind == .source or device != null)));
        }
    }
    fn volumeChanged(range: *gtk.Range, row: *Row) callconv(.c) void {
        if (row.view.updating) return;
        row.view.audio.request(.{ .key = row.key, .volume = @intFromFloat(range.getValue()) }) catch {};
    }
    fn muteClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        row.view.audio.request(.{ .key = row.key, .mute = !row.view.audio.desiredMute(row.key) }) catch {};
    }
    fn routeClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        var write: Audio.Write = .{ .key = row.key };
        if (row.key.kind == .sink or row.key.kind == .source) write.default = true else {
            const device = row.view.audio.default(if (row.key.kind == .playback) .sink else .source) orelse return;
            write.move = device.key.index;
        }
        row.view.audio.request(write) catch {};
    }
};

pub const PowerView = struct {
    owner: @import("../services/view_ownership.zig").Owner,
    power: *Power,
    power_status: *gtk.Label,
    battery_icon: *gtk.Image,
    profile_status: *gtk.Label,
    brightness_label: *gtk.Label,
    error_label: *gtk.Label,
    brightness: *gtk.Scale,
    brightness_view: ?*@import("brightness_controls.zig").View = null,
    profiles: [3]*gtk.Button,
    actions: *PowerActions,
    updating: bool = false,
    probe_focus: ?*gtk.Widget = null,
    connections: std.ArrayList(Connection) = .empty,
    profile_choices: [3]ProfileChoice = undefined,
    const ProfileChoice = struct { view: *PowerView, index: u8 };
    pub fn create(host: *gtk.Box, power: *Power) !*PowerView {
        const owner = try power.acquireView();
        errdefer power.releaseView(owner);
        const self = try a.create(PowerView);
        self.* = .{ .owner = owner, .power = power, .power_status = undefined, .battery_icon = undefined, .profile_status = undefined, .brightness_label = undefined, .error_label = undefined, .brightness = undefined, .profiles = undefined, .actions = undefined };
        errdefer {
            for (self.connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
            self.connections.deinit(a);
            a.destroy(self);
        }
        const root = host;
        const power_card = w.card();
        root.append(power_card.as(gtk.Widget));
        power_card.append(w.label(@import("i18n").dtr("pearl", "Power and brightness"), "pearl-card-title").as(gtk.Widget));
        const state_row = w.row(10);
        state_row.as(gtk.Widget).addCssClass("pearl-state");
        const battery_icon = w.icon("pearl-battery-symbolic");
        battery_icon.as(gtk.Widget).addCssClass("pearl-state-icon");
        state_row.append(battery_icon.as(gtk.Widget));
        self.battery_icon = battery_icon;
        self.power_status = w.label("", "pearl-secondary");
        self.power_status.setWrap(1);
        state_row.append(self.power_status.as(gtk.Widget));
        power_card.append(state_row.as(gtk.Widget));
        self.brightness_view = try @import("brightness_controls.zig").View.create(power_card, power, null);
        self.brightness = self.brightness_view.?.scale;
        self.brightness_label = self.brightness_view.?.status;
        focus_state.tag(self.brightness.as(gtk.Widget), "brightness", .{});
        self.profile_status = w.label("", "pearl-secondary");
        power_card.append(self.profile_status.as(gtk.Widget));
        const profile_box = w.row(4);
        power_card.append(profile_box.as(gtk.Widget));
        for (&self.profiles, 0..) |*button, i| {
            button.* = w.wrappingButton(([_][*:0]const u8{ @import("i18n").dtr("pearl", "Power saver"), @import("i18n").dtr("pearl", "Balanced"), @import("i18n").dtr("pearl", "Performance") })[i]);
            button.*.as(gtk.Widget).setHexpand(1);
            button.*.as(gtk.Widget).addCssClass("pearl-pill");
            focus_state.tag(button.*.as(gtk.Widget), "profile:{d}", .{i});
            self.profile_choices[i] = .{ .view = self, .index = @intCast(i) };
            profile_box.append(button.*.as(gtk.Widget));
            self.remember(button.*.as(object.Object), gtk.Button.signals.clicked.connect(button.*, *ProfileChoice, profileClicked, &self.profile_choices[i], .{}), false);
        }
        self.actions = try PowerActions.create(power_card, power);
        self.actions.show_status = false;
        self.error_label = w.label("", "pearl-secondary");
        self.error_label.setWrap(1);
        root.append(self.error_label.as(gtk.Widget));
        self.update();
        return self;
    }
    fn remember(self: *PowerView, obj: *object.Object, id: c_ulong, _: bool) void {
        self.connections.append(a, .{ .object = obj, .id = id }) catch @panic("OOM");
    }
    pub fn destroy(self: *PowerView) void {
        if (self.brightness_view) |view| view.destroy();
        self.actions.destroy();
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        self.power.releaseView(self.owner);
        self.connections.deinit(a);
        a.destroy(self);
    }
    pub fn update(self: *PowerView) void {
        self.updating = true;
        defer self.updating = false;
        var buffer: [1024]u8 = undefined;
        const power = self.power;
        const percent = if (power.percentage_valid) power.percentage else null;
        self.battery_icon.setFromIconName(presentation.icon(power.battery_state, percent));
        // Sticky presence, and an unmeasured charge is named as unavailable rather
        // than printed as 0%. A service outage is reported separately via err.
        const battery = if (!power.battery_observed)
            @import("i18n").dtr("pearl", "No battery reported")
        else if (percent) |n|
            std.mem.printSentinel(&buffer, "{d:.0}% · {s}", .{ n, chargeState(power.battery_state) }, 0) catch chargeState(power.battery_state)
        else
            std.mem.printSentinel(&buffer, "{s} · {s}", .{ @import("i18n").dtr("pearl", "Charge unavailable"), chargeState(power.battery_state) }, 0) catch "Battery";
        self.power_status.setText(battery);
        self.brightness_view.?.update();
        self.profile_status.setText(if (!power.profiles[0] and !power.profiles[1] and !power.profiles[2]) @import("i18n").dtr("pearl", "Power profiles unavailable") else @import("i18n").dtr("pearl", "Power profile"));
        for (self.profiles, 0..) |button, i| {
            button.as(gtk.Widget).setSensitive(@intFromBool(power.profiles[i]));
            if (std.mem.eql(u8, power.profile.slice(), Power.profile_names[i])) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
        }
        self.actions.update();
        self.error_label.setText(if (power.err) |e| std.mem.printSentinel(&buffer, "{s}", .{e}, 0) catch "Power error" else if (power.profile_pending or power.profile_wanted != null) @import("i18n").dtr("pearl", "Applying power profile…") else if (power.action_pending) @import("i18n").dtr("pearl", "Waiting for the power service…") else power.degraded.z());
    }
    pub fn probe(self: *PowerView, window: *gtk.Window) void {
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        log.info("event=services-focus target={s}", .{if (focus == self.brightness.as(gtk.Widget)) "brightness" else if (focus == self.actions.off.as(gtk.Widget)) "power-off" else if (focus == self.actions.reboot.as(gtk.Widget)) "reboot" else "other"});
    }
    fn brightnessChanged(range: *gtk.Range, self: *PowerView) callconv(.c) void {
        if (!self.updating) self.power.setBrightness(@intFromFloat(range.getValue())) catch {};
    }
    fn profileClicked(_: *gtk.Button, choice: *ProfileChoice) callconv(.c) void {
        choice.view.power.setProfile(choice.index) catch {};
    }
};

/// Shared confirmation controls for the overview and the power page.
pub const PowerActions = struct {
    power: *Power,
    off: *gtk.Button,
    reboot: *gtk.Button,
    error_label: *gtk.Label,
    connections: std.ArrayList(Connection) = .empty,
    confirmation: @import("../services/policy.zig").Confirmation = .{},
    show_status: bool = true,

    pub fn create(host: *gtk.Box, power: *Power) !*PowerActions {
        const self = try a.create(PowerActions);
        self.* = .{ .power = power, .off = undefined, .reboot = undefined, .error_label = undefined };
        const actions = w.flow(3);
        host.append(actions.as(gtk.Widget));
        self.off = w.wrappingButton(@import("i18n").dtr("pearl", "Power off…"));
        self.reboot = w.wrappingButton(@import("i18n").dtr("pearl", "Restart…"));
        self.off.as(gtk.Widget).addCssClass("pearl-destructive");
        for ([_]*gtk.Button{ self.off, self.reboot }) |button| {
            button.as(gtk.Widget).addCssClass("pearl-pill");
            actions.append(button.as(gtk.Widget));
            self.remember(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *PowerActions, powerClicked, self, .{}), false);
        }
        focus_state.tag(self.off.as(gtk.Widget), "power-off", .{});
        focus_state.tag(self.reboot.as(gtk.Widget), "reboot", .{});
        const cancel = w.wrappingButton(@import("i18n").dtr("pearl", "Cancel"));
        cancel.as(gtk.Widget).addCssClass("pearl-pill");
        focus_state.tag(cancel.as(gtk.Widget), "power-cancel", .{});
        actions.insert(cancel.as(gtk.Widget), -1);
        self.remember(cancel.as(object.Object), gtk.Button.signals.clicked.connect(cancel, *PowerActions, cancelClicked, self, .{}), false);
        self.error_label = w.label("", "pearl-secondary");
        self.error_label.setWrap(1);
        host.append(self.error_label.as(gtk.Widget));
        self.update();
        return self;
    }
    fn remember(self: *PowerActions, obj: *object.Object, id: c_ulong, _: bool) void {
        self.connections.append(a, .{ .object = obj, .id = id }) catch @panic("OOM");
    }
    pub fn destroy(self: *PowerActions) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        self.connections.deinit(a);
        a.destroy(self);
    }
    pub fn update(self: *PowerActions) void {
        const power = self.power;
        self.off.as(gtk.Widget).setTooltipText(if (power.can_off) @import("i18n").dtr("pearl", "Power off after confirmation") else @import("i18n").dtr("pearl", "Power off is unavailable or requires permission"));
        self.reboot.as(gtk.Widget).setTooltipText(if (power.can_reboot) @import("i18n").dtr("pearl", "Restart after confirmation") else @import("i18n").dtr("pearl", "Restart is unavailable or requires permission"));
        _ = self.confirmation.valid(power.epoch(), glib.getMonotonicTime());
        self.off.setLabel(if (self.confirmation.action != null and !self.confirmation.action.?) @import("i18n").dtr("pearl", "Confirm power off") else @import("i18n").dtr("pearl", "Power off…"));
        self.reboot.setLabel(if (self.confirmation.action != null and self.confirmation.action.?) @import("i18n").dtr("pearl", "Confirm restart") else @import("i18n").dtr("pearl", "Restart…"));
        self.off.as(gtk.Widget).setSensitive(@intFromBool(power.can_off and !power.action_pending and !power.preparing));
        self.reboot.as(gtk.Widget).setSensitive(@intFromBool(power.can_reboot and !power.action_pending and !power.preparing));
        var buffer: [1024]u8 = undefined;
        self.error_label.setText(if (power.err) |e| std.mem.printSentinel(&buffer, "{s}", .{e}, 0) catch "Power error" else if (power.action_pending) @import("i18n").dtr("pearl", "Waiting for the power service…") else "");
        self.error_label.as(gtk.Widget).setVisible(@intFromBool(self.show_status and (power.err != null or power.action_pending)));
    }
    fn cancelClicked(_: *gtk.Button, self: *PowerActions) callconv(.c) void {
        self.confirmation.action = null;
        self.update();
    }
    fn powerClicked(button: *gtk.Button, self: *PowerActions) callconv(.c) void {
        const reboot = button == self.reboot;
        const now = glib.getMonotonicTime();
        const confirmed = self.confirmation.click(reboot, self.power.epoch(), now);
        if (@import("build_options").test_hooks) log.info("event=power-intent reboot={} confirmed={}", .{ reboot, confirmed });
        if (confirmed) self.power.powerAction(reboot) catch {
            self.power.err = "Power action unavailable. Review the current service state.";
            self.power.changed(self.power.context, .failure);
        };
        self.update();
    }
};
