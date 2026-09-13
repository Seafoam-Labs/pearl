const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const m = @import("../services/mpris.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
const Button = struct { view: *View, action: m.Action, generation: u64 = 0, widget: *gtk.Button };
pub const View = struct {
    service: *m.Media, title: *gtk.Label, artist: *gtk.Label, state: *gtk.Label, progress: *gtk.Scale, image: *gtk.Image,
    choices: [8]Button = undefined, buttons: [5]Button = undefined, generation: u64 = 0, updating: bool = false, timer: c_uint = 0,
    pub fn create(host: *gtk.Box, media: *m.Media) !*View {
        const self = try a.create(View);
        const card = w.card(); card.as(gtk.Widget).addCssClass("pearl-media-card");
        card.append(w.label(tr("Now playing", "Aktuelle Wiedergabe"), "pearl-card-title").as(gtk.Widget));
        const choices = w.row(4); card.append(choices.as(gtk.Widget));
        const image = w.icon("pearl-media-symbolic"); image.setPixelSize(96); image.as(gtk.Widget).setHalign(.center); card.append(image.as(gtk.Widget));
        const title = w.label("", "pearl-card-title"); title.setEllipsize(.end); title.setLines(2); card.append(title.as(gtk.Widget));
        const artist = w.label("", "pearl-secondary"); artist.setEllipsize(.end); artist.setLines(1); card.append(artist.as(gtk.Widget));
        const progress = gtk.Scale.newWithRange(.horizontal, 0, 100, 1); progress.setDrawValue(0); w.name(progress.as(gtk.Widget), tr("Playback position", "Wiedergabeposition")); card.append(progress.as(gtk.Widget));
        const state = w.label("", "pearl-secondary"); card.append(state.as(gtk.Widget));
        self.* = .{ .service = media, .title = title, .artist = artist, .state = state, .progress = progress, .image = image };
        for (&self.choices) |*choice| { const button = gtk.Button.newWithLabel(""); choice.* = .{ .view = self, .action = .select, .widget = button }; _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, choice, .{}); choices.append(button.as(gtk.Widget)); }
        const controls = w.row(8); controls.as(gtk.Widget).setHalign(.center); card.append(controls.as(gtk.Widget));
        for (&self.buttons, [_]m.Action{ .previous, .play_pause, .next, .stop, .seek }, [_][:0]const u8{ "Previous", "Play", "Next", "Stop", "Seek" }) |*b, action, label| {
            const button = gtk.Button.newWithLabel(label); b.* = .{ .view = self, .action = action, .widget = button };
            _ = gtk.Button.signals.clicked.connect(button, *Button, clicked, b, .{}); controls.append(button.as(gtk.Widget));
        }
        host.append(card.as(gtk.Widget)); media.view(true); self.update(); return self;
    }
    pub fn destroy(self: *View) void { if (self.timer != 0) _ = glib.Source.remove(self.timer); self.service.view(false); a.destroy(self); }
    pub fn update(self: *View) void {
        self.updating = true; defer self.updating = false;
        var count: usize = 0;
        for (&self.service.players) |*player| if (player.ready) { const choice = &self.choices[count]; choice.generation = player.generation; choice.widget.setLabel(if (player.identity.len > 0) player.identity.z() else player.name.z()); choice.widget.as(gtk.Widget).setVisible(1); count += 1; };
        for (self.choices[count..]) |choice| choice.widget.as(gtk.Widget).setVisible(0);
        const p = self.service.current(); self.generation = if (p) |player| player.generation else 0;
        const playing = if (p) |player| std.mem.eql(u8, player.playback.slice(), "Playing") else false;
        self.title.setText(if (p) |player| (if (player.title.len > 0) player.title.z() else "Untitled track") else tr("Nothing playing", "Keine Wiedergabe"));
        self.artist.setText(if (p) |player| player.artist.z() else tr("Open a media player to get started", "Öffne einen Mediaplayer"));
        if (self.service.art.image) |image| self.image.setFromPixbuf(image) else self.image.setFromIconName("pearl-media-symbolic");
        self.image.setPixelSize(96);
        for (&self.buttons) |*button| {
            button.generation = self.generation;
            const allowed = if (p) |player| player.control and !player.busy and switch (button.action) { .previous => player.previous, .next => player.next, .play_pause => if (playing) player.pause else player.play, .seek => player.seek and player.length > 0 and player.track.len > 0, else => true } else false;
            button.widget.as(gtk.Widget).setSensitive(@intFromBool(allowed));
            if (button.action == .play_pause) button.widget.setLabel(if (playing) "Pause" else "Play");
        }
        self.progress.as(gtk.Widget).setSensitive(@intFromBool(if (p) |player| player.control and player.seek and player.length > 0 and !player.busy else false));
        self.tickProgress();
        if (self.timer != 0 and !playing) { _ = glib.Source.remove(self.timer); self.timer = 0; }
        if (self.timer == 0 and playing) self.timer = glib.timeoutAdd(1000, tick, self);
    }
    fn tickProgress(self: *View) void {
        const p = self.service.current();
        if (p) |player| {
            const pos = player.progress();
            // Keep a focused slider stable until the explicit Seek button is used.
            if (self.progress.as(gtk.Widget).hasFocus() == 0) self.progress.as(gtk.Range).setValue(if (player.length > 0) @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(player.length)) * 100 else 0);
            var buf: [120]u8 = undefined;
            self.state.setText(if (self.service.err) |err| blk: { const text = @import("../services/policy.zig").Text(120); var s: text = .{}; s.set(err); break :blk std.fmt.bufPrintZ(&buf, "{s}", .{s.slice()}) catch unreachable; } else std.fmt.bufPrintZ(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ @divTrunc(pos, 60000000), @mod(@divTrunc(pos, 1000000), 60), @divTrunc(player.length, 60000000), @mod(@divTrunc(player.length, 1000000), 60) }) catch "");
        } else { self.progress.as(gtk.Range).setValue(0); self.state.setText(""); }
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int { const self: *View = @ptrCast(@alignCast(data.?)); self.tickProgress(); return 1; }
    fn clicked(_: *gtk.Button, button: *Button) callconv(.c) void {
        const self = button.view;
        const p = self.service.find(button.generation) orelse return;
        const position: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(std.math.maxInt(i64) / 2)), @as(f64, @floatFromInt(p.length)) * self.progress.as(gtk.Range).getValue() / 100));
        self.service.act(button.generation, button.action, position) catch {};
    }
};
