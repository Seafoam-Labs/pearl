//! Isolated software-rendering benchmark; no display or hardware acceleration claim.
const std = @import("std");
const c = @import("platform/c.zig").c;
const History = @import("core/model.zig").History;
const Graph = @import("ui/graph.zig").Graph;
pub fn main() void {
    var history: History = .{};
    for (0..1202) |i| {
        const value = 50 + 40 * @sin(@as(f64, @floatFromInt(i)) / 25);
        history.add(@intCast(i * 500000), if (i % 101 == 0) null else value, value / 2);
    }
    var duration: i64 = 600000000;
    var light = false;
    var graph: Graph = .{ .history = &history, .duration = &duration, .light = &light, .fixed = 100 };
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 900, 220).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    var elapsed: [500]i64 = undefined;
    for (&elapsed) |*sample| {
        const started = c.g_get_monotonic_time();
        Graph.draw(null, cr, 900, 220, &graph);
        sample.* = c.g_get_monotonic_time() - started;
    }
    std.mem.sort(i64, &elapsed, {}, std.sort.asc(i64));
    c.g_print("{\"renderer\":\"Cairo ARGB32 image surface\",\"width\":900,\"height\":220,\"series\":2,\"points\":1202,\"iterations\":500,\"median_us\":%lld,\"p95_us\":%lld,\"cairo_status\":%d}\n", @as(c_longlong, elapsed[250]), @as(c_longlong, elapsed[475]), c.cairo_status(cr));
    if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) std.process.exit(1);
}
