//! Session-owned supervisor. All mutation/IPC occurs on the GLib main context.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const m = @import("model.zig");
const wire = @import("protocol.zig");
const Registry = @import("registry.zig").Registry;
const Transport = @import("../aqueous/transport.zig").Transport;
const a = std.heap.c_allocator;
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});
pub const Status = enum { disabled, starting, active, suspended, failed, unavailable };
pub const Slot = struct {
    owner: *Manager,
    entry: @import("registry.zig").Entry,
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
        if (self.process == null or self.busy or self.owner.locked) return error.PluginBusy;
        const now = glib.getMonotonicTime();
        if (self.sequence != 0 and now - self.last_send < 100_000) return error.PluginRateLimited;
        self.sequence += 1;
        const bytes = try std.json.Stringify.valueAlloc(a, wire.Request{ .generation = self.generation, .sequence = self.sequence, .event = event }, .{});
        defer a.free(bytes);
        const line = try std.fmt.allocPrint(a, "{s}\n", .{bytes});
        defer a.free(line);
        if (line.len > m.Limits.frame) return error.PluginFrameLimit;
        try self.transport.send(line);
        self.busy = true;
        self.last_send = now;
        self.deadline = glib.timeoutAdd(if (self.sequence == 1) 5000 else 100, expired, self);
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
        if (self.busy) {
            self.timer = glib.timeoutAdd(100, tick, self);
            return 0;
        }
        self.send(.{ .kind = .timer, .reduced_motion = self.owner.reduced_motion }) catch |err| self.fail(@errorName(err));
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
                if (reply.scene) |scene| {
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
                }
                if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
                self.deadline = 0;
                self.busy = false;
                self.status = .active;
                if (self.timer != 0) _ = glib.Source.remove(self.timer);
                self.timer = 0;
                if (reply.timer_ms > 0) self.timer = glib.timeoutAdd(reply.timer_ms, tick, self);
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
        if (!owner.stopped and self.status != .failed) owner.reconcile();
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
    pub fn create(app: *gio.Application, context: *anyopaque, notify: *const fn (*anyopaque) void) !*Manager {
        const root = if (glib.getenv("XDG_DATA_HOME")) |v| try a.dupeZ(u8, std.mem.span(v)) else try std.fmt.allocPrintSentinel(a, "{s}/.local/share", .{std.mem.span(glib.getenv("HOME") orelse return error.PluginHome)}, 0);
        defer a.free(root);
        const user = try std.fmt.allocPrintSentinel(a, "{s}/pearl/plugins", .{root}, 0);
        errdefer a.free(user);
        var executable: [4096]u8 = undefined;
        const path = try @import("../settings/distribution.zig").executable(&executable);
        const system = try std.fmt.allocPrintSentinel(a, "{s}/../share/pearl{s}/plugins", .{ std.fs.path.dirname(path).?, if (@import("../settings/distribution.zig").isGit(path)) "-git" else "" }, 0);
        const self = try a.create(Manager);
        self.* = .{ .app = app, .context = context, .notify = notify, .cancel = gio.Cancellable.new(), .roots = .{ user, system } };
        app.hold();
        const task = gio.Task.new(null, self.cancel, scanned, self);
        task.setTaskData(self, null);
        _ = task.setReturnOnCancel(0);
        self.refs += 1;
        task.runInThread(scan);
        task.unref();
        return self;
    }
    fn scan(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        const registry = Registry.scan(&self.roots, cancel.?) catch {
            task.returnPointer(null, null);
            return;
        };
        task.returnPointer(registry, null);
    }
    fn scanned(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@alignCast(data.?));
        // Disable automatic cancellation propagation so returned snapshots are freed.
        const task = object.ext.cast(gio.Task, result).?;
        task.setCheckCancellable(0);
        const ptr = task.propagatePointer(null);
        if (ptr) |p| {
            const registry: *Registry = @ptrCast(@alignCast(p));
            if (self.stopped) registry.destroy() else {
                self.registry = registry;
                for (registry.entries.items) |entry| {
                    const slot = a.create(Slot) catch break;
                    slot.* = .{ .owner = self, .entry = entry };
                    slot.transport = Transport.init(slot, Slot.received);
                    slot.transport.framer.limit = m.Limits.frame;
                    self.slots.append(a, slot) catch {
                        slot.transport.deinit();
                        a.destroy(slot);
                        break;
                    };
                }
                self.reconcile();
                self.changed();
            }
        } else {
            self.discovery_error = "PluginDiscoveryFailed";
            self.changed();
        }
        self.release();
    }
    fn release(self: *Manager) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        for (self.slots.items) |slot| {
            slot.transport.deinit();
            slot.clearView();
            if (slot.config) |v| a.free(v);
            a.destroy(slot);
        }
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
        for (self.slots.items) |slot| slot.stop(.disabled);
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
            if (changed_config) {
                slot.error_code = null;
                slot.stop(.disabled);
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
    }
    pub fn report(self: *Manager, alloc: std.mem.Allocator, id: ?[]const u8, offset: usize) ![]const u8 {
        const Info = struct { id: []const u8, name: []const u8, version: []const u8, digest: []const u8, status: Status, error_code: ?[]const u8, generation: u64, nodes: usize, capabilities: m.Grants };
        var infos: std.ArrayList(Info) = .empty;
        const start = @min(offset, self.slots.items.len);
        const end = if (id != null) self.slots.items.len else @min(start + 4, self.slots.items.len);
        for (self.slots.items[start..end]) |slot| {
            if (id) |value| if (!std.mem.eql(u8, value, slot.id())) continue;
            const scene = if (slot.scene) |bytes| try std.json.parseFromSliceLeaky(m.Scene, alloc, bytes, .{}) else m.Scene{ .nodes = &.{} };
            const manifest = slot.entry.package.manifest;
            try infos.append(alloc, .{ .id = slot.id(), .name = manifest.name, .version = manifest.version, .digest = &slot.entry.package.digest, .status = slot.status, .error_code = slot.error_code, .generation = slot.generation, .nodes = scene.nodes.len, .capabilities = manifest.capabilities });
        }
        if (id != null and infos.items.len == 0) return error.UnknownPlugin;
        return std.json.Stringify.valueAlloc(alloc, .{ .version = 1, .loading = self.registry == null and self.discovery_error == null, .error_code = self.discovery_error, .input_activity = "unsupported", .packages = infos.items, .next_offset = if (end < self.slots.items.len) end else @as(?usize, null) }, .{});
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
