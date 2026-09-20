//! Generation-bound native warming on GTK's connection. GTK owns socket dispatch.
const std = @import("std");
const gdk = @import("gdk4");
const object = @import("gobject2");
const backend = @import("gdkwayland4");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
const a = std.heap.c_allocator;
extern fn gdk_wayland_monitor_get_wl_output(*gdk.Monitor) ?*wl.Output;
pub const State = enum { unavailable, busy, pending, committed, restoring, failed };
pub const Output = struct {
    control: *Control,
    wl_output: *wl.Output,
    observation: *aq.OutputWarmingOutputV1,
    lease: ?*aq.OutputWarmingLeaseV1 = null,
    generation: u64 = 0,
    pending_generation: u64 = 0,
    reason_code: u32 = 1,
    pending_reason: u32 = 1,
    committed_kelvin: u32 = 0,
    pending_committed: u32 = 0,
    request_id: u32 = 0,
    in_flight: u32 = 0,
    sent_kelvin: u32 = 0,
    denied_generation: ?u64 = null,
    acquired: bool = false,
    releasing: bool = false,
    seen: bool = false,
    state: State = .unavailable,
    pub fn available(self: *const Output) bool {
        return self.reason_code == 0 or (self.reason_code == 5 and self.acquired and !self.releasing);
    }
    pub fn reason(self: *const Output) []const u8 {
        return switch (self.reason_code) {
            0 => "Eligible",
            1 => "OutputPathUnqualified",
            2 => "HdrOutputUnsupported",
            3 => "CalibrationUnknown",
            4 => "OutputInactive",
            5 => if (self.acquired) "Owned" else "ColorServiceBusy",
            6 => "StaleColorGeneration",
            7 => "OutputRemoved",
            8 => "RestoringBaseline",
            9 => "UnsupportedColorPath",
            10 => "InvalidTemperature",
            11 => "OutputCommitFailed",
            12 => "ColorStateTransition",
            else => "OutputColorEligibilityUnavailable",
        };
    }
    fn dropLease(self: *Output) void {
        if (self.lease) |lease| lease.destroy();
        self.lease = null;
        self.acquired = false;
        self.releasing = false;
        self.in_flight = 0;
        self.sent_kelvin = 0;
    }
    fn serial(self: *Output) ?u32 {
        if (self.request_id == std.math.maxInt(u32)) {
            self.dropLease();
            self.denied_generation = self.generation;
            self.state = .failed;
            return null;
        }
        self.request_id += 1;
        return self.request_id;
    }
    fn reconcile(self: *Output) void {
        if (!self.control.wanted) {
            if (self.acquired and !self.releasing) {
                const id = self.serial() orelse return;
                self.lease.?.release(id);
                self.in_flight = id;
                self.releasing = true;
                self.state = .restoring;
            }
            return;
        }
        if (self.lease == null) {
            if (self.reason_code != 0 or self.generation == 0 or self.denied_generation == self.generation) return;
            self.lease = self.observation.acquire(@truncate(self.generation >> 32), @truncate(self.generation)) catch {
                self.state = .failed;
                return;
            };
            self.lease.?.setListener(*Output, leaseEvent, self);
            self.request_id = 0;
            self.state = .pending;
        } else if (self.acquired and !self.releasing and self.in_flight == 0 and self.sent_kelvin != self.control.kelvin and self.available()) {
            const id = self.serial() orelse return;
            self.lease.?.set(@truncate(self.generation >> 32), @truncate(self.generation), id, self.control.kelvin);
            self.sent_kelvin = self.control.kelvin;
            self.in_flight = id;
            self.state = .pending;
        }
    }
    fn event(_: *aq.OutputWarmingOutputV1, ev: aq.OutputWarmingOutputV1.Event, self: *Output) void {
        switch (ev) {
            .state => |s| {
                self.pending_generation = (@as(u64, s.generation_hi) << 32) | s.generation_lo;
                self.pending_reason = @bitCast(@intFromEnum(s.reason));
                self.pending_committed = s.committed_kelvin;
            },
            .done => {
                if (self.reason_code == 5 and self.pending_reason == 0) self.denied_generation = null;
                self.generation = self.pending_generation;
                self.reason_code = self.pending_reason;
                self.committed_kelvin = self.pending_committed;
                if (self.reason_code == 7) {
                    self.dropLease();
                    self.state = .unavailable;
                }
                if (self.lease == null) self.state = if (self.reason_code == 5) .busy else if (self.reason_code == 8) .restoring else .unavailable;
                self.reconcile();
                self.control.notify();
            },
        }
    }
    fn leaseEvent(_: *aq.OutputWarmingLeaseV1, ev: aq.OutputWarmingLeaseV1.Event, self: *Output) void {
        switch (ev) {
            .acquired => |v| {
                self.generation = (@as(u64, v.generation_hi) << 32) | v.generation_lo;
                self.acquired = true;
            },
            .denied => |v| {
                self.reason_code = @bitCast(@intFromEnum(v.reason));
                self.denied_generation = self.generation;
                self.dropLease();
                self.state = if (self.reason_code == 5) .busy else .unavailable;
            },
            .revoked => |v| {
                self.reason_code = @bitCast(@intFromEnum(v.reason));
                self.denied_generation = self.generation;
                self.dropLease();
                self.state = .unavailable;
            },
            .result => |v| {
                if (v.request_id != self.in_flight) return;
                self.in_flight = 0;
                if (v.result == .committed) {
                    self.committed_kelvin = v.kelvin;
                    if (self.releasing) {
                        self.dropLease();
                        self.state = .unavailable;
                    } else self.state = .committed;
                } else {
                    self.reason_code = @bitCast(@intFromEnum(v.reason));
                    self.denied_generation = self.generation;
                    self.dropLease();
                    self.state = .failed;
                }
            },
        }
        self.reconcile();
        self.control.notify();
    }
};
pub const Control = struct {
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    registry: ?*wl.Registry = null,
    manager: ?*aq.OutputWarmingManagerV1 = null,
    global: ?u32 = null,
    outputs: [16]?*Output = @splat(null),
    wanted: bool = false,
    kelvin: u32 = 4500,
    pub fn start(self: *Control) !void {
        const wayland = object.ext.cast(backend.WaylandDisplay, self.display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay().?);
        self.registry = try connection.getRegistry();
        self.registry.?.setListener(*Control, registryEvent, self);
        self.display.flush();
    }
    pub fn stop(self: *Control) void {
        for (&self.outputs) |*slot| if (slot.*) |o| {
            o.dropLease();
            o.observation.destroy();
            a.destroy(o);
            slot.* = null;
        };
        if (self.manager) |m| m.destroy();
        self.manager = null;
        self.global = null;
        if (self.registry) |r| @as(*wl.Proxy, @ptrCast(r)).destroy();
        self.registry = null;
        self.display.flush();
    }
    fn notify(self: *Control) void {
        self.display.flush();
        self.changed(self.context);
    }
    pub fn find(self: *Control, monitor: *gdk.Monitor) ?*Output {
        if (self.manager == null) return null;
        const w = gdk_wayland_monitor_get_wl_output(monitor) orelse return null;
        for (self.outputs) |slot| if (slot) |o| {
            if (o.wl_output == w) return o;
        };
        return null;
    }
    pub fn sync(self: *Control, wanted: bool, kelvin: u32) void {
        self.wanted = wanted;
        self.kelvin = kelvin;
        const manager = self.manager orelse return;
        for (self.outputs) |slot| if (slot) |o| {
            o.seen = false;
        };
        const monitors = self.display.getMonitors();
        for (0..monitors.getNItems()) |i| {
            const item = monitors.getItem(@intCast(i)) orelse continue;
            const monitor: *gdk.Monitor = @ptrCast(@alignCast(item));
            defer monitor.unref();
            const w = gdk_wayland_monitor_get_wl_output(monitor) orelse continue;
            if (self.find(monitor)) |o| {
                o.seen = true;
                o.reconcile();
                continue;
            }
            for (&self.outputs) |*slot| if (slot.* == null) {
                const observation = manager.getOutput(w) catch break;
                const o = a.create(Output) catch {
                    observation.destroy();
                    break;
                };
                o.* = .{ .control = self, .wl_output = w, .observation = observation, .seen = true };
                slot.* = o;
                observation.setListener(*Output, Output.event, o);
                break;
            };
        }
        for (&self.outputs) |*slot| if (slot.*) |o| {
            if (!o.seen) {
                o.dropLease();
                o.observation.destroy();
                a.destroy(o);
                slot.* = null;
            }
        };
        self.display.flush();
    }
    pub fn available(self: *const Control) bool {
        for (self.outputs) |slot| if (slot) |o| {
            if (o.available()) return true;
        };
        return false;
    }
    pub fn retry(self: *Control) void {
        for (self.outputs) |slot| if (slot) |o| {
            o.denied_generation = null;
        };
    }
    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Control) void {
        switch (event) {
            .global => |g| if (std.mem.eql(u8, std.mem.span(g.interface), "aqueous_output_warming_manager_v1") and self.manager == null) {
                self.manager = registry.bind(g.name, aq.OutputWarmingManagerV1, 1) catch return;
                self.global = g.name;
                self.sync(self.wanted, self.kelvin);
                self.notify();
            },
            .global_remove => |g| if (self.global == g.name) {
                self.stop();
                self.changed(self.context);
            },
        }
    }
};
