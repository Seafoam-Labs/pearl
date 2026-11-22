//! Stage the prebuilt mistral.rs server binary without a release-specific file list.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Arguments;
    const io = init.io;
    var source = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer source.close(io);
    try std.Io.Dir.cwd().createDirPath(io, args[2]);
    var target = try std.Io.Dir.cwd().openDir(io, args[2], .{});
    defer target.close(io);
    var iterator = source.iterate();
    var server = false;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, "mistralrs")) server = true else if (!std.mem.eql(u8, entry.name, "LICENSE")) continue;
        try source.copyFile(entry.name, target, entry.name, io, .{});
    }
    if (!server) return error.MistralrsBinaryMissing;
}
