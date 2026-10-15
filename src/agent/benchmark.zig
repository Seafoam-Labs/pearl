//! Sequential local-evidence comparisons using the production controller.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const cfg = @import("config.zig");
const registry = @import("model_registry.zig");
const controller = @import("controller.zig");
const probe = @import("runtime_probe.zig");
const io = @import("../config/io.zig");
const telemetry = @import("telemetry.zig");
const memory = @import("memory.zig");
pub const fixture_revision: u32 = 1;
pub const Mode = enum { cpu, current, cpu_gpu };
pub const Outcome = enum { answer, results_only, truncated, timeout, cancelled, skipped, incompatible, tool_error, runtime_error, incorrect };
pub const Settings = struct {
    model_id: []const u8,
    runtime: cfg.RuntimeConfig,
    compute: cfg.Compute,
    threads: u32,
    context: u32,
    generation: u32,
    pub fn config(self: Settings) cfg.Config {
        return .{ .enabled = true, .model_id = self.model_id, .runtime = self.runtime, .compute = self.compute, .cpu_threads = self.threads, .context_tokens = self.context, .answer_tokens = self.generation, .read_pages = true };
    }
    pub fn adopt(self: Settings, current: *cfg.Config) void {
        current.model_id = self.model_id;
        current.runtime = self.runtime;
        current.compute = self.compute;
        current.cpu_threads = self.threads;
        current.context_tokens = self.context;
        current.answer_tokens = self.generation;
    }
};
pub const Hardware = struct {
    cpu: []const u8,
    architecture: []const u8,
    os: []const u8,
    features: []const u8,
    affinity: []const u8,
    logical: u32,
    physical: u32,
    power: []const u8,
    load: []const u8,
    available_mib: ?u64,
    gpu_driver: []const u8,
    fingerprint: []const u8,
};
pub fn first(a: std.mem.Allocator, filename: [:0]const u8) ![]const u8 {
    const fd = std.c.open(filename, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, @as(c_uint, 0));
    if (fd < 0) return a.dupe(u8, "unavailable");
    defer _ = std.c.close(fd);
    var buffer: [16384]u8 = undefined;
    const n = std.c.read(fd, &buffer, buffer.len);
    if (n <= 0) return a.dupe(u8, "unavailable");
    return a.dupe(u8, std.mem.trim(u8, buffer[0..@intCast(n)], " \t\r\n"));
}
fn field(bytes: []const u8, name: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return "unavailable";
}
pub fn hardware(a: std.mem.Allocator) !Hardware {
    const info = try first(a, "/proc/cpuinfo");
    const status = try first(a, "/proc/self/status");
    const affinity = field(status, "Cpus_allowed_list");
    var mask: std.os.linux.cpu_set_t = @splat(0);
    const have_mask = std.os.linux.sched_getaffinity(0, @sizeOf(@TypeOf(mask)), &mask) == 0;
    var logical: u32 = 0;
    var cores: std.StringHashMap(void) = .init(a);
    defer cores.deinit();
    if (have_mask) for (0..@bitSizeOf(@TypeOf(mask))) |cpu| {
        if (mask[cpu / @bitSizeOf(usize)] & (@as(usize, 1) << @intCast(cpu % @bitSizeOf(usize))) == 0) continue;
        logical += 1;
        const package = try first(a, try std.fmt.allocPrintSentinel(a, "/sys/devices/system/cpu/cpu{d}/topology/physical_package_id", .{cpu}, 0));
        const core = try first(a, try std.fmt.allocPrintSentinel(a, "/sys/devices/system/cpu/cpu{d}/topology/core_id", .{cpu}, 0));
        if (!std.mem.eql(u8, core, "unavailable")) try cores.put(try std.fmt.allocPrint(a, "{s}:{s}", .{ package, core }), {});
    };
    if (logical == 0) logical = @intCast(std.Thread.getCpuCount() catch 1);
    var driver: std.ArrayList(u8) = .empty;
    try driver.appendSlice(a, try first(a, "/proc/driver/nvidia/version"));
    for (0..16) |card| for ([_][]const u8{ "uevent", "driver/module/version" }) |part| {
        try driver.appendSlice(a, try first(a, try std.fmt.allocPrintSentinel(a, "/sys/class/drm/card{d}/device/{s}", .{ card, part }, 0)));
    };
    var result: Hardware = .{
        .cpu = field(info, "model name"),
        .architecture = @tagName(@import("builtin").cpu.arch),
        .os = try first(a, "/proc/sys/kernel/osrelease"),
        .features = field(info, "flags"),
        .affinity = affinity,
        .logical = logical,
        .physical = if (cores.count() == 0) logical else cores.count(),
        .power = try std.fmt.allocPrint(a, "{s}; governor {s}", .{ try first(a, "/sys/firmware/acpi/platform_profile"), try first(a, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") }),
        .load = try first(a, "/proc/loadavg"),
        .available_mib = memory.availableMiB(),
        .gpu_driver = driver.items,
        .fingerprint = "",
    };
    if (std.mem.eql(u8, result.cpu, "unavailable")) result.cpu = field(info, "Hardware");
    if (std.mem.eql(u8, result.features, "unavailable")) result.features = field(info, "Features");
    const stable = try std.json.Stringify.valueAlloc(a, .{ result.cpu, result.architecture, result.os, result.features, result.affinity, result.power, result.gpu_driver }, .{});
    result.fingerprint = try a.dupe(u8, &io.digest(stable));
    return result;
}
pub const Options = struct { selected: [registry.models.len]bool = .{ false, false, true, true, true }, mode: Mode = .cpu, detailed: bool = false };
pub fn candidates(a: std.mem.Allocator, base: cfg.Config, options: Options, host: Hardware, devices: []const @import("compute.zig").Device) ![]Settings {
    var result: std.ArrayList(Settings) = .empty;
    for (registry.models, options.selected) |model, selected| {
        if (!selected) continue;
        var seed: Settings = .{ .model_id = model.id, .runtime = base.runtime, .compute = if (options.mode == .current) base.compute else .{}, .threads = if (options.mode == .current) base.cpu_threads else 0, .context = if (options.mode == .current and base.context_tokens != 0) base.context_tokens else model.context_tokens, .generation = if (options.mode == .current and base.answer_tokens != 0) base.answer_tokens else model.answer_tokens };
        try appendUnique(a, &result, seed);
        if (options.detailed and seed.compute.mode == .cpu) {
            for ([_]u32{ 0, @max(1, host.physical / 2), host.physical, host.logical, base.cpu_threads }) |threads| {
                var item = seed;
                item.threads = threads;
                try appendUnique(a, &result, item);
            }
        }
        if (options.detailed) try appendContexts(a, &result, seed, base.contextTokens());
        if (options.mode == .cpu_gpu) {
            // No suitable devices is a recorded GPU failure, never a fabricated
            // CPU-versus-GPU result. Auto selection remains a separate candidate.
            seed.compute = .{ .mode = .auto, .backend = base.compute.backend };
            try appendUnique(a, &result, seed);
            if (options.detailed) try appendContexts(a, &result, seed, base.contextTokens());
            for (devices) |device| {
                if (device.ambiguous or (base.compute.backend != .auto and device.backend != base.compute.backend)) continue;
                seed.compute = .{ .mode = .gpu, .backend = device.backend, .device_id = device.id, .allow_cpu_fallback = base.compute.allow_cpu_fallback };
                try appendUnique(a, &result, seed);
                if (options.detailed) {
                    try appendContexts(a, &result, seed, base.contextTokens());
                    seed.compute.offload_layers = base.compute.offload_layers;
                    seed.compute.gpu_memory_target_mib = base.compute.gpu_memory_target_mib;
                    try appendUnique(a, &result, seed);
                    try appendContexts(a, &result, seed, base.contextTokens());
                }
            }
        }
    }
    if (result.items.len == 0) return error.SelectBenchmarkModels;
    // Vary detailed run order without changing or dropping any candidate.
    if (options.detailed) std.mem.rotate(Settings, result.items, @intCast(@mod(glib.getRealTime(), @as(i64, @intCast(result.items.len)))));
    return result.items;
}
fn appendContexts(a: std.mem.Allocator, result: *std.ArrayList(Settings), seed: Settings, entered: u32) !void {
    for ([_]u32{ 4096, 8192, entered }) |context| {
        if (context <= @as(u64, seed.generation) + 700) continue;
        var item = seed;
        item.context = context;
        try appendUnique(a, result, item);
    }
}
fn appendUnique(a: std.mem.Allocator, result: *std.ArrayList(Settings), item: Settings) !void {
    const key = try std.json.Stringify.valueAlloc(a, item, .{});
    for (result.items) |old| if (std.mem.eql(u8, key, try std.json.Stringify.valueAlloc(a, old, .{}))) return;
    try result.append(a, item);
}
pub const Fixture = struct { id: []const u8, question: []const u8, followup: []const u8, evidence: []const u8, expected: ?[]const u8 = null, followup_expected: ?[]const u8 = null };
pub const fixtures = [_]Fixture{
    .{ .id = "memory", .question = "What is the difference between RAM and storage?", .followup = "Will adding RAM give me more space for saved files? Use the existing evidence.", .evidence = "RAM holds active working data temporarily and loses its contents when power is removed. Storage retains saved files between sessions. Adding RAM does not increase storage space." },
    .{ .id = "timetable", .question = "In the supplied depot timetable, how many minutes is the trip from Alder to Birch?", .followup = "The return trip takes 13 minutes longer. How many minutes is the return trip?", .evidence = "The fictional depot timetable lists the Alder departure at 09:00 and the Birch arrival at 09:47. This outward trip takes 47 minutes. The return trip takes 13 minutes longer, or 60 minutes.", .expected = "47", .followup_expected = "60" },
};
const Local = struct {
    fixture: Fixture,
    searches: u32 = 0,
    reads: u32 = 0,
    fn search(context: *anyopaque, a: std.mem.Allocator, _: []const u8, cancel: *gio.Cancellable) ![]const controller.Source {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        const self: *Local = @ptrCast(@alignCast(context));
        self.searches += 1;
        const source = try a.alloc(controller.Source, 1);
        source[0] = .{ .id = 1, .title = self.fixture.id, .url = "https://benchmark.invalid/local-evidence", .snippet = self.fixture.evidence, .provider = "local-benchmark" };
        return source;
    }
    fn read(context: *anyopaque, _: std.mem.Allocator, _: controller.Source, cancel: *gio.Cancellable) ![]const u8 {
        if (cancel.isCancelled() != 0) return error.Cancelled;
        const self: *Local = @ptrCast(@alignCast(context));
        self.reads += 1;
        return self.fixture.evidence;
    }
    fn tools(self: *Local) controller.Tools {
        return .{ .context = self, .search = search, .read = read };
    }
};
pub const Sample = struct {
    fixture: []const u8,
    followup: bool,
    warmup: bool,
    outcome: Outcome,
    first_visible_ms: ?f64 = null,
    complete_ms: f64 = 0,
    answer: []const u8 = "",
    error_code: []const u8 = "",
    searches: u32 = 0,
    reads: u32 = 0,
    gpu: bool = false,
    fallback: []const u8 = "",
    tokens: telemetry.Tokens = .{},
};
pub const Result = struct {
    settings: Settings,
    model_hash: []const u8 = "",
    model_identity: []const u8 = "",
    runtime_identity: []const u8 = "",
    runtime_version: []const u8 = "",
    device: ?@import("compute.zig").Device = null,
    offload_layers: u16 = 0,
    gpu_memory_mib: ?u64 = null,
    group: []const u8 = "",
    error_code: []const u8 = "",
    complete: bool = false,
    verification_ms: f64 = 0,
    load_ms: f64 = 0,
    peak_rss_kib: ?u64 = null,
    high_water_kib: ?u64 = null,
    memory_samples: u32 = 0,
    samples: []const Sample = &.{},
    pub fn successful(self: Result) bool {
        if (!self.complete or self.error_code.len > 0 or self.samples.len != fixtures.len * 8) return false;
        for (self.samples) |sample| if (sample.outcome != .answer or sample.fallback.len > 0 or (self.settings.compute.mode != .cpu and !sample.gpu)) return false;
        return true;
    }
    pub fn actualCompute(self: Result) []const u8 {
        var gpu: usize = 0;
        var cpu: usize = 0;
        var fallback = false;
        for (self.samples) |sample| {
            if (sample.gpu) gpu += 1 else cpu += 1;
            fallback = fallback or sample.fallback.len > 0;
        }
        if (gpu > 0 and cpu > 0) return "Mixed GPU / CPU recovery";
        if (fallback) return "CPU fallback";
        if (gpu > 0) return if (self.device) |device| @tagName(device.backend) else "GPU";
        return if (cpu > 0) "CPU" else "No completed inference";
    }
};
pub const Run = struct {
    schema: u32 = 1,
    workload: u32 = fixture_revision,
    id: []const u8,
    started_us: i64,
    finished_us: ?i64 = null,
    state: enum { running, complete, cancelled, interrupted } = .running,
    hardware: Hardware,
    options: Options,
    results: []const Result = &.{},
};
pub const Progress = struct {
    candidate: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    sample: std.atomic.Value(u32) = .init(0),
    phase: std.atomic.Value(controller.Phase) = .init(.preparing),
    completed: std.atomic.Value(u32) = .init(0),
    download_bytes: std.atomic.Value(u64) = .init(0),
    model_index: std.atomic.Value(usize) = .init(0),
    skip: std.atomic.Value(bool) = .init(false),
};
pub fn execute(a: std.mem.Allocator, base: cfg.Config, options: Options, cancel: *gio.Cancellable, progress: *Progress) !Run {
    for (options.selected) |selected| {
        if (selected) break;
    } else return error.SelectBenchmarkModels;
    const host = try hardware(a);
    var run: Run = .{ .id = try std.fmt.allocPrint(a, "{d}-{d}", .{ glib.getRealTime(), std.c.getpid() }), .started_us = glib.getRealTime(), .hardware = host, .options = options };
    try save(a, run);
    const info: ?probe.Probe = probe.inspect(a, base.runtime, options.mode != .cpu, cancel) catch |err| blk: {
        if (cancel.isCancelled() != 0 or err == error.Cancelled) {
            run.state = .cancelled;
            run.finished_us = glib.getRealTime();
            try save(a, run);
            return run;
        }
        break :blk null; // Record per-candidate compatibility failures below.
    };
    const choices = try candidates(a, base, options, host, if (info) |p| p.devices else &.{});
    var results: std.ArrayList(Result) = .empty;
    progress.total.store(choices.len, .monotonic);
    try save(a, run);
    for (choices, 0..) |settings, index| {
        if (cancel.isCancelled() != 0) break;
        progress.candidate.store(index, .monotonic);
        progress.model_index.store(registry.selection(settings.model_id), .monotonic);
        progress.skip.store(false, .monotonic);
        progress.sample.store(0, .monotonic);
        var result: Result = .{ .settings = settings, .runtime_identity = if (info) |p| p.fingerprint else "", .runtime_version = if (info) |p| p.version else "", .group = try std.fmt.allocPrint(a, "fixture-{d}/context-{d}", .{ fixture_revision, settings.context }) };
        measure(a, &result, cancel, progress) catch |err| {
            result.error_code = @errorName(err);
        };
        result.complete = cancel.isCancelled() == 0;
        try results.append(a, result);
        run.results = results.items;
        try save(a, run);
        progress.completed.store(@intCast(results.items.len), .monotonic);
    }
    run.state = if (cancel.isCancelled() != 0) .cancelled else .complete;
    run.finished_us = glib.getRealTime();
    try save(a, run);
    return run;
}
fn measure(a: std.mem.Allocator, result: *Result, cancel: *gio.Cancellable, progress: *Progress) !void {
    const config = result.settings.config();
    try config.validate();
    const model = registry.find(config.model_id) orelse return error.UnknownAssistantModel;
    result.model_hash = model.sha256;
    result.model_identity = probe.fingerprint(a, try @import("downloads.zig").path(a, model)) catch return error.ModelNotInstalled;
    var metrics: telemetry.Metrics = .{ .skip = &progress.skip };
    var runtime: @import("runtime.zig").Runtime = .{ .telemetry = &metrics };
    defer runtime.stop();
    defer {
        result.verification_ms = milliseconds(metrics.verification_us);
        result.load_ms = milliseconds(metrics.load_us);
        result.peak_rss_kib = metrics.peak_rss_kib;
        result.high_water_kib = metrics.high_water_kib;
        result.memory_samples = metrics.samples;
    }
    progress.phase.store(.checking, .monotonic);
    try runtime.ensure(config, cancel);
    result.runtime_version = try a.dupe(u8, runtime.version);
    if (runtime.device) |device| result.device = try clone(@import("compute.zig").Device, a, device);
    result.offload_layers = runtime.offload_layers;
    var samples: std.ArrayList(Sample) = .empty;
    defer result.samples = samples.items;
    for (0..4) |round| for (fixtures) |fixture| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        var local: Local = .{ .fixture = fixture };
        var previous: []const controller.Source = &.{};
        var turns: []const controller.Turn = &.{};
        var turn: [1]controller.Turn = undefined;
        for ([_][]const u8{ fixture.question, fixture.followup }, 0..) |question, turn_index| {
            if (cancel.isCancelled() != 0) return error.Cancelled;
            metrics.tokens = .{};
            var live: @import("sse.zig").Live = .{};
            const started = glib.getMonotonicTime();
            var sample: Sample = .{ .fixture = fixture.id, .followup = turn_index == 1, .warmup = round == 0, .outcome = .runtime_error };
            const before_searches = local.searches;
            const before_reads = local.reads;
            const answer = controller.runWithTools(temporary, &runtime, config, question, turns, previous, cancel, &progress.phase, &live, local.tools()) catch |err| {
                sample.outcome = classify(err);
                sample.error_code = @errorName(err);
                sample.complete_ms = milliseconds(glib.getMonotonicTime() - started);
                sample.tokens = metrics.tokens;
                try samples.append(a, sample);
                return err;
            };
            sample.complete_ms = milliseconds(glib.getMonotonicTime() - started);
            const first_us = live.first_visible_us.load(.monotonic);
            if (first_us > 0) sample.first_visible_ms = milliseconds(first_us - started);
            sample.answer = try a.dupe(u8, answer.text);
            sample.outcome = if (answer.summarized) .answer else .results_only;
            const expected = if (turn_index == 0) fixture.expected else fixture.followup_expected;
            if (answer.summarized and expected != null and std.mem.indexOf(u8, answer.text, expected.?) == null) sample.outcome = .incorrect;
            sample.searches = local.searches - before_searches;
            sample.reads = local.reads - before_reads;
            sample.tokens = metrics.tokens;
            sample.gpu = runtime.gpu;
            sample.fallback = try a.dupe(u8, runtime.fallback_reason);
            try samples.append(a, sample);
            progress.sample.store(@intCast(samples.items.len), .monotonic);
            if (!answer.summarized) break;
            turn[0] = .{ .question = fixture.question, .answer = answer.text };
            turns = &turn;
            previous = answer.sources;
        }
    };
}
pub fn classify(err: anyerror) Outcome {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.BenchmarkSkipped => .skipped,
        error.GenerationTruncated => .truncated,
        error.TurnTimedOut, error.RuntimeCheckTimedOut, error.RequestTimedOut => .timeout,
        error.ModelToolsIncompatible, error.RuntimeReasoningUnsupported, error.RuntimeCapabilityMissing, error.RuntimeAuthenticationMissing => .incompatible,
        error.ToolBudgetExceeded, error.InvalidToolCall, error.UnknownSource => .tool_error,
        else => .runtime_error,
    };
}
fn milliseconds(us: i64) f64 {
    return @as(f64, @floatFromInt(@max(0, us))) / 1000;
}
fn clone(comptime T: type, a: std.mem.Allocator, value: T) !T {
    return std.json.parseFromSliceLeaky(T, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{});
}
pub const Summary = struct { median_ms: f64 = 0, min_ms: f64 = 0, max_ms: f64 = 0, first_ms: ?f64 = null, passed: usize = 0, measured: usize = 0 };
pub fn summarize(result: Result) Summary {
    var values: [fixtures.len * 6]f64 = undefined;
    var firsts: [fixtures.len * 6]f64 = undefined;
    var first_count: usize = 0;
    var summary: Summary = .{};
    for (result.samples) |sample| {
        if (sample.warmup or summary.measured == values.len) continue;
        values[summary.measured] = sample.complete_ms;
        summary.measured += 1;
        if (sample.outcome == .answer) summary.passed += 1;
        if (sample.first_visible_ms) |ms| {
            firsts[first_count] = ms;
            first_count += 1;
        }
    }
    if (summary.measured > 0) {
        std.mem.sort(f64, values[0..summary.measured], {}, less);
        summary.min_ms = values[0];
        summary.max_ms = values[summary.measured - 1];
        summary.median_ms = median(values[0..summary.measured]);
    }
    if (first_count > 0) {
        std.mem.sort(f64, firsts[0..first_count], {}, less);
        summary.first_ms = median(firsts[0..first_count]);
    }
    return summary;
}
fn less(_: void, x: f64, y: f64) bool {
    return x < y;
}
fn median(sorted: []const f64) f64 {
    return (sorted[(sorted.len - 1) / 2] + sorted[sorted.len / 2]) / 2;
}
pub const Recommendations = struct { fastest: ?usize = null, memory: ?usize = null, balanced: ?usize = null };
pub fn recommend(results: []const Result, group: []const u8, stale: []const bool) Recommendations {
    var out: Recommendations = .{};
    for (results, 0..) |result, i| {
        if (i >= stale.len or stale[i] or !result.successful() or !std.mem.eql(u8, result.group, group)) continue;
        if (out.fastest == null or summarize(result).median_ms < summarize(results[out.fastest.?]).median_ms) out.fastest = i;
        if (result.peak_rss_kib) |rss| if (out.memory == null or rss < results[out.memory.?].peak_rss_kib.?) {
            out.memory = i;
        };
    }
    if (out.fastest) |fast| {
        const timing = summarize(results[fast]);
        // Within 20% AND the fastest candidate's observed range: explicitly
        // account for spread instead of a hidden composite quality score.
        const tolerance = @max(timing.median_ms * 1.2, timing.max_ms);
        for (results, 0..) |result, i| {
            if (i >= stale.len or stale[i] or !result.successful() or !std.mem.eql(u8, result.group, group) or summarize(result).median_ms > tolerance) continue;
            if (result.peak_rss_kib) |rss| if (out.balanced == null or rss < results[out.balanced.?].peak_rss_kib.?) {
                out.balanced = i;
            };
        }
    }
    return out;
}
pub fn staleReason(a: std.mem.Allocator, run: Run, result: Result, host: Hardware) ?[]const u8 {
    if (run.schema != 1 or run.workload != fixture_revision) return "Benchmark workload changed";
    if (!std.mem.eql(u8, run.hardware.fingerprint, host.fingerprint)) return "Hardware, driver, affinity, power mode or OS changed";
    const model = registry.find(result.settings.model_id) orelse return "Model no longer suggested";
    if (!std.mem.eql(u8, model.sha256, result.model_hash)) return "Model revision changed";
    const filename = @import("downloads.zig").path(a, model) catch return "Model unavailable";
    const identity = probe.fingerprint(a, filename) catch return "Model unavailable";
    if (!std.mem.eql(u8, identity, result.model_identity)) return "Model file changed";
    const exe = probe.resolve(a, result.settings.runtime) catch return "Runtime unavailable";
    const runtime_id = probe.fingerprint(a, exe) catch return "Runtime unavailable";
    if (!std.mem.eql(u8, runtime_id, result.runtime_identity)) return "Runtime changed";
    return null;
}
pub fn directory(a: std.mem.Allocator) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/pearl/assistant/benchmarks", .{glib.getUserStateDir()}, 0);
}
pub fn path(a: std.mem.Allocator, id: []const u8) ![:0]const u8 {
    if (id.len == 0 or id.len > 64) return error.InvalidBenchmarkId;
    for (id) |ch| if (!std.ascii.isDigit(ch) and ch != '-') return error.InvalidBenchmarkId;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}.json", .{ try directory(a), id }, 0);
}
pub fn save(a: std.mem.Allocator, run: Run) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temporary = arena.allocator();
    try io.mkdir(try directory(temporary));
    try writeFile(temporary, try path(temporary, run.id), run);
}
pub fn load(a: std.mem.Allocator, id: []const u8) !Run {
    return loadFile(a, try path(a, id));
}
fn writeFile(a: std.mem.Allocator, filename: [:0]const u8, run: Run) !void {
    try io.atomic(filename, try std.json.Stringify.valueAlloc(a, run, .{ .whitespace = .indent_2 }), false);
}
fn loadFile(a: std.mem.Allocator, filename: [:0]const u8) !Run {
    const data = try io.read(a, filename, 32 * 1024 * 1024, null);
    if (data.missing) return error.BenchmarkNotFound;
    var run = try std.json.parseFromSliceLeaky(Run, a, data.bytes, .{});
    if (run.schema != 1) return error.BenchmarkSchemaUnsupported;
    if (run.state == .running) run.state = .interrupted;
    return run;
}
pub fn history(a: std.mem.Allocator) ![]const []const u8 {
    const dir = glib.Dir.open(try directory(a), 0, null) orelse return &.{};
    defer dir.close();
    const read: *const fn (*glib.Dir) callconv(.c) ?[*:0]const u8 = @ptrCast(&glib.Dir.readName);
    var ids: std.ArrayList([]const u8) = .empty;
    while (read(dir)) |name_| {
        const name = std.mem.span(name_);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const id = name[0 .. name.len - 5];
        _ = path(a, id) catch continue;
        try ids.append(a, try a.dupe(u8, id));
    }
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn newer(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .gt;
        }
    }.newer);
    return ids.items;
}
pub fn remove(a: std.mem.Allocator, id: []const u8) !void {
    if (std.c.unlink(try path(a, id)) != 0) return error.BenchmarkDeleteFailed;
}

test "benchmark adoption preserves providers and enable choice" {
    var config: cfg.Config = .{};
    const settings: Settings = .{ .model_id = registry.models[2].id, .runtime = .{}, .compute = .{}, .threads = 8, .context = 16384, .generation = 2048 };
    settings.adopt(&config);
    try std.testing.expect(!config.enabled);
    try std.testing.expectEqualStrings("bing", config.default_provider_id);
    try std.testing.expectEqual(@as(u32, 8), config.cpu_threads);
    try config.validate();
}
test "unfinished, truncated and fallback runs cannot be recommended" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const host = try hardware(a);
    const choices = try candidates(a, .{ .cpu_threads = 7 }, .{ .selected = .{ false, false, false, false, true }, .detailed = true }, host, &.{});
    try std.testing.expect(choices.len > 1);
    var samples: [fixtures.len * 8]Sample = undefined;
    for (&samples, 0..) |*sample, i| sample.* = .{ .fixture = "memory", .followup = false, .warmup = i < 4, .outcome = .answer, .complete_ms = 10 };
    var result: Result = .{ .settings = choices[0], .complete = true, .samples = &samples, .group = "same", .peak_rss_kib = 100 };
    try std.testing.expectEqual(@as(?usize, 0), recommend(&.{result}, "same", &.{false}).fastest);
    samples[4].outcome = .truncated;
    try std.testing.expectEqual(@as(?usize, null), recommend(&.{result}, "same", &.{false}).fastest);
    samples[4].outcome = .answer;
    samples[4].fallback = "GPU failed";
    try std.testing.expect(!result.successful());
    samples[4].fallback = "";
    result.complete = false;
    try std.testing.expect(!result.successful());
    try std.testing.expectError(error.InvalidBenchmarkId, path(a, "../escape"));
}

test "atomic checkpoints retain interruption and hardware/workload freshness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = glib.Dir.makeTmp("pearl-benchmark-XXXXXX", null) orelse return error.TempDirectoryFailed;
    defer glib.free(dir);
    defer _ = std.c.rmdir(dir);
    const filename = try std.fmt.allocPrintSentinel(a, "{s}/result.json", .{dir}, 0);
    defer _ = std.c.unlink(filename);
    const host = try hardware(a);
    var run: Run = .{ .id = "1-2", .started_us = 1, .hardware = host, .options = .{} };
    try writeFile(a, filename, run);
    const interrupted = try loadFile(a, filename);
    try std.testing.expectEqual(.interrupted, interrupted.state);
    run.state = .complete;
    try writeFile(a, filename, run);
    try std.testing.expectEqual(.complete, (try loadFile(a, filename)).state);
    const choices = try candidates(a, .{}, .{}, host, &.{});
    const result: Result = .{ .settings = choices[0] };
    var changed = host;
    changed.fingerprint = "different hardware";
    try std.testing.expect(staleReason(a, run, result, changed) != null);
    run.workload += 1;
    try std.testing.expectEqualStrings("Benchmark workload changed", staleReason(a, run, result, host).?);
}
