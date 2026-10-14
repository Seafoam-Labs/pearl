//! Optional, checksum-pinned CPU runtime target. Upstream CMake is the necessary
//! C/C++ inference dependency boundary; all Pearl build orchestration is Zig.
const std = @import("std");
pub const commit = "d81235049384534c167caea52b85a694f6103d14";
pub const archive_sha256 = "6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14";
pub fn add(b: *std.Build) void {
    const step = b.step("build-assistant-runtime", "Download, verify, build and stage pinned CPU llama.cpp (optional)");
    const archive_option = b.option([]const u8, "assistant-runtime-archive", "Use this checksum-verified llama.cpp archive instead of downloading");
    const archive: std.Build.LazyPath = if (archive_option) |path| .{ .cwd_relative = path } else blk: {
        const download = b.addSystemCommand(&.{ "curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "https://github.com/ggml-org/llama.cpp/archive/" ++ commit ++ ".tar.gz", "-o" });
        break :blk download.addOutputFileArg("llama.tar.gz");
    };
    const verifier = b.addExecutable(.{ .name = "pearl-verify-assistant-source", .root_module = b.createModule(.{ .root_source_file = b.path("src/verify_assistant_source.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    const verify = b.addRunArtifact(verifier);
    verify.addArg(archive_sha256);
    verify.addFileArg(archive);
    const unpack = b.addSystemCommand(&.{ "tar", "--extract", "--strip-components=1", "--file" });
    unpack.addFileArg(archive);
    unpack.addArg("--directory");
    const source = unpack.addOutputDirectoryArg("source");
    unpack.step.dependOn(&verify.step);
    const configure = b.addSystemCommand(&.{ "cmake", "-S" });
    configure.addDirectoryArg(source);
    configure.addArg("-B");
    const build = configure.addOutputDirectoryArg("build");
    configure.addArgs(&.{ "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=ON", "-DGGML_NATIVE=OFF", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON", "-DGGML_CUDA=OFF", "-DGGML_VULKAN=OFF", "-DGGML_METAL=OFF", "-DLLAMA_BUILD_SERVER=ON", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_UI=OFF", "-DLLAMA_USE_PREBUILT_UI=OFF", "-DCMAKE_BUILD_RPATH=$ORIGIN", "-DCMAKE_INSTALL_RPATH=$ORIGIN", "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON" });
    const compile = b.addSystemCommand(&.{ "cmake", "--build" });
    compile.addDirectoryArg(build);
    compile.addArgs(&.{ "--target", "llama-server", "--parallel", "2" });
    const install = b.addInstallDirectory(.{ .source_dir = build.path(b, "bin"), .install_dir = .prefix, .install_subdir = "libexec/pearl/assistant" });
    install.step.dependOn(&compile.step);
    step.dependOn(&install.step);
    // InstallDir skips symlinks. Materialize the exact SONAME entries as well,
    // so the private runtime works without the build tree or LD_LIBRARY_PATH.
    for ([_][]const u8{ "libggml-base.so.0", "libggml.so.0", "libllama-common.so.0", "libllama.so.0", "libmtmd.so.0" }) |name| {
        const soname = b.addInstallFile(build.path(b, b.fmt("bin/{s}", .{name})), b.fmt("libexec/pearl/assistant/{s}", .{name}));
        soname.step.dependOn(&compile.step);
        step.dependOn(&soname.step);
    }
    const license = b.addInstallFile(source.path(b, "LICENSE"), "share/licenses/pearl-assistant-runtime/llama.cpp-LICENSE");
    step.dependOn(&license.step);
    const manifest = b.addWriteFiles();
    const pin = manifest.add("runtime.json", "{\"version\":\"v0.6.0\",\"commit\":\"" ++ commit ++ "\",\"source_sha256\":\"" ++ archive_sha256 ++ "\",\"cpu_only\":true}\n");
    step.dependOn(&b.addInstallFile(pin, "libexec/pearl/assistant/runtime.json").step);
}
