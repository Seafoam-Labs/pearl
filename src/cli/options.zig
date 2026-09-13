const std = @import("std");
const protocol = @import("protocol.zig");
pub const Options = union(enum) { help, version, request: protocol.Request };
pub fn parse(args: []const []const u8) !Options {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .help;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return .version;
    if (args.len == 0) return error.Usage;
    var index: usize = 1;
    const op: protocol.Op = blk: {
        if (std.mem.eql(u8, args[0], "status")) break :blk .status;
        if (std.mem.eql(u8, args[0], "quit")) break :blk .quit;
        if (args.len < 2) return error.Usage;
        index = 2;
        const pairs = .{ .{ "popup", "show", protocol.Op.popup_show }, .{ "popup", "hide", protocol.Op.popup_hide }, .{ "popup", "toggle", protocol.Op.popup_toggle }, .{ "bar", "set", protocol.Op.bar_set }, .{ "frame", "set", protocol.Op.frame_set }, .{ "osd", "show", protocol.Op.osd_show } };
        inline for (pairs) |p| if (std.mem.eql(u8, args[0], p[0]) and std.mem.eql(u8, args[1], p[1])) break :blk p[2];
        return error.Usage;
    };
    var r: protocol.Request = .{ .op = op };
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.Usage;
        const flag = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, flag, "--output") and r.output == null) {
            r.output = value;
        } else if (std.mem.eql(u8, flag, "--edge") and r.edge == null) {
            r.edge = std.meta.stringToEnum(protocol.Edge, value) orelse return error.Usage;
        } else if (std.mem.eql(u8, flag, "--size") and r.size == null) {
            r.size = std.fmt.parseInt(u16, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--text") and r.text == null) {
            r.text = value;
        } else if (std.mem.eql(u8, flag, "--duration") and r.duration_ms == null) {
            r.duration_ms = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else return error.Usage;
    }
    // Reuse the wire schema for option applicability and value validation.
    r.session = "00000000000000000000000000000000";
    r.display = "/validation-only";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), r, .{ .emit_null_optional_fields = false });
    _ = protocol.parse(arena.allocator(), encoded) catch return error.Usage;
    r.session = "";
    r.display = "";
    return .{ .request = r };
}
pub const usage =
    \\Usage: pearlctl status | quit
    \\       pearlctl popup show|toggle [--output ID]
    \\       pearlctl popup hide
    \\       pearlctl bar set --output ID --edge top|right|bottom|left --size 32..160
    \\       pearlctl frame set --output ID --edge EDGE --size 0..160
    \\       pearlctl osd show --text TEXT [--output ID] [--duration 100..10000]
    \\
    \\Uses the current AQUEOUS_SOCKET, WAYLAND_DISPLAY and XDG_RUNTIME_DIR.
    \\Output IDs come from `pearlctl status`. Replies are Pearl control v1 JSON.
    \\
;

test "CLI rejects unknown options, duplicate flags and inappropriate fields" {
    const t = std.testing;
    try t.expectError(error.Usage, parse(&.{ "status", "--output", "1" }));
    try t.expectError(error.Usage, parse(&.{ "popup", "hide", "--edge", "top" }));
    try t.expectError(error.Usage, parse(&.{ "popup", "show", "--output", "1", "--output", "2" }));
    try t.expectError(error.Usage, parse(&.{ "frame", "set", "--size", "8" }));
    const result = try parse(&.{ "osd", "show", "--text", "Sound muted", "--duration", "1200" });
    try t.expectEqual(protocol.Op.osd_show, result.request.op);
}
