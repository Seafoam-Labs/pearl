//! Capability discovery, never an upstream version allowlist.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const config = @import("config.zig");
const helper = @import("../config/helper_process.zig");
pub const environment = [_][:0]const u8{ "PATH=/usr/bin:/usr/local/bin", "LANG=C.UTF-8", "LC_ALL=C", "MALLOC_ARENA_MAX=2", "OMP_NUM_THREADS=2", "NO_COLOR=1" };
pub const Probe = struct {
    executable: [:0]const u8,
    fingerprint: []const u8,
    version: []const u8,
    help: []const u8,
    devices: []const @import("compute.zig").Device,
    child_environment: []const [:0]const u8,
    pub fn has(self: Probe, flag: []const u8) bool {
        return hasFlag(self.help, flag);
    }
};
pub fn hasFlag(help: []const u8, flag: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, help, " \t\r\n,=[]");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, flag)) return true;
    return false;
}
pub fn resolve(a: std.mem.Allocator, cfg: config.RuntimeConfig) ![:0]const u8 {
    const path = switch (cfg.source) {
        .custom => try a.dupeZ(u8, cfg.executable),
        .system => blk: {
            for ([_][:0]const u8{ "/usr/bin/llama-server", "/usr/local/bin/llama-server" }) |p| if (std.c.access(p, std.c.X_OK) == 0) break :blk p;
            return error.AssistantRuntimeNotInstalled;
        },
        .packaged => blk: {
            var buffer: [4096]u8 = undefined;
            const own = try @import("../settings/distribution.zig").executable(&buffer);
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/../libexec/pearl/assistant/llama-server", .{std.fs.path.dirname(own).?}, 0);
        },
    };
    if (!std.fs.path.isAbsolute(path) or std.c.access(path, std.c.X_OK) != 0) return error.AssistantRuntimeNotInstalled;
    var resolved: [std.posix.PATH_MAX]u8 = undefined;
    const resolved_ptr = std.c.realpath(path, &resolved) orelse return error.InvalidRuntimeExecutable;
    return a.dupeZ(u8, std.mem.span(resolved_ptr));
}
pub fn fingerprint(a: std.mem.Allocator, path: [:0]const u8) ![]const u8 {
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true, .CTIME = true, .INO = true }, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidRuntimeExecutable;
    return std.fmt.allocPrint(a, "{s}:{d}:{d}:{d}:{d}:{d}:{d}", .{ path, st.ino, st.size, st.mtime.sec, st.mtime.nsec, st.ctime.sec, st.ctime.nsec });
}
pub fn inspect(a: std.mem.Allocator, cfg: config.RuntimeConfig, devices: bool, cancel: *gio.Cancellable) !Probe {
    const exe = try resolve(a, cfg);
    const identity = try fingerprint(a, exe);
    const env = try childEnvironment(a);
    const help = try invoke(a, exe, "--help", cancel, env);
    try required(help);
    const version = try invoke(a, exe, "--version", cancel, env);
    const listing = if (devices and hasFlag(help, "--list-devices")) try invoke(a, exe, "--list-devices", cancel, env) else "";
    if (!std.mem.eql(u8, identity, try fingerprint(a, exe))) return error.RuntimeChanged;
    return .{ .executable = exe, .fingerprint = identity, .version = try sanitized(a, version, 256), .help = help, .devices = try @import("compute.zig").parse(a, listing), .child_environment = env };
}
fn childEnvironment(a: std.mem.Allocator) ![]const [:0]const u8 {
    var result: std.ArrayList([:0]const u8) = .empty;
    try result.appendSlice(a, &environment);
    // Preserve explicit device visibility, never loader injection or LLAMA_ARG
    // overrides. Probe and server receive exactly the same snapshot.
    for ([_][:0]const u8{ "CUDA_VISIBLE_DEVICES", "GGML_VK_VISIBLE_DEVICES" }) |name| {
        if (glib.getenv(name)) |value| {
            const bytes = std.mem.span(value);
            try config.text(bytes, 1024);
            try result.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ name, bytes }, 0));
        }
    }
    return result.items;
}
fn invoke(a: std.mem.Allocator, exe: [:0]const u8, option: [:0]const u8, cancel: *gio.Cancellable, env: []const [:0]const u8) ![]const u8 {
    const result = try helper.runConfigured(a, &.{ exe, option }, null, cancel, 5000, null, .{ .stdout_limit = 256 * 1024, .stderr_limit = 256 * 1024, .environment = env });
    if (!result.success) return error.RuntimeProbeFailed;
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ result.stdout, result.stderr });
}
pub fn sanitized(a: std.mem.Allocator, bytes: []const u8, limit: usize) ![]const u8 {
    const out = try a.alloc(u8, @min(bytes.len, limit));
    for (bytes[0..out.len], out) |ch, *dest| dest.* = if (ch >= 32 and ch < 127) ch else ' ';
    return std.mem.trim(u8, out, " ");
}
pub fn required(help: []const u8) !void {
    for ([_][]const u8{ "--host", "--port", "--api-key-file", "--alias", "--jinja", "--ctx-size", "--parallel", "--threads", "--threads-batch", "--threads-http", "--batch-size", "--ubatch-size", "--gpu-layers" }) |flag| if (!hasFlag(help, flag)) return error.RuntimeCapabilityMissing;
    // Old runtimes without a web UI or built-in agent need no disabling switch.
    if ((hasFlag(help, "--webui") or hasFlag(help, "--ui")) and !hasFlag(help, "--no-webui") and !hasFlag(help, "--no-ui")) return error.RuntimeCapabilityMissing;
    if ((hasFlag(help, "--agent") or hasFlag(help, "--mcp-servers-config")) and !hasFlag(help, "--no-agent")) return error.RuntimeCapabilityMissing;
}
test "option discovery uses exact tokens, not versions or prefix matches" {
    try std.testing.expect(hasFlag("-ngl, --gpu-layers N\n--fit [on|off]", "--gpu-layers"));
    try std.testing.expect(!hasFlag("--device-draft X", "--device"));
    try std.testing.expectError(error.RuntimeCapabilityMissing, required("--version arbitrary-new-release"));
}
