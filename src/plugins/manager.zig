//! Session-owned supervisor. All mutation/IPC occurs on the GLib main context.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const m = @import("model.zig");
const wire = @import("protocol.zig");
const discovery_policy = @import("discovery_policy.zig");
const Registry = @import("registry.zig").Registry;
const Transport = @import("../aqueous/transport.zig").Transport;
const activity_policy = @import("activity_policy.zig");
const Broker = @import("../platform/wayland/input_activity.zig").Broker;
const a = std.heap.c_allocator;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});
pub const Status = enum { disabled, starting, active, suspended, failed, unavailable };
pub const Slot = struct {
    owner: *Manager,
    entry: *@import("registry.zig").Entry,
    refs: usize = 1,
    retired: bool = false,
    discovery_error: ?[]const u8 = null,
    shadowed: usize = 0,
    process: ?*gio.Subprocess = null,
    transport: Transport = undefined,
    status: Status = .disabled,
    error_code: ?[]const u8 = null,
    generation: u64 = 0,
    sequence: u64 = 0,
    busy: bool = false,
    deadline: c_uint = 0,
    timer: c_uint = 0,
    scene: ?[]u8 = null,
    config: ?[]u8 = null,
    last_send: i64 = 0,
    test_activity_events: u64 = 0,
    test_painted_us: i64 = 0,
    activity_granted: bool = false,
    activity_requested: bool = false,
    pending_activity: activity_policy.Pending = .{},
    state_sent: activity_policy.HostState = .{},
    callback_inflight: bool = false,
    activity_inflight: bool = false,
    dispatch_source: c_uint = 0,
    timer_due: bool = false,
    pending_click: ?u32 = null,
    pending_preview: bool = false,
    pub fn retain(self: *Slot) void {
        self.refs += 1;
    }
    pub fn release(self: *Slot) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.transport.deinit();
        self.clearView();
        if (self.config) |bytes| a.free(bytes);
        self.entry.release();
        a.destroy(self);
    }
    pub fn activityState(self: *const Slot) activity_policy.HostState {
        var state = self.owner.activity_state;
        if (!self.activity_granted) state.availability = .@"permission-denied";
        return state;
    }

    pub fn id(self: *const Slot) []const u8 {
        return self.entry.package.manifest.id;
    }
    fn clearView(self: *Slot) void {
        if (self.scene) |v| a.free(v);
        self.scene = null;
    }
    fn stop(self: *Slot, status: Status) void {
        self.status = status;
        self.busy = false;
        self.activity_requested = false;
        self.pending_activity.clear();
        self.timer_due = false;
        self.pending_click = null;
        self.pending_preview = false;
        if (self.dispatch_source != 0) _ = glib.Source.remove(self.dispatch_source);
        self.dispatch_source = 0;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = 0;
        self.transport.close();
        self.clearView();
        if (self.process) |process| process.forceExit();
    }
    fn fail(self: *Slot, code: []const u8) void {
        self.error_code = code;
        self.stop(.failed);
        self.owner.changed();
    }
    pub fn send(self: *Slot, event: m.Event) !void {
        if (self.retired or self.process == null or self.owner.locked) return error.PluginBusy;
        if (event.kind == .activate) return self.transmit(event);
        switch (event.kind) {
            .click => self.pending_click = event.node,
            .preview => self.pending_preview = true,
            .timer => self.timer_due = true,
            else => return error.PluginEvent,
        }
        self.flush();
    }
    fn transmit(self: *Slot, event: ?m.Event) !void {
        self.sequence += 1;
        self.state_sent = self.activityState();
        const bytes = try std.json.Stringify.valueAlloc(a, wire.Request{ .generation = self.generation, .sequence = self.sequence, .state = self.state_sent, .event = event }, .{});
        defer a.free(bytes);
        const line = try std.fmt.allocPrint(a, "{s}\n", .{bytes});
        defer a.free(line);
        if (line.len > m.Limits.frame) return error.PluginFrameLimit;
        try self.transport.send(line);
        self.busy = true;
        self.callback_inflight = event != null;
        self.activity_inflight = if (event) |e| e.kind == .activity else false;
        if (event != null) self.last_send = glib.getMonotonicTime();
        self.deadline = glib.timeoutAdd(if (self.sequence == 1) 5000 else 100, expired, self);
    }
    fn dispatch(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        self.dispatch_source = 0;
        self.flush();
        return 0;
    }
    fn flush(self: *Slot) void {
        if (self.busy or self.process == null or self.owner.locked or self.status != .active) return;
        if (!std.meta.eql(self.state_sent, self.activityState())) {
            self.transmit(null) catch |err| self.fail(@errorName(err));
            return;
        }
        if (self.pending_click == null and !self.pending_preview and !self.timer_due and self.pending_activity.mask == 0) return;
        const now = glib.getMonotonicTime();
        const delay = 100_000 - (now - self.last_send);
        if (delay > 0) {
            if (self.dispatch_source == 0) self.dispatch_source = glib.timeoutAdd(@intCast(@divTrunc(delay + 999, 1000)), dispatch, self);
            return;
        }
        var event: m.Event = .{ .kind = .activity, .count = 1, .reduced_motion = self.owner.reduced_motion };
        if (self.pending_click) |node| {
            self.pending_click = null;
            event.kind = .click;
            event.node = node;
        } else if (self.pending_preview) {
            self.pending_preview = false;
            event.kind = .preview;
        } else if (self.timer_due) {
            self.timer_due = false;
            event.kind = .timer;
        } else {
            if (!self.activity_granted or !self.activity_requested or self.activityState().availability != .available) {
                self.pending_activity.clear();
                return;
            }
            if (!self.pending_activity.take(self.owner.activity_state.epoch, now)) return;
        }
        self.transmit(event) catch |err| self.fail(@errorName(err));
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.fail("PluginTimeout");
        return 0;
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.timer_due = true;
        self.flush();
        return 0;
    }
    fn received(data: *anyopaque, event: @import("../aqueous/transport.zig").Event) void {
        const self: *Slot = @ptrCast(@alignCast(data));
        switch (event) {
            .failed => if (self.status == .starting or self.status == .active) self.fail("PluginDisconnected"),
            .frame => |bytes| {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const reply = wire.parse(wire.Reply, arena.allocator(), bytes) catch {
                    self.fail("PluginProtocol");
                    return;
                };
                if (!self.busy or reply.generation != self.generation or reply.sequence != self.sequence) {
                    self.fail("PluginSequence");
                    return;
                }
                if (reply.error_code != null) {
                    self.fail("PluginCallbackFailed");
                    return;
                }
                if (reply.timer_ms != 0 and (reply.timer_ms < 100 or reply.timer_ms > 86400000)) {
                    self.fail("PluginTimerLimit");
                    return;
                }
                if (reply.activity_epoch != self.state_sent.epoch) {
                    self.fail("PluginActivityEpoch");
                    return;
                }
                const current = !self.activity_inflight or std.meta.eql(self.state_sent, self.activityState());
                if (@import("build_options").test_hooks and current and self.activity_inflight) self.test_activity_events += 1;
                if (current) self.activity_requested = self.activity_granted and reply.activity_requested;
                if (!self.activity_requested) self.pending_activity.clear();
                if (current) if (reply.scene) |scene| {
                    scene.validate(self.entry.package.manifest) catch {
                        self.fail("PluginViewInvalid");
                        return;
                    };
                    const next = std.json.Stringify.valueAlloc(a, scene, .{}) catch {
                        self.fail("PluginMemory");
                        return;
                    };
                    self.clearView();
                    self.scene = next;
                };
                if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
                self.deadline = 0;
                self.busy = false;
                self.status = .active;
                if (self.callback_inflight and current and reply.timer_changed) {
                    if (self.timer != 0) _ = glib.Source.remove(self.timer);
                    self.timer = 0;
                    self.timer_due = false;
                    if (reply.timer_ms > 0) self.timer = glib.timeoutAdd(reply.timer_ms, tick, self);
                }
                self.owner.refreshDemand();
                self.flush();
                self.owner.changed();
            },
            else => {},
        }
    }
    fn exited(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Slot = @ptrCast(@alignCast(data.?));
        const process = object.ext.cast(gio.Subprocess, source.?).?;
        _ = process.waitFinish(result, null);
        self.process = null;
        process.unref();
        if (self.status == .active or self.status == .starting) self.fail("PluginExited");
        const owner = self.owner;
        if (!owner.stopped and !self.retired and self.status != .failed) owner.reconcile();
        self.release();
        owner.release();
    }
};
pub const Manager = struct {
    app: *gio.Application,
    context: ?*anyopaque,
    notify: ?*const fn (*anyopaque) void,
    refs: usize = 1,
    stopped: bool = false,
    locked: bool = true,
    reduced_motion: bool = false,
    cancel: *gio.Cancellable,
    roots: [2][:0]const u8,
    registry: ?*Registry = null,
    slots: std.ArrayList(*Slot) = .empty,
    prefs: ?[]u8 = null,
    discovery_error: ?[]const u8 = null,
    next_generation: u64 = 1,
    discovery: @import("discovery.zig").Discovery = undefined,
    requested: u64 = 0,
    completed: u64 = 0,
    revision: u64 = 0,
    scan_ticket: u64 = 0,
    scanning: bool = false,
    scan_error: ?[]const u8 = null,
    refresh_source: c_uint = 0,
    last_scan: i64 = 0,
    first_event: i64 = 0,
    retries: u8 = 0,
    broker: ?*Broker = null,
    activity_state: activity_policy.HostState = .{},
    pub fn setActivity(self: *Manager, state: activity_policy.HostState) void {
        if (std.meta.eql(self.activity_state, state)) return;
        const suspended = self.activity_state.availability == .available and state.availability != .available;
        self.activity_state = state;
        for (self.slots.items) |slot| {
            // Reset guest animation/timer state across compositor privacy gates.
            // Local lock/auth gates already stop all guests through setLocked.
            if (suspended and slot.activity_requested) slot.stop(.suspended);
            slot.pending_activity.clear();
            slot.flush();
        }
        self.changed();
    }
    pub fn noteActivity(self: *Manager, mask: u32, epoch: u64) void {
        if (self.locked or epoch != self.activity_state.epoch or self.activity_state.availability != .available) return;
        for (self.slots.items) |slot| if (slot.status == .active and slot.activity_granted and slot.activity_requested) {
            slot.pending_activity.offer(mask, epoch, glib.getMonotonicTime());
            slot.flush();
        };
    }
    pub fn refreshDemand(self: *Manager) void {
        var wanted = false;
        if (!self.stopped and !self.locked) for (self.slots.items) |slot| {
            if (slot.status == .active and slot.activity_granted and slot.activity_requested) wanted = true;
        };
        if (self.broker) |broker| broker.configure(wanted, !self.stopped and !self.locked);
    }
    pub fn activityReason(self: *const Manager) []const u8 {
        return if (self.broker) |broker| broker.reason() else "Input activity protocol unavailable";
    }

    pub fn create(app: *gio.Application, context: *anyopaque, notify: *const fn (*anyopaque) void) !*Manager {
        const root = if (glib.getenv("XDG_DATA_HOME")) |v| try a.dupeZ(u8, std.mem.span(v)) else try std.fmt.allocPrintSentinel(a, "{s}/.local/share", .{std.mem.span(glib.getenv("HOME") orelse return error.PluginHome)}, 0);
        defer a.free(root);
        const user_path = try std.fs.path.resolve(a, &.{ root, "pearl", "plugins" });
        defer a.free(user_path);
        const user = try a.dupeZ(u8, user_path);
        errdefer a.free(user);
        var executable: [4096]u8 = undefined;
        const path = try @import("../settings/distribution.zig").executable(&executable);
        const system_path = try std.fmt.allocPrintSentinel(a, "{s}/../share/pearl{s}/plugins", .{ std.fs.path.dirname(path).?, if (@import("../settings/distribution.zig").isGit(path)) "-git" else "" }, 0);
        defer a.free(system_path);
        const normalized = try std.fs.path.resolve(a, &.{system_path});
        defer a.free(normalized);
        const system = try a.dupeZ(u8, normalized);
        errdefer a.free(system);
        const self = try a.create(Manager);
        self.* = .{ .app = app, .context = context, .notify = notify, .cancel = gio.Cancellable.new(), .roots = .{ user, system } };
        app.hold();
        self.discovery = .{ .context = self, .request = filesChanged };
        self.discovery.rebuild(&self.roots, &.{}, false);
        _ = self.requestRefresh();
        return self;
    }
    fn filesChanged(data: *anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(data));
        if (self.stopped) return;
        self.requested += 1;
        self.retries = 0;
        const now = glib.getMonotonicTime();
        if (self.first_event == 0) self.first_event = now;
        self.schedule(@min(now + 250_000, self.first_event + 2_000_000));
    }
    pub fn requestRefresh(self: *Manager) u64 {
        if (self.stopped) return self.requested;
        self.requested += 1;
        self.retries = 0;
        self.schedule(glib.getMonotonicTime());
        self.changed();
        return self.requested;
    }
    fn schedule(self: *Manager, desired: i64) void {
        if (self.scanning or self.stopped) return;
        if (self.refresh_source != 0) _ = glib.Source.remove(self.refresh_source);
        const delay = @max(1, @divTrunc(@max(desired, self.last_scan + 1_000_000) - glib.getMonotonicTime() + 999, 1000));
        self.refresh_source = glib.timeoutAdd(@intCast(delay), beginScan, self);
    }
    fn beginScan(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        self.refresh_source = 0;
        self.first_event = 0;
        self.scanning = true;
        self.scan_ticket = self.requested;
        self.scan_error = null;
        self.last_scan = glib.getMonotonicTime();
        const task = gio.Task.new(null, self.cancel, scanned, self);
        task.setTaskData(self, null);
        _ = task.setReturnOnCancel(0);
        self.refs += 1;
        task.runInThread(scan);
        task.unref();
        self.changed();
        return 0;
    }
    fn scan(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        const registry = Registry.scan(&self.roots, cancel.?) catch |err| {
            self.scan_error = @errorName(err);
            task.returnPointer(null, null);
            return;
        };
        task.returnPointer(registry, null);
    }
    fn scanned(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        const task = object.ext.cast(gio.Task, result).?;
        task.setCheckCancellable(0);
        const ptr = task.propagatePointer(null);
        self.scanning = false;
        self.completed = self.scan_ticket;
        if (ptr) |p| {
            const registry: *Registry = @ptrCast(@alignCast(p));
            if (self.stopped or self.requested > self.scan_ticket) registry.destroy() else {
                self.install(registry) catch |err| {
                    registry.destroy();
                    self.scan_error = @errorName(err);
                };
            }
        }
        if (!self.stopped) {
            self.discovery_error = self.scan_error;
            // Errors do not turn a partial scan into mass uninstall. Retry briefly,
            // then rely on a subsequent event, polling or explicit Refresh.
            if ((self.scan_error != null or (self.registry != null and self.registry.?.rejected > 0)) and self.retries < 3) {
                self.retries += 1;
                self.requested += 1;
            }
            if (self.requested > self.completed) self.schedule(glib.getMonotonicTime() + 250_000);
            self.changed();
        }
        self.release();
    }
    fn install(self: *Manager, registry: *Registry) !void {
        var new_directories = self.registry == null;
        if (self.registry) |previous| for (registry.directories.items) |path| {
            if (!previous.containsDirectory(path)) {
                new_directories = true;
                break;
            }
        };
        // Keep an invalid override visible and authoritative until its directory
        // is actually removed. It must never silently reveal a system package.
        for (self.slots.items) |old| {
            var found = false;
            for (registry.entries.items) |entry| if (std.mem.eql(u8, entry.path, old.entry.path)) {
                found = true;
                break;
            };
            if (!found and registry.containsDirectory(old.entry.path)) {
                if (registry.entries.items.len >= m.Limits.packages) return error.PluginPackageLimit;
                if (registry.bytes + old.entry.bytes > 64 * 1024 * 1024) return error.PluginMemoryLimit;
                registry.bytes += old.entry.bytes;
                try registry.entries.append(a, old.entry);
                old.entry.retain();
                if (self.registry) |previous| for (previous.directories.items) |path| {
                    if (std.mem.startsWith(u8, path, old.entry.path)) try registry.directory(path);
                };
            }
        }
        std.mem.sort(*@import("registry.zig").Entry, registry.entries.items, {}, Registry.less);
        var next: std.ArrayList(*Slot) = .empty;
        errdefer {
            for (next.items) |slot| slot.release();
            next.deinit(a);
        }
        try next.ensureTotalCapacity(a, registry.entries.items.len);
        var pos: usize = 0;
        while (pos < registry.entries.items.len) {
            const entry = registry.entries.items[pos];
            var end = pos + 1;
            while (end < registry.entries.items.len and std.mem.eql(u8, entry.package.manifest.id, registry.entries.items[end].package.manifest.id)) : (end += 1) {}
            var reused: ?*Slot = null;
            for (self.slots.items) |old| if (discovery_policy.change(.{ .id = old.id(), .path = old.entry.path, .digest = &old.entry.package.digest }, .{ .id = entry.package.manifest.id, .path = entry.path, .digest = &entry.package.digest }, true) == .unchanged) {
                reused = old;
                break;
            };
            const slot = reused orelse try a.create(Slot);
            if (reused != null) slot.retain() else {
                entry.retain();
                slot.* = .{ .owner = self, .entry = entry };
                slot.transport = Transport.init(slot, Slot.received);
                slot.transport.framer.limit = m.Limits.frame;
            }
            next.appendAssumeCapacity(slot);
            // No fallible work after allocation is committed below.
            pos = end;
        }
        // Install metadata and retire old slots only after all allocations succeed.
        pos = 0;
        for (next.items) |slot| {
            const entry = registry.entries.items[pos];
            var end = pos + 1;
            var same_root: usize = 1;
            while (end < registry.entries.items.len and std.mem.eql(u8, entry.package.manifest.id, registry.entries.items[end].package.manifest.id)) : (end += 1) {
                if (entry.root == registry.entries.items[end].root) same_root += 1;
            }
            var preserved_invalid = false;
            for (self.slots.items) |old| if (old.entry == entry) {
                preserved_invalid = true;
                break;
            };
            const blocked: ?[]const u8 = discovery_policy.conflict(same_root) orelse registry.issue(entry.path) orelse if (preserved_invalid) @as(?[]const u8, "PluginPackageIncomplete") else null;
            if (blocked != null or slot.discovery_error != null) {
                slot.stop(.disabled);
                slot.error_code = null;
            }
            slot.discovery_error = blocked;
            slot.shadowed = end - pos - 1;
            pos = end;
        }
        for (self.slots.items) |old| {
            var kept = false;
            for (next.items) |slot| if (old == slot) {
                kept = true;
                break;
            };
            if (!kept) {
                old.retired = true;
                old.stop(.unavailable);
            }
            old.release();
        }
        self.slots.deinit(a);
        self.slots = next;
        // Drop duplicate worker snapshots for unchanged instances. Otherwise each
        // no-op refresh would retain both a registry and a live copy of every asset.
        for (registry.entries.items) |*record| {
            for (self.slots.items) |slot| if (slot.entry != record.* and std.mem.eql(u8, slot.entry.path, record.*.path) and std.mem.eql(u8, &slot.entry.package.digest, &record.*.package.digest)) {
                record.*.release();
                slot.entry.retain();
                record.* = slot.entry;
                break;
            };
        }
        if (self.registry) |old| old.destroy();
        self.registry = registry;
        self.revision += 1;
        // Verify once after attaching new watches: a file may have changed in the
        // interval between its worker read and installing its directory monitor.
        if (new_directories) self.requested += 1;
        self.discovery.rebuild(&self.roots, registry.directories.items, registry.rejected > 0);
        self.reconcile();
    }
    fn release(self: *Manager) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (self.slots.items) |slot| slot.release();
        self.slots.deinit(a);
        if (self.registry) |registry| registry.destroy();
        if (self.prefs) |v| a.free(v);
        for (self.roots) |root| a.free(root);
        self.cancel.unref();
        self.app.release();
        a.destroy(self);
    }
    pub fn stop(self: *Manager) void {
        self.stopped = true;
        self.notify = null;
        self.context = null;
        self.cancel.cancel();
        self.discovery.deinit();
        if (self.refresh_source != 0) _ = glib.Source.remove(self.refresh_source);
        self.refresh_source = 0;
        for (self.slots.items) |slot| slot.stop(.disabled);
        self.refreshDemand();
        self.broker = null;
        self.release();
    }
    pub fn configure(self: *Manager, prefs: m.Preferences, reduced_motion: bool) void {
        const bytes = std.json.Stringify.valueAlloc(a, prefs, .{}) catch return;
        const motion_changed = self.reduced_motion != reduced_motion;
        self.reduced_motion = reduced_motion;
        if (motion_changed) for (self.slots.items) |slot| {
            if (slot.status == .active or slot.status == .starting) slot.stop(.disabled);
        };
        if (self.prefs) |previous| if (std.mem.eql(u8, previous, bytes)) {
            a.free(bytes);
            if (motion_changed) {
                self.reconcile();
                self.changed();
            }
            return;
        };
        if (self.prefs) |previous| a.free(previous);
        self.prefs = bytes;
        self.reconcile();
    }
    pub fn setLocked(self: *Manager, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        self.reconcile();
        self.changed();
    }
    pub fn changed(self: *Manager) void {
        self.refreshDemand();
        if (!self.stopped) if (self.notify) |notify| notify(self.context.?);
    }
    pub fn retry(self: *Manager, id: []const u8) !void {
        if (self.locked) return error.Locked;
        var found = false;
        for (self.slots.items) |slot| if (std.mem.eql(u8, slot.id(), id)) {
            slot.error_code = null;
            slot.stop(.disabled);
            found = true;
        };
        if (!found) return error.UnknownPlugin;
        self.reconcile();
        self.changed();
    }
    pub fn reconcile(self: *Manager) void {
        if (self.stopped) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const prefs = std.json.parseFromSliceLeaky(m.Preferences, alloc, self.prefs orelse "{}", .{}) catch return;
        for (self.slots.items) |slot| {
            const cfg = prefs.find(slot.id()) orelse m.Config{ .id = slot.id() };
            const bytes = std.json.Stringify.valueAlloc(a, cfg, .{}) catch continue;
            const changed_config = slot.config == null or !std.mem.eql(u8, slot.config.?, bytes);
            if (slot.config) |v| a.free(v);
            slot.config = bytes;
            slot.activity_granted = cfg.grants.input_activity and slot.entry.package.manifest.capabilities.input_activity;
            if (changed_config) {
                slot.error_code = null;
                slot.stop(.disabled);
            }
            if (slot.discovery_error) |err| {
                slot.stop(.unavailable);
                slot.error_code = err;
                continue;
            }
            if (!cfg.enabled) {
                slot.stop(.disabled);
                continue;
            }
            if (self.locked) {
                slot.stop(.suspended);
                continue;
            }
            if (slot.status == .failed or slot.process != null) continue;
            if (!std.mem.eql(u8, cfg.digest, &slot.entry.package.digest)) {
                slot.status = .unavailable;
                slot.error_code = "PluginApprovalRequired";
                continue;
            }
            slot.entry.package.manifest.config(cfg) catch |err| {
                slot.fail(@errorName(err));
                continue;
            };
            if (!@import("build_options").wasm_plugins) {
                slot.status = .unavailable;
                slot.error_code = "PluginRuntimeNotBuilt";
                continue;
            }
            self.startSlot(slot, cfg, alloc) catch |err| slot.fail(@errorName(err));
        }
        self.refreshDemand();
    }
    pub fn sources(self: *Manager, alloc: std.mem.Allocator, id: []const u8) ![]const m.PackageSource {
        var values: std.ArrayList(m.PackageSource) = .empty;
        if (self.registry) |registry| for (registry.entries.items) |entry| {
            if (!std.mem.eql(u8, id, entry.package.manifest.id)) continue;
            if (values.items.len == 4) break;
            try values.append(alloc, .{ .source = if (entry.root == 0) "user" else "system", .path = entry.path, .digest = &entry.package.digest });
        };
        return values.items;
    }
    pub fn report(self: *Manager, alloc: std.mem.Allocator, id: ?[]const u8, offset: usize) ![]const u8 {
        const TestActivity = struct { events: u64, painted_us: i64, scene: m.Scene };
        const Info = struct { sources: []const m.PackageSource, source: []const u8, path: []const u8, shadowed: usize, test_activity: ?TestActivity = null, id: []const u8, name: []const u8, version: []const u8, digest: []const u8, status: Status, error_code: ?[]const u8, generation: u64, nodes: usize, input_activity: activity_policy.Availability, activity_requested: bool, capabilities: m.Grants };
        var infos: std.ArrayList(Info) = .empty;
        const start = @min(offset, self.slots.items.len);
        const end = if (id != null) self.slots.items.len else @min(start + 4, self.slots.items.len);
        for (self.slots.items[start..end]) |slot| {
            if (id) |value| if (!std.mem.eql(u8, value, slot.id())) continue;
            const scene = if (slot.scene) |bytes| try std.json.parseFromSliceLeaky(m.Scene, alloc, bytes, .{}) else m.Scene{ .nodes = &.{} };
            const manifest = slot.entry.package.manifest;
            try infos.append(alloc, .{ .sources = try self.sources(alloc, slot.id()), .source = if (slot.entry.root == 0) "user" else "system", .path = slot.entry.path, .shadowed = slot.shadowed, .test_activity = if (@import("build_options").test_hooks) .{ .events = slot.test_activity_events, .painted_us = slot.test_painted_us, .scene = scene } else null, .id = slot.id(), .name = manifest.name, .version = manifest.version, .digest = &slot.entry.package.digest, .status = slot.status, .error_code = slot.error_code, .generation = slot.generation, .nodes = scene.nodes.len, .input_activity = slot.activityState().availability, .activity_requested = slot.activity_requested, .capabilities = manifest.capabilities });
        }
        if (id != null and infos.items.len == 0) return error.UnknownPlugin;
        var issues: []const @import("registry.zig").Issue = if (self.registry) |registry| registry.issues.items[0..@min(4, registry.issues.items.len)] else &.{};
        var count = infos.items.len;
        var details_truncated = false;
        while (true) {
            const bytes = try std.json.Stringify.valueAlloc(alloc, .{ .version = 1, .loading = self.registry == null and self.discovery_error == null, .pending = self.scanning or self.refresh_source != 0, .requested = self.requested, .completed = self.completed, .discovery_revision = self.revision, .monitoring = if (self.discovery.degraded) "polling" else "watching", .watch_count = self.discovery.watches.items.len, .retained_bytes = Registry.retainedBytes(), .error_code = self.discovery_error, .rejected = if (self.registry) |registry| registry.rejected else 0, .issues = issues, .input_activity = self.activity_state.availability, .input_activity_reason = self.activityReason(), .details_truncated = details_truncated, .packages = infos.items[0..count], .next_offset = if (id == null and start + count < self.slots.items.len) start + count else @as(?usize, null) }, .{ .emit_null_optional_fields = false });
            // Leave room for the CLI response envelope. Long installation paths
            // and conflicts must not make an otherwise valid list unreadable.
            if (bytes.len <= 7600) return bytes;
            alloc.free(bytes);
            if (count > 1) {
                count -= 1;
                continue;
            }
            details_truncated = true;
            if (issues.len > 0) {
                issues = issues[0 .. issues.len - 1];
                continue;
            }
            if (count == 1 and infos.items[0].sources.len > 0) {
                infos.items[0].sources = infos.items[0].sources[0 .. infos.items[0].sources.len - 1];
                continue;
            }
            return error.ResponseTooLarge;
        }
    }
    fn startSlot(self: *Manager, slot: *Slot, cfg: m.Config, alloc: std.mem.Allocator) !void {
        var buffer: [4096]u8 = undefined;
        const exe = try @import("../settings/distribution.zig").executable(&buffer);
        const helper = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl-plugin-host{s}", .{ std.fs.path.dirname(exe).?, if (@import("../settings/distribution.zig").isGit(exe)) "-git" else "" }, 0);
        if (std.c.access(helper, std.c.X_OK) != 0) return error.PluginHelperMissing;
        var pair: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair) != 0) return error.PluginSocket;
        var parent_owned = true;
        defer {
            if (parent_owned) _ = c.close(pair[0]);
        }
        const launcher = gio.SubprocessLauncher.new(.{ .stdout_silence = true, .stderr_silence = true });
        defer launcher.unref();
        launcher.takeFd(pair[1], 3);
        var empty = [_:null]?[*:0]const u8{};
        launcher.setEnviron(@ptrCast(&empty));
        launcher.setenv("PEARL_PLUGIN_PACKAGE", slot.entry.path, 1);
        const hash = try alloc.dupeZ(u8, &slot.entry.package.digest);
        launcher.setenv("PEARL_PLUGIN_DIGEST", hash, 1);
        slot.generation = self.next_generation;
        self.next_generation += 1;
        slot.sequence = 0;
        launcher.setenv("PEARL_PLUGIN_GENERATION", try std.fmt.allocPrintSentinel(alloc, "{d}", .{slot.generation}, 0), 1);
        launcher.setenv("PEARL_PLUGIN_ACTIVITY", if (cfg.grants.input_activity) "1" else "0", 1);
        const argv = [_:null]?[*:0]const u8{helper};
        const process = launcher.spawnv(@ptrCast(&argv), null) orelse return error.PluginSpawn;
        slot.process = process;
        slot.status = .starting;
        slot.error_code = null;
        self.refs += 1;
        slot.retain();
        process.waitAsync(null, Slot.exited, slot);
        const socket = gio.Socket.newFromFd(pair[0], null) orelse return error.PluginSocket;
        parent_owned = false;
        try slot.transport.adopt(socket);
        var settings: std.ArrayList(m.Setting) = .empty;
        for (slot.entry.package.manifest.settings) |spec| {
            var value = spec.default;
            for (cfg.settings) |s| if (std.mem.eql(u8, s.key, spec.key)) {
                value = s.value;
                break;
            };
            try settings.append(alloc, .{ .key = spec.key, .value = value });
        }
        try slot.send(.{ .kind = .activate, .settings = settings.items, .reduced_motion = self.reduced_motion });
    }
};
