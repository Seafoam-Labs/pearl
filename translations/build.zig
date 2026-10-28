//! Standalone catalog build: no GTK, application, or optional runtime dependencies.
const std = @import("std");
pub fn build(b: *std.Build) void {
    defer @import("pearl_ffi").attach(b, b.path("../bindings/c"));
    const source_archive = b.addSystemCommand(&.{ "tar", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=zig-pkg", "-czf" });
    // tar reads whole source directories outside Zig's file-argument dependency
    // tracking. Never reuse an archive after a translator edits its inputs.
    source_archive.has_side_effects = true;
    const archive = source_archive.addOutputFileArg("pearl-translations.tar.gz");
    source_archive.addArgs(&.{ "-C", (b.root.join(b.allocator, "..") catch @panic("OOM")).toString(b.allocator) catch @panic("OOM"), "--transform=s,^,pearl-translations/,", "translations", "src/i18n", "src/i18n_tool.zig", "src/i18n_probe.zig", "src/language_pack_tool.zig", "src/testing/repeat.zig", "bindings/c", "tests/test_language_packs.py" });
    const install_archive = b.addInstallFile(archive, "pearl-translations.tar.gz");
    b.step("source", "Export catalog-only sources for independent package releases").dependOn(&install_archive.step);
    const extractor = b.addExecutable(.{ .name = "pearl-extract-messages", .root_module = b.createModule(.{ .root_source_file = b.path("../src/i18n_tool.zig"), .target = b.graph.host, .optimize = .safe }) });
    for ([_][]const u8{ "extract", "check-templates" }) |step_name| {
        const run = b.addRunArtifact(extractor);
        run.setCwd(b.path(".."));
        run.addArg(if (std.mem.eql(u8, step_name, "extract")) "extract" else "check");
        run.has_side_effects = true;
        b.step(step_name, "Extract or verify catalog templates and pinned schema mappings").dependOn(&run.step);
    }
    const extractor_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("../src/i18n_tool.zig"), .target = b.graph.host, .optimize = .safe }) });
    const language = b.option([]const u8, "language", "Language to package") orelse "de";
    for (language) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '@' and c != '-') @panic("Invalid language identifier");
    const metadata_bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, (b.root.join(b.allocator, b.fmt("{s}/language.json", .{language})) catch @panic("OOM")).toString(b.allocator) catch @panic("OOM"), b.allocator, .limited(16384)) catch @panic("Missing language metadata");
    const Metadata = struct { native_name: []const u8, direction: []const u8 = "ltr", revision: []const u8 };
    const metadata = std.json.parseFromSliceLeaky(Metadata, b.allocator, metadata_bytes, .{}) catch @panic("Invalid language metadata");
    const validator = b.addExecutable(.{ .name = "pearl-language-pack", .root_module = b.createModule(.{ .root_source_file = b.path("../src/language_pack_tool.zig"), .target = b.graph.host, .optimize = .safe }) });
    const validate = b.addRunArtifact(validator);
    validate.addArgs(&.{ language, metadata.native_name, metadata.direction, metadata.revision });
    const manifest = validate.addOutputFileArg(b.fmt("{s}.json", .{language}));
    const domain_names = [_][]const u8{ "pearl", "pearl-greeter", "pearl-lock", "pearl-files", "pearl-agent", "phyto", "dome", "coral" };
    for (domain_names) |domain| {
        const compile = b.addSystemCommand(&.{ "msgfmt", "--check", "-o" });
        const catalog = compile.addOutputFileArg(b.fmt("{s}.mo", .{domain}));
        compile.addFileArg(b.path(b.fmt("{s}/{s}.po", .{ language, domain })));
        validate.addArg(domain);
        validate.addFileArg(catalog);
        validate.addFileArg(b.path(b.fmt("{s}.pot", .{domain})));
        const install = b.addInstallFile(catalog, b.fmt("share/locale/{s}/LC_MESSAGES/{s}.mo", .{ language, domain }));
        install.step.dependOn(&validate.step);
        b.getInstallStep().dependOn(&install.step);
    }
    b.getInstallStep().dependOn(&b.addInstallFile(manifest, b.fmt("share/pearl/language-packs/{s}.json", .{language})).step);
    b.installFile("COPYING", b.fmt("share/licenses/pearl-lang-{s}/COPYING", .{language}));
    b.installFile("CREDITS", b.fmt("share/doc/pearl-lang-{s}/CREDITS", .{language}));
    b.step("check", "Validate catalogs, metadata, and placeholders").dependOn(&validate.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("../src/i18n/tests.zig"), .target = b.graph.host, .optimize = .safe, .link_libc = true }) });
    const test_step = b.step("test", "Test locale policy, catalogs, extraction, plurals, and formatting");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(extractor_tests).step);
    const runtime = b.addModule("pearl_i18n", .{ .root_source_file = b.path("../src/i18n/runtime.zig"), .target = b.graph.host, .optimize = .safe, .link_libc = true });
    const options = b.addOptions();
    options.addOptionPathUntracked("prefix", .{ .relative = .{ .base = .install_prefix, .sub_path = "" } });
    options.addOptionPathUntracked("system_config", .{ .relative = .{ .base = .install_prefix, .sub_path = "test-system-config.json" } });
    runtime.addOptions("i18n_options", options);
    const runtime_tests = b.addTest(.{ .root_module = runtime });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const probe_module = b.createModule(.{ .root_source_file = b.path("../src/i18n_probe.zig"), .target = b.graph.host, .optimize = .safe, .link_libc = true });
    probe_module.addImport("i18n", runtime);
    const probe = b.addExecutable(.{ .name = "pearl-language-probe", .root_module = probe_module });
    const check = b.addSystemCommand(&.{"python3"});
    check.addFileArg(b.path("../tests/test_language_packs.py"));
    check.addArg("--probe");
    check.addArtifactArg(probe);
    check.addArg("--prefix");
    check.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "" } });
    check.step.dependOn(b.getInstallStep());
    b.step("test-runtime", "Test language pack installation and removal under a private /tmp prefix").dependOn(&check.step);
}
