//! Optional caller-selected prebuilt mistral.rs runtime. No implicit download/version lock.
const std = @import("std");
pub fn add(b: *std.Build) void {
    const step = b.step("build-assistant-runtime", "Stage a caller-selected prebuilt mistral.rs runtime (optional)");
    const binary_option = b.option([]const u8, "assistant-runtime-binary", "Existing prebuilt mistralrs executable");
    const archive_option = b.option([]const u8, "assistant-runtime-archive", "Existing prebuilt mistral.rs release archive");
    const checksum = b.option([]const u8, "assistant-runtime-sha256", "Expected release archive SHA256");
    if ((binary_option == null) == (archive_option == null) or (archive_option != null and checksum == null) or (binary_option != null and checksum != null)) {
        step.dependOn(&b.addFail("Provide exactly one -Dassistant-runtime-binary executable or -Dassistant-runtime-archive plus -Dassistant-runtime-sha256. No runtime is downloaded automatically.").step);
        return;
    }
    if (binary_option) |path| {
        step.dependOn(&b.addInstallFile(.{ .cwd_relative = path }, "libexec/pearl/assistant/mistralrs").step);
    } else {
        const archive: std.Build.LazyPath = .{ .cwd_relative = archive_option.? };
        const verifier = b.addExecutable(.{ .name = "pearl-verify-assistant-source", .root_module = b.createModule(.{ .root_source_file = b.path("src/verify_assistant_source.zig"), .target = b.graph.host, .optimize = .safe }) });
        const verify = b.addRunArtifact(verifier);
        verify.addArg(checksum.?);
        verify.addFileArg(archive);
        const unpack = b.addSystemCommand(&.{ "tar", "--extract", "--file" });
        unpack.addFileArg(archive);
        unpack.addArg("--directory");
        const tree = unpack.addOutputDirectoryArg("source");
        unpack.step.dependOn(&verify.step);
        const staging_tool = b.addExecutable(.{ .name = "pearl-stage-assistant-runtime", .root_module = b.createModule(.{ .root_source_file = b.path("src/stage_assistant_runtime.zig"), .target = b.graph.host, .optimize = .safe }) });
        const stage = b.addRunArtifact(staging_tool);
        stage.addDirectoryArg(tree);
        const staged = stage.addOutputDirectoryArg("runtime");
        stage.step.dependOn(&unpack.step);
        step.dependOn(&b.addInstallDirectory(.{ .source_dir = staged, .install_dir = .prefix, .install_subdir = "libexec/pearl/assistant" }).step);
    }
    const files = b.addWriteFiles();
    const provenance = files.add("runtime.json", std.json.Stringify.valueAlloc(b.allocator, .{ .source_kind = if (binary_option != null) "local-binary" else "verified-archive", .source_sha256 = checksum, .backend = "cpu" }, .{}) catch @panic("OOM"));
    step.dependOn(&b.addInstallFile(provenance, "libexec/pearl/assistant/runtime.json").step);
}
