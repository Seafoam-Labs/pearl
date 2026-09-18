//! Private supervised helper. fd 3 is a connected socket, never guest stdin.
const std = @import("std");
const m = @import("plugins/model.zig");
const wire = @import("plugins/protocol.zig");
const Package = @import("plugins/package.zig").Package;
const Runtime = @import("plugins/runtime.zig").Runtime;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/resource.h");
});
const a = std.heap.c_allocator;
extern "c" fn getenv([*:0]const u8) ?[*:0]u8;
fn env(name: [*:0]const u8) ![:0]const u8 {
    return std.mem.span(getenv(name) orelse return error.HelperEnvironment);
}
pub fn main() !void {
    // Die with the supervisor even if a guest is busy. EOF handles graceful exit.
    const parent = c.getppid();
    if (c.prctl(c.PR_SET_PDEATHSIG, c.SIGKILL, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0 or c.getppid() != parent or parent == 1) return error.HelperParent;
    if (c.prctl(c.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.HelperPrivileges;
    // Bound the entire compiler/helper, including allocations outside Wasm memory.
    // Wasmtime reservations are reduced explicitly in Runtime.create.
    const memory: c.struct_rlimit = .{ .rlim_cur = 512 * 1024 * 1024, .rlim_max = 512 * 1024 * 1024 };
    const core: c.struct_rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    if (c.setrlimit(c.RLIMIT_AS, &memory) != 0 or c.setrlimit(c.RLIMIT_CORE, &core) != 0) return error.HelperLimits;
    const package = try Package.load(try env("PEARL_PLUGIN_PACKAGE"));
    defer package.destroy();
    if (!std.mem.eql(u8, &package.digest, try env("PEARL_PLUGIN_DIGEST"))) return error.PluginContentChanged;
    const generation = try std.fmt.parseInt(u64, try env("PEARL_PLUGIN_GENERATION"), 10);
    const runtime = try Runtime.create(package.wasm, package.manifest, .{ .input_activity = std.mem.eql(u8, try env("PEARL_PLUGIN_ACTIVITY"), "1") });
    defer runtime.destroy();
    var buffer: [m.Limits.frame]u8 = undefined;
    var used: usize = 0;
    var sequence: u64 = 0;
    while (true) {
        if (used == buffer.len) return error.PluginFrameLimit;
        const n = c.read(3, buffer[used..].ptr, buffer.len - used);
        if (n == 0) return;
        if (n < 0) return error.HelperRead;
        used += @intCast(n);
        while (std.mem.indexOfScalar(u8, buffer[0..used], '\n')) |end| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const alloc = arena.allocator();
            const request = try wire.parse(wire.Request, alloc, buffer[0..end]);
            if (request.generation != generation or request.sequence != sequence + 1) return error.PluginSequence;
            sequence = request.sequence;
            runtime.activity_state = request.state;
            var reply: wire.Reply = .{ .generation = generation, .sequence = sequence, .activity_epoch = request.state.epoch };
            var scene: ?[]u8 = null;
            if (request.event) |event| {
                if (event.settings.len > 16) return error.PluginSettingsLimit;
                for (event.settings) |s| {
                    if (!m.identifier(s.key)) return error.PluginSetting;
                    try m.text(s.value, 256);
                }
                if (event.kind == .activity and (!runtime.grants.input_activity or !runtime.activity_requested or request.state.availability != .available or event.count != 1)) return error.PluginActivityDenied;
                scene = runtime.handle(event) catch |err| blk: {
                    reply.error_code = @errorName(err);
                    break :blk null;
                };
            }
            defer if (scene) |s| a.free(s);
            if (scene) |s| reply.scene = try std.json.parseFromSliceLeaky(m.Scene, alloc, s, .{});
            reply.timer_ms = runtime.timer_ms;
            reply.timer_changed = request.event != null and runtime.timer_changed;
            reply.activity_requested = runtime.activity_requested;
            const bytes = try std.json.Stringify.valueAlloc(alloc, reply, .{ .emit_null_optional_fields = false });
            if (bytes.len + 1 > m.Limits.frame) return error.PluginFrameLimit;
            const line = try std.fmt.allocPrint(alloc, "{s}\n", .{bytes});
            var sent: usize = 0;
            while (sent < line.len) {
                const count = c.send(3, line[sent..].ptr, line.len - sent, c.MSG_NOSIGNAL);
                if (count <= 0) return error.HelperWrite;
                sent += @intCast(count);
            }
            if (reply.error_code != null or (if (request.event) |event| event.kind == .deactivate else false)) return;
            std.mem.copyForwards(u8, &buffer, buffer[end + 1 .. used]);
            used -= end + 1;
        }
    }
}
