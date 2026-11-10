const std = @import("std");
pub fn build(b: *std.Build) void {
    defer @import("pearl_ffi").attach(b, b.path("../../bindings/c"));
    const bindings = b.dependency("gobject", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_python = b.option([]const u8, "native-python", "Python interpreter or validation-only launcher for private native harnesses") orelse "python3";
    const scanner = @import("wayland").Scanner.create(b, .{ .wayland_xml = b.path("../../bindings/protocols/wayland.xml"), .wayland_protocols = b.path("../../bindings/protocols") });
    scanner.addCustomProtocol(b.path("../../bindings/protocols/aqueous-shell-v1.xml"));
    scanner.addCustomProtocol(b.path("../../bindings/protocols/ext-workspace-v1.xml"));
    scanner.generate("aqueous_shell_manager_v1", 2);
    const native = createModule(b, .{ .root_source_file = scanner.result, .target = target, .optimize = optimize });
    // Shared read-only appearance boundary with the parent tree, identical to Dome's and Phyto's.
    const appearance = createModule(b, .{ .root_source_file = b.path("../../src/appearance_client.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2", "gdkwayland4" }) |name| appearance.addImport(name, bindings.module(name));
    appearance.addImport("wayland", native);
    for ([_][]const u8{ "gtk4", "wayland-client", "libpng" }) |name| appearance.linkSystemLibrary(name, .{ .use_pkg_config = .yes });
    const git_variant = b.option(bool, "git-variant", "Use the Git application identity") orelse false;
    const command = if (git_variant) "coral-git" else "coral";
    const options = b.addOptions();
    options.addOption(bool, "git_variant", git_variant);
    options.addOptionPathDirectory("development_styles", b.path("resources"));
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "Enable isolated native test instrumentation") orelse false);
    const m = createModule(b, .{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| m.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    m.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    m.addOptions("build_options", options);
    m.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    m.addAnonymousImport("theme_style", .{ .root_source_file = b.path("resources/theme.css") });
    m.addImport("appearance_client", appearance);
    // Shared by path with the parent tree so every executable renders identical
    // log lines and redacts untrusted text the same way.
    const logging = createModule(b, .{ .root_source_file = b.path("../../src/core/logging.zig"), .target = target, .optimize = optimize });
    const diagnostics = createModule(b, .{ .root_source_file = b.path("../../src/diagnostics_bridge.zig"), .target = target, .optimize = optimize });
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
    run.addPassthruArgs();
    b.step("run", "Launch Coral").dependOn(&run.step);
    const tm = createModule(b, .{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| tm.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    tm.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    // Admission tests use real App types but perform no GTK or filesystem I/O.
    // Keep their module boundaries identical to the production application.
    inline for (.{ "build_options", "appearance_client", "logging", "diagnostics", "style", "theme_style", "previews", "file_chooser" }) |name| tm.addImport(name, m.import_table.get(name).?);
    const tests = b.addTest(.{ .root_module = tm });
    const test_step = b.step("test", "Test file format, revisions, Unicode tokenization and real GIO saves");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Trust concurrency tests fork; isolate them from the GIO tests' worker pool.
    const trust_module = createModule(b, .{ .root_source_file = b.path("src/workspace/trust_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const trust_tests = b.addTest(.{ .root_module = trust_module });
    test_step.dependOn(&b.addRunArtifact(trust_tests).step);
    // Session publication tests fork too; keep them outside the GIO test process.
    const session_module = b.createModule(.{ .root_source_file = b.path("src/session_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const session_tests = b.addTest(.{ .root_module = session_module });
    const session_units = b.addRunArtifact(session_tests);
    test_step.dependOn(&session_units.step);
    b.step("session-unit", "Test saved-session schema and durable publication").dependOn(&session_units.step);
    const project_module = b.createModule(.{ .root_source_file = b.path("src/project_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const project_tests = b.addTest(.{ .root_module = project_module });
    const project_units = b.addRunArtifact(project_tests);
    test_step.dependOn(&project_units.step);
    b.step("project-unit", "Test automatic project catalog, leases and atomic publication").dependOn(&project_units.step);
    const appearance_module = createModule(b, .{ .root_source_file = b.path("src/appearance.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| appearance_module.addImport(name, bindings.module(name));
    appearance_module.addImport("appearance_client", appearance);
    appearance_module.addAnonymousImport("theme_style", .{ .root_source_file = b.path("resources/theme.css") });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| appearance_module.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    const appearance_tests = b.addTest(.{ .root_module = appearance_module });
    test_step.dependOn(&b.addRunArtifact(appearance_tests).step);
    const io = b.addOptions();
    io.addOption(bool, "test_hooks", true);
    io.addOption(bool, "git_variant", false);
    io.addOptionPathDirectory("development_styles", b.path("resources"));
    const im = createModule(b, .{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| im.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
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
    const integration = b.addSystemCommand(&.{ native_python, "tests/native.py", "--binary" });
    integration.addArtifactArg(ie);
    // Never overwrite the checked-in native evidence when running local gates.
    integration.addArgs(&.{ "--output", "../../.cache/coral-native" });
    integration.addPassthruArgs();
    b.step("integration", "Run native Coral workflows in an isolated Wayland session").dependOn(&integration.step);
    const workspaces = b.addSystemCommand(&.{ native_python, "tests/workspaces.py", "--binary" });
    workspaces.addArtifactArg(ie);
    workspaces.addPassthruArgs();
    b.step("workspaces", "Test first M2 restricted bounded native workspace browser").dependOn(&workspaces.step);
    const m2_slice = b.step("test-m2-slice", "Run model/browser unit tests and first M2 native workspace acceptance");
    m2_slice.dependOn(test_step);
    m2_slice.dependOn(&workspaces.step);
    const explorer = b.addSystemCommand(&.{ native_python, "tests/explorer.py", "--binary" });
    explorer.addArtifactArg(ie);
    explorer.addPassthruArgs();
    b.step("explorer", "Run 100k native virtualized explorer acceptance").dependOn(&explorer.step);
    const m2_explorer = b.step("test-m2-explorer", "Run explorer unit and 100k native acceptance");
    m2_explorer.dependOn(test_step);
    m2_explorer.dependOn(&explorer.step);
    const search = b.addSystemCommand(&.{ native_python, "tests/search.py", "--binary" });
    search.addArtifactArg(ie);
    search.addPassthruArgs();
    b.step("search", "Run native quick-open and workspace search acceptance").dependOn(&search.step);
    const m2_search = b.step("test-m2-search", "Run search unit, widget and 100k native acceptance");
    m2_search.dependOn(test_step);
    m2_search.dependOn(&search.step);
    const policy = b.addSystemCommand(&.{ native_python, "tests/policy.py", "--binary" });
    policy.addArtifactArg(ie);
    policy.addPassthruArgs();
    b.step("policy", "Run native settings provenance and workspace trust acceptance").dependOn(&policy.step);
    const m2_policy = b.step("test-m2-policy", "Run settings/trust units, widgets and native acceptance");
    m2_policy.dependOn(test_step);
    m2_policy.dependOn(&policy.step);
    const sessions = b.addSystemCommand(&.{ native_python, "tests/sessions.py", "--binary" });
    sessions.addArtifactArg(ie);
    sessions.addPassthruArgs();
    b.step("sessions", "Run explicit workspace session native acceptance").dependOn(&sessions.step);
    const m2_sessions = b.step("test-m2-sessions", "Run session units, widgets and native acceptance");
    m2_sessions.dependOn(test_step);
    m2_sessions.dependOn(&sessions.step);
    const docks = b.addSystemCommand(&.{ native_python, "tests/docks.py", "--binary" });
    docks.addArtifactArg(ie);
    docks.addPassthruArgs();
    b.step("docks", "Run native dock geometry, focus and picker acceptance").dependOn(&docks.step);
    const m2_docks = b.step("test-m2-docks", "Run dock units, widgets and native acceptance");
    m2_docks.dependOn(test_step);
    m2_docks.dependOn(&docks.step);
    const windows = b.addSystemCommand(&.{ native_python, "tests/windows.py", "--binary" });
    windows.addArtifactArg(ie);
    windows.addPassthruArgs();
    b.step("windows", "Run native multi-window ownership and lifecycle acceptance").dependOn(&windows.step);
    const m2_windows = b.step("test-m2-windows", "Run units, widgets and multi-window acceptance");
    m2_windows.dependOn(test_step);
    m2_windows.dependOn(&windows.step);
    const operations = b.addSystemCommand(&.{ native_python, "tests/operations.py", "--binary" });
    operations.addArtifactArg(ie);
    operations.addPassthruArgs();
    b.step("operations", "Run native workspace file operation acceptance").dependOn(&operations.step);
    const m2_operations = b.step("test-m2-operations", "Run units, widgets and workspace file operation acceptance");
    m2_operations.dependOn(test_step);
    m2_operations.dependOn(&operations.step);
    const projects = b.addSystemCommand(&.{ native_python, "tests/projects.py", "--binary" });
    projects.addArtifactArg(ie);
    projects.addPassthruArgs();
    b.step("projects", "Run automatic project sessions, startup and picker acceptance").dependOn(&projects.step);
    const m2_projects = b.step("test-m2-projects", "Run units, widgets and complete project lifecycle acceptance");
    m2_projects.dependOn(test_step);
    m2_projects.dependOn(&projects.step);
    const roots = b.addSystemCommand(&.{ native_python, "tests/roots.py", "--binary" });
    roots.addArtifactArg(ie);
    roots.addPassthruArgs();
    b.step("roots", "Run native workspace root and manifest management acceptance").dependOn(&roots.step);
    const m2_roots = b.step("test-m2-roots", "Run units, widgets and root management acceptance");
    m2_roots.dependOn(test_step);
    m2_roots.dependOn(&roots.step);
    const m1 = b.step("test-m1", "Run unit, widget, native, group and recovery acceptance tests");
    m1.dependOn(test_step);
    m1.dependOn(&integration.step);
    inline for (.{ .{ "app-groups", "tests/app_groups.py" }, .{ "app-recovery", "tests/app_recovery.py" } }) |entry| {
        const check = b.addSystemCommand(&.{ native_python, entry[1], "--binary" });
        check.addArtifactArg(ie);
        check.addPassthruArgs();
        b.step(entry[0], "Run isolated native acceptance harness").dependOn(&check.step);
        m1.dependOn(&check.step);
    }
    const wm = createModule(b, .{ .root_source_file = b.path("src/widget_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| wm.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    const widget_tests = b.addTest(.{ .root_module = wm });
    const widgets = b.addSystemCommand(&.{ native_python, "tests/widgets.py", "--binary" });
    widgets.addArtifactArg(widget_tests);
    widgets.addPassthruArgs();
    b.step("widgets", "Test editor views and palette lifetimes in a private Wayland session").dependOn(&widgets.step);
    m1.dependOn(&widgets.step);
    m2_explorer.dependOn(&widgets.step);
    m2_search.dependOn(&widgets.step);
    m2_policy.dependOn(&widgets.step);
    m2_sessions.dependOn(&widgets.step);
    m2_docks.dependOn(&widgets.step);
    m2_windows.dependOn(&widgets.step);
    m2_operations.dependOn(&widgets.step);
    m2_projects.dependOn(&widgets.step);
    m2_roots.dependOn(&widgets.step);
    const m2 = b.step("test-m2", "Run complete bounded M2 acceptance, including M1 regressions");
    for ([_]*std.Build.Step{ m1, m2_slice, m2_explorer, m2_search, m2_policy, m2_sessions, m2_docks, m2_windows, m2_operations, m2_projects, m2_roots }) |gate| m2.dependOn(gate);

    const bm = createModule(b, .{ .root_source_file = b.path("src/benchmark_m0.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| bm.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    const benchmark = b.addExecutable(.{ .name = "coral-benchmark-m0", .root_module = bm });
    const source_snapshot = b.addSystemCommand(&.{ "python3", "tests/benchmarks.py", "--capture-sources" });
    source_snapshot.has_side_effects = true;
    const source_manifest = source_snapshot.addOutputFileArg("benchmark-sources.json");
    benchmark.step.dependOn(&source_snapshot.step);
    b.step("build-benchmarks", "Build bounded M0 engine benchmarks (use -Doptimize=safe)").dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const benchmarks = b.addSystemCommand(&.{ "python3", "tests/benchmarks.py", "--binary" });
    benchmarks.addArtifactArg(benchmark);
    benchmarks.addArgs(&.{ "--optimize", @tagName(optimize), "--expected-sources" });
    benchmarks.addFileArg(source_manifest);
    benchmarks.addPassthruArgs();
    b.step("benchmarks", "Run B01-B05 and separately labelled production-policy fallback baselines").dependOn(&benchmarks.step);

    // Optional fixtures only: no VTE dependency or install edge in production.
    const terminal_spike = b.addSystemCommand(&.{ "python3", "tests/terminal_spike.py" });
    terminal_spike.addPassthruArgs();
    b.step("terminal-spike", "Run optional prebuilt GTK4 VTE fixtures; pass --binary and --child after --").dependOn(&terminal_spike.step);
    if (b.option([]const u8, "prototype-python", "Explicit Playwright venv Python for optional prototype-m0 target")) |python| {
        if (b.graph.environ_map.get("PLAYWRIGHT_BROWSERS_PATH") == null)
            @panic("prototype-python requires an explicit offline PLAYWRIGHT_BROWSERS_PATH; see docs/WORKBENCH_M0_BENCHMARKS.md");
        const prototype = b.addSystemCommand(&.{ python, "-B", "tests/prototype_m0.py" });
        prototype.addPassthruArgs();
        b.step("prototype-m0", "Optional offline browser review; writes prototype evidence, never part of test-m1/install").dependOn(&prototype.step);
    }
}

fn previewModule(b: *std.Build, bindings: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: std.Build.LazyPath, options: *std.Build.Module, diagnostics: *std.Build.Module) *std.Build.Module {
    const m = createModule(b, .{ .root_source_file = root, .target = target, .optimize = optimize, .link_libc = true });
    for ([_][]const u8{ "gdk4", "gio2", "glib2", "gobject2", "gdkpixbuf2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("build_options", options);
    m.addImport("diagnostics", diagnostics);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    return m;
}

fn chooserModule(b: *std.Build, root: std.Build.LazyPath, host: *std.Build.Module, bindings: *std.Build.Dependency, previews: *std.Build.Module, git_variant: bool) *std.Build.Module {
    const m = createModule(b, .{ .root_source_file = root, .target = host.resolved_target, .optimize = host.optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gdk4", "gio2", "glib2", "gobject2" }) |name| m.addImport(name, bindings.module(name));
    m.addImport("previews", previews);
    const options = b.addOptions();
    options.addOption([:0]const u8, "helper_path", if (git_variant) "/usr/lib/pearl-git/pearl-preview-helper" else "/usr/lib/pearl/pearl-preview-helper");
    m.addOptions("chooser_options", options);
    m.linkSystemLibrary("gtk4", .{ .use_pkg_config = .yes });
    return m;
}

fn createModule(b: *std.Build, opts: std.Build.Module.CreateOptions) *std.Build.Module {
    const m = b.addModule(b.fmt("pearl_root_{d}", .{b.modules.count()}), opts);
    const runtime = b.modules.get("pearl_i18n") orelse blk: {
        const runtime = b.addModule("pearl_i18n", .{ .root_source_file = b.path("../../src/i18n/runtime.zig"), .target = opts.target orelse b.graph.host, .optimize = opts.optimize orelse .debug, .link_libc = true });
        const options = b.addOptions();
        options.addOption([]const u8, "prefix", b.option([]const u8, "i18n-prefix", "Language pack installation prefix") orelse "/usr");
        runtime.addOptions("i18n_options", options);
        break :blk runtime;
    };
    const app_c: @import("translate_c").Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "app_c",
        .c_source_file = b.path("src/c.h"),
        .target = opts.target orelse b.graph.host,
        .optimize = opts.optimize orelse .debug,
        .link_system_libs = &.{ .{ .name = "gtk4" }, .{ .name = "gtksourceview-5" }, .{ .name = "enchant-2" } },
    });
    m.addImport("pearl_app_c", app_c.mod);
    m.addImport("i18n", runtime);
    return m;
}
