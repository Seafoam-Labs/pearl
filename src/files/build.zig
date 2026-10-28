const std = @import("std");
/// Every host imports one chooser module backed by its existing binding modules.
pub fn module(b: *std.Build, root: std.Build.LazyPath, host: *std.Build.Module, bindings: *std.Build.Dependency, previews: *std.Build.Module, git_variant: bool) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = root, .target = host.resolved_target, .optimize = host.optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("previews", previews);
    const options = b.addOptions();
    options.addOption([:0]const u8, "helper_path", if (git_variant) "/usr/lib/pearl-git/pearl-preview-helper" else "/usr/lib/pearl/pearl-preview-helper");
    m.addOptions("chooser_options", options);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    m.addImport("i18n", host.import_table.get("i18n").?);
    return m;
}
