//! Preserve actual backend/SONAME files without a release-specific library list.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 4) return error.Arguments;
    const io = init.io;
    var source = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer source.close(io);
    if (args.len == 4 and !std.mem.eql(u8, args[3], "cpu")) {
        const cache = try source.readFileAlloc(io, "../CMakeCache.txt", init.arena.allocator(), .limited(4 * 1024 * 1024));
        const expected = if (std.mem.eql(u8, args[3], "vulkan")) "GGML_VULKAN:BOOL=ON" else if (std.mem.eql(u8, args[3], "cuda")) "GGML_CUDA:BOOL=ON" else return error.InvalidBackend;
        if (std.mem.indexOf(u8, cache, expected) == null) return error.RequestedBackendNotConfigured;
    }
    try std.Io.Dir.cwd().createDirPath(io, args[2]);
    var target = try std.Io.Dir.cwd().openDir(io, args[2], .{});
    defer target.close(io);
    var iterator = source.iterate();
    var server = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, "llama-server")) server = true else if (std.mem.indexOf(u8, entry.name, ".so") == null) continue;
        try source.copyFile(entry.name, target, entry.name, io, .{});
    }
    if (!server) return error.LlamaServerBuildMissing;
}
