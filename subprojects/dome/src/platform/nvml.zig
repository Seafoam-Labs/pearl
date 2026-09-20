//! Optional NVIDIA probe runs in a disposable child so a driver cannot block GTK or collection.
const std = @import("std");
const io = @import("io.zig");
const c = io.c;
const m = @import("../core/model.zig");
const u = @import("../ui/widgets.zig");
pub const Provider = struct {
    child: ?*c.GSubprocess = null,
    cancel: ?*c.GCancellable = null,
    timeout: c_uint = 0,
    closed: bool = false,
    last_attempt: i64 = 0,
    last_success: i64 = 0,
    devices: [16]m.Gpu = undefined,
    count: usize = 0,
    timeouts: usize = 0,
    pub fn tick(self: *Provider, enabled: bool) void {
        if (!enabled or self.closed or self.child != null or io.monotonic() - self.last_attempt < 5000000) return;
        self.last_attempt = io.monotonic();
        // Resolve in the spawned child, retaining this executable even after an on-disk upgrade.
        const argv = [_]?[*:0]const u8{ "/proc/self/exe", "--gpu-probe", null };
        var err: ?*c.GError = null;
        self.child = c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE, &err);
        defer if (err) |e| c.g_error_free(e);
        if (self.child == null) return;
        self.cancel = c.g_cancellable_new().?;
        self.timeout = c.g_timeout_add(1200, expired, self);
        c.g_subprocess_communicate_utf8_async(self.child, null, self.cancel, finished, self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(Provider, data);
        self.timeout = 0;
        self.timeouts += 1;
        if (self.child) |child| c.g_subprocess_force_exit(child);
        return 0;
    }
    fn finished(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Provider, data);
        var output: [*c]u8 = null;
        var err: ?*c.GError = null;
        const ok = c.g_subprocess_communicate_utf8_finish(u.cast(c.GSubprocess, source), result, &output, null, &err);
        defer if (err) |e| c.g_error_free(e);
        defer if (output != null) c.g_free(output);
        if (self.timeout != 0) {
            _ = c.g_source_remove(self.timeout);
            self.timeout = 0;
        }
        if (!self.closed) {
            self.count = 0;
            if (ok != 0 and output != null) {
                const text = std.mem.span(output);
                if (text.len <= 16384) {
                    var lines = std.mem.splitScalar(u8, text, '\n');
                    while (lines.next()) |line| {
                        if (self.count >= 16) break;
                        var words = std.mem.splitScalar(u8, line, '\t');
                        const key = words.next() orelse continue;
                        const name = words.next() orelse continue;
                        var gpu: m.Gpu = .{ .key = m.Path.init(key), .name = m.Name.init(name), .vendor = 0x10de, .driver = m.Name.init("NVIDIA NVML") };
                        inline for (.{ "usage", "used", "total", "temp", "power", "encode", "decode" }) |field| {
                            const number = m.number(words.next() orelse "") orelse -1;
                            if (number >= 0) @field(gpu, field) = number / (if (comptime std.mem.eql(u8, field, "power")) @as(f64, 1000) else 1);
                        }
                        self.devices[self.count] = gpu;
                        self.count += 1;
                    }
                    if (self.count > 0) self.last_success = io.monotonic();
                }
            }
        }
        c.g_object_unref(self.child);
        self.child = null;
        c.g_object_unref(self.cancel);
        self.cancel = null;
    }
    pub fn resolve(self: *Provider, original: m.Gpu) m.Gpu {
        if (original.vendor != 0x10de or io.monotonic() - self.last_success > 10000000) return original;
        for (self.devices[0..self.count]) |device| if (std.mem.endsWith(u8, original.key.slice(), device.key.slice())) {
            var result = device;
            result.key = original.key;
            return result;
        };
        return original;
    }
    pub fn deinit(self: *Provider) void {
        self.closed = true;
        if (self.child) |child| {
            c.g_subprocess_force_exit(child);
            c.g_cancellable_cancel(self.cancel);
            while (self.child != null) _ = c.g_main_context_iteration(null, 1);
        }
        if (self.timeout != 0) {
            _ = c.g_source_remove(self.timeout);
            self.timeout = 0;
        }
    }
};
pub fn probe() void {
    if (@import("build_options").test_hooks and c.g_getenv("DOME_TEST_GPU_HANG") != null) {
        while (true) _ = c.pause();
    }
    const lib = c.dlopen("libnvidia-ml.so.1", c.RTLD_NOW | c.RTLD_LOCAL) orelse return;
    defer _ = c.dlclose(lib);
    const Init = *const fn () callconv(.c) c_int;
    const init: @TypeOf(@as(Init, undefined)) = @ptrCast(c.dlsym(lib, "nvmlInit_v2") orelse return);
    const shutdown: Init = @ptrCast(c.dlsym(lib, "nvmlShutdown") orelse return);
    if (init() != 0) return;
    defer _ = shutdown();
    const Count = *const fn (*c_uint) callconv(.c) c_int;
    const count_fn: Count = @ptrCast(c.dlsym(lib, "nvmlDeviceGetCount_v2") orelse return);
    var count: c_uint = 0;
    if (count_fn(&count) != 0) return;
    const Device = ?*anyopaque;
    const Handle = *const fn (c_uint, *Device) callconv(.c) c_int;
    const handle: Handle = @ptrCast(c.dlsym(lib, "nvmlDeviceGetHandleByIndex_v2") orelse return);
    const String = *const fn (Device, [*]u8, c_uint) callconv(.c) c_int;
    const name_fn: String = @ptrCast(c.dlsym(lib, "nvmlDeviceGetName") orelse return);
    const Pci = extern struct { bus_id_legacy: [16]u8, domain: c_uint, bus: c_uint, device: c_uint, pci_device_id: c_uint, pci_subsystem_id: c_uint, bus_id: [32]u8 };
    const PciFn = *const fn (Device, *Pci) callconv(.c) c_int;
    const pci_fn: PciFn = @ptrCast(c.dlsym(lib, "nvmlDeviceGetPciInfo_v3") orelse return);
    const Util = extern struct { gpu: c_uint, memory: c_uint };
    const UtilFn = *const fn (Device, *Util) callconv(.c) c_int;
    const Memory = extern struct { total: c_ulonglong, free: c_ulonglong, used: c_ulonglong };
    const MemFn = *const fn (Device, *Memory) callconv(.c) c_int;
    const UintFn = *const fn (Device, *c_uint) callconv(.c) c_int;
    const TempFn = *const fn (Device, c_uint, *c_uint) callconv(.c) c_int;
    const VideoFn = *const fn (Device, *c_uint, *c_uint) callconv(.c) c_int;
    for (0..@min(count, 16)) |i| {
        var device: Device = null;
        if (handle(@intCast(i), &device) != 0) continue;
        var name: [128]u8 = @splat(0);
        _ = name_fn(device, &name, name.len);
        name[name.len - 1] = 0;
        for (&name) |*ch| if (ch.* == '\t' or ch.* == '\n') {
            ch.* = ' ';
        };
        var pci: Pci = std.mem.zeroes(Pci);
        if (pci_fn(device, &pci) != 0) continue;
        var util: Util = .{ .gpu = 0, .memory = 0 };
        var usage: i64 = -1;
        if (c.dlsym(lib, "nvmlDeviceGetUtilizationRates")) |f| if (@as(UtilFn, @ptrCast(f))(device, &util) == 0) {
            usage = util.gpu;
        };
        var memory: Memory = std.mem.zeroes(Memory);
        var used: i64 = -1;
        var total: i64 = -1;
        if (c.dlsym(lib, "nvmlDeviceGetMemoryInfo")) |f| if (@as(MemFn, @ptrCast(f))(device, &memory) == 0) {
            used = @intCast(@min(memory.used, std.math.maxInt(i64)));
            total = @intCast(@min(memory.total, std.math.maxInt(i64)));
        };
        var value: c_uint = 0;
        var power: i64 = -1;
        if (c.dlsym(lib, "nvmlDeviceGetPowerUsage")) |f| if (@as(UintFn, @ptrCast(f))(device, &value) == 0) {
            power = value;
        };
        var temp: i64 = -1;
        if (c.dlsym(lib, "nvmlDeviceGetTemperature")) |f| if (@as(TempFn, @ptrCast(f))(device, 0, &value) == 0) {
            temp = value;
        };
        var enc: i64 = -1;
        var dec: i64 = -1;
        var period: c_uint = 0;
        if (c.dlsym(lib, "nvmlDeviceGetEncoderUtilization")) |f| if (@as(VideoFn, @ptrCast(f))(device, &value, &period) == 0) {
            enc = value;
        };
        if (c.dlsym(lib, "nvmlDeviceGetDecoderUtilization")) |f| if (@as(VideoFn, @ptrCast(f))(device, &value, &period) == 0) {
            dec = value;
        };
        c.g_print("%04x:%02x:%02x.0\t%s\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\n", pci.domain, pci.bus, pci.device, &name, usage, used, total, temp, power, enc, dec);
    }
}
