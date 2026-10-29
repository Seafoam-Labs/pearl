const std = @import("std");
const Scanner = @import("wayland").Scanner;
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    defer @import("pearl_ffi").attach(b, b.path("bindings/c"));
    @import("packaging/assistant/build.zig").add(b);
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0"))
        @panic("Pearl requires Zig 0.17.0; see .zigversion");
    const plugin_examples = b.option([]const u8, "plugin-examples", "Prebuilt plugin examples and failure fixtures") orelse ".cache/plugin-examples";
    const wasm_plugins = b.option(bool, "wasm-plugins", "Build the experimental WebAssembly plugin helper") orelse false;
    const community_theme_repository = b.option(bool, "community-theme-repository", "Include the Seafoam GitHub community repository by default") orelse true;
    const portal_variant = b.option(enum { stable, git }, "portal-variant", "Desktop portal and shell backend identity") orelse .stable;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.option(bool, "release", "Strip production artifacts for reproducible safe packages") orelse false;
    if (release and optimize != .safe) @panic("-Drelease requires -Doptimize=safe");
    if (b.option(bool, "codegen", "Build the pinned Ghostty GIR generator") orelse false) {
        if (b.lazyDependency("gobject_codegen", .{ .target = b.graph.host, .optimize = .safe })) |generator| {
            b.installArtifact(generator.artifact("translate-gir"));
            for ([_][]const u8{ "gir-fixes", "binding-overrides", "extensions" }) |directory|
                b.installDirectory(.{ .source_dir = generator.path(directory), .install_dir = .prefix, .install_subdir = b.fmt("share/gir-codegen/{s}", .{directory}) });
        }
        return;
    }
    const bindings = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    const preview_options = b.addOptions();
    preview_options.addOption(bool, "test_hooks", false);
    const preview_module = @import("src/files/preview/build.zig").module(b, bindings, target, optimize, b.path("src/files/preview/root.zig"), preview_options.createModule(), createModule(b, .{ .root_source_file = b.path("src/diagnostics/safe_text.zig"), .target = target, .optimize = optimize }));
    const preview_main = createModule(b, .{ .root_source_file = b.path("src/preview_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    preview_main.addImport("previews", preview_module);
    const preview_helper = b.addExecutable(.{ .name = "pearl-preview-helper", .root_module = preview_main });
    const preview_install = b.addInstallArtifact(preview_helper, .{});
    b.getInstallStep().dependOn(&preview_install.step);
    const chooser_main = createModule(b, .{ .root_source_file = b.path("src/chooser_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    chooser_main.addImport("previews", preview_module);
    chooser_main.addImport("file_chooser", @import("src/files/build.zig").module(b, b.path("src/files/chooser.zig"), chooser_main, bindings, preview_module, portal_variant == .git));
    chooser_main.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    const chooser = b.addExecutable(.{ .name = "pearl-chooser", .root_module = chooser_main });
    const chooser_build = b.step("build-chooser", "Build the shared native file chooser and isolated preview helper");
    chooser_build.dependOn(&b.addInstallArtifact(chooser, .{}).step);
    chooser_build.dependOn(&preview_install.step);
    const capture_main = createModule(b, .{ .root_source_file = b.path("src/capture_picker_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "gdkwayland4" }) |name| capture_main.addImport(name, bindings.module(name));
    const capture_options = b.addOptions();
    capture_options.addOption(bool, "test_hooks", b.option(bool, "capture-picker-test-hooks", "Enable isolated capture picker test controls") orelse false);
    capture_options.addOption(bool, "git_variant", portal_variant == .git);
    capture_main.addOptions("build_options", capture_options);
    const capture_style = b.addWriteFiles();
    const capture_css = capture_style.add("capture-picker.css", @embedFile("resources/portal.css") ++ "\n" ++ @embedFile("resources/capture-picker.css"));
    capture_main.addAnonymousImport("portal_style", .{ .root_source_file = capture_css });
    for ([_][]const u8{ "gtk4", "libcurl", "libarchive", "libpng" }) |name| capture_main.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const capture = b.addExecutable(.{ .name = "pearl-capture-picker", .root_module = capture_main });
    const capture_install = b.addInstallArtifact(capture, .{});
    b.getInstallStep().dependOn(&capture_install.step);
    b.step("build-capture-picker", "Build Pearl's capture source picker").dependOn(&capture_install.step);
    const capture_tests = b.addTest(.{ .root_module = createModule(b, .{ .root_source_file = b.path("src/capture/sources.zig"), .target = target, .optimize = optimize }) });
    b.step("test-capture-picker", "Test capture source parsing and byte preservation").dependOn(&b.addRunArtifact(capture_tests).step);
    const portal_main = createModule(b, .{ .root_source_file = b.path("src/portal_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    portal_main.addImport("previews", @import("src/files/preview/build.zig").module(b, bindings, target, optimize, b.path("src/files/preview/root.zig"), preview_module.import_table.get("build_options").?, portal_main));
    portal_main.addImport("file_chooser", @import("src/files/build.zig").module(b, b.path("src/files/chooser.zig"), portal_main, bindings, portal_main.import_table.get("previews").?, portal_variant == .git));
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "gdkwayland4" }) |name| portal_main.addImport(name, bindings.module(name));
    portal_main.addImport("build_options", preview_module.import_table.get("build_options").?);
    portal_main.addAnonymousImport("portal_style", .{ .root_source_file = b.path("resources/portal.css") });
    for ([_][]const u8{ "libcurl", "libarchive", "libpng" }) |name| portal_main.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    for ([_][]const u8{ "gtk4", "gio-unix-2.0" }) |name| portal_main.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const portal_identity = b.addOptions();
    portal_identity.addOption(bool, "git_variant", portal_variant == .git);
    portal_main.addOptions("portal_identity", portal_identity);
    portal_main.linkSystemLibrary("cups", .{ .use_pkg_config = .no });
    const portal = b.addExecutable(.{ .name = "xdg-desktop-portal-pearl", .root_module = portal_main });
    const portal_build = b.step("build-portal", "Build Pearl's desktop portal backend without changing session routing");
    const portal_install = b.addInstallArtifact(portal, .{});
    b.getInstallStep().dependOn(&portal_install.step);
    portal_build.dependOn(&portal_install.step);
    portal_build.dependOn(&preview_install.step);
    portal_build.dependOn(&capture_install.step);
    const session_fixture_module = createModule(b, .{ .root_source_file = b.path("src/portal/session_test_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    session_fixture_module.addOptions("portal_identity", portal_identity);
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| session_fixture_module.addImport(name, bindings.module(name));
    session_fixture_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .yes });
    session_fixture_module.addCSourceFile(.{ .file = b.path("tests/portal/session_harness.c"), .flags = &.{"-Dmain=pearl_session_harness_main"} });
    const session_fixture = b.addExecutable(.{ .name = "portal-session-harness", .root_module = session_fixture_module });
    const session_fixture_install = b.addInstallArtifact(session_fixture, .{});
    const session_fixture_build = b.step("build-portal-session-test", "Build the private portal session fixture using the Zig session adapter");
    session_fixture_build.dependOn(&session_fixture_install.step);
    const portal_tests = b.step("test-portals", "Run the portal contracts, shared chooser, print worker and staging checks in isolated sessions");
    const settings_module = createModule(b, .{ .root_source_file = b.path("src/portal_settings_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "gdkwayland4" }) |name| settings_module.addImport(name, bindings.module(name));
    settings_module.addOptions("portal_identity", portal_identity);
    settings_module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    const settings_unit = b.addTest(.{ .root_module = settings_module });
    const settings_check = b.addSystemCommand(&.{ "python3", "tests/portal/test_settings.py", "--lifecycle" });
    settings_check.addArtifactArg(settings_unit);
    settings_check.step.dependOn(portal_build);
    b.step("test-portal-settings", "Test packaged Settings through a private public portal and isolated GSettings").dependOn(&settings_check.step);
    portal_tests.dependOn(&settings_check.step);
    for ([_][]const u8{ "tests/portal/test_startup.py", "tests/portal/test_contracts.py", "tests/portal/test_native.py", "tests/portal/test_print_worker.py", "tests/portal/test_package.py", "tests/portal/test_frontend.py", "tests/portal/test_ipp.py" }) |script| {
        const check = b.addSystemCommand(&.{ "python3", script });
        check.step.dependOn(portal_build);
        check.step.dependOn(&session_fixture_install.step);
        check.step.dependOn(chooser_build);
        portal_tests.dependOn(&check.step);
    }

    const state_module = createModule(b, .{ .root_source_file = b.path("src/files/chooser/state.zig"), .target = target, .optimize = optimize, .link_libc = true });
    state_module.addImport("glib2", bindings.module("glib2"));
    state_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
    const state_tests = b.addTest(.{ .root_module = state_module });
    const state_run = b.addRunArtifact(state_tests);
    b.step("test-file-chooser-state", "Test private chooser preference persistence").dependOn(&state_run.step);
    portal_tests.dependOn(&state_run.step);
    const preview_tests = b.addTest(.{ .root_module = createModule(b, .{ .root_source_file = b.path("src/files/preview/core/preview.zig"), .target = target, .optimize = optimize }) });
    b.step("test-file-previews", "Test the shared thumbnail policy and helper protocol").dependOn(&b.addRunArtifact(preview_tests).step);
    b.installDirectory(.{ .source_dir = b.path("src/theme/material"), .install_dir = .prefix, .install_subdir = "share/pearl/material" });
    var themes_tool: *std.Build.Step.Compile = undefined;
    for ([_][]const u8{ "zed", "equibop", "fluxer", "starship", "steam" }) |application| {
        b.installDirectory(.{ .source_dir = b.path(b.fmt("themes/profiles/seafoam.{s}", .{application})), .install_dir = .prefix, .install_subdir = b.fmt("share/pearl/matugen/profiles/seafoam.{s}", .{application}) });
    }
    for ([_]bool{ false, true }) |instrumented| {
        const tm = createModule(b, .{ .root_source_file = b.path("src/themes_main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = release and !instrumented });
        for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| tm.addImport(name, bindings.module(name));
        tm.addAnonymousImport("settings_base_style", .{ .root_source_file = b.path("resources/style.css") });
        tm.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
        for ([_][]const u8{ "gio-2.0", "libcurl", "libarchive", "libpng" }) |name| tm.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
        const options = b.addOptions();
        options.addOption(bool, "test_hooks", instrumented);
        options.addOption(bool, "community_theme_repository", community_theme_repository);
        tm.addOptions("build_options", options);
        const tool = b.addExecutable(.{ .name = if (instrumented) "pearl-themes-test" else "pearl-themes", .root_module = tm });
        if (!instrumented) {
            themes_tool = tool;
            b.installArtifact(tool);
            b.step("build-themes", "Build native theme author and repository tools").dependOn(&b.addInstallArtifact(tool, .{}).step);
        } else {
            const github_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_github.py", "--tool" });
            github_test.addArtifactArg(tool);
            if (community_theme_repository) github_test.addArg("--default-enabled");
            b.step("test-theme-github", "Verify direct GitHub theme discovery and installation in private storage").dependOn(&github_test.step);
            for ([_][]const u8{ "packages", "repository" }) |suite| {
                const test_ = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_packages.py", "--suite", suite, "--tool" });
                test_.addArtifactArg(tool);
                b.step(b.fmt("test-theme-{s}", .{suite}), "Verify native theme packages and community repository operations in private XDG roots").dependOn(&test_.step);
            }
        }
    }
    const assets_module = createModule(b, .{ .root_source_file = b.path("src/theme_assets_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const publishing_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_publishing.py", "--tool" });
    publishing_test.addArtifactArg(themes_tool);
    if (community_theme_repository) publishing_test.addArg("--default-enabled");
    b.step("test-theme-publishing", "Verify native deterministic publication, schema 2 and source migration").dependOn(&publishing_test.step);
    for ([_][]const u8{ "gio-2.0", "libpng" }) |name| assets_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const assets_test = b.addTest(.{ .root_module = assets_module });
    b.step("test-theme-assets", "Validate PNG bounds and native memory resource lifetimes").dependOn(&b.addRunArtifact(assets_test).step);
    const theme_native_module = createModule(b, .{ .root_source_file = b.path("src/theme_native_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| theme_native_module.addImport(name, bindings.module(name));
    for ([_][]const u8{ "gio-2.0", "libcurl", "libarchive", "libpng" }) |name| theme_native_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const native_options = b.addOptions();
    native_options.addOption(bool, "test_hooks", true);
    theme_native_module.addOptions("build_options", native_options);
    theme_native_module.addAnonymousImport("matugen_fixture", .{ .root_source_file = b.path("tests/fixtures/community/render-data/matugen-4.2.json") });
    const theme_native_test = b.addRunArtifact(b.addTest(.{ .root_module = theme_native_module }));
    theme_native_test.setCwd(b.path("."));
    theme_native_test.setEnvironmentVariable("XDG_CACHE_HOME", b.pathJoin(&.{ b.root.toString(b.allocator) catch @panic("OOM"), ".cache/profile-tests" }));
    const matugen_tests = b.step("test-matugen", "Test native application rendering, snapshots and ownership recovery");
    matugen_tests.dependOn(&theme_native_test.step);
    const material_tests = b.step("test-base-material-profiles", "Verify built-in Material palettes, target coverage and ownership");
    material_tests.dependOn(matugen_tests);
    const material_module = createModule(b, .{ .root_source_file = b.path("src/material_test_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| material_module.addImport(name, bindings.module(name));
    for ([_][]const u8{ "gio-2.0", "libcurl", "libarchive", "libpng" }) |name| material_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    material_module.addOptions("build_options", native_options);
    const material_driver = b.addExecutable(.{ .name = "pearl-material-test", .root_module = material_module });
    const material_check = b.addSystemCommand(&.{ "python3", "tests/integration/test_base_material_profiles.py", "--driver" });
    material_check.addArtifactArg(material_driver);
    material_check.addArg("--tool");
    material_check.addArtifactArg(themes_tool);
    material_tests.dependOn(&material_check.step);
    const profile_formats = b.addSystemCommand(&.{ "python3", "tests/integration/test_profile_formats.py", "--tool" });
    profile_formats.addArtifactArg(themes_tool);
    matugen_tests.dependOn(&profile_formats.step);
    b.step("test-theme-discovery", "Test event-driven local theme discovery").dependOn(&theme_native_test.step);
    const pam = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("bindings/headers/pam.h"), .target = target, .optimize = optimize });
    pam.addIncludePath(b.path("bindings/headers"));
    const pam_module = pam.mod;
    const pam_export = b.addInstallFile(pam.output_file, "share/pearl/bindings/pam.zig");
    b.step("generate-pam", "Export the pinned PAM ABI").dependOn(&pam_export.step);
    const pulse = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{ .c_source_file = b.path("bindings/headers/pulse.h"), .target = target, .optimize = optimize });
    pulse.addIncludePath(b.path("bindings/headers"));
    const pulse_module = pulse.mod;
    const pulse_export = b.addInstallFile(pulse.output_file, "share/pearl/bindings/pulse.zig");
    b.step("generate-pulse", "Export the translated pinned libpulse ABI").dependOn(&pulse_export.step);
    const scanner = Scanner.create(b, .{ .wayland_xml = b.path("bindings/protocols/wayland.xml"), .wayland_protocols = b.path("bindings/protocols") });
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-background-effect-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-workspace-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-window-info-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-foreign-toplevel-list-v1.xml"));
    scanner.generate("aqueous_window_info_manager_v1", 3);
    scanner.generate("aqueous_shell_manager_v1", 2);
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-output-warming-v1.xml"));
    scanner.generate("aqueous_output_warming_manager_v1", 1);
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-input-activity-v1.xml"));
    scanner.generate("aqueous_input_activity_manager_v1", 1);
    scanner.addCustomProtocol(b.path("bindings/protocols/wlr-output-management-unstable-v1.xml"));
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-idle-notify-v1.xml"));
    scanner.generate("ext_idle_notifier_v1", 1);
    scanner.addCustomProtocol(b.path("bindings/protocols/wlr-output-power-management-unstable-v1.xml"));
    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-data-control-v1.xml"));
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.addCustomProtocol(b.path("bindings/protocols/wlr-screencopy-unstable-v1.xml"));
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-image-copy-capture-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/ext-image-capture-source-v1.xml"));
    scanner.addCustomProtocol(b.path("bindings/protocols/aqueous-capture-color-v1.xml"));
    scanner.generate("ext_image_copy_capture_manager_v1", 1);
    scanner.generate("ext_output_image_capture_source_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_image_capture_source_manager_v1", 1);
    scanner.generate("aqueous_capture_color_manager_v1", 1);
    scanner.generate("ext_foreign_toplevel_list_v1", 1);

    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 9);
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_output", 4);
    scanner.generate("ext_background_effect_manager_v1", 1);
    const native = createModule(b, .{ .root_source_file = scanner.result, .target = target, .optimize = optimize });
    capture_main.addImport("wayland", native);
    capture_main.linkSystemLibrary("wayland-client", .{});
    portal_main.addImport("wayland", native);
    portal_main.linkSystemLibrary("wayland-client", .{});
    const native_export = b.addInstallFile(scanner.result, "share/pearl/bindings/wayland.zig");
    b.step("generate-wayland", "Export generated native protocol bindings for review and reproducibility checks").dependOn(&native_export.step);

    const system_versions = b.addSystemCommand(&.{
        "pkg-config",       "--print-errors",                 "--exists",
        "gtk4 >= 4.22.5",   "glib-2.0 >= 2.88.3",             "gtk4-layer-shell-0 >= 1.3.0",
        "libpulse >= 17.0", "libpulse-mainloop-glib >= 17.0", "polkit-agent-1 >= 127",
        "pam >= 1.7.2",
    });
    const resource_command = b.addSystemCommand(&.{"glib-compile-resources"});
    resource_command.addFileArg(b.path("resources/pearl.gresource.xml"));
    resource_command.addArg("--sourcedir");
    resource_command.addDirectoryArg(b.path("resources"));
    resource_command.addArg("--target");
    const resources = resource_command.addOutputFileArg("pearl.gresource");
    resource_command.addArg("--dependency-file");
    _ = resource_command.addDepFileOutputArg("pearl.gresource.d");

    const greeter_unit = b.addTest(.{ .root_module = createModule(b, .{ .root_source_file = b.path("src/greeter_tests.zig"), .target = target, .optimize = optimize }) });
    const greeter_unit_step = b.step("test-greeter-unit", "Test greetd framing, authority state, desktop parsing and monitor identity");
    greeter_unit_step.dependOn(&b.addRunArtifact(greeter_unit).step);
    const output_unit_module = greeterModule(b, bindings, target, optimize, "src/greeter_output_tests.zig", true);
    output_unit_module.addImport("wayland", native);
    output_unit_module.addImport("gdkwayland4", bindings.module("gdkwayland4"));
    output_unit_module.linkSystemLibrary("wayland-client", .{});
    const output_unit = b.addTest(.{ .root_module = output_unit_module });
    greeter_unit_step.dependOn(&b.addRunArtifact(output_unit).step);
    const greeter_versions = b.addSystemCommand(&.{ "pkg-config", "--exists", "gtk4 >= 4.22.5", "glib-2.0 >= 2.88.3", "gtk4-layer-shell-0 >= 1.3.0" });
    const greeter_build = b.step("build-greeter", "Build optional greeter artifacts without installing or activating a display manager");
    var greeter_test_executable: *std.Build.Step.Compile = undefined;
    var greeter_sync_test_executable: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        for ([_][]const u8{ "greeter", "greeter_session", "greeter_host", "greeter_sync" }) |component| {
            const gm = greeterModule(b, bindings, target, optimize, b.fmt("src/{s}_main.zig", .{component}), instrumented);
            gm.addImport("wayland", native);
            gm.addImport("gdkwayland4", bindings.module("gdkwayland4"));
            gm.addAnonymousImport("pearl_resources", .{ .root_source_file = resources });
            gm.linkSystemLibrary("wayland-client", .{});
            gm.strip = release and !instrumented;
            const name = std.mem.replaceOwned(u8, b.allocator, component, "_", "-") catch @panic("OOM");
            const exe = b.addExecutable(.{ .name = b.fmt("pearl-{s}{s}", .{ name, if (instrumented) "-test" else "" }), .root_module = gm });
            const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = if (instrumented) "test" else "greeter/bin" } } });
            exe.step.dependOn(&greeter_versions.step);
            greeter_build.dependOn(&install.step);
            if (instrumented and std.mem.eql(u8, component, "greeter")) {
                greeter_test_executable = exe;
                for ([_][]const u8{ "ipc", "ui", "login", "catalog", "services", "soak", "outputs" }) |suite| {
                    const check = b.addSystemCommand(&.{ "python3", b.fmt("tests/integration/test_greeter_{s}.py", .{suite}), "--greeter" });
                    check.addArtifactArg(exe);
                    check.addPassthruArgs();
                    b.step(b.fmt("test-greeter-{s}", .{suite}), b.fmt("Private greeter {s} validation", .{suite})).dependOn(&check.step);
                }
            }
            if (instrumented and std.mem.eql(u8, component, "greeter_session")) {
                const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_greeter_session.py", "--greeter" });
                check.addArtifactArg(greeter_test_executable);
                check.addArg("--launcher");
                check.addArtifactArg(exe);
                b.step("test-greeter-session", "Verify authenticated session argv, identity and revalidation with harmless commands").dependOn(&check.step);
            }
            if (instrumented and std.mem.eql(u8, component, "greeter_host")) {
                const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_greeter_host.py", "--host" });
                check.addArtifactArg(exe);
                b.step("test-greeter-host", "Verify owned process teardown with private fixtures").dependOn(&check.step);
            }
            if (instrumented and std.mem.eql(u8, component, "greeter_sync")) {
                greeter_sync_test_executable = exe;
                const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_greeter_sync.py", "--helper" });
                check.addArtifactArg(exe);
                b.step("test-greeter-sync", "Verify native appearance sync with private configuration").dependOn(&check.step);
            }
        }
    }

    const module = gtkModule(b, bindings, target, optimize, "src/main.zig", pulse_module);
    configureApp(b, module, resources, false, wasm_plugins, community_theme_repository, true, portal_variant == .git);
    module.addImport("wayland", native);
    module.strip = release;
    const app = b.addExecutable(.{ .name = "pearl", .root_module = module });
    app.step.dependOn(&system_versions.step);
    const shell_install = b.addInstallArtifact(app, .{});
    b.getInstallStep().dependOn(&shell_install.step);
    b.step("build-shell", "Stage the production shell without launching it or building bundled applications").dependOn(&shell_install.step);

    const agent_tests = createModule(b, .{ .root_source_file = b.path("src/agent_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "gobject2" }) |name| agent_tests.addImport(name, bindings.module(name));
    for ([_][]const u8{ "gio-2.0", "libcurl", "libxml-2.0", "libsecret-1" }) |name| agent_tests.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    b.step("test-agent", "Test assistant policy, tools, providers and native extraction").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = agent_tests })).step);
    const benchmark_module = createModule(b, .{ .root_source_file = b.path("src/benchmark_check.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "gobject2" }) |name| benchmark_module.addImport(name, bindings.module(name));
    for ([_][]const u8{ "gio-2.0", "libcurl", "libxml-2.0", "libsecret-1" }) |name| benchmark_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const benchmark_check = b.addExecutable(.{ .name = "pearl-benchmark-check", .root_module = benchmark_module });
    b.step("build-benchmark-check", "Build the headless local model comparison driver").dependOn(&b.addInstallArtifact(benchmark_check, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    const benchmark_tests = b.addSystemCommand(&.{ "python3", "tests/integration/test_agent_benchmark.py", "--driver" });
    benchmark_tests.addArtifactArg(benchmark_check);
    benchmark_tests.addPassthruArgs();
    b.step("test-agent-benchmark", "Verify local benchmark lifecycle, failures and persistence").dependOn(&benchmark_tests.step);
    var agent_build: *std.Build.Step = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        const agent_module = createModule(b, .{ .root_source_file = b.path("src/agent_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        for ([_][]const u8{ "gtk4", "gdk4", "gio2", "giounix2", "glib2", "gobject2" }) |name| agent_module.addImport(name, bindings.module(name));
        for ([_][]const u8{ "gtk4", "libcurl", "libxml-2.0", "libsecret-1" }) |name| agent_module.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
        const agent_options = b.addOptions();
        agent_options.addOption(bool, "git_variant", portal_variant == .git);
        agent_options.addOption(bool, "test_hooks", instrumented);
        agent_module.addOptions("build_options", agent_options);
        agent_module.addAnonymousImport("agent_style", .{ .root_source_file = b.path("resources/agent.css") });
        const agent_exe = b.addExecutable(.{ .name = if (instrumented) "pearl-agent-test" else "pearl-agent", .root_module = agent_module });
        const agent_install = b.addInstallArtifact(agent_exe, .{ .dest_dir = .{ .override = .{ .custom = if (instrumented) "test" else "bin" } } });
        const agent_step = b.step(if (instrumented) "build-agent-test" else "build-agent", "Build the opt-in native launcher assistant");
        agent_step.dependOn(&agent_install.step);
        if (!instrumented) {
            agent_build = agent_step;
            const desktop = b.addInstallFile(b.path("packaging/applications/org.aqueous.Pearl.Agent.desktop"), "share/applications/org.aqueous.Pearl.Agent.desktop");
            agent_step.dependOn(&desktop.step);
            b.getInstallStep().dependOn(&desktop.step);
        }
        if (!instrumented) b.getInstallStep().dependOn(&agent_install.step);
    }

    var settings_app: *std.Build.Step.Compile = undefined;
    var settings_test_app: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        // Ordinary application: deliberately excludes layer-shell, PulseAudio,
        // polkit/PAM and shell service initialization dependencies.
        const sm = createModule(b, .{ .root_source_file = b.path("src/settings_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "glibunix2", "gobject2", "gdkwayland4", "cairo1", "graphene1", "gdkpixbuf2", "giounix2" }) |name| sm.addImport(name, bindings.module(name));
        sm.addImport("wayland", native);
        sm.addAnonymousImport("settings_base_style", .{ .root_source_file = b.path("resources/style.css") });
        sm.addAnonymousImport("settings_colors", .{ .root_source_file = b.path("resources/settings.css") });
        sm.addAnonymousImport("settings_layout", .{ .root_source_file = b.path("resources/settings-layout.css") });
        sm.addAnonymousImport("settings_native", .{ .root_source_file = b.path("resources/gtk-theme.css") });

        sm.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
        for ([_][]const u8{ "libxml-2.0", "libsecret-1" }) |name| sm.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
        sm.linkSystemLibrary("wayland-client", .{});
        configureApp(b, sm, resources, instrumented, wasm_plugins, community_theme_repository, true, portal_variant == .git);
        sm.strip = release and !instrumented;
        const exe = b.addExecutable(.{ .name = if (instrumented) "pearl-settings-test" else "pearl-settings", .root_module = sm });
        const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = if (instrumented) "test" else "bin" } } });
        const settings_build = b.step(if (instrumented) "build-settings-test" else "build-settings", "Stage standalone Settings application");
        settings_build.dependOn(&install.step);
        if (instrumented) settings_test_app = exe else {
            settings_app = exe;
            b.getInstallStep().dependOn(&install.step);
            for ([_][]const u8{ "applications/org.aqueous.Pearl.Settings.desktop", "icons/hicolor/scalable/apps/org.aqueous.Pearl.Settings.svg", "metainfo/org.aqueous.Pearl.Settings.metainfo.xml" }) |asset| {
                const resource_install = b.addInstallFile(b.path(b.fmt("packaging/{s}", .{asset})), b.fmt("share/{s}", .{asset}));
                b.getInstallStep().dependOn(&resource_install.step);
                settings_build.dependOn(&resource_install.step);
            }
        }
    }

    var test_locker: *std.Build.Step.Compile = undefined;
    var production_locker: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        const lock_module = gtkModule(b, bindings, target, optimize, "src/lock_main.zig", pulse_module);
        configureApp(b, lock_module, resources, instrumented, false, community_theme_repository, false, portal_variant == .git);

        lock_module.addImport("wayland", native);
        lock_module.addAnonymousImport("lock_style", .{ .root_source_file = b.path("resources/style.css") });
        lock_module.addImport("pam", pam_module);
        lock_module.linkSystemLibrary("pam", .{});
        lock_module.strip = release and !instrumented;
        const locker = b.addExecutable(.{ .name = if (instrumented) "pearl-lock-test" else "pearl-lock", .root_module = lock_module });
        if (instrumented) test_locker = locker else production_locker = locker;
        if (instrumented) {
            b.step("build-lock-test", "Build isolated PAM test locker (never installed)").dependOn(&b.addInstallArtifact(locker, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
        } else {
            const install_locker = b.addInstallArtifact(locker, .{});
            b.getInstallStep().dependOn(&install_locker.step);
            b.step("build-locker", "Stage the production locker in zig-out for independent reproduction").dependOn(&install_locker.step);
        }
    }

    const spike_module = gtkModule(b, bindings, target, optimize, "spikes/t00/main.zig", pulse_module);
    // The spike root lives outside src/, so it reaches the handler by module name.
    spike_module.addImport("logging", createModule(b, .{ .root_source_file = b.path("src/core/logging.zig"), .target = target, .optimize = optimize }));
    const spike = b.addExecutable(.{ .name = "pearl-t00", .root_module = spike_module });
    spike.step.dependOn(&system_versions.step);
    b.installArtifact(spike);
    const bindings_test = b.addTest(.{ .root_module = spike_module });
    bindings_test.step.dependOn(&system_versions.step);
    b.step("test-bindings", "Test generated binding types and API coverage").dependOn(&b.addRunArtifact(bindings_test).step);

    const pure_module = createModule(b, .{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize });
    pure_module.addAnonymousImport("aqueous_presentation_fixture", .{ .root_source_file = b.path("tests/fixtures/aqueous-master/snapshot.json") });
    pure_module.addImport("aqueous_fixtures", createModule(b, .{ .root_source_file = b.path("tests/fixtures/aqueous/fixtures.zig"), .target = target, .optimize = optimize }));
    const pure = b.addTest(.{ .root_module = pure_module });
    const filter_module = createModule(b, .{ .root_source_file = b.path("src/notification_filter_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    filter_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
    const filter_tests = b.addRunArtifact(b.addTest(.{ .root_module = filter_module }));
    b.step("test-notification-filters", "Verify notification Unicode matching and policy lifetime").dependOn(&filter_tests.step);

    const night_clock_module = createModule(b, .{ .root_source_file = b.path("src/night_light_clock_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    night_clock_module.addImport("glib2", bindings.module("glib2"));
    night_clock_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
    const night_clock = b.addRunArtifact(b.addTest(.{ .root_module = night_clock_module }));
    const bar_clock_module = createModule(b, .{ .root_source_file = b.path("src/bar_clock_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bar_clock_module.addImport("glib2", bindings.module("glib2"));
    bar_clock_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .yes });
    const bar_clock = b.addRunArtifact(b.addTest(.{ .root_module = bar_clock_module }));
    bar_clock.setEnvironmentVariable("LC_ALL", "C");
    b.step("test-bar-clock", "Verify time-zone clocks, DST, formatting and zone discovery").dependOn(&bar_clock.step);
    b.step("test-night-light-clock", "Verify Night Light schedules across timezone and DST transitions").dependOn(&night_clock.step);
    const test_step = b.step("test", "Run model and Unicode policy tests without GTK or a compositor");
    test_step.dependOn(&b.addRunArtifact(pure).step);
    test_step.dependOn(&filter_tests.step);
    const i18n_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file", "translations/build.zig", "test", "check-templates" });
    i18n_tests.setCwd(b.path("."));
    i18n_tests.has_side_effects = true;
    b.step("test-i18n", "Check translation infrastructure and generated catalog inventory").dependOn(&i18n_tests.step);
    test_step.dependOn(&i18n_tests.step);

    b.step("test-plugin-unit", "Verify plugin documents, permissions, framing and route isolation").dependOn(&b.addRunArtifact(pure).step);
    var plugin_test_helper: ?*std.Build.Step.InstallArtifact = null;
    if (wasm_plugins) {
        const prefix = b.option([]const u8, "wasmtime-prefix", "Verified Wasmtime 48.0.2 C API prefix") orelse @panic("-Dwasm-plugins=true requires -Dwasmtime-prefix");
        const translated = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{ .c_source_file = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include/wasmtime.h" }) }, .target = target, .optimize = optimize });
        translated.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        const host = createModule(b, .{ .root_source_file = b.path("src/plugin_host_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        host.addImport("wasmtime", translated.mod);
        host.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib/libwasmtime.a" }) });
        host.linkSystemLibrary("m", .{});
        host.linkSystemLibrary("gcc_s", .{});
        host.linkSystemLibrary("dl", .{});
        host.linkSystemLibrary("pthread", .{});
        const exe = b.addExecutable(.{ .name = "pearl-plugin-host", .root_module = host });
        const helper_install = b.addInstallArtifact(exe, .{});
        plugin_test_helper = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "test" } } });
        const runtime_license = b.addInstallFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "LICENSE" }) }, "share/licenses/pearl/Wasmtime-LICENSE");
        const helper_step = b.step("build-plugin-host", "Build the isolated plugin helper and stage its pinned runtime");
        for ([_]*std.Build.Step{ &helper_install.step, &runtime_license.step }) |step| {
            helper_step.dependOn(step);
            b.getInstallStep().dependOn(step);
        }
        const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugin_host.py", "--helper" });
        check.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "pearl-plugin-host" } });
        check.addArgs(&.{ "--examples", plugin_examples });
        check.step.dependOn(helper_step);
        b.step("test-plugin-host", "Exercise three guest languages, sprites and helper failures").dependOn(&check.step);
    }

    const ctl_module = createModule(b, .{ .root_source_file = b.path("src/pearlctl.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| ctl_module.addImport(name, bindings.module(name));
    ctl_module.strip = release;
    const ctl = b.addExecutable(.{ .name = "pearlctl", .root_module = ctl_module });
    b.installArtifact(ctl);
    b.step("build-ctl", "Stage the Pearl command-line client").dependOn(&b.addInstallArtifact(ctl, .{}).step);

    // Root helper for scheduling profiles; packaging installs it in lib/pearl.
    const scheduling_helper_module = createModule(b, .{ .root_source_file = b.path("src/scheduling_helper_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| scheduling_helper_module.addImport(name, bindings.module(name));
    scheduling_helper_module.strip = release;
    b.installArtifact(b.addExecutable(.{ .name = "pearl-scheduling-helper", .root_module = scheduling_helper_module }));

    if (wasm_plugins) {
        const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugins.py", "--pearl" });
        check.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "pearl" } });
        check.addArg("--ctl");
        check.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "pearlctl" } });
        check.addArg("--settings");
        check.addArtifactArg(settings_test_app);
        check.addArgs(&.{ "--examples", plugin_examples });
        check.addPassthruArgs();
        check.step.dependOn(b.getInstallStep());
        b.step("test-plugins", "Verify plugins and main Settings in private Aqueous").dependOn(&check.step);
    }
    if (b.option(bool, "qt-themes", "Build isolated Qt 5/6 Darkly dependency probes") orelse false) {
        for ([_][]const u8{ "5", "6" }) |version| {
            const probe = b.addSystemCommand(&.{"python3"});
            probe.addFileArg(b.path("scripts/build-qt-probe.py"));
            probe.addArgs(&.{ "--qt", version, "--source" });
            probe.addFileArg(b.path("src/qt_probe.cpp"));
            probe.addArg("--output");
            const output = probe.addOutputFileArg(b.fmt("pearl-qt{s}-probe", .{version}));
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .bin, b.fmt("pearl-qt{s}-probe", .{version})).step);
        }
    }

    const material_session = b.addSystemCommand(&.{ "python3", "tests/integration/test_base_material_session.py", "--pearl" });
    material_session.addArtifactArg(app);
    material_session.addArg("--settings");
    material_session.addArtifactArg(settings_test_app);
    material_session.addPassthruArgs();
    b.step("test-base-material-session", "Verify Material defaults UI and real GTK consumers in private Aqueous").dependOn(&material_session.step);

    const custom_themes = b.addSystemCommand(&.{ "python3", "tests/integration/test_custom_themes.py", "--pearl" });
    custom_themes.addArtifactArg(app);
    custom_themes.addArg("--settings");
    custom_themes.addArtifactArg(settings_test_app);
    custom_themes.addPassthruArgs();
    b.step("test-custom-themes", "Verify community themes and recovery in a private desktop session").dependOn(&custom_themes.step);
    const theme_completion = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_completion.py", "--pearl" });
    theme_completion.addArtifactArg(app);
    theme_completion.addArg("--settings");
    theme_completion.addArtifactArg(settings_test_app);
    theme_completion.addArg("--themes");
    theme_completion.addArtifactArg(themes_tool);
    theme_completion.addPassthruArgs();
    b.step("test-theme-completion", "Verify image transfer, discovery and committed application profiles in a private session").dependOn(&theme_completion.step);
    const wallpaper_profiles = b.addSystemCommand(&.{ "python3", "tests/integration/test_wallpaper_profiles.py", "--pearl" });
    wallpaper_profiles.addArtifactArg(app);
    wallpaper_profiles.addArg("--ctl");
    wallpaper_profiles.addArtifactArg(ctl);
    wallpaper_profiles.addArg("--spike");
    wallpaper_profiles.addArtifactArg(spike);
    wallpaper_profiles.addPassthruArgs();
    b.step("test-wallpaper-profiles", "Verify live wallpaper colors, committed profiles and cancellation in private XDG roots").dependOn(&wallpaper_profiles.step);

    const settings_window_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_app.py", "--settings" });
    settings_window_test.addArtifactArg(settings_test_app);
    settings_window_test.addArg("--production");
    settings_window_test.addArtifactArg(settings_app);
    settings_window_test.addArg("--pearl");
    settings_window_test.addArtifactArg(app);
    settings_window_test.addArg("--ctl");
    settings_window_test.addArtifactArg(ctl);
    settings_window_test.addPassthruArgs();
    b.step("test-settings-app", "Report standalone window, activation and presentation diagnostics (non-blocking)").dependOn(&settings_window_test.step);

    const settings_appearance = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_appearance.py", "--settings" });
    settings_appearance.addArtifactArg(settings_test_app);
    settings_appearance.addArg("--pearl");
    settings_appearance.addArtifactArg(app);
    settings_appearance.addArg("--ctl");
    settings_appearance.addArtifactArg(ctl);
    settings_appearance.addArg("--spike");
    settings_appearance.addArtifactArg(spike);
    settings_appearance.addPassthruArgs();
    b.step("test-settings-appearance", "Verify real standalone Appearance editing, shared drafts and save lifecycle").dependOn(&settings_appearance.step);

    const appearance_redesign = b.addSystemCommand(&.{ "python3", "tests/integration/test_appearance_redesign.py", "--settings" });
    appearance_redesign.addArtifactArg(settings_test_app);
    appearance_redesign.addArg("--pearl");
    appearance_redesign.addArtifactArg(app);
    appearance_redesign.addPassthruArgs();
    b.step("test-appearance-redesign", "Verify Appearance disclosures, preview isolation and responsive native controls").dependOn(&appearance_redesign.step);

    const border_theme = b.addSystemCommand(&.{ "python3", "tests/integration/test_border_theme.py", "--settings" });
    border_theme.addArtifactArg(settings_test_app);
    border_theme.addArg("--pearl");
    border_theme.addArtifactArg(app);
    border_theme.addPassthruArgs();
    b.step("test-border-theme", "Verify matugen border colors, draft deferral and generator failure").dependOn(&border_theme.step);

    const settings_services = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_services.py", "--settings" });
    settings_services.addArtifactArg(settings_test_app);
    settings_services.addArg("--pearl");
    settings_services.addArtifactArg(app);
    settings_services.addArg("--ctl");
    settings_services.addArtifactArg(ctl);
    settings_services.addArg("--spike");
    settings_services.addArtifactArg(spike);
    settings_services.addPassthruArgs();
    b.step("test-settings-services", "Verify standalone live pages and complete Aqueous editor boundary").dependOn(&settings_services.step);

    const settings_displays = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_displays.py", "--settings" });
    settings_displays.addArtifactArg(settings_test_app);
    settings_displays.addArg("--pearl");
    settings_displays.addArtifactArg(app);
    settings_displays.addArg("--ctl");
    settings_displays.addArtifactArg(ctl);
    settings_displays.addPassthruArgs();
    b.step("test-settings-displays", "Verify selected displays, positioning, HDR controls and native previews").dependOn(&settings_displays.step);

    const settings_boundary = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_boundary.py", "--pearl" });
    settings_boundary.addArtifactArg(app);
    settings_boundary.addArg("--ctl");
    settings_boundary.addArtifactArg(ctl);
    settings_boundary.addPassthruArgs();
    b.step("test-settings-boundary", "Verify Settings frontend handshake and isolation in private sessions").dependOn(&settings_boundary.step);

    const release_tools = b.addSystemCommand(&.{ "python3", "tests/test_release_tools.py" });
    b.step("test-release-tools", "Verify release gates fail closed and source archives are deterministic").dependOn(&release_tools.step);

    const release_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_release.py", "--pearl" });
    release_test.step.dependOn(agent_build);
    release_test.addArtifactArg(app);
    release_test.addArg("--themes");
    release_test.addArtifactArg(themes_tool);
    release_test.addArg("--ctl");
    release_test.addArtifactArg(ctl);
    release_test.addArg("--settings");
    release_test.addArtifactArg(settings_app);
    release_test.addArg("--locker");
    release_test.addArtifactArg(production_locker);
    release_test.addPassthruArgs();
    b.step("test-release", "Verify staged production installation and reversible DMS migration").dependOn(&release_test.step);

    const performance_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_release_performance.py", "--pearl" });
    performance_test.addArtifactArg(app);
    performance_test.addArg("--ctl");
    performance_test.addArtifactArg(ctl);
    performance_test.addPassthruArgs();
    b.step("test-release-performance", "Measure production idle cost and 1,000 popup cycles in private Aqueous").dependOn(&performance_test.step);

    const adapter_module = createModule(b, .{ .root_source_file = b.path("src/adapter_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "glibunix2", "gobject2", "gdkpixbuf2" }) |name| adapter_module.addImport(name, bindings.module(name));
    const adapter_probe = b.addExecutable(.{ .name = "pearl-adapter-probe", .root_module = adapter_module });
    const qt_test_module = createModule(b, .{ .root_source_file = b.path("src/qt_theme_test_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "gobject2" }) |name| qt_test_module.addImport(name, bindings.module(name));
    const qt_driver = b.addExecutable(.{ .name = "pearl-qt-test", .root_module = qt_test_module });
    const qt_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_qt_theme.py", "--driver" });
    qt_test.addArtifactArg(qt_driver);
    qt_test.step.dependOn(b.getInstallStep());
    qt_test.addPassthruArgs();
    b.step("test-qt-theme", "Verify Qt palettes, Darkly, file ownership and restoration in private configuration").dependOn(&qt_test.step);
    b.step("test-qt-theme-unit", "Verify Qt policy, palette and lossless INI unit contracts").dependOn(&b.addRunArtifact(pure).step);
    b.step("adapter-probe", "Build the private IPC test driver").dependOn(&b.addInstallArtifact(adapter_probe, .{}).step);

    const adapter_unit = b.addTest(.{ .root_module = adapter_module });
    b.step("test-adapter-unit", "Check endpoint and image bounds using generated GIO bindings").dependOn(&b.addRunArtifact(adapter_unit).step);
    const adapter_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_adapter.py", "--probe" });
    adapter_test.addArtifactArg(adapter_probe);
    adapter_test.addPassthruArgs();
    b.step("test-adapter", "Exercise IPC recovery, policy and commands on private sockets and nested Aqueous").dependOn(&adapter_test.step);

    const test_module = gtkModule(b, bindings, target, optimize, "src/main.zig", pulse_module);
    configureApp(b, test_module, resources, true, wasm_plugins, community_theme_repository, true, portal_variant == .git);
    test_module.addImport("wayland", native);
    const integration_app = b.addExecutable(.{ .name = "pearl-integration", .root_module = test_module });
    const night_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_night_light.py", "--pearl" });
    night_test.addArtifactArg(integration_app);
    night_test.addArg("--ctl");
    night_test.addArtifactArg(ctl);
    night_test.addArg("--settings");
    night_test.addArtifactArg(settings_test_app);
    night_test.addArg("--spike");
    night_test.addArtifactArg(spike);
    night_test.addPassthruArgs();
    const night_tests = b.step("test-night-light", "Verify Night Light policy, unavailable output gating and shared controls");
    night_tests.dependOn(&night_test.step);
    night_tests.dependOn(&night_clock.step);
    night_tests.dependOn(&b.addRunArtifact(pure).step);
    integration_app.step.dependOn(&system_versions.step);
    const integration_build = b.step("build-integration", "Stage the private instrumented shell (never packaged)");
    integration_build.dependOn(&b.addInstallArtifact(integration_app, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    if (plugin_test_helper) |helper| integration_build.dependOn(&helper.step);
    const discovery_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugin_discovery.py" });
    discovery_test.step.dependOn(integration_build);
    discovery_test.addArg("--settings");
    discovery_test.addArtifactArg(settings_test_app);
    discovery_test.addArg("--ctl");
    discovery_test.addArtifactArg(ctl);
    if (!wasm_plugins) discovery_test.addArg("--runtime-disabled");
    discovery_test.addPassthruArgs();
    b.step("test-plugin-discovery", "Verify live plugin installation, replacement and removal in a private session").dependOn(&discovery_test.step);
    const plugins_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugins_layout.py" });
    plugins_layout.step.dependOn(integration_build);
    plugins_layout.addArg("--pearl");
    plugins_layout.addFileArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "test/pearl-integration" } });
    plugins_layout.addArgs(&.{ "--examples", plugin_examples });
    for ([_][]const u8{ "--settings", "--ctl" }, [_]*std.Build.Step.Compile{ settings_test_app, ctl }) |flag, binary| {
        plugins_layout.addArg(flag);
        plugins_layout.addArtifactArg(binary);
    }
    plugins_layout.addPassthruArgs();
    b.step("test-plugins-layout", "Verify native plugin reviews, pagination and responsive layout in a private session").dependOn(&plugins_layout.step);
    var plugin_activity_test: ?*std.Build.Step.Run = null;
    if (wasm_plugins) {
        const activity = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugin_activity.py" });
        plugin_activity_test = activity;
        activity.step.dependOn(integration_build);
        activity.addArg("--ctl");
        activity.addArtifactArg(ctl);
        activity.addPassthruArgs();
        b.step("test-plugin-activity", "Verify compositor input, cat poses and privacy on private Aqueous").dependOn(&activity.step);
    }
    const greeter_sync_ui = b.addSystemCommand(&.{ "python3", "tests/integration/test_greeter_sync_ui.py", "--settings" });
    greeter_sync_ui.addArtifactArg(settings_test_app);
    greeter_sync_ui.addArg("--pearl");
    greeter_sync_ui.addArtifactArg(integration_app);
    greeter_sync_ui.addArg("--ctl");
    greeter_sync_ui.addArtifactArg(ctl);
    greeter_sync_ui.addArg("--helper");
    greeter_sync_ui.addArtifactArg(greeter_sync_test_executable);
    greeter_sync_ui.addPassthruArgs();
    b.step("test-greeter-sync-ui", "Verify native appearance sync from Settings and the flyout").dependOn(&greeter_sync_ui.step);
    const filter_settings = b.addSystemCommand(&.{ "python3", "tests/integration/test_notification_filters.py", "--settings" });
    filter_settings.addArtifactArg(settings_test_app);
    filter_settings.addArg("--pearl");
    filter_settings.addArtifactArg(integration_app);
    filter_settings.addArg("--ctl");
    filter_settings.addArtifactArg(ctl);
    filter_settings.addPassthruArgs();
    b.step("test-notification-filter-settings", "Verify native filter drafts, matching and notification protocol in a private session").dependOn(&filter_settings.step);
    const window_rules = b.addSystemCommand(&.{ "python3", "tests/integration/test_window_rules.py", "--settings" });
    window_rules.addArtifactArg(settings_test_app);
    window_rules.addArg("--pearl");
    window_rules.addArtifactArg(integration_app);
    window_rules.addArg("--ctl");
    window_rules.addArtifactArg(ctl);
    window_rules.addPassthruArgs();
    b.step("test-window-rule-settings", "Verify native window rules, draft preservation and ordering in a private session").dependOn(&window_rules.step);
    const aqueous_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_aqueous_layout.py", "--settings" });
    aqueous_layout.addArtifactArg(settings_test_app);
    aqueous_layout.addArg("--pearl");
    aqueous_layout.addArtifactArg(integration_app);
    aqueous_layout.addPassthruArgs();
    b.step("test-aqueous-layout", "Verify Aqueous cards, search, shared review and responsive layout in a private session").dependOn(&aqueous_layout.step);
    const settings_devices = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_devices.py", "--settings" });
    settings_devices.addArtifactArg(settings_test_app);
    settings_devices.addArg("--pearl");
    settings_devices.addArtifactArg(integration_app);
    settings_devices.addArg("--ctl");
    settings_devices.addArtifactArg(ctl);
    settings_devices.addArg("--spike");
    settings_devices.addArtifactArg(spike);
    settings_devices.addPassthruArgs();
    b.step("test-settings-devices", "Verify standalone audio, power, notifications and media against private services").dependOn(&settings_devices.step);

    const settings_acceptance = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_acceptance.py" });
    for ([_][]const u8{ "--pearl", "--production-pearl", "--ctl", "--settings", "--production-settings", "--spike", "--locker" }, [_]*std.Build.Step.Compile{ integration_app, app, ctl, settings_test_app, settings_app, spike, production_locker }) |flag, binary| {
        settings_acceptance.addArg(flag);
        settings_acceptance.addArtifactArg(binary);
    }
    settings_acceptance.addPassthruArgs();
    const standalone_acceptance = b.step("test-settings-acceptance", "Run complete standalone Settings acceptance and affected private regressions");
    standalone_acceptance.dependOn(&b.addRunArtifact(pure).step);
    standalone_acceptance.dependOn(&settings_acceptance.step);

    const settings_presentation = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_presentation.py", "--settings" });
    settings_presentation.addArtifactArg(settings_test_app);
    settings_presentation.addArg("--pearl");
    settings_presentation.addArtifactArg(integration_app);
    settings_presentation.addArg("--ctl");
    settings_presentation.addArtifactArg(ctl);
    settings_presentation.addPassthruArgs();
    b.step("test-settings-presentation", "Verify standalone reference pages, scales, short windows and monitor removal").dependOn(&settings_presentation.step);

    const settings_integration = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_integration.py", "--pearl" });
    settings_integration.step.dependOn(agent_build);
    settings_integration.addArtifactArg(integration_app);
    settings_integration.addArg("--production-pearl");
    settings_integration.addArtifactArg(app);
    settings_integration.addArg("--ctl");
    settings_integration.addArtifactArg(ctl);
    settings_integration.addArg("--settings");
    settings_integration.addArtifactArg(settings_test_app);
    settings_integration.addArg("--production-settings");
    settings_integration.addArtifactArg(settings_app);
    settings_integration.addArg("--spike");
    settings_integration.addArtifactArg(spike);
    settings_integration.addArg("--locker");
    settings_integration.addArtifactArg(production_locker);
    settings_integration.addArg("--themes");
    settings_integration.addArtifactArg(themes_tool);
    settings_integration.addPassthruArgs();
    b.step("test-settings-integration", "Verify staged Settings desktop, CLI and flyout launch integration").dependOn(&settings_integration.step);

    const pam_fixture_module = createModule(b, .{ .root_source_file = b.path("tests/fixtures/pam.zig"), .target = target, .optimize = optimize, .link_libc = true });
    pam_fixture_module.addImport("pam", pam_module);
    pam_fixture_module.linkSystemLibrary("pam", .{});
    const pam_fixture = b.addLibrary(.{ .name = "pearl-pam-fixture", .linkage = .dynamic, .root_module = pam_fixture_module });
    if (plugin_activity_test) |activity| {
        activity.addArg("--pam-module");
        activity.addArtifactArg(pam_fixture);
        activity.addArg("--locker");
        activity.addArtifactArg(test_locker);
    }
    const fingerprint = b.addSystemCommand(&.{ "python3", "tests/integration/test_fingerprint.py", "--greeter" });
    fingerprint.addArtifactArg(greeter_test_executable);
    fingerprint.addArg("--locker");
    fingerprint.addArtifactArg(test_locker);
    fingerprint.addArg("--pam-module");
    fingerprint.addArtifactArg(pam_fixture);
    fingerprint.addPassthruArgs();
    const fingerprint_step = b.step("test-fingerprint", "Test passive fingerprint conversations, PAM policy branches and cancellation without hardware");
    fingerprint_step.dependOn(&fingerprint.step);
    fingerprint_step.dependOn(&b.addRunArtifact(greeter_unit).step);
    if (b.option([]const u8, "fingerprint-pam", "Path to non-installed pinned pam_fprintd test module")) |module_path| {
        const upstream = b.addSystemCommand(&.{ "python3", "tests/integration/test_fingerprint_upstream.py", "--locker" });
        upstream.addArtifactArg(test_locker);
        upstream.addArg("--pam-module");
        upstream.addArtifactArg(pam_fixture);
        upstream.addArgs(&.{ "--fprintd-module", module_path });
        upstream.addPassthruArgs();
        b.step("test-fingerprint-upstream", "Test upstream pam_fprintd against a private fake reader service").dependOn(&upstream.step);
    }
    const security = b.addSystemCommand(&.{ "python3", "tests/integration/test_security.py", "--pearl" });
    security.addArtifactArg(integration_app);
    security.addArg("--ctl");
    security.addArtifactArg(ctl);
    security.addArg("--locker");
    security.addArtifactArg(test_locker);
    security.addArg("--pam-module");
    security.addArtifactArg(pam_fixture);
    security.addPassthruArgs();
    b.step("test-security", "Verify native lock, PAM, polkit and idle/sleep sequencing on private services").dependOn(&security.step);
    const clipboard_fixture_module = createModule(b, .{ .root_source_file = b.path("tests/fixtures/clipboard.zig"), .target = target, .optimize = optimize, .link_libc = true });
    clipboard_fixture_module.addImport("wayland", native);
    clipboard_fixture_module.linkSystemLibrary("wayland-client", .{});
    const clipboard_fixture = b.addExecutable(.{ .name = "pearl-clipboard-fixture", .root_module = clipboard_fixture_module });
    const clipboard_tests = b.addSystemCommand(&.{ "python3", "tests/integration/test_clipboard_capture.py", "--pearl" });
    clipboard_tests.addArtifactArg(integration_app);
    clipboard_tests.addArg("--ctl");
    clipboard_tests.addArtifactArg(ctl);
    clipboard_tests.addArg("--locker");
    clipboard_tests.addArtifactArg(test_locker);
    clipboard_tests.addArg("--pam-module");
    clipboard_tests.addArtifactArg(pam_fixture);
    clipboard_tests.addArg("--producer");
    clipboard_tests.addArtifactArg(clipboard_fixture);
    clipboard_tests.addPassthruArgs();
    b.step("test-clipboard-capture", "Verify native clipboard privacy, ownership and output screenshots on private Aqueous").dependOn(&clipboard_tests.step);
    const calculator_tests = b.addSystemCommand(&.{ "python3", "tests/integration/test_launcher_calculator.py" });
    for ([_][]const u8{ "--pearl", "--ctl", "--locker", "--pam-module", "--producer" }, [_]*std.Build.Step.Compile{ integration_app, ctl, test_locker, pam_fixture, clipboard_fixture }) |flag, binary| {
        calculator_tests.addArg(flag);
        calculator_tests.addArtifactArg(binary);
    }
    calculator_tests.addPassthruArgs();
    b.step("test-launcher-calculator", "Verify launcher calculation, native copy and stale input handling in private Aqueous").dependOn(&calculator_tests.step);
    const assistant_launcher = b.addSystemCommand(&.{ "python3", "tests/integration/test_agent_launcher.py" });
    for ([_][]const u8{ "--pearl", "--ctl", "--locker", "--pam-module", "--settings" }, [_]*std.Build.Step.Compile{ integration_app, ctl, test_locker, pam_fixture, settings_test_app }) |flag, binary| {
        assistant_launcher.addArg(flag);
        assistant_launcher.addArtifactArg(binary);
    }
    assistant_launcher.addArg("--agent");
    assistant_launcher.addFileArg(.{ .relative = .{ .base = .install_bin, .sub_path = "pearl-agent" } });
    assistant_launcher.step.dependOn(agent_build);
    assistant_launcher.addPassthruArgs();
    b.step("test-agent-launcher", "Verify real launcher handoff and Settings controls with private search fixtures").dependOn(&assistant_launcher.step);
    const assistant_models = b.addSystemCommand(&.{ "python3", "tests/integration/test_agent_model_settings.py", "--pearl" });
    assistant_models.addArtifactArg(integration_app);
    assistant_models.addArg("--settings");
    assistant_models.addArtifactArg(settings_test_app);
    assistant_models.addArg("--ctl");
    assistant_models.addArtifactArg(ctl);
    assistant_models.addPassthruArgs();
    b.step("test-agent-model-settings", "Verify model choices and resource settings through the native Settings draft").dependOn(&assistant_models.step);
    const assistant_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_assistant_layout.py", "--pearl" });
    assistant_layout.addArtifactArg(integration_app);
    assistant_layout.addArg("--settings");
    assistant_layout.addArtifactArg(settings_test_app);
    assistant_layout.addPassthruArgs();
    b.step("test-assistant-layout", "Verify Assistant disclosures, draft controls and responsive presentation").dependOn(&assistant_layout.step);
    const benchmark_settings = b.addSystemCommand(&.{ "python3", "tests/integration/test_agent_benchmark_settings.py" });
    for ([_][]const u8{ "--pearl", "--ctl", "--settings" }, [_]*std.Build.Step.Compile{ integration_app, ctl, settings_test_app }) |flag, binary| {
        benchmark_settings.addArg(flag);
        benchmark_settings.addArtifactArg(binary);
    }
    benchmark_settings.addPassthruArgs();
    b.step("test-agent-benchmark-settings", "Verify native benchmark comparison and draft adoption").dependOn(&benchmark_settings.step);
    const lock_tests = b.addSystemCommand(&.{ "python3", "tests/integration/test_lock.py", "--locker" });
    lock_tests.addArtifactArg(test_locker);
    lock_tests.addArg("--pam-module");
    lock_tests.addArtifactArg(pam_fixture);
    lock_tests.addPassthruArgs();
    b.step("test-lock", "Verify native lock accessibility, output lifecycle, PAM failures and idle cost").dependOn(&lock_tests.step);
    const integration = b.addSystemCommand(&.{ "python3", "tests/integration/test_lifecycle.py", "--pearl" });
    integration.addArtifactArg(integration_app);
    integration.addArg("--production-pearl");
    integration.addArtifactArg(app);
    integration.addPassthruArgs();
    b.step("integration", "Run lifecycle tests on private Aqueous displays and buses").dependOn(&integration.step);
    const components = b.addSystemCommand(&.{ "python3", "tests/integration/test_components.py", "--pearl" });
    components.addArtifactArg(integration_app);
    components.addPassthruArgs();
    b.step("test-components", "Exercise gallery keyboard behavior and capture private Aqueous visuals").dependOn(&components.step);

    const gpu_report = b.addSystemCommand(&.{ "python3", "tests/integration/test_gpu_report.py", "--pearl" });
    gpu_report.addArtifactArg(app);
    gpu_report.addArg("--ctl");
    gpu_report.addArtifactArg(ctl);
    gpu_report.addPassthruArgs();
    b.step("test-gpu-report", "Verify GPU/report diagnostics on a private compositor (-- --aqueous PATH)").dependOn(&gpu_report.step);

    const surfaces = b.addSystemCommand(&.{ "python3", "tests/integration/test_surfaces.py", "--pearl" });
    const effect_trace_tests = b.addSystemCommand(&.{ "python3", "tests/test_background_effect_trace.py" });
    surfaces.step.dependOn(&effect_trace_tests.step);
    surfaces.addArtifactArg(app);
    surfaces.addArg("--ctl");
    surfaces.addArtifactArg(ctl);
    surfaces.addArg("--spike");
    surfaces.addArtifactArg(spike);
    surfaces.addPassthruArgs();
    b.step("test-surfaces", "Verify surfaces, CLI isolation and GTK/native blur ownership in private Aqueous").dependOn(&surfaces.step);

    const window_switcher = b.addSystemCommand(&.{ "python3", "tests/integration/test_window_switcher.py", "--pearl" });
    window_switcher.addArtifactArg(integration_app);
    window_switcher.addArg("--ctl");
    window_switcher.addArtifactArg(ctl);
    window_switcher.addPassthruArgs();
    b.step("test-window-switcher", "Verify global cycling, cursor handoff, animated scene and focus lifecycle").dependOn(&window_switcher.step);

    const running_apps = b.addSystemCommand(&.{ "python3", "tests/integration/test_running_apps.py", "--pearl" });
    running_apps.addArtifactArg(integration_app);
    running_apps.addArg("--ctl");
    running_apps.addArtifactArg(ctl);
    running_apps.addPassthruArgs();
    b.step("test-running-apps", "Verify global taskbar grouping, activation and chooser lifecycle").dependOn(&running_apps.step);

    const bar_editor = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_bar_editor.py", "--settings" });
    bar_editor.addArtifactArg(settings_test_app);
    bar_editor.addArg("--pearl");
    bar_editor.addArtifactArg(integration_app);
    bar_editor.addArg("--ctl");
    bar_editor.addArtifactArg(ctl);
    bar_editor.addPassthruArgs();
    b.step("test-settings-bar-editor", "Verify native bar selections, shared drafts and persistence").dependOn(&bar_editor.step);

    const dock = b.addSystemCommand(&.{ "python3", "tests/integration/test_dock_islands.py", "--pearl" });
    dock.addArtifactArg(integration_app);
    dock.addArg("--ctl");
    dock.addArtifactArg(ctl);
    dock.addPassthruArgs();
    b.step("test-dock-islands", "Verify T15 dock and island layouts in private Aqueous").dependOn(&dock.step);
    const desktop_overrides = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop_overrides.py", "--pearl" });
    desktop_overrides.addArtifactArg(integration_app);
    desktop_overrides.addArg("--ctl");
    desktop_overrides.addArtifactArg(ctl);
    desktop_overrides.addPassthruArgs();
    b.step("test-desktop-overrides", "Verify custom launcher selection, pin correction and recovery").dependOn(&desktop_overrides.step);
    const preferred_launchers = b.addSystemCommand(&.{ "python3", "tests/integration/test_preferred_launchers.py", "--pearl" });
    preferred_launchers.addArtifactArg(integration_app);
    preferred_launchers.addArg("--ctl");
    preferred_launchers.addArtifactArg(ctl);
    preferred_launchers.addPassthruArgs();
    b.step("test-preferred-launchers", "Verify automatic launcher preferences, grouping and installed desktop IDs").dependOn(&preferred_launchers.step);
    const bar_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_bar_layout.py", "--pearl" });
    bar_layout.addArtifactArg(integration_app);
    bar_layout.addArg("--ctl");
    bar_layout.addArtifactArg(ctl);
    bar_layout.addPassthruArgs();
    b.step("test-bar-layout", "Verify bar thickness and stacked widgets on every edge").dependOn(&bar_layout.step);
    const bar_autohide = b.addSystemCommand(&.{ "python3", "tests/integration/test_bar_autohide.py", "--pearl" });
    bar_autohide.addArtifactArg(integration_app);
    bar_autohide.addArg("--ctl");
    bar_autohide.addArtifactArg(ctl);
    bar_autohide.addPassthruArgs();
    b.step("test-bar-autohide", "Verify bar reveal, reservations, popup holds and lifecycle in private Aqueous").dependOn(&bar_autohide.step);

    const desktop = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop.py", "--pearl" });
    desktop.addArtifactArg(app);
    desktop.addArg("--ctl");
    desktop.addArtifactArg(ctl);
    desktop.addPassthruArgs();
    b.step("test-desktop", "Verify T06 live desktop and GIO discovery/activation in private Aqueous").dependOn(&desktop.step);

    const desktop_icons = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop_icons.py", "--pearl" });
    const desktop_icons_build = b.step("build-desktop-icons-test", "Stage the instrumented desktop icon session binary and control client");
    desktop_icons_build.dependOn(&b.addInstallArtifact(integration_app, .{}).step);
    desktop_icons_build.dependOn(&b.addInstallArtifact(ctl, .{}).step);
    desktop_icons.addArtifactArg(integration_app);
    desktop_icons.addArg("--ctl");
    desktop_icons.addArtifactArg(ctl);
    desktop_icons.addPassthruArgs();
    b.step("test-desktop-icons", "Verify desktop files, input, placement and installation defaults in private Aqueous").dependOn(&desktop_icons.step);

    const ddc_fixture = b.addLibrary(.{ .name = "pearl-ddc-fixture", .linkage = .dynamic, .root_module = createModule(b, .{
        .root_source_file = b.path("tests/fixtures/services/ddc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const brightness_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_display_brightness.py", "--pearl" });
    brightness_test.addArtifactArg(integration_app);
    brightness_test.addArg("--ctl");
    brightness_test.addArtifactArg(ctl);
    brightness_test.addArg("--ddc-library");
    brightness_test.addArtifactArg(ddc_fixture);
    brightness_test.addPassthruArgs();
    b.step("test-display-brightness", "Test mixed display brightness, identity and recovery against a private DDC ABI").dependOn(&brightness_test.step);

    const services = b.addSystemCommand(&.{ "python3", "tests/integration/test_services.py", "--pearl" });
    services.addArtifactArg(integration_app);
    services.addArg("--ctl");
    services.addArtifactArg(ctl);
    services.addArg("--spike");
    services.addArtifactArg(spike);
    services.addPassthruArgs();
    b.step("test-services", "Verify audio and power on private synthetic services").dependOn(&services.step);

    const connectivity = b.addSystemCommand(&.{ "python3", "tests/integration/test_connectivity.py", "--pearl" });
    connectivity.addArtifactArg(integration_app);
    connectivity.addArg("--ctl");
    connectivity.addArtifactArg(ctl);
    connectivity.addPassthruArgs();
    b.step("test-connectivity", "Verify NetworkManager and BlueZ on private services").dependOn(&connectivity.step);
    const network_ui = b.addSystemCommand(&.{ "python3", "tests/integration/test_network_ui.py", "--settings" });
    network_ui.addArtifactArg(settings_test_app);
    network_ui.addArg("--pearl");
    network_ui.addArtifactArg(integration_app);
    network_ui.addArg("--ctl");
    network_ui.addArtifactArg(ctl);
    network_ui.addPassthruArgs();
    b.step("test-network-ui", "Verify native Network views, grouping, radio state and responsive layouts on private services").dependOn(&network_ui.step);

    const settings_pages = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_pages.py", "--pearl" });
    settings_pages.addArtifactArg(integration_app);
    settings_pages.addArg("--ctl");
    settings_pages.addArtifactArg(ctl);
    settings_pages.addPassthruArgs();
    b.step("test-settings-pages", "Verify compact settings page composition and capture private service fixtures").dependOn(&settings_pages.step);

    const settings_lifecycle = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_lifecycle.py", "--pearl" });
    settings_lifecycle.addArtifactArg(integration_app);
    settings_lifecycle.addArg("--ctl");
    settings_lifecycle.addArtifactArg(ctl);
    settings_lifecycle.addArg("--spike");
    settings_lifecycle.addArtifactArg(spike);
    settings_lifecycle.addPassthruArgs();
    b.step("test-settings-lifecycle", "Verify settings popup routing, restored state and independent service owners").dependOn(&settings_lifecycle.step);

    const settings_accessibility = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_accessibility.py", "--pearl" });
    settings_accessibility.addArtifactArg(integration_app);
    settings_accessibility.addArg("--ctl");
    settings_accessibility.addArtifactArg(ctl);
    settings_accessibility.addPassthruArgs();
    b.step("test-settings-accessibility", "Verify service bar input, settings accessibility and compact presentation").dependOn(&settings_accessibility.step);

    const settings_navigation = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_navigation.py", "--pearl" });
    settings_navigation.addArtifactArg(integration_app);
    settings_navigation.addArg("--production-pearl");
    settings_navigation.addArtifactArg(app);
    settings_navigation.addArg("--ctl");
    settings_navigation.addArtifactArg(ctl);
    settings_navigation.addArg("--spike");
    settings_navigation.addArtifactArg(spike);
    settings_navigation.addPassthruArgs();
    const navigation_acceptance = b.step("test-settings-navigation", "Run pure tests and complete private-session compact settings acceptance");
    navigation_acceptance.dependOn(&b.addRunArtifact(pure).step);
    navigation_acceptance.dependOn(&settings_navigation.step);

    const aqueous_settings = b.addSystemCommand(&.{ "python3", "tests/integration/test_aqueous_master.py", "--pearl" });
    aqueous_settings.addArtifactArg(app);
    aqueous_settings.addArg("--ctl");
    aqueous_settings.addArtifactArg(ctl);
    aqueous_settings.addPassthruArgs();
    b.step("test-aqueous-settings", "Verify matching-master settings, receipts and native display leases").dependOn(&aqueous_settings.step);
    b.step("test-aqueous-master", "Verify pinned Aqueous master transactions").dependOn(&aqueous_settings.step);
    const single_window = b.addSystemCommand(&.{ "python3", "tests/integration/test_single_window_centering.py", "--pearl" });
    single_window.addArtifactArg(app);
    single_window.addArg("--ctl");
    single_window.addArtifactArg(ctl);
    single_window.addArg("--settings");
    single_window.addArtifactArg(settings_test_app);
    single_window.addPassthruArgs();
    b.step("test-single-window-centering", "Verify centering settings with a local Aqueous prefix (-- --prefix PATH)").dependOn(&single_window.step);
    const preview_lifecycle = b.addSystemCommand(&.{ "python3", "tests/integration/test_aqueous_preview.py", "--pearl" });
    preview_lifecycle.addArtifactArg(app);
    preview_lifecycle.addArg("--ctl");
    preview_lifecycle.addArtifactArg(ctl);
    preview_lifecycle.addPassthruArgs();
    b.step("test-aqueous-preview", "Verify presentation, session suspension and durable preview recovery").dependOn(&preview_lifecycle.step);
    const master_ui = b.addSystemCommand(&.{ "python3", "tests/integration/test_master_ui.py", "--pearl" });
    master_ui.addArtifactArg(app);
    master_ui.addArg("--settings");
    master_ui.addArtifactArg(settings_app);
    master_ui.addArg("--keyboard-settings");
    master_ui.addArtifactArg(settings_test_app);
    master_ui.addArg("--ctl");
    master_ui.addArtifactArg(ctl);
    master_ui.addPassthruArgs();
    b.step("test-master-ui", "Verify master settings themes, native accessibility and keyboard workflows").dependOn(&master_ui.step);
    const master_capture = b.addSystemCommand(&.{ "python3", "tests/integration/test_capture_master.py", "--pearl" });
    master_capture.addArtifactArg(app);
    master_capture.addArg("--ctl");
    master_capture.addArtifactArg(ctl);
    master_capture.addPassthruArgs();
    b.step("test-capture-master", "Verify matching-master image-copy sources and color negotiation").dependOn(&master_capture.step);

    const preferences = b.addSystemCommand(&.{ "python3", "tests/integration/test_preferences.py", "--pearl" });
    preferences.addArtifactArg(integration_app);
    preferences.addArg("--ctl");
    preferences.addArtifactArg(ctl);
    preferences.addPassthruArgs();
    b.step("test-preferences", "Verify preferences, wallpaper, dynamic and native GTK themes in private Aqueous").dependOn(&preferences.step);
    const qt_session = b.addSystemCommand(&.{ "python3", "tests/integration/test_qt_session.py", "--pearl" });
    qt_session.addArtifactArg(integration_app);
    qt_session.addArg("--settings");
    qt_session.addArtifactArg(settings_test_app);
    qt_session.addArg("--ctl");
    qt_session.addArtifactArg(ctl);
    qt_session.step.dependOn(b.getInstallStep());
    qt_session.addPassthruArgs();
    b.step("test-qt-session", "Verify Qt Appearance UI, committed updates and repair in private Aqueous").dependOn(&qt_session.step);

    const session_services = b.addSystemCommand(&.{ "python3", "tests/integration/test_session_services.py", "--pearl" });
    session_services.addArtifactArg(integration_app);
    session_services.addArg("--production-pearl");
    session_services.addArtifactArg(app);
    session_services.addArg("--spike");
    session_services.addArtifactArg(spike);
    session_services.addArg("--ctl");
    session_services.addArtifactArg(ctl);
    session_services.addPassthruArgs();
    b.step("test-session-services", "Verify notifications, StatusNotifier/DBusMenu and MPRIS on private session buses").dependOn(&session_services.step);

    const dev_backend = b.option(enum { headless, nested }, "dev-backend", "Development compositor backend") orelse .headless;
    for ([_][]const u8{ "run", "gallery" }) |name| {
        const launch = b.addSystemCommand(&.{ "python3", "scripts/dev-session.py", "--backend", @tagName(dev_backend), "--" });
        launch.addArtifactArg(app);
        if (std.mem.eql(u8, name, "gallery")) launch.addArg("--demo");
        launch.addPassthruArgs();
        b.step(name, if (std.mem.eql(u8, name, "gallery")) "Launch the demo gallery in private Aqueous" else "Launch Pearl in private Aqueous").dependOn(&launch.step);
    }
}

fn configureApp(b: *std.Build, module: *std.Build.Module, resources: std.Build.LazyPath, test_hooks: bool, wasm_plugins: bool, community_theme_repository: bool, file_chooser: bool, git_variant: bool) void {
    module.linkSystemLibrary("libcurl", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("libarchive", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("libpng", .{ .use_pkg_config = .yes });
    module.addAnonymousImport("pearl_resources", .{ .root_source_file = resources });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
    options.addOption(bool, "wasm_plugins", wasm_plugins);
    options.addOption(bool, "community_theme_repository", community_theme_repository);
    module.addOptions("build_options", options);
    if (!file_chooser) return;
    const previews = createModule(b, .{ .root_source_file = b.path("src/files/preview/root.zig"), .target = module.resolved_target, .optimize = module.optimize, .link_libc = true });
    for ([_][]const u8{ "gdk4", "gio2", "glib2", "gobject2", "gdkpixbuf2" }) |name| previews.addImport(name, module.import_table.get(name).?);
    previews.addImport("build_options", module.import_table.get("build_options").?);
    previews.addImport("diagnostics", module);
    module.addImport("previews", previews);
    const portal_identity = b.addOptions();
    portal_identity.addOption(bool, "git_variant", git_variant);
    module.addOptions("portal_identity", portal_identity);
    const chooser = createModule(b, .{ .root_source_file = b.path("src/files/chooser.zig"), .target = module.resolved_target, .optimize = module.optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| chooser.addImport(name, module.import_table.get(name).?);
    chooser.addImport("previews", previews);
    const chooser_options = b.addOptions();
    chooser_options.addOption([:0]const u8, "helper_path", if (git_variant) "/usr/lib/pearl-git/pearl-preview-helper" else "/usr/lib/pearl/pearl-preview-helper");
    chooser.addOptions("chooser_options", chooser_options);
    module.addImport("file_chooser", chooser);
}

fn gtkModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: []const u8, pulse: *std.Build.Module) *std.Build.Module {
    const module = createModule(b, .{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("pulse", pulse);
    module.addImport("giounix2", bindings.module("giounix2"));
    module.addImport("graphene1", bindings.module("graphene1"));
    module.linkSystemLibrary("libpulse", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("libpulse-mainloop-glib", .{ .use_pkg_config = .yes });
    // Interposition requires layer-shell to load before GTK's Wayland dependency.
    module.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("wayland-client", .{});
    const polkit = createModule(b, .{ .root_source_file = b.path("bindings/generated/polkit1/polkit1.zig"), .target = target, .optimize = optimize });
    var polkit_imports = bindings.module("gtk4").import_table.iterator();
    while (polkit_imports.next()) |entry| polkit.addImport(entry.key_ptr.*, entry.value_ptr.*);
    module.addImport("polkit1", polkit);
    module.linkSystemLibrary("polkit-agent-1", .{ .use_pkg_config = .yes });
    for ([_][]const u8{ "gtk4layershell1", "gtk4sessionlock1", "polkitagent1" }) |name| {
        const generated = createModule(b, .{
            .root_source_file = b.path(b.fmt("bindings/generated/{s}/{s}.zig", .{ name, name })),
            .target = target,
            .optimize = optimize,
        });
        generated.addImport("polkit1", polkit);
        generated.addImport("gtk4", bindings.module("gtk4"));
        var imports = bindings.module("gtk4").import_table.iterator();
        while (imports.next()) |entry| generated.addImport(entry.key_ptr.*, entry.value_ptr.*);
        module.addImport(name, generated);
    }
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "giounix2", "glib2", "glibunix2", "gobject2", "pango1", "gdkpixbuf2", "gdkwayland4", "cairo1", "giounix2" }) |name|
        module.addImport(name, bindings.module(name));
    return module;
}

fn greeterModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: []const u8, instrumented: bool) *std.Build.Module {
    const m = createModule(b, .{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    m.addAnonymousImport("greeter_style", .{ .root_source_file = b.path("resources/style.css") });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", instrumented);
    m.addOptions("build_options", options);
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "giounix2", "glib2", "glibunix2", "gobject2", "gdkpixbuf2" }) |name| m.addImport(name, bindings.module(name));
    m.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .yes });
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    const layer = createModule(b, .{ .root_source_file = b.path("bindings/generated/gtk4layershell1/gtk4layershell1.zig"), .target = target, .optimize = optimize });
    layer.addImport("gtk4", bindings.module("gtk4"));
    var imports = bindings.module("gtk4").import_table.iterator();
    while (imports.next()) |entry| layer.addImport(entry.key_ptr.*, entry.value_ptr.*);
    m.addImport("gtk4layershell1", layer);
    return m;
}

fn createModule(b: *std.Build, opts: std.Build.Module.CreateOptions) *std.Build.Module {
    const m = b.addModule(b.fmt("pearl_root_{d}", .{b.modules.count()}), opts);
    m.addImport("i18n", @import("src/i18n/build.zig").module(b, opts.target orelse b.graph.host, opts.optimize orelse .debug, b.path("src/i18n/runtime.zig")));
    return m;
}
