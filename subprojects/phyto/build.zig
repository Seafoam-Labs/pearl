const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const git_variant = b.option(bool, "git-variant", "Use the Git runtime preview helper") orelse false;
    const bindings = b.dependency("gobject", .{});
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "Enable test-only state inspection") orelse false);
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "pango1", "gdkpixbuf2" }) |name| module.addImport(name, bindings.module(name));
    module.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    module.addOptions("build_options", options);
    module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    // Shared by path with the parent tree so every executable renders identical
    // log lines and redacts untrusted text the same way.
    const logging = b.createModule(.{ .root_source_file = b.path("../../src/core/logging.zig"), .target = target, .optimize = optimize });
    const diagnostics = b.createModule(.{ .root_source_file = b.path("../../src/diagnostics/safe_text.zig"), .target = target, .optimize = optimize });
    module.addImport("logging", logging);
    module.addImport("diagnostics", diagnostics);
    module.addImport("previews", previewModule(b, bindings, target, optimize, b.path("../../src/files/preview/root.zig"), module.import_table.get("build_options").?, diagnostics));
    module.addImport("file_chooser", chooserModule(b, b.path("../../src/files/chooser.zig"), module, bindings, module.import_table.get("previews").?, git_variant));
    const exe = b.addExecutable(.{ .name = "phyto", .root_module = module });
    b.installArtifact(exe);
    b.installFile("packaging/org.aqueous.Phyto.desktop", "share/applications/org.aqueous.Phyto.desktop");
    b.installFile("resources/org.aqueous.Phyto.svg", "share/icons/hicolor/scalable/apps/org.aqueous.Phyto.svg");
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Launch the native Phyto application").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/core/model.zig"), .target = target, .optimize = optimize }) });
    const test_step = b.step("test", "Test navigation, capability policy and file operations");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const preview_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("../../src/files/preview/core/preview.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(preview_tests).step);
    const context_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/core/context.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(context_tests).step);
    const engine_module = b.createModule(.{ .root_source_file = b.path("src/operations/engine.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2" }) |name| engine_module.addImport(name, bindings.module(name));
    const engine_tests = b.addTest(.{ .root_module = engine_module });
    test_step.dependOn(&b.addRunArtifact(engine_tests).step);
    const network_module = b.createModule(.{ .root_source_file = b.path("src/network_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "pango1", "gdkpixbuf2" }) |name| network_module.addImport(name, bindings.module(name));
    const network_tests = b.addTest(.{ .root_module = network_module });
    test_step.dependOn(&b.addRunArtifact(network_tests).step);
    const test_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "pango1", "gdkpixbuf2" }) |name| test_module.addImport(name, bindings.module(name));
    test_module.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    const test_options = b.addOptions();
    test_options.addOption(bool, "test_hooks", true);
    test_module.addOptions("build_options", test_options);
    test_module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    test_module.addImport("logging", logging);
    test_module.addImport("diagnostics", diagnostics);
    test_module.addImport("previews", previewModule(b, bindings, target, optimize, b.path("../../src/files/preview/root.zig"), test_module.import_table.get("build_options").?, diagnostics));
    test_module.addImport("file_chooser", chooserModule(b, b.path("../../src/files/chooser.zig"), test_module, bindings, test_module.import_table.get("previews").?, git_variant));
    const test_exe = b.addExecutable(.{ .name = "phyto-test", .root_module = test_module });
    const integration = b.addSystemCommand(&.{ "python3", "tests/native.py", "--binary" });
    integration.addArtifactArg(test_exe);
    if (b.args) |args| integration.addArgs(args);
    const menus = b.addSystemCommand(&.{ "python3", "tests/context_native.py", "--binary" });
    menus.addArtifactArg(test_exe);
    if (b.args) |args| menus.addArgs(args);
    b.step("test-context-menus", "Exercise native context menus and batch operations").dependOn(&menus.step);
    b.step("integration", "Exercise native GTK in a private Aqueous session and capture evidence").dependOn(&integration.step);
    const networks = b.addSystemCommand(&.{ "python3", "tests/network_native.py", "--binary" });
    networks.addArtifactArg(test_exe);
    if (b.args) |args| networks.addArgs(args);
    b.step("test-network", "Test saved connections and real GVfs mounts in an isolated session").dependOn(&networks.step);
    const providers = b.addSystemCommand(&.{ "python3", "tests/providers_helper.py", "--faults", "--binary" });
    providers.addArtifactArg(test_exe);
    b.step("test-preview-providers", "Test PDF/video rendering and sandbox lifecycle without a display").dependOn(&providers.step);
    const previews = b.addSystemCommand(&.{ "python3", "tests/previews_native.py", "--binary" });
    previews.addArtifactArg(test_exe);
    if (b.args) |args| previews.addArgs(args);
    b.step("test-previews", "Test bounded decoding, cache and native file previews").dependOn(&previews.step);
}

fn previewModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: std.Build.LazyPath, options: *std.Build.Module, diagnostics: *std.Build.Module) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gdk4", "gio2", "glib2", "gobject2", "gdkpixbuf2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("build_options", options);
    m.addImport("diagnostics", diagnostics);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    return m;
}

fn chooserModule(b: *std.Build, root: std.Build.LazyPath, host: *std.Build.Module, bindings: *std.Build.Dependency, previews: *std.Build.Module, git_variant: bool) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = root, .target = host.resolved_target, .optimize = host.optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("previews", previews);
    const options = b.addOptions();
    options.addOption([:0]const u8, "helper_path", if (git_variant) "/usr/lib/pearl-git/pearl-preview-helper" else "/usr/lib/pearl/pearl-preview-helper");
    m.addOptions("chooser_options", options);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    return m;
}
