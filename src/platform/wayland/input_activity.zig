//! One authorized activity owner on GTK's display. GTK is the only socket reader.
const std = @import("std");
const glib = @import("glib2");
const gdk = @import("gdk4");
const backend = @import("gdkwayland4");
const object = @import("gobject2");
const wl = @import("wayland").client.wl;
const aq = @import("wayland").client.aqueous;
const policy = @import("../../plugins/activity_policy.zig");
const bootstrap = @import("activity_bootstrap.zig");
const a = std.heap.c_allocator;
pub const Token = struct {
    broker: ?*Broker = null,
    inhibitor: ?*aq.InputActivityInhibitorV1 = null,
    serial: u32 = 0,
    source: c_uint = 0,
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque) void = null,
    pub fn begin(self: *Token, broker: ?*Broker, context: *anyopaque, callback: *const fn (*anyopaque) void) void {
        self.cancel();
        self.context = context;
        self.callback = callback;
        if (broker) |b| {
            self.broker = b;
            var inserted = false;
            for (&b.tokens) |*slot| if (slot.* == null) {
                slot.* = self;
                inserted = true;
                break;
            };
            // There are only two production owners. Resource exhaustion suspends
            // the entire source rather than permitting an untracked auth flow.
            if (!inserted) {
                b.failed = true;
                b.dropSubscription();
            }
            b.bump();
            if (b.subscription) |sub| {
                self.serial = b.serial();
                self.inhibitor = sub.inhibit(self.serial) catch null;
            }
            self.source = if (self.inhibitor != null) glib.timeoutAdd(500, expired, self) else glib.idleAdd(done, self);
            b.notify();
            b.display.flush();
        } else self.source = glib.idleAdd(done, self);
    }
    fn done(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Token = @ptrCast(@alignCast(data.?));
        self.source = 0;
        const callback = self.callback;
        self.callback = null;
        if (callback) |f| f(self.context.?);
        return 0;
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Token = @ptrCast(@alignCast(data.?));
        self.source = 0;
        if (self.broker) |b| {
            b.dropSubscription();
            b.display.flush();
            b.notify();
            // dropSubscription completes every waiting token asynchronously.
            if (self.source != 0) return 0;
        }
        return done(self);
    }
    fn complete(self: *Token) void {
        if (self.callback == null) return;
        if (self.source != 0) _ = glib.Source.remove(self.source);
        self.source = glib.idleAdd(done, self);
    }
    pub fn cancel(self: *Token) void {
        if (self.source != 0) _ = glib.Source.remove(self.source);
        self.source = 0;
        self.callback = null;
        if (self.inhibitor) |inhibitor| inhibitor.destroy();
        self.inhibitor = null;
        if (self.broker) |b| {
            self.broker = null;
            for (&b.tokens) |*slot| if (slot.* == self) {
                slot.* = null;
                break;
            };
            b.bump();
            b.reconcile();
            b.notify();
            b.display.flush();
        }
    }
};
pub const Broker = struct {
    display: *gdk.Display,
    registry: *wl.Registry,
    manager: ?*aq.InputActivityManagerV1 = null,
    subscription: ?*aq.InputActivityV1 = null,
    name: u32 = 0,
    proof: c_int = -1,
    deadline: c_uint = 0,
    reconcile_source: c_uint = 0,
    last_request_us: i64 = 0,
    authorized: bool = false,
    denied: bool = false,
    failed: bool = false,
    supported: bool = true,
    allowed: bool = false,
    wanted: bool = false,
    ready: bool = false,
    generation: u64 = 0,
    attempted: u64 = 0,
    ready_serial: u32 = 0,
    last_sequence: u32 = 0,
    next_serial: u32 = 0,
    epoch: u64 = 1,
    tokens: [8]?*Token = @splat(null),
    context: ?*anyopaque = null,
    changed: ?*const fn (*anyopaque) void = null,
    activity: ?*const fn (*anyopaque, u32, u64) void = null,
    pub fn create(display: *gdk.Display) !*Broker {
        const proof = bootstrap.take();
        var transferred = false;
        defer if (!transferred and proof >= 0) {
            _ = std.c.close(proof);
        };
        const wayland = object.ext.cast(backend.WaylandDisplay, display) orelse return error.NotWayland;
        const connection: *wl.Display = @ptrCast(wayland.getWlDisplay() orelse return error.NotWayland);
        const registry = try connection.getRegistry();
        errdefer @as(*wl.Proxy, @ptrCast(registry)).destroy();
        const self = try a.create(Broker);
        self.* = .{ .display = display, .registry = registry, .proof = proof };
        transferred = true;
        if (!@import("build_options").wasm_plugins) {
            self.closeProof();
        } else {
            registry.setListener(*Broker, registryEvent, self);
            self.deadline = glib.timeoutAdd(3000, authExpired, self);
        }
        display.flush();
        return self;
    }
    fn closeProof(self: *Broker) void {
        if (self.proof >= 0) _ = std.c.close(self.proof);
        self.proof = -1;
    }
    fn cancelDeadline(self: *Broker) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
    }
    fn authExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Broker = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.closeProof();
        if (self.manager != null and !self.authorized) self.denied = true;
        self.bump();
        self.notify();
        return 0;
    }
    pub fn destroy(self: *Broker) void {
        self.changed = null;
        self.activity = null;
        self.failed = true;
        self.cancelDeadline();
        if (self.reconcile_source != 0) _ = glib.Source.remove(self.reconcile_source);
        self.reconcile_source = 0;
        self.closeProof();
        for (&self.tokens) |*slot| if (slot.*) |token| {
            token.cancel();
            slot.* = null;
        };
        self.dropSubscription();
        if (self.manager) |manager| manager.destroy();
        @as(*wl.Proxy, @ptrCast(self.registry)).destroy();
        self.display.flush();
        a.destroy(self);
    }
    pub fn inhibited(self: *const Broker) bool {
        for (self.tokens) |token| if (token != null) return true;
        return false;
    }
    pub fn state(self: *const Broker) policy.HostState {
        const status: policy.Availability = if (self.manager == null or !self.supported) .unsupported else if (self.denied) .@"permission-denied" else if (!self.authorized or !self.allowed or self.inhibited() or !self.ready or self.failed) .suspended else .available;
        return .{ .availability = status, .epoch = self.epoch };
    }
    pub fn reason(self: *const Broker) []const u8 {
        if (self.manager == null) return "Input activity protocol unavailable";
        if (!self.supported) return "Input activity unsupported in this compositor session";
        if (self.denied) return "Launch not authorized; use Aqueous's Pearl integration service";
        if (self.failed) return "Input activity unavailable until Pearl restarts";
        if (self.inhibited() or !self.allowed) return "Input activity suspended for session privacy";
        if (!self.authorized) return "Waiting for input activity authorization";
        if (!self.wanted) return "Input activity idle; no granted plugin has subscribed";
        return if (self.ready) "Input activity active" else "Waiting for compositor readiness";
    }
    fn serial(self: *Broker) u32 {
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
        return self.next_serial;
    }
    fn bump(self: *Broker) void {
        self.epoch +%= 1;
        if (self.epoch == 0) self.epoch = 1;
        self.ready = false;
    }
    fn notify(self: *Broker) void {
        if (self.changed) |f| f(self.context.?);
    }
    pub fn configure(self: *Broker, wanted: bool, allowed: bool) void {
        if (self.wanted == wanted and self.allowed == allowed) return;
        const was_allowed = self.allowed;
        self.wanted = wanted;
        self.allowed = allowed;
        if (was_allowed != allowed) self.bump();
        self.reconcile();
        self.notify();
    }
    fn dropSubscription(self: *Broker) void {
        for (self.tokens) |token| if (token) |t| {
            if (t.inhibitor) |i| i.destroy();
            t.inhibitor = null;
            t.complete();
        };
        if (self.subscription) |sub| sub.destroy();
        self.subscription = null;
        self.generation = 0;
        self.attempted = 0;
        self.last_sequence = 0;
        self.ready_serial = 0;
        self.bump();
        self.display.flush();
    }
    fn reconcile(self: *Broker) void {
        if (!self.authorized or self.failed) return;
        if (self.inhibited()) return; // keep the subscription until inhibit acknowledgments arrive
        if (!self.wanted or !self.allowed) {
            if (self.subscription != null) self.dropSubscription();
            return;
        }
        const needs_request = self.subscription == null or (self.supported and self.generation != 0 and self.attempted != self.generation);
        if (!needs_request) return;
        // Guest subscription churn must stay below the compositor's resource
        // budget. Inhibition, destruction and input acks remain immediate.
        const now = glib.getMonotonicTime();
        const delay = 100_000 - (now - self.last_request_us);
        if (delay > 0) {
            if (self.reconcile_source == 0) self.reconcile_source = glib.timeoutAdd(@intCast(@divTrunc(delay + 999, 1000)), reconcileLater, self);
            return;
        }
        self.last_request_us = now;
        if (self.subscription == null) {
            self.subscription = self.manager.?.getSubscription() catch {
                self.failed = true;
                self.notify();
                return;
            };
            self.subscription.?.setListener(*Broker, subscriptionEvent, self);
        } else if (self.supported and self.generation != 0 and self.attempted != self.generation) {
            self.attempted = self.generation;
            self.ready_serial = self.serial();
            self.subscription.?.setReady(self.ready_serial, @truncate(self.generation >> 32), @truncate(self.generation), 1);
        }
        self.display.flush();
    }
    fn reconcileLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Broker = @ptrCast(@alignCast(data.?));
        self.reconcile_source = 0;
        self.reconcile();
        self.notify();
        return 0;
    }
    fn registryEvent(registry: *wl.Registry, event: wl.Registry.Event, self: *Broker) void {
        switch (event) {
            .global => |g| {
                if (!std.mem.eql(u8, std.mem.span(g.interface), "aqueous_input_activity_manager_v1") or self.manager != null) return;
                self.manager = registry.bind(g.name, aq.InputActivityManagerV1, 1) catch return;
                self.name = g.name;
                self.manager.?.setListener(*Broker, managerEvent, self);
                if (self.proof >= 0) {
                    self.manager.?.authorize(self.proof);
                    self.closeProof();
                } else self.denied = true;
                self.display.flush();
                self.notify();
            },
            .global_remove => |g| if (g.name == self.name) {
                self.dropSubscription();
                if (self.manager) |manager| manager.destroy();
                self.manager = null;
                self.authorized = false;
                self.denied = true;
                self.notify();
            },
        }
    }
    fn managerEvent(_: *aq.InputActivityManagerV1, event: aq.InputActivityManagerV1.Event, self: *Broker) void {
        switch (event) {
            .capabilities => |v| if (v.minimum_interval_ms != 100 or v.categories != 3) {
                self.supported = false;
            },
            .authorization => |v| {
                self.cancelDeadline();
                self.authorized = v.status == .available and !self.denied;
                self.denied = !self.authorized;
                self.bump();
                if (!self.authorized) self.dropSubscription();
                self.reconcile();
            },
        }
        self.notify();
    }
    fn subscriptionEvent(sub: *aq.InputActivityV1, event: aq.InputActivityV1.Event, self: *Broker) void {
        if (self.subscription != sub) return;
        switch (event) {
            .state => |v| {
                const generation = (@as(u64, v.generation_hi) << 32) | v.generation_lo;
                if (v.status == .permission_denied) {
                    self.denied = true;
                    self.authorized = false;
                    self.dropSubscription();
                    self.notify();
                    return;
                }
                if (generation < self.generation) return;
                if (generation != self.generation) {
                    self.generation = generation;
                    self.last_sequence = 0;
                    self.bump();
                }
                if (v.status == .unsupported) self.supported = false;
                if (v.status != .available) self.ready = false;
                if (v.status == .available and v.serial == self.ready_serial and self.attempted == generation and self.allowed and !self.inhibited()) self.ready = true;
                if (v.status == .suspended) for (self.tokens) |token| if (token) |t| {
                    if (t.serial != 0 and t.serial == v.serial) {
                        // Exercise Pearl's bounded fallback without stalling GTK
                        // or changing the production protocol implementation.
                        if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_ACTIVITY_STALL_ACK") != null) continue;
                        t.complete();
                    }
                };
                self.reconcile();
                self.notify();
            },
            .activity => |v| {
                const generation = (@as(u64, v.generation_hi) << 32) | v.generation_lo;
                const mask: u32 = @bitCast(v.categories);
                if (generation != self.generation or v.sequence == 0 or v.sequence <= self.last_sequence or mask == 0 or mask & ~@as(u32, 3) != 0) return;
                self.last_sequence = v.sequence;
                sub.ack(v.generation_hi, v.generation_lo, v.sequence);
                self.display.flush();
                if (self.state().availability == .available) if (self.activity) |f| f(self.context.?, mask, self.epoch);
            },
        }
    }
};
