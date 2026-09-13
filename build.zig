const std = @import("std");
const Scanner = @import("wayland").Scanner;
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0"))
        @panic("Pearl requires Zig 0.16.0; see .zigversion");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bindings = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    if (b.option(bool, "codegen", "Build the pinned Ghostty GIR generator") orelse false) {
        if (b.lazyDependency("gobject_codegen", .{ .target = b.graph.host, .optimize = .ReleaseSafe })) |generator| {
            b.installArtifact(generator.artifact("translate-gir"));
            for ([_][]const u8{ "gir-fixes", "binding-overrides", "extensions" }) |directory|
                b.installDirectory(.{ .source_dir = generator.path(directory), .install_dir = .prefix, .install_subdir = b.fmt("share/gir-codegen/{s}", .{directory}) });
        }
        return;
    }
    const scanner = Scanner.create(b, .{ .wayland_xml = b.path("bindings/protocols/wayland.xml"), .wayland_protocols = b.path("bindings/protocols") });
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-background-effect-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-workspace-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-window-info-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-foreign-toplevel-list-v1.xml"));
    scanner.generate("aqueous_window_info_manager_v1", 3);
    scanner.generate("aqueous_shell_manager_v1", 2);
    scanner.generate("wl_compositor", 6);
    scanner.generate("ext_background_effect_manager_v1", 1);
    const native = b.createModule(.{ .root_source_file = scanner.result, .target = target, .optimize = optimize });
    const native_export = b.addInstallFile(scanner.result, "share/pearl/bindings/wayland.zig");
    b.step("generate-wayland", "Export generated native protocol bindings for review and reproducibility checks").dependOn(&native_export.step);

    const system_versions = b.addSystemCommand(&.{
        "pkg-config",     "--print-errors",     "--exists",
        "gtk4 >= 4.22.5", "glib-2.0 >= 2.88.3", "gtk4-layer-shell-0 >= 1.3.0",
    });
    const resource_command = b.addSystemCommand(&.{"glib-compile-resources"});
    resource_command.addFileArg(b.path("resources/pearl.gresource.xml"));
    resource_command.addArg("--sourcedir");
    resource_command.addDirectoryArg(b.path("resources"));
    resource_command.addArg("--target");
    const resources = resource_command.addOutputFileArg("pearl.gresource");
    resource_command.addArg("--dependency-file");
    _ = resource_command.addDepFileOutputArg("pearl.gresource.d");

    const module = gtkModule(b, bindings, target, optimize, "src/main.zig");
    configureApp(b, module, resources, false);
    module.addImport("wayland", native);
    const app = b.addExecutable(.{ .name = "pearl", .root_module = module });
    app.step.dependOn(&system_versions.step);
    b.installArtifact(app);

    const spike_module = gtkModule(b, bindings, target, optimize, "spikes/t00/main.zig");
    const spike = b.addExecutable(.{ .name = "pearl-t00", .root_module = spike_module });
    spike.step.dependOn(&system_versions.step);
    b.installArtifact(spike);
    const bindings_test = b.addTest(.{ .root_module = spike_module });
    bindings_test.step.dependOn(&system_versions.step);
    b.step("test-bindings", "Test generated binding types and API coverage").dependOn(&b.addRunArtifact(bindings_test).step);

    const pure_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize });
    pure_module.addImport("aqueous_fixtures", b.createModule(.{ .root_source_file = b.path("tests/fixtures/aqueous/fixtures.zig"), .target = target, .optimize = optimize }));
    const pure = b.addTest(.{ .root_module = pure_module });
    b.step("test", "Run pure lifecycle, startup and Aqueous model tests without GTK or a compositor").dependOn(&b.addRunArtifact(pure).step);

    const ctl_module = b.createModule(.{ .root_source_file = b.path("src/pearlctl.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| ctl_module.addImport(name, bindings.module(name));
    const ctl = b.addExecutable(.{ .name = "pearlctl", .root_module = ctl_module });
    b.installArtifact(ctl);

    const adapter_module = b.createModule(.{ .root_source_file = b.path("src/adapter_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "glibunix2", "gobject2", "gdkpixbuf2" }) |name| adapter_module.addImport(name, bindings.module(name));
    const adapter_probe = b.addExecutable(.{ .name = "pearl-adapter-probe", .root_module = adapter_module });
    b.step("adapter-probe", "Build the private IPC test driver").dependOn(&b.addInstallArtifact(adapter_probe, .{}).step);

    const adapter_unit = b.addTest(.{ .root_module = adapter_module });
    b.step("test-adapter-unit", "Check endpoint and image bounds using generated GIO bindings").dependOn(&b.addRunArtifact(adapter_unit).step);
    const adapter_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_adapter.py", "--probe" });
    adapter_test.addArtifactArg(adapter_probe);
    if (b.args) |args| adapter_test.addArgs(args);
    b.step("test-adapter", "Exercise IPC recovery, policy and commands on private sockets and nested Aqueous").dependOn(&adapter_test.step);

    const test_module = gtkModule(b, bindings, target, optimize, "src/main.zig");
    configureApp(b, test_module, resources, true);
    test_module.addImport("wayland", native);
    const integration_app = b.addExecutable(.{ .name = "pearl-integration", .root_module = test_module });
    integration_app.step.dependOn(&system_versions.step);
    const integration = b.addSystemCommand(&.{ "python3", "tests/integration/test_lifecycle.py", "--pearl" });
    integration.addArtifactArg(integration_app);
    integration.addArg("--production-pearl");
    integration.addArtifactArg(app);
    if (b.args) |args| integration.addArgs(args);
    b.step("integration", "Run lifecycle tests on private Aqueous displays and buses").dependOn(&integration.step);
    const components = b.addSystemCommand(&.{ "python3", "tests/integration/test_components.py", "--pearl" });
    components.addArtifactArg(integration_app);
    if (b.args) |args| components.addArgs(args);
    b.step("test-components", "Exercise gallery keyboard behavior and capture private Aqueous visuals").dependOn(&components.step);

    const surfaces = b.addSystemCommand(&.{ "python3", "tests/integration/test_surfaces.py", "--pearl" });
    surfaces.addArtifactArg(app);
    surfaces.addArg("--ctl");
    surfaces.addArtifactArg(ctl);
    surfaces.addArg("--spike");
    surfaces.addArtifactArg(spike);
    if (b.args) |args| surfaces.addArgs(args);
    b.step("test-surfaces", "Verify surfaces, CLI isolation and native blur in private Aqueous").dependOn(&surfaces.step);

    const desktop = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop.py", "--pearl" });
    desktop.addArtifactArg(app);
    desktop.addArg("--ctl");
    desktop.addArtifactArg(ctl);
    if (b.args) |args| desktop.addArgs(args);
    b.step("test-desktop", "Verify T06 live desktop and GIO discovery/activation in private Aqueous").dependOn(&desktop.step);

    const dev_backend = b.option(enum { headless, nested }, "dev-backend", "Development compositor backend") orelse .headless;
    for ([_][]const u8{ "run", "gallery" }) |name| {
        const launch = b.addSystemCommand(&.{ "python3", "scripts/dev-session.py", "--backend", @tagName(dev_backend), "--" });
        launch.addArtifactArg(app);
        if (std.mem.eql(u8, name, "gallery")) launch.addArg("--demo");
        if (b.args) |args| launch.addArgs(args);
        b.step(name, if (std.mem.eql(u8, name, "gallery")) "Launch the demo gallery in private Aqueous" else "Launch Pearl in private Aqueous").dependOn(&launch.step);
    }
}

fn configureApp(b: *std.Build, module: *std.Build.Module, resources: std.Build.LazyPath, test_hooks: bool) void {
    module.addAnonymousImport("pearl_resources", .{ .root_source_file = resources });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
    module.addOptions("build_options", options);
}

fn gtkModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: []const u8) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    const pulse = b.addTranslateC(.{ .root_source_file = b.path("bindings/headers/pulse.h"), .target = target, .optimize = optimize });
    pulse.addIncludePath(b.path("bindings/headers"));
    module.addImport("pulse", pulse.createModule());
    module.linkSystemLibrary("libpulse", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libpulse-mainloop-glib", .{ .use_pkg_config = .force });
    // Interposition requires layer-shell to load before GTK's Wayland dependency.
    module.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("wayland-client", .{});
    for ([_][]const u8{ "gtk4layershell1", "gtk4sessionlock1" }) |name| {
        const generated = b.createModule(.{
            .root_source_file = b.path(b.fmt("bindings/generated/{s}/{s}.zig", .{ name, name })),
            .target = target,
            .optimize = optimize,
        });
        generated.addImport("gtk4", bindings.module("gtk4"));
        var imports = bindings.module("gtk4").import_table.iterator();
        while (imports.next()) |entry| generated.addImport(entry.key_ptr.*, entry.value_ptr.*);
        module.addImport(name, generated);
    }
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "glibunix2", "gobject2", "pango1", "gdkpixbuf2", "gdkwayland4", "cairo1", "giounix2" }) |name|
        module.addImport(name, bindings.module(name));
    return module;
}
