//! NetworkManager state and a session-only SecretAgent; credentials never enter the model.
const std = @import("std");
const d = @import("dbus_peer.zig");
const gio = d.gio;
const glib = d.glib;
const p = @import("connectivity_policy.zig");
const Text = d.Text;
const V = glib.Variant;
pub const root = "/org/freedesktop/NetworkManager";
const nm = "org.freedesktop.NetworkManager";
const devif = nm ++ ".Device";
const wifiif = devif ++ ".Wireless";
const apif = nm ++ ".AccessPoint";
const settingsif = nm ++ ".Settings.Connection";
const agentpath = root ++ "/SecretAgent";
const security_setting = "802-11-wireless-security";
pub const Device = struct { path: Text(512), name: Text(512), kind: u32, state: u32, active: Text(512), ap: Text(512), available: ?*V = null };
pub const AccessPoint = struct { path: Text(512), device: Text(512), label: Text(128), ssid: [32]u8 = @splat(0), len: usize = 0, strength: u8, security: p.Security };
pub const Saved = struct { path: Text(512), label: Text(512) = .{}, device: Text(512) = .{}, security: p.Security = .advanced, loaded: bool = false };
pub const Network = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque, @import("audio.zig").Event) void,
    peer: d.Peer = undefined,
    agent: d.Export = .{},
    registered: bool = false,
    panel_open: bool = false,
    devices: [8]Device = undefined,
    device_count: usize = 0,
    aps: [64]AccessPoint = undefined,
    ap_count: usize = 0,
    saved: [32]Saved = undefined,
    saved_count: usize = 0,
    settings_loading: bool = false,
    settings_revision: u64 = 0,
    settings_path: Text(512) = .{},
    enabled: bool = false,
    hardware_enabled: bool = false,
    connectivity: u32 = 0,
    truncated: bool = false,
    err: ?[]const u8 = null,
    pending: bool = false,
    cancelled: bool = false,
    activation_waiting: bool = false,
    sequence: u64 = 0,
    device: Text(512) = .{},
    selected_ap: Text(512) = .{},
    selected_profile: Text(512) = .{},
    selected_ssid: [32]u8 = @splat(0),
    selected_len: usize = 0,
    selected_security: p.Security = .open,
    title: Text(128) = .{},
    active: Text(512) = .{},
    deadline: c_uint = 0,
    scan_pending: bool = false,
    scan_last: i64 = 0,
    prompt: ?*gio.DBusMethodInvocation = null,
    prompt_path: Text(512) = .{},
    prompt_serial: u64 = 0,
    pub fn start(self: *Network) void {
        self.peer = .{ .app = self.app, .context = self, .changed = stateChanged, .invalidated = invalidated, .name = nm, .root = "/org/freedesktop" };
        self.peer.start();
    }
    pub fn stop(self: *Network) void {
        self.panel(false);
        self.peer.stop();
    }
    fn emit(self: *Network) void {
        self.changed(self.context, .state);
    }
    pub fn panel(self: *Network, open: bool) void {
        self.panel_open = open;
        if (!open) self.cancelOperation();
    }
    fn clearDevices(self: *Network) void {
        for (self.devices[0..self.device_count]) |dev| if (dev.available) |v| v.unref();
        self.device_count = 0;
        self.ap_count = 0;
    }
    fn stateChanged(data: *anyopaque, reset: bool) void {
        const self: *Network = @ptrCast(@alignCast(data));
        if (reset) {
            self.err = null;
            self.rejectPrompt();
            self.finish();
            self.clearDevices();
            self.saved_count = 0;
            self.settings_loading = false;
            self.enabled = false;
            self.hardware_enabled = false;
            self.connectivity = 0;
            self.scan_pending = false;
            self.scan_last = 0;
            self.agent.stop();
            self.registered = false;
            if (self.peer.owner.len != 0 and self.agent.start(&self.peer, agentpath, @embedFile("network_agent.xml"), &vtable, self)) {
                self.peer.call(0, root ++ "/AgentManager", nm ++ ".AgentManager", "RegisterWithCapabilities", d.tuple(&.{ d.str("org.aqueous.Pearl"), V.newUint32(0) }), "()", 5000, registeredDone) catch {};
            }
        } else self.read();
        self.emit();
    }
    fn registeredDone(data: *anyopaque, _: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        self.registered = value != null;
        if (!self.registered) self.err = "Wi-Fi authentication agent unavailable. Open the network editor.";
        self.emit();
    }
    fn read(self: *Network) void {
        self.clearDevices();
        self.truncated = false;
        const snapshot = self.peer.snapshot orelse {
            self.enabled = false;
            self.hardware_enabled = false;
            self.saved_count = 0;
            self.cancelOperation();
            return;
        };
        if (d.lookup(snapshot, root, "a{sa{sv}}")) |interfaces| {
            defer interfaces.unref();
            if (d.lookup(interfaces, nm, "a{sv}")) |props| {
                defer props.unref();
                self.enabled = d.boolean(props, "WirelessEnabled");
                self.hardware_enabled = d.boolean(props, "WirelessHardwareEnabled");
                self.connectivity = d.number(props, "Connectivity");
            }
        }
        for (0..snapshot.nChildren()) |i| {
            const item = snapshot.getChildValue(i);
            defer item.unref();
            const path = item.getChildValue(0);
            defer path.unref();
            const interfaces = item.getChildValue(1);
            defer interfaces.unref();
            const props = d.lookup(interfaces, devif, "a{sv}") orelse continue;
            defer props.unref();
            const kind = d.number(props, "DeviceType");
            if ((kind != 1 and kind != 2) or !d.boolean(props, "Managed")) continue;
            if (self.device_count == self.devices.len) {
                self.truncated = true;
                continue;
            }
            const raw = std.mem.span(path.getString(null));
            if (raw.len > 512) {
                self.truncated = true;
                continue;
            }
            const dev = &self.devices[self.device_count];
            self.device_count += 1;
            dev.* = .{ .path = .{}, .name = d.string(props, "Interface", "s"), .kind = kind, .state = d.number(props, "State"), .active = d.string(props, "ActiveConnection", "o"), .ap = .{}, .available = d.lookup(props, "AvailableConnections", "ao") };
            dev.path.set(raw);
            if (d.lookup(interfaces, wifiif, "a{sv}")) |wifi| {
                defer wifi.unref();
                dev.ap = d.string(wifi, "ActiveAccessPoint", "o");
                if (d.lookup(wifi, "AccessPoints", "ao")) |aps| {
                    defer aps.unref();
                    for (0..@min(aps.nChildren(), 128)) |j| {
                        const ap_path = aps.getChildValue(j);
                        defer ap_path.unref();
                        self.readAP(snapshot, dev, std.mem.span(ap_path.getString(null)));
                    }
                    if (aps.nChildren() > 128) self.truncated = true;
                }
            }
        }
        var next: [32]Saved = undefined;
        var count: usize = 0;
        for (0..snapshot.nChildren()) |i| {
            const item = snapshot.getChildValue(i);
            defer item.unref();
            const path = item.getChildValue(0);
            defer path.unref();
            const interfaces = item.getChildValue(1);
            defer interfaces.unref();
            const props = d.lookup(interfaces, settingsif, "a{sv}") orelse continue;
            props.unref();
            const raw = std.mem.span(path.getString(null));
            if (count == next.len or raw.len > 512) {
                self.truncated = true;
                continue;
            }
            var saved: Saved = .{ .path = .{} };
            saved.path.set(raw);
            for (self.saved[0..self.saved_count]) |old| if (std.mem.eql(u8, old.path.slice(), raw)) {
                saved = old;
                break;
            };
            saved.device = .{};
            for (self.devices[0..self.device_count]) |dev| if (dev.available) |available| {
                for (0..@min(available.nChildren(), 128)) |j| {
                    const v = available.getChildValue(j);
                    defer v.unref();
                    if (std.mem.eql(u8, raw, std.mem.span(v.getString(null)))) {
                        saved.device = dev.path;
                        break;
                    }
                }
                if (saved.device.len != 0) break;
            };
            next[count] = saved;
            count += 1;
        }
        self.saved = next;
        self.saved_count = count;
        self.loadSettings();
        if (self.pending and self.device.len > 0) {
            const dev = self.findDevice(self.device.slice()) orelse {
                self.cancelOperation();
                self.err = "Network device was removed.";
                return;
            };
            if ((self.selected_ap.len != 0 and self.findAP(self.selected_ap.slice()) == null) or (self.selected_profile.len != 0 and !self.hasSaved(self.selected_profile.slice()))) {
                self.cancelOperation();
                self.err = "Selected network was removed.";
                return;
            }
            if (dev.state == 120) {
                self.rejectPrompt();
                self.finish();
                self.err = "Connection failed. Check credentials and try again.";
            }
            if (!self.activation_waiting and self.active.len != 0 and dev.state == 100 and std.mem.eql(u8, dev.active.slice(), self.active.slice())) self.finish();
        }
    }
    fn readAP(self: *Network, snapshot: *V, dev: *Device, path: [:0]const u8) void {
        if (self.ap_count == self.aps.len or path.len > 512) {
            self.truncated = true;
            return;
        }
        const interfaces = d.lookup(snapshot, path, "a{sa{sv}}") orelse return;
        defer interfaces.unref();
        const props = d.lookup(interfaces, apif, "a{sv}") orelse return;
        defer props.unref();
        const ssid = d.lookup(props, "Ssid", "ay") orelse return;
        defer ssid.unref();
        if (ssid.nChildren() > 32) return;
        const ap = &self.aps[self.ap_count];
        self.ap_count += 1;
        ap.* = .{ .path = .{}, .device = dev.path, .label = .{}, .strength = 0, .security = p.security(d.number(props, "Flags"), d.number(props, "WpaFlags"), d.number(props, "RsnFlags")) };
        ap.path.set(path);
        ap.len = ssid.nChildren();
        for (0..ap.len) |i| {
            const byte = ssid.getChildValue(i);
            defer byte.unref();
            ap.ssid[i] = byte.getByte();
        }
        var label: [128]u8 = undefined;
        ap.label.set(p.ssidLabel(ap.ssid[0..ap.len], &label));
        if (ap.len == 0) ap.security = .advanced;
        if (d.lookup(props, "Strength", "y")) |strength| {
            defer strength.unref();
            ap.strength = @min(100, strength.getByte());
        }
    }
    fn hasSaved(self: *Network, path: []const u8) bool {
        for (self.saved[0..self.saved_count]) |*saved| if (std.mem.eql(u8, saved.path.slice(), path)) return true;
        return false;
    }
    fn invalidated(data: *anyopaque, path: []const u8, iface: []const u8, method: []const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        if (std.mem.eql(u8, iface, settingsif) and std.mem.eql(u8, method, "Updated")) {
            self.settings_revision += 1;
            for (self.saved[0..self.saved_count]) |*saved| if (std.mem.eql(u8, path, saved.path.slice())) {
                saved.loaded = false;
            };
        }
    }
    fn loadSettings(self: *Network) void {
        if (self.settings_loading) return;
        for (self.saved[0..self.saved_count]) |*saved| if (!saved.loaded) {
            self.settings_loading = true;
            self.settings_path = saved.path;
            self.peer.call(self.settings_revision, saved.path.z(), settingsif, "GetSettings", null, "(a{sa{sv}})", 3000, settingsDone) catch {
                self.settings_loading = false;
            };
            return;
        };
    }
    fn settingsDone(data: *anyopaque, revision: u64, result: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        self.settings_loading = false;
        if (revision != self.settings_revision) {
            self.loadSettings();
            return;
        }
        for (self.saved[0..self.saved_count]) |*saved| if (std.mem.eql(u8, saved.path.slice(), self.settings_path.slice())) {
            saved.loaded = true;
            if (result) |v| {
                if (v.getSize() > 65536) {
                    saved.label.set("Saved profile exceeds the supported size");
                    break;
                }
                const settings = v.getChildValue(0);
                defer settings.unref();
                if (d.lookup(settings, "connection", "a{sv}")) |props| {
                    defer props.unref();
                    saved.label = d.string(props, "id", "s");
                    const kind = d.string(props, "type", "s");
                    if (std.mem.eql(u8, kind.slice(), "802-3-ethernet") or std.mem.eql(u8, kind.slice(), "802-11-wireless")) saved.security = .open;
                }
                if (d.lookup(settings, security_setting, "a{sv}")) |props| {
                    defer props.unref();
                    const key = d.string(props, "key-mgmt", "s");
                    saved.security = if (std.mem.eql(u8, key.slice(), "wpa-psk")) .psk else if (std.mem.eql(u8, key.slice(), "sae")) .sae else .advanced;
                }
                if (d.lookup(settings, "802-1x", "a{sv}")) |props| {
                    props.unref();
                    saved.security = .advanced;
                }
            }
            break;
        };
        self.loadSettings();
        self.emit();
    }
    pub fn findDevice(self: *Network, path: []const u8) ?*Device {
        for (self.devices[0..self.device_count]) |*dev| if (std.mem.eql(u8, dev.path.slice(), path)) return dev;
        return null;
    }
    pub fn findAP(self: *Network, path: []const u8) ?*AccessPoint {
        for (self.aps[0..self.ap_count]) |*ap| if (std.mem.eql(u8, ap.path.slice(), path)) return ap;
        return null;
    }
    pub fn scan(self: *Network, epoch: u64, path: []const u8) !void {
        if (!self.panel_open or epoch != self.peer.epoch or self.scan_pending or !self.enabled or !self.hardware_enabled) return error.Unavailable;
        const now = glib.getMonotonicTime();
        if (self.scan_last != 0 and now - self.scan_last < 15_000_000) return error.Busy;
        const dev = self.findDevice(path) orelse return error.Unavailable;
        if (dev.kind != 2 or dev.state < 30) return error.Unavailable;
        try self.peer.call(0, dev.path.z(), wifiif, "RequestScan", d.tuple(&.{d.array("{sv}", &.{})}), "()", 15000, scanDone);
        self.scan_last = now;
        self.scan_pending = true;
        self.err = null;
        self.emit();
    }
    fn scanDone(data: *anyopaque, _: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        self.scan_pending = false;
        if (value == null) self.err = "Scan unavailable or rate limited. Try again shortly.";
        self.peer.refresh();
        self.emit();
    }
    pub fn setEnabled(self: *Network, enabled: bool) !void {
        if (self.pending or !self.hardware_enabled) return error.Unavailable;
        try self.peer.call(0, root, "org.freedesktop.DBus.Properties", "Set", d.tuple(&.{ d.str(nm), d.str("WirelessEnabled"), V.newVariant(V.newBoolean(@intFromBool(enabled))) }), "()", 5000, simpleDone);
        self.pending = true;
        self.device = .{};
        self.err = null;
        self.emit();
    }
    pub fn connectAP(self: *Network, epoch: u64, path: []const u8) !void {
        if (!self.panel_open or epoch != self.peer.epoch or self.pending or !self.enabled) return error.Unavailable;
        const ap = self.findAP(path) orelse return error.Unavailable;
        if (ap.security == .advanced) {
            self.err = "Enterprise, WEP and hidden networks require the network editor.";
            self.emit();
            return error.Unsupported;
        }
        if (ap.security != .open and !self.registered) return error.Unavailable;
        const dev = self.findDevice(ap.device.slice()) orelse return error.Unavailable;
        if (dev.state < 30) return error.Unavailable;
        self.begin(dev.path, ap.label.slice(), ap.security);
        self.selected_ap = ap.path;
        self.selected_ssid = ap.ssid;
        self.selected_len = ap.len;
        const settings = d.array("{sa{sv}}", if (ap.security == .open) &.{d.section("connection", &.{d.entry("autoconnect", V.newBoolean(0))})} else &.{
            d.section("connection", &.{d.entry("autoconnect", V.newBoolean(0))}),
            d.section(security_setting, &.{ d.entry("key-mgmt", d.str(if (ap.security == .sae) "sae" else "wpa-psk")), d.entry("psk-flags", V.newUint32(2)) }),
        });
        self.peer.call(self.sequence, root, nm, "AddAndActivateConnection2", d.tuple(&.{ settings, d.path(dev.path.z()), d.path(ap.path.z()), d.array("{sv}", &.{d.entry("persist", d.str("volatile"))}) }), "(ooa{sv})", 90000, activated) catch |err| {
            self.finish();
            return err;
        };
        self.emit();
    }
    pub fn connectSaved(self: *Network, epoch: u64, path: []const u8) !void {
        if (!self.panel_open or epoch != self.peer.epoch or self.pending) return error.Unavailable;
        for (self.saved[0..self.saved_count]) |*saved| if (std.mem.eql(u8, saved.path.slice(), path)) {
            if (!saved.loaded or saved.device.len == 0) return error.Unavailable;
            if (saved.security == .advanced) {
                self.err = "Advanced authentication requires the network editor.";
                self.emit();
                return error.Unsupported;
            }
            if (saved.security != .open and !self.registered) return error.Unavailable;
            self.begin(saved.device, saved.label.slice(), saved.security);
            self.selected_profile = saved.path;
            self.peer.call(self.sequence, root, nm, "ActivateConnection", d.tuple(&.{ d.path(saved.path.z()), d.path(saved.device.z()), d.path("/") }), "(o)", 90000, activated) catch |err| {
                self.finish();
                return err;
            };
            self.emit();
            return;
        };
        return error.Unavailable;
    }
    fn begin(self: *Network, device: Text(512), title: []const u8, security: p.Security) void {
        self.sequence += 1;
        self.pending = true;
        self.cancelled = false;
        self.activation_waiting = true;
        self.device = device;
        self.title.set(title);
        self.selected_security = security;
        self.selected_ap = .{};
        self.selected_profile = .{};
        self.selected_len = 0;
        self.active = .{};
        self.err = null;
        self.deadline = glib.timeoutAdd(90000, expired, self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Network = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.cancelOperation();
        self.err = "Connection timed out. Check the network and try again.";
        self.emit();
        return 0;
    }
    fn activated(data: *anyopaque, token: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        if (token != self.sequence) return;
        self.activation_waiting = false;
        if (value) |v| {
            const active = v.getChildValue(if (d.is(v, "(o)")) 0 else 1);
            defer active.unref();
            self.active.set(std.mem.span(active.getString(null)));
            if (self.cancelled) {
                self.peer.call(token, root, nm, "DeactivateConnection", d.tuple(&.{d.path(self.active.z())}), "()", 5000, cleanupDone) catch {
                    self.finish();
                };
            } else self.peer.refresh();
        } else {
            self.rejectPrompt();
            self.finish();
            if (!self.cancelled) self.err = "Connection failed or credentials were rejected. Try again.";
        }
        self.emit();
    }
    fn cleanupDone(data: *anyopaque, token: u64, _: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        if (token != self.sequence) return;
        self.finish();
        self.peer.refresh();
        self.emit();
    }
    fn finish(self: *Network) void {
        self.rejectPrompt();
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        self.pending = false;
        self.activation_waiting = false;
        self.active = .{};
        self.device = .{};
    }
    pub fn disconnect(self: *Network, epoch: u64, path: []const u8) !void {
        if (epoch != self.peer.epoch or self.pending) return error.Unavailable;
        const dev = self.findDevice(path) orelse return error.Unavailable;
        try self.peer.call(0, dev.path.z(), devif, "Disconnect", null, "()", 10000, simpleDone);
        self.pending = true;
        self.device = .{};
        self.err = null;
        self.emit();
    }
    fn simpleDone(data: *anyopaque, _: u64, value: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        self.pending = false;
        if (value == null) self.err = "Network change denied or unavailable.";
        self.peer.refresh();
        self.emit();
    }
    pub fn cancelOperation(self: *Network) void {
        self.rejectPrompt();
        if (!self.pending or self.device.len == 0 or self.cancelled) return;
        self.cancelled = true;
        self.err = "Connection cancelled.";
        self.peer.call(self.sequence, self.device.z(), devif, "Disconnect", null, "()", 5000, cancelledDone) catch {
            self.finish();
        };
        self.emit();
    }
    fn cancelledDone(data: *anyopaque, token: u64, _: ?*V, _: ?[]const u8) void {
        const self: *Network = @ptrCast(@alignCast(data));
        if (token != self.sequence) return;
        if (!self.activation_waiting) self.finish();
        self.peer.refresh();
        self.emit();
    }
    fn rejectPrompt(self: *Network) void {
        if (self.prompt) |invocation| invocation.returnDbusError(nm ++ ".SecretAgent.UserCanceled", "Authentication cancelled");
        self.prompt = null;
        self.prompt_path = .{};
        self.prompt_serial += 1;
    }
    pub fn answer(self: *Network, serial: u64, password: []const u8) !void {
        if (serial != self.prompt_serial or !self.panel_open or !self.pending or self.cancelled) return error.Unavailable;
        const invocation = self.prompt orelse return error.Unavailable;
        if (!p.password(password, self.selected_security)) {
            self.err = "Enter a valid Wi-Fi password.";
            self.emit();
            return error.InvalidValue;
        }
        // This short-lived copy is wiped. GTK and GDBus own their transient copies.
        var secret: [65:0]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &secret);
        @memcpy(secret[0..password.len], password);
        invocation.returnValue(d.tuple(&.{d.array("{sa{sv}}", &.{d.section(security_setting, &.{ d.entry("name", d.str(security_setting)), d.entry("psk", d.str(secret[0..password.len :0])) })})}));
        self.prompt = null;
        self.prompt_path = .{};
        self.prompt_serial += 1;
        self.err = null;
        self.emit();
    }
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = agentCall, .f_get_property = null, .f_set_property = null, .f_padding = @splat(undefined) };
    fn agentCall(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, method: [*:0]const u8, params: *V, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Network = @ptrCast(@alignCast(data.?));
        if (sender == null or self.peer.owner.len == 0 or !std.mem.eql(u8, std.mem.span(sender.?), self.peer.owner.slice())) {
            invocation.returnDbusError("org.freedesktop.DBus.Error.AccessDenied", "Only NetworkManager may call this agent");
            return;
        }
        const name = std.mem.span(method);
        if (std.mem.eql(u8, name, "CancelGetSecrets")) {
            const path = params.getChildValue(0);
            defer path.unref();
            const setting = params.getChildValue(1);
            defer setting.unref();
            if (std.mem.eql(u8, self.prompt_path.slice(), std.mem.span(path.getString(null))) and std.mem.eql(u8, security_setting, std.mem.span(setting.getString(null)))) self.rejectPrompt();
            invocation.returnValue(null);
            self.emit();
            return;
        }
        if (std.mem.eql(u8, name, "DeleteSecrets")) {
            invocation.returnValue(null);
            return;
        }
        if (std.mem.eql(u8, name, "SaveSecrets")) {
            invocation.returnDbusError(nm ++ ".SecretAgent.NotSupported", "Pearl does not store credentials");
            return;
        }
        if (!std.mem.eql(u8, name, "GetSecrets")) {
            invocation.returnDbusError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
            return;
        }
        const settings = params.getChildValue(0);
        defer settings.unref();
        const path = params.getChildValue(1);
        defer path.unref();
        const setting = params.getChildValue(2);
        defer setting.unref();
        const flags = params.getChildValue(4);
        defer flags.unref();
        const rawpath = std.mem.span(path.getString(null));
        var matches = self.selected_profile.len != 0 and std.mem.eql(u8, self.selected_profile.slice(), rawpath);
        if (self.selected_profile.len == 0) if (d.lookup(settings, "802-11-wireless", "a{sv}")) |wireless| {
            defer wireless.unref();
            if (d.lookup(wireless, "ssid", "ay")) |ssid| {
                defer ssid.unref();
                matches = self.selected_len != 0 and ssid.nChildren() == self.selected_len;
                if (matches) for (0..self.selected_len) |i| {
                    const c = ssid.getChildValue(i);
                    defer c.unref();
                    if (c.getByte() != self.selected_ssid[i]) {
                        matches = false;
                        break;
                    }
                };
            }
        };
        if (d.lookup(settings, security_setting, "a{sv}")) |security| {
            defer security.unref();
            const key = d.string(security, "key-mgmt", "s");
            matches = matches and std.mem.eql(u8, key.slice(), if (self.selected_security == .sae) "sae" else "wpa-psk");
        } else matches = false;
        if (!self.panel_open or !self.pending or self.cancelled or self.prompt != null or !matches or rawpath.len > 512 or flags.getUint32() & 1 == 0 or !std.mem.eql(u8, std.mem.span(setting.getString(null)), security_setting)) {
            invocation.returnDbusError(nm ++ ".SecretAgent.NoSecrets", "No supported interactive request");
            return;
        }
        self.prompt = invocation;
        self.prompt_path.set(rawpath);
        self.prompt_serial += 1;
        self.err = if (flags.getUint32() & 2 != 0) "Credentials were rejected. Enter a new password." else null;
        self.emit();
    }
};
