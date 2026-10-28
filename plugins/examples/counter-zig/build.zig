const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk = b.option([]const u8, "sdk-dir", "Generated WIT C bindings directory") orelse @panic("provide -Dsdk-dir");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const translated: @import("translate_c").Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "plugin_c",
        .c_source_file = .{ .cwd_relative = b.pathJoin(&.{ sdk, "plugin.h" }) },
        .target = target,
        .optimize = .small,
    });
    const root = b.createModule(.{ .root_source_file = b.path("plugin.zig"), .target = target, .optimize = .small, .link_libc = true });
    root.addImport("plugin_c", translated.mod);
    const object = b.addObject(.{ .name = "counter-zig", .root_module = root });
    b.getInstallStep().dependOn(&b.addInstallFile(object.getEmittedBin(), "counter-zig.o").step);
}
