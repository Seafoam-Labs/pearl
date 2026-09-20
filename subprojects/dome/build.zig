const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", b.option(bool, "test-hooks", "Enable isolated integration instrumentation") orelse false);
    const git_variant = b.option(bool, "git-variant", "Use the Git application identity") orelse false;
    options.addOption(bool, "git_variant", git_variant);
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    module.addOptions("build_options", options);
    module.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    const exe = b.addExecutable(.{ .name = if (git_variant) "dome-git" else "dome", .root_module = module });
    b.installArtifact(exe);
    const generated = b.addWriteFiles();
    const identity = if (git_variant) "org.aqueous.Dome.Git" else "org.aqueous.Dome";
    inline for (.{ .{ "packaging/org.aqueous.Dome.desktop", "share/applications", "desktop" }, .{ "packaging/org.aqueous.Dome.metainfo.xml", "share/metainfo", "metainfo.xml" } }) |entry| {
        const original = @embedFile(entry[0]);
        const named = std.mem.replaceOwned(u8, b.allocator, original, "org.aqueous.Dome", identity) catch @panic("Out of memory");
        const launcher = if (git_variant) std.mem.replaceOwned(u8, b.allocator, named, "Exec=dome", "Exec=dome-git") catch @panic("Out of memory") else named;
        const content = if (git_variant) std.mem.replaceOwned(u8, b.allocator, launcher, "<binary>dome</binary>", "<binary>dome-git</binary>") catch @panic("Out of memory") else launcher;
        const file = generated.add(entry[2], content);
        b.getInstallStep().dependOn(&b.addInstallFile(file, b.fmt("{s}/{s}.{s}", .{ entry[1], identity, entry[2] })).step);
    }
    b.installFile("resources/org.aqueous.Dome.svg", b.fmt("share/icons/hicolor/scalable/apps/{s}.svg", .{identity}));
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Launch Dome").dependOn(&run.step);
    const test_step = b.step("test", "Test metric contracts, parsers, identities and live collector lifecycle");
    for ([_][]const u8{ "src/core/model.zig", "src/collectors/linux.zig" }) |path| {
        const tm = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = true });
        // A common root permits collector tests to import the pure model.
        const tests = if (std.mem.eql(u8, path, "src/core/model.zig")) b.addTest(.{ .root_module = tm }) else blk: {
            tm.root_source_file = b.path("src/tests.zig");
            tm.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
            tm.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
            break :blk b.addTest(.{ .root_module = tm });
        };
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const test_options = b.addOptions();
    test_options.addOption(bool, "test_hooks", true);
    test_options.addOption(bool, "git_variant", false);
    const im = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    im.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    im.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    im.addOptions("build_options", test_options);
    im.addAnonymousImport("style", .{ .root_source_file = b.path("resources/style.css") });
    const ie = b.addExecutable(.{ .name = "dome-test", .root_module = im });
    const integration = b.addSystemCommand(&.{ "python3", "tests/native.py", "--binary" });
    integration.addArtifactArg(ie);
    if (b.args) |args| integration.addArgs(args);
    b.step("integration", "Run native GTK tests in a private Aqueous session").dependOn(&integration.step);
    const bm = b.createModule(.{ .root_source_file = b.path("src/benchmark.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bm.linkSystemLibrary("gtk4", .{ .use_pkg_config = .force });
    bm.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
    const benchmark = b.addExecutable(.{ .name = "dome-graph-benchmark", .root_module = bm });
    b.step("benchmark", "Measure Cairo graph drawing on a software image surface").dependOn(&b.addRunArtifact(benchmark).step);
}
