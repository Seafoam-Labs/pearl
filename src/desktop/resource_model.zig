//! Pure resource sampling: kernel counter parsing, rate maths and a fixed window.
//! Reading the kernel files and NVML belongs to the GTK side; this module only
//! turns text into numbers so the sampling stays testable without a session.
const std = @import("std");

/// Samples retained per series. At the one-second interval this is one minute.
pub const window = 60;

/// How the bar presents the widget. Both open the same detail popup.
pub const Mode = enum {
    icon,
    graph,
    pub fn label(self: Mode) [:0]const u8 {
        return switch (self) {
            .icon => "Icon",
            .graph => "Mini graphs",
        };
    }
    pub fn description(self: Mode) [:0]const u8 {
        return switch (self) {
            .icon => "A bar icon that opens the detail graphs",
            .graph => "Live sparklines in the bar, opening the same detail graphs",
        };
    }
};

/// Which graphs the detail popup renders. Sampling is unaffected, so the bar
/// tooltip keeps reporting every series even while its graph is hidden.
pub const Selection = struct { cpu: bool = true, gpu: bool = true, memory: bool = true, network: bool = true };

pub const Series = enum {
    cpu,
    gpu,
    memory,
    network,
    pub fn label(self: Series) [:0]const u8 {
        return switch (self) {
            .cpu => "CPU",
            .gpu => "GPU",
            .memory => "Memory",
            .network => "Network",
        };
    }
    pub fn enabled(self: Series, selection: Selection) bool {
        return switch (self) {
            .cpu => selection.cpu,
            .gpu => selection.gpu,
            .memory => selection.memory,
            .network => selection.network,
        };
    }
};
pub const series = std.enums.values(Series);

/// Short form used inside the bar's miniature cells, where the full name will
/// not fit beside the line.
pub fn abbreviation(kind: Series) [:0]const u8 {
    return switch (kind) {
        .cpu => "CPU",
        .gpu => "GPU",
        .memory => "RAM",
        .network => "NET",
    };
}

/// One metric's retained samples, oldest to newest.
pub const History = struct {
    values: [window]f64 = [_]f64{0} ** window,
    count: usize = 0,
    /// Index of the oldest retained sample once the ring wraps.
    start: usize = 0,
    pub fn push(self: *History, value: f64) void {
        self.values[(self.start + self.count) % window] = value;
        if (self.count == window) self.start = (self.start + 1) % window else self.count += 1;
    }
    /// Oldest first; `index` must be below `count`.
    pub fn at(self: History, index: usize) f64 {
        return self.values[(self.start + index) % window];
    }
    pub fn newest(self: History) ?f64 {
        if (self.count == 0) return null;
        return self.values[(self.start + self.count - 1) % window];
    }
    pub fn maximum(self: History) f64 {
        var peak: f64 = 0;
        var index: usize = 0;
        while (index < self.count) : (index += 1) peak = @max(peak, self.at(index));
        return peak;
    }
};

pub const Cpu = struct { total: u64, idle: u64 };

/// The aggregate `/proc/stat` line. `guest` and `guest_nice` are already counted
/// inside `user` and `nice`, so only the first eight fields are summed.
pub fn cpu(text: []const u8) ?Cpu {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu ")) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        var result: Cpu = .{ .total = 0, .idle = 0 };
        var index: usize = 0;
        while (index < 8) : (index += 1) {
            const value = std.fmt.parseInt(u64, fields.next() orelse break, 10) catch return null;
            result.total += value;
            // Field three is idle and field four is iowait; neither is busy time.
            if (index == 3 or index == 4) result.idle += value;
        }
        return if (index == 8) result else null;
    }
    return null;
}

/// Busy share between two readings, or null when the counters did not advance.
pub fn usage(previous: Cpu, current: Cpu) ?f64 {
    const total = @as(i128, current.total) - @as(i128, previous.total);
    if (total <= 0) return null;
    return share(total - (@as(i128, current.idle) - @as(i128, previous.idle)), total);
}

/// Used share of `/proc/meminfo`, counting caches and reclaimable slab as free.
pub fn memory(text: []const u8) ?f64 {
    const total = kilobytes(text, "MemTotal:") orelse return null;
    const available = kilobytes(text, "MemAvailable:") orelse return null;
    if (total == 0 or available > total) return null;
    return share(@as(i128, total) - @as(i128, available), @as(i128, total));
}

fn kilobytes(text: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        return std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch null;
    }
    return null;
}

pub const Network = struct { received: u64, sent: u64 };

/// `/proc/net/dev` byte counters summed over every interface except loopback,
/// which would otherwise count local traffic twice.
pub fn network(text: []const u8) ?Network {
    var result: ?Network = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0 or std.mem.eql(u8, name, "lo")) continue;
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        // Field zero is rx_bytes and field eight is tx_bytes; the counters
        // between them are error and queue counts this widget does not show.
        var counters: [9]u64 = undefined;
        var index: usize = 0;
        while (index < counters.len) : (index += 1) {
            counters[index] = std.fmt.parseInt(u64, fields.next() orelse break, 10) catch break;
        }
        if (index < counters.len) continue;
        const prior = result orelse Network{ .received = 0, .sent = 0 };
        result = .{ .received = prior.received + counters[0], .sent = prior.sent + counters[8] };
    }
    return result;
}

/// Bytes per second between two counters, or null across an interface reset.
pub fn rate(previous: u64, current: u64, seconds: f64) ?f64 {
    if (seconds <= 0 or current < previous) return null;
    return @as(f64, @floatFromInt(current - previous)) / seconds;
}

/// An AMD or Intel `gpu_busy_percent` reading. NVIDIA exposes no sysfs counter.
pub fn gpu(text: []const u8) ?f64 {
    const value = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t\r\n"), 10) catch return null;
    if (value > 100) return null;
    return @floatFromInt(value);
}

/// Throughput text for tooltips; scaled so an idle link still reads as zero.
pub fn throughputLabel(buffer: []u8, bytes_per_second: f64) []const u8 {
    const units = [_][:0]const u8{ "B/s", "KiB/s", "MiB/s", "GiB/s" };
    var value = bytes_per_second;
    var index: usize = 0;
    while (value >= 1024 and index + 1 < units.len) : (index += 1) value /= 1024;
    return if (index == 0)
        std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ value, units[index] }) catch ""
    else
        std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[index] }) catch "";
}

/// Compact throughput for the one-line network readout: a bare unit letter, so
/// both directions fit the fixed card width instead of resizing it.
pub fn compactLabel(buffer: []u8, bytes_per_second: f64) []const u8 {
    const units = [_]u8{ 'B', 'K', 'M', 'G' };
    var value = bytes_per_second;
    var index: usize = 0;
    while (value >= 1024 and index + 1 < units.len) : (index += 1) value /= 1024;
    return if (index == 0)
        std.fmt.bufPrint(buffer, "{d:.0}{c}", .{ value, units[index] }) catch ""
    else
        std.fmt.bufPrint(buffer, "{d:.1}{c}", .{ value, units[index] }) catch "";
}

/// Bytes per second that fills the network cell. Unlike the other three series
/// throughput has no natural ceiling, so the window's own peak scales it, with
/// a floor that keeps an idle link flat instead of amplifying stray packets.
pub const network_floor: f64 = 1024;

/// Quantises a throughput ceiling to 1, 2, 5 or 10 × 10ⁿ. Without this the
/// scale would follow the peak every second and the graph would jump about.
pub fn niceCeiling(value: f64) f64 {
    if (!(value > 1)) return 1;
    var magnitude: f64 = 1;
    while (value / magnitude >= 10) magnitude *= 10;
    const scaled = value / magnitude;
    const step: f64 = if (scaled <= 1) 1 else if (scaled <= 2) 2 else if (scaled <= 5) 5 else 10;
    return step * magnitude;
}

pub fn networkCeiling(received: History, sent: History) f64 {
    return @max(network_floor, niceCeiling(@max(received.maximum(), sent.maximum())));
}

fn share(part: i128, whole: i128) f64 {
    if (whole <= 0) return 0;
    return @min(100, @max(0, @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100));
}

/// Retained history plus the raw counters the next reading is differenced against.
pub const State = struct {
    cpu: History = .{},
    gpu: History = .{},
    memory: History = .{},
    /// In and out are kept apart so the graph can draw both directions at once.
    network_in: History = .{},
    network_out: History = .{},
    /// Stays false until some GPU source answers, so the cell can report absence
    /// instead of pretending an unsupported card is permanently idle.
    gpu_available: bool = false,
    previous_cpu: ?Cpu = null,
    previous_network: ?Network = null,
    /// Bytes per second in each direction behind the newest network samples.
    throughput_in: f64 = 0,
    throughput_out: f64 = 0,
    pub fn sampleCpu(self: *State, text: []const u8) void {
        const current = cpu(text) orelse return;
        defer self.previous_cpu = current;
        if (self.previous_cpu) |previous| if (usage(previous, current)) |value| self.cpu.push(value);
    }
    pub fn sampleMemory(self: *State, text: []const u8) void {
        if (memory(text)) |value| self.memory.push(value);
    }
    pub fn sampleNetwork(self: *State, text: []const u8, seconds: f64) void {
        const current = network(text) orelse return;
        defer self.previous_network = current;
        const previous = self.previous_network orelse return;
        self.throughput_in = rate(previous.received, current.received, seconds) orelse 0;
        self.throughput_out = rate(previous.sent, current.sent, seconds) orelse 0;
        self.network_in.push(self.throughput_in);
        self.network_out.push(self.throughput_out);
    }
    pub fn sampleGpu(self: *State, percent: ?f64) void {
        if (percent != null) self.gpu_available = true;
        self.gpu.push(percent orelse 0);
    }
};

test "cpu aggregate ignores guest double counting and reports the busy share" {
    const first = cpu("cpu  0 0 0 0 0 0 0 0 0 0\ncpu0 1 1 1 1 1 1 1 1 1 1\nintr 42\n").?;
    try std.testing.expectEqual(Cpu{ .total = 0, .idle = 0 }, first);
    const second = cpu("cpu  10 0 10 70 10 0 0 0 500 500\n").?;
    try std.testing.expectEqual(@as(u64, 100), second.total);
    try std.testing.expectEqual(@as(u64, 80), second.idle);
    try std.testing.expectApproxEqAbs(@as(f64, 20), usage(first, second).?, 0.0001);
    // Counters that did not advance, or went backwards across a reset, yield nothing.
    try std.testing.expect(usage(second, second) == null);
    try std.testing.expect(usage(second, first) == null);
    // A truncated line is rejected rather than read as a fully idle processor.
    try std.testing.expect(cpu("cpu  1 2 3\n") == null);
    try std.testing.expect(cpu("intr 42 0 0\n") == null);
}

test "memory counts reclaimable pages as free" {
    const text = "MemTotal:       32659884 kB\nMemFree:         1234567 kB\nMemAvailable:   16329942 kB\nBuffers:          123456 kB\n";
    try std.testing.expectApproxEqAbs(@as(f64, 50), memory(text).?, 0.0001);
    try std.testing.expect(memory("MemTotal: 0 kB\nMemAvailable: 0 kB\n") == null);
    try std.testing.expect(memory("MemTotal: 100 kB\n") == null);
    try std.testing.expect(memory("MemFree: 100 kB\n") == null);
}

test "network sums every interface except loopback" {
    const text =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo: 1234567    8901    0    0    0     0          0         0  1234567    8901    0    0    0     0       0          0
        \\  eth0:    1000      10    0    0    0     0          0         0     2000      20    0    0    0     0       0          0
        \\ wlan0:    500       5    0    0    0     0          0         0     700       7    0    0    0     0       0          0
        \\
    ;
    try std.testing.expectEqual(Network{ .received = 1500, .sent = 2700 }, network(text).?);
    try std.testing.expect(network("Inter-| Receive | Transmit\n face |bytes\n") == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), rate(1000, 3000, 2).?, 0.0001);
    try std.testing.expect(rate(3000, 1000, 2) == null);
    try std.testing.expect(rate(1000, 3000, 0) == null);
}

test "gpu readings outside a percentage are rejected" {
    try std.testing.expectApproxEqAbs(@as(f64, 42), gpu("42\n").?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), gpu(" 0 \n").?, 0.0001);
    try std.testing.expect(gpu("150\n") == null);
    try std.testing.expect(gpu("\n") == null);
}

test "the retained window drops the oldest sample and keeps its peak" {
    var ring: History = .{};
    try std.testing.expect(ring.newest() == null);
    ring.push(90);
    var index: usize = 1;
    while (index < window + 5) : (index += 1) ring.push(@floatFromInt(index));
    try std.testing.expectEqual(@as(usize, window), ring.count);
    try std.testing.expectEqual(@as(usize, 5), ring.start);
    try std.testing.expectApproxEqAbs(@as(f64, 5), ring.at(0), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, window + 4), ring.newest().?, 0.0001);
    // The overwritten 90 is gone, so the peak is the newest sample.
    try std.testing.expectApproxEqAbs(@as(f64, window + 4), ring.maximum(), 0.0001);
}

test "throughput scales by unit and quantises so the network graph cannot jump" {
    var buffer: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", throughputLabel(&buffer, 0));
    try std.testing.expectEqualStrings("512 B/s", throughputLabel(&buffer, 512));
    try std.testing.expectEqualStrings("2.0 KiB/s", throughputLabel(&buffer, 2048));
    try std.testing.expectEqualStrings("5.0 MiB/s", throughputLabel(&buffer, 5 * 1024 * 1024));
    var compact: [12]u8 = undefined;
    try std.testing.expectEqualStrings("0B", compactLabel(&compact, 0));
    try std.testing.expectEqualStrings("512B", compactLabel(&compact, 512));
    try std.testing.expectEqualStrings("2.0K", compactLabel(&compact, 2048));
    try std.testing.expectEqualStrings("340.0K", compactLabel(&compact, 340 * 1024));
    try std.testing.expectEqualStrings("1.2M", compactLabel(&compact, 1.2 * 1024 * 1024));
    // Only 1, 2, 5 and 10 times a power of ten, so ordinary fluctuation cannot
    // move the scale, and with it the drawn line, from one second to the next.
    try std.testing.expectEqual(@as(f64, 1), niceCeiling(0));
    try std.testing.expectEqual(@as(f64, 1000), niceCeiling(900));
    try std.testing.expectEqual(@as(f64, 2000), niceCeiling(1696));
    try std.testing.expectEqual(@as(f64, 5000), niceCeiling(2100));
    try std.testing.expectEqual(@as(f64, 10000000), niceCeiling(5242880));
    // An empty or idle window keeps the floor rather than collapsing to nothing.
    try std.testing.expectEqual(network_floor, networkCeiling(.{}, .{}));
    var idle: History = .{};
    idle.push(12);
    try std.testing.expectEqual(network_floor, networkCeiling(idle, .{}));
    // Two peaks either side of ordinary jitter land on the same scale.
    var first: History = .{};
    first.push(1400);
    var second: History = .{};
    second.push(1600);
    try std.testing.expectEqual(networkCeiling(first, .{}), networkCeiling(second, .{}));
    // The busier direction sets the shared scale, so both lines stay comparable.
    var quiet: History = .{};
    quiet.push(500);
    var busy: History = .{};
    busy.push(network_floor * 8);
    try std.testing.expectEqual(@as(f64, 10000), networkCeiling(quiet, busy));
    try std.testing.expectEqual(@as(f64, 10000), networkCeiling(busy, quiet));
}

test "every series renders by default and the picker hides only what it names" {
    const all = Selection{};
    for (series) |kind| try std.testing.expect(kind.enabled(all));
    const only_network = Selection{ .cpu = false, .gpu = false, .memory = false, .network = true };
    for (series) |kind| try std.testing.expectEqual(kind == .network, kind.enabled(only_network));
    const none = Selection{ .cpu = false, .gpu = false, .memory = false, .network = false };
    for (series) |kind| try std.testing.expect(!kind.enabled(none));
    // The picker and the bar mode both surface as labels, so they stay distinct.
    for (std.enums.values(Mode)) |mode| try std.testing.expect(mode.label().len > 0 and mode.description().len > 0);
    try std.testing.expectEqualStrings("Memory", Series.memory.label());
    try std.testing.expectEqualStrings("RAM", abbreviation(.memory));
}

test "state differences consecutive readings and records gpu absence separately" {
    var state: State = .{};
    state.sampleCpu("cpu  0 0 0 0 0 0 0 0 0 0\n");
    try std.testing.expectEqual(@as(usize, 0), state.cpu.count);
    state.sampleCpu("cpu  10 0 10 70 10 0 0 0 0 0\n");
    try std.testing.expectApproxEqAbs(@as(f64, 20), state.cpu.newest().?, 0.0001);
    state.sampleMemory("MemTotal: 200 kB\nMemAvailable: 50 kB\n");
    try std.testing.expectApproxEqAbs(@as(f64, 75), state.memory.newest().?, 0.0001);
    state.sampleNetwork("  eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n", 2);
    try std.testing.expectEqual(@as(usize, 0), state.network_in.count);
    try std.testing.expectEqual(@as(usize, 0), state.network_out.count);
    state.sampleNetwork("  eth0: 3000 0 0 0 0 0 0 0 6000 0 0 0 0 0 0 0\n", 2);
    // 2000 received and 4000 sent over two seconds: 1000 in, 2000 out per second.
    try std.testing.expectApproxEqAbs(@as(f64, 1000), state.throughput_in, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2000), state.throughput_out, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), state.network_in.newest().?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2000), state.network_out.newest().?, 0.0001);
    try std.testing.expect(!state.gpu_available);
    state.sampleGpu(null);
    try std.testing.expect(!state.gpu_available);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.gpu.newest().?, 0.0001);
    state.sampleGpu(35);
    try std.testing.expect(state.gpu_available);
    try std.testing.expectApproxEqAbs(@as(f64, 35), state.gpu.newest().?, 0.0001);
}
