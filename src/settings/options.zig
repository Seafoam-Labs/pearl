const std = @import("std");
const nav = @import("../desktop/settings_navigation.zig");
pub const Options = struct {
    target: nav.Target = .{},
    help: bool = false,
    version: bool = false,
    pub fn parse(args: []const []const u8) !Options {
        var result: Options = .{};
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .{ .help = true };
        if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return .{ .version = true };
        var page = false;
        var section = false;
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, args[i], "--page") and !page) {
                result.target.page = try nav.parse(args[i + 1]);
                page = true;
            } else if (std.mem.eql(u8, args[i], "--section") and !section) {
                result.target.section = args[i + 1];
                section = true;
            } else return error.InvalidArguments;
        }
        try result.target.validate();
        return result;
    }
};
pub const usage = "Usage: pearl-settings [--page PAGE] [--section AQUEOUS_SECTION]\n\nPages: overview, network, bluetooth, sound, power, appearance, bar,\n       notifications, session, aqueous, advanced\nAqueous sections: appearance, layouts, input, keybinds, rules, displays, advanced\n\nA generic launch opens Overview. Repeated launches activate the existing\nwindow in this Aqueous session. Editing requires a running Pearl session.\n";
test "standalone arguments use shared destinations and fail before activation" {
    try std.testing.expectEqual(nav.Route.overview, (try Options.parse(&.{})).target.page);
    for (std.enums.values(nav.Route)) |page| try std.testing.expectEqual(page, (try Options.parse(&.{ "--page", page.id() })).target.page);
    try std.testing.expectEqualStrings("displays", (try Options.parse(&.{ "--page", "aqueous", "--section", "displays" })).target.section.?);
    for ([_][]const []const u8{ &.{"--page"}, &.{ "--page", "wifi" }, &.{ "--page", "sound", "--page", "power" }, &.{ "--section", "displays" }, &.{ "--page", "aqueous", "--section", "bogus" }, &.{"--test-fixture"} }) |bad|
        try std.testing.expectError(if (bad.len == 2 and std.mem.eql(u8, bad[1], "wifi")) error.InvalidRoute else if (bad.len == 2) error.InvalidSection else if (bad.len == 4 and std.mem.eql(u8, bad[0], "--page") and std.mem.eql(u8, bad[1], "aqueous")) error.UnknownPage else error.InvalidArguments, Options.parse(bad));
}
