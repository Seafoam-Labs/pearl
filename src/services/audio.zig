//! libpulse callbacks share GTK's GLib context. No worker touches these objects.
const std = @import("std");
const glib = @import("glib2");
const p = @import("pulse");
const policy = @import("policy.zig");
const feedback_policy = @import("audio_feedback.zig");
pub const Kind = policy.Kind;
pub const Key = policy.Key;
pub const Write = policy.Write;
const Text = policy.Text;
pub const Event = enum { state, applied, failure };
pub const Device = struct {
    key: Key,
    name: Text(256) = .{},
    label: Text(256) = .{},
    volume: u8 = 0,
    mute: bool = false,
    channels: p.pa_cvolume = std.mem.zeroes(p.pa_cvolume),
    target: u32 = 0,
    writable: bool = true,
};
pub const Audio = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, Event) void,
    loop: ?*p.pa_glib_mainloop = null,
    connection: ?*p.pa_context = null,
    op: ?*p.pa_operation = null,
    subscription: ?*p.pa_operation = null,
    timer: c_uint = 0,
    deadline: c_uint = 0,
    running: bool = false,
    ready: bool = false,
    retry_ms: u32 = 1000,
    generation: u64 = 0,
    devices: [128]Device = undefined,
    count: usize = 0,
    staging: [128]Device = undefined,
    staged: usize = 0,
    truncated: bool = false,
    default_sink: Text(256) = .{},
    default_source: Text(256) = .{},
    scan_sink: Text(256) = .{},
    scan_source: Text(256) = .{},
    phase: u8 = 0,
    dirty: bool = false,
    queue: policy.Queue = .{},
    active: ?Write = null,
    feedback: ?Key = null,
    feedback_write: ?Write = null,
    observed: feedback_policy.Observer = .{},
    snapshot_change: ?feedback_policy.Change = null,
    err: ?[]const u8 = null,
    pub fn start(self: *Audio) void {
        self.running = true;
        self.loop = p.pa_glib_mainloop_new(null);
        self.connect();
    }
    pub fn stop(self: *Audio) void {
        self.running = false;
        self.reset();
        if (self.loop) |loop| p.pa_glib_mainloop_free(loop);
        self.loop = null;
    }
    fn reset(self: *Audio) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.timer = 0;
        self.deadline = 0;
        if (self.op) |op| {
            p.pa_operation_cancel(op);
            p.pa_operation_unref(op);
        }
        if (self.subscription) |op| {
            p.pa_operation_cancel(op);
            p.pa_operation_unref(op);
        }
        self.op = null;
        self.subscription = null;
        if (self.connection) |c| {
            p.pa_context_set_state_callback(c, null, null);
            p.pa_context_set_subscribe_callback(c, null, null);
            p.pa_context_disconnect(c);
            p.pa_context_unref(c);
        }
        self.connection = null;
        self.ready = false;
        self.count = 0;
        self.phase = 0;
        self.queue.len = 0;
        self.active = null;
        self.feedback = null;
        self.feedback_write = null;
        self.observed = .{};
        self.snapshot_change = null;
        self.default_sink = .{};
        self.default_source = .{};
    }
    fn connect(self: *Audio) void {
        self.reset();
        self.generation += 1;
        const loop = self.loop orelse return;
        const c = p.pa_context_new(p.pa_glib_mainloop_get_api(loop), "Pearl") orelse {
            self.failed();
            return;
        };
        self.connection = c;
        p.pa_context_set_state_callback(c, stateChanged, self);
        if (p.pa_context_connect(c, null, p.PA_CONTEXT_NOAUTOSPAWN, null) < 0) {
            self.failed();
            return;
        }
        self.deadline = glib.timeoutAdd(5000, timedOut, self);
    }
    fn failed(self: *Audio) void {
        const report = self.ready or self.active != null or self.queue.len > 0;
        if (self.op) |op| p.pa_operation_cancel(op);
        self.done();
        if (self.subscription) |op| {
            p.pa_operation_cancel(op);
            p.pa_operation_unref(op);
        }
        self.subscription = null;
        self.phase = 0;
        self.feedback = null;
        self.feedback_write = null;
        self.observed = .{};
        self.snapshot_change = null;
        self.ready = false;
        self.count = 0;
        self.queue.len = 0;
        self.active = null;
        self.err = "Audio service disconnected; pending changes were discarded.";
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.timer = glib.timeoutAdd(self.retry_ms, retry, self);
        self.retry_ms = @min(30000, self.retry_ms * 2);
        self.changed(self.context, if (report) .failure else .state);
    }
    fn retry(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(data);
        self.timer = 0;
        if (self.running) self.connect();
        return 0;
    }
    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(data);
        self.deadline = 0;
        self.failed();
        return 0;
    }
    fn cast(data: ?*anyopaque) *Audio {
        return @ptrCast(@alignCast(data.?));
    }
    fn stateChanged(c: ?*p.pa_context, data: ?*anyopaque) callconv(.c) void {
        const self = cast(data);
        switch (p.pa_context_get_state(c)) {
            p.PA_CONTEXT_READY => {
                if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
                self.deadline = 0;
                self.retry_ms = 1000;
                self.ready = true;
                self.err = null;
                p.pa_context_set_subscribe_callback(c, subscribed, self);
                self.subscription = p.pa_context_subscribe(c, p.PA_SUBSCRIPTION_MASK_SINK | p.PA_SUBSCRIPTION_MASK_SOURCE | p.PA_SUBSCRIPTION_MASK_SINK_INPUT | p.PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT | p.PA_SUBSCRIPTION_MASK_SERVER, subscriptionDone, self);
                self.dirty = true;
                self.arm();
            },
            p.PA_CONTEXT_FAILED, p.PA_CONTEXT_TERMINATED => self.failed(),
            else => {},
        }
    }
    fn subscriptionDone(_: ?*p.pa_context, success: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(data);
        if (self.subscription) |op| p.pa_operation_unref(op);
        self.subscription = null;
        if (success == 0) self.failed();
    }
    fn subscribed(_: ?*p.pa_context, _: p.pa_subscription_event_type_t, _: u32, data: ?*anyopaque) callconv(.c) void {
        const self = cast(data);
        self.dirty = true;
        self.arm();
    }
    pub fn find(self: *const Audio, key: Key) ?*const Device {
        for (self.devices[0..self.count]) |*d| if (std.meta.eql(d.key, key)) return d;
        return null;
    }
    pub fn default(self: *const Audio, kind: Kind) ?*const Device {
        const name = if (kind == .sink) self.default_sink.slice() else self.default_source.slice();
        for (self.devices[0..self.count]) |*d| if (d.key.kind == kind and std.mem.eql(u8, d.name.slice(), name)) return d;
        return null;
    }
    pub fn desiredMute(self: *const Audio, key: Key) bool {
        for (self.queue.items[0..self.queue.len]) |write| if (std.meta.eql(write.key, key)) {
            if (write.mute) |value| return value;
        };
        if (self.active) |write| if (std.meta.eql(write.key, key)) {
            if (write.mute) |value| return value;
        };
        return if (self.find(key)) |device| device.mute else false;
    }
    pub fn request(self: *Audio, write: Write) !void {
        if (!self.ready) return error.Unavailable;
        const device = self.find(write.key) orelse return error.Unavailable;
        if (write.volume) |v| if (v > 100 or !device.writable) return error.InvalidValue;
        if (write.default and write.key.kind != .sink and write.key.kind != .source) return error.InvalidValue;
        if (write.move) |index| {
            const kind: Kind = switch (write.key.kind) {
                .playback => .sink,
                .recording => .source,
                else => return error.InvalidValue,
            };
            if (self.find(.{ .generation = self.generation, .kind = kind, .index = index }) == null) return error.Unavailable;
        }
        try self.queue.put(write);
        self.err = null;
        self.arm();
        self.changed(self.context, .state);
    }
    fn arm(self: *Audio) void {
        if (self.running and self.ready and self.timer == 0 and self.op == null) self.timer = glib.timeoutAdd(35, pump, self);
    }
    fn pump(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(data);
        self.timer = 0;
        if (!self.ready or self.op != null) return 0;
        if (self.phase != 0) {
            self.scan();
            return 0;
        }
        if (self.queue.take()) |write| {
            self.send(write);
            return 0;
        }
        if (self.dirty) {
            self.dirty = false;
            self.staged = 0;
            self.truncated = false;
            self.phase = 1;
            self.scan();
        }
        return 0;
    }
    fn own(self: *Audio, op: ?*p.pa_operation) void {
        self.op = op;
        if (op == null) {
            self.failed();
            return;
        }
        self.deadline = glib.timeoutAdd(5000, timedOut, self);
    }
    fn done(self: *Audio) void {
        if (self.op) |op| p.pa_operation_unref(op);
        self.op = null;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
    }
    fn scan(self: *Audio) void {
        const c = self.connection;
        self.own(switch (self.phase) {
            1 => p.pa_context_get_server_info(c, serverInfo, self),
            2 => p.pa_context_get_sink_info_list(c, sinkInfo, self),
            3 => p.pa_context_get_source_info_list(c, sourceInfo, self),
            4 => p.pa_context_get_sink_input_info_list(c, playbackInfo, self),
            5 => p.pa_context_get_source_output_info_list(c, recordingInfo, self),
            else => unreachable,
        });
    }
    fn next(self: *Audio, eol: c_int) void {
        self.done();
        if (eol < 0) {
            self.failed();
            return;
        }
        self.phase += 1;
        if (self.phase == 6) {
            self.phase = 0;
            self.count = self.staged;
            @memcpy(self.devices[0..self.count], self.staging[0..self.count]);
            self.default_sink = self.scan_sink;
            self.default_source = self.scan_source;
            self.snapshot_change = self.observed.observe(if (self.default(.sink)) |d| feedback_policy.Volume.from(d) else null);
            self.changed(self.context, if (self.feedback != null) .applied else .state);
            self.snapshot_change = null;
            self.feedback = null;
            self.feedback_write = null;
        }
        self.arm();
    }
    fn serverInfo(_: ?*p.pa_context, info: [*c]const p.pa_server_info, data: ?*anyopaque) callconv(.c) void {
        const self = cast(data);
        if (info == null) {
            self.done();
            self.failed();
            return;
        }
        self.scan_sink.set(span(info.*.default_sink_name));
        self.scan_source.set(span(info.*.default_source_name));
        self.next(1);
    }
    fn add(self: *Audio, kind: Kind, index: u32, name: [*c]const u8, label: [*c]const u8, volume: p.pa_cvolume, mute: c_int, target: u32, writable: bool) void {
        if (span(name).len > 256 or self.staged == self.staging.len) {
            self.truncated = true;
            return;
        }
        var d: Device = .{ .key = .{ .generation = self.generation, .kind = kind, .index = index }, .channels = volume, .mute = mute != 0, .target = target, .writable = writable };
        d.name.set(span(name));
        d.label.set(span(label));
        d.volume = @intCast(@min(100, (@as(u64, p.pa_cvolume_max(&volume)) * 100 + p.PA_VOLUME_NORM / 2) / p.PA_VOLUME_NORM));
        self.staging[self.staged] = d;
        self.staged += 1;
    }
    fn span(s: [*c]const u8) []const u8 {
        return if (s == null) "" else std.mem.span(s);
    }
    fn sinkInfo(_: ?*p.pa_context, info: [*c]const p.pa_sink_info, eol: c_int, data: ?*anyopaque) callconv(.c) void {
        const s = cast(data);
        if (eol != 0) {
            s.next(eol);
            return;
        }
        if (info == null) return;
        const i = info.*;
        s.add(.sink, i.index, i.name, i.description, i.volume, i.mute, 0, true);
    }
    fn sourceInfo(_: ?*p.pa_context, info: [*c]const p.pa_source_info, eol: c_int, data: ?*anyopaque) callconv(.c) void {
        const s = cast(data);
        if (eol != 0) {
            s.next(eol);
            return;
        }
        if (info == null) return;
        const i = info.*;
        s.add(.source, i.index, i.name, i.description, i.volume, i.mute, 0, true);
    }
    fn playbackInfo(_: ?*p.pa_context, info: [*c]const p.pa_sink_input_info, eol: c_int, data: ?*anyopaque) callconv(.c) void {
        const s = cast(data);
        if (eol != 0) {
            s.next(eol);
            return;
        }
        if (info == null) return;
        const i = info.*;
        s.add(.playback, i.index, i.name, i.name, i.volume, i.mute, i.sink, i.has_volume != 0 and i.volume_writable != 0);
    }
    fn recordingInfo(_: ?*p.pa_context, info: [*c]const p.pa_source_output_info, eol: c_int, data: ?*anyopaque) callconv(.c) void {
        const s = cast(data);
        if (eol != 0) {
            s.next(eol);
            return;
        }
        if (info == null) return;
        const i = info.*;
        s.add(.recording, i.index, i.name, i.name, i.volume, i.mute, i.source, i.has_volume != 0 and i.volume_writable != 0);
    }
    fn send(self: *Audio, write: Write) void {
        const d = self.find(write.key) orelse {
            self.err = "Audio device disappeared.";
            self.changed(self.context, .failure);
            self.arm();
            return;
        };
        const c = self.connection;
        const id = write.key.index;
        const kind = write.key.kind;
        self.active = write;
        const op = if (write.volume) |v| blk: {
            var volume = d.channels;
            // Scale relative channels to preserve balance; initialize silent channels uniformly.
            const target: u32 = @intCast(@as(u64, v) * p.PA_VOLUME_NORM / 100);
            if (p.pa_cvolume_max(&volume) == 0) {
                _ = p.pa_cvolume_set(&volume, volume.channels, target);
            } else {
                _ = p.pa_cvolume_scale(&volume, target);
            }
            break :blk switch (kind) {
                .sink => p.pa_context_set_sink_volume_by_index(c, id, &volume, written, self),
                .source => p.pa_context_set_source_volume_by_index(c, id, &volume, written, self),
                .playback => p.pa_context_set_sink_input_volume(c, id, &volume, written, self),
                .recording => p.pa_context_set_source_output_volume(c, id, &volume, written, self),
            };
        } else if (write.mute) |mute| switch (kind) {
            .sink => p.pa_context_set_sink_mute_by_index(c, id, @intFromBool(mute), written, self),
            .source => p.pa_context_set_source_mute_by_index(c, id, @intFromBool(mute), written, self),
            .playback => p.pa_context_set_sink_input_mute(c, id, @intFromBool(mute), written, self),
            .recording => p.pa_context_set_source_output_mute(c, id, @intFromBool(mute), written, self),
        } else if (write.default) (if (kind == .sink) p.pa_context_set_default_sink(c, d.name.z(), written, self) else p.pa_context_set_default_source(c, d.name.z(), written, self)) else switch (kind) {
            .playback => p.pa_context_move_sink_input_by_index(c, id, write.move.?, written, self),
            .recording => p.pa_context_move_source_output_by_index(c, id, write.move.?, written, self),
            else => unreachable,
        };
        self.own(op);
    }
    fn written(_: ?*p.pa_context, success: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(data);
        self.done();
        if (success == 0) {
            self.err = "Audio change rejected by the server.";
            self.changed(self.context, .failure);
        } else if (self.active) |write| {
            self.feedback = write.key;
            self.feedback_write = write;
            self.err = null;
        }
        self.active = null;
        self.dirty = true;
        self.arm();
    }
};
