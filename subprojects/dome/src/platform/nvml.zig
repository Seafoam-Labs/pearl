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
                    self.count = m.parseGpuProbe(text, &self.devices);
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
const NVML_CLOCK_SM = 1;
const NVML_CLOCK_MEM = 2;
const NVML_CLOCK_VIDEO = 3;
const NVML_PCIE_UTIL_TX_BYTES = 0;
const NVML_PCIE_UTIL_RX_BYTES = 1;
const NVML_PSTATE_MAX = 15;
inline fn symbol(comptime T: type, lib: *anyopaque, name: [*:0]const u8) ?T {
    const resolved = c.dlsym(lib, name) orelse return null;
    return @ptrCast(resolved);
}
/// Direct write-all: rows must not sit in stdio buffers if teardown stalls, and
/// device names must never reach a format string.
fn writeOutput(bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wrote = c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (wrote > 0) {
            offset += @intCast(wrote);
            continue;
        }
        if (wrote < 0 and c.__errno_location().* == c.EINTR) continue;
        return false;
    }
    return true;
}
pub fn probe() void {
    if (@import("build_options").test_hooks and c.g_getenv("DOME_TEST_GPU_HANG") != null) {
        while (true) _ = c.pause();
    }
    const lib = c.dlopen("libnvidia-ml.so.1", c.RTLD_NOW | c.RTLD_LOCAL) orelse return;
    const Init = *const fn () callconv(.c) c_int;
    const init: Init = @ptrCast(c.dlsym(lib, "nvmlInit_v2") orelse return);
    if (init() != 0) return;
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
    const MemoryV2 = extern struct { version: c_uint, total: c_ulonglong, reserved: c_ulonglong, free: c_ulonglong, used: c_ulonglong };
    const MemoryV2Fn = *const fn (Device, *MemoryV2) callconv(.c) c_int;
    const Memory = extern struct { total: c_ulonglong, free: c_ulonglong, used: c_ulonglong };
    const MemFn = *const fn (Device, *Memory) callconv(.c) c_int;
    const UintFn = *const fn (Device, *c_uint) callconv(.c) c_int;
    const TypedFn = *const fn (Device, c_uint, *c_uint) callconv(.c) c_int;
    const VideoFn = *const fn (Device, *c_uint, *c_uint) callconv(.c) c_int;
    const MaskFn = *const fn (Device, *c_ulonglong) callconv(.c) c_int;
    const ComputeFn = *const fn (Device, *c_int, *c_int) callconv(.c) c_int;
    const CudaFn = *const fn (*c_int) callconv(.c) c_int;
    const SystemString = *const fn ([*]u8, c_uint) callconv(.c) c_int;
    const get_memory_v2 = symbol(MemoryV2Fn, lib, "nvmlDeviceGetMemoryInfo_v2");
    const get_memory = symbol(MemFn, lib, "nvmlDeviceGetMemoryInfo");
    const get_util = symbol(UtilFn, lib, "nvmlDeviceGetUtilizationRates");
    const get_power = symbol(UintFn, lib, "nvmlDeviceGetPowerUsage");
    const get_temp = symbol(TypedFn, lib, "nvmlDeviceGetTemperature");
    const get_encode = symbol(VideoFn, lib, "nvmlDeviceGetEncoderUtilization");
    const get_decode = symbol(VideoFn, lib, "nvmlDeviceGetDecoderUtilization");
    const get_clock = symbol(TypedFn, lib, "nvmlDeviceGetClockInfo");
    const get_max_clock = symbol(TypedFn, lib, "nvmlDeviceGetMaxClockInfo");
    const get_power_limit = symbol(UintFn, lib, "nvmlDeviceGetEnforcedPowerLimit");
    const get_fan = symbol(UintFn, lib, "nvmlDeviceGetFanSpeed");
    const get_pstate = symbol(UintFn, lib, "nvmlDeviceGetPerformanceState");
    const get_pcie_gen = symbol(UintFn, lib, "nvmlDeviceGetCurrPcieLinkGeneration");
    const get_pcie_width = symbol(UintFn, lib, "nvmlDeviceGetCurrPcieLinkWidth");
    const get_pcie_throughput = symbol(TypedFn, lib, "nvmlDeviceGetPcieThroughput");
    const get_event_reasons = symbol(MaskFn, lib, "nvmlDeviceGetCurrentClocksEventReasons");
    const get_legacy_reasons = symbol(MaskFn, lib, "nvmlDeviceGetCurrentClocksThrottleReasons");
    const get_compute = symbol(ComputeFn, lib, "nvmlDeviceGetCudaComputeCapability");
    const driver_version = symbol(SystemString, lib, "nvmlSystemGetDriverVersion");
    const cuda_v2 = symbol(CudaFn, lib, "nvmlSystemGetCudaDriverVersion_v2");
    const cuda_v1 = symbol(CudaFn, lib, "nvmlSystemGetCudaDriverVersion");
    var driver_buffer: [80]u8 = undefined;
    var driver_text: []const u8 = "";
    if (driver_version) |f| if (f(&driver_buffer, driver_buffer.len) == 0) {
        driver_buffer[driver_buffer.len - 1] = 0;
        driver_text = driver_buffer[0 .. std.mem.indexOfScalar(u8, &driver_buffer, 0) orelse driver_buffer.len];
    };
    var cuda_raw: i32 = -1;
    if (cuda_v2 orelse cuda_v1) |f| {
        var version: c_int = 0;
        if (f(&version) == 0) cuda_raw = version;
    }
    var meta: [192]u8 = undefined;
    if (m.formatGpuMeta(driver_text, cuda_raw, &meta)) |line| {
        if (!writeOutput(line) or !writeOutput("\n")) c._exit(1);
    }
    for (0..@min(count, 16)) |i| {
        var device: Device = null;
        if (handle(@intCast(i), &device) != 0) continue;
        var name: [128]u8 = @splat(0);
        _ = name_fn(device, &name, name.len);
        name[name.len - 1] = 0;
        var pci: Pci = std.mem.zeroes(Pci);
        if (pci_fn(device, &pci) != 0) continue;
        var gpu: m.Gpu = .{ .vendor = 0x10de };
        var key_buffer: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buffer, "{x:0>4}:{x:0>2}:{x:0>2}.0", .{ pci.domain, pci.bus, pci.device }) catch continue;
        gpu.key.set(key);
        const device_name = name[0 .. std.mem.indexOfScalar(u8, &name, 0) orelse name.len];
        gpu.name.set(if (device_name.len == 0) "NVIDIA GPU" else device_name);
        if (get_util) |f| {
            var util: Util = .{ .gpu = 0, .memory = 0 };
            if (f(device, &util) == 0) {
                gpu.usage = @floatFromInt(util.gpu);
                gpu.mem_usage = @floatFromInt(util.memory);
            }
        }
        var memory_read = false;
        if (get_memory_v2) |f| {
            var memory: MemoryV2 = std.mem.zeroes(MemoryV2);
            // nvmlMemory_v2_t requires a version word, not a bare 2 (nvtop #531).
            memory.version = (2 << 24) | @as(c_uint, @sizeOf(MemoryV2));
            if (f(device, &memory) == 0) {
                gpu.total = @floatFromInt(memory.total);
                gpu.used = @floatFromInt(memory.used);
                gpu.reserved = @floatFromInt(memory.reserved);
                memory_read = true;
            }
        }
        if (!memory_read) if (get_memory) |f| {
            var memory: Memory = std.mem.zeroes(Memory);
            if (f(device, &memory) == 0) {
                gpu.total = @floatFromInt(memory.total);
                gpu.used = @floatFromInt(memory.used);
            }
        };
        var value: c_uint = 0;
        if (get_power) |f| if (f(device, &value) == 0) {
            gpu.power = m.milliwattsToWatts(value);
        };
        if (get_temp) |f| if (f(device, 0, &value) == 0) {
            gpu.temp = @floatFromInt(value);
        };
        var period: c_uint = 0;
        if (get_encode) |f| if (f(device, &value, &period) == 0) {
            gpu.encode = @floatFromInt(value);
        };
        if (get_decode) |f| if (f(device, &value, &period) == 0) {
            gpu.decode = @floatFromInt(value);
        };
        if (get_clock) |f| {
            if (f(device, NVML_CLOCK_SM, &value) == 0) gpu.frequency = @floatFromInt(value);
            if (f(device, NVML_CLOCK_MEM, &value) == 0) gpu.mem_frequency = @floatFromInt(value);
            if (f(device, NVML_CLOCK_VIDEO, &value) == 0) gpu.video_frequency = @floatFromInt(value);
        }
        if (get_max_clock) |f| if (f(device, NVML_CLOCK_SM, &value) == 0) {
            gpu.max_frequency = @floatFromInt(value);
        };
        if (get_power_limit) |f| if (f(device, &value) == 0) {
            gpu.power_cap = m.milliwattsToWatts(value);
        };
        if (get_fan) |f| if (f(device, &value) == 0) {
            gpu.fan = @floatFromInt(value);
        };
        if (get_pstate) |f| if (f(device, &value) == 0 and value <= NVML_PSTATE_MAX) {
            gpu.pstate = value;
        };
        if (get_pcie_gen) |f| if (f(device, &value) == 0 and value != 0) {
            gpu.pcie_gen = value;
        };
        if (get_pcie_width) |f| if (f(device, &value) == 0 and value != 0) {
            gpu.pcie_width = value;
        };
        if (get_pcie_throughput) |f| {
            if (f(device, NVML_PCIE_UTIL_TX_BYTES, &value) == 0) gpu.pcie_tx = m.kilobytesToBytes(value);
            if (f(device, NVML_PCIE_UTIL_RX_BYTES, &value) == 0) gpu.pcie_rx = m.kilobytesToBytes(value);
        }
        if (get_event_reasons) |f| {
            var mask: c_ulonglong = 0;
            if (f(device, &mask) == 0) {
                gpu.throttle = mask;
            } else if (get_legacy_reasons) |legacy| {
                if (legacy(device, &mask) == 0) gpu.throttle = mask;
            }
        } else if (get_legacy_reasons) |f| {
            var mask: c_ulonglong = 0;
            if (f(device, &mask) == 0) gpu.throttle = mask;
        }
        if (get_compute) |f| {
            var major: c_int = -1;
            var minor: c_int = -1;
            if (f(device, &major, &minor) == 0 and major >= 0 and minor >= 0) {
                gpu.cuda_major = @intCast(major);
                gpu.cuda_minor = @intCast(minor);
            }
        }
        var row: [1024]u8 = undefined;
        if (m.formatGpuRow(&gpu, &row)) |line| {
            if (!writeOutput(line) or !writeOutput("\n")) c._exit(1);
        }
    }
    // The disposable child exits without nvmlShutdown; the OS reclaims NVML state.
    c._exit(0);
}
