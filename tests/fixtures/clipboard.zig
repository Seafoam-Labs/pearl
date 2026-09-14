//! Private test producer: arbitrary MIME, interrupted and stalled owners.
const std = @import("std");
const wl = @import("wayland").client.wl;
const ext = @import("wayland").client.ext;
const Fixture = struct {
    registry: *wl.Registry,
    manager: ?*ext.DataControlManagerV1 = null,
    seat: ?*wl.Seat = null,
    mode: []const u8,
    payload: [:0]const u8,
    fn registryEvent(_: *wl.Registry, event: wl.Registry.Event, self: *Fixture) void {
        if (event != .global) return;
        const g = event.global;
        if (std.mem.eql(u8, std.mem.span(g.interface), "ext_data_control_manager_v1")) self.manager = self.registry.bind(g.name, ext.DataControlManagerV1, 1) catch unreachable;
        if (std.mem.eql(u8, std.mem.span(g.interface), "wl_seat") and self.seat == null) {
            self.seat = self.registry.bind(g.name, wl.Seat, 5) catch unreachable;
            self.seat.?.setListener(*Fixture, seatEvent, self);
        }
    }
    fn seatEvent(_: *wl.Seat, _: wl.Seat.Event, _: *Fixture) void {}
    fn deviceEvent(_: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, self: *Fixture) void {
        if (event == .data_offer) event.data_offer.id.setListener(*Fixture, offerEvent, self);
    }
    fn offerEvent(_: *ext.DataControlOfferV1, _: ext.DataControlOfferV1.Event, _: *Fixture) void {}
    fn sourceEvent(_: *ext.DataControlSourceV1, event: ext.DataControlSourceV1.Event, self: *Fixture) void {
        if (event != .send) return;
        const fd = event.send.fd;
        if (std.mem.eql(u8, self.mode, "stall")) return; // deliberately retain it until test kills us
        defer _ = std.c.close(fd);
        if (std.mem.eql(u8, self.mode, "vanish")) std.c._exit(0);
        if (std.mem.eql(u8, self.mode, "large")) {
            const data: [65536]u8 = @splat('x');
            for (0..6) |_| {
                if (std.c.write(fd, &data, data.len) < 0) break;
            }
            return;
        }
        if (std.mem.eql(u8, self.mode, "invalid")) {
            _ = std.c.write(fd, "\xff", 1);
            return;
        }
        if (std.mem.eql(u8, self.mode, "png")) {
            const input = std.c.open(self.payload, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c_uint, 0));
            if (input < 0) return;
            defer _ = std.c.close(input);
            var buffer: [8192]u8 = undefined;
            while (true) {
                const n = std.c.read(input, &buffer, buffer.len);
                if (n <= 0) break;
                var used: usize = 0;
                while (used < n) {
                    const out = std.c.write(fd, buffer[used..].ptr, @as(usize, @intCast(n)) - used);
                    if (out <= 0) return;
                    used += @intCast(out);
                }
            }
            return;
        }
        _ = std.c.write(fd, self.payload.ptr, self.payload.len);
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    var action: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = std.mem.zeroes(std.c.sigset_t), .flags = 0 };
    std.posix.sigaction(.PIPE, &action, null);
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    var f: Fixture = .{ .registry = try display.getRegistry(), .mode = args[1], .payload = args[2] };
    f.registry.setListener(*Fixture, Fixture.registryEvent, &f);
    if (display.roundtrip() != .SUCCESS) return error.Connection;
    const device = try f.manager.?.getDataDevice(f.seat.?);
    device.setListener(*Fixture, Fixture.deviceEvent, &f);
    const source = try f.manager.?.createDataSource();
    source.setListener(*Fixture, Fixture.sourceEvent, &f);
    source.offer(if (std.mem.eql(u8, f.mode, "png")) "image/png" else if (std.mem.eql(u8, f.mode, "unsupported")) "text/html" else "text/plain;charset=utf-8");
    if (std.mem.eql(u8, f.mode, "sensitive")) source.offer("x-kde-passwordManagerHint");
    device.setSelection(source);
    _ = display.flush();
    _ = std.c.write(1, "event=ready\n", 12);
    while (display.dispatch() == .SUCCESS) {}
}
