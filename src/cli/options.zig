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
        const pairs = .{ .{ "services", "status", protocol.Op.services_status }, .{ "audio", "set", protocol.Op.audio_set }, .{ "brightness", "set", protocol.Op.brightness_set }, .{ "profile", "set", protocol.Op.profile_set }, .{ "popup", "show", protocol.Op.popup_show }, .{ "popup", "hide", protocol.Op.popup_hide }, .{ "popup", "toggle", protocol.Op.popup_toggle }, .{ "bar", "set", protocol.Op.bar_set }, .{ "frame", "set", protocol.Op.frame_set }, .{ "osd", "show", protocol.Op.osd_show }, .{ "launcher", "show", protocol.Op.launcher_show }, .{ "launcher", "hide", protocol.Op.launcher_hide }, .{ "launcher", "toggle", protocol.Op.launcher_toggle }, .{ "control-center", "show", protocol.Op.control_show }, .{ "control-center", "toggle", protocol.Op.control_toggle }, .{ "calendar", "toggle", protocol.Op.calendar_toggle }, .{ "bar", "groups", protocol.Op.bar_groups }, .{ "layout", "get", protocol.Op.layout_get }, .{ "layout", "set", protocol.Op.layout_set }, .{ "overview", "toggle", protocol.Op.overview_toggle } };
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
        } else if (std.mem.eql(u8, flag, "--left") and r.left == null) {
            r.left = value;
        } else if (std.mem.eql(u8, flag, "--center") and r.center == null) {
            r.center = value;
        } else if (std.mem.eql(u8, flag, "--right") and r.right == null) {
            r.right = value;
        } else if (std.mem.eql(u8, flag, "--layout") and r.layout == null) {
            r.layout = value;
        } else if (std.mem.eql(u8, flag, "--generation") and r.generation == null) {
            r.generation = std.fmt.parseInt(u64, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--device") and r.device == null) {
            r.device = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--kind") and r.kind == null) {
            r.kind = std.meta.stringToEnum(@import("../services/policy.zig").Kind, value) orelse return error.Usage;
        } else if (std.mem.eql(u8, flag, "--volume") and r.volume == null) {
            r.volume = std.fmt.parseInt(u8, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--mute") and r.mute == null) {
            r.mute = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.Usage;
        } else if (std.mem.eql(u8, flag, "--default") and r.make_default == null) {
            r.make_default = if (std.mem.eql(u8, value, "true")) true else return error.Usage;
        } else if (std.mem.eql(u8, flag, "--target") and r.target == null) {
            r.target = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--percent") and r.percent == null) {
            r.percent = std.fmt.parseInt(u8, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--profile") and r.profile == null) {
            r.profile = if (std.mem.eql(u8, value, "power-saver")) 0 else if (std.mem.eql(u8, value, "balanced")) 1 else if (std.mem.eql(u8, value, "performance")) 2 else return error.Usage;
        } else if (std.mem.eql(u8, flag, "--offset") and r.offset == null) {
            r.offset = std.fmt.parseInt(u16, value, 10) catch return error.Usage;
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
    \\       pearlctl launcher show|hide|toggle [--output ID]
    \\       pearlctl control-center show|toggle [--output ID]
    \\       pearlctl calendar toggle [--output ID]
    \\       pearlctl overview toggle [--output ID]
    \\       pearlctl layout get|set --output ID [--layout NAME]
    \\       pearlctl bar groups --output ID --left ITEMS --center ITEMS --right ITEMS
    \\       ITEMS: comma-separated launcher,workspaces,title,clock,keyboard,overview,control
    \\
    \\       pearlctl services status [--offset N]
    \\       pearlctl audio set --kind sink|source|playback|recording [--generation N --device ID]
    \\                          [--volume 0..100] [--mute true|false] [--default true] [--target ID]
    \\       pearlctl brightness set --percent 0..100
    \\       pearlctl profile set --profile power-saver|balanced|performance
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

test "desktop commands validate group ownership and native layout names" {
    const t = std.testing;
    const pane = try parse(&.{ "launcher", "toggle", "--output", "opaque-output" });
    try t.expectEqual(protocol.Op.launcher_toggle, pane.request.op);
    const layout = try parse(&.{ "layout", "set", "--output", "opaque-output", "--layout", "reverse-dwindle" });
    try t.expectEqual(protocol.Op.layout_set, layout.request.op);
    try t.expectError(error.Usage, parse(&.{ "layout", "set", "--output", "x", "--layout", "fake-layout" }));
    try t.expectError(error.Usage, parse(&.{ "layout", "get", "--output", "x", "--layout", "grid" }));
    try t.expectError(error.Usage, parse(&.{ "launcher", "hide", "--output", "x" }));
    try t.expectError(error.Usage, parse(&.{ "bar", "groups", "--output", "x", "--left", "launcher", "--center", "clock", "--right", "clock" }));
}
