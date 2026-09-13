const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const Audio = @import("../services/audio.zig");
const Power = @import("../services/power.zig").Power;
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
const Connection = struct { object: *object.Object, id: c_ulong };
const Row = struct { view: *View, key: Audio.Key, title: *gtk.Label, scale: *gtk.Scale, mute: *gtk.Button, route: *gtk.Button };
pub const View = struct {
    audio: *Audio.Audio,
    power: *Power,
    root: *gtk.Box,
    devices: *gtk.Box,
    audio_status: *gtk.Label,
    power_status: *gtk.Label,
    brightness_label: *gtk.Label,
    error_label: *gtk.Label,
    brightness: *gtk.Scale,
    profiles: [3]*gtk.Button,
    off: *gtk.Button,
    reboot: *gtk.Button,
    rows: [128]Row = undefined,
    count: usize = 0,
    updating: bool = false,
    connections: std.ArrayList(Connection) = .empty,
    row_connections: std.ArrayList(Connection) = .empty,
    armed: ?bool = null,
    armed_at: i64 = 0,
    armed_epoch: u64 = 0,
    profile_choices: [3]ProfileChoice = undefined,
    const ProfileChoice = struct { view: *View, index: u8 };
    pub fn create(host: *gtk.Box, audio: *Audio.Audio, power: *Power) !*View {
        const self = try a.create(View);
        const root = w.column(16);
        host.append(root.as(gtk.Widget));
        self.* = .{ .audio = audio, .power = power, .root = root, .devices = undefined, .audio_status = undefined, .power_status = undefined, .brightness_label = undefined, .error_label = undefined, .brightness = undefined, .profiles = undefined, .off = undefined, .reboot = undefined };
        const sound = w.card();
        root.append(sound.as(gtk.Widget));
        sound.append(w.label(tr("Sound", "Klang"), "pearl-card-title").as(gtk.Widget));
        self.audio_status = w.label("", "pearl-secondary");
        self.audio_status.setWrap(1);
        sound.append(self.audio_status.as(gtk.Widget));
        self.devices = w.column(12);
        const expander = gtk.Expander.new(tr("Output, input and applications", "Ausgabe, Eingabe und Anwendungen"));
        expander.setChild(self.devices.as(gtk.Widget));
        expander.setExpanded(1);
        sound.append(expander.as(gtk.Widget));
        const power_card = w.card();
        root.append(power_card.as(gtk.Widget));
        power_card.append(w.label(tr("Power and brightness", "Energie und Helligkeit"), "pearl-card-title").as(gtk.Widget));
        self.power_status = w.label("", "pearl-secondary");
        self.power_status.setWrap(1);
        power_card.append(self.power_status.as(gtk.Widget));
        self.brightness_label = w.label("", null);
        power_card.append(self.brightness_label.as(gtk.Widget));
        self.brightness = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
        self.brightness.setDrawValue(1);
        self.brightness.setDigits(0);
        self.brightness.as(gtk.Widget).setTooltipText(tr("Display brightness", "Bildschirmhelligkeit"));
        power_card.append(self.brightness.as(gtk.Widget));
        self.remember(self.brightness.as(object.Object), gtk.Range.signals.value_changed.connect(self.brightness.as(gtk.Range), *View, brightnessChanged, self, .{}), false);
        const profile_box = w.row(8);
        power_card.append(profile_box.as(gtk.Widget));
        for (&self.profiles, 0..) |*button, i| {
            button.* = gtk.Button.newWithLabel(Power.profile_names[i]);
            self.profile_choices[i] = .{ .view = self, .index = @intCast(i) };
            profile_box.append(button.*.as(gtk.Widget));
            self.remember(button.*.as(object.Object), gtk.Button.signals.clicked.connect(button.*, *ProfileChoice, profileClicked, &self.profile_choices[i], .{}), false);
        }
        const actions = w.row(8);
        power_card.append(actions.as(gtk.Widget));
        self.off = gtk.Button.newWithLabel(tr("Power off…", "Ausschalten…"));
        self.reboot = gtk.Button.newWithLabel(tr("Restart…", "Neu starten…"));
        for ([_]*gtk.Button{ self.off, self.reboot }) |button| {
            actions.append(button.as(gtk.Widget));
            self.remember(button.as(object.Object), gtk.Button.signals.clicked.connect(button, *View, powerClicked, self, .{}), false);
        }
        const cancel = gtk.Button.newWithLabel(tr("Cancel", "Abbrechen"));
        actions.append(cancel.as(gtk.Widget));
        self.remember(cancel.as(object.Object), gtk.Button.signals.clicked.connect(cancel, *View, cancelClicked, self, .{}), false);
        const sleep = w.label(tr("Suspend will be available after secure session locking is connected.", "Bereitschaft wird verfügbar, sobald die sichere Sitzungssperre verbunden ist."), "pearl-secondary");
        sleep.setWrap(1);
        power_card.append(sleep.as(gtk.Widget));
        self.error_label = w.label("", "pearl-secondary");
        self.error_label.setWrap(1);
        root.append(self.error_label.as(gtk.Widget));
        power.panel(true);
        self.update();
        return self;
    }
    fn remember(self: *View, obj: *object.Object, id: c_ulong, row: bool) void {
        const list = if (row) &self.row_connections else &self.connections;
        list.append(a, .{ .object = obj, .id = id }) catch @panic("OOM");
    }
    fn disconnect(list: *std.ArrayList(Connection)) void {
        for (list.items) |c| object.signalHandlerDisconnect(c.object, c.id);
        list.clearRetainingCapacity();
    }
    pub fn destroy(self: *View) void {
        self.power.panel(false);
        disconnect(&self.connections);
        disconnect(&self.row_connections);
        self.connections.deinit(a);
        self.row_connections.deinit(a);
        a.destroy(self);
    }
    fn rebuild(self: *View) void {
        disconnect(&self.row_connections);
        while (self.devices.as(gtk.Widget).getFirstChild()) |child| self.devices.remove(child);
        self.count = self.audio.count;
        for (self.audio.devices[0..self.count], 0..) |d, i| {
            const row = &self.rows[i];
            const box = w.column(4);
            self.devices.append(box.as(gtk.Widget));
            const title = w.label(d.label.z(), null);
            title.setEllipsize(.end);
            title.setXalign(0);
            box.append(title.as(gtk.Widget));
            const controls = w.row(8);
            box.append(controls.as(gtk.Widget));
            const scale = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
            scale.setDrawValue(1);
            scale.setDigits(0);
            scale.as(gtk.Widget).setHexpand(1);
            controls.append(scale.as(gtk.Widget));
            const mute = gtk.Button.newWithLabel(tr("Mute", "Stumm"));
            controls.append(mute.as(gtk.Widget));
            const route = gtk.Button.newWithLabel(if (d.key.kind == .sink or d.key.kind == .source) tr("Use default", "Als Standard") else tr("Move to default", "Zum Standard verschieben"));
            controls.append(route.as(gtk.Widget));
            row.* = .{ .view = self, .key = d.key, .title = title, .scale = scale, .mute = mute, .route = route };
            self.remember(scale.as(object.Object), gtk.Range.signals.value_changed.connect(scale.as(gtk.Range), *Row, volumeChanged, row, .{}), true);
            self.remember(mute.as(object.Object), gtk.Button.signals.clicked.connect(mute, *Row, muteClicked, row, .{}), true);
            self.remember(route.as(object.Object), gtk.Button.signals.clicked.connect(route, *Row, routeClicked, row, .{}), true);
        }
    }
    pub fn update(self: *View) void {
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
        const sound_text = if (!self.audio.ready) tr("Audio unavailable", "Audio nicht verfügbar") else if (self.audio.count == 0) tr("No audio devices", "Keine Audiogeräte") else std.fmt.bufPrintZ(&buffer, "{s}: {s}\n{s}: {s}{s}", .{ tr("Output", "Ausgabe"), if (self.audio.default(.sink)) |d| d.label.slice() else "—", tr("Input", "Eingabe"), if (self.audio.default(.source)) |d| d.label.slice() else "—", if (self.audio.active != null or self.audio.queue.len > 0) tr(" · Applying…", " · Wird angewendet…") else "" }) catch "Audio";
        self.audio_status.setText(sound_text);
        for (self.rows[0..self.count], self.audio.devices[0..self.count]) |*row, d| {
            const kind = if (d.key.kind == .sink) tr("Output", "Ausgabe") else if (d.key.kind == .source) tr("Input", "Eingabe") else if (d.key.kind == .playback) tr("Playback", "Wiedergabe") else tr("Recording", "Aufnahme");
            row.title.setText(std.fmt.bufPrintZ(&buffer, "{s} · {s}", .{ kind, d.label.slice() }) catch d.label.z());
            row.scale.as(gtk.Widget).setTooltipText(row.title.getText());
            var pending = false;
            if (self.audio.active) |active| pending = std.meta.eql(active.key, row.key);
            for (self.audio.queue.items[0..self.audio.queue.len]) |write| if (std.meta.eql(write.key, row.key)) {
                pending = true;
            };
            if (!pending) row.scale.as(gtk.Range).setValue(@floatFromInt(d.volume));
            row.scale.as(gtk.Widget).setSensitive(@intFromBool(d.writable));
            row.mute.setLabel(if (d.mute) tr("Unmute", "Ton ein") else tr("Mute", "Stumm"));
            const device = if (d.key.kind == .sink or d.key.kind == .playback) self.audio.default(.sink) else self.audio.default(.source);
            const is_default = if (device) |target| target.key.index == d.key.index and target.key.kind == d.key.kind else false;
            row.route.as(gtk.Widget).setSensitive(@intFromBool(!is_default and (d.key.kind == .sink or d.key.kind == .source or device != null)));
        }
        const power = self.power;
        const battery = if (power.battery_present) std.fmt.bufPrintZ(&buffer, "{d:.0}% · {s}", .{ power.percentage, if (power.battery_state == 1) tr("Charging", "Lädt") else if (power.battery_state == 2) tr("On battery", "Akkubetrieb") else if (power.battery_state == 4) tr("Fully charged", "Vollständig geladen") else tr("Battery", "Akku") }) catch "Battery" else tr("No battery reported", "Kein Akku gemeldet");
        self.power_status.setText(battery);
        self.brightness_label.setText(if (power.backlight.maximum == 0) tr("Brightness unavailable · no supported backlight", "Helligkeit nicht verfügbar · keine unterstützte Hintergrundbeleuchtung") else std.fmt.bufPrintZ(&buffer, "{s} · {s}{s}", .{ tr("Brightness", "Helligkeit"), power.backlight.name.slice(), if (power.brightness_pending or power.brightness_wanted != null) tr(" · Applying…", " · Wird angewendet…") else "" }) catch "Brightness");
        self.brightness_label.setWrap(1);
        self.brightness.as(gtk.Widget).setSensitive(@intFromBool(power.brightnessAvailable()));
        if (!power.brightness_pending and power.brightness_wanted == null) self.brightness.as(gtk.Range).setValue(@floatFromInt(power.backlight.percent()));
        for (self.profiles, 0..) |button, i| {
            button.as(gtk.Widget).setSensitive(@intFromBool(power.profiles[i]));
            if (std.mem.eql(u8, power.profile.slice(), Power.profile_names[i])) button.as(gtk.Widget).addCssClass("pearl-selected") else button.as(gtk.Widget).removeCssClass("pearl-selected");
        }
        if (self.armed_epoch != power.epoch() or glib.getMonotonicTime() - self.armed_at > 10_000_000) self.armed = null;
        self.off.setLabel(if (self.armed != null and !self.armed.?) tr("Confirm power off", "Ausschalten bestätigen") else tr("Power off…", "Ausschalten…"));
        self.reboot.setLabel(if (self.armed != null and self.armed.?) tr("Confirm restart", "Neustart bestätigen") else tr("Restart…", "Neu starten…"));
        self.off.as(gtk.Widget).setSensitive(@intFromBool(power.can_off and !power.action_pending and !power.preparing));
        self.reboot.as(gtk.Widget).setSensitive(@intFromBool(power.can_reboot and !power.action_pending and !power.preparing));
        self.error_label.setText(if (self.audio.err) |e| std.fmt.bufPrintZ(&buffer, "{s}", .{e}) catch "Audio error" else if (power.err) |e| std.fmt.bufPrintZ(&buffer, "{s}", .{e}) catch "Power error" else if (power.profile_pending or power.profile_wanted != null) tr("Applying power profile…", "Energieprofil wird angewendet…") else if (power.action_pending) tr("Waiting for the power service…", "Warten auf den Energiedienst…") else power.degraded.z());
    }
    fn volumeChanged(range: *gtk.Range, row: *Row) callconv(.c) void {
        if (row.view.updating) return;
        row.view.audio.request(.{ .key = row.key, .volume = @intFromFloat(range.getValue()) }) catch {};
    }
    fn muteClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        const device = row.view.audio.find(row.key) orelse return;
        row.view.audio.request(.{ .key = row.key, .mute = !device.mute }) catch {};
    }
    fn routeClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        var write: Audio.Write = .{ .key = row.key };
        if (row.key.kind == .sink or row.key.kind == .source) write.default = true else {
            const device = row.view.audio.default(if (row.key.kind == .playback) .sink else .source) orelse return;
            write.move = device.key.index;
        }
        row.view.audio.request(write) catch {};
    }
    fn brightnessChanged(range: *gtk.Range, self: *View) callconv(.c) void {
        if (!self.updating) self.power.setBrightness(@intFromFloat(range.getValue())) catch {};
    }
    fn profileClicked(_: *gtk.Button, choice: *ProfileChoice) callconv(.c) void {
        choice.view.power.setProfile(choice.index) catch {};
    }
    fn cancelClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.armed = null;
        self.update();
    }
    fn powerClicked(button: *gtk.Button, self: *View) callconv(.c) void {
        const reboot = button == self.reboot;
        const now = glib.getMonotonicTime();
        if (self.armed != null and self.armed.? == reboot and self.armed_epoch == self.power.epoch() and now - self.armed_at <= 10_000_000) {
            self.armed = null;
            self.power.powerAction(reboot) catch {};
            self.update();
        } else {
            self.armed = reboot;
            self.armed_at = now;
            self.armed_epoch = self.power.epoch();
            self.update();
        }
    }
};
