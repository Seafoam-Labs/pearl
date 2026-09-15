const std = @import("std");
const Scanner = @import("wayland").Scanner;
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.16.0"))
        @panic("Pearl requires Zig 0.16.0; see .zigversion");
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
    b.step("test-greeter-unit", "Test bounded greetd framing, authority state and desktop parsing").dependOn(&b.addRunArtifact(greeter_unit).step);
    const greeter_versions = b.addSystemCommand(&.{ "pkg-config", "--exists", "gtk4 >= 4.22.5", "glib-2.0 >= 2.88.3", "gtk4-layer-shell-0 >= 1.3.0" });
    const greeter_build = b.step("build-greeter", "Build optional greeter artifacts without installing or activating a display manager");
    var greeter_test_executable: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        for ([_][]const u8{ "greeter", "greeter_session", "greeter_host" }) |component| {
            const gm = greeterModule(b, bindings, target, optimize, b.fmt("src/{s}_main.zig", .{component}), instrumented);
            gm.strip = release and !instrumented;
            const name = std.mem.replaceOwned(u8, b.allocator, component, "_", "-") catch @panic("OOM");
            const exe = b.addExecutable(.{ .name = b.fmt("pearl-{s}{s}", .{ name, if (instrumented) "-test" else "" }), .root_module = gm });
            const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = if (instrumented) "test" else "greeter/bin" } } });
            exe.step.dependOn(&greeter_versions.step);
            greeter_build.dependOn(&install.step);
            if (instrumented and std.mem.eql(u8, component, "greeter")) {
                greeter_test_executable = exe;
                for ([_][]const u8{ "ipc", "ui", "catalog", "services", "soak" }) |suite| {
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
        }
    }

    const module = gtkModule(b, bindings, target, optimize, "src/main.zig", pulse_module);
    configureApp(b, module, resources, false);
    module.addImport("wayland", native);
    module.strip = release;
    const app = b.addExecutable(.{ .name = "pearl", .root_module = module });
    app.step.dependOn(&system_versions.step);
    b.installArtifact(app);

    var test_locker: *std.Build.Step.Compile = undefined;
    var production_locker: *std.Build.Step.Compile = undefined;
    for ([_]bool{ false, true }) |instrumented| {
        const lock_module = gtkModule(b, bindings, target, optimize, "src/lock_main.zig", pulse_module);
        configureApp(b, lock_module, resources, instrumented);
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
    b.step("test", "Run pure lifecycle, startup and Aqueous model tests without GTK or a compositor").dependOn(&b.addRunArtifact(pure).step);

    const ctl_module = b.createModule(.{ .root_source_file = b.path("src/pearlctl.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gio2", "glib2", "gobject2" }) |name| ctl_module.addImport(name, bindings.module(name));
    ctl_module.strip = release;
    const ctl = b.addExecutable(.{ .name = "pearlctl", .root_module = ctl_module });
    b.installArtifact(ctl);

    const release_tools = b.addSystemCommand(&.{ "python3", "tests/test_release_tools.py" });
    b.step("test-release-tools", "Verify release gates fail closed and source archives are deterministic").dependOn(&release_tools.step);

    const release_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_release.py", "--pearl" });
    release_test.addArtifactArg(app);
    release_test.addArg("--ctl");
    release_test.addArtifactArg(ctl);
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
    b.step("adapter-probe", "Build the private IPC test driver").dependOn(&b.addInstallArtifact(adapter_probe, .{}).step);

    const adapter_unit = b.addTest(.{ .root_module = adapter_module });
    b.step("test-adapter-unit", "Check endpoint and image bounds using generated GIO bindings").dependOn(&b.addRunArtifact(adapter_unit).step);
    const adapter_test = b.addSystemCommand(&.{ "python3", "tests/integration/test_adapter.py", "--probe" });
    adapter_test.addArtifactArg(adapter_probe);
    if (b.args) |args| adapter_test.addArgs(args);
    b.step("test-adapter", "Exercise IPC recovery, policy and commands on private sockets and nested Aqueous").dependOn(&adapter_test.step);

    const test_module = gtkModule(b, bindings, target, optimize, "src/main.zig", pulse_module);
    configureApp(b, test_module, resources, true);
    test_module.addImport("wayland", native);
    const integration_app = b.addExecutable(.{ .name = "pearl-integration", .root_module = test_module });
    integration_app.step.dependOn(&system_versions.step);
    const pam_fixture_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/pam.zig"), .target = target, .optimize = optimize, .link_libc = true });
    pam_fixture_module.addImport("pam", pam_module);
    pam_fixture_module.linkSystemLibrary("pam", .{});
    const pam_fixture = b.addLibrary(.{ .name = "pearl-pam-fixture", .linkage = .dynamic, .root_module = pam_fixture_module });
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

    const dock = b.addSystemCommand(&.{ "python3", "tests/integration/test_dock_islands.py", "--pearl" });
    dock.addArtifactArg(app);
    dock.addArg("--ctl");
    dock.addArtifactArg(ctl);
    if (b.args) |args| dock.addArgs(args);
    b.step("test-dock-islands", "Verify T15 dock and island layouts in private Aqueous").dependOn(&dock.step);
    const bar_layout = b.addSystemCommand(&.{ "python3", "tests/integration/test_bar_layout.py", "--pearl" });
    bar_layout.addArtifactArg(integration_app);
    bar_layout.addArg("--ctl");
    bar_layout.addArtifactArg(ctl);
    if (b.args) |args| bar_layout.addArgs(args);
    b.step("test-bar-layout", "Verify bar thickness and stacked widgets on every edge").dependOn(&bar_layout.step);

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
    if (b.args) |args| services.addArgs(args);
    b.step("test-services", "Verify audio and power on private synthetic services").dependOn(&services.step);

    const connectivity = b.addSystemCommand(&.{ "python3", "tests/integration/test_connectivity.py", "--pearl" });
    connectivity.addArtifactArg(integration_app);
    connectivity.addArg("--ctl");
    connectivity.addArtifactArg(ctl);
    if (b.args) |args| connectivity.addArgs(args);
    b.step("test-connectivity", "Verify NetworkManager and BlueZ on private services").dependOn(&connectivity.step);

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
    master_ui.addArg("--keyboard-pearl");
    master_ui.addArtifactArg(integration_app);
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

fn configureApp(b: *std.Build, module: *std.Build.Module, resources: std.Build.LazyPath, test_hooks: bool) void {
    module.addAnonymousImport("pearl_resources", .{ .root_source_file = resources });
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);
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
