//! Borrowed live-service adapters. Leases and confirmations belong to a peer.
const std = @import("std");
const glib = @import("glib2");
const p = @import("editor_protocol.zig");
const ui = @import("live_protocol.zig");
const nav = @import("../desktop/settings_navigation.zig");
const Owner = @import("../services/view_ownership.zig").Owner;
const a = std.heap.c_allocator;
pub const Scope = struct {
    media: bool = false,
    network: ?Owner = null,
    bluetooth: ?Owner = null,
    power: ?Owner = null,
    confirmation: ?u64 = null,
    power_confirmation: ?struct { serial: u64, reboot: bool, deadline: i64 } = null,
};
pub const Pending = enum { none, audio, network, scan, bluetooth, discovery, brightness, profile, power, media, lifecycle, layout };
pub const Live = struct {
    night_light: ?*@import("../services/night_light.zig").NightLight = null,
    plugins: ?*@import("../plugins/manager.zig").Manager = null,
    audio: *@import("../services/audio.zig").Audio,
    network: *@import("../services/network.zig").Network,
    bluetooth: *@import("../services/bluetooth.zig").Bluetooth,
    power: *@import("../services/power.zig").Power,
    session: *@import("../services/session.zig").Session,
    lifecycle: *@import("../services/lifecycle.zig").Lifecycle,
    layout: ?*@import("../platform/wayland/layout.zig").Layout = null,
    layout_context: ?*anyopaque = null,
    layout_rows: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![]const ui.Row = null,
    launcher_icon_retry: ?*const fn (*anyopaque, @import("../desktop/launcher_icon_policy.zig").Config) anyerror!void = null,
    layout_action: ?*const fn (*anyopaque, ui.Layout) anyerror!void = null,
    pub fn release(self: *Live, scope: *Scope) void {
        const previous = scope.*;
        scope.* = .{};
        if (previous.media) self.session.media.view(false);
        if (previous.network) |owner| self.network.releaseView(owner);
        if (previous.bluetooth) |owner| self.bluetooth.releaseView(owner);
        if (previous.power) |owner| self.power.releaseView(owner);
        if (previous.confirmation != null and previous.confirmation == self.lifecycle.confirmation and self.lifecycle.pending != null) self.lifecycle.act("cancel", null) catch {};
    }
    pub fn enter(self: *Live, scope: *Scope, route: nav.Route) !void {
        var next: Scope = .{};
        switch (route) {
            .overview => {
                self.session.media.view(true);
                next.media = true;
            },
            .network => next.network = try self.network.acquireView(),
            .bluetooth => next.bluetooth = try self.bluetooth.acquireView(),
            .power => next.power = try self.power.acquireView(),
            else => {},
        }
        self.release(scope);
        scope.* = next;
    }
    pub fn busy(self: *Live, pending: Pending) bool {
        return switch (pending) {
            .none => false,
            .layout => if (self.layout) |layout| layout.manager != null else false,
            .audio => self.audio.active != null or self.audio.queue.len > 0 or self.audio.feedback != null,
            .network => self.network.pending,
            .scan => self.network.scan_pending,
            .bluetooth => self.bluetooth.pending,
            .discovery => self.bluetooth.discovery_waiting,
            .brightness => self.power.brightness_pending or self.power.brightness_wanted != null,
            .profile => self.power.profile_pending or self.power.profile_wanted != null,
            .power => self.power.action_pending,
            .lifecycle => self.lifecycle.action_busy,
            .media => blk: {
                for (&self.session.media.players) |*player| if (player.busy) break :blk true;
                break :blk false;
            },
        };
    }
    pub fn failure(self: *Live, pending: Pending) ?[]const u8 {
        return switch (pending) {
            .layout => if (self.layout) |layout| layout.err else "Unavailable",
            .audio => self.audio.err,
            .network, .scan => self.network.err,
            .bluetooth, .discovery => self.bluetooth.err,
            .brightness, .profile, .power => self.power.err,
            .lifecycle => self.lifecycle.err,
            .media => self.session.media.err,
            .none => null,
        };
    }
    pub fn perform(self: *Live, scope: *Scope, route: nav.Route, revision: u64, op: ui.Op, params: std.json.Value, alloc: std.mem.Allocator) !Pending {
        switch (op) {
            .@"launcher-icon.retry" => {
                if (route != .bar) return error.WrongPage;
                const v = try p.fields(ui.LauncherIconRetry, alloc, params);
                try v.selection.validate();
                try (self.launcher_icon_retry orelse return error.Unsupported)(self.layout_context.?, v.selection);
                return .none;
            },
            .@"night-light.action" => {
                if (route != .appearance and route != .overview) return error.WrongPage;
                const v = try p.fields(ui.NightLight, alloc, params);
                const service = self.night_light orelse return error.Unsupported;
                service.refresh();
                if (try p.number(v.generation) != service.generation) return error.Stale;
                try service.act(v.action);
                return .none;
            },
            .@"plugin.refresh" => {
                if (route != .plugins) return error.WrongPage;
                _ = try p.fields(ui.PluginRefresh, alloc, params);
                const plugins = self.plugins orelse return error.Unavailable;
                _ = plugins.requestRefresh();
                return .none;
            },
            .@"plugin.action" => {
                if (route != .plugins) return error.WrongPage;
                const v = try p.fields(ui.Plugin, alloc, params);
                const plugins = self.plugins orelse return error.Unavailable;
                switch (v.action) {
                    .retry => try plugins.retry(v.id),
                    .preview => {
                        for (plugins.slots.items) |slot| if (std.mem.eql(u8, slot.id(), v.id) and slot.status == .active) {
                            try slot.send(.{ .kind = .preview, .reduced_motion = plugins.reduced_motion });
                            return .none;
                        };
                        return error.Unavailable;
                    },
                }
                return .none;
            },
            .@"layout.set", .@"layout.get" => {
                if (route != .overview) return error.WrongPage;
                const v = try p.fields(ui.Layout, alloc, params);
                const action = self.layout_action orelse return error.Unsupported;
                try action(self.layout_context.?, v);
                return .layout;
            },
            .@"audio.set" => {
                if (route != .sound) return error.WrongPage;
                const v = try p.fields(ui.Audio, alloc, params);
                try self.audio.request(.{ .key = .{ .generation = try p.number(v.generation), .kind = v.kind, .index = v.device }, .volume = v.volume, .mute = v.mute, .default = v.make_default orelse false, .move = v.target });
                return .audio;
            },
            .@"brightness.set" => {
                if (route != .power or scope.power == null) return error.WrongPage;
                const v = try p.fields(ui.Brightness, alloc, params);
                if (try p.number(v.generation) != self.power.brightnessGeneration()) return error.Stale;
                try self.power.setBrightness(v.percent);
                return .brightness;
            },
            .@"profile.set" => {
                if (route != .power or scope.power == null) return error.WrongPage;
                const v = try p.fields(ui.Profile, alloc, params);
                if (try p.number(v.generation) != self.power.profileGeneration()) return error.Stale;
                for (@import("../services/power.zig").Power.profile_names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, v.profile)) {
                        try self.power.setProfile(@intCast(i));
                        return .profile;
                    }
                }
                return error.InvalidProfile;
            },
            .@"network.editor" => {
                if (route != .network or scope.network == null) return error.WrongPage;
                _ = try p.fields(ui.NetworkEditor, alloc, params);
                return .none;
            },
            .@"network.action" => {
                if (route != .network) return error.WrongPage;
                const owner = scope.network orelse return error.Unavailable;
                const v = try p.fields(ui.Network, alloc, params);
                const generation = try p.number(v.generation);
                if (generation != self.network.peer.epoch) return error.Stale;
                switch (v.action) {
                    .scan => {
                        try self.network.scan(owner, generation, v.path);
                        return .scan;
                    },
                    .connect => try self.network.connectAP(owner, generation, v.path),
                    .connect_saved => try self.network.connectSaved(owner, generation, v.path),
                    .disconnect => try self.network.disconnect(generation, v.path),
                    .enable, .disable => try self.network.setEnabled(v.action == .enable),
                    .cancel => self.network.cancelOwned(owner),
                }
                return .network;
            },
            .@"bluetooth.action" => {
                if (route != .bluetooth) return error.WrongPage;
                const owner = scope.bluetooth orelse return error.Unavailable;
                const v = try p.fields(ui.Bluetooth, alloc, params);
                const generation = try p.number(v.generation);
                if (generation != self.bluetooth.peer.epoch) return error.Stale;
                switch (v.action) {
                    .discover => {
                        try self.bluetooth.discover(owner, generation, v.path);
                        return .discovery;
                    },
                    .stop_discovery => self.bluetooth.stopDiscoveryOwned(owner),
                    .cancel => self.bluetooth.cancelOwned(owner),
                    else => try self.bluetooth.request(owner, generation, v.path, std.meta.stringToEnum(@import("../services/bluetooth.zig").Action, @tagName(v.action)).?),
                }
                return .bluetooth;
            },
            .@"prompt.answer" => {
                const v = try p.fields(ui.Answer, alloc, params);
                if (v.text) |text| if (text.len > 1024 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSecret;
                if (v.service == .network) {
                    if (route != .network) return error.WrongPage;
                    const owner = scope.network orelse return error.Unavailable;
                    if (!self.network.ownsPrompt(owner) or try p.number(v.prompt) != self.network.prompt_serial) return error.StalePrompt;
                    if (v.accept) try self.network.answer(owner, try p.number(v.prompt), v.text orelse "") else self.network.cancelOwned(owner);
                } else {
                    if (route != .bluetooth) return error.WrongPage;
                    const owner = scope.bluetooth orelse return error.Unavailable;
                    if (!self.bluetooth.ownsPrompt(owner) or try p.number(v.prompt) != self.bluetooth.prompt_serial) return error.StalePrompt;
                    if (!v.accept and self.bluetooth.prompt_kind == .display) self.bluetooth.cancelOwned(owner) else try self.bluetooth.answer(owner, try p.number(v.prompt), v.accept, v.text orelse "");
                }
                return .none; // Answer delivery, not connection/pairing completion.
            },
            .@"notifications.action" => {
                if (route != .notifications) return error.WrongPage;
                const v = try p.fields(ui.Notifications, alloc, params);
                const n = &self.session.notifications;
                switch (v.action) {
                    .dnd_on, .dnd_off => n.setDnd(v.action == .dnd_on),
                    .clear_history => {
                        n.model.clearHistory();
                        n.update();
                    },
                    .dismiss, .invoke => {
                        const record = n.model.find(v.notification orelse return error.InvalidRequest) orelse return error.StaleNotification;
                        if (record.serial != try p.number(v.serial orelse return error.InvalidRequest) or !record.active) return error.StaleNotification;
                        if (v.action == .invoke) try n.invoke(record.id, v.key orelse return error.InvalidRequest) else if (!n.close(record.id, 2)) return error.StaleNotification;
                    },
                }
                return .none;
            },
            .@"lifecycle.action" => {
                if (route != .overview and route != .session and route != .power) return error.WrongPage;
                const v = try p.fields(ui.Lifecycle, alloc, params);
                if (v.action == .confirm or v.action == .cancel) {
                    if (scope.confirmation == null or self.lifecycle.confirmation != scope.confirmation.? or try p.number(v.confirmation orelse return error.InvalidRequest) != scope.confirmation.?) return error.StaleConfirmation;
                } else if (self.lifecycle.pending != null and (v.action == .logout or v.action == .@"suspend" or v.action == .hibernate)) return error.Busy;
                try self.lifecycle.act(@tagName(v.action), if (v.confirmation) |serial| try p.number(serial) else null);
                if (v.action == .logout or v.action == .@"suspend" or v.action == .hibernate) scope.confirmation = self.lifecycle.confirmation;
                return .lifecycle;
            },
            .@"power.action" => {
                if (route != .overview and route != .power and route != .session) return error.WrongPage;
                const v = try p.fields(ui.Power, alloc, params);
                if (v.confirmation) |serial| {
                    const confirmation = scope.power_confirmation orelse return error.StaleConfirmation;
                    if (confirmation.serial != try p.number(serial) or confirmation.reboot != v.reboot or confirmation.deadline < glib.getMonotonicTime()) return error.StaleConfirmation;
                    scope.power_confirmation = null;
                    try self.power.powerAction(v.reboot);
                    return .power;
                }
                scope.power_confirmation = .{ .serial = revision, .reboot = v.reboot, .deadline = glib.getMonotonicTime() + 20000000 };
                return .none;
            },
            .@"media.action" => {
                if (route != .overview and route != .sound) return error.WrongPage;
                const v = try p.fields(ui.Media, alloc, params);
                try self.session.media.act(try p.number(v.generation), std.meta.stringToEnum(@import("../services/mpris.zig").Action, @tagName(v.action)).?, v.position orelse 0);
                return .media;
            },
            else => return error.Unsupported,
        }
    }
    pub fn page(self: *Live, alloc: std.mem.Allocator, scope: *Scope, route: nav.Route, _: u64, offset: usize) !ui.Page {
        if (route == .bar) {
            var widgets: std.ArrayList(@import("bar_model.zig").Plugin) = .empty;
            if (self.plugins) |plugins| for (plugins.slots.items) |slot| {
                if (widgets.items.len == @import("../plugins/model.zig").Limits.packages) break;
                const manifest = slot.entry.package.manifest;
                try widgets.append(alloc, .{ .id = manifest.id, .name = manifest.name, .digest = &slot.entry.package.digest, .available = slot.discovery_error == null, .status = @tagName(slot.status) });
            };
            return .{ .summary = "Default bar layout", .rows = &.{}, .offset = p.num(0), .bar_widgets = widgets.items };
        }
        if (route == .plugins) {
            const plugins = self.plugins orelse return .{ .summary = "Plugin service unavailable", .rows = &.{}, .offset = p.num(0) };
            var infos: std.ArrayList(ui.PluginInfo) = .empty;
            for (plugins.slots.items) |slot| {
                const manifest = slot.entry.package.manifest;
                try infos.append(alloc, .{ .available = slot.discovery_error == null, .sources = try plugins.sources(alloc, slot.id()), .source = if (slot.entry.root == 0) "user" else "system", .path = slot.entry.path, .shadowed = slot.shadowed, .id = manifest.id, .name = manifest.name, .version = manifest.version, .digest = &slot.entry.package.digest, .capabilities = manifest.capabilities, .settings = manifest.settings, .status = @tagName(slot.status), .input_activity = @tagName(slot.activityState().availability), .error_code = slot.error_code });
            }
            const saved = try std.json.parseFromSliceLeaky(@import("../plugins/model.zig").Preferences, alloc, plugins.prefs orelse "{}", .{});
            for (saved.entries) |cfg| {
                var found = false;
                for (plugins.slots.items) |slot| if (std.mem.eql(u8, slot.id(), cfg.id)) {
                    found = true;
                    break;
                };
                if (!found) try infos.append(alloc, .{ .installed = false, .id = cfg.id, .name = cfg.id, .version = "missing", .digest = "", .capabilities = cfg.grants, .settings = &.{}, .status = "missing", .error_code = "PluginPackageMissing" });
            }
            std.mem.sort(ui.PluginInfo, infos.items, {}, struct {
                fn less(_: void, left: ui.PluginInfo, right: ui.PluginInfo) bool {
                    return std.mem.lessThan(u8, left.id, right.id);
                }
            }.less);
            const start = @min(offset, infos.items.len);
            const end = @min(start + 4, infos.items.len);
            return .{ .refresh_available = true, .pending = plugins.scanning or plugins.refresh_source != 0, .requested = p.num(plugins.requested), .completed = p.num(plugins.completed), .discovery_revision = p.num(plugins.revision), .monitoring = if (plugins.discovery.degraded) "polling (30 seconds)" else "watching", .summary = if (plugins.discovery_error) |err| err else if (plugins.registry == null) "Discovering local plugins…" else try std.fmt.allocPrint(alloc, "{d} installed packages · {d} rejected · {s}{s}{s} · {s}", .{ plugins.slots.items.len, plugins.registry.?.rejected, if (plugins.registry.?.issues.items.len > 0) plugins.registry.?.issues.items[0].path else "", if (plugins.registry.?.issues.items.len > 0) ": " else "", if (plugins.registry.?.issues.items.len > 0) plugins.registry.?.issues.items[0].code else "", plugins.activityReason() }), .rows = &.{}, .plugins = infos.items[start..end], .offset = p.num(start), .next_offset = if (end < infos.items.len) p.num(end) else null };
        }
        var rows: std.ArrayList(ui.Row) = .empty;
        var summary: []const u8 = "";
        var pending = false;
        var truncated = false;
        var prompt: ?ui.Prompt = null;
        switch (route) {
            .network => {
                const n = self.network;
                summary = n.err orelse n.peer.err orelse if (n.peer.owner.len == 0) "NetworkManager unavailable" else if (!n.hardware_enabled) "Wi-Fi blocked by hardware" else if (!n.enabled) "Wi-Fi off" else if (n.pending) "Connecting…" else if (n.connectivity == 4) "Online" else "Network connections";
                pending = n.pending or n.scan_pending;
                truncated = n.truncated;
                try rows.append(alloc, .{ .id = "network", .title = "Wi-Fi", .controls = try alloc.dupe(ui.Control, &.{
                    try ui.button(alloc, "radio", if (n.enabled) "Turn off" else "Turn on", .@"network.action", .{ .generation = p.num(n.peer.epoch), .path = "", .action = if (n.enabled) "disable" else "enable" }, n.peer.owner.len != 0 and n.hardware_enabled and !n.pending),
                    try ui.button(alloc, "editor", "Network editor…", .@"network.editor", .{ .view = "", .operation = "" }, true),
                    try ui.button(alloc, "cancel", "Cancel request", .@"network.action", .{ .generation = p.num(n.peer.epoch), .path = "", .action = "cancel" }, n.operation_owner == scope.network and n.pending),
                }) });
                for (n.devices[0..n.device_count]) |*device| try rows.append(alloc, .{ .id = device.path.slice(), .title = device.name.slice(), .detail = try std.fmt.allocPrint(alloc, "Adapter · state {d}", .{device.state}), .controls = try alloc.dupe(ui.Control, &.{
                    try ui.button(alloc, "scan", "Scan", .@"network.action", .{ .generation = p.num(n.peer.epoch), .path = device.path.slice(), .action = "scan" }, device.kind == 2 and n.enabled and n.hardware_enabled and !n.scan_pending),
                    try ui.button(alloc, "disconnect", "Disconnect", .@"network.action", .{ .generation = p.num(n.peer.epoch), .path = device.path.slice(), .action = "disconnect" }, device.active.len > 1),
                }) });
                for (n.aps[0..n.ap_count]) |*ap| try rows.append(alloc, .{ .id = ap.path.slice(), .title = ap.label.slice(), .detail = try std.fmt.allocPrint(alloc, "{d}% · {s}", .{ ap.strength, @tagName(ap.security) }), .controls = try alloc.dupe(ui.Control, &.{try ui.button(alloc, "connect", if (ap.security == .advanced) "Configure…" else "Connect", if (ap.security == .advanced) .@"network.editor" else .@"network.action", if (ap.security == .advanced) try json(alloc, .{ .view = "", .operation = "" }) else try json(alloc, .{ .generation = p.num(n.peer.epoch), .path = ap.path.slice(), .action = "connect" }), !n.pending and (ap.security == .advanced or (if (n.findDevice(ap.device.slice())) |device| n.canConnectDevice(device) else false)))}) });
                for (n.saved[0..n.saved_count]) |*saved| try rows.append(alloc, .{ .id = saved.path.slice(), .title = saved.label.slice(), .detail = "Saved connection", .controls = try alloc.dupe(ui.Control, &.{try ui.button(alloc, "connect", if (saved.security == .advanced) "Configure…" else "Connect saved", if (saved.security == .advanced) .@"network.editor" else .@"network.action", if (saved.security == .advanced) try json(alloc, .{ .view = "", .operation = "" }) else try json(alloc, .{ .generation = p.num(n.peer.epoch), .path = saved.path.slice(), .action = "connect_saved" }), saved.loaded and !n.pending and (saved.security == .advanced or (if (n.findDevice(saved.device.slice())) |device| n.canConnectDevice(device) else false)))}) });
                if (scope.network) |owner| if (n.ownsPrompt(owner) and n.prompt != null) {
                    prompt = .{ .service = .network, .serial = p.num(n.prompt_serial), .kind = "password", .title = n.title.slice(), .secret = true };
                };
            },
            .bluetooth => {
                const b = self.bluetooth;
                summary = b.err orelse b.peer.err orelse if (b.peer.owner.len == 0) "Bluetooth service unavailable" else if (b.pending) "Waiting for device…" else "Bluetooth devices";
                pending = b.pending or b.discovery_waiting;
                truncated = b.truncated;
                try rows.append(alloc, .{ .id = "bluetooth", .title = "Discovery", .detail = "Discovery starts only when requested and stops after 30 seconds.", .controls = try alloc.dupe(ui.Control, &.{
                    try ui.button(alloc, "stop", "Stop discovery", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = "", .action = "stop_discovery" }, scope.bluetooth != null and b.discovery_owner == scope.bluetooth),
                    try ui.button(alloc, "cancel", "Cancel request", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = "", .action = "cancel" }, scope.bluetooth != null and b.operation_owner == scope.bluetooth and b.pending),
                }) });
                for (b.adapters[0..b.adapter_count]) |*adapter| try rows.append(alloc, .{ .id = adapter.path.slice(), .title = adapter.label.slice(), .detail = if (adapter.powered) "On" else "Off", .controls = try alloc.dupe(ui.Control, &.{
                    try ui.button(alloc, "power", if (adapter.powered) "Turn off" else "Turn on", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = adapter.path.slice(), .action = if (adapter.powered) "power_off" else "power_on" }, !b.pending),
                    try ui.button(alloc, "discover", "Discover", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = adapter.path.slice(), .action = "discover" }, adapter.powered and b.discovery_path.len == 0),
                }) });
                for (b.devices[0..b.device_count]) |*device| {
                    const powered = if (b.findAdapter(device.adapter.slice())) |adapter| adapter.powered else false;
                    try rows.append(alloc, .{ .id = device.path.slice(), .title = device.label.slice(), .detail = try std.fmt.allocPrint(alloc, "{s} · {s}{s}", .{ device.address.slice(), if (device.connected) "Connected" else if (device.paired) "Paired" else "Not paired", if (device.trusted) " · Trusted" else "" }), .controls = try alloc.dupe(ui.Control, &.{
                        try ui.button(alloc, "connect", if (device.connected) "Disconnect" else if (device.paired) "Connect" else "Pair", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = device.path.slice(), .action = if (device.connected) "disconnect" else if (device.paired) "connect" else "pair" }, powered and !device.blocked and !b.pending),
                        try ui.button(alloc, "trust", if (device.trusted) "Remove trust" else "Trust", .@"bluetooth.action", .{ .generation = p.num(b.peer.epoch), .path = device.path.slice(), .action = if (device.trusted) "untrust" else "trust" }, powered and device.paired and !device.blocked and !b.pending),
                    }) });
                }
                if (scope.bluetooth) |owner| if (b.ownsPrompt(owner) and b.prompt_kind != .none) {
                    prompt = .{ .service = .bluetooth, .serial = p.num(b.prompt_serial), .kind = @tagName(b.prompt_kind), .title = b.title.slice(), .challenge = b.prompt_text.slice(), .secret = b.prompt_kind == .pin or b.prompt_kind == .passkey, .editable = b.prompt_kind != .display };
                };
            },
            .sound => {
                const sound = self.audio;
                summary = sound.err orelse if (sound.ready) "Sound devices and application streams" else "Audio service unavailable";
                pending = self.busy(.audio);
                truncated = sound.truncated;
                for (sound.devices[0..sound.count]) |*device| {
                    var controls: std.ArrayList(ui.Control) = .empty;
                    var volume = try ui.button(alloc, "volume", "Volume", .@"audio.set", .{ .generation = p.num(device.key.generation), .kind = device.key.kind, .device = device.key.index }, device.writable and sound.ready);
                    volume.kind = .number;
                    volume.field = "volume";
                    volume.value = @floatFromInt(device.volume);
                    volume.max = 150;
                    try controls.append(alloc, volume);
                    try controls.append(alloc, try ui.button(alloc, "mute", if (device.mute) "Unmute" else "Mute", .@"audio.set", .{ .generation = p.num(device.key.generation), .kind = device.key.kind, .device = device.key.index, .mute = !device.mute }, device.writable and sound.ready));
                    if (device.key.kind == .sink or device.key.kind == .source) {
                        const current = sound.default(device.key.kind);
                        try controls.append(alloc, try ui.button(alloc, "default", "Use by default", .@"audio.set", .{ .generation = p.num(device.key.generation), .kind = device.key.kind, .device = device.key.index, .make_default = true }, current == null or current.?.key.index != device.key.index));
                    } else {
                        var choices: std.ArrayList(ui.Choice) = .empty;
                        for (sound.devices[0..sound.count]) |*target| if ((device.key.kind == .playback and target.key.kind == .sink) or (device.key.kind == .recording and target.key.kind == .source)) try choices.append(alloc, .{ .label = try shortLabel(alloc, target.label.slice(), target.key.index), .value = try std.fmt.allocPrint(alloc, "{d}", .{target.key.index}) });
                        var target = try ui.button(alloc, "target", "Device", .@"audio.set", .{ .generation = p.num(device.key.generation), .kind = device.key.kind, .device = device.key.index }, choices.items.len > 0);
                        target.kind = .choice;
                        target.field = "target";
                        target.choices = choices.items;
                        target.value = @floatFromInt(device.target);
                        try controls.append(alloc, target);
                    }
                    try rows.append(alloc, .{ .id = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ @tagName(device.key.kind), device.key.index }), .title = device.label.slice(), .detail = switch (device.key.kind) {
                        .sink => "Audio output",
                        .source => "Audio input",
                        .playback => "Application playback",
                        .recording => "Application recording",
                    }, .controls = controls.items });
                }
            },
            .power => {
                const power = self.power;
                summary = power.err orelse if (power.battery_present) "Power and battery" else "No battery reported";
                pending = self.busy(.brightness) or self.busy(.profile) or self.busy(.power);
                try rows.append(alloc, .{ .id = "battery", .title = if (power.on_battery) "On battery" else "AC power", .detail = if (power.battery_present) try std.fmt.allocPrint(alloc, "{d:.0}% · {s}", .{ power.percentage, if (power.battery_state == 1) "Charging" else if (power.battery_state == 2) "Discharging" else if (power.battery_state == 4) "Fully charged" else "Battery" }) else "Battery information is unavailable on this system." });
                var controls: std.ArrayList(ui.Control) = .empty;
                var brightness = try ui.button(alloc, "brightness", "Brightness", .@"brightness.set", .{ .generation = p.num(power.brightnessGeneration()) }, power.brightnessAvailable());
                brightness.kind = .number;
                brightness.field = "percent";
                brightness.value = @floatFromInt(power.backlight.percent());
                try controls.append(alloc, brightness);
                for (@import("../services/power.zig").Power.profile_names, 0..) |name, i| try controls.append(alloc, try ui.button(alloc, name, switch (i) {
                    0 => "Power saver",
                    1 => "Balanced",
                    else => "Performance",
                }, .@"profile.set", .{ .generation = p.num(power.profileGeneration()), .profile = name }, power.profiles[i] and !std.mem.eql(u8, power.profile.slice(), name)));
                try rows.append(alloc, .{ .id = "power", .title = "Brightness and performance", .detail = power.degraded.slice(), .controls = controls.items });
            },
            .notifications => {
                const n = &self.session.notifications;
                summary = if (n.model.dnd) "Do Not Disturb is on" else "Notification history";
                try rows.append(alloc, .{ .id = "notifications", .title = "Notifications", .controls = try alloc.dupe(ui.Control, &.{
                    try ui.button(alloc, "dnd", if (n.model.dnd) "Turn Do Not Disturb off" else "Turn Do Not Disturb on", .@"notifications.action", .{ .action = if (n.model.dnd) "dnd_off" else "dnd_on" }, true),
                    try ui.button(alloc, "clear", "Clear history", .@"notifications.action", .{ .action = "clear_history" }, true),
                }) });
                for (&n.model.records) |*record| if (record.id != 0) {
                    var controls: std.ArrayList(ui.Control) = .empty;
                    if (record.active) {
                        try controls.append(alloc, try ui.button(alloc, "dismiss", "Dismiss", .@"notifications.action", .{ .action = "dismiss", .notification = record.id, .serial = p.num(record.serial) }, true));
                        for (record.actions[0..record.action_count]) |*action| try controls.append(alloc, try ui.button(alloc, action.key.slice(), action.label.slice(), .@"notifications.action", .{ .action = "invoke", .notification = record.id, .serial = p.num(record.serial), .key = action.key.slice() }, true));
                    }
                    try rows.append(alloc, .{ .id = try std.fmt.allocPrint(alloc, "{d}:{d}", .{ record.id, record.serial }), .title = record.summary.slice(), .detail = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ record.app.slice(), record.body.slice() }), .controls = controls.items });
                };
            },
            .overview, .session => summary = "Session controls",
            else => {},
        }
        if (route == .overview or route == .session or route == .power) {
            const life = self.lifecycle;
            var controls: std.ArrayList(ui.Control) = .empty;
            for ([_][]const u8{ "lock", "suspend", "hibernate", "logout", if (life.idle_held) "uninhibit" else "inhibit" }) |action| try controls.append(alloc, try ui.button(alloc, action, if (std.mem.eql(u8, action, "inhibit")) "Pause automatic idle" else if (std.mem.eql(u8, action, "uninhibit")) "Resume automatic idle" else if (std.mem.eql(u8, action, "lock")) "Lock" else if (std.mem.eql(u8, action, "suspend")) "Suspend" else if (std.mem.eql(u8, action, "hibernate")) "Hibernate" else "Log out…", .@"lifecycle.action", .{ .action = action }, life.gate.active and life.gate.available and !life.gate.preparing and (if (std.mem.eql(u8, action, "lock")) life.lock_supported else if (std.mem.eql(u8, action, "suspend")) life.can_suspend and life.delay_fd >= 0 else if (std.mem.eql(u8, action, "hibernate")) life.can_hibernate and life.delay_fd >= 0 else true)));
            if (scope.confirmation != null and scope.confirmation == life.confirmation and life.pending != null) {
                try controls.append(alloc, try ui.button(alloc, "confirm", "Confirm session action", .@"lifecycle.action", .{ .action = "confirm", .confirmation = p.num(scope.confirmation.?) }, true));
                try controls.append(alloc, try ui.button(alloc, "cancel", "Cancel session action", .@"lifecycle.action", .{ .action = "cancel", .confirmation = p.num(scope.confirmation.?) }, true));
            }
            for ([_]bool{ false, true }) |reboot| {
                const confirmation = if (scope.power_confirmation) |c| if (c.reboot == reboot and c.deadline > glib.getMonotonicTime()) @as(?p.Number, p.num(c.serial)) else null else null;
                try controls.append(alloc, try ui.button(alloc, if (reboot) "reboot" else "shutdown", if (confirmation != null) (if (reboot) "Confirm restart" else "Confirm shutdown") else if (reboot) "Restart…" else "Shut down…", .@"power.action", .{ .reboot = reboot, .confirmation = confirmation }, if (reboot) self.power.can_reboot else self.power.can_off));
            }
            try rows.append(alloc, .{ .id = "session", .title = "Session", .detail = life.err orelse "Lock your session, manage automatic idle, or shut down.", .controls = controls.items });
        }
        if (route == .overview) {
            if (self.layout_rows) |get| try rows.appendSlice(alloc, try get(self.layout_context.?, alloc));
            for (&self.session.media.players) |*player| if (player.name.len > 0) {
                var controls: std.ArrayList(ui.Control) = .empty;
                for ([_][]const u8{ "select", "play_pause", "play", "pause", "stop", "next", "previous" }, [_][]const u8{ "Use this player", "Play / pause", "Play", "Pause", "Stop", "Next", "Previous" }) |action, label| try controls.append(alloc, try ui.button(alloc, action, label, .@"media.action", .{ .generation = p.num(player.generation), .action = action }, player.ready and !player.busy and (if (std.mem.eql(u8, action, "select")) true else player.control and (if (std.mem.eql(u8, action, "play")) player.play else if (std.mem.eql(u8, action, "pause")) player.pause else if (std.mem.eql(u8, action, "next")) player.next else if (std.mem.eql(u8, action, "previous")) player.previous else if (std.mem.eql(u8, action, "play_pause")) (if (std.mem.eql(u8, player.playback.slice(), "Playing")) player.pause else player.play) else true))));
                var seek = try ui.button(alloc, "seek", "Position (seconds)", .@"media.action", .{ .generation = p.num(player.generation), .action = "seek" }, player.seek and !player.busy);
                seek.kind = .number;
                seek.field = "position";
                seek.max = @as(f64, @floatFromInt(@max(0, player.length))) / 1_000_000;
                seek.value = @as(f64, @floatFromInt(player.progress())) / 1_000_000;
                try controls.append(alloc, seek);
                try rows.append(alloc, .{ .id = player.name.slice(), .title = player.identity.slice(), .detail = player.title.slice(), .controls = controls.items });
            };
        }
        const first = @min(offset, rows.items.len);
        const end = @min(first + 16, rows.items.len);
        return .{ .summary = summary, .pending = pending, .truncated = truncated, .rows = rows.items[first..end], .offset = p.num(first), .next_offset = if (end < rows.items.len) p.num(end) else null, .prompt = prompt };
    }
};
fn json(alloc: std.mem.Allocator, value: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, value, .{}), .{});
}

fn shortLabel(alloc: std.mem.Allocator, label: []const u8, index: u32) ![]const u8 {
    var end = @min(label.len, 32);
    while (end < label.len and end > 0 and label[end] & 0xc0 == 0x80) end -= 1;
    const short = try alloc.dupe(u8, label[0..end]);
    for (short) |*byte| if (byte.* < 32) {
        byte.* = ' ';
    };
    return std.fmt.allocPrint(alloc, "{s}{s} ({d})", .{ short, if (end < label.len) "…" else "", index });
}
