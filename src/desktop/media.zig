const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const m = @import("../services/mpris.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
const Button = struct { view: *View, action: m.Action, generation: u64 = 0, track: @import("../services/policy.zig").Text(512) = .{}, widget: *gtk.Button };
pub const View = struct {
    probe_focus: ?*gtk.Widget = null,
    service: *m.Media,
    title: *gtk.Label,
    artist: *gtk.Label,
    state: *gtk.Label,
    progress: *gtk.Scale,
    image: *gtk.Image,
    choices: [8]Button = undefined,
    buttons: [5]Button = undefined,
    generation: u64 = 0,
    updating: bool = false,
    desired_position: ?f64 = null,
    track: @import("../services/policy.zig").Text(512) = .{},
    timer: c_uint = 0,
    pub fn create(host: *gtk.Box, media: *m.Media) !*View {
        const self = try a.create(View);
        const card = w.card();
        card.as(gtk.Widget).addCssClass("pearl-media-card");
        card.append(w.label(tr("Now playing", "Aktuelle Wiedergabe"), "pearl-card-title").as(gtk.Widget));
        const choices = w.flow(2);
        card.append(choices.as(gtk.Widget));
        const image = w.icon("pearl-media-symbolic");
        image.setPixelSize(96);
        image.as(gtk.Widget).setHalign(.center);
        card.append(image.as(gtk.Widget));
        const title = w.label("", "pearl-card-title");
        title.setEllipsize(.end);
        title.setLines(2);
        card.append(title.as(gtk.Widget));
        const artist = w.label("", "pearl-secondary");
        artist.setEllipsize(.end);
        artist.setLines(1);
        card.append(artist.as(gtk.Widget));
        const progress = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
        progress.setDrawValue(0);
        w.name(progress.as(gtk.Widget), tr("Playback position", "Wiedergabeposition"));
        card.append(progress.as(gtk.Widget));
        const state = w.label("", "pearl-secondary");
        card.append(state.as(gtk.Widget));
        self.* = .{ .service = media, .title = title, .artist = artist, .state = state, .progress = progress, .image = image };
        for (&self.choices) |*choice| {
            const button = gtk.Button.newWithLabel("");
            choice.* = .{ .view = self, .action = .select, .widget = button };
            _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, choice, .{});
            choices.insert(button.as(gtk.Widget), -1);
            if (@import("gobject2").ext.cast(gtk.Label, button.getChild().?)) |label| {
                label.setEllipsize(.end);
                label.setMaxWidthChars(18);
            }
        }
        const controls = w.row(8);
        controls.as(gtk.Widget).setHalign(.center);
        card.append(controls.as(gtk.Widget));
        for (&self.buttons, [_]m.Action{ .previous, .play_pause, .next, .stop, .seek }, [_][:0]const u8{ "Previous", "Play", "Next", "Stop", "Seek" }) |*b, action, label| {
            const button = gtk.Button.newWithLabel(if (action == .previous) "‹" else if (action == .next) "›" else label);
            w.name(button.as(gtk.Widget), label);
            button.as(gtk.Widget).setTooltipText(label);
            b.* = .{ .view = self, .action = action, .widget = button };
            _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, b, .{});
            controls.append(button.as(gtk.Widget));
        }
        _ = gtk.Range.signals.value_changed.connect(progress.as(gtk.Range), *View, positionChanged, self, .{});
        host.append(card.as(gtk.Widget));
        media.view(true);
        self.update();
        return self;
    }
    pub fn probe(self: *View, window: *gtk.Window) void {
        const focus = window.getFocus();
        if (focus == self.probe_focus) return;
        self.probe_focus = focus;
        if (focus == self.progress.as(gtk.Widget)) {
            std.log.info("event=session-focus target=media-position", .{});
            return;
        }
        for (&self.buttons) |*button| if (focus == button.widget.as(gtk.Widget)) {
            std.log.info("event=session-focus target=media-{s}", .{@tagName(button.action)});
            return;
        };
        std.log.info("event=session-focus target=other", .{});
    }
    pub fn destroy(self: *View) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.service.view(false);
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        self.updating = true;
        defer self.updating = false;
        var count: usize = 0;
        for (&self.service.players) |*player| if (player.ready) {
            const choice = &self.choices[count];
            choice.generation = player.generation;
            choice.widget.setLabel(if (player.identity.len > 0) player.identity.z() else player.name.z());
            choice.widget.as(gtk.Widget).getParent().?.setVisible(1);
            choice.widget.as(gtk.Widget).setVisible(1);
            count += 1;
        };
        for (self.choices[count..]) |choice| {
            choice.widget.as(gtk.Widget).getParent().?.setVisible(0);
            choice.widget.as(gtk.Widget).setVisible(0);
        }
        const p = self.service.current();
        const track = if (p) |player| player.track else @as(@import("../services/policy.zig").Text(512), .{});
        if (self.generation != (if (p) |player| player.generation else 0) or !std.mem.eql(u8, self.track.slice(), track.slice())) self.desired_position = null;
        self.track = track;
        self.generation = if (p) |player| player.generation else 0;
        const playing = if (p) |player| std.mem.eql(u8, player.playback.slice(), "Playing") else false;
        self.title.setText(if (p) |player| (if (player.title.len > 0) player.title.z() else "Untitled track") else tr("Nothing playing", "Keine Wiedergabe"));
        self.artist.setText(if (p) |player| player.artist.z() else tr("Open a media player to get started", "Öffne einen Mediaplayer"));
        if (self.service.art.image) |image| self.image.setFromPixbuf(image) else self.image.setFromIconName("pearl-media-symbolic");
        self.image.setPixelSize(96);
        for (&self.buttons) |*button| {
            button.generation = self.generation;
            button.track = if (p) |player| player.track else .{};
            const allowed = if (p) |player| player.control and !player.busy and switch (button.action) {
                .previous => player.previous,
                .next => player.next,
                .play_pause => if (playing) player.pause else player.play,
                .seek => player.seek and player.length > 0 and player.track.len > 0,
                else => true,
            } else false;
            button.widget.as(gtk.Widget).setSensitive(@intFromBool(allowed));
            if (button.action == .play_pause) {
                button.widget.setLabel(if (playing) "Pause" else "Play");
                w.name(button.widget.as(gtk.Widget), if (playing) "Pause" else "Play");
            }
        }
        self.progress.as(gtk.Widget).setSensitive(@intFromBool(if (p) |player| player.control and player.seek and player.length > 0 and !player.busy else false));
        self.tickProgress();
        if (self.timer != 0 and !playing) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        if (self.timer == 0 and playing) self.timer = glib.timeoutAdd(1000, tick, self);
    }
    fn tickProgress(self: *View) void {
        const was_updating = self.updating;
        self.updating = true;
        defer self.updating = was_updating;
        const p = self.service.current();
        if (p) |player| {
            const pos = player.progress();
            // Keep a focused slider stable until the explicit Seek button is used.
            if (self.desired_position == null) self.progress.as(gtk.Range).setValue(if (player.length > 0) @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(player.length)) * 100 else 0);
            var buf: [120]u8 = undefined;
            self.state.setText(if (self.service.err) |err| blk: {
                const text = @import("../services/policy.zig").Text(120);
                var s: text = .{};
                s.set(err);
                break :blk std.fmt.bufPrintZ(&buf, "{s}", .{s.slice()}) catch unreachable;
            } else std.fmt.bufPrintZ(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ @as(u64, @intCast(@divTrunc(pos, 60000000))), @as(u64, @intCast(@mod(@divTrunc(pos, 1000000), 60))), @as(u64, @intCast(@divTrunc(player.length, 60000000))), @as(u64, @intCast(@mod(@divTrunc(player.length, 1000000), 60))) }) catch "");
        } else {
            self.progress.as(gtk.Range).setValue(0);
            self.state.setText("");
        }
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.tickProgress();
        return 1;
    }
    fn positionChanged(range: *gtk.Range, self: *View) callconv(.c) void {
        if (!self.updating) self.desired_position = range.getValue();
    }
    fn clicked(_: *gtk.Button, button: *Button) callconv(.c) void {
        const self = button.view;
        const p = self.service.find(button.generation) orelse return;
        if (button.action == .seek and !std.mem.eql(u8, button.track.slice(), p.track.slice())) return;
        const position: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(std.math.maxInt(i64) / 2)), @as(f64, @floatFromInt(p.length)) * self.progress.as(gtk.Range).getValue() / 100));
        self.service.act(button.generation, button.action, position) catch return;
        if (button.action == .seek) self.desired_position = null;
    }
};
