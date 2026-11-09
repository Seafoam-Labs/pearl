const std = @import("std");
const m = @import("../core/model.zig");
const io = @import("../platform/io.zig");
const c = io.c;
const max_processes = 32768;

pub fn collect(previous: ?*const m.Snapshot, sequence: u64) *m.Snapshot {
    const s = m.Snapshot.create();
    const a = s.arena.allocator();
    s.time = io.monotonic();
    s.sequence = sequence;
    const seconds = if (previous) |p| @as(f64, @floatFromInt(s.time - p.time)) / 1e6 else 0;
    var buffer: [131072]u8 = undefined;
    var cpus: std.ArrayList(m.Cpu) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    if (io.read("/proc/stat", &buffer)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu")) continue;
            if (cpus.items.len >= 4097) {
                s.truncated = true;
                break;
            }
            const cpu = m.parseCpu(line) orelse continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const key = words.next().?;
            const id: u32 = if (key.len == 3) std.math.maxInt(u32) else std.fmt.parseInt(u32, key[3..], 10) catch continue;
            cpus.append(a, cpu) catch unreachable;
            ids.append(a, id) catch unreachable;
        }
    }
    s.cpus = cpus.items;
    s.cpu_ids = ids.items;
    var topology_same = false;
    if (previous) |p| {
        topology_same = std.mem.eql(u32, s.cpu_ids, p.cpu_ids);
        if (topology_same) for (s.cpus, p.cpus) |*now, old| m.cpuRate(now, old);
    }
    if (io.read("/proc/meminfo", &buffer)) |text| s.memory = m.parseMemory(text);
    if (io.read("/proc/uptime", &buffer)) |text| {
        var words = std.mem.tokenizeAny(u8, text, " \n");
        s.uptime = m.number(words.next() orelse "") orelse 0;
    }
    if (io.read("/proc/cpuinfo", &buffer)) |text| {
        s.cpu_name.set(m.field(text, "model name") orelse m.field(text, "Hardware") orelse "CPU");
        // procfs keys are padded before the colon on common kernels.
        if (s.cpu_name.len == 3) {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "model name")) {
                    if (std.mem.indexOfScalar(u8, line, ':')) |n| {
                        s.cpu_name.set(std.mem.trim(u8, line[n + 1 ..], " \t"));
                        break;
                    }
                }
            }
        }
    }
    if (io.number("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")) |n| s.frequency = n / 1e6;
    if (topology_same) {
        s.core_count = previous.?.core_count;
        s.cache = previous.?.cache;
        s.base_frequency = previous.?.base_frequency;
    } else {
        var unique: std.AutoHashMap(u64, void) = .init(a);
        for (s.cpu_ids) |id| {
            if (id == std.math.maxInt(u32)) continue;
            const core_path = io.path("/sys/devices/system/cpu/cpu{d}/topology/core_id", .{id});
            const package_path = io.path("/sys/devices/system/cpu/cpu{d}/topology/physical_package_id", .{id});
            const core = io.integer(core_path.slice()) orelse continue;
            const package = io.integer(package_path.slice()) orelse continue;
            unique.put((package << 32) | core, {}) catch unreachable;
        }
        s.core_count = unique.count();
        if (io.number("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency")) |v| s.base_frequency = v / 1e6;
        var names: std.ArrayList(u8) = .empty;
        if (io.Dir.open("/sys/devices/system/cpu/cpu0/cache")) |dir| {
            defer dir.close();
            while (dir.next()) |index| {
                if (!std.mem.startsWith(u8, index, "index")) continue;
                const level_path = io.path("/sys/devices/system/cpu/cpu0/cache/{s}/level", .{index});
                const size_path = io.path("/sys/devices/system/cpu/cpu0/cache/{s}/size", .{index});
                const size = io.text(size_path.slice());
                const entry = io.path("{s}L{d}: {s}", .{ if (names.items.len > 0) " · " else "", io.integer(level_path.slice()) orelse 0, size.slice() });
                names.appendSlice(a, entry.slice()) catch unreachable;
            }
            s.cache.set(names.items);
        }
    }
    var old_processes: std.AutoHashMap(i32, *const m.Process) = .init(a);
    if (previous) |p| for (p.processes) |*process| old_processes.put(process.id.pid, process) catch unreachable;
    var processes: std.ArrayList(m.Process) = .empty;
    const ticks: f64 = @floatFromInt(c.sysconf(c._SC_CLK_TCK));
    const page_size: u64 = @intCast(@max(1, c.sysconf(c._SC_PAGESIZE)));
    if (io.Dir.open("/proc")) |dir| {
        defer dir.close();
        while (dir.next()) |name| {
            const pid = std.fmt.parseInt(i32, name, 10) catch continue;
            if (pid <= 0) continue;
            if (processes.items.len >= max_processes) {
                s.truncated = true;
                break;
            }
            const stat_path = io.path("/proc/{d}/stat", .{pid});
            const stat = io.read(stat_path.slice(), &buffer) orelse {
                s.process_denied += 1;
                continue;
            };
            var process = m.parseProcess(stat, page_size) orelse continue;
            const status_path = io.path("/proc/{d}/status", .{pid});
            if (io.read(status_path.slice(), &buffer)) |status| {
                process.uid = @intCast(@min(m.fieldInt(status, "Uid") orelse 0, std.math.maxInt(u32)));
            }
            const io_path = io.path("/proc/{d}/io", .{pid});
            if (io.read(io_path.slice(), &buffer)) |data| {
                process.read = m.fieldInt(data, "read_bytes");
                process.write = m.fieldInt(data, "write_bytes");
            }
            const exe_path = io.path("/proc/{d}/exe", .{pid});
            process.exe = io.link(exe_path.slice());
            const group_path = io.path("/proc/{d}/cgroup", .{pid});
            if (io.read(group_path.slice(), &buffer)) |groups| {
                var lines = std.mem.splitScalar(u8, groups, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "0::") and (std.mem.indexOf(u8, line, "app-") != null or std.mem.indexOf(u8, line, "app.slice/") != null)) {
                        process.group.set(line[3..]);
                        break;
                    }
                }
            }
            // Recheck after metadata reads to reject a disappearing/reused PID.
            const last_stat = io.read(stat_path.slice(), &buffer) orelse continue;
            const verified = m.parseProcess(last_stat, page_size) orelse continue;
            if (!verified.id.eql(process.id)) continue;
            if (topology_same) {
                if (old_processes.get(pid)) |old| m.processRate(&process, old.*, seconds, ticks, s.cpus.len -| 1);
            }
            processes.append(a, process) catch unreachable;
        }
    }
    s.processes = processes.items;
    collectDisks(s, previous, seconds);
    collectNetwork(s, previous, seconds);
    collectSensors(s);
    collectGpu(s, "/sys/class/drm", &default_ids_paths);
    collectMounts(s);
    if (previous) |p| if (s.uptime - p.uptime > seconds + 3) {
        s.reset = true;
        for (s.cpus) |*cpu| {
            cpu.usage = null;
            cpu.io_wait = null;
        }
        for (s.processes) |*process| {
            process.cpu = null;
            process.read_rate = null;
            process.write_rate = null;
        }
        for (s.disks) |*disk| {
            disk.read_rate = null;
            disk.write_rate = null;
            disk.activity = null;
            disk.latency = null;
        }
        for (s.networks) |*network| {
            network.receive = null;
            network.send = null;
        }
    };
    s.duration = io.monotonic() - s.time;
    return s;
}
fn collectDisks(s: *m.Snapshot, previous: ?*const m.Snapshot, seconds: f64) void {
    const a = s.arena.allocator();
    var items: std.ArrayList(m.Disk) = .empty;
    const dir = io.Dir.open("/sys/class/block") orelse return;
    defer dir.close();
    while (dir.next()) |name| {
        if (items.items.len >= 256) {
            s.truncated = true;
            break;
        }
        if (std.mem.startsWith(u8, name, "loop") or std.mem.startsWith(u8, name, "ram")) continue;
        const base = io.path("/sys/class/block/{s}", .{name});
        const part = io.path("{s}/partition", .{base.slice()});
        if (io.exists(part.slice())) continue;
        var d: m.Disk = .{ .name = m.Name.init(name), .key = io.real(base.slice()) };
        const sequence_path = io.path("{s}/diskseq", .{base.slice()});
        if (io.integer(sequence_path.slice())) |sequence| {
            const key = io.path("{s}#{d}", .{ d.key.slice(), sequence });
            d.key.set(key.slice());
        }
        const model_path = io.path("{s}/device/model", .{base.slice()});
        d.model = io.text(model_path.slice());
        if (d.model.len == 0) d.model.set(name);
        const size_path = io.path("{s}/size", .{base.slice()});
        d.size = std.math.mul(u64, io.integer(size_path.slice()) orelse 0, 512) catch 0;
        const dev_path = io.path("{s}/dev", .{base.slice()});
        const dev = io.text(dev_path.slice());
        var pair = std.mem.splitScalar(u8, dev.slice(), ':');
        d.major = std.fmt.parseInt(u32, pair.next() orelse "0", 10) catch 0;
        d.minor = std.fmt.parseInt(u32, pair.next() orelse "0", 10) catch 0;
        const stat_path = io.path("{s}/stat", .{base.slice()});
        var buf: [2048]u8 = undefined;
        const data = io.read(stat_path.slice(), &buf) orelse continue;
        var words = std.mem.tokenizeAny(u8, data, " \t\n");
        var f: [11]u64 = @splat(0);
        var n: usize = 0;
        while (n < f.len) : (n += 1) f[n] = m.uint(words.next() orelse break) orelse break;
        if (n < 11) continue;
        d.read = std.math.mul(u64, f[2], 512) catch continue;
        d.write = std.math.mul(u64, f[6], 512) catch continue;
        d.busy = f[9];
        d.ops = f[0] +| f[4];
        d.ms = f[3] +| f[7];
        if (previous) |old| for (old.disks) |o| {
            if (!std.mem.eql(u8, d.key.slice(), o.key.slice()) or d.major != o.major or d.minor != o.minor) continue;
            d.read_rate = m.rate(d.read, o.read, seconds);
            d.write_rate = m.rate(d.write, o.write, seconds);
            if (m.rate(d.busy, o.busy, seconds)) |r| d.activity = @min(100, r / 10);
            if (m.delta(d.ops, o.ops)) |ops| {
                if (ops > 0) {
                    if (m.delta(d.ms, o.ms)) |ms| d.latency = @as(f64, @floatFromInt(ms)) / @as(f64, @floatFromInt(ops));
                }
            }
            break;
        };
        items.append(a, d) catch unreachable;
    }
    s.disks = items.items;
}
fn collectNetwork(s: *m.Snapshot, previous: ?*const m.Snapshot, seconds: f64) void {
    const a = s.arena.allocator();
    var items: std.ArrayList(m.Network) = .empty;
    var buffer: [65536]u8 = undefined;
    const data = io.read("/proc/net/dev", &buffer) orelse return;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
        if (items.items.len >= 256) {
            s.truncated = true;
            break;
        }
        const name = std.mem.trim(u8, line[0..colon], " \t");
        var n: m.Network = .{ .name = m.Name.init(name) };
        var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var f: [16]u64 = @splat(0);
        var count: usize = 0;
        while (count < 16) : (count += 1) f[count] = m.uint(words.next() orelse break) orelse break;
        if (count < 16) continue;
        n.rx = f[0];
        n.tx = f[8];
        n.index = c.if_nametoindex(n.name.z());
        const base = io.path("/sys/class/net/{s}", .{name});
        const mac_path = io.path("{s}/address", .{base.slice()});
        n.mac = io.text(mac_path.slice());
        const key = io.path("{d}:{s}", .{ n.index, n.mac.slice() });
        n.key.set(key.slice());
        const state_path = io.path("{s}/operstate", .{base.slice()});
        n.state = io.text(state_path.slice());
        const speed_path = io.path("{s}/speed", .{base.slice()});
        if (io.number(speed_path.slice())) |v| {
            if (v > 0) n.speed = v * 1e6;
        }
        if (previous) |old| for (old.networks) |o| {
            if (std.mem.eql(u8, n.key.slice(), o.key.slice()) and std.mem.eql(u8, n.name.slice(), o.name.slice())) {
                n.receive = m.rate(n.rx, o.rx, seconds);
                n.send = m.rate(n.tx, o.tx, seconds);
                break;
            }
        };
        items.append(a, n) catch unreachable;
    }
    var addresses: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&addresses) == 0) {
        defer c.freeifaddrs(addresses);
        var cursor = addresses;
        while (cursor) |entry| : (cursor = entry.ifa_next) {
            if (entry.ifa_addr == null or entry.ifa_name == null) continue;
            const family = entry.ifa_addr.*.sa_family;
            if (family != c.AF_INET and family != c.AF_INET6) continue;
            var out: [128]u8 = undefined;
            const src: *const anyopaque = if (family == c.AF_INET) &@as(*const c.struct_sockaddr_in, @ptrCast(@alignCast(entry.ifa_addr))).sin_addr else &@as(*const c.struct_sockaddr_in6, @ptrCast(@alignCast(entry.ifa_addr))).sin6_addr;
            if (c.inet_ntop(family, src, &out, out.len) == null) continue;
            for (items.items) |*item| if (std.mem.eql(u8, item.name.slice(), std.mem.span(entry.ifa_name))) {
                const joined = io.path("{s}{s}{s}", .{ item.address.slice(), if (item.address.len > 0) " · " else "", std.mem.sliceTo(&out, 0) });
                item.address.set(joined.slice());
                break;
            };
        }
    }
    std.mem.sort(m.Network, items.items, {}, struct {
        fn less(_: void, l: m.Network, r: m.Network) bool {
            const lp: u8 = if (std.mem.eql(u8, l.name.slice(), "lo")) 2 else if (std.mem.eql(u8, l.state.slice(), "up")) 0 else 1;
            const rp: u8 = if (std.mem.eql(u8, r.name.slice(), "lo")) 2 else if (std.mem.eql(u8, r.state.slice(), "up")) 0 else 1;
            return if (lp != rp) lp < rp else std.mem.lessThan(u8, l.name.slice(), r.name.slice());
        }
    }.less);
    s.networks = items.items;
}
fn collectSensors(s: *m.Snapshot) void {
    var items: std.ArrayList(m.Sensor) = .empty;
    const a = s.arena.allocator();
    const dir = io.Dir.open("/sys/class/hwmon") orelse return;
    defer dir.close();
    while (dir.next()) |hw| {
        const base = io.path("/sys/class/hwmon/{s}", .{hw});
        const device_path = io.path("{s}/name", .{base.slice()});
        const device = io.text(device_path.slice());
        const entries = io.Dir.open(base.slice()) orelse continue;
        defer entries.close();
        while (entries.next()) |name| {
            const fan = std.mem.startsWith(u8, name, "fan");
            if ((!fan and !std.mem.startsWith(u8, name, "temp")) or !std.mem.endsWith(u8, name, "_input")) continue;
            if (items.items.len >= 128) {
                s.truncated = true;
                break;
            }
            const input_path = io.path("{s}/{s}", .{ base.slice(), name });
            const value = io.number(input_path.slice()) orelse continue;
            const label_path = io.path("{s}/{s}_label", .{ base.slice(), name[0 .. name.len - 6] });
            var label = io.text(label_path.slice());
            if (label.len == 0) label.set(name[0 .. name.len - 6]);
            const title = io.path("{s} · {s}", .{ device.slice(), label.slice() });
            items.append(a, .{ .key = io.real(input_path.slice()), .name = m.Name.init(title.slice()), .value = value / (if (fan) @as(f64, 1) else 1000), .fan = fan }) catch unreachable;
        }
    }
    s.sensors = items.items;
}
const default_ids_paths = [_][]const u8{ "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids" };
const ids_memo_size = 16;
const IdsMemoEntry = struct { path: m.Path = .{}, vendor: u32 = 0, device: u32 = 0, name: m.Name = .{} };
var ids_memo: [ids_memo_size]IdsMemoEntry = @splat(.{});
var ids_memo_count: usize = 0;
fn sortedEntries(a: std.mem.Allocator, directory: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const dir = io.Dir.open(directory) orelse return &.{};
    defer dir.close();
    while (dir.next()) |name| {
        const copy = a.dupe(u8, name) catch break;
        names.append(a, copy) catch break;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    return names.items;
}
fn scanPciIds(ids_path: []const u8, vendor: u32, device: u32) ?m.Name {
    const path = m.Text(2048).init(ids_path);
    const fd = c.open(path.z(), c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var scanner: m.PciIdsScanner = .{ .target_vendor = vendor, .target_device = device };
    var chunk: [65536]u8 = undefined;
    var line: [4096]u8 = undefined;
    var line_len: usize = 0;
    var discarding = false;
    while (true) {
        const got = c.read(fd, &chunk, chunk.len);
        if (got < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return null;
        }
        if (got == 0) break;
        for (chunk[0..@intCast(got)]) |byte| {
            if (byte == '\n') {
                if (!discarding) if (scanner.feed(line[0..line_len])) |name| return m.Name.init(name);
                line_len = 0;
                discarding = false;
            } else if (!discarding) {
                if (line_len == line.len) {
                    discarding = true;
                } else {
                    line[line_len] = byte;
                    line_len += 1;
                }
            }
        }
    }
    if (!discarding and line_len > 0) if (scanner.feed(line[0..line_len])) |name| return m.Name.init(name);
    return null;
}
fn pciIdsName(ids_paths: []const []const u8, vendor: u32, device: u32) ?m.Name {
    for (ids_paths) |ids_path| {
        if (ids_path.len == 0) continue;
        var cached = false;
        for (ids_memo[0..ids_memo_count]) |entry| {
            if (entry.vendor != vendor or entry.device != device) continue;
            if (!std.mem.eql(u8, entry.path.slice(), ids_path)) continue;
            if (entry.name.len > 0) return entry.name;
            cached = true;
            break;
        }
        if (cached) continue;
        const name = scanPciIds(ids_path, vendor, device);
        if (ids_memo_count < ids_memo.len) {
            ids_memo[ids_memo_count] = .{ .path = m.Path.init(ids_path), .vendor = vendor, .device = device, .name = name orelse .{} };
            ids_memo_count += 1;
        }
        if (name) |value| return value;
    }
    return null;
}
fn collectGpu(s: *m.Snapshot, root: []const u8, ids_paths: []const []const u8) void {
    const a = s.arena.allocator();
    var items: std.ArrayList(m.Gpu) = .empty;
    var slots: std.ArrayList(m.Name) = .empty;
    for (sortedEntries(a, root)) |card_name| {
        if (!std.mem.startsWith(u8, card_name, "card") or std.mem.indexOfScalar(u8, card_name, '-') != null) continue;
        if (items.items.len >= 16) break;
        const base = io.path("{s}/{s}/device", .{ root, card_name });
        var gpu: m.Gpu = .{ .key = io.real(base.slice()) };
        var uevent_buffer: [4096]u8 = undefined;
        var slot: m.Name = .{};
        const uevent_path = io.path("{s}/uevent", .{base.slice()});
        if (io.read(uevent_path.slice(), &uevent_buffer)) |text| if (m.ueventValue(text, "PCI_SLOT_NAME")) |value| slot.set(value);
        if (slot.len == 0) {
            const real = io.real(base.slice());
            slot.set(std.fs.path.basename(real.slice()));
        }
        if (slot.len == 0) slot.set(card_name);
        var duplicate = false;
        for (slots.items) |seen| {
            if (!std.mem.eql(u8, seen.slice(), slot.slice())) continue;
            duplicate = true;
            break;
        }
        if (duplicate) continue;
        slots.append(a, slot) catch unreachable;
        const vendor_path = io.path("{s}/vendor", .{base.slice()});
        const vendor = io.text(vendor_path.slice());
        gpu.vendor = std.fmt.parseInt(u32, vendor.slice(), 0) catch 0;
        const driver_path = io.path("{s}/driver", .{base.slice()});
        const driver = io.link(driver_path.slice());
        gpu.driver.set(std.fs.path.basename(driver.slice()));
        const label = io.path("{s} · {s}", .{ if (gpu.vendor == 0x1002) "AMD GPU" else if (gpu.vendor == 0x8086) "Intel GPU" else if (gpu.vendor == 0x10de) "NVIDIA GPU" else "Display adapter", card_name });
        gpu.name.set(label.slice());
        const device_path = io.path("{s}/device", .{base.slice()});
        const device_text = io.text(device_path.slice());
        const device = std.fmt.parseInt(u32, device_text.slice(), 0) catch 0;
        const product_path = io.path("{s}/product_name", .{base.slice()});
        const product = io.text(product_path.slice());
        if (product.len > 0) {
            gpu.name = product;
        } else if (gpu.vendor == 0x1002) {
            if (pciIdsName(ids_paths, gpu.vendor, device)) |pci_name| {
                const name = io.path("AMD {s}", .{pci_name.slice()});
                gpu.name.set(name.slice());
            } else if (device != 0) {
                const name = io.path("AMD GPU {x:0>4}", .{device});
                gpu.name.set(name.slice());
            }
        }
        if (gpu.vendor == 0x1002) {
            const vram_vendor_path = io.path("{s}/mem_info_vram_vendor", .{base.slice()});
            gpu.integrated = !io.exists(vram_vendor_path.slice());
        }
        inline for (.{ .{ "gpu_busy_percent", "usage" }, .{ "mem_busy_percent", "mem_usage" }, .{ "mem_info_vram_used", "used" }, .{ "mem_info_vram_total", "total" }, .{ "mem_info_gtt_used", "gtt_used" }, .{ "mem_info_gtt_total", "gtt_total" } }) |field| {
            const p = io.path("{s}/{s}", .{ base.slice(), field[0] });
            if (io.number(p.slice())) |value| @field(gpu, field[1]) = value;
        }
        if (gpu.vendor == 0x8086) {
            const frequency_path = io.path("{s}/{s}/gt_cur_freq_mhz", .{ root, card_name });
            gpu.frequency = io.number(frequency_path.slice());
        }
        if (gpu.vendor == 0x1002) {
            var clock_buffer: [65536]u8 = undefined;
            const sclk_path = io.path("{s}/pp_dpm_sclk", .{base.slice()});
            if (io.read(sclk_path.slice(), &clock_buffer)) |text| gpu.max_frequency = m.parseSclkList(text);
        }
        const speed_path = io.path("{s}/current_link_speed", .{base.slice()});
        const speed = io.text(speed_path.slice());
        gpu.pcie_gen = m.pcieGen(speed.slice());
        const width_path = io.path("{s}/current_link_width", .{base.slice()});
        if (io.integer(width_path.slice())) |width| gpu.pcie_width = @intCast(@min(width, std.math.maxInt(u32)));
        const hw_path = io.path("{s}/hwmon", .{base.slice()});
        const hw_names = sortedEntries(a, hw_path.slice());
        if (hw_names.len > 0) {
            const hw_dev_path = io.path("{s}/{s}", .{ hw_path.slice(), hw_names[0] });
            var labels: std.ArrayList(m.LabeledFile) = .empty;
            for (sortedEntries(a, hw_dev_path.slice())) |file_name| {
                if (!std.mem.endsWith(u8, file_name, "_label")) continue;
                const label_path = io.path("{s}/{s}", .{ hw_dev_path.slice(), file_name });
                const hw_label = io.text(label_path.slice());
                if (hw_label.len == 0) continue;
                const label_copy = a.dupe(u8, hw_label.slice()) catch continue;
                labels.append(a, .{ .file = file_name[0 .. file_name.len - 6], .label = label_copy }) catch continue;
            }
            const temp_path = io.path("{s}/{s}_input", .{ hw_dev_path.slice(), m.chooseTemp(labels.items) });
            if (io.number(temp_path.slice())) |value| gpu.temp = value / 1000;
            if (gpu.vendor == 0x1002) {
                if (m.chooseClock(labels.items, "sclk")) |file| {
                    const p = io.path("{s}/{s}_input", .{ hw_dev_path.slice(), file });
                    if (io.number(p.slice())) |value| gpu.frequency = value / 1000000;
                }
                if (m.chooseClock(labels.items, "mclk")) |file| {
                    const p = io.path("{s}/{s}_input", .{ hw_dev_path.slice(), file });
                    if (io.number(p.slice())) |value| gpu.mem_frequency = value / 1000000;
                }
            }
            const average_path = io.path("{s}/power1_average", .{hw_dev_path.slice()});
            const input_path = io.path("{s}/power1_input", .{hw_dev_path.slice()});
            if (io.number(average_path.slice())) |average| {
                gpu.power = if (average == 0)
                    if (io.number(input_path.slice())) |input| input / 1000000 else average / 1000000
                else
                    average / 1000000;
            } else if (io.number(input_path.slice())) |input| gpu.power = input / 1000000;
            if (gpu.power != null) {
                const power_label_path = io.path("{s}/power1_label", .{hw_dev_path.slice()});
                gpu.power_label = io.text(power_label_path.slice());
            }
            const cap_path = io.path("{s}/power1_cap", .{hw_dev_path.slice()});
            if (io.number(cap_path.slice())) |cap| gpu.power_cap = cap / 1000000;
            const fan_input_path = io.path("{s}/fan1_input", .{hw_dev_path.slice()});
            const fan_max_path = io.path("{s}/fan1_max", .{hw_dev_path.slice()});
            if (io.number(fan_input_path.slice())) |fan_input| if (io.number(fan_max_path.slice())) |fan_max| {
                if (fan_max > 0) gpu.fan = fan_input * 100 / fan_max;
            };
        }
        items.append(a, gpu) catch unreachable;
    }
    std.mem.sort(m.Gpu, items.items, {}, struct {
        fn less(_: void, left: m.Gpu, right: m.Gpu) bool {
            if (left.integrated != right.integrated) return !left.integrated;
            const left_total = left.total orelse 0;
            const right_total = right.total orelse 0;
            if (left_total != right_total) return left_total > right_total;
            return std.mem.lessThan(u8, left.key.slice(), right.key.slice());
        }
    }.less);
    s.gpus = items.items;
}
fn collectMounts(s: *m.Snapshot) void {
    var buffer: [131072]u8 = undefined;
    const text = io.read("/proc/self/mountinfo", &buffer) orelse return;
    var items: std.ArrayList(m.Mount) = .empty;
    const a = s.arena.allocator();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (items.items.len >= 128) break;
        const separator = std.mem.indexOf(u8, line, " - ") orelse continue;
        var right = std.mem.tokenizeScalar(u8, line[separator + 3 ..], ' ');
        const kind = right.next() orelse continue;
        // Skip remote, FUSE and pseudo filesystems: statvfs on an unavailable mount can block indefinitely.
        if (!std.mem.eql(u8, kind, "ext4") and !std.mem.eql(u8, kind, "xfs") and !std.mem.eql(u8, kind, "btrfs") and !std.mem.eql(u8, kind, "vfat")) continue;
        var left = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
        _ = left.next();
        _ = left.next();
        const dev = left.next() orelse continue;
        _ = left.next();
        const mount = left.next() orelse continue;
        var decoded: [512]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < mount.len and n < decoded.len) {
            if (mount[i] == '\\' and i + 3 < mount.len) {
                decoded[n] = std.fmt.parseInt(u8, mount[i + 1 .. i + 4], 8) catch break;
                i += 4;
            } else {
                decoded[n] = mount[i];
                i += 1;
            }
            n += 1;
        }
        if (i != mount.len) continue;
        var item: m.Mount = .{ .path = m.Path.init(decoded[0..n]), .kind = m.Name.init(kind) };
        var parts = std.mem.splitScalar(u8, dev, ':');
        item.device.major = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch continue;
        item.device.minor = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch continue;
        var stat: c.struct_statvfs = undefined;
        const raw_path = a.dupeSentinel(u8, decoded[0..n], 0) catch unreachable;
        if (c.statvfs(raw_path, &stat) != 0) continue;
        item.total = std.math.mul(u64, stat.f_blocks, stat.f_frsize) catch continue;
        item.available = std.math.mul(u64, stat.f_bavail, stat.f_frsize) catch continue;
        items.append(a, item) catch unreachable;
    }
    s.mounts = items.items;
}

pub const Worker = struct {
    mutex: c.GMutex = std.mem.zeroes(c.GMutex),
    cond: c.GCond = std.mem.zeroes(c.GCond),
    thread: ?std.Thread = null,
    latest: ?*m.Snapshot = null,
    stopped: bool = false,
    paused: bool = false,
    immediate: bool = true,
    reset: bool = false,
    interval: i64 = 1000000,
    detail: m.Identity = .{},
    pub fn inspect(self: *Worker, id: m.Identity) void {
        c.g_mutex_lock(&self.mutex);
        self.detail = id;
        c.g_mutex_unlock(&self.mutex);
    }
    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn configure(self: *Worker, paused: bool, interval: i64, manual: bool) void {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        if (self.paused != paused) {
            self.reset = true;
            self.immediate = !paused;
        }
        self.paused = paused;
        self.interval = interval;
        self.immediate = self.immediate or manual;
        c.g_cond_signal(&self.cond);
    }
    pub fn take(self: *Worker) ?*m.Snapshot {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        const s = self.latest;
        self.latest = null;
        return s;
    }
    pub fn stop(self: *Worker) void {
        c.g_mutex_lock(&self.mutex);
        self.stopped = true;
        c.g_cond_signal(&self.cond);
        c.g_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.take()) |s| s.unref();
        c.g_cond_clear(&self.cond);
        c.g_mutex_clear(&self.mutex);
    }
    fn run(self: *Worker) void {
        var previous: ?*m.Snapshot = null;
        defer if (previous) |p| p.unref();
        var sequence: u64 = 0;
        var due = io.monotonic();
        while (true) {
            c.g_mutex_lock(&self.mutex);
            while (!self.stopped and !self.immediate and (self.paused or io.monotonic() < due)) {
                if (self.paused) c.g_cond_wait(&self.cond, &self.mutex) else {
                    _ = c.g_cond_wait_until(&self.cond, &self.mutex, due);
                }
            }
            if (self.stopped) {
                c.g_mutex_unlock(&self.mutex);
                break;
            }
            const reset = self.reset;
            self.reset = false;
            self.immediate = false;
            const interval = self.interval;
            const detail = self.detail;
            c.g_mutex_unlock(&self.mutex);
            sequence += 1;
            const s = collect(if (reset) null else previous, sequence);
            s.reset = s.reset or reset;
            if (detail.pid > 0) {
                var buffer: [32768]u8 = undefined;
                const stat_path = io.path("/proc/{d}/stat", .{detail.pid});
                if (io.read(stat_path.slice(), &buffer)) |text| {
                    if (m.parseProcess(text, 4096)) |p| if (p.id.eql(detail)) {
                        s.detail_id = detail;
                        const pss_path = io.path("/proc/{d}/smaps_rollup", .{detail.pid});
                        if (io.read(pss_path.slice(), &buffer)) |data| {
                            if (m.fieldInt(data, "Pss")) |v| s.pss = std.math.mul(u64, v, 1024) catch null;
                        }
                        const cmd_path = io.path("/proc/{d}/cmdline", .{detail.pid});
                        if (io.read(cmd_path.slice(), &buffer)) |data| s.command.set(data);
                    };
                }
            }
            if (previous) |p| p.unref();
            previous = s;
            c.g_mutex_lock(&self.mutex);
            if (self.latest) |p| p.unref();
            self.latest = s.ref();
            c.g_mutex_unlock(&self.mutex);
            due = @max(io.monotonic() + 1000, s.time + interval);
        }
    }
};
test "live snapshots use actual counters and release ownership" {
    const s = collect(null, 1);
    defer s.unref();
    try std.testing.expect(s.time > 0);
    try std.testing.expect(s.memory.total > 0);
    try std.testing.expect(s.cpus.len > 0);
    try std.testing.expect(s.processes.len > 0);
    const next = collect(s, 2);
    defer next.unref();
    try std.testing.expect(next.time >= s.time);
    for (next.processes) |p| if (p.cpu) |v| try std.testing.expect(v >= 0 and v <= 100);
}
fn writeFixture(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}
test "GPU fixture reads AMD sysfs fields, dedups and orders cards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const tmp_path = path_buffer[0..path_length];
    const root = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "drm" });
    defer std.testing.allocator.free(root);
    const ids_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "pci.ids" });
    defer std.testing.allocator.free(ids_path);
    try writeFixture(tmp.dir, "drm/card1/device/vendor", "0x1002\n");
    try writeFixture(tmp.dir, "drm/card1/device/device", "0xabcd\n");
    try writeFixture(tmp.dir, "drm/card1/device/product_name", "Fixture Discrete 7900\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_info_vram_vendor", "Samsung\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_info_vram_total", "17179869184\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_info_vram_used", "2147483648\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_info_gtt_total", "8589934592\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_info_gtt_used", "1073741824\n");
    try writeFixture(tmp.dir, "drm/card1/device/gpu_busy_percent", "37\n");
    try writeFixture(tmp.dir, "drm/card1/device/mem_busy_percent", "23\n");
    try writeFixture(tmp.dir, "drm/card1/device/pp_dpm_sclk", "0: 500Mhz *\n1: 2200Mhz\n2: 2500Mhz\n");
    try writeFixture(tmp.dir, "drm/card1/device/current_link_speed", "16.0 GT/s PCIe\n");
    try writeFixture(tmp.dir, "drm/card1/device/current_link_width", "16\n");
    try writeFixture(tmp.dir, "drm/card1/device/uevent", "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/name", "amdgpu\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/temp1_label", "junction\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/temp1_input", "85000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/temp2_label", "edge\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/temp2_input", "65000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/freq1_label", "mclk\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/freq1_input", "1000000000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/freq2_label", "sclk\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/freq2_input", "2500000000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/power1_average", "0\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/power1_input", "45000000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/power1_cap", "120000000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/power1_label", "PPT\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/fan1_input", "1200\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon0/fan1_max", "3000\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon1/temp1_label", "edge\n");
    try writeFixture(tmp.dir, "drm/card1/device/hwmon/hwmon1/temp1_input", "99000\n");
    try writeFixture(tmp.dir, "drm/card2/device/vendor", "0x1002\n");
    try writeFixture(tmp.dir, "drm/card2/device/device", "0x1234\n");
    try writeFixture(tmp.dir, "drm/card2/device/mem_info_vram_total", "536870912\n");
    try writeFixture(tmp.dir, "drm/card2/device/mem_info_vram_used", "134217728\n");
    try writeFixture(tmp.dir, "drm/card2/device/gpu_busy_percent", "5\n");
    try writeFixture(tmp.dir, "drm/card2/device/uevent", "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:04:00.0\n");
    try writeFixture(tmp.dir, "drm/card3/device/product_name", "Duplicate card\n");
    try writeFixture(tmp.dir, "drm/card3/device/uevent", "DRIVER=amdgpu\nPCI_SLOT_NAME=0000:03:00.0\n");
    try writeFixture(tmp.dir, "pci.ids", "# fixture ids\n1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t--  Subclass separator\n\tzzzz  Not a device\n\t1234  Fixture Graphics [Fixture Marketing]\n\t\t17aa  Subsystem line\n");
    var s: m.Snapshot = .{ .arena = .init(std.testing.allocator) };
    defer s.arena.deinit();
    const ids_paths = [_][]const u8{ids_path};
    collectGpu(&s, root, &ids_paths);
    try std.testing.expectEqual(@as(usize, 2), s.gpus.len);
    const gpu = s.gpus[0];
    try std.testing.expectEqualStrings("Fixture Discrete 7900", gpu.name.slice());
    try std.testing.expect(!gpu.integrated);
    try std.testing.expectEqual(@as(?f64, 37), gpu.usage);
    try std.testing.expectEqual(@as(?f64, 23), gpu.mem_usage);
    try std.testing.expectEqual(@as(?f64, 2147483648), gpu.used);
    try std.testing.expectEqual(@as(?f64, 17179869184), gpu.total);
    try std.testing.expectEqual(@as(?f64, 1073741824), gpu.gtt_used);
    try std.testing.expectEqual(@as(?f64, 8589934592), gpu.gtt_total);
    try std.testing.expectEqual(@as(?f64, 65), gpu.temp);
    try std.testing.expectEqual(@as(?f64, 45), gpu.power);
    try std.testing.expectEqual(@as(?f64, 120), gpu.power_cap);
    try std.testing.expectEqualStrings("PPT", gpu.power_label.slice());
    try std.testing.expectEqual(@as(?f64, 40), gpu.fan);
    try std.testing.expectEqual(@as(?f64, 2500), gpu.frequency);
    try std.testing.expectEqual(@as(?f64, 1000), gpu.mem_frequency);
    try std.testing.expectEqual(@as(?f64, 2500), gpu.max_frequency);
    try std.testing.expectEqual(@as(?u32, 4), gpu.pcie_gen);
    try std.testing.expectEqual(@as(?u32, 16), gpu.pcie_width);
    const apu = s.gpus[1];
    try std.testing.expectEqualStrings("AMD Fixture Marketing", apu.name.slice());
    try std.testing.expect(apu.integrated);
    try std.testing.expectEqual(@as(?f64, 5), apu.usage);
    try std.testing.expectEqual(@as(?f64, 536870912), apu.total);
}
