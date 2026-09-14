const std = @import("std");

pub const Mode = enum { session, demo };
pub const Options = struct {
    mode: Mode = .session,
    action: enum { run, help, version, check_environment } = .run,

    pub fn parse(args: []const []const u8) !Options {
        var result: Options = .{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--demo")) {
                result.mode = .demo;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                result.action = .help;
            } else if (std.mem.eql(u8, arg, "--check-environment")) {
                result.action = .check_environment;
            } else if (std.mem.eql(u8, arg, "--version")) {
                result.action = .version;
            } else return error.UnknownArgument;
        }
        return result;
    }
};

pub const Environment = struct {
    desktop: []const u8,
    runtime: []const u8,
    display: []const u8,
    endpoint: []const u8,
};

fn cleanAbsolute(path: []const u8) bool {
    if (path.len < 2 or path.len > 4096 or path[0] != '/') return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Only validates launch prerequisites. Aqueous identity/state is verified by T04.
pub fn validate(mode: Mode, environment: Environment) !void {
    if (environment.display.len == 0) return error.WaylandDisplayRequired;
    if (mode == .demo) return;
    var desktops = std.mem.splitScalar(u8, environment.desktop, ':');
    var supported = false;
    while (desktops.next()) |desktop| {
        if (std.ascii.eqlIgnoreCase(desktop, "Aqueous")) supported = true;
    }
    if (!supported) return error.AqueousSessionRequired;
    if (!cleanAbsolute(environment.runtime)) return error.InvalidRuntimeDirectory;
    if (!cleanAbsolute(environment.endpoint) or !std.mem.startsWith(u8, environment.endpoint, environment.runtime))
        return error.InvalidAqueousEndpoint;
    const suffix = environment.endpoint[environment.runtime.len..];
    if (!std.mem.startsWith(u8, suffix, "/aqueous/") or !std.mem.endsWith(u8, suffix, "/ipc.sock"))
        return error.InvalidAqueousEndpoint;
    if (suffix.len <= "/aqueous//ipc.sock".len) return error.InvalidAqueousEndpoint;
    const instance = suffix["/aqueous/".len .. suffix.len - "/ipc.sock".len];
    if (instance.len > 128 or std.mem.indexOfScalar(u8, instance, '/') != null) return error.InvalidAqueousEndpoint;
}

pub fn diagnostic(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownArgument => "Unknown argument. Use pearl --help.",
        error.WaylandDisplayRequired => "Pearl requires a Wayland display. Use scripts/dev-session.py to start a private Aqueous session.",
        error.AqueousSessionRequired => "Pearl requires an Aqueous session. Use --demo for the standalone gallery on Wayland.",
        error.InvalidRuntimeDirectory => "XDG_RUNTIME_DIR must be an absolute, normalized session directory.",
        error.InvalidAqueousEndpoint => "AQUEOUS_SOCKET must identify this runtime's aqueous/<instance>/ipc.sock. Launch Pearl from Aqueous or use --demo.",
        else => "Pearl could not start.",
    };
}

test "demo is explicit and unknown options fail" {
    try std.testing.expectEqual(Mode.session, (try Options.parse(&.{})).mode);
    try std.testing.expectEqual(Mode.demo, (try Options.parse(&.{"--demo"})).mode);
    try std.testing.expectError(error.UnknownArgument, Options.parse(&.{"--demoo"}));
}

test "session prerequisites reject other desktops and foreign runtime endpoints" {
    var env: Environment = .{ .desktop = "Aqueous:wlroots", .runtime = "/run/user/1000", .display = "wayland-1", .endpoint = "/run/user/1000/aqueous/abc/ipc.sock" };
    try validate(.session, env);
    env.desktop = "NotAqueous";
    try std.testing.expectError(error.AqueousSessionRequired, validate(.session, env));
    try validate(.demo, env);
    env.desktop = "Aqueous";
    for ([_][]const u8{ "/run/user/10001/aqueous/abc/ipc.sock", "/tmp/aqueous/abc/ipc.sock", "/run/user/1000/aqueous/../ipc.sock", "/run/user/1000/aqueous//ipc.sock", "/run/user/1000/aqueous/a/b/ipc.sock" }) |endpoint| {
        env.endpoint = endpoint;
        try std.testing.expectError(error.InvalidAqueousEndpoint, validate(.session, env));
    }
    env.display = "";
    try std.testing.expectError(error.WaylandDisplayRequired, validate(.demo, env));
}
