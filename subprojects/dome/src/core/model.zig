const std = @import("std");
pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity + 1]u8 = @splat(0),
        len: usize = 0,
        const Self = @This();
        pub fn init(value: []const u8) Self {
            var result: Self = .{};
            result.set(value);
            return result;
        }
        pub fn set(self: *Self, value: []const u8) void {
            var n = @min(value.len, capacity);
            while (n > 0 and !std.unicode.utf8ValidateSlice(value[0..n])) : (n -= 1) {}
            @memcpy(self.bytes[0..n], value[0..n]);
            for (self.bytes[0..n]) |*ch| if (ch.* < 32 or ch.* == 127) {
                ch.* = ' ';
            };
            self.bytes[n] = 0;
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn z(self: *const Self) [*:0]const u8 {
            return @ptrCast(&self.bytes);
        }
    };
}
pub const Name = Text(128);
pub const Path = Text(512);
pub const Identity = struct {
    pid: i32 = 0,
    start: u64 = 0,
    pub fn eql(a: Identity, b: Identity) bool {
        return a.pid == b.pid and a.start == b.start;
    }
};
pub const Process = struct {
    id: Identity = .{},
    name: Name = .{},
    exe: Path = .{},
    group: Text(192) = .{},
    uid: u32 = 0,
    parent: i32 = 0,
    threads: u64 = 0,
    rss: u64 = 0,
    ticks: u64 = 0,
    read: ?u64 = null,
    write: ?u64 = null,
    cpu: ?f64 = null,
    read_rate: ?f64 = null,
    write_rate: ?f64 = null,
    state: u8 = '?',
    members: u32 = 1,
    is_group: bool = false,
};
pub const Cpu = struct {
    total: u64 = 0,
    idle: u64 = 0,
    wait: u64 = 0,
    usage: ?f64 = null,
    io_wait: ?f64 = null,
};
pub const Mount = struct { device: DeviceNumber = .{}, path: Path = .{}, kind: Name = .{}, total: u64 = 0, available: u64 = 0 };
pub const DeviceNumber = struct { major: u32 = 0, minor: u32 = 0 };
pub const Memory = struct {
    total: u64 = 0,
    available: ?u64 = null,
    free: u64 = 0,
    cached: u64 = 0,
    buffers: u64 = 0,
    reclaimable: u64 = 0,
    shared: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    pub fn used(self: Memory) ?u64 {
        return if (self.available) |v| self.total -| v else null;
    }
};
pub const Disk = struct {
    key: Path = .{},
    name: Name = .{},
    model: Name = .{},
    major: u32 = 0,
    minor: u32 = 0,
    read: u64 = 0,
    write: u64 = 0,
    busy: u64 = 0,
    ops: u64 = 0,
    ms: u64 = 0,
    size: u64 = 0,
    read_rate: ?f64 = null,
    write_rate: ?f64 = null,
    activity: ?f64 = null,
    latency: ?f64 = null,
};
pub const Network = struct {
    key: Path = .{},
    name: Name = .{},
    mac: Name = .{},
    address: Text(256) = .{},
    state: Name = .{},
    index: u32 = 0,
    rx: u64 = 0,
    tx: u64 = 0,
    speed: ?f64 = null,
    receive: ?f64 = null,
    send: ?f64 = null,
};
pub const Sensor = struct { key: Path = .{}, name: Name = .{}, value: f64 = 0, fan: bool = false };
pub const Gpu = struct {
    key: Path = .{},
    name: Name = .{},
    driver: Name = .{},
    vendor: u32 = 0,
    integrated: bool = false,
    usage: ?f64 = null,
    mem_usage: ?f64 = null,
    used: ?f64 = null,
    total: ?f64 = null,
    gtt_used: ?f64 = null,
    gtt_total: ?f64 = null,
    temp: ?f64 = null,
    power: ?f64 = null,
    power_cap: ?f64 = null,
    power_label: Name = .{},
    fan: ?f64 = null,
    encode: ?f64 = null,
    decode: ?f64 = null,
    frequency: ?f64 = null,
    mem_frequency: ?f64 = null,
    max_frequency: ?f64 = null,
    pcie_gen: ?u32 = null,
    pcie_width: ?u32 = null,
    reserved: ?f64 = null,
    video_frequency: ?f64 = null,
    pstate: ?u32 = null,
    pcie_tx: ?f64 = null,
    pcie_rx: ?f64 = null,
    cuda: Name = .{},
    cuda_major: ?u32 = null,
    cuda_minor: ?u32 = null,
    throttle: ?u64 = null,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),
    sequence: u64 = 0,
    time: i64 = 0,
    duration: i64 = 0,
    reset: bool = false,
    cpu_name: Name = .{},
    cpus: []Cpu = &.{},
    cpu_ids: []u32 = &.{},
    memory: Memory = .{},
    processes: []Process = &.{},
    disks: []Disk = &.{},
    networks: []Network = &.{},
    sensors: []Sensor = &.{},
    gpus: []Gpu = &.{},
    mounts: []Mount = &.{},
    core_count: usize = 0,
    cache: Text(256) = .{},
    base_frequency: ?f64 = null,
    detail_id: Identity = .{},
    pss: ?u64 = null,
    command: Text(1024) = .{},
    uptime: f64 = 0,
    frequency: ?f64 = null,
    process_denied: usize = 0,
    truncated: bool = false,
    pub fn create() *Snapshot {
        const s = std.heap.c_allocator.create(Snapshot) catch @panic("Out of memory");
        s.* = .{ .arena = .init(std.heap.c_allocator) };
        return s;
    }
    pub fn ref(s: *Snapshot) *Snapshot {
        _ = s.refs.fetchAdd(1, .monotonic);
        return s;
    }
    pub fn unref(s: *Snapshot) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) {
            s.arena.deinit();
            std.heap.c_allocator.destroy(s);
        }
    }
};
pub fn uint(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch null;
}
pub fn number(text: []const u8) ?f64 {
    const n = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \n\r\t")) catch return null;
    return if (std.math.isFinite(n)) n else null;
}
pub fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
pub fn fieldInt(text: []const u8, key: []const u8) ?u64 {
    const v = field(text, key) orelse return null;
    var tokens = std.mem.tokenizeAny(u8, v, " \t");
    return uint(tokens.next() orelse return null);
}
pub fn ueventValue(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equals], " \t"), key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t\r");
    }
    return null;
}
pub fn parseSclkList(text: []const u8) ?f64 {
    var maximum: ?f64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        var previous: ?[]const u8 = null;
        while (words.next()) |word| {
            var value: ?f64 = null;
            if (std.ascii.eqlIgnoreCase(word, "mhz")) {
                if (previous) |number_word| value = number(number_word);
            } else if (word.len > 3 and std.ascii.eqlIgnoreCase(word[word.len - 3 ..], "mhz")) {
                value = number(word[0 .. word.len - 3]);
            }
            if (value) |v| {
                if (v > 0 and (maximum == null or v > maximum.?)) maximum = v;
            }
            previous = word;
        }
    }
    return maximum;
}
pub fn pcieGen(text: []const u8) ?u32 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const speed = number(words.next() orelse return null) orelse return null;
    if (speed == 2.5) return 1;
    if (speed == 5) return 2;
    if (speed == 8) return 3;
    if (speed == 16) return 4;
    if (speed == 32) return 5;
    if (speed == 64) return 6;
    return null;
}
pub fn pciEntryName(entry: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, entry, '[') orelse return entry;
    const close = std.mem.lastIndexOfScalar(u8, entry, ']') orelse return entry;
    if (close <= open + 1) return entry;
    return std.mem.trim(u8, entry[open + 1 .. close], " \t");
}
pub const PciIdsScanner = struct {
    target_vendor: u32,
    target_device: u32,
    vendor: ?u32 = null,
    found: bool = false,
    /// Feed one pci.ids line; returns the preferred device name on a match.
    pub fn feed(self: *PciIdsScanner, line: []const u8) ?[]const u8 {
        if (self.found) return null;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') return null;
        const indented = line.len > 0 and (line[0] == '\t' or line[0] == ' ');
        if (!indented) {
            var words = std.mem.tokenizeAny(u8, trimmed, " \t");
            const first = words.next() orelse {
                self.vendor = null;
                return null;
            };
            self.vendor = std.fmt.parseInt(u32, first, 16) catch null;
            return null;
        }
        if (line[0] == '\t' and line.len > 1 and line[1] == '\t') return null;
        if (self.vendor != self.target_vendor) return null;
        var words = std.mem.tokenizeAny(u8, trimmed, " \t");
        const first = words.next() orelse return null;
        const device = std.fmt.parseInt(u32, first, 16) catch return null;
        if (device != self.target_device) return null;
        const name = std.mem.trim(u8, words.rest(), " \t");
        if (name.len == 0) return null;
        self.found = true;
        return pciEntryName(name);
    }
};
pub const LabeledFile = struct { file: []const u8, label: []const u8 };
pub fn chooseTemp(entries: []const LabeledFile) []const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.label, "edge")) return entry.file;
    return "temp1";
}
pub fn chooseClock(entries: []const LabeledFile, label: []const u8) ?[]const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.label, label)) return entry.file;
    return null;
}
pub fn milliwattsToWatts(value: u32) f64 {
    return @as(f64, @floatFromInt(value)) / 1000;
}
/// NVML PCIe throughput counters are kilobytes/second; dome's byte formatters are base-1024.
pub fn kilobytesToBytes(value: u32) f64 {
    return @as(f64, @floatFromInt(value)) * 1024;
}
pub const max_gpus = 16;
pub const max_gpu_meta_bytes = 192;
pub const max_gpu_row_bytes = 1024;
pub const max_gpu_probe_bytes = 16384;
const ColumnKind = enum { number, int, mask };
const gpu_columns = [_]struct { field: []const u8, kind: ColumnKind = .number }{
    .{ .field = "usage" },
    .{ .field = "used" },
    .{ .field = "total" },
    .{ .field = "temp" },
    .{ .field = "power" },
    .{ .field = "encode" },
    .{ .field = "decode" },
    .{ .field = "mem_usage" },
    .{ .field = "reserved" },
    .{ .field = "frequency" },
    .{ .field = "mem_frequency" },
    .{ .field = "video_frequency" },
    .{ .field = "max_frequency" },
    .{ .field = "power_cap" },
    .{ .field = "fan" },
    .{ .field = "pstate", .kind = .int },
    .{ .field = "pcie_gen", .kind = .int },
    .{ .field = "pcie_width", .kind = .int },
    .{ .field = "pcie_tx" },
    .{ .field = "pcie_rx" },
    .{ .field = "throttle", .kind = .mask },
    .{ .field = "cuda_major", .kind = .int },
    .{ .field = "cuda_minor", .kind = .int },
};
const throttle_names = [_]struct { bit: u64, label: []const u8 }{
    .{ .bit = 0x2, .label = "app-clocks" },
    .{ .bit = 0x4, .label = "sw-power-cap" },
    .{ .bit = 0x8, .label = "hw-slowdown" },
    .{ .bit = 0x20, .label = "sw-thermal" },
    .{ .bit = 0x40, .label = "hw-thermal" },
    .{ .bit = 0x80, .label = "power-brake" },
};
pub fn formatGpuMeta(driver: []const u8, cuda_raw: i32, buf: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    const version = Name.init(std.mem.trim(u8, driver, " \t\r"));
    writer.writeByte('#') catch return null;
    writer.writeByte('\t') catch return null;
    if (version.len == 0) writer.writeByte('-') catch return null else writer.writeAll(version.slice()) catch return null;
    writer.writeByte('\t') catch return null;
    if (cuda_raw <= 0) writer.writeAll("-1") catch return null else writer.print("{d}", .{cuda_raw}) catch return null;
    return buf[0..writer.end];
}
pub fn formatGpuRow(g: *const Gpu, buf: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    writer.writeAll(g.key.slice()) catch return null;
    writer.writeByte('\t') catch return null;
    writer.writeAll(g.name.slice()) catch return null;
    inline for (gpu_columns) |column| {
        writer.writeByte('\t') catch return null;
        switch (column.kind) {
            .number, .int => if (@field(g, column.field)) |value| writer.print("{d}", .{value}) catch return null else writer.writeAll("-1") catch return null,
            .mask => if (@field(g, column.field)) |value| writer.print("{x}", .{value}) catch return null else writer.writeAll("-1") catch return null,
        }
    }
    return buf[0..writer.end];
}
pub fn parseGpuProbe(text: []const u8, out: *[max_gpus]Gpu) usize {
    var driver: ?[]const u8 = null;
    var cuda_raw: i32 = -1;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '#') {
            if (driver != null) continue;
            var words = std.mem.splitScalar(u8, line, '\t');
            _ = words.next() orelse continue;
            const version = words.next() orelse continue;
            cuda_raw = std.fmt.parseInt(i32, std.mem.trim(u8, words.next() orelse "-1", " \t\r"), 10) catch -1;
            driver = version;
            continue;
        }
        if (count >= out.len) continue;
        var words = std.mem.splitScalar(u8, line, '\t');
        const key = words.next() orelse continue;
        if (key.len == 0) continue;
        const name = words.next() orelse continue;
        var gpu: Gpu = .{ .key = Path.init(key), .name = Name.init(name), .vendor = 0x10de };
        inline for (gpu_columns) |column| {
            const value = words.next() orelse "";
            switch (column.kind) {
                .number => if (number(value)) |parsed| {
                    if (parsed >= 0) @field(gpu, column.field) = parsed;
                },
                .int => if (std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t\r\n"), 10)) |parsed| {
                    @field(gpu, column.field) = parsed;
                } else |_| {},
                .mask => {
                    const trimmed = std.mem.trim(u8, value, " \t\r\n");
                    if (!std.mem.eql(u8, trimmed, "-1")) if (std.fmt.parseInt(u64, trimmed, 16)) |parsed| {
                        @field(gpu, column.field) = parsed;
                    } else |_| {};
                },
            }
        }
        out[count] = gpu;
        count += 1;
    }
    var driver_name: Name = .{};
    if (driver) |value| {
        const version = Name.init(std.mem.trim(u8, value, " \t\r"));
        if (version.len > 0 and !std.mem.eql(u8, version.slice(), "-")) {
            var joined: [256]u8 = undefined;
            driver_name.set(std.fmt.bufPrint(&joined, "NVIDIA {s}", .{version.slice()}) catch "NVIDIA NVML");
        }
    }
    if (driver_name.len == 0) driver_name.set("NVIDIA NVML");
    var cuda: Name = .{};
    if (cuda_raw >= 1000) {
        var version: [32]u8 = undefined;
        cuda.set(std.fmt.bufPrint(&version, "{d}.{d}", .{ @divTrunc(cuda_raw, 1000), @divTrunc(@mod(cuda_raw, 1000), 10) }) catch "");
    }
    for (out[0..count]) |*gpu| {
        gpu.driver = driver_name;
        gpu.cuda = cuda;
    }
    return count;
}
pub fn throttleText(mask: u64, buf: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var named = false;
    for (throttle_names) |reason| {
        if (mask & reason.bit == 0) continue;
        if (named) writer.writeAll(", ") catch return null;
        writer.writeAll(reason.label) catch return null;
        named = true;
    }
    return if (named) buf[0..writer.end] else null;
}
pub fn delta(now: u64, before: u64) ?u64 {
    return if (now >= before) now - before else null;
}
pub fn rate(now: u64, before: u64, seconds: f64) ?f64 {
    if (seconds <= 0 or !std.math.isFinite(seconds)) return null;
    return @as(f64, @floatFromInt(delta(now, before) orelse return null)) / seconds;
}
pub fn parseCpu(line: []const u8) ?Cpu {
    var words = std.mem.tokenizeAny(u8, line, " \t\n");
    _ = words.next() orelse return null;
    var fields: [8]u64 = @splat(0);
    var n: usize = 0;
    while (n < fields.len) : (n += 1) {
        const word = words.next() orelse break;
        fields[n] = uint(word) orelse return null;
    }
    if (n < 4) return null;
    var sum: u64 = 0;
    for (fields) |v| sum = std.math.add(u64, sum, v) catch return null;
    return .{ .total = sum, .idle = fields[3], .wait = fields[4] };
}
pub fn cpuRate(now: *Cpu, previous: Cpu) void {
    const total = delta(now.total, previous.total) orelse return;
    const idle = delta(now.idle, previous.idle) orelse return;
    const wait = delta(now.wait, previous.wait) orelse return;
    if (total == 0 or idle > total or wait > total - idle) return;
    now.usage = @as(f64, @floatFromInt(total - idle - wait)) * 100 / @as(f64, @floatFromInt(total));
    now.io_wait = @as(f64, @floatFromInt(wait)) * 100 / @as(f64, @floatFromInt(total));
}
pub fn parseMemory(text: []const u8) Memory {
    var m: Memory = .{};
    inline for (.{ .{ "MemTotal", "total" }, .{ "MemFree", "free" }, .{ "Cached", "cached" }, .{ "Buffers", "buffers" }, .{ "SReclaimable", "reclaimable" }, .{ "Shmem", "shared" }, .{ "SwapTotal", "swap_total" }, .{ "SwapFree", "swap_free" } }) |pair| @field(m, pair[1]) = std.math.mul(u64, fieldInt(text, pair[0]) orelse 0, 1024) catch 0;
    if (fieldInt(text, "MemAvailable")) |v| m.available = @min(m.total, std.math.mul(u64, v, 1024) catch m.total);
    return m;
}
pub fn parseProcess(text: []const u8, page_size: u64) ?Process {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close <= open) return null;
    var p: Process = .{};
    p.id.pid = std.fmt.parseInt(i32, std.mem.trim(u8, text[0..open], " "), 10) catch return null;
    if (p.id.pid <= 0) return null;
    p.name.set(text[open + 1 .. close]);
    var words = std.mem.tokenizeAny(u8, text[close + 1 ..], " \t\n");
    var idx: usize = 3;
    var user: u64 = 0;
    while (words.next()) |word| : (idx += 1) {
        switch (idx) {
            3 => {
                if (word.len != 1) return null;
                p.state = word[0];
            },
            4 => p.parent = std.fmt.parseInt(i32, word, 10) catch return null,
            14 => user = uint(word) orelse return null,
            15 => p.ticks = std.math.add(u64, user, uint(word) orelse return null) catch return null,
            20 => p.threads = uint(word) orelse return null,
            22 => p.id.start = uint(word) orelse return null,
            24 => {
                const pages = std.fmt.parseInt(i64, word, 10) catch return null;
                p.rss = std.math.mul(u64, @intCast(@max(0, pages)), page_size) catch return null;
                return p;
            },
            else => {},
        }
    }
    return null;
}
pub fn processRate(p: *Process, old: Process, seconds: f64, ticks: f64, cores: usize) void {
    if (!p.id.eql(old.id) or ticks <= 0 or cores == 0) return;
    if (rate(p.ticks, old.ticks, seconds)) |r| p.cpu = @min(100, r / ticks / @as(f64, @floatFromInt(cores)) * 100);
    if (p.read) |v| {
        if (old.read) |o| p.read_rate = rate(v, o, seconds);
    }
    if (p.write) |v| {
        if (old.write) |o| p.write_rate = rate(v, o, seconds);
    }
}
pub const History = struct {
    pub const Point = struct { time: i64 = 0, value: ?f64 = null, second: ?f64 = null };
    points: [1202]Point = @splat(.{}),
    head: usize = 0,
    len: usize = 0,
    pub fn add(self: *History, time: i64, value: ?f64, second: ?f64) void {
        self.points[self.head] = .{ .time = time, .value = value, .second = second };
        self.head = (self.head + 1) % self.points.len;
        self.len = @min(self.len + 1, self.points.len);
    }
    pub fn at(self: *const History, index: usize) Point {
        return self.points[(self.head + self.points.len - self.len + index) % self.points.len];
    }
};
test "CPU excludes guest double-counting, treats iowait separately, rejects resets" {
    var next = parseCpu("cpu 40 0 10 40 10 0 0 0 22 0").?;
    cpuRate(&next, .{});
    try std.testing.expectEqual(@as(?f64, 50), next.usage);
    var reset = parseCpu("cpu 1 0 1 1 1").?;
    cpuRate(&reset, next);
    try std.testing.expect(reset.usage == null);
    try std.testing.expect(parseCpu("cpu 1 bad 0 1") == null);
}
test "process names may contain spaces and parentheses; identity gates rates" {
    const line = "123 (odd ) process) S 1 0 0 0 0 0 0 0 0 0 100 20 0 0 0 0 4 0 999 40960 10";
    const p = parseProcess(line, 4096).?;
    try std.testing.expectEqualStrings("odd ) process", p.name.slice());
    try std.testing.expectEqual(@as(u64, 999), p.id.start);
    try std.testing.expectEqual(@as(u64, 40960), p.rss);
    var changed = p;
    changed.id.start += 1;
    processRate(&changed, p, 1, 100, 8);
    try std.testing.expect(changed.cpu == null);
    try std.testing.expect(parseProcess("123 (truncated) S 1", 4096) == null);
}
test "memory, actual elapsed time, missing values and bounded history" {
    const m = parseMemory("MemTotal: 100 kB\nMemAvailable: 40 kB\nCached: 20 kB\n");
    try std.testing.expectEqual(@as(?u64, 60 * 1024), m.used());
    try std.testing.expect(parseMemory("MemTotal: 100 kB").used() == null);
    try std.testing.expectEqual(@as(?f64, 50), rate(200, 100, 2));
    try std.testing.expect(rate(1, 2, 1) == null);
    try std.testing.expect(rate(2, 1, 0) == null);
    var h: History = .{};
    for (0..2000) |n| h.add(@intCast(n), @floatFromInt(n), null);
    try std.testing.expectEqual(@as(usize, 1202), h.len);
    try std.testing.expectEqual(@as(i64, 1999), h.at(h.len - 1).time);
}
test "counter overflow, invalid elapsed values, topology normalization and nullable I/O" {
    try std.testing.expect(parseCpu("cpu 18446744073709551615 1 0 0") == null);
    try std.testing.expect(rate(10, 1, std.math.inf(f64)) == null);
    try std.testing.expect(number("nan") == null);
    var p: Process = .{ .id = .{ .pid = 20, .start = 1 }, .ticks = 200, .read = 1000 };
    const old: Process = .{ .id = p.id, .ticks = 100, .read = 400 };
    processRate(&p, old, 2, 100, 4);
    try std.testing.expectEqual(@as(?f64, 12.5), p.cpu);
    try std.testing.expectEqual(@as(?f64, 300), p.read_rate);
    try std.testing.expect(p.write_rate == null);
    p.cpu = null;
    processRate(&p, old, 1, 100, 0);
    try std.testing.expect(p.cpu == null);
    try std.testing.expectEqualStrings("model", field("model name\t: model\n", "model name").?);
}
test "bounded arbitrary parser input and UTF-8 truncation" {
    var random = std.Random.DefaultPrng.init(0x646f6d65);
    var bytes: [256]u8 = undefined;
    for (0..2000) |_| {
        random.random().bytes(&bytes);
        const slice = bytes[0..random.random().intRangeAtMost(usize, 0, bytes.len)];
        _ = parseProcess(slice, 4096);
        _ = parseCpu(slice);
        _ = parseMemory(slice);
        const text = Text(64).init(slice);
        try std.testing.expect(text.len <= 64);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
        try std.testing.expectEqual(@as(u8, 0), text.bytes[text.len]);
    }
    const text = Text(3).init("abé");
    try std.testing.expectEqualStrings("ab", text.slice());
}
test "GPU sysfs parsers: sclk list, PCIe generation, uevent and labels" {
    try std.testing.expectEqual(@as(?f64, 2500), parseSclkList("0: 500Mhz *\n1: 2200Mhz\n2: 2500 Mhz\n"));
    try std.testing.expectEqual(@as(?f64, null), parseSclkList(""));
    try std.testing.expectEqual(@as(?f64, null), parseSclkList("garbage\n0: fast\n"));
    try std.testing.expectEqual(@as(?u32, 3), pcieGen("8.0 GT/s PCIe"));
    try std.testing.expectEqual(@as(?u32, 1), pcieGen("2.5 GT/s"));
    try std.testing.expectEqual(@as(?u32, 4), pcieGen("16.0 GT/s PCIe"));
    try std.testing.expectEqual(@as(?u32, 5), pcieGen("32.0 GT/s PCIe"));
    try std.testing.expectEqual(@as(?u32, 6), pcieGen("64.0 GT/s PCIe"));
    try std.testing.expectEqual(@as(?u32, null), pcieGen("unknown"));
    try std.testing.expectEqualStrings("0000:03:00.0", ueventValue("DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n", "PCI_SLOT_NAME").?);
    try std.testing.expect(ueventValue("DRIVER=amdgpu\n", "PCI_SLOT_NAME") == null);
    const labels = [_]LabeledFile{ .{ .file = "temp1", .label = "junction" }, .{ .file = "temp2", .label = "edge" } };
    try std.testing.expectEqualStrings("temp2", chooseTemp(&labels));
    try std.testing.expectEqualStrings("temp1", chooseTemp(&.{}));
    const clocks = [_]LabeledFile{ .{ .file = "freq1", .label = "mclk" }, .{ .file = "freq2", .label = "sclk" } };
    try std.testing.expectEqualStrings("freq2", chooseClock(&clocks, "sclk").?);
    try std.testing.expectEqualStrings("freq1", chooseClock(&clocks, "mclk").?);
    try std.testing.expect(chooseClock(&clocks, "vclk") == null);
}
test "pci.ids scanner tokenizes indentation, skips junk and prefers brackets" {
    var scanner: PciIdsScanner = .{ .target_vendor = 0x1002, .target_device = 0x744c };
    try std.testing.expect(scanner.feed("# comment") == null);
    try std.testing.expect(scanner.feed("1002  Advanced Micro Devices, Inc. [AMD/ATI]") == null);
    try std.testing.expect(scanner.feed("\t--  Subclass separator") == null);
    try std.testing.expect(scanner.feed("\tzzzz  Not a device") == null);
    try std.testing.expectEqualStrings("Radeon RX 7900 XT/7900 XTX", scanner.feed("\t744c  Navi 31 [Radeon RX 7900 XT/7900 XTX]").?);
    try std.testing.expect(scanner.feed("\t744c  Duplicate entry") == null);
    var plain: PciIdsScanner = .{ .target_vendor = 0x1002, .target_device = 0x1234 };
    try std.testing.expect(plain.feed("1002  Vendor") == null);
    try std.testing.expectEqualStrings("Plain Device", plain.feed("\t1234  Plain Device").?);
    var wrong_vendor: PciIdsScanner = .{ .target_vendor = 0x8086, .target_device = 0x1234 };
    try std.testing.expect(wrong_vendor.feed("1002  Vendor") == null);
    try std.testing.expect(wrong_vendor.feed("\t1234  Device") == null);
    try std.testing.expect(wrong_vendor.feed("8086  Intel") == null);
    try std.testing.expectEqualStrings("Device", wrong_vendor.feed("\t1234  Device").?);
}
fn fullGpuProbeText() []const u8 {
    return "#\t550.54.14\t12080\n" ++
        "0000:03:00.0\tNVIDIA GeForce RTX 4090\t30\t6442450944\t25769803776\t61\t45.2\t10\t20\t35\t268435456\t2520\t10501\t1500\t2520\t450\t60\t0\t4\t16\t102400\t204800\t26\t1\t8\n";
}
test "GPU probe row decodes every column in canonical units" {
    var devices: [max_gpus]Gpu = undefined;
    const count = parseGpuProbe(fullGpuProbeText(), &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    const g = devices[0];
    try std.testing.expectEqualStrings("0000:03:00.0", g.key.slice());
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 4090", g.name.slice());
    try std.testing.expectEqualStrings("NVIDIA 550.54.14", g.driver.slice());
    try std.testing.expectEqualStrings("12.8", g.cuda.slice());
    try std.testing.expectEqual(@as(u32, 0x10de), g.vendor);
    inline for (.{ .{ "usage", 30.0 }, .{ "used", 6442450944.0 }, .{ "total", 25769803776.0 }, .{ "temp", 61.0 }, .{ "power", 45.2 }, .{ "encode", 10.0 }, .{ "decode", 20.0 }, .{ "mem_usage", 35.0 }, .{ "reserved", 268435456.0 }, .{ "frequency", 2520.0 }, .{ "mem_frequency", 10501.0 }, .{ "video_frequency", 1500.0 }, .{ "max_frequency", 2520.0 }, .{ "power_cap", 450.0 }, .{ "fan", 60.0 }, .{ "pcie_tx", 102400.0 }, .{ "pcie_rx", 204800.0 } }) |pair| {
        try std.testing.expectEqual(@as(?f64, pair[1]), @field(g, pair[0]));
    }
    try std.testing.expectEqual(@as(?u32, 0), g.pstate);
    try std.testing.expectEqual(@as(?u32, 4), g.pcie_gen);
    try std.testing.expectEqual(@as(?u32, 16), g.pcie_width);
    try std.testing.expectEqual(@as(?u64, 0x26), g.throttle);
    try std.testing.expectEqual(@as(?u32, 1), g.cuda_major);
    try std.testing.expectEqual(@as(?u32, 8), g.cuda_minor);
}
test "GPU probe sentinels: -1, missing columns and malformed lines" {
    var devices: [max_gpus]Gpu = undefined;
    var count = parseGpuProbe("0000:03:00.0\tGPU\t-1\t-1\t-1\t-1\t-1\t-1\t-1\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    inline for (gpu_columns) |column| try std.testing.expect(@field(devices[0], column.field) == null);
    count = parseGpuProbe("0000:03:00.0\tGPU\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(devices[0].usage == null);
    count = parseGpuProbe("garbage without tabs\n\n\tmissing key\tvalue\n0000:03:00.0\tGPU\t0\t0\t0\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(?f64, 0), devices[0].usage);
    try std.testing.expectEqual(@as(?f64, 0), devices[0].total);
    // Zero is a reading, not unknown: pstate 0 survives as a value.
    count = parseGpuProbe("0000:03:00.0\tGPU\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(?u32, 0), devices[0].pstate);
    try std.testing.expectEqual(@as(?u64, 0), devices[0].throttle);
    // pstate 8 and the 15 upper bound decode; the child maps UNKNOWN (32) to the -1 sentinel.
    const base = "0000:03:00.0\tGPU";
    const zeros = "\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0";
    count = parseGpuProbe(base ++ zeros ++ "\t8\t4\t16\n", &devices);
    try std.testing.expectEqual(@as(?u32, 8), devices[0].pstate);
    count = parseGpuProbe(base ++ zeros ++ "\t15\t4\t16\n", &devices);
    try std.testing.expectEqual(@as(?u32, 15), devices[0].pstate);
    count = parseGpuProbe(base ++ zeros ++ "\t-1\t4\t16\n", &devices);
    try std.testing.expect(devices[0].pstate == null);
    count = parseGpuProbe("0000:03:00.0\tGPU\t30\t30\t30\t30\t30\t30\t30\tignored\textra\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(?f64, 30), devices[0].decode);
    try std.testing.expect(devices[0].mem_usage == null);
}
test "GPU probe meta: first line wins, applies after rows, defaults on absent" {
    var devices: [max_gpus]Gpu = undefined;
    var count = parseGpuProbe("#\t-\t-1\n0000:03:00.0\tGPU\t30\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("NVIDIA NVML", devices[0].driver.slice());
    try std.testing.expectEqual(@as(usize, 0), devices[0].cuda.len);
    count = parseGpuProbe("0000:03:00.0\tGPU\t30\n#\t545.23.08\t12100\n", &devices);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("NVIDIA 545.23.08", devices[0].driver.slice());
    try std.testing.expectEqualStrings("12.10", devices[0].cuda.slice());
    count = parseGpuProbe("#\t550.1\t12080\n#\tignored\t9999\n0000:03:00.0\tGPU\t30\n", &devices);
    try std.testing.expectEqualStrings("NVIDIA 550.1", devices[0].driver.slice());
    try std.testing.expectEqualStrings("12.8", devices[0].cuda.slice());
    count = parseGpuProbe("0000:03:00.0\tGPU\t30\n", &devices);
    try std.testing.expectEqualStrings("NVIDIA NVML", devices[0].driver.slice());
    try std.testing.expectEqual(@as(usize, 0), devices[0].cuda.len);
    count = parseGpuProbe("#\t550.1\t0\n0000:03:00.0\tGPU\t30\n", &devices);
    try std.testing.expectEqual(@as(usize, 0), devices[0].cuda.len);
    count = parseGpuProbe("#\t550.1\t999\n0000:03:00.0\tGPU\t30\n", &devices);
    try std.testing.expectEqual(@as(usize, 0), devices[0].cuda.len);
}
test "GPU probe truncates beyond 16 devices" {
    var devices: [max_gpus]Gpu = undefined;
    var text: [6000]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    for (0..20) |i| {
        writer.print("{d}\tGPU\t30\n", .{i}) catch unreachable;
    }
    const count = parseGpuProbe(text[0..writer.end], &devices);
    try std.testing.expectEqual(@as(usize, max_gpus), count);
}
test "GPU probe int columns reject floats, sentinels and overflow" {
    var devices: [max_gpus]Gpu = undefined;
    // pstate, pcie_gen and pcie_width sit at table positions 15, 16 and 17.
    const base = "0000:03:00.0\tGPU";
    const zeros = "\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0";
    _ = parseGpuProbe(base ++ zeros ++ "\t1.5\t4\t16\n", &devices);
    try std.testing.expect(devices[0].pstate == null);
    try std.testing.expectEqual(@as(?u32, 4), devices[0].pcie_gen);
    _ = parseGpuProbe(base ++ zeros ++ "\t99999999999\t-1\t0x10\n", &devices);
    try std.testing.expect(devices[0].pstate == null);
    try std.testing.expect(devices[0].pcie_gen == null);
    try std.testing.expect(devices[0].pcie_width == null);
}
test "GPU probe mask column is exact u64 hex, not float" {
    var devices: [max_gpus]Gpu = undefined;
    const base = "0000:03:00.0\tGPU";
    const zeros = "\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0";
    _ = parseGpuProbe(base ++ zeros ++ "\tffffffffffffffff\n", &devices);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), devices[0].throttle);
    _ = parseGpuProbe(base ++ zeros ++ "\tdeadbeef\n", &devices);
    try std.testing.expectEqual(@as(?u64, 0xdeadbeef), devices[0].throttle);
    _ = parseGpuProbe(base ++ zeros ++ "\t-1\n", &devices);
    try std.testing.expect(devices[0].throttle == null);
    _ = parseGpuProbe(base ++ zeros ++ "\tnotanumber\n", &devices);
    try std.testing.expect(devices[0].throttle == null);
}
test "GPU probe codec round trips and stays stable" {
    var source: Gpu = .{ .key = Path.init("0000:03:00.0"), .name = Name.init("GeForce RTX 4090") };
    source.usage = 0;
    source.used = 6442450944;
    source.total = 25769803776;
    source.temp = 0;
    source.power = 45.2;
    source.encode = 0;
    source.decode = 100;
    source.mem_usage = 35;
    source.reserved = 0;
    source.frequency = 2520;
    source.mem_frequency = 10501;
    source.video_frequency = 1500;
    source.max_frequency = 2520;
    source.power_cap = 450;
    source.fan = 0;
    source.pstate = 0;
    source.pcie_gen = 4;
    source.pcie_width = 16;
    source.pcie_tx = 102400;
    source.pcie_rx = 0;
    source.throttle = 0xdeadc0decafebabe;
    source.cuda_major = 1;
    source.cuda_minor = 0;
    var row: [max_gpu_row_bytes]u8 = undefined;
    const formatted = formatGpuRow(&source, &row).?;
    var devices: [max_gpus]Gpu = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseGpuProbe(formatted, &devices));
    const g = devices[0];
    inline for (.{ "usage", "used", "total", "temp", "power", "encode", "decode", "mem_usage", "reserved", "frequency", "mem_frequency", "video_frequency", "max_frequency", "power_cap", "fan", "pstate", "pcie_gen", "pcie_width", "pcie_tx", "pcie_rx", "cuda_major", "cuda_minor" }) |column| {
        try std.testing.expectEqual(@field(&source, column), @field(g, column));
    }
    try std.testing.expectEqual(@as(?u64, 0xdeadc0decafebabe), g.throttle);
    var again: [max_gpu_row_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(formatted, formatGpuRow(&g, &again).?);
}
test "GPU throttle labels follow fixed order and skip unnamed bits" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("app-clocks, sw-power-cap, sw-thermal", throttleText(0x26, &buf).?);
    try std.testing.expect(throttleText(0x1, &buf) == null);
    try std.testing.expect(throttleText(0x100 | 0x200 | 0x400, &buf) == null);
    try std.testing.expect(throttleText(0, &buf) == null);
    var single: [128]u8 = undefined;
    try std.testing.expectEqualStrings("hw-thermal", throttleText(0x40, &single).?);
}
test "GPU probe formatting returns null instead of truncating" {
    var g: Gpu = .{ .key = Path.init("0000:03:00.0"), .name = Name.init("Long device name that should overflow a very tiny buffer for the formatter test to fail"), .usage = 5 };
    var tiny: [32]u8 = undefined;
    try std.testing.expect(formatGpuRow(&g, &tiny) == null);
    try std.testing.expect(formatGpuMeta("550.54.14", 12080, tiny[0..8]) == null);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("#\t550.54.14\t12080", formatGpuMeta(" 550.54.14 ", 12080, &buf).?);
    try std.testing.expectEqualStrings("#\t-\t-1", formatGpuMeta("", 0, &buf).?);
}
test "GPU probe output fits the provider guard at maximum width" {
    const long_name: [128]u8 = @splat('x');
    var g: Gpu = .{ .key = Path.init("0000:0000:00.0"), .name = Name.init(&long_name) };
    const huge: f64 = @floatFromInt(std.math.maxInt(u64));
    g.usage = huge;
    g.used = huge;
    g.total = huge;
    g.temp = huge;
    g.power = huge;
    g.encode = huge;
    g.decode = huge;
    g.mem_usage = huge;
    g.reserved = huge;
    g.frequency = huge;
    g.mem_frequency = huge;
    g.video_frequency = huge;
    g.max_frequency = huge;
    g.power_cap = huge;
    g.fan = huge;
    g.pstate = std.math.maxInt(u32);
    g.pcie_gen = std.math.maxInt(u32);
    g.pcie_width = std.math.maxInt(u32);
    g.pcie_tx = huge;
    g.pcie_rx = huge;
    g.throttle = std.math.maxInt(u64);
    g.cuda_major = std.math.maxInt(u32);
    g.cuda_minor = std.math.maxInt(u32);
    var total: usize = max_gpu_meta_bytes;
    var row: [max_gpu_row_bytes]u8 = undefined;
    for (0..max_gpus) |_| total += (formatGpuRow(&g, &row) orelse return error.TestUnexpectedResult).len + 1;
    try std.testing.expect(total <= max_gpu_probe_bytes);
}
test "GPU probe helpers survive bounded random input" {
    var devices: [max_gpus]Gpu = undefined;
    var buf: [512]u8 = undefined;
    var seed: u64 = 0x646f6d65;
    for (0..500) |i| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        var random = std.Random.DefaultPrng.init(seed);
        for (buf[0..64]) |*ch| ch.* = random.random().int(u8);
        _ = parseGpuProbe(buf[0..64], &devices);
        _ = throttleText(random.random().int(u64), &buf);
        _ = formatGpuMeta(buf[0..random.random().intRangeAtMost(usize, 0, 64)], @as(i32, @bitCast(random.random().int(u32))), &buf);
        _ = i;
    }
}
test "unit helpers convert NVML scales to canonical model units" {
    try std.testing.expectEqual(@as(f64, 12.345), milliwattsToWatts(12345));
    try std.testing.expectEqual(@as(f64, 35840), kilobytesToBytes(35));
    try std.testing.expectEqual(@as(f64, 0), milliwattsToWatts(0));
}
