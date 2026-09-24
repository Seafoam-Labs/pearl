//! A clock button's content. The bar owns the button and callback lifetime.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const time = @import("clock_time.zig");
const policy = time.policy;
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const a = std.heap.c_allocator;
pub const View = struct {
    definition: policy.Definition,
    reference: []const u8,
    button: *gtk.Button,
    label: *gtk.Label,
    date: ?*gtk.Label = null,
    zone: ?*glib.TimeZone,
    vertical: bool,
    pub fn create(button: *gtk.Button, d: policy.Definition, ref: []const u8, vertical: bool) View {
        const content = gtk.Box.new(if (vertical) .vertical else .horizontal, if (vertical) 2 else 4);
        const label = gtk.Label.new("");
        label.setJustify(.center);
        var view: View = .{ .definition = d, .reference = ref, .button = button, .label = label, .zone = time.resolve(d.timezone), .vertical = vertical };
        if (d.label.len > 0 or !std.mem.eql(u8, d.id, "local") or !std.mem.eql(u8, d.timezone, "local")) {
            const name = policy.displayName(a, d) catch unreachable;
            defer a.free(name);
            const title = gtk.Label.new(name);
            title.setEllipsize(.end);
            title.setMaxWidthChars(if (vertical) 3 else 12);
            title.setJustify(.center);
            content.append(title.as(gtk.Widget));
        }
        if (d.show_date) {
            const date = gtk.Label.new("");
            date.setJustify(.center);
            // The date can shorten under horizontal pressure; the time stays readable.
            date.setEllipsize(.end);
            if (vertical) {
                date.setMaxWidthChars(3);
                date.as(gtk.Widget).addCssClass("pearl-bar-value");
            }
            view.date = date;
            content.append(date.as(gtk.Widget));
        }
        content.append(label.as(gtk.Widget));
        button.setChild(content.as(gtk.Widget));
        return view;
    }
    pub fn deinit(self: *View) void {
        if (self.zone) |zone| zone.unref();
        self.zone = null;
    }
    pub fn reload(self: *View) void {
        self.deinit();
        self.zone = time.resolve(self.definition.timezone);
    }
    pub fn update(self: *View, utc: *glib.DateTime) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const widget = self.button.as(gtk.Widget);
        const value = if (self.zone) |zone| time.format(alloc, self.definition, utc, zone, self.vertical) catch null else null;
        if (value) |text| {
            self.label.setText(text.time);
            if (self.date) |date| date.setText(if (self.vertical) text.date else std.fmt.allocPrintSentinel(alloc, "{s} ·", .{text.date}, 0) catch text.date);
            const detail = std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ text.detail, tr("Open local calendar", "Lokalen Kalender öffnen") }, 0) catch return;
            widget.setTooltipText(detail);
            w.name(widget, detail);
        } else {
            self.label.setText("—");
            if (self.date) |date| date.setText("");
            const detail = std.fmt.allocPrintSentinel(alloc, "{s} · {s}: {s} · {s}", .{ self.definition.label, tr("Time zone unavailable", "Zeitzone nicht verfügbar"), self.definition.timezone, tr("Open local calendar", "Lokalen Kalender öffnen") }, 0) catch return;
            widget.setTooltipText(detail);
            w.name(widget, detail);
        }
    }
};
