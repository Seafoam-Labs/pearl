//! Resource monitor surfaces: the bar item and the detail popup it opens. One
//! sampler per process feeds both, plus every bar on every output, matching the
//! single shared clock timer rather than one timer per widget and output.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const gdk = @import("gdk4");
const cairo = @import("cairo1");
const w = @import("../ui/components/widgets.zig");
const tr = @import("text.zig").tr;
const model = @import("resource_model.zig");
const a = std.heap.c_allocator;

const interval_ms: c_uint = 1000;
/// DRM cards probed for an AMD or Intel `gpu_busy_percent` counter.
const gpu_cards = 8;
/// Upper bound for one `/proc` reading. A truncated sample is dropped instead of
/// being parsed as a partial counter set.
const scratch_bytes = 32768;
/// Detail-pane graph height; the width follows the popup so narrow displays fit.
const card_height: c_int = 96;
/// Fixed readout width in characters, so a changing figure cannot resize the grid.
const readout_chars: c_int = 14;
/// The outbound network line's dash, so in and out stay apart in one colour.
const dash_pattern = [_]f64{ 3, 2 };

fn history(state: *const model.State, kind: model.Series) *const model.History {
    return switch (kind) {
        .cpu => &state.cpu,
        .gpu => &state.gpu,
        .memory => &state.memory,
        .network => &state.network_in,
    };
}

fn ceiling(state: *const model.State, kind: model.Series) f64 {
    return if (kind == .network) model.networkCeiling(state.network_in, state.network_out) else 100;
}

/// An absent GPU stays visibly absent instead of reading as an idle card.
fn available(state: *const model.State, kind: model.Series) bool {
    return kind != .gpu or state.gpu_available;
}

/// Plots one line with the newest sample pinned to the right edge, so the line
/// grows leftwards while the window is still filling. `inset` reserves room for
/// a cell label and thins the stroke to match; `dashed` marks the outbound
/// direction so in and out stay apart in a single accent colour.
fn plot(cr: *cairo.Context, samples: *const model.History, scale: f64, color: gdk.RGBA, wide: f64, tall: f64, inset: f64, dashed: bool) void {
    if (samples.count < 2) return;
    const step = wide / @as(f64, model.window - 1);
    const span = @max(1, tall - inset - 1);
    cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, 1);
    cr.setLineWidth(if (inset > 2) 1.2 else 1.6);
    if (dashed) cr.setDash(&dash_pattern, dash_pattern.len, 0) else cr.setDash(&dash_pattern, 0, 0);
    var index: usize = 0;
    while (index < samples.count) : (index += 1) {
        const fraction = @min(1, @max(0, samples.at(index) / scale));
        const x = wide - @as(f64, @floatFromInt(samples.count - 1 - index)) * step;
        const y = inset + span - fraction * span;
        if (index == 0) cr.moveTo(x, y) else cr.lineTo(x, y);
    }
    cr.stroke();
    cr.setDash(&dash_pattern, 0, 0);
}

/// The live figure under one graph. The caller owns the buffer.
fn reading(state: *const model.State, kind: model.Series, buffer: []u8) [:0]const u8 {
    if (kind == .network) {
        var received: [12]u8 = undefined;
        var sent: [12]u8 = undefined;
        // Both directions on one line, compact enough for the fixed card width;
        // anything longer is ellipsised rather than resizing the grid.
        return std.fmt.bufPrintZ(buffer, "I:{s} O:{s}", .{
            model.compactLabel(&received, state.throughput_in),
            model.compactLabel(&sent, state.throughput_out),
        }) catch "—";
    }
    if (!available(state, kind)) return tr("Unavailable", "Nicht verfügbar");
    return std.fmt.bufPrintZ(buffer, "{d:.0}%", .{history(state, kind).newest() orelse 0}) catch "—";
}

/// Every series on one line, for the bar item's tooltip and accessible name. The
/// caller owns the buffer.
fn summary(state: *const model.State, buffer: []u8) [:0]const u8 {
    var rates: [24]u8 = undefined;
    var writer = std.Io.Writer.fixed(buffer);
    for (model.series, 0..) |kind, index| {
        if (index != 0) writer.print(" · ", .{}) catch return "";
        if (kind == .network) {
            var sent: [24]u8 = undefined;
            writer.print("{s} ↓{s} ↑{s}", .{ model.abbreviation(kind), model.throughputLabel(&rates, state.throughput_in), model.throughputLabel(&sent, state.throughput_out) }) catch return "";
        } else if (!available(state, kind)) {
            writer.print("{s} {s}", .{ model.abbreviation(kind), tr("unavailable", "nicht verfügbar") }) catch return "";
        } else writer.print("{s} {d:.0}%", .{ model.abbreviation(kind), history(state, kind).newest() orelse 0 }) catch return "";
    }
    const text = writer.buffered();
    buffer[text.len] = 0;
    return buffer[0..text.len :0];
}

const Cell = struct {
    owner: *View,
    area: *gtk.DrawingArea,
    kind: model.Series,
    vertical: bool,
};

fn drawCell(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const cell: *Cell = @ptrCast(@alignCast(data.?));
    const state = &cell.owner.sampler.state;
    var color: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&color);
    const font: f64 = if (cell.vertical) 5 else 6;
    const wide = @as(f64, @floatFromInt(width));
    const tall = @as(f64, @floatFromInt(height));
    cr.save();
    cr.rectangle(0, 0, wide, tall);
    cr.clip();
    const shown = available(state, cell.kind);
    cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, if (shown) 0.7 else 0.3);
    cr.setFontSize(font);
    cr.moveTo(1.5, font + 1);
    cr.showText(model.abbreviation(cell.kind));
    if (shown) {
        const scale = ceiling(state, cell.kind);
        plot(cr, history(state, cell.kind), scale, color, wide, tall, font + 3, false);
        if (cell.kind == .network) plot(cr, &state.network_out, scale, color, wide, tall, font + 3, true);
    }
    cr.restore();
}

/// The bar item. Both modes are buttons that open the detail popup; icon mode
/// carries its live figures in the tooltip and accessible name alone.
pub const View = struct {
    button: *gtk.Button,
    /// Null in icon mode, where the button keeps the icon the bar gave it.
    grid: ?*gtk.Grid = null,
    cells: [model.series.len]Cell = undefined,
    sampler: *Sampler,
    pub fn create(button: *gtk.Button, vertical: bool, mode: model.Mode) !*View {
        const sampler = try Sampler.acquire();
        errdefer sampler.release();
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .button = button, .sampler = sampler };
        if (mode == .graph) {
            const grid = gtk.Grid.new();
            grid.setColumnSpacing(2);
            grid.setRowSpacing(2);
            // A side bar reserves its thickness for the grid's width instead.
            const width: c_int = if (vertical) 17 else 34;
            const height: c_int = if (vertical) 14 else 18;
            for (model.series, 0..) |kind, index| {
                const area = gtk.DrawingArea.new();
                area.setContentWidth(width);
                area.setContentHeight(height);
                area.as(gtk.Widget).addCssClass("pearl-resource-graph");
                const cell = &self.cells[index];
                cell.* = .{ .owner = self, .area = area, .kind = kind, .vertical = vertical };
                area.setDrawFunc(drawCell, cell, null);
                grid.attach(area.as(gtk.Widget), @intCast(index % 2), @intCast(index / 2), 1, 1);
            }
            grid.as(gtk.Widget).addCssClass("pearl-resource-grid");
            button.setChild(grid.as(gtk.Widget));
            self.grid = grid;
        }
        try sampler.attach(.{ .context = self, .refresh = refresh });
        self.describe();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.sampler.detach(self);
        // The bar still owns the button while it unparents it, so the draw
        // callbacks must stop referring to this struct first.
        if (self.grid != null) for (self.cells) |cell| cell.area.setDrawFunc(null, null, null);
        self.sampler.release();
        a.destroy(self);
    }
    fn refresh(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        if (self.grid != null) for (self.cells) |cell| cell.area.as(gtk.Widget).queueDraw();
        self.describe();
    }
    fn describe(self: *View) void {
        var buffer: [256]u8 = undefined;
        const text = summary(&self.sampler.state, &buffer);
        const widget = self.button.as(gtk.Widget);
        widget.setTooltipText(text);
        w.name(widget, text);
    }
};

/// One detail-pane column: the graph above its readout card.
const Card = struct {
    owner: *Detail,
    kind: model.Series,
    area: *gtk.DrawingArea,
    column: *gtk.Box,
    value: *gtk.Label,
};

fn drawCard(area: *gtk.DrawingArea, cr: *cairo.Context, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const card: *Card = @ptrCast(@alignCast(data.?));
    const state = &card.owner.sampler.state;
    var color: gdk.RGBA = undefined;
    area.as(gtk.Widget).getColor(&color);
    const wide = @as(f64, @floatFromInt(width));
    const tall = @as(f64, @floatFromInt(height));
    cr.save();
    cr.rectangle(0, 0, wide, tall);
    cr.clip();
    // Every series is drawn as a share of its own ceiling, so the same quarter
    // guides mean the same thing on all four graphs; the network readout states
    // what 100% currently is.
    cr.setLineWidth(1);
    for ([_]f64{ 0.25, 0.5, 0.75 }) |fraction| {
        cr.setSourceRgba(color.f_red, color.f_green, color.f_blue, if (fraction == 0.5) 0.22 else 0.1);
        const y = @trunc(tall * (1 - fraction)) + 0.5;
        cr.moveTo(0, y);
        cr.lineTo(wide, y);
        cr.stroke();
    }
    if (available(state, card.kind)) {
        const scale = ceiling(state, card.kind);
        plot(cr, history(state, card.kind), scale, color, wide, tall, 1, false);
        if (card.kind == .network) plot(cr, &state.network_out, scale, color, wide, tall, 1, true);
    }
    cr.restore();
}

/// The popup opened from the bar: one large graph per selected series, arranged
/// four across and two deep — graphs on the top row, names and readings below.
pub const Detail = struct {
    grid: *gtk.Grid,
    empty: *gtk.Label,
    cards: [model.series.len]Card = undefined,
    placed: [model.series.len]model.Series = undefined,
    placed_count: usize = 0,
    sampler: *Sampler,
    pub fn create(host: *gtk.Box, selection: model.Selection) !*Detail {
        const sampler = try Sampler.acquire();
        errdefer sampler.release();
        const self = try a.create(Detail);
        errdefer a.destroy(self);
        const header = w.row(8);
        header.append(w.label(tr("Resource monitor", "Ressourcenmonitor"), "pearl-card-title").as(gtk.Widget));
        host.append(header.as(gtk.Widget));
        const grid = gtk.Grid.new();
        grid.setColumnSpacing(10);
        grid.setRowSpacing(6);
        grid.setColumnHomogeneous(1);
        grid.as(gtk.Widget).setHexpand(1);
        grid.as(gtk.Widget).setVexpand(1);
        const empty = w.label(tr("No graphs selected. Enable them in Settings → Bar & dock.", "Keine Diagramme ausgewählt. In Einstellungen → Leiste & Dock aktivieren."), "pearl-secondary");
        empty.as(gtk.Widget).setHalign(.center);
        empty.as(gtk.Widget).setValign(.center);
        empty.as(gtk.Widget).setVexpand(1);
        empty.as(gtk.Widget).setVisible(0);
        self.* = .{ .grid = grid, .empty = empty, .sampler = sampler };
        for (model.series, 0..) |kind, index| {
            const area = gtk.DrawingArea.new();
            area.setContentWidth(120);
            area.setContentHeight(card_height);
            area.as(gtk.Widget).setHexpand(1);
            // Growing vertically lets the graphs absorb whatever height the popup
            // reserved, so `card_height` stays a floor rather than a fixed size.
            area.as(gtk.Widget).setVexpand(1);
            area.as(gtk.Widget).addCssClass("pearl-resource-graph");
            area.as(gtk.Widget).addCssClass("pearl-resource-card");
            const column = w.column(3);
            column.as(gtk.Widget).addCssClass("pearl-resource-readout");
            column.as(gtk.Widget).setHexpand(1);
            const name = w.label(kind.label(), "pearl-resource-name");
            const value = w.label("—", "pearl-resource-value");
            // A fixed character width keeps the column — and so the whole grid —
            // from resizing every second as the reading's text length changes.
            for ([_]*gtk.Label{ name, value }) |label| {
                label.setWidthChars(readout_chars);
                label.setEllipsize(.end);
                label.setJustify(.center);
                // Width chars fixes the widget; this centres the text inside it,
                // so short and long readings share one column line.
                label.setXalign(0.5);
                label.as(gtk.Widget).setHalign(.center);
            }
            column.append(name.as(gtk.Widget));
            column.append(value.as(gtk.Widget));
            const card = &self.cards[index];
            card.* = .{ .owner = self, .kind = kind, .area = area, .column = column, .value = value };
            area.setDrawFunc(drawCard, card, null);
        }
        host.append(grid.as(gtk.Widget));
        host.append(empty.as(gtk.Widget));
        try sampler.attach(.{ .context = self, .refresh = refresh });
        self.select(selection);
        self.read();
        return self;
    }
    pub fn destroy(self: *Detail) void {
        self.sampler.detach(self);
        for (self.cards) |card| card.area.setDrawFunc(null, null, null);
        self.sampler.release();
        a.destroy(self);
    }
    /// A live preference change re-lays the same cards; nothing is reallocated.
    pub fn update(self: *Detail, selection: model.Selection) void {
        self.select(selection);
        self.read();
    }
    fn select(self: *Detail, selection: model.Selection) void {
        for (self.placed[0..self.placed_count]) |kind| {
            const card = &self.cards[@intFromEnum(kind)];
            self.grid.remove(card.area.as(gtk.Widget));
            self.grid.remove(card.column.as(gtk.Widget));
        }
        self.placed_count = 0;
        var column: c_int = 0;
        for (model.series) |kind| {
            if (!kind.enabled(selection)) continue;
            const card = &self.cards[@intFromEnum(kind)];
            self.grid.attach(card.area.as(gtk.Widget), column, 0, 1, 1);
            self.grid.attach(card.column.as(gtk.Widget), column, 1, 1, 1);
            self.placed[self.placed_count] = kind;
            self.placed_count += 1;
            column += 1;
        }
        self.empty.as(gtk.Widget).setVisible(@intFromBool(self.placed_count == 0));
        self.grid.as(gtk.Widget).setVisible(@intFromBool(self.placed_count != 0));
    }
    fn refresh(context: *anyopaque) void {
        const self: *Detail = @ptrCast(@alignCast(context));
        self.read();
    }
    fn read(self: *Detail) void {
        const state = &self.sampler.state;
        var value: [48]u8 = undefined;
        for (self.placed[0..self.placed_count]) |kind| {
            const card = &self.cards[@intFromEnum(kind)];
            card.area.as(gtk.Widget).queueDraw();
            card.value.setText(reading(state, kind, &value));
        }
    }
};

/// NVML reached through `dlopen`, so an absent or unsupported driver costs one
/// failed lookup instead of a build dependency. The handle is process-wide and
/// never closed: a bar reconfiguration must not remap the driver, and the
/// library stays resident once a session has used it.
const Utilization = extern struct { gpu: c_uint, memory: c_uint };
const Nvml = struct {
    handles: [4]?*anyopaque = [_]?*anyopaque{null} ** 4,
    count: usize = 0,
    probed: bool = false,
    rates: ?*const fn (?*anyopaque, *Utilization) callconv(.c) c_int = null,
    fn open(self: *Nvml) void {
        if (self.probed) return;
        self.probed = true;
        const library = std.c.dlopen("libnvidia-ml.so.1", .{ .LAZY = true }) orelse return;
        const initialize: *const fn () callconv(.c) c_int = @ptrCast(std.c.dlsym(library, "nvmlInit_v2") orelse return);
        const devices: *const fn (*c_uint) callconv(.c) c_int = @ptrCast(std.c.dlsym(library, "nvmlDeviceGetCount_v2") orelse return);
        const handle: *const fn (c_uint, *?*anyopaque) callconv(.c) c_int = @ptrCast(std.c.dlsym(library, "nvmlDeviceGetHandleByIndex_v2") orelse return);
        self.rates = @ptrCast(std.c.dlsym(library, "nvmlDeviceGetUtilizationRates") orelse return);
        if (initialize() != 0) return;
        var total: c_uint = 0;
        if (devices(&total) != 0) return;
        var index: c_uint = 0;
        while (index < total and self.count < self.handles.len) : (index += 1) {
            var device: ?*anyopaque = null;
            if (handle(index, &device) != 0) continue;
            self.handles[self.count] = device;
            self.count += 1;
        }
    }
    fn busy(self: *Nvml) ?f64 {
        const call = self.rates orelse return null;
        var peak: ?f64 = null;
        for (self.handles[0..self.count]) |device| {
            var rates: Utilization = .{ .gpu = 0, .memory = 0 };
            if (call(device, &rates) != 0 or rates.gpu > 100) continue;
            peak = @max(peak orelse 0, @as(f64, @floatFromInt(rates.gpu)));
        }
        return peak;
    }
};

const Subscription = struct { context: *anyopaque, refresh: *const fn (*anyopaque) void };

var process: ?*Sampler = null;
var nvml: Nvml = .{};

const Sampler = struct {
    state: model.State = .{},
    subscriptions: std.ArrayList(Subscription) = .empty,
    references: usize = 0,
    timer: c_uint = 0,
    last: i64 = 0,
    scratch: [scratch_bytes]u8 = undefined,
    fn acquire() !*Sampler {
        if (process) |existing| {
            existing.references += 1;
            return existing;
        }
        const self = try a.create(Sampler);
        self.* = .{};
        self.references = 1;
        self.last = glib.getMonotonicTime();
        self.sample(interval_ms / 1000);
        self.timer = glib.timeoutAdd(interval_ms, tick, self);
        process = self;
        return self;
    }
    fn release(self: *Sampler) void {
        self.references -= 1;
        if (self.references > 0) return;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        process = null;
        a.destroy(self);
    }
    fn attach(self: *Sampler, subscription: Subscription) !void {
        try self.subscriptions.append(a, subscription);
    }
    fn detach(self: *Sampler, context: *anyopaque) void {
        for (self.subscriptions.items, 0..) |existing, index| {
            if (existing.context != context) continue;
            _ = self.subscriptions.orderedRemove(index);
            return;
        }
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Sampler = @ptrCast(@alignCast(data.?));
        const now = glib.getMonotonicTime();
        self.sample(@as(f64, @floatFromInt(now - self.last)) / std.time.us_per_s);
        self.last = now;
        for (self.subscriptions.items) |subscription| subscription.refresh(subscription.context);
        return 1;
    }
    fn sample(self: *Sampler, seconds: f64) void {
        if (read("/proc/stat", &self.scratch)) |text| self.state.sampleCpu(text);
        if (read("/proc/meminfo", &self.scratch)) |text| self.state.sampleMemory(text);
        if (read("/proc/net/dev", &self.scratch)) |text| self.state.sampleNetwork(text, seconds);
        self.state.sampleGpu(self.gpu());
    }
    /// The busiest card over both supported sources, so a hybrid machine reports
    /// whichever GPU is actually doing work.
    fn gpu(self: *Sampler) ?f64 {
        var peak: ?f64 = null;
        var path: [64]u8 = undefined;
        var index: usize = 0;
        while (index < gpu_cards) : (index += 1) {
            const name = std.fmt.bufPrintZ(&path, "/sys/class/drm/card{d}/device/gpu_busy_percent", .{index}) catch continue;
            if (read(name, &self.scratch)) |text| {
                if (model.gpu(text)) |value| peak = @max(peak orelse 0, value);
            }
        }
        nvml.open();
        if (nvml.busy()) |value| peak = @max(peak orelse 0, value);
        return peak;
    }
};

fn read(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var used: usize = 0;
    while (used < buffer.len) {
        const n = std.c.read(fd, buffer[used..].ptr, buffer.len - used);
        if (n < 0) return null;
        if (n == 0) break;
        used += @intCast(n);
    }
    return if (used == 0) null else buffer[0..used];
}
