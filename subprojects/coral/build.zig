const std = @import("std");
pub fn build(b: *std.Build) void {
    const bindings = b.dependency("gobject", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const scanner = @import("wayland").Scanner.create(b, .{ .wayland_xml = b.path("../../bindings/protocols/wayland.xml"), .wayland_protocols = b.path("../../bindings/protocols") });
    scanner.addCustomProtocol(b.path("../../bindings/protocols/aqueous-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("../../bindings/protocols/ext-workspace-v1.xml"));
    scanner.generate("aqueous_shell_manager_v1", 2);
    const native = b.createModule(.{ .root_source_file = scanner.result, .target = target, .optimize = optimize });
    // Shared read-only appearance boundary with the parent tree, identical to Dome's and Phyto's.
    const appearance = b.createModule(.{ .root_source_file = b.path("../../src/appearance_client.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "gdkwayland4" }) |name| appearance.addImport(name, bindings.module(name));
    appearance.addImport("wayland", native);
    for ([_][]const u8{ "gtk4", "wayland-client", "libpng" }) |name| appearance.linkSystemLibrary(name, .{ .use_pkg_config = .force });
    const git_variant = b.option(bool, "git-variant", "Use the Git application identity") orelse false;
    const command = if (git_variant) "coral-git" else "coral";
    const options = b.addOptions();
    options.addOption(bool, "git_variant", git_variant);
    options.addOption([]const u8, "development_styles", b.pathFromRoot("resources"));
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "Enable isolated native test instrumentation") orelse false);
    const m = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| m.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    m.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    m.addOptions("build_options", options);
    m.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    m.addAnonymousImport("theme_style", .{ .root_source_file = b.path("resources/theme.css") });
    m.addImport("appearance_client", appearance);
    // Shared by path with the parent tree so every executable renders identical
    // log lines and redacts untrusted text the same way.
    const logging = b.createModule(.{ .root_source_file = b.path("../../src/core/logging.zig"), .target = target, .optimize = optimize });
    const diagnostics = b.createModule(.{ .root_source_file = b.path("../../src/diagnostics_bridge.zig"), .target = target, .optimize = optimize });
    diagnostics.addImport("appearance_client", appearance);
    m.addImport("logging", logging);
    m.addImport("diagnostics", diagnostics);
    m.addImport("previews", previewModule(b, bindings, target, optimize, b.path("../../src/files/preview/root.zig"), m.import_table.get("build_options").?, diagnostics));
    m.addImport("file_chooser", chooserModule(b, b.path("../../src/files/chooser.zig"), m, bindings, m.import_table.get("previews").?, git_variant));
    const exe = b.addExecutable(.{ .name = command, .root_module = m });
    b.installArtifact(exe);
    b.installFile("resources/coral-dark.xml", b.fmt("share/{s}/styles/coral-dark.xml", .{command}));
    b.installFile("resources/coral-light.xml", b.fmt("share/{s}/styles/coral-light.xml", .{command}));
    const generated = b.addWriteFiles();
    const identity = if (git_variant) "org.aqueous.Coral.Git" else "org.aqueous.Coral";
    inline for (.{ .{ "packaging/org.aqueous.Coral.desktop", "share/applications", "desktop" }, .{ "packaging/org.aqueous.Coral.metainfo.xml", "share/metainfo", "metainfo.xml" } }) |entry| {
        const original = @embedFile(entry[0]);
        const named = std.mem.replaceOwned(u8, b.allocator, original, "org.aqueous.Coral", identity) catch @panic("Out of memory");
        const launcher = if (git_variant) std.mem.replaceOwned(u8, b.allocator, named, "Exec=coral", "Exec=coral-git") catch @panic("Out of memory") else named;
        const binary = if (git_variant) std.mem.replaceOwned(u8, b.allocator, launcher, "<binary>coral</binary>", "<binary>coral-git</binary>") catch @panic("Out of memory") else launcher;
        const title = if (git_variant) std.mem.replaceOwned(u8, b.allocator, binary, "Name=Coral\n", "Name=Coral Git\n") catch @panic("Out of memory") else binary;
        const content = if (git_variant) std.mem.replaceOwned(u8, b.allocator, title, "<name>Coral</name>", "<name>Coral Git</name>") catch @panic("Out of memory") else title;
        const file = generated.add(entry[2], content);
        b.getInstallStep().dependOn(&b.addInstallFile(file, b.fmt("{s}/{s}.{s}", .{ entry[1], identity, entry[2] })).step);
    }
    b.installFile("resources/org.aqueous.Coral.svg", b.fmt("share/icons/hicolor/scalable/apps/{s}.svg", .{identity}));
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Launch Coral").dependOn(&run.step);
    const tm = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| tm.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    tm.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    const tests = b.addTest(.{ .root_module = tm });
    const test_step = b.step("test", "Test file format, revisions, Unicode tokenization and real GIO saves");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const appearance_module = b.createModule(.{ .root_source_file = b.path("src/appearance.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| appearance_module.addImport(name, bindings.module(name));
    appearance_module.addImport("appearance_client", appearance);
    appearance_module.addAnonymousImport("theme_style", .{ .root_source_file = b.path("resources/theme.css") });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| appearance_module.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    const appearance_tests = b.addTest(.{ .root_module = appearance_module });
    test_step.dependOn(&b.addRunArtifact(appearance_tests).step);
    const io = b.addOptions();
    io.addOption(bool, "test_hooks", true);
    io.addOption(bool, "git_variant", false);
    io.addOption([]const u8, "development_styles", b.pathFromRoot("resources"));
    const im = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| im.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    im.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    im.addOptions("build_options", io);
    im.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    im.addAnonymousImport("theme_style", .{ .root_source_file = b.path("resources/theme.css") });
    im.addImport("appearance_client", appearance);
    im.addImport("logging", logging);
    im.addImport("diagnostics", diagnostics);
    im.addImport("previews", previewModule(b, bindings, target, optimize, b.path("../../src/files/preview/root.zig"), im.import_table.get("build_options").?, diagnostics));
    im.addImport("file_chooser", chooserModule(b, b.path("../../src/files/chooser.zig"), im, bindings, im.import_table.get("previews").?, git_variant));
    const ie = b.addExecutable(.{ .name = "coral-test", .root_module = im });
    const integration = b.addSystemCommand(&.{ "python3", "tests/native.py", "--binary" });
    integration.addArtifactArg(ie);
    if (b.args) |args| integration.addArgs(args);
    b.step("integration", "Run native Coral workflows in an isolated Wayland session").dependOn(&integration.step);
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
