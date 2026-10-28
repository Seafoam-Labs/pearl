const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
        @panic("This probe is pinned to Zig 0.17.0");
    const prefix = b.option([]const u8, "wasmtime-prefix", "Extracted Wasmtime 48.0.2 C API directory") orelse @panic("provide -Dwasmtime-prefix");
    const target = b.standardTargetOptions(.{});
    const translated = @import("translate_c").Translator.init(b.dependency("translate_c", .{}), .{
        .c_source_file = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include/wasmtime.h" }) },
        .target = target,
        .optimize = .safe,
    });
    translated.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .safe,
        .link_libc = true,
    });
    module.addImport("wasmtime", translated.mod);
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    module.addRPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    module.linkSystemLibrary("wasmtime", .{});
    const exe = b.addExecutable(.{ .name = "pearl-wasm-probe", .root_module = module });
    const run = b.addRunArtifact(exe);
    b.step("probe", "Run isolated Component Model interoperability checks").dependOn(&run.step);
}
