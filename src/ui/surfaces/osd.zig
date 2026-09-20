//! Bounded OSD content and an informational, non-interactive volume card.
const std = @import("std");
const gtk = @import("gtk4");
const policy = @import("../../services/policy.zig");
const tr = @import("../../desktop/text.zig").tr;
pub const Volume = @import("../../services/audio_feedback.zig").Volume;
pub const Content = union(enum) {
    text: policy.Text(512),
    volume: Volume,

    pub fn summary(self: *const Content) policy.Text(512) {
        switch (self.*) {
            .text => |t| return t,
            .volume => |v| {
                var result: policy.Text(512) = .{};
                var buffer: [512]u8 = undefined;
                result.set(std.fmt.bufPrint(&buffer, "{s} · {d}%{s}{s}", .{ v.label.slice(), v.percent, if (v.muted) " · " else "", if (v.muted) tr("Muted", "Stumm") else "" }) catch "");
                return result;
            },
        }
    }
};

pub const View = struct {
    root: *gtk.Box,
    text: *gtk.Label,
    card: *gtk.Box,
    icon: *gtk.Image,
    label: *gtk.Label,
    value: *gtk.Label,
    meter: *gtk.ProgressBar,

    pub fn init(parent: *gtk.Box) View {
        const root = gtk.Box.new(.vertical, 0);
        parent.append(root.as(gtk.Widget));
        const text = gtk.Label.new(null);
        text.setWrap(1);
        text.setWrapMode(.word_char);
        text.setMaxWidthChars(40);
        root.append(text.as(gtk.Widget));
        const card = gtk.Box.new(.vertical, 10);
        card.as(gtk.Widget).addCssClass("pearl-volume-osd");
        root.append(card.as(gtk.Widget));
        const row = gtk.Box.new(.horizontal, 10);
        card.append(row.as(gtk.Widget));
        const icon = gtk.Image.newFromIconName("pearl-audio-volume-high-symbolic");
        icon.setPixelSize(24);
        row.append(icon.as(gtk.Widget));
        const label = gtk.Label.new(null);
        label.setEllipsize(.end);
        label.setMaxWidthChars(24);
        label.setXalign(0);
        label.as(gtk.Widget).setHexpand(1);
        row.append(label.as(gtk.Widget));
        const value = gtk.Label.new(null);
        value.as(gtk.Widget).addCssClass("pearl-volume-value");
        row.append(value.as(gtk.Widget));
        const meter = gtk.ProgressBar.new();
        meter.as(gtk.Accessible).updateProperty(.label, tr("Output volume", "Ausgabelautstärke").ptr, @as(c_int, -1));
        card.append(meter.as(gtk.Widget));
        return .{ .root = root, .text = text, .card = card, .icon = icon, .label = label, .value = value, .meter = meter };
    }

    pub fn update(self: *View, content: *const Content) void {
        self.text.as(gtk.Widget).setVisible(@intFromBool(content.* == .text));
        self.card.as(gtk.Widget).setVisible(@intFromBool(content.* == .volume));
        switch (content.*) {
            .text => |t| self.text.setText(t.z()),
            .volume => |v| {
                self.label.setText(if (v.label.len != 0) v.label.z() else tr("Output volume", "Ausgabelautstärke"));
                self.icon.setFromIconName(if (v.muted) "pearl-audio-volume-muted-symbolic" else "pearl-audio-volume-high-symbolic");
                var buffer: [80]u8 = undefined;
                self.value.setText(std.fmt.bufPrintZ(&buffer, "{s}{s}{d}%", .{ if (v.muted) tr("Muted", "Stumm") else "", if (v.muted) " · " else "", v.percent }) catch "");
                self.meter.setFraction(@as(f64, @floatFromInt(v.percent)) / 100);
                if (v.muted) self.card.as(gtk.Widget).addCssClass("pearl-volume-muted") else self.card.as(gtk.Widget).removeCssClass("pearl-volume-muted");
            },
        }
        const summary = content.summary();
        self.root.as(gtk.Accessible).updateProperty(.label, summary.z().ptr, @as(c_int, -1));
    }
};
