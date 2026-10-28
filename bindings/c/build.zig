//! Header translation for Pearl-owned C ABI boundaries. No library implementation is copied.
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(_: *std.Build) void {}

/// Attach ABI modules after callers have declared their system libraries. Pure
/// test roots acquire only libc headers, keeping external dependencies optional.
pub fn attach(b: *std.Build, headers: std.Build.LazyPath) void {
    var cache: std.StringHashMap(*std.Build.Module) = .init(b.allocator);
    defer cache.deinit();
    const strings = b.createModule(.{ .root_source_file = headers.path(b, "../../src/testing/repeat.zig") });
    const modules = b.modules.values();
    for (modules) |m| {
        const target = m.resolved_target orelse b.graph.host;
        const optimize = m.optimize orelse .debug;
        m.addImport("test_strings", strings);
        const key = b.fmt("{s}-{t}-{s}-{x}", .{ target.result.zigTriple(b.allocator) catch @panic("OOM"), optimize, target.result.cpu.model.name, std.hash.Wyhash.hash(0, std.mem.asBytes(&target.result.cpu.features)) });
        const libc_module = cache.get(key) orelse blk: {
            const libc: Translator = .init(b.dependency("translate_c", .{}), .{
                .name = "pearl_libc",
                .c_source_file = headers.path(b, "libc.h"),
                .target = target,
                .optimize = optimize,
            });
            cache.put(key, libc.mod) catch @panic("OOM");
            break :blk libc.mod;
        };
        m.addImport("pearl_libc", libc_module);
        for ([_][2][]const u8{
            .{ "libcurl", "curl" }, .{ "libarchive", "archive" },
            .{ "libpng", "png" },   .{ "libxml-2.0", "xml" },
        }) |entry| {
            for (m.link_objects.items) |object| {
                if (object == .system_lib and std.mem.eql(u8, object.system_lib.name, entry[0])) {
                    const lib_key = b.fmt("{s}-{s}", .{ key, entry[1] });
                    const lib_module = cache.get(lib_key) orelse blk: {
                        const translated: Translator = .init(b.dependency("translate_c", .{}), .{
                            .name = b.fmt("pearl_{s}", .{entry[1]}),
                            .c_source_file = headers.path(b, b.fmt("{s}.h", .{entry[1]})),
                            .target = target,
                            .optimize = optimize,
                            .link_system_libs = &.{.{ .name = entry[0] }},
                        });
                        cache.put(lib_key, translated.mod) catch @panic("OOM");
                        break :blk translated.mod;
                    };
                    m.addImport(b.fmt("pearl_{s}", .{entry[1]}), lib_module);
                    break;
                }
            }
        }
    }
}
