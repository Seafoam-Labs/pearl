//! Standalone integration driver, never linked into Pearl or installed by default.
const std = @import("std");
const glib = @import("glib2");
const unix = @import("glibunix2");
const adapter = @import("aqueous/client.zig");
const a = std.heap.c_allocator;
const Driver = struct { client: adapter.Client = undefined, loop: *glib.MainLoop, input: @import("aqueous/codec.zig").Framer };
fn event(context: *anyopaque, value: adapter.Event) void {
    const d: *Driver = @ptrCast(@alignCast(context));
    switch (value) {
        .availability => |v| std.debug.print("availability={s}\n", .{@tagName(v)}),
        .fault => |v| std.debug.print("fault={s}\n", .{v}),
        .state => std.debug.print("state={s}:{d}\n", .{ d.client.model.sequence, d.client.model.entities.count() }),
        .completion => |v| std.debug.print("completion={d}:{s}:{s}:{s}\n", .{ v.ticket, @tagName(v.status), v.detail, v.sequence }),
        .icons => std.debug.print("icons\n", .{}),
    }
}
const Input = struct { action: ?adapter.Action = null, icon: ?adapter.IconKey = null, count: u32 = 1, quit: bool = false, metrics: bool = false };
fn command(d: *Driver, bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Input, a, bytes, .{});
    defer parsed.deinit();
    const p = parsed.value;
    if (p.quit) {
        d.loop.quit();
        return;
    }
    if (p.metrics) std.debug.print("metrics=timer:{},queued:{d},cache:{d},ready:{}\n", .{ d.client.timer != null, d.client.queue.items.len, d.client.cache.entries.items.len, d.client.model.ready });
    if (p.count > 100) return error.Invalid;
    for (0..p.count) |_| {
        if (p.action) |v| {
            const ticket = d.client.enqueue(v) catch |err| {
                std.debug.print("enqueue-error={s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("queued={d}\n", .{ticket});
        }
        if (p.icon) |v| {
            const result = d.client.icon(v) catch |err| {
                std.debug.print("icon-error={s}\n", .{@errorName(err)});
                continue;
            };
            std.debug.print("icon-hit={}\n", .{result != null});
            if (result) |pixels| std.debug.print("pixel-crc={x}\n", .{std.hash.Crc32.hash(pixels.getPixels()[0..pixels.getByteLength()])});
        }
    }
}
fn input(_: c_int, _: glib.IOCondition, context: ?*anyopaque) callconv(.c) c_int {
    const d: *Driver = @ptrCast(@alignCast(context.?));
    var buffer: [4096]u8 = undefined;
    const n = std.os.linux.read(0, &buffer, buffer.len);
    if (n == 0 or n > buffer.len) {
        d.loop.quit();
        return 1;
    }
    var remaining: []const u8 = buffer[0..n];
    while (remaining.len > 0) {
        const part = d.input.push(remaining) catch {
            d.loop.quit();
            return 1;
        };
        remaining = remaining[part.consumed..];
        if (part.frame) |bytes| command(d, bytes) catch |err| std.debug.print("input-error={s}\n", .{@errorName(err)});
    }
    return 1;
}
pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    var d: Driver = .{ .loop = glib.MainLoop.new(null, 0), .input = try @import("aqueous/codec.zig").Framer.init(a, 65536) };
    defer d.loop.unref();
    defer d.input.deinit();
    d.client = try adapter.Client.init(env.get("AQUEOUS_SOCKET").?, env.get("XDG_RUNTIME_DIR").?, &d, event);
    defer d.client.deinit();
    if (env.get("PEARL_PROBE_DEADLINE_MS")) |v| d.client.request_ms = try std.fmt.parseInt(u32, v, 10);
    if (env.get("PEARL_PROBE_SUBSCRIPTION_MS")) |v| d.client.subscription_ms = try std.fmt.parseInt(u32, v, 10);
    d.client.start();
    if (env.get("PEARL_PROBE_WRITE_CHUNK")) |v| {
        const chunk = try std.fmt.parseInt(usize, v, 10);
        if (chunk == 0) return error.Invalid;
        d.client.request.wire.write_chunk = chunk;
        d.client.events.wire.write_chunk = chunk;
    }
    if (env.get("PEARL_PROBE_SEND_BUFFER")) |v| {
        const size = try std.fmt.parseInt(c_int, v, 10);
        if (d.client.request.wire.socket.?.setOption(1, 7, size, null) == 0) return error.SocketOption;
    }
    const source = unix.fdAdd(0, .{ .in = true, .hup = true }, input, &d);
    defer _ = glib.Source.remove(source);
    d.loop.run();
}

test {
    _ = adapter;
    _ = @import("aqueous/icons.zig");
    _ = @import("aqueous/transport.zig");
}
