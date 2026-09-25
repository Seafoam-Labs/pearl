const std = @import("std");
const glib = @import("glib2");
const runner = @import("preview_runner.zig");
const providers = @import("preview_providers.zig");
const metadata = @import("../core/preview_video_metadata.zig");
const a = std.heap.c_allocator;
pub fn render(fd: c_int, edge: u32, timeout: u32) runner.Result {
    const deadline = glib.getMonotonicTime() + @as(i64, timeout) * 1000;
    const probe = runner.run(providers.tool("ffprobe"), &.{ "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,avi", "-probesize", "5242880", "-analyzeduration", "2000000", "-threads", "2", "-select_streams", "V", "-show_entries", "format=duration:stream=index,codec_type,width,height,duration,sample_aspect_ratio,color_transfer:stream_disposition=attached_pic", "-of", "json", "/input/source" }, fd, @min(timeout, 2000), 65536);
    defer probe.deinit();
    if (probe.status != .ok) return .{ .status = probe.status };
    const selection = metadata.select(a, probe.bytes) catch return .{ .status = .unsupported };
    var mapping_buffer: [32]u8 = undefined;
    const mapping = std.fmt.bufPrintZ(&mapping_buffer, "0:{d}", .{selection.index}) catch unreachable;
    var filter_buffer: [512]u8 = undefined;
    // scale computes square-pixel display geometry after FFmpeg's autorotation.
    // Both dimensions are bounded and small videos retain their display size.
    const filter = std.fmt.bufPrintZ(&filter_buffer, "scale=w='max(1,trunc(iw*sar*min(1,min({d}/(iw*sar),{d}/ih))))':h='max(1,trunc(ih*min(1,min({d}/(iw*sar),{d}/ih))))',setsar=1", .{ edge, edge, edge, edge }) catch unreachable;
    var position = selection.time;
    for (0..2) |attempt| {
        const remaining = @divTrunc(deadline - glib.getMonotonicTime(), 1000);
        if (remaining <= 0) return .{ .status = .timeout };
        var seek_buffer: [64]u8 = undefined;
        const seek = std.fmt.bufPrintZ(&seek_buffer, "{d:.6}", .{position}) catch unreachable;
        const result = runner.run(providers.tool("ffmpeg"), &.{ "-nostdin", "-v", "error", "-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,avi", "-probesize", "5242880", "-analyzeduration", "2000000", "-threads", "2", "-hwaccel", "none", "-ss", seek, "-i", "/input/source", "-map", mapping, "-an", "-sn", "-dn", "-frames:v", "1", "-filter_threads", "1", "-vf", filter, "-threads", "1", "-c:v", "png", "-pix_fmt", "rgba", "-f", "image2pipe", "-protocol_whitelist", "pipe", "pipe:1" }, fd, @intCast(remaining), 20 * 1024 * 1024);
        if (result.status != .ok or result.bytes.len != 0 or position == 0 or attempt == 1) return result;
        result.deinit();
        position = 0;
    }
    return .{ .status = .failed };
}
