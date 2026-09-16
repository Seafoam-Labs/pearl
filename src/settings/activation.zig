const std = @import("std");
const e = @import("../aqueous/entities.zig");
const nav = @import("../desktop/settings_navigation.zig");
pub const Request = struct {
    settings: u32 = 1,
    session: []const u8,
    display: []const u8,
    op: enum { activate, probe } = .activate,
    page: nav.Route = .overview,
    section: ?[]const u8 = null,
    activation: ?[]const u8 = null,
    pub fn target(self: Request) nav.Target {
        return .{ .page = self.page, .section = self.section };
    }
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8, test_hooks: bool) !Request {
    try @import("../config/preferences.zig").boundedJson(bytes, 8192, 1);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (v != .object) return error.InvalidRequest;
    for ([_][]const u8{ "settings", "session", "display" }) |key| if (!v.object.contains(key)) return error.InvalidRequest;
    var it = v.object.iterator();
    while (it.next()) |field| {
        inline for (@typeInfo(Request).@"struct".fields) |known| {
            if (std.mem.eql(u8, known.name, field.key_ptr.*)) break;
        } else return error.InvalidRequest;
    }
    const r = try e.read(Request, a, v);
    if (r.settings != 1) return error.Version;
    try e.sessionToken(r.session);
    if (r.display.len == 0 or r.display.len > 4096 or r.display[0] != '/' or std.mem.indexOfScalar(u8, r.display, 0) != null) return error.InvalidRequest;
    try r.target().validate();
    if (r.op == .probe and !test_hooks) return error.Unsupported;
    if (r.activation) |token| if (token.len == 0 or token.len > 4096 or std.mem.indexOfScalar(u8, token, 0) != null) return error.InvalidRequest;
    return r;
}
pub fn endpoint(a: std.mem.Allocator, runtime: []const u8, session: []const u8) ![:0]u8 {
    const base = try @import("protocol.zig").endpoint(a, runtime, session);
    defer a.free(base);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/settings-app.sock", .{std.fs.path.dirname(base).?}, 0);
    errdefer a.free(path);
    if (path.len >= 108) return error.InvalidEndpoint;
    return path;
}
test "activation excludes production probes and validates route before dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = "{\"settings\":1,\"session\":\"0123456789abcdef0123456789abcdef\",\"display\":\"/tmp/wayland-1\"";
    try std.testing.expectEqual(nav.Route.overview, (try parse(a, prefix ++ "}", false)).page);
    try std.testing.expectError(error.Unsupported, parse(a, prefix ++ ",\"op\":\"probe\"}", false));
    _ = try parse(a, prefix ++ ",\"op\":\"probe\"}", true);
    try std.testing.expectError(error.InvalidSection, parse(a, prefix ++ ",\"page\":\"sound\",\"section\":\"displays\"}", false));
    try std.testing.expectError(error.InvalidRequest, parse(a, prefix ++ ",\"shell_command\":\"anything\"}", false));
}
