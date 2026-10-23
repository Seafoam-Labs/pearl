const std = @import("std");
pub fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: std.Build.LazyPath) *std.Build.Module {
    if (b.modules.get("pearl_i18n")) |existing| return existing;
    const m = b.addModule("pearl_i18n", .{ .root_source_file = root, .target = target, .optimize = optimize, .link_libc = true });
    const options = b.addOptions();
    options.addOption([]const u8, "prefix", b.option([]const u8, "i18n-prefix", "Installed language-pack prefix (defaults to /usr)") orelse "/usr");
    m.addOptions("i18n_options", options);
    return m;
}
