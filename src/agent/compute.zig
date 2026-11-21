//! Conservative single-device selection. Device ordinals are never persisted.
const std = @import("std");
const cfg = @import("config.zig");
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    backend: cfg.Backend,
    total_mib: u64,
    free_mib: u64,
    // Enumeration does not reliably expose UMA across runtime versions.
    // Treat memory as potentially shared until established otherwise.
    shared: bool = true,
    ambiguous: bool = false,
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) ![]const Device {
    var result: std.ArrayList(Device) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const name = line[0..colon];
        const backend: cfg.Backend = if (std.mem.startsWith(u8, name, "Vulkan")) .vulkan else if (std.mem.startsWith(u8, name, "CUDA")) .cuda else continue;
        if (name.len > 32) continue;
        for (name) |ch| if (!std.ascii.isAlphanumeric(ch)) break else {} else {
            const opening = std.mem.lastIndexOf(u8, line, " (") orelse continue;
            const middle = std.mem.indexOfPos(u8, line, opening, " MiB, ") orelse continue;
            const end = std.mem.indexOfPos(u8, line, middle, " MiB free)") orelse continue;
            const total = std.fmt.parseInt(u64, line[opening + 2 .. middle], 10) catch continue;
            const free = std.fmt.parseInt(u64, line[middle + 6 .. end], 10) catch continue;
            if (opening <= colon + 2 or total == 0 or total > 1048576 or free > total) continue;
            const description = line[colon + 2 .. opening];
            if (description.len > 350 or !std.unicode.utf8ValidateSlice(description)) continue;
            const id = try std.fmt.allocPrint(a, "{s}:{s}:{d}", .{ @tagName(backend), description, total });
            var device: Device = .{ .id = id, .name = try a.dupe(u8, name), .description = try a.dupe(u8, description), .backend = backend, .total_mib = total, .free_mib = free, .shared = !(std.mem.indexOf(u8, description, "NVIDIA") != null or std.mem.indexOf(u8, description, "GeForce") != null or std.mem.indexOf(u8, description, "Radeon RX") != null) };
            for (result.items) |*other| if (std.mem.eql(u8, other.id, id)) {
                other.ambiguous = true;
                device.ambiguous = true;
            };
            if (result.items.len >= 32) return error.TooManyGpuDevices;
            try result.append(a, device);
        }
    }
    return result.items;
}
/// Conservative parser for `mistralrs doctor` device reports. Upstream does
/// not guarantee a stable format, so only lines that name a supported backend
/// and carry two MiB figures (total, then free) are accepted. Metal devices
/// are skipped because Pearl selects Vulkan or CUDA backends only. Anything
/// unparseable yields an empty list and the caller falls back to CPU.
pub fn parseDoctor(a: std.mem.Allocator, bytes: []const u8) ![]const Device {
    var result: std.ArrayList(Device) = .empty;
    var ordinals = [_]u16{ 0, 0, 0 };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const keyword: []const u8 = if (std.mem.indexOf(u8, line, "CUDA") != null) "CUDA" else if (std.mem.indexOf(u8, line, "Vulkan") != null) "Vulkan" else continue;
        const backend: cfg.Backend = if (keyword[0] == 'C') .cuda else .vulkan;
        if (std.mem.indexOf(u8, line, "free") == null) continue;
        const total = mibFigure(line, 0) orelse continue;
        const free = mibFigure(line, total.end) orelse continue;
        if (total.value == 0 or total.value > 1048576 or free.value > total.value) continue;
        const keyword_at = std.mem.indexOf(u8, line, keyword).?;
        var description = std.mem.trim(u8, line[keyword_at + keyword.len .. total.start], " \t:,-()");
        // Strip a leading device ordinal ("0: ") but keep model numbers.
        var skip: usize = 0;
        while (skip < description.len and std.ascii.isDigit(description[skip])) skip += 1;
        if (skip > 0 and skip < description.len and (description[skip] == ':' or description[skip] == ' ')) description = std.mem.trim(u8, description[skip..], " \t:,-");
        if (description.len == 0) description = "Unknown device";
        if (description.len > 350 or !std.unicode.utf8ValidateSlice(description)) continue;
        const ordinal = ordinals[@backingInt(backend)];
        ordinals[@backingInt(backend)] += 1;
        const name = try std.fmt.allocPrint(a, "{s}{d}", .{ keyword, ordinal });
        const id = try std.fmt.allocPrint(a, "{s}:{s}:{d}", .{ @tagName(backend), description, total.value });
        var device: Device = .{ .id = id, .name = name, .description = try a.dupe(u8, description), .backend = backend, .total_mib = total.value, .free_mib = free.value, .shared = !(std.mem.indexOf(u8, description, "NVIDIA") != null or std.mem.indexOf(u8, description, "GeForce") != null or std.mem.indexOf(u8, description, "Radeon RX") != null) };
        for (result.items) |*other| if (std.mem.eql(u8, other.id, id)) {
            other.ambiguous = true;
            device.ambiguous = true;
        };
        if (result.items.len >= 32) return error.TooManyGpuDevices;
        try result.append(a, device);
    }
    return result.items;
}
const Figure = struct { value: u64, start: usize, end: usize };
fn mibFigure(line: []const u8, from: usize) ?Figure {
    var i = from;
    while (i < line.len) {
        if (!std.ascii.isDigit(line[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (std.mem.startsWith(u8, line[i..], " MiB")) {
            const value = std.fmt.parseInt(u64, line[start..i], 10) catch return null;
            return .{ .value = value, .start = start, .end = i + 4 };
        }
    }
    return null;
}
pub fn available(device: Device, settings: cfg.Compute) u64 {
    const reserve = @max(512, device.total_mib / 5);
    return @min(device.free_mib -| reserve, settings.gpu_memory_target_mib orelse std.math.maxInt(u32));
}
pub fn select(devices: []const Device, settings: cfg.Compute, required_mib: u64) !?Device {
    if (settings.mode == .cpu) return null;
    var best: ?Device = null;
    for (devices) |device| {
        if (settings.backend != .auto and settings.backend != device.backend) continue;
        if (settings.device_id.len > 0 and !std.mem.eql(u8, settings.device_id, device.id)) continue;
        if (device.ambiguous) {
            if (settings.device_id.len > 0) return error.AmbiguousGpuDevice;
            continue;
        }
        if (available(device, settings) < required_mib) continue;
        if (best == null or rank(device) < rank(best.?) or (rank(device) == rank(best.?) and std.mem.order(u8, device.id, best.?.id) == .lt)) best = device;
    }
    if (best == null and settings.mode == .gpu) return error.GpuUnavailableOrMemoryInsufficient;
    return best;
}
fn rank(device: Device) u8 {
    return @as(u8, if (device.shared) 2 else 0) + @as(u8, if (device.backend == .cuda) 0 else 1);
}
pub fn offloaded(log: []const u8) u16 {
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, "offloaded ") orelse continue;
        const slash = std.mem.indexOfScalarPos(u8, line, start + 10, '/') orelse continue;
        if (std.mem.indexOf(u8, line[slash..], "layers to GPU") == null) continue;
        return std.fmt.parseInt(u16, line[start + 10 .. slash], 10) catch 0;
    }
    return 0;
}
test "GPU selection tolerates ordinal changes and rejects ambiguous identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try parse(a, "Available devices:\n  Vulkan0: Example GPU (8192 MiB, 7000 MiB free)\n");
    const next = try parse(a, "  Vulkan2: Example GPU (8192 MiB, 6000 MiB free)\n");
    const selected = (try select(next, .{ .mode = .gpu, .device_id = first[0].id }, 600)).?;
    try std.testing.expectEqualStrings("Vulkan2", selected.name);
    try std.testing.expectEqual(@as(u64, 4362), available(selected, .{}));
    const duplicate = try parse(a, "Vulkan0: Same (8192 MiB, 7000 MiB free)\nVulkan1: Same (8192 MiB, 7000 MiB free)\n");
    try std.testing.expectError(error.AmbiguousGpuDevice, select(duplicate, .{ .mode = .gpu, .device_id = duplicate[0].id }, 600));
    try std.testing.expectEqual(@as(?Device, null), try select(first, .{ .mode = .auto, .gpu_memory_target_mib = 128 }, 600));
    try std.testing.expectEqual(@as(u16, 17), offloaded("load_tensors: offloaded 17/17 layers to GPU\n"));
    try std.testing.expectEqual(@as(u16, 0), offloaded("GPU found\n"));
}
test "doctor device reports parse conservatively and unreadable reports fall back to CPU" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const devices = try parseDoctor(a, "mistralrs doctor\nDevices:\n  CUDA0: NVIDIA GeForce RTX 4090 (24576 MiB, 24000 MiB free)\n  Vulkan0: Example GPU (8192 MiB, 7000 MiB free)\n");
    try std.testing.expectEqual(@as(usize, 2), devices.len);
    try std.testing.expectEqualStrings("CUDA0", devices[0].name);
    try std.testing.expectEqualStrings("NVIDIA GeForce RTX 4090", devices[0].description);
    try std.testing.expect(!devices[0].shared);
    try std.testing.expectEqualStrings("vulkan:Example GPU:8192", devices[1].id);
    const selected = (try select(devices, .{ .mode = .gpu, .backend = .vulkan }, 600)).?;
    try std.testing.expectEqualStrings("Vulkan0", selected.name);
    try std.testing.expectEqual(@as(usize, 0), (try parseDoctor(a, "system information without devices")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseDoctor(a, "CUDA0: broken (0 MiB, 0 MiB free)")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseDoctor(a, "CUDA0: inverted (100 MiB, 200 MiB free)")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseDoctor(a, "Metal0: Apple M2 (16384 MiB, 16000 MiB free)")).len);
    const duplicate = try parseDoctor(a, "CUDA0: Same (8192 MiB, 7000 MiB free)\nCUDA1: Same (8192 MiB, 7000 MiB free)\n");
    try std.testing.expectError(error.AmbiguousGpuDevice, select(duplicate, .{ .mode = .gpu, .device_id = duplicate[0].id }, 600));
}
