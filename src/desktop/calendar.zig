//! Month grid for the bar's calendar pane. GtkCalendar draws a fixed cell layout
//! that cannot take the shell theme's rounded day pills, so the grid is assembled
//! from plain buttons and styled entirely through CSS.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const glib = @import("glib2");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const model = @import("calendar_model.zig");
const Date = model.Date;
const Month = model.Month;
const shift = model.shift;
const daysInMonth = model.daysInMonth;
const firstWeekday = model.firstWeekday;
const a = std.heap.c_allocator;

const columns: usize = 7;
const weeks: usize = 6;
const slots = columns * weeks;
const month_names = [_][:0]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
/// Monday-first, matching the ISO weekday numbering the pane used before.
const weekday_names = [_][:0]const u8{ "MO", "TU", "WE", "TH", "FR", "SA", "SU" };
const key_left: c_uint = 0xff51;
const key_up: c_uint = 0xff52;
const key_right: c_uint = 0xff53;
const key_down: c_uint = 0xff54;

const Day = struct { view: *View, index: u8, button: *gtk.ToggleButton };
/// months == 0 jumps back to today instead of stepping.
const Step = struct { view: *View, months: i8 };

pub const View = struct {
    heading: *gtk.Label,
    days: [slots]Day = undefined,
    steps: [3]Step = undefined,
    shown: Month,
    today: Date,
    selected: Date,

    pub fn create(host: *gtk.Box) !*View {
        const now = glib.DateTime.newNowLocal() orelse return error.ClockUnavailable;
        defer now.unref();
        const stamp = now.format("%A, %d %B %Y") orelse return error.ClockUnavailable;
        defer glib.free(stamp);

        const self = try a.create(View);
        errdefer a.destroy(self);

        host.append(w.label(stamp, "pearl-card-title").as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const content = w.column(14);
        scroll.setChild(content.as(gtk.Widget));
        host.append(scroll.as(gtk.Widget));

        const card = w.column(12);
        card.as(gtk.Widget).addCssClass("pearl-calendar");
        card.as(gtk.Widget).setHexpand(1);
        card.as(gtk.Widget).setValign(.start);
        content.append(card.as(gtk.Widget));

        const header = w.row(6);
        card.append(header.as(gtk.Widget));
        const previous = stepButton("‹", tr("Previous month", "Vorheriger Monat"));
        const next = stepButton("›", tr("Next month", "Nächster Monat"));
        const heading = gtk.Label.new("");
        heading.setXalign(0.5);
        heading.as(gtk.Widget).addCssClass("pearl-calendar-heading");
        heading.as(gtk.Widget).setHexpand(1);
        const jump = gtk.Button.newWithLabel(tr("Today", "Heute"));
        jump.as(gtk.Widget).addCssClass("pearl-pill");
        jump.as(gtk.Widget).addCssClass("pearl-calendar-jump");
        w.name(jump.as(gtk.Widget), tr("Show the current month", "Aktuellen Monat anzeigen"));
        header.append(previous.as(gtk.Widget));
        header.append(heading.as(gtk.Widget));
        header.append(next.as(gtk.Widget));
        header.append(jump.as(gtk.Widget));

        const grid = gtk.Grid.new();
        grid.setColumnHomogeneous(1);
        grid.setColumnSpacing(4);
        grid.setRowSpacing(2);
        grid.as(gtk.Widget).setHexpand(1);
        card.append(grid.as(gtk.Widget));
        for (weekday_names, 0..) |weekday, i| {
            const cell = gtk.Label.new(weekday);
            cell.setXalign(0.5);
            cell.as(gtk.Widget).addCssClass("pearl-calendar-weekday");
            grid.attach(cell.as(gtk.Widget), @intCast(i), 0, 1, 1);
        }

        const today = Date{ .year = now.getYear(), .month = @intCast(now.getMonth()), .day = @intCast(now.getDayOfMonth()) };
        self.* = .{ .heading = heading, .shown = model.monthOf(today), .today = today, .selected = today };

        for (&self.days, 0..) |*day, i| {
            const button = gtk.ToggleButton.new();
            button.as(gtk.Widget).addCssClass("pearl-calendar-day");
            // Homogeneous columns widen past the cell minimum in a 440px popup;
            // centering keeps the day pills circular instead of stretching.
            button.as(gtk.Widget).setHalign(.center);
            button.as(gtk.Widget).setValign(.center);
            day.* = .{ .view = self, .index = @intCast(i), .button = button };
            _ = gtk.Button.signals.clicked.connect(button.as(gtk.Button), *Day, dayClicked, day, .{});
            grid.attach(button.as(gtk.Widget), @intCast(i % columns), @intCast(1 + i / columns), 1, 1);
        }
        const steps = [_]struct { button: *gtk.Button, months: i8 }{
            .{ .button = previous, .months = -1 },
            .{ .button = next, .months = 1 },
            .{ .button = jump, .months = 0 },
        };
        for (steps, &self.steps) |item, *step| {
            step.* = .{ .view = self, .months = item.months };
            _ = gtk.Button.signals.clicked.connect(item.button, *Step, stepClicked, step, .{});
        }

        // Arrow keys walk the grid, so only one day stays in the tab order.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *View, keyPressed, self, .{});
        card.as(gtk.Widget).addController(keys.as(gtk.EventController));

        content.append(w.status(.empty, w.label(tr("Your local calendar", "Dein lokaler Kalender"), null), w.label(tr("Browse months and dates. Calendar accounts are not connected.", "Blättere durch Monate und Tage. Kalenderkonten sind nicht verbunden."), "pearl-secondary")).as(gtk.Widget));

        self.render();
        return self;
    }
    pub fn destroy(self: *View) void {
        a.destroy(self);
    }

    fn render(self: *View) void {
        var text: [32:0]u8 = undefined;
        self.heading.setText(std.fmt.bufPrintZ(&text, "{s} {d}", .{ month_names[self.shown.month - 1], self.shown.year }) catch unreachable);

        const lead = firstWeekday(self.shown.year, self.shown.month) - 1;
        const count = daysInMonth(self.shown.year, self.shown.month);
        const used = @min(slots, model.visibleSlots(lead, count, columns));
        // Keep the grid reachable by keyboard even when the selection sits in
        // another month: fall back to today, then to the first day.
        const focus_day: u32 = if (model.sameMonth(self.selected, self.shown))
            self.selected.day
        else if (model.sameMonth(self.today, self.shown))
            self.today.day
        else
            1;

        for (&self.days, 0..) |*day, i| {
            const widget = day.button.as(gtk.Widget);
            if (i >= used) {
                widget.setVisible(0);
                widget.setCanFocus(0);
                day.button.setActive(0);
                continue;
            }
            const date = shift(self.shown.year, self.shown.month, @as(i32, @intCast(i)) - @as(i32, @intCast(lead)) + 1);
            const outside = !model.sameMonth(date, self.shown);
            var label: [8:0]u8 = undefined;
            day.button.as(gtk.Button).setLabel(std.fmt.bufPrintZ(&label, "{d}", .{date.day}) catch unreachable);
            var name: [48:0]u8 = undefined;
            w.name(widget, std.fmt.bufPrintZ(&name, "{d} {s} {d}", .{ date.day, month_names[date.month - 1], date.year }) catch unreachable);
            widget.setVisible(1);
            setClass(widget, "pearl-calendar-outside", outside);
            setClass(widget, "pearl-calendar-today", model.sameDate(date, self.today));
            day.button.setActive(@intFromBool(model.sameDate(date, self.selected)));
            widget.setCanFocus(@intFromBool(!outside and date.day == focus_day));
        }
    }
    fn focusSelected(self: *View) void {
        for (&self.days) |*day| {
            const widget = day.button.as(gtk.Widget);
            if (widget.getCanFocus() != 0) {
                _ = widget.grabFocus();
                return;
            }
        }
    }

    fn dayClicked(_: *gtk.Button, day: *Day) callconv(.c) void {
        const self = day.view;
        self.select(self.dateAt(day.index));
        self.focusSelected();
    }
    fn stepClicked(_: *gtk.Button, step: *Step) callconv(.c) void {
        const self = step.view;
        if (step.months == 0) {
            self.shown = model.monthOf(self.today);
            self.selected = self.today;
        } else {
            self.shown = if (step.months < 0) model.stepBack(self.shown) else model.stepForward(self.shown);
        }
        self.render();
    }
    fn keyPressed(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *View) callconv(.c) c_int {
        const offset: i32 = switch (keyval) {
            key_left => -1,
            key_right => 1,
            key_up => -@as(i32, @intCast(columns)),
            key_down => @intCast(columns),
            else => return 0,
        };
        self.select(shift(self.selected.year, self.selected.month, @as(i32, @intCast(self.selected.day)) + offset));
        self.focusSelected();
        return 1;
    }

    fn select(self: *View, date: Date) void {
        self.selected = date;
        self.shown = model.monthOf(date);
        self.render();
    }
    fn dateAt(self: *View, index: u8) Date {
        const lead = firstWeekday(self.shown.year, self.shown.month) - 1;
        return shift(self.shown.year, self.shown.month, @as(i32, @intCast(index)) - @as(i32, @intCast(lead)) + 1);
    }
};

fn stepButton(glyph: [*:0]const u8, tip: [*:0]const u8) *gtk.Button {
    const button = gtk.Button.newWithLabel(glyph);
    button.as(gtk.Widget).addCssClass("pearl-icon");
    button.as(gtk.Widget).addCssClass("pearl-calendar-nav");
    button.as(gtk.Widget).setTooltipText(tip);
    w.name(button.as(gtk.Widget), tip);
    return button;
}

fn setClass(widget: *gtk.Widget, class: [*:0]const u8, on: bool) void {
    if (widget.hasCssClass(class) != 0) {
        if (!on) widget.removeCssClass(class);
    } else if (on) widget.addCssClass(class);
}
