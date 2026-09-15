//! BlueZ client-local Agent1. Discovery and pairing belong to their initiating view.
const std = @import("std");
const ownership = @import("view_ownership.zig");
pub const Owner = ownership.Owner;
const d = @import("dbus_peer.zig");
const gio = d.gio;
const glib = d.glib;
const V = glib.Variant;
const Text = d.Text;
const p = @import("connectivity_policy.zig");
const adapterif = "org.bluez.Adapter1";
const deviceif = "org.bluez.Device1";
const agentpath = "/org/aqueous/Pearl/BluetoothAgent";
pub const Adapter = struct { path: Text(512), label: Text(512), powered: bool, discovering: bool };
pub const Device = struct { path: Text(512), adapter: Text(512), label: Text(512), address: Text(512), paired: bool, trusted: bool, connected: bool, blocked: bool };
pub const PromptKind = enum { none, pin, passkey, confirm, authorize, display };
pub const Action = enum { pair, connect, disconnect, trust, untrust, power_on, power_off };
pub const Bluetooth = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, @import("audio.zig").Event) void,
    peer: d.Peer = undefined,
    agent: d.Export = .{},
    registered: bool = false,
    interest: ownership.Interest = .{},
    operation_owner: ?Owner = null,
    adapters: [8]Adapter = undefined,
    adapter_count: usize = 0,
    devices: [64]Device = undefined,
    device_count: usize = 0,
    truncated: bool = false,
    pending: bool = false,
    cancelling: bool = false,
    sequence: u64 = 0,
    action: Action = .pair,
    target: Text(512) = .{},
    title: Text(128) = .{},
    err: ?[]const u8 = null,
    deadline: c_uint = 0,
    discovering: bool = false,
    discovery_waiting: bool = false,
    discovery_cancelled: bool = false,
    discovery_path: Text(512) = .{},
    discovery_owner: ?Owner = null,
    discovery_sequence: u64 = 0,
    discovery_timer: c_uint = 0,
    prompt: ?*gio.DBusMethodInvocation = null,
    prompt_kind: PromptKind = .none,
    prompt_serial: u64 = 0,
    prompt_text: Text(256) = .{},
    pub fn start(self: *Bluetooth) void {
        self.peer = .{ .app = self.app, .context = self, .changed = stateChanged, .name = "org.bluez", .root = "/" };
        self.peer.start();
    }
    pub fn stop(self: *Bluetooth) void {
        self.revokeViews();
        self.peer.stop();
    }
    fn emit(self: *Bluetooth) void {
        self.changed(self.context, .state);
    }
    pub fn acquireView(self: *Bluetooth) !Owner {
        return self.interest.acquire();
    }
    pub fn releaseView(self: *Bluetooth, owner: Owner) void {
        if (!self.interest.release(owner)) return;
        self.cancelOwned(owner);
        self.stopDiscoveryOwned(owner);
    }
    pub fn revokeViews(self: *Bluetooth) void {
        self.interest.revoke();
        self.cancelOperation();
        self.stopDiscovery();
    }
    pub fn cancelOwned(self: *Bluetooth, owner: Owner) void {
        if (self.operation_owner == owner) self.cancelOperation();
    }
    pub fn ownsPrompt(self: *Bluetooth, owner: Owner) bool {
        return self.interest.contains(owner) and self.operation_owner == owner;
    }
    fn stateChanged(data: *anyopaque, reset: bool) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        if (reset) {
            self.err = null;
            self.rejectPrompt();
            self.finish();
            self.clearDiscovery();
            self.adapter_count = 0;
            self.device_count = 0;
            self.registered = false;
            self.agent.stop();
            if (self.peer.owner.len != 0 and self.agent.start(&self.peer, agentpath, @embedFile("bluetooth_agent.xml"), &vtable, self)) {
                self.peer.call(0, "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", d.tuple(&.{ d.path(agentpath), d.str("KeyboardDisplay") }), "()", 5000, registeredDone) catch {};
            }
        } else self.read();
        self.emit();
    }
    fn registeredDone(data: *anyopaque, _: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        self.registered = value != null;
        if (!self.registered) self.err = "Bluetooth pairing agent unavailable.";
        self.emit();
    }
    fn read(self: *Bluetooth) void {
        self.adapter_count = 0;
        self.device_count = 0;
        self.truncated = false;
        const snapshot = self.peer.snapshot orelse {
            self.cancelOperation();
            self.stopDiscovery();
            return;
        };
        for (0..snapshot.nChildren()) |i| {
            const item = snapshot.getChildValue(i);
            defer item.unref();
            const path = item.getChildValue(0);
            defer path.unref();
            const interfaces = item.getChildValue(1);
            defer interfaces.unref();
            const raw = std.mem.span(path.getString(null));
            if (raw.len > 512) {
                self.truncated = true;
                continue;
            }
            if (d.lookup(interfaces, adapterif, "a{sv}")) |props| {
                defer props.unref();
                if (self.adapter_count == self.adapters.len) {
                    self.truncated = true;
                    continue;
                }
                const adapter = &self.adapters[self.adapter_count];
                self.adapter_count += 1;
                adapter.* = .{ .path = .{}, .label = d.string(props, "Alias", "s"), .powered = d.boolean(props, "Powered"), .discovering = d.boolean(props, "Discovering") };
                adapter.path.set(raw);
            }
            if (d.lookup(interfaces, deviceif, "a{sv}")) |props| {
                defer props.unref();
                if (self.device_count == self.devices.len) {
                    self.truncated = true;
                    continue;
                }
                const dev = &self.devices[self.device_count];
                self.device_count += 1;
                dev.* = .{ .path = .{}, .adapter = d.string(props, "Adapter", "o"), .label = d.string(props, "Alias", "s"), .address = d.string(props, "Address", "s"), .paired = d.boolean(props, "Paired"), .trusted = d.boolean(props, "Trusted"), .connected = d.boolean(props, "Connected"), .blocked = d.boolean(props, "Blocked") };
                dev.path.set(raw);
                if (dev.label.len == 0) dev.label = dev.address;
            }
        }
        if (self.pending and self.action != .power_on and self.action != .power_off and self.findDevice(self.target.slice()) == null) {
            self.cancelOperation();
            self.err = "Bluetooth device was removed.";
        }
        if (self.discovery_path.len != 0 and self.findAdapter(self.discovery_path.slice()) == null) self.stopDiscovery();
    }
    pub fn findDevice(self: *Bluetooth, path: []const u8) ?*Device {
        for (self.devices[0..self.device_count]) |*dev| if (std.mem.eql(u8, dev.path.slice(), path)) return dev;
        return null;
    }
    pub fn findAdapter(self: *Bluetooth, path: []const u8) ?*Adapter {
        for (self.adapters[0..self.adapter_count]) |*adapter| if (std.mem.eql(u8, adapter.path.slice(), path)) return adapter;
        return null;
    }
    pub fn discover(self: *Bluetooth, owner: Owner, epoch: u64, path: []const u8) !void {
        if (!self.interest.contains(owner) or epoch != self.peer.epoch or self.discovery_path.len != 0) return error.Unavailable;
        const adapter = self.findAdapter(path) orelse return error.Unavailable;
        if (!adapter.powered) return error.Unavailable;
        self.discovery_sequence += 1;
        try self.peer.call(self.discovery_sequence, adapter.path.z(), adapterif, "StartDiscovery", null, "()", 10000, discoveryDone);
        self.discovery_owner = owner;
        self.discovery_path = adapter.path;
        self.discovery_waiting = true;
        self.discovery_cancelled = false;
        self.err = null;
        self.discovery_timer = glib.timeoutAdd(30000, discoveryExpired, self);
        self.emit();
    }
    fn discoveryDone(data: *anyopaque, token: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        if (token != self.discovery_sequence) return;
        self.discovery_waiting = false;
        if (value == null) {
            self.err = "Bluetooth discovery unavailable.";
            self.clearDiscovery();
        } else {
            self.discovering = true;
            if (self.discovery_cancelled or !self.interest.contains(self.discovery_owner)) self.stopDiscovery();
        }
        self.peer.refresh();
        self.emit();
    }
    fn discoveryExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Bluetooth = @ptrCast(@alignCast(data.?));
        self.discovery_timer = 0;
        self.stopDiscovery();
        return 0;
    }
    fn clearDiscovery(self: *Bluetooth) void {
        if (self.discovery_timer != 0) _ = glib.Source.remove(self.discovery_timer);
        self.discovery_timer = 0;
        self.discovery_owner = null;
        self.discovery_path = .{};
        self.discovering = false;
        self.discovery_waiting = false;
        self.discovery_cancelled = false;
    }
    pub fn stopDiscoveryOwned(self: *Bluetooth, owner: Owner) void {
        if (self.discovery_owner == owner) self.stopDiscovery();
    }
    fn stopDiscovery(self: *Bluetooth) void {
        if (self.discovery_path.len == 0) return;
        self.discovery_cancelled = true;
        if (self.discovery_waiting) return;
        self.discovery_waiting = true;
        self.peer.call(self.discovery_sequence, self.discovery_path.z(), adapterif, "StopDiscovery", null, "()", 5000, discoveryStopped) catch {
            self.clearDiscovery();
        };
        self.emit();
    }
    fn discoveryStopped(data: *anyopaque, token: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        if (token != self.discovery_sequence) return;
        self.clearDiscovery();
        if (value == null) self.err = "Discovery stop was not confirmed by BlueZ.";
        self.peer.refresh();
        self.emit();
    }
    pub fn request(self: *Bluetooth, owner: Owner, epoch: u64, path: []const u8, action: Action) !void {
        if (!self.interest.contains(owner) or epoch != self.peer.epoch or self.pending) return error.Unavailable;
        var target: Text(512) = .{};
        if (action == .power_on or action == .power_off) {
            const adapter = self.findAdapter(path) orelse return error.Unavailable;
            target = adapter.path;
            self.title.set(adapter.label.slice());
        } else {
            const dev = self.findDevice(path) orelse return error.Unavailable;
            const adapter = self.findAdapter(dev.adapter.slice()) orelse return error.Unavailable;
            if (!adapter.powered or dev.blocked) return error.Unavailable;
            if (action == .pair and (dev.paired or !self.registered)) return error.Unavailable;
            target = dev.path;
            self.title.set(dev.label.slice());
        }
        self.operation_owner = owner;
        self.sequence += 1;
        self.target = target;
        self.action = action;
        self.pending = true;
        self.cancelling = false;
        self.err = null;
        const set = action == .trust or action == .untrust or action == .power_on or action == .power_off;
        self.peer.call(self.sequence, target.z(), if (set) "org.freedesktop.DBus.Properties" else deviceif, switch (action) {
            .pair => "Pair",
            .connect => "Connect",
            .disconnect => "Disconnect",
            else => "Set",
        }, if (set) d.tuple(&.{ d.str(if (action == .trust or action == .untrust) deviceif else adapterif), d.str(if (action == .trust or action == .untrust) "Trusted" else "Powered"), V.newVariant(V.newBoolean(@intFromBool(action == .trust or action == .power_on))) }) else null, "()", if (action == .pair) 90000 else 15000, actionDone) catch |err| {
            self.finish();
            return err;
        };
        self.deadline = glib.timeoutAdd(if (action == .pair) 90000 else 15000, expired, self);
        self.emit();
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Bluetooth = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.cancelOperation();
        self.err = "Bluetooth request timed out.";
        self.emit();
        return 0;
    }
    fn actionDone(data: *anyopaque, token: u64, value: ?*V, err: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        if (token != self.sequence) return;
        self.rejectPrompt();
        if (self.cancelling and self.action == .connect and value != null) {
            self.peer.call(token, self.target.z(), deviceif, "Disconnect", null, "()", 5000, cancelledConnectDone) catch {
                self.finish();
            };
            return;
        }
        self.finish();
        if (value == null and !self.cancelling) {
            self.err = if (err != null and (std.mem.endsWith(u8, err.?, "AuthenticationRejected") or std.mem.endsWith(u8, err.?, "AuthenticationFailed"))) "Pairing rejected. Verify the code and try again." else "Bluetooth change failed or was denied.";
        }
        self.peer.refresh();
        self.emit();
    }
    fn cancelledConnectDone(data: *anyopaque, token: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        if (token != self.sequence) return;
        self.finish();
        if (value == null) self.err = "Disconnect after cancellation was not confirmed.";
        self.peer.refresh();
        self.emit();
    }
    fn finish(self: *Bluetooth) void {
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.pending = false;
        self.operation_owner = null;
    }
    fn cancelOperation(self: *Bluetooth) void {
        self.rejectPrompt();
        if (!self.pending or self.cancelling) {
            self.emit();
            return;
        }
        self.cancelling = true;
        if (self.action == .pair or self.action == .connect) {
            self.peer.call(self.sequence, self.target.z(), deviceif, if (self.action == .pair) "CancelPairing" else "Disconnect", null, "()", 5000, cancelDone) catch {};
            self.err = "Bluetooth request cancelled.";
        }
        self.emit();
    }
    fn cancelDone(data: *anyopaque, _: u64, _: ?*V, _: ?[]const u8) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data));
        self.peer.refresh();
    }
    fn rejectPrompt(self: *Bluetooth) void {
        if (self.prompt) |invocation| invocation.returnDbusError("org.bluez.Error.Canceled", "Authentication cancelled");
        self.prompt = null;
        self.prompt_kind = .none;
        self.prompt_serial += 1;
        std.crypto.secureZero(u8, &self.prompt_text.bytes);
        self.prompt_text.len = 0;
    }
    pub fn answer(self: *Bluetooth, owner: Owner, serial: u64, accept: bool, text: []const u8) !void {
        if (!self.ownsPrompt(owner) or serial != self.prompt_serial or !self.pending or self.cancelling) return error.Unavailable;
        const invocation = self.prompt orelse return error.Unavailable;
        if (!accept) {
            invocation.returnDbusError("org.bluez.Error.Rejected", "User rejected authentication");
            self.prompt = null;
            self.cancelOperation();
            return;
        }
        const reply: ?*V = switch (self.prompt_kind) {
            .pin => blk: {
                if (!p.pin(text)) return error.InvalidValue;
                var secret: [17:0]u8 = @splat(0);
                defer std.crypto.secureZero(u8, &secret);
                @memcpy(secret[0..text.len], text);
                break :blk d.tuple(&.{d.str(secret[0..text.len :0])});
            },
            .passkey => d.tuple(&.{V.newUint32(p.passkey(text) orelse return error.InvalidValue)}),
            .confirm, .authorize => null,
            else => return error.Unavailable,
        };
        invocation.returnValue(reply);
        self.prompt = null;
        self.rejectPrompt();
        self.err = null;
        self.emit();
    }
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = agentCall, .f_get_property = null, .f_set_property = null, .f_padding = @splat(undefined) };
    fn agentCall(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, method: [*:0]const u8, params: *V, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Bluetooth = @ptrCast(@alignCast(data.?));
        if (sender == null or self.peer.owner.len == 0 or !std.mem.eql(u8, std.mem.span(sender.?), self.peer.owner.slice())) {
            invocation.returnDbusError("org.freedesktop.DBus.Error.AccessDenied", "Only BlueZ may call this agent");
            return;
        }
        const name = std.mem.span(method);
        if (std.mem.eql(u8, name, "Cancel") or std.mem.eql(u8, name, "Release")) {
            self.rejectPrompt();
            if (std.mem.eql(u8, name, "Release")) {
                self.registered = false;
                self.cancelOperation();
            }
            invocation.returnValue(null);
            self.emit();
            return;
        }
        const path = params.getChildValue(0);
        defer path.unref();
        if (!self.interest.contains(self.operation_owner) or !self.pending or self.cancelling or (self.action != .pair and self.action != .connect) or !std.mem.eql(u8, std.mem.span(path.getString(null)), self.target.slice()) or self.findDevice(self.target.slice()) == null or self.prompt != null) {
            invocation.returnDbusError("org.bluez.Error.Rejected", "No matching user-initiated request");
            return;
        }
        self.prompt_serial += 1;
        if (std.mem.eql(u8, name, "RequestPinCode")) {
            self.prompt_kind = .pin;
            self.prompt_text.set("Enter the PIN shown on the device.");
        } else if (std.mem.eql(u8, name, "RequestPasskey")) {
            self.prompt_kind = .passkey;
            self.prompt_text.set("Enter the six-digit passkey shown on the device.");
        } else if (std.mem.eql(u8, name, "RequestConfirmation") or std.mem.eql(u8, name, "DisplayPasskey")) {
            const key = params.getChildValue(1);
            defer key.unref();
            if (key.getUint32() > 999999) {
                invocation.returnDbusError("org.bluez.Error.Rejected", "Invalid passkey");
                return;
            }
            var buffer: [256]u8 = undefined;
            self.prompt_kind = if (std.mem.eql(u8, name, "RequestConfirmation")) .confirm else .display;
            self.prompt_text.set(std.fmt.bufPrint(&buffer, "{s}{d:0>6}{s}", .{ if (self.prompt_kind == .confirm) "Does " else "Type ", key.getUint32(), if (self.prompt_kind == .confirm) " match the code on your device?" else " on the device, then press Enter." }) catch unreachable);
        } else if (std.mem.eql(u8, name, "DisplayPinCode")) {
            const key = params.getChildValue(1);
            defer key.unref();
            const raw = std.mem.span(key.getString(null));
            if (!p.pin(raw)) {
                invocation.returnDbusError("org.bluez.Error.Rejected", "Invalid PIN");
                return;
            }
            self.prompt_kind = .display;
            var buffer: [256]u8 = undefined;
            self.prompt_text.set(std.fmt.bufPrint(&buffer, "Type {s} on the device, then press Enter.", .{raw}) catch unreachable);
        } else if (std.mem.eql(u8, name, "RequestAuthorization") or std.mem.eql(u8, name, "AuthorizeService")) {
            self.prompt_kind = .authorize;
            self.prompt_text.set("Allow this device to complete the requested connection?");
        } else {
            invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
            return;
        }
        if (self.prompt_kind == .display) invocation.returnValue(null) else self.prompt = invocation;
        self.emit();
    }
};
