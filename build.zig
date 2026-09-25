const std = @import("std");
const Scanner = @import("wayland").Scanner;
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0"))
        @panic("Pearl requires Zig 0.16.0; see .zigversion");
    const plugin_examples = b.option([]const u8, "plugin-examples", "Prebuilt plugin examples and failure fixtures") orelse ".cache/plugin-examples";
    const wasm_plugins = b.option(bool, "wasm-plugins", "Build the experimental WebAssembly plugin helper") orelse false;
    const community_theme_repository = b.option(bool, "community-theme-repository", "Include the Seafoam GitHub community repository by default") orelse true;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.option(bool, "release", "Strip production artifacts for reproducible ReleaseSafe packages") orelse false;
    if (release and optimize != .ReleaseSafe) @panic("-Drelease requires -Doptimize=ReleaseSafe");
    const bindings = b.dependency("gobject", .{ .target = target, .optimize = optimize });
    if (b.option(bool, "codegen", "Build the pinned Ghostty GIR generator") orelse false) {
        if (b.lazyDependency("gobject_codegen", .{ .target = b.graph.host, .optimize = .ReleaseSafe })) |generator| {
            b.installArtifact(generator.artifact("translate-gir"));
            for ([_][]const u8{ "gir-fixes", "binding-overrides", "extensions" }) |directory|
                b.installDirectory(.{ .source_dir = generator.path(directory), .install_dir = .prefix, .install_subdir = b.fmt("share/gir-codegen/{s}", .{directory}) });
        }
        return;
    }
    var themes_tool: *std.Build.Step.Compile = undefined;
    for ([_][]const u8{ "zed", "equibop", "fluxer", "starship", "steam" }) |application| {
        b.installDirectory(.{ .source_dir = b.path(b.fmt("themes/profiles/seafoam.{s}", .{application})), .install_dir = .prefix, .install_subdir = b.fmt("share/pearl/matugen/profiles/seafoam.{s}", .{application}) });
    }
    for ([_]bool{ false, true }) |instrumented| {
        const tm = b.createModule(.{ .root_source_file = b.path("src/themes_main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = release and !instrumented });
        for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| tm.addImport(name, bindings.module(name));
        for ([_][]const u8{ "gio-2.0", "libcurl", "libarchive", "libpng" }) |name| tm.linkSystemLibrary(name, .{ .use_pkg_config = .force });
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
    const assets_module = b.createModule(.{ .root_source_file = b.path("src/theme_assets_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const publishing_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_publishing.py", "--tool" });
    publishing_test.addArtifactArg(themes_tool);
    if (community_theme_repository) publishing_test.addArg("--default-enabled");
    b.step("test-theme-publishing", "Verify native deterministic publication, schema 2 and source migration").dependOn(&publishing_test.step);
    for ([_][]const u8{ "gio-2.0", "libpng" }) |name| assets_module.linkSystemLibrary(name, .{ .use_pkg_config = .force });
    const assets_test = b.addTest(.{ .root_module = assets_module });
    b.step("test-theme-assets", "Validate PNG bounds and native memory resource lifetimes").dependOn(&b.addRunArtifact(assets_test).step);
    const theme_native_module = b.createModule(.{ .root_source_file = b.path("src/theme_native_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| theme_native_module.addImport(name, bindings.module(name));
    for ([_][]const u8{ "gio-2.0", "libcurl", "libarchive", "libpng" }) |name| theme_native_module.linkSystemLibrary(name, .{ .use_pkg_config = .force });
    const native_options = b.addOptions();
    native_options.addOption(bool, "test_hooks", true);
    theme_native_module.addOptions("build_options", native_options);
    theme_native_module.addAnonymousImport("matugen_fixture", .{ .root_source_file = b.path("tests/fixtures/community/render-data/matugen-4.2.json") });
    const theme_native_test = b.addRunArtifact(b.addTest(.{ .root_module = theme_native_module }));
    theme_native_test.setCwd(b.path("."));
    theme_native_test.setEnvironmentVariable("XDG_CACHE_HOME", b.pathFromRoot(".cache/profile-tests"));
    const matugen_tests = b.step("test-matugen", "Test native application rendering, snapshots and ownership recovery");
    matugen_tests.dependOn(&theme_native_test.step);
    const profile_formats = b.addSystemCommand(&.{ "python3", "tests/integration/test_profile_formats.py", "--tool" });
    profile_formats.addArtifactArg(themes_tool);
    matugen_tests.dependOn(&profile_formats.step);
    b.step("test-theme-discovery", "Test event-driven local theme discovery").dependOn(&theme_native_test.step);
    const pam = b.addTranslateC(.{ .root_source_file = b.path("bindings/headers/pam.h"), .target = target, .optimize = optimize });
    pam.addIncludePath(b.path("bindings/headers"));
    const pam_module = pam.createModule();
    const pam_export = b.addInstallFile(pam.getOutput(), "share/pearl/bindings/pam.zig");
    b.step("generate-pam", "Export the pinned PAM ABI").dependOn(&pam_export.step);
    const pulse = b.addTranslateC(.{ .root_source_file = b.path("bindings/headers/pulse.h"), .target = target, .optimize = optimize });
    pulse.addIncludePath(b.path("bindings/headers"));
    const pulse_module = pulse.createModule();
    const pulse_export = b.addInstallFile(pulse.getOutput(), "share/pearl/bindings/pulse.zig");
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
    const native = b.createModule(.{ .root_source_file = scanner.result, .target = target, .optimize = optimize });
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

    const greeter_unit = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/greeter_tests.zig"), .target = target, .optimize = optimize }) });
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
            gm.linkSystemLibrary("wayland-client", .{});
            gm.strip = release and !instrumented;
            const name = std.mem.replaceOwned(u8, b.allocator, component, "_", "-") catch @panic("OOM");
            const exe = b.addExecutable(.{ .name = b.fmt("pearl-{s}{s}", .{ name, if (instrumented) "-test" else "" }), .root_module = gm });
            const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = if (instrumented) "test" else "greeter/bin" } } });
            exe.step.dependOn(&greeter_versions.step);
            greeter_build.dependOn(&install.step);
            if (instrumented and std.mem.eql(u8, component, "greeter")) {
                greeter_test_executable = exe;
                for ([_][]const u8{ "ipc", "ui", "catalog", "services", "soak", "outputs" }) |suite| {
                    const check = b.addSystemCommand(&.{ "python3", b.fmt("tests/integration/test_greeter_{s}.py", .{suite}), "--greeter" });
                    check.addArtifactArg(exe);
                    if (b.args) |args| check.addArgs(args);
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
    configureApp(b, module, resources, false, wasm_plugins, community_theme_repository);
    module.addImport("wayland", native);
    module.strip = release;
    const app = b.addExecutable(.{ .name = "pearl", .root_module = module });
    app.step.dependOn(&system_versions.step);
    b.installArtifact(app);

    var settings_app: *std.Build.Step.Compile = undefined;
    var settings_test_app: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        // Ordinary application: deliberately excludes layer-shell, PulseAudio,
        // polkit/PAM and shell service initialization dependencies.
        const sm = b.createModule(.{ .root_source_file = b.path("src/settings_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "glibunix2", "gobject2", "gdkwayland4", "cairo1", "graphene1", "gdkpixbuf2", "giounix2" }) |name| sm.addImport(name, bindings.module(name));
        sm.addImport("wayland", native);
        sm.addAnonymousImport("settings_base_style", .{ .root_source_file = b.path("resources/style.css") });
        sm.addAnonymousImport("settings_colors", .{ .root_source_file = b.path("resources/settings.css") });
        sm.addAnonymousImport("settings_layout", .{ .root_source_file = b.path("resources/settings-layout.css") });
        sm.addAnonymousImport("settings_native", .{ .root_source_file = b.path("resources/gtk-theme.css") });

        sm.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
        sm.linkSystemLibrary("wayland-client", .{});
        configureApp(b, sm, resources, instrumented, wasm_plugins, community_theme_repository);
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
        configureApp(b, lock_module, resources, instrumented, false, community_theme_repository);
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
    const spike = b.addExecutable(.{ .name = "pearl-t00", .root_module = spike_module });
    spike.step.dependOn(&system_versions.step);
    b.installArtifact(spike);
    const bindings_test = b.addTest(.{ .root_module = spike_module });
    bindings_test.step.dependOn(&system_versions.step);
    b.step("test-bindings", "Test generated binding types and API coverage").dependOn(&b.addRunArtifact(bindings_test).step);

    const pure_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize });
    pure_module.addImport("aqueous_fixtures", b.createModule(.{ .root_source_file = b.path("tests/fixtures/aqueous/fixtures.zig"), .target = target, .optimize = optimize }));
    const pure = b.addTest(.{ .root_module = pure_module });
    const filter_module = b.createModule(.{ .root_source_file = b.path("src/notification_filter_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    filter_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
    const filter_tests = b.addRunArtifact(b.addTest(.{ .root_module = filter_module }));
    b.step("test-notification-filters", "Verify notification Unicode matching and policy lifetime").dependOn(&filter_tests.step);

    const night_clock_module = b.createModule(.{ .root_source_file = b.path("src/night_light_clock_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    night_clock_module.addImport("glib2", bindings.module("glib2"));
    night_clock_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
    const night_clock = b.addRunArtifact(b.addTest(.{ .root_module = night_clock_module }));
    const bar_clock_module = b.createModule(.{ .root_source_file = b.path("src/bar_clock_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bar_clock_module.addImport("glib2", bindings.module("glib2"));
    bar_clock_module.linkSystemLibrary("glib-2.0", .{ .use_pkg_config = .force });
    const bar_clock = b.addRunArtifact(b.addTest(.{ .root_module = bar_clock_module }));
    bar_clock.setEnvironmentVariable("LC_ALL", "C");
    b.step("test-bar-clock", "Verify time-zone clocks, DST, formatting and zone discovery").dependOn(&bar_clock.step);
    b.step("test-night-light-clock", "Verify Night Light schedules across timezone and DST transitions").dependOn(&night_clock.step);
    const test_step = b.step("test", "Run model and Unicode policy tests without GTK or a compositor");
    test_step.dependOn(&b.addRunArtifact(pure).step);
    test_step.dependOn(&filter_tests.step);

    b.step("test-plugin-unit", "Verify plugin documents, permissions, framing and route isolation").dependOn(&b.addRunArtifact(pure).step);
    var plugin_test_helper: ?*std.Build.Step.InstallArtifact = null;
    if (wasm_plugins) {
        const prefix = b.option([]const u8, "wasmtime-prefix", "Verified Wasmtime 48.0.2 C API prefix") orelse @panic("-Dwasm-plugins=true requires -Dwasmtime-prefix");
        const translated = b.addTranslateC(.{ .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include/wasmtime.h" }) }, .target = target, .optimize = optimize });
        translated.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        const host = b.createModule(.{ .root_source_file = b.path("src/plugin_host_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
        host.addImport("wasmtime", translated.createModule());
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
        const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugin_host.py", "--helper", b.getInstallPath(.bin, "pearl-plugin-host"), "--examples", plugin_examples });
        check.step.dependOn(helper_step);
        b.step("test-plugin-host", "Exercise three guest languages, sprites and helper failures").dependOn(&check.step);
    }

    const ctl_module = b.createModule(.{ .root_source_file = b.path("src/pearlctl.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| ctl_module.addImport(name, bindings.module(name));
    ctl_module.strip = release;
    const ctl = b.addExecutable(.{ .name = "pearlctl", .root_module = ctl_module });
    b.installArtifact(ctl);

    if (wasm_plugins) {
        const check = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugins.py", "--pearl", b.getInstallPath(.bin, "pearl"), "--ctl", b.getInstallPath(.bin, "pearlctl"), "--settings" });
        check.addArtifactArg(settings_test_app);
        check.addArgs(&.{ "--examples", plugin_examples });
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

    const custom_themes = b.addSystemCommand(&.{ "python3", "tests/integration/test_custom_themes.py", "--pearl" });
    custom_themes.addArtifactArg(app);
    custom_themes.addArg("--settings");
    custom_themes.addArtifactArg(settings_test_app);
    if (b.args) |args| custom_themes.addArgs(args);
    b.step("test-custom-themes", "Verify community themes and recovery in a private desktop session").dependOn(&custom_themes.step);
    const theme_completion = b.addSystemCommand(&.{ "python3", "tests/integration/test_theme_completion.py", "--pearl" });
    theme_completion.addArtifactArg(app);
    theme_completion.addArg("--settings");
    theme_completion.addArtifactArg(settings_test_app);
    if (b.args) |args| theme_completion.addArgs(args);
    b.step("test-theme-completion", "Verify image transfer, discovery and committed application profiles in a private session").dependOn(&theme_completion.step);
    const wallpaper_profiles = b.addSystemCommand(&.{ "python3", "tests/integration/test_wallpaper_profiles.py", "--pearl" });
    wallpaper_profiles.addArtifactArg(app);
    wallpaper_profiles.addArg("--ctl");
    wallpaper_profiles.addArtifactArg(ctl);
    wallpaper_profiles.addArg("--spike");
    wallpaper_profiles.addArtifactArg(spike);
    if (b.args) |args| wallpaper_profiles.addArgs(args);
    b.step("test-wallpaper-profiles", "Verify live wallpaper colors, committed profiles and cancellation in private XDG roots").dependOn(&wallpaper_profiles.step);

    const settings_window_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_app.py", "--settings" });
    settings_window_test.addArtifactArg(settings_test_app);
    settings_window_test.addArg("--production");
    settings_window_test.addArtifactArg(settings_app);
    settings_window_test.addArg("--pearl");
    settings_window_test.addArtifactArg(app);
    settings_window_test.addArg("--ctl");
    settings_window_test.addArtifactArg(ctl);
    if (b.args) |args| settings_window_test.addArgs(args);
    b.step("test-settings-app", "Verify standalone window, process isolation, activation and presentation").dependOn(&settings_window_test.step);

    const settings_appearance = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_appearance.py", "--settings" });
    settings_appearance.addArtifactArg(settings_test_app);
    settings_appearance.addArg("--pearl");
    settings_appearance.addArtifactArg(app);
    settings_appearance.addArg("--ctl");
    settings_appearance.addArtifactArg(ctl);
    settings_appearance.addArg("--spike");
    settings_appearance.addArtifactArg(spike);
    if (b.args) |args| settings_appearance.addArgs(args);
    b.step("test-settings-appearance", "Verify real standalone Appearance editing, shared drafts and save lifecycle").dependOn(&settings_appearance.step);

    const border_theme = b.addSystemCommand(&.{ "python3", "tests/integration/test_border_theme.py", "--settings" });
    border_theme.addArtifactArg(settings_test_app);
    border_theme.addArg("--pearl");
    border_theme.addArtifactArg(app);
    if (b.args) |args| border_theme.addArgs(args);
    b.step("test-border-theme", "Verify matugen border colors, draft deferral and generator failure").dependOn(&border_theme.step);

    const settings_services = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_services.py", "--settings" });
    settings_services.addArtifactArg(settings_test_app);
    settings_services.addArg("--pearl");
    settings_services.addArtifactArg(app);
    settings_services.addArg("--ctl");
    settings_services.addArtifactArg(ctl);
    settings_services.addArg("--spike");
    settings_services.addArtifactArg(spike);
    if (b.args) |args| settings_services.addArgs(args);
    b.step("test-settings-services", "Verify standalone live pages and complete Aqueous editor boundary").dependOn(&settings_services.step);

    const settings_displays = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_displays.py", "--settings" });
    settings_displays.addArtifactArg(settings_test_app);
    settings_displays.addArg("--pearl");
    settings_displays.addArtifactArg(app);
    settings_displays.addArg("--ctl");
    settings_displays.addArtifactArg(ctl);
    if (b.args) |args| settings_displays.addArgs(args);
    b.step("test-settings-displays", "Verify selected displays, positioning, HDR controls and native previews").dependOn(&settings_displays.step);

    const settings_boundary = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_boundary.py", "--pearl" });
    settings_boundary.addArtifactArg(app);
    settings_boundary.addArg("--ctl");
    settings_boundary.addArtifactArg(ctl);
    if (b.args) |args| settings_boundary.addArgs(args);
    b.step("test-settings-boundary", "Verify Settings frontend handshake and isolation in private sessions").dependOn(&settings_boundary.step);

    const release_tools = b.addSystemCommand(&.{ "python3", "tests/test_release_tools.py" });
    b.step("test-release-tools", "Verify release gates fail closed and source archives are deterministic").dependOn(&release_tools.step);

    const release_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_release.py", "--pearl" });
    release_test.addArtifactArg(app);
    release_test.addArg("--themes");
    release_test.addArtifactArg(themes_tool);
    release_test.addArg("--ctl");
    release_test.addArtifactArg(ctl);
    release_test.addArg("--settings");
    release_test.addArtifactArg(settings_app);
    release_test.addArg("--locker");
    release_test.addArtifactArg(production_locker);
    if (b.args) |args| release_test.addArgs(args);
    b.step("test-release", "Verify staged production installation and reversible DMS migration").dependOn(&release_test.step);

    const performance_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_release_performance.py", "--pearl" });
    performance_test.addArtifactArg(app);
    performance_test.addArg("--ctl");
    performance_test.addArtifactArg(ctl);
    if (b.args) |args| performance_test.addArgs(args);
    b.step("test-release-performance", "Measure production idle cost and 1,000 popup cycles in private Aqueous").dependOn(&performance_test.step);

    const adapter_module = b.createModule(.{ .root_source_file = b.path("src/adapter_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "glibunix2", "gobject2", "gdkpixbuf2" }) |name| adapter_module.addImport(name, bindings.module(name));
    const adapter_probe = b.addExecutable(.{ .name = "pearl-adapter-probe", .root_module = adapter_module });
    const qt_test_module = b.createModule(.{ .root_source_file = b.path("src/qt_theme_test_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "giounix2", "glib2", "gobject2" }) |name| qt_test_module.addImport(name, bindings.module(name));
    const qt_driver = b.addExecutable(.{ .name = "pearl-qt-test", .root_module = qt_test_module });
    const qt_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_qt_theme.py", "--driver" });
    qt_test.addArtifactArg(qt_driver);
    qt_test.step.dependOn(b.getInstallStep());
    if (b.args) |args| qt_test.addArgs(args);
    b.step("test-qt-theme", "Verify Qt palettes, Darkly, file ownership and restoration in private configuration").dependOn(&qt_test.step);
    b.step("test-qt-theme-unit", "Verify Qt policy, palette and lossless INI unit contracts").dependOn(&b.addRunArtifact(pure).step);
    b.step("adapter-probe", "Build the private IPC test driver").dependOn(&b.addInstallArtifact(adapter_probe, .{}).step);

    const adapter_unit = b.addTest(.{ .root_module = adapter_module });
    b.step("test-adapter-unit", "Check endpoint and image bounds using generated GIO bindings").dependOn(&b.addRunArtifact(adapter_unit).step);
    const adapter_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_adapter.py", "--probe" });
    adapter_test.addArtifactArg(adapter_probe);
    if (b.args) |args| adapter_test.addArgs(args);
    b.step("test-adapter", "Exercise IPC recovery, policy and commands on private sockets and nested Aqueous").dependOn(&adapter_test.step);

    const test_module = gtkModule(b, bindings, target, optimize, "src/main.zig", pulse_module);
    configureApp(b, test_module, resources, true, wasm_plugins, community_theme_repository);
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
    if (b.args) |args| night_test.addArgs(args);
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
    if (b.args) |args| discovery_test.addArgs(args);
    b.step("test-plugin-discovery", "Verify live plugin installation, replacement and removal in a private session").dependOn(&discovery_test.step);
    var plugin_activity_test: ?*std.Build.Step.Run = null;
    if (wasm_plugins) {
        const activity = b.addSystemCommand(&.{ "python3", "tests/integration/test_plugin_activity.py" });
        plugin_activity_test = activity;
        activity.step.dependOn(integration_build);
        activity.addArg("--ctl");
        activity.addArtifactArg(ctl);
        if (b.args) |args| activity.addArgs(args);
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
    b.step("test-greeter-sync-ui", "Verify native appearance sync from Settings and the flyout").dependOn(&greeter_sync_ui.step);
    const filter_settings = b.addSystemCommand(&.{ "python3", "tests/integration/test_notification_filters.py", "--settings" });
    filter_settings.addArtifactArg(settings_test_app);
    filter_settings.addArg("--pearl");
    filter_settings.addArtifactArg(integration_app);
    filter_settings.addArg("--ctl");
    filter_settings.addArtifactArg(ctl);
    if (b.args) |args| filter_settings.addArgs(args);
    b.step("test-notification-filter-settings", "Verify native filter drafts, matching and notification protocol in a private session").dependOn(&filter_settings.step);
    const settings_devices = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_devices.py", "--settings" });
    settings_devices.addArtifactArg(settings_test_app);
    settings_devices.addArg("--pearl");
    settings_devices.addArtifactArg(integration_app);
    settings_devices.addArg("--ctl");
    settings_devices.addArtifactArg(ctl);
    settings_devices.addArg("--spike");
    settings_devices.addArtifactArg(spike);
    if (b.args) |args| settings_devices.addArgs(args);
    b.step("test-settings-devices", "Verify standalone audio, power, notifications and media against private services").dependOn(&settings_devices.step);

    const settings_acceptance = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_acceptance.py" });
    for ([_][]const u8{ "--pearl", "--production-pearl", "--ctl", "--settings", "--production-settings", "--spike", "--locker" }, [_]*std.Build.Step.Compile{ integration_app, app, ctl, settings_test_app, settings_app, spike, production_locker }) |flag, binary| {
        settings_acceptance.addArg(flag);
        settings_acceptance.addArtifactArg(binary);
    }
    if (b.args) |args| settings_acceptance.addArgs(args);
    const standalone_acceptance = b.step("test-settings-acceptance", "Run complete standalone Settings acceptance and affected private regressions");
    standalone_acceptance.dependOn(&b.addRunArtifact(pure).step);
    standalone_acceptance.dependOn(&settings_acceptance.step);

    const settings_presentation = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_presentation.py", "--settings" });
    settings_presentation.addArtifactArg(settings_test_app);
    settings_presentation.addArg("--pearl");
    settings_presentation.addArtifactArg(integration_app);
    settings_presentation.addArg("--ctl");
    settings_presentation.addArtifactArg(ctl);
    if (b.args) |args| settings_presentation.addArgs(args);
    b.step("test-settings-presentation", "Verify standalone reference pages, scales, short windows and monitor removal").dependOn(&settings_presentation.step);

    const settings_integration = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_integration.py", "--pearl" });
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
    if (b.args) |args| settings_integration.addArgs(args);
    b.step("test-settings-integration", "Verify staged Settings desktop, CLI and flyout launch integration").dependOn(&settings_integration.step);

    const pam_fixture_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/pam.zig"), .target = target, .optimize = optimize, .link_libc = true });
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
    if (b.args) |args| fingerprint.addArgs(args);
    const fingerprint_step = b.step("test-fingerprint", "Test passive fingerprint conversations, PAM policy branches and cancellation without hardware");
    fingerprint_step.dependOn(&fingerprint.step);
    fingerprint_step.dependOn(&b.addRunArtifact(greeter_unit).step);
    if (b.option([]const u8, "fingerprint-pam", "Path to non-installed pinned pam_fprintd test module")) |module_path| {
        const upstream = b.addSystemCommand(&.{ "python3", "tests/integration/test_fingerprint_upstream.py", "--locker" });
        upstream.addArtifactArg(test_locker);
        upstream.addArg("--pam-module");
        upstream.addArtifactArg(pam_fixture);
        upstream.addArgs(&.{ "--fprintd-module", module_path });
        if (b.args) |args| upstream.addArgs(args);
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
    if (b.args) |args| security.addArgs(args);
    b.step("test-security", "Verify native lock, PAM, polkit and idle/sleep sequencing on private services").dependOn(&security.step);
    const clipboard_fixture_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/clipboard.zig"), .target = target, .optimize = optimize, .link_libc = true });
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
    if (b.args) |args| clipboard_tests.addArgs(args);
    b.step("test-clipboard-capture", "Verify native clipboard privacy, ownership and output screenshots on private Aqueous").dependOn(&clipboard_tests.step);
    const lock_tests = b.addSystemCommand(&.{ "python3", "tests/integration/test_lock.py", "--locker" });
    lock_tests.addArtifactArg(test_locker);
    lock_tests.addArg("--pam-module");
    lock_tests.addArtifactArg(pam_fixture);
    if (b.args) |args| lock_tests.addArgs(args);
    b.step("test-lock", "Verify native lock accessibility, output lifecycle, PAM failures and idle cost").dependOn(&lock_tests.step);
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

    const window_switcher = b.addSystemCommand(&.{ "python3", "tests/integration/test_window_switcher.py", "--pearl" });
    window_switcher.addArtifactArg(integration_app);
    window_switcher.addArg("--ctl");
    window_switcher.addArtifactArg(ctl);
    if (b.args) |args| window_switcher.addArgs(args);
    b.step("test-window-switcher", "Verify global cycling, cursor handoff, animated scene and focus lifecycle").dependOn(&window_switcher.step);

    const running_apps = b.addSystemCommand(&.{ "python3", "tests/integration/test_running_apps.py", "--pearl" });
    running_apps.addArtifactArg(integration_app);
    running_apps.addArg("--ctl");
    running_apps.addArtifactArg(ctl);
    if (b.args) |args| running_apps.addArgs(args);
    b.step("test-running-apps", "Verify global taskbar grouping, activation and chooser lifecycle").dependOn(&running_apps.step);

    const bar_editor = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_bar_editor.py", "--settings" });
    bar_editor.addArtifactArg(settings_test_app);
    bar_editor.addArg("--pearl");
    bar_editor.addArtifactArg(integration_app);
    bar_editor.addArg("--ctl");
    bar_editor.addArtifactArg(ctl);
    if (b.args) |args| bar_editor.addArgs(args);
    b.step("test-settings-bar-editor", "Verify native bar selections, shared drafts and persistence").dependOn(&bar_editor.step);

    const dock = b.addSystemCommand(&.{ "python3", "tests/integration/test_dock_islands.py", "--pearl" });
    dock.addArtifactArg(integration_app);
    dock.addArg("--ctl");
    dock.addArtifactArg(ctl);
    if (b.args) |args| dock.addArgs(args);
    b.step("test-dock-islands", "Verify T15 dock and island layouts in private Aqueous").dependOn(&dock.step);
    const desktop_overrides = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop_overrides.py", "--pearl" });
    desktop_overrides.addArtifactArg(integration_app);
    desktop_overrides.addArg("--ctl");
    desktop_overrides.addArtifactArg(ctl);
    if (b.args) |args| desktop_overrides.addArgs(args);
    b.step("test-desktop-overrides", "Verify custom launcher selection, pin correction and recovery").dependOn(&desktop_overrides.step);
    const preferred_launchers = b.addSystemCommand(&.{ "python3", "tests/integration/test_preferred_launchers.py", "--pearl" });
    preferred_launchers.addArtifactArg(integration_app);
    preferred_launchers.addArg("--ctl");
    preferred_launchers.addArtifactArg(ctl);
    if (b.args) |args| preferred_launchers.addArgs(args);
    b.step("test-preferred-launchers", "Verify automatic launcher preferences, grouping and installed desktop IDs").dependOn(&preferred_launchers.step);
    const bar_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_bar_layout.py", "--pearl" });
    bar_layout.addArtifactArg(integration_app);
    bar_layout.addArg("--ctl");
    bar_layout.addArtifactArg(ctl);
    if (b.args) |args| bar_layout.addArgs(args);
    b.step("test-bar-layout", "Verify bar thickness and stacked widgets on every edge").dependOn(&bar_layout.step);
    const bar_autohide = b.addSystemCommand(&.{ "python3", "tests/integration/test_bar_autohide.py", "--pearl" });
    bar_autohide.addArtifactArg(integration_app);
    bar_autohide.addArg("--ctl");
    bar_autohide.addArtifactArg(ctl);
    if (b.args) |args| bar_autohide.addArgs(args);
    b.step("test-bar-autohide", "Verify bar reveal, reservations, popup holds and lifecycle in private Aqueous").dependOn(&bar_autohide.step);

    const desktop = b.addSystemCommand(&.{ "python3", "tests/integration/test_desktop.py", "--pearl" });
    desktop.addArtifactArg(app);
    desktop.addArg("--ctl");
    desktop.addArtifactArg(ctl);
    if (b.args) |args| desktop.addArgs(args);
    b.step("test-desktop", "Verify T06 live desktop and GIO discovery/activation in private Aqueous").dependOn(&desktop.step);

    const services = b.addSystemCommand(&.{ "python3", "tests/integration/test_services.py", "--pearl" });
    services.addArtifactArg(integration_app);
    services.addArg("--ctl");
    services.addArtifactArg(ctl);
    services.addArg("--spike");
    services.addArtifactArg(spike);
    if (b.args) |args| services.addArgs(args);
    b.step("test-services", "Verify audio and power on private synthetic services").dependOn(&services.step);

    const connectivity = b.addSystemCommand(&.{ "python3", "tests/integration/test_connectivity.py", "--pearl" });
    connectivity.addArtifactArg(integration_app);
    connectivity.addArg("--ctl");
    connectivity.addArtifactArg(ctl);
    if (b.args) |args| connectivity.addArgs(args);
    b.step("test-connectivity", "Verify NetworkManager and BlueZ on private services").dependOn(&connectivity.step);

    const settings_pages = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_pages.py", "--pearl" });
    settings_pages.addArtifactArg(integration_app);
    settings_pages.addArg("--ctl");
    settings_pages.addArtifactArg(ctl);
    if (b.args) |args| settings_pages.addArgs(args);
    b.step("test-settings-pages", "Verify compact settings page composition and capture private service fixtures").dependOn(&settings_pages.step);

    const settings_lifecycle = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_lifecycle.py", "--pearl" });
    settings_lifecycle.addArtifactArg(integration_app);
    settings_lifecycle.addArg("--ctl");
    settings_lifecycle.addArtifactArg(ctl);
    settings_lifecycle.addArg("--spike");
    settings_lifecycle.addArtifactArg(spike);
    if (b.args) |args| settings_lifecycle.addArgs(args);
    b.step("test-settings-lifecycle", "Verify settings popup routing, restored state and independent service owners").dependOn(&settings_lifecycle.step);

    const settings_accessibility = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_accessibility.py", "--pearl" });
    settings_accessibility.addArtifactArg(integration_app);
    settings_accessibility.addArg("--ctl");
    settings_accessibility.addArtifactArg(ctl);
    if (b.args) |args| settings_accessibility.addArgs(args);
    b.step("test-settings-accessibility", "Verify service bar input, settings accessibility and compact presentation").dependOn(&settings_accessibility.step);

    const settings_navigation = b.addSystemCommand(&.{ "python3", "tests/integration/test_settings_navigation.py", "--pearl" });
    settings_navigation.addArtifactArg(integration_app);
    settings_navigation.addArg("--production-pearl");
    settings_navigation.addArtifactArg(app);
    settings_navigation.addArg("--ctl");
    settings_navigation.addArtifactArg(ctl);
    settings_navigation.addArg("--spike");
    settings_navigation.addArtifactArg(spike);
    if (b.args) |args| settings_navigation.addArgs(args);
    const navigation_acceptance = b.step("test-settings-navigation", "Run pure tests and complete private-session compact settings acceptance");
    navigation_acceptance.dependOn(&b.addRunArtifact(pure).step);
    navigation_acceptance.dependOn(&settings_navigation.step);

    const aqueous_settings = b.addSystemCommand(&.{ "python3", "tests/integration/test_aqueous_master.py", "--pearl" });
    aqueous_settings.addArtifactArg(app);
    aqueous_settings.addArg("--ctl");
    aqueous_settings.addArtifactArg(ctl);
    if (b.args) |args| aqueous_settings.addArgs(args);
    b.step("test-aqueous-settings", "Verify matching-master settings, receipts and native display leases").dependOn(&aqueous_settings.step);
    b.step("test-aqueous-master", "Verify pinned Aqueous master transactions").dependOn(&aqueous_settings.step);
    const preview_lifecycle = b.addSystemCommand(&.{ "python3", "tests/integration/test_aqueous_preview.py", "--pearl" });
    preview_lifecycle.addArtifactArg(app);
    preview_lifecycle.addArg("--ctl");
    preview_lifecycle.addArtifactArg(ctl);
    if (b.args) |args| preview_lifecycle.addArgs(args);
    b.step("test-aqueous-preview", "Verify presentation, session suspension and durable preview recovery").dependOn(&preview_lifecycle.step);
    const master_ui = b.addSystemCommand(&.{ "python3", "tests/integration/test_master_ui.py", "--pearl" });
    master_ui.addArtifactArg(app);
    master_ui.addArg("--settings");
    master_ui.addArtifactArg(settings_app);
    master_ui.addArg("--keyboard-settings");
    master_ui.addArtifactArg(settings_test_app);
    master_ui.addArg("--ctl");
    master_ui.addArtifactArg(ctl);
    if (b.args) |args| master_ui.addArgs(args);
    b.step("test-master-ui", "Verify master settings themes, native accessibility and keyboard workflows").dependOn(&master_ui.step);
    const master_capture = b.addSystemCommand(&.{ "python3", "tests/integration/test_capture_master.py", "--pearl" });
    master_capture.addArtifactArg(app);
    master_capture.addArg("--ctl");
    master_capture.addArtifactArg(ctl);
    if (b.args) |args| master_capture.addArgs(args);
    b.step("test-capture-master", "Verify matching-master image-copy sources and color negotiation").dependOn(&master_capture.step);

    const preferences = b.addSystemCommand(&.{ "python3", "tests/integration/test_preferences.py", "--pearl" });
    preferences.addArtifactArg(integration_app);
    preferences.addArg("--ctl");
    preferences.addArtifactArg(ctl);
    if (b.args) |args| preferences.addArgs(args);
    b.step("test-preferences", "Verify preferences, wallpaper, dynamic and native GTK themes in private Aqueous").dependOn(&preferences.step);
    const qt_session = b.addSystemCommand(&.{ "python3", "tests/integration/test_qt_session.py", "--pearl" });
    qt_session.addArtifactArg(integration_app);
    qt_session.addArg("--settings");
    qt_session.addArtifactArg(settings_test_app);
    qt_session.addArg("--ctl");
    qt_session.addArtifactArg(ctl);
    qt_session.step.dependOn(b.getInstallStep());
    if (b.args) |args| qt_session.addArgs(args);
    b.step("test-qt-session", "Verify Qt Appearance UI, committed updates and repair in private Aqueous").dependOn(&qt_session.step);

    const session_services = b.addSystemCommand(&.{ "python3", "tests/integration/test_session_services.py", "--pearl" });
    session_services.addArtifactArg(integration_app);
    session_services.addArg("--production-pearl");
    session_services.addArtifactArg(app);
    session_services.addArg("--spike");
    session_services.addArtifactArg(spike);
    session_services.addArg("--ctl");
    session_services.addArtifactArg(ctl);
    if (b.args) |args| session_services.addArgs(args);
    b.step("test-session-services", "Verify notifications, StatusNotifier/DBusMenu and MPRIS on private session buses").dependOn(&session_services.step);

    const dev_backend = b.option(enum { headless, nested }, "dev-backend", "Development compositor backend") orelse .headless;
    for ([_][]const u8{ "run", "gallery" }) |name| {
        const launch = b.addSystemCommand(&.{ "python3", "scripts/dev-session.py", "--backend", @tagName(dev_backend), "--" });
        launch.addArtifactArg(app);
        if (std.mem.eql(u8, name, "gallery")) launch.addArg("--demo");
        if (b.args) |args| launch.addArgs(args);
        b.step(name, if (std.mem.eql(u8, name, "gallery")) "Launch the demo gallery in private Aqueous" else "Launch Pearl in private Aqueous").dependOn(&launch.step);
    }
}

fn configureApp(b: *std.Build, module: *std.Build.Module, resources: std.Build.LazyPath, test_hooks: bool, wasm_plugins: bool, community_theme_repository: bool) void {
    module.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libarchive", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
    module.addAnonymousImport("pearl_resources", .{ .root_source_file = resources });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
    options.addOption(bool, "wasm_plugins", wasm_plugins);
    options.addOption(bool, "community_theme_repository", community_theme_repository);
    module.addOptions("build_options", options);
}

fn gtkModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: []const u8, pulse: *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("pulse", pulse);
    module.addImport("giounix2", bindings.module("giounix2"));
    module.linkSystemLibrary("libpulse", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("libpulse-mainloop-glib", .{ .use_pkg_config = .force });
    // Interposition requires layer-shell to load before GTK's Wayland dependency.
    module.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("wayland-client", .{});
    const polkit = b.createModule(.{ .root_source_file = b.path("bindings/generated/polkit1/polkit1.zig"), .target = target, .optimize = optimize });
    var polkit_imports = bindings.module("gtk4").import_table.iterator();
    while (polkit_imports.next()) |entry| polkit.addImport(entry.key_ptr.*, entry.value_ptr.*);
    module.addImport("polkit1", polkit);
    module.linkSystemLibrary("polkit-agent-1", .{ .use_pkg_config = .force });
    for ([_][]const u8{ "gtk4layershell1", "gtk4sessionlock1", "polkitagent1" }) |name| {
        const generated = b.createModule(.{
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
    const m = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize, .link_libc = true });
    m.addAnonymousImport("greeter_style", .{ .root_source_file = b.path("resources/style.css") });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", instrumented);
    m.addOptions("build_options", options);
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "giounix2", "glib2", "glibunix2", "gobject2", "gdkpixbuf2" }) |name| m.addImport(name, bindings.module(name));
    m.linkSystemLibrary("gtk4-layer-shell-0", .{ .use_pkg_config = .force });
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    const layer = b.createModule(.{ .root_source_file = b.path("bindings/generated/gtk4layershell1/gtk4layershell1.zig"), .target = target, .optimize = optimize });
    layer.addImport("gtk4", bindings.module("gtk4"));
    var imports = bindings.module("gtk4").import_table.iterator();
    while (imports.next()) |entry| layer.addImport(entry.key_ptr.*, entry.value_ptr.*);
    m.addImport("gtk4layershell1", layer);
    return m;
}
