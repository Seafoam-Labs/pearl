const std = @import("std");
/// Both standalone application builds and Pearl use this same module definition.
pub fn module(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: std.Build.LazyPath, options: *std.Build.Module, diagnostics: *std.Build.Module) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gdk4", "gio2", "glib2", "gobject2", "gdkpixbuf2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("build_options", options);
    m.addImport("diagnostics", diagnostics);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    return m;
}
