//! Optional caller-selected upstream build. No implicit download/version lock.
const std = @import("std");
pub fn add(b: *std.Build) void {
    const step = b.step("build-assistant-runtime", "Build a caller-selected llama.cpp source tree/archive (optional)");
    const source_option = b.option([]const u8, "assistant-runtime-source", "Existing llama.cpp source directory");
    const archive_option = b.option([]const u8, "assistant-runtime-archive", "Existing llama.cpp source archive");
    const checksum = b.option([]const u8, "assistant-runtime-sha256", "Expected source archive SHA256");
    const backend = b.option(enum { cpu, vulkan, cuda }, "assistant-runtime-backend", "Inference backend (CPU remains available)") orelse .cpu;
    if ((source_option == null) == (archive_option == null) or (archive_option != null and checksum == null) or (source_option != null and checksum != null)) {
        step.dependOn(&b.addFail("Provide exactly one -Dassistant-runtime-source directory or -Dassistant-runtime-archive plus -Dassistant-runtime-sha256. No source is downloaded automatically.").step);
        return;
    }
    const source: std.Build.LazyPath = if (source_option) |path| .{ .cwd_relative = path } else blk: {
        const archive: std.Build.LazyPath = .{ .cwd_relative = archive_option.? };
        const verifier = b.addExecutable(.{ .name = "pearl-verify-assistant-source", .root_module = b.createModule(.{ .root_source_file = b.path("src/verify_assistant_source.zig"), .target = b.graph.host, .optimize = .safe }) });
        const verify = b.addRunArtifact(verifier);
        verify.addArg(checksum.?);
        verify.addFileArg(archive);
        const unpack = b.addSystemCommand(&.{ "tar", "--extract", "--strip-components=1", "--file" });
        unpack.addFileArg(archive);
        unpack.addArg("--directory");
        const tree = unpack.addOutputDirectoryArg("source");
        unpack.step.dependOn(&verify.step);
        break :blk tree;
    };
    const configure = b.addSystemCommand(&.{ "cmake", "-S" });
    configure.addDirectoryArg(source);
    configure.addArg("-B");
    const build = configure.addOutputDirectoryArg("build");
    configure.addArgs(&.{ "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=ON", "-DGGML_NATIVE=OFF", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON", if (backend == .cuda) "-DGGML_CUDA=ON" else "-DGGML_CUDA=OFF", if (backend == .vulkan) "-DGGML_VULKAN=ON" else "-DGGML_VULKAN=OFF", "-DGGML_METAL=OFF", "-DLLAMA_BUILD_SERVER=ON", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_UI=OFF", "-DLLAMA_USE_PREBUILT_UI=OFF", "-DCMAKE_BUILD_RPATH=$ORIGIN", "-DCMAKE_INSTALL_RPATH=$ORIGIN", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON" });
    const compile = b.addSystemCommand(&.{ "cmake", "--build" });
    compile.addDirectoryArg(build);
    compile.addArgs(&.{ "--target", "llama-server", "--parallel", "2" });
    const staging_tool = b.addExecutable(.{ .name = "pearl-stage-assistant-runtime", .root_module = b.createModule(.{ .root_source_file = b.path("src/stage_assistant_runtime.zig"), .target = b.graph.host, .optimize = .safe }) });
    const stage = b.addRunArtifact(staging_tool);
    stage.addDirectoryArg(build.path(b, "bin"));
    const staged = stage.addOutputDirectoryArg("runtime");
    stage.addArg(@tagName(backend));
    stage.step.dependOn(&compile.step);
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = staged, .install_dir = .prefix, .install_subdir = "libexec/pearl/assistant" }).step);
    step.dependOn(&b.addInstallFile(source.path(b, "LICENSE"), "share/licenses/pearl-assistant-runtime/llama.cpp-LICENSE").step);
    const files = b.addWriteFiles();
    const provenance = files.add("runtime.json", std.json.Stringify.valueAlloc(b.allocator, .{ .source_kind = if (source_option != null) "local-source-tree" else "verified-archive", .source_sha256 = checksum, .backend = @tagName(backend) }, .{}) catch @panic("OOM"));
    step.dependOn(&b.addInstallFile(provenance, "libexec/pearl/assistant/runtime.json").step);
}
