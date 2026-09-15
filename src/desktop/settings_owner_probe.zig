//! Private integration fixture for a second frontend. This module is reachable
//! only in builds with test_hooks; no executable or frontend protocol is added.
const std = @import("std");
const ownership = @import("../services/view_ownership.zig");
const Network = @import("../services/network.zig").Network;
const Bluetooth = @import("../services/bluetooth.zig").Bluetooth;
const Power = @import("../services/power.zig").Power;
pub const Probe = struct {
    network: ?ownership.Owner = null,
    bluetooth: ?ownership.Owner = null,
    power: ?ownership.Owner = null,
    pub fn command(self: *Probe, alloc: std.mem.Allocator, bytes: []const u8, n: *Network, b: *Bluetooth, p: *Power) ![]const u8 {
        const Request = struct { test_owner: enum { acquire, release, connect, discover, pair, wrong_answer }, service: enum { network, bluetooth, power }, path: ?[]const u8 = null };
        const parsed = try std.json.parseFromSlice(Request, alloc, bytes, .{});
        defer parsed.deinit();
        const request = parsed.value;
        switch (request.service) {
            .network => switch (request.test_owner) {
                .acquire => {
                    if (self.network == null) self.network = try n.acquireView();
                },
                .release => {
                    if (self.network) |owner| n.releaseView(owner);
                    self.network = null;
                },
                .connect => try n.connectAP(self.network orelse return error.Unavailable, n.peer.epoch, request.path orelse return error.InvalidRequest),
                .wrong_answer => {
                    // The fixture owner's token must not answer the flyout's prompt.
                    n.answer(self.network orelse return error.Unavailable, n.prompt_serial, "") catch |err| return std.json.Stringify.valueAlloc(alloc, .{ .denied = err == error.Unavailable }, .{});
                    return error.InvalidRequest;
                },
                else => return error.InvalidRequest,
            },
            .bluetooth => switch (request.test_owner) {
                .acquire => {
                    if (self.bluetooth == null) self.bluetooth = try b.acquireView();
                },
                .release => {
                    if (self.bluetooth) |owner| b.releaseView(owner);
                    self.bluetooth = null;
                },
                .discover => try b.discover(self.bluetooth orelse return error.Unavailable, b.peer.epoch, request.path orelse return error.InvalidRequest),
                .pair => try b.request(self.bluetooth orelse return error.Unavailable, b.peer.epoch, request.path orelse return error.InvalidRequest, .pair),
                .wrong_answer => {
                    b.answer(self.bluetooth orelse return error.Unavailable, b.prompt_serial, true, "") catch |err| return std.json.Stringify.valueAlloc(alloc, .{ .denied = err == error.Unavailable }, .{});
                    return error.InvalidRequest;
                },
                else => return error.InvalidRequest,
            },
            .power => switch (request.test_owner) {
                .acquire => {
                    if (self.power == null) self.power = try p.acquireView();
                },
                .release => {
                    if (self.power) |owner| p.releaseView(owner);
                    self.power = null;
                },
                else => return error.InvalidRequest,
            },
        }
        return std.json.Stringify.valueAlloc(alloc, .{ .network = n.interest.count(), .bluetooth = b.interest.count(), .power = p.interest.count(), .power_polling = p.poll_source != 0 }, .{});
    }
};
