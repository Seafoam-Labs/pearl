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
    usage: ?f64 = null,
    used: ?f64 = null,
    total: ?f64 = null,
    temp: ?f64 = null,
    power: ?f64 = null,
    encode: ?f64 = null,
    decode: ?f64 = null,
    frequency: ?f64 = null,
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
