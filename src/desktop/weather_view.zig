//! Weather popup: current conditions, the next 24 hours and the 7-day outlook.
//! Content is rebuilt from the service snapshot; GTK copies every label string,
//! so one arena per update owns all formatted text.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const policy = @import("weather_policy.zig");
const Service = @import("../services/weather.zig").Service;
const a = std.heap.c_allocator;

pub const View = struct {
    service: *Service,
    content: *gtk.Box,
    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        self.* = .{ .service = service, .content = w.column(12) };
        // The pane height is clamped to the screen; scrolling keeps tall
        // content readable instead of squeezing every section.
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.setPropagateNaturalHeight(1);
        scroll.as(gtk.Widget).setVexpand(1);
        scroll.setChild(self.content.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        while (self.content.as(gtk.Widget).getFirstChild()) |child| self.content.remove(child);
        const forecast = self.service.snapshot orelse {
            const message = w.label(if (self.service.failed) @import("i18n").dtr("pearl", "Weather unavailable") else @import("i18n").dtr("pearl", "Fetching weather…"), "pearl-secondary");
            message.as(gtk.Widget).setMarginTop(24);
            message.as(gtk.Widget).setMarginBottom(24);
            self.content.append(message.as(gtk.Widget));
            return;
        };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const header = w.row(12);
        const glyph = w.icon(policy.icon(forecast.current.code, !forecast.current.is_day));
        glyph.setPixelSize(56);
        glyph.as(gtk.Widget).setValign(.center);
        header.append(glyph.as(gtk.Widget));
        const summary = w.column(2);
        summary.as(gtk.Widget).setValign(.center);
        const location = w.label(alloc.dupeSentinel(u8, self.service.config.location, 0) catch return, "heading");
        location.setEllipsize(.end);
        location.setMaxWidthChars(24);
        location.as(gtk.Widget).setHalign(.start);
        summary.append(location.as(gtk.Widget));
        const condition = w.label(policy.condition(forecast.current.code), "pearl-secondary");
        condition.as(gtk.Widget).setHalign(.start);
        summary.append(condition.as(gtk.Widget));
        header.append(summary.as(gtk.Widget));
        const temperature = w.label(std.fmt.allocPrintSentinel(alloc, "{d:.0}°", .{forecast.current.temperature}, 0) catch return, "title-1");
        temperature.as(gtk.Widget).setHalign(.end);
        temperature.as(gtk.Widget).setHexpand(1);
        temperature.as(gtk.Widget).setValign(.center);
        header.append(temperature.as(gtk.Widget));
        self.content.append(header.as(gtk.Widget));
        if (forecast.hour_count != 0) {
            self.content.append(w.label(@import("i18n").dtr("pearl", "Next 24 hours"), "settings-row-title").as(gtk.Widget));
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.automatic, .never);
            scroll.setPropagateNaturalHeight(1);
            // The overlay scrollbar fades when idle; the bottom margin keeps it
            // off the temperatures even while it is visible.
            const hours = w.row(10);
            hours.as(gtk.Widget).setMarginBottom(14);
            for (forecast.hours[0..forecast.hour_count], 0..) |hour, i| {
                const cell = w.column(4);
                // A fixed floor keeps the strip wider than the popup, which is
                // what makes the scrolled window scroll instead of squeezing.
                cell.as(gtk.Widget).setHalign(.center);
                cell.as(gtk.Widget).setSizeRequest(44, -1);
                // The shared label helper wraps and expands; strip cells must not.
                const when: [:0]const u8 = if (i == 0) @import("i18n").dtr("pearl", "Now") else formatAt(alloc, hour.time, forecast.utc_offset, "%H:00");
                const when_label = w.label(when, "pearl-secondary");
                when_label.setWrap(0);
                when_label.setXalign(0.5);
                when_label.as(gtk.Widget).setHalign(.center);
                when_label.as(gtk.Widget).setHexpand(0);
                cell.append(when_label.as(gtk.Widget));
                const cell_icon = w.icon(policy.icon(hour.code, !hour.is_day));
                cell_icon.as(gtk.Widget).setHalign(.center);
                cell.append(cell_icon.as(gtk.Widget));
                const temp_label = w.label(std.fmt.allocPrintSentinel(alloc, "{d:.0}°", .{hour.temperature}, 0) catch continue, null);
                temp_label.setWrap(0);
                temp_label.setXalign(0.5);
                temp_label.as(gtk.Widget).setHalign(.center);
                temp_label.as(gtk.Widget).setHexpand(0);
                cell.append(temp_label.as(gtk.Widget));
                hours.append(cell.as(gtk.Widget));
            }
            scroll.setChild(hours.as(gtk.Widget));
            self.content.append(scroll.as(gtk.Widget));
        }
        if (forecast.day_count != 0) {
            self.content.append(w.label(@import("i18n").dtr("pearl", "7-day forecast"), "settings-row-title").as(gtk.Widget));
            for (forecast.days[0..forecast.day_count], 0..) |day, i| {
                const row = w.row(8);
                const name = if (i == 0) @import("i18n").dtr("pearl", "Today") else formatAt(alloc, day.time, forecast.utc_offset, "%a");
                const day_label = w.label(name, null);
                day_label.setWrap(0);
                day_label.setWidthChars(6);
                day_label.setXalign(0);
                day_label.as(gtk.Widget).setHexpand(0);
                row.append(day_label.as(gtk.Widget));
                row.append(w.icon(policy.icon(day.code, false)).as(gtk.Widget));
                const outlook = w.label(policy.condition(day.code), "pearl-secondary");
                outlook.setEllipsize(.end);
                outlook.setMaxWidthChars(18);
                outlook.setXalign(0);
                outlook.as(gtk.Widget).setHexpand(1);
                row.append(outlook.as(gtk.Widget));
                const range = w.label(std.fmt.allocPrintSentinel(alloc, "{d:.0}° · {d:.0}°", .{ day.min, day.max }, 0) catch continue, null);
                range.setWrap(0);
                range.as(gtk.Widget).setHexpand(0);
                row.append(range.as(gtk.Widget));
                self.content.append(row.as(gtk.Widget));
            }
        }
    }
    /// Location wall time: the API returns real unix timestamps plus the
    /// location's UTC offset, so formatting the shifted instant as UTC yields
    /// the place's own clock even for remote locations.
    fn formatAt(alloc: std.mem.Allocator, unix: i64, offset: i32, pattern: [:0]const u8) [:0]const u8 {
        const time = glib.DateTime.newFromUnixUtc(unix + offset) orelse return "—";
        defer time.unref();
        const text = time.format(pattern) orelse return "—";
        defer glib.free(text);
        return alloc.dupeSentinel(u8, std.mem.span(text), 0) catch "—";
    }
};
