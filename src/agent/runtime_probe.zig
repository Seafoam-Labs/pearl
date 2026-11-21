//! Capability discovery for the mistralrs server, never an upstream version allowlist.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const config = @import("config.zig");
const helper = @import("../config/helper_process.zig");
pub const environment = [_][:0]const u8{ "PATH=/usr/bin:/usr/local/bin", "LANG=C.UTF-8", "LC_ALL=C", "NO_COLOR=1" };
pub const Probe = struct {
    executable: [:0]const u8,
    fingerprint: []const u8,
    version: []const u8,
    /// `mistralrs serve --help` output; chat and embedding share these flags.
    help: []const u8,
    /// The main help advertises the `serve embedding` subcommand.
    embedding: bool,
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
        .custom => try a.dupeSentinel(u8, cfg.executable, 0),
        .system => blk: {
            for ([_][:0]const u8{ "/usr/bin/mistralrs", "/usr/local/bin/mistralrs" }) |p| if (std.c.access(p, std.c.X_OK) == 0) break :blk p;
            const cargo = try std.fmt.allocPrintSentinel(a, "{s}/.cargo/bin/mistralrs", .{std.mem.span(glib.getHomeDir())}, 0);
            if (std.c.access(cargo, std.c.X_OK) == 0) break :blk cargo;
            return error.AssistantRuntimeNotInstalled;
        },
        .packaged => blk: {
            var buffer: [4096]u8 = undefined;
            const own = try @import("../settings/distribution.zig").executable(&buffer);
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/../libexec/pearl/assistant/mistralrs", .{std.fs.path.dirname(own).?}, 0);
        },
    };
    if (!std.fs.path.isAbsolute(path) or std.c.access(path, std.c.X_OK) != 0) return error.AssistantRuntimeNotInstalled;
    var resolved: [std.posix.PATH_MAX]u8 = undefined;
    const resolved_ptr = std.c.realpath(path, &resolved) orelse return error.InvalidRuntimeExecutable;
    return a.dupeSentinel(u8, std.mem.span(resolved_ptr), 0);
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
    const help = try invoke(a, exe, &.{ "serve", "--help" }, cancel, env);
    try required(help);
    const version = try invoke(a, exe, &.{"--version"}, cancel, env);
    const main_help = try invoke(a, exe, &.{"--help"}, cancel, env);
    // Device discovery is best-effort: `mistralrs doctor` reports system
    // information whose format is not stable. An unreadable or unparseable
    // report yields no devices and the caller falls back to CPU.
    var listing: []const @import("compute.zig").Device = &.{};
    if (devices) {
        const report = invoke(a, exe, &.{"doctor"}, cancel, env) catch "";
        listing = @import("compute.zig").parseDoctor(a, report) catch &.{};
    }
    if (!std.mem.eql(u8, identity, try fingerprint(a, exe))) return error.RuntimeChanged;
    return .{ .executable = exe, .fingerprint = identity, .version = try sanitized(a, version, 256), .help = help, .embedding = hasFlag(main_help, "embedding"), .devices = listing, .child_environment = env };
}
fn childEnvironment(a: std.mem.Allocator) ![]const [:0]const u8 {
    var result: std.ArrayList([:0]const u8) = .empty;
    try result.appendSlice(a, &environment);
    // Preserve explicit device visibility. Probe and server receive exactly
    // the same snapshot; no loader injection or runtime argument overrides.
    for ([_][:0]const u8{ "CUDA_VISIBLE_DEVICES", "GGML_VK_VISIBLE_DEVICES" }) |name| {
        if (glib.getenv(name)) |value| {
            const bytes = std.mem.span(value);
            try config.text(bytes, 1024);
            try result.append(a, try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ name, bytes }, 0));
        }
    }
    return result.items;
}
fn invoke(a: std.mem.Allocator, exe: [:0]const u8, args: []const [:0]const u8, cancel: *gio.Cancellable, env: []const [:0]const u8) ![]const u8 {
    var argv: std.ArrayList([:0]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, args);
    const result = try helper.runConfigured(a, argv.items, null, cancel, 5000, null, .{ .stdout_limit = 256 * 1024, .stderr_limit = 256 * 1024, .environment = env });
    if (!result.success) return error.RuntimeProbeFailed;
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ result.stdout, result.stderr });
}
pub fn sanitized(a: std.mem.Allocator, bytes: []const u8, limit: usize) ![]const u8 {
    const out = try a.alloc(u8, @min(bytes.len, limit));
    for (bytes[0..out.len], out) |ch, *dest| dest.* = if (ch >= 32 and ch < 127) ch else ' ';
    return std.mem.trim(u8, out, " ");
}
/// Chat templates and reasoning are handled natively by mistral.rs (detected
/// from GGUF metadata), and the server has no authentication or built-in
/// agent to disable. Only the bounded loopback serving surface is required.
pub fn required(help: []const u8) !void {
    for ([_][]const u8{ "--host", "--port", "--max-model-len", "--no-ui", "--cpu", "--max-seqs" }) |flag| if (!hasFlag(help, flag)) return error.RuntimeCapabilityMissing;
    if (!hasFlag(help, "-f") and !hasFlag(help, "--quantized-file")) return error.RuntimeCapabilityMissing;
}
/// Semantic search needs the `serve embedding` subcommand in addition to the
/// common server capabilities. Older releases are rejected, never silently replaced.
pub fn requiredEmbedding(info: Probe) !void {
    try required(info.help);
    if (!info.embedding) return error.RuntimeEmbeddingUnsupported;
}
test "option discovery uses exact tokens, not versions or prefix matches" {
    try std.testing.expect(hasFlag("-n, --n-gpu-layers ORDINAL:COUNT\n--gpu-memory-utilization FRACTION", "--n-gpu-layers"));
    try std.testing.expect(!hasFlag("--device-draft X", "--device"));
    try std.testing.expectError(error.RuntimeCapabilityMissing, required("--version arbitrary-new-release"));
    const chat = "-f, --quantized-file --host --port --max-model-len --no-ui --cpu --max-seqs --disable-metrics --disable-access-log";
    try required(chat);
    try std.testing.expectError(error.RuntimeCapabilityMissing, required("--host --port --max-model-len --no-ui --cpu"));
    const info = Probe{ .executable = "/usr/bin/mistralrs", .fingerprint = "test", .version = "test", .help = chat, .embedding = false, .devices = &.{}, .child_environment = &.{} };
    try std.testing.expectError(error.RuntimeEmbeddingUnsupported, requiredEmbedding(info));
    var embedding = info;
    embedding.embedding = true;
    try requiredEmbedding(embedding);
}
