const std = @import("std");
const coral = @import("build.zig");

pub fn build(b: *std.Build) void {
    coral.build(b);
    var found: ?*std.Build.Module = null;
    var it = b.modules.iterator();
    while (it.next()) |entry| {
        const mod = entry.value_ptr.*;
        if (mod.import_table.get("pearl_app_c") != null and mod.import_table.get("previews") != null and mod.import_table.get("file_chooser") != null) {
            found = mod;
            break;
        }
    }
    const src = found orelse @panic("main module not found");
    const tm = b.createModule(.{ .root_source_file = b.path("src/m4_verify_root.zig"), .target = src.resolved_target, .optimize = src.optimize, .link_libc = true });
    for ([_][]const u8{ "gtk4", "gtksourceview-5", "enchant-2" }) |lib| tm.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    tm.addCSourceFile(.{ .file = b.path("src/spelling/pango_words.c"), .flags = &.{"-std=c11"} });
    var iit = src.import_table.iterator();
    while (iit.next()) |e| tm.addImport(e.key_ptr.*, e.value_ptr.*);
    const tests = b.addTest(.{ .root_module = tm });
    const run = b.addRunArtifact(tests);
    b.step("m4-check", "Type-check M4 controllers").dependOn(&run.step);
}
