//! One bounded watch worker owns every filesystem syscall and inotify handle.
//! GTK exchanges immutable plans and bounded notification mailboxes; it never
//! registers, resolves, reads or closes a filesystem watch handle.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const linux = std.os.linux;
pub const limit = 128;
pub const byte_limit = 128 * 1024;
pub const read_byte_limit = 32 * 1024;
pub const overflow_index = std.math.maxInt(usize) - 1;
pub const manifest_index = std.math.maxInt(usize);
pub const Event = extern struct { wd: i32, mask: u32, cookie: u32, len: u32 };
const Spec = struct { path: [:0]u8, node: usize, filter: ?[:0]u8, descriptor: i32 = -1 };
const Root = struct { lexical: [:0]u8, canonical: ?[:0]u8 };
const root_limit = @import("manifest.zig").limits.roots;
const Plan = struct {
    items: std.ArrayList(Spec) = .empty,
    roots: std.ArrayList(Root) = .empty,
    bytes: usize = 0,
    manifest: ?[:0]u8 = null,
    generation: u64 = 0,
    failed: bool = false,
    policy_failed: bool = false,
    disabled: bool = false,
    delay_us: c_ulong = 0,
    fn deinit(self: *Plan) void {
        for (self.items.items) |item| {
            a.free(item.path);
            if (item.filter) |filter| a.free(filter);
        }
        self.items.deinit(a);
        for (self.roots.items) |root| {
            a.free(root.lexical);
            if (root.canonical) |path| a.free(path);
        }
        self.roots.deinit(a);
        if (self.manifest) |path| a.free(path);
        self.* = .{};
    }
    fn addRoot(self: *Plan, lexical: []const u8, canonical: ?[]const u8) void {
        const bytes = lexical.len + 1 + if (canonical) |path| path.len + 1 else @as(usize, 0);
        if (self.roots.items.len == root_limit or lexical.len > 4095 or bytes > byte_limit - self.bytes) {
            self.failed = true;
            self.policy_failed = true;
            return;
        }
        self.roots.append(a, .{ .lexical = u.z(lexical), .canonical = if (canonical) |path| u.z(path) else null }) catch unreachable;
        self.bytes += bytes;
    }
    fn add(self: *Plan, path: []const u8, node: usize, filter: ?[]const u8) ?usize {
        for (self.items.items, 0..) |item, i| if (item.node == node and std.mem.eql(u8, item.path, path) and (item.filter == null) == (filter == null) and std.mem.eql(u8, item.filter orelse "", filter orelse "")) return i;
        const bytes = path.len + 1 + if (filter) |f| f.len + 1 else @as(usize, 0);
        if (self.items.items.len == limit or bytes > byte_limit - self.bytes) {
            self.failed = true;
            if (node == manifest_index) self.policy_failed = true;
            return null;
        }
        self.items.append(a, .{ .path = u.z(path), .node = node, .filter = if (filter) |f| u.z(f) else null }) catch unreachable;
        self.bytes += bytes;
        return self.items.items.len - 1;
    }
};
const Notice = struct { node: usize, rearm: bool };
const Batch = struct {
    items: [limit]Notice = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn add(self: *Batch, node: usize, rearm: bool) void {
        if (node == overflow_index) {
            self.overflow = true;
            return;
        }
        for (self.items[0..self.len]) |*item| if (item.node == node) {
            item.rearm = item.rearm or rearm;
            return;
        };
        if (self.len == limit) {
            self.overflow = true;
            return;
        }
        self.items[self.len] = .{ .node = node, .rearm = rearm };
        self.len += 1;
    }
};
const ReadResult = struct {
    events: Batch = .{},
    state: enum { pending, drained, unavailable } = .pending,
    bytes: usize = 0,
};
const Snapshot = struct {
    plan: Plan = .{},
    fd: c_int = -1,
    fn deinit(self: *Snapshot) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.plan.deinit();
        self.* = .{};
    }
    fn register(self: *Snapshot, owner: *Watches, path: []const u8, node: usize, filter: ?[]const u8) bool {
        if (owner.obsolete(self.plan.generation)) return false;
        const index = self.plan.add(path, node, filter) orelse return false;
        const item = &self.plan.items.items[index];
        if (item.descriptor >= 0) return true;
        if (self.fd < 0) return false;
        const mask = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVE | linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW;
        const result = linux.inotify_add_watch(self.fd, item.path, mask);
        if (linux.errno(result) != .SUCCESS) {
            self.plan.failed = true;
            if (node == manifest_index) self.plan.policy_failed = true;
            return false;
        }
        item.descriptor = @intCast(result);
        return true;
    }
    fn chain(self: *Snapshot, owner: *Watches, path: []const u8) bool {
        var child = path;
        while (std.fs.path.dirname(child)) |parent| {
            if (!self.register(owner, parent, manifest_index, std.fs.path.basename(child))) return false;
            child = parent;
        }
        return true;
    }
    fn identityPath(self: *Snapshot, owner: *Watches, lexical: []const u8, root: ?Root) bool {
        if (!std.fs.path.isAbsolute(lexical) or lexical.len > 4095) return false;
        // Walk left to right and subscribe BEFORE resolving each component. Do
        // not register unresolved symlink parents with IN_DONT_FOLLOW, or erase
        // '..' before the preceding links have supplied its physical meaning.
        var path = u.z(lexical);
        defer a.free(path);
        var hops: usize = 0;
        var end: usize = 1;
        while (end <= path.len and !owner.obsolete(self.plan.generation)) {
            if (end < path.len and path[end] != '/') {
                end += 1;
                continue;
            }
            const prefix = u.z(path[0..end]);
            defer a.free(prefix);
            if (std.fs.path.dirname(prefix)) |parent| {
                if (!self.register(owner, parent, manifest_index, std.fs.path.basename(prefix))) return false;
            }
            var target: [4096]u8 = undefined;
            const count = std.c.readlink(prefix, &target, target.len);
            if (count >= 0) {
                hops += 1;
                if (hops > 40 or count == target.len) return false;
                const link = target[0..@intCast(count)];
                const joined = if (std.fs.path.isAbsolute(link)) u.fmt("{s}{s}", .{ link, path[end..] }) else u.fmt("{s}/{s}{s}", .{ std.fs.path.dirname(prefix).?, link, path[end..] });
                if (joined.len > 4095) {
                    a.free(joined);
                    return false;
                }
                a.free(path);
                path = joined;
                end = 1;
            } else {
                if (std.c.errno(count) != .INVAL) return false;
                end += 1;
            }
        }
        if (owner.obsolete(self.plan.generation)) return false;
        const canonical = c.realpath(path, null) orelse return false;
        defer c.free(canonical);
        const resolved = std.mem.span(canonical);
        if (!self.chain(owner, resolved)) return false;
        if (root) |expected| {
            if (!std.mem.eql(u8, resolved, expected.canonical orelse return false)) return false;
            // Empty filter accepts only self events, never source-file saves.
            if (!self.register(owner, resolved, manifest_index, "")) return false;
        }
        return true;
    }
    fn identities(self: *Snapshot, owner: *Watches, plan: *const Plan) void {
        var complete = !plan.policy_failed and !plan.disabled and plan.roots.items.len != 0 and self.fd >= 0;
        if (plan.manifest) |path| if (!self.identityPath(owner, path, null)) {
            complete = false;
        };
        for (plan.roots.items) |root| {
            if (!self.identityPath(owner, root.lexical, root)) complete = false;
            if (owner.obsolete(self.plan.generation)) break;
        }
        self.plan.policy_failed = !complete;
        self.plan.failed = self.plan.failed or !complete;
    }
    fn read(self: *Snapshot) ReadResult {
        if (self.fd < 0) return .{ .state = .unavailable };
        var buffer: [read_byte_limit]u8 = undefined;
        const count = std.c.read(self.fd, &buffer, buffer.len);
        if (count < 0) return self.readResult(&.{}, std.c.errno(count));
        return self.readResult(buffer[0..@intCast(count)], .SUCCESS);
    }
    fn readResult(self: *Snapshot, bytes: []const u8, err: linux.E) ReadResult {
        if (err == .AGAIN) return .{ .state = .drained };
        if (err == .INTR) return .{};
        if (err != .SUCCESS or bytes.len == 0) {
            // EOF is not a drain acknowledgement for an inotify descriptor.
            self.plan.failed = true;
            self.plan.policy_failed = true;
            return .{ .state = .unavailable, .events = .{ .overflow = true } };
        }
        var result: ReadResult = .{ .bytes = bytes.len };
        parse(&result.events, self.plan.items.items, bytes);
        // Inotify returns whole records: even a short positive read can leave
        // later policy events queued. Only a subsequent EAGAIN proves drain.
        return result;
    }
};
fn parse(result: *Batch, items: []const Spec, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < @sizeOf(Event)) {
            result.overflow = true;
            return;
        }
        const event = std.mem.bytesToValue(Event, bytes[offset..][0..@sizeOf(Event)]);
        offset += @sizeOf(Event);
        if (event.len > bytes.len - offset or event.mask & linux.IN.Q_OVERFLOW != 0) {
            result.overflow = true;
            return;
        }
        const name = std.mem.sliceTo(bytes[offset..][0..event.len], 0);
        offset += event.len;
        for (items) |item| {
            if (item.descriptor != event.wd) continue;
            if (name.len != 0) if (item.filter) |filter| if (!std.mem.eql(u8, filter, name)) continue;
            const rearm = item.node == manifest_index or name.len == 0 or (event.mask & linux.IN.ISDIR != 0 and event.mask & (linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVE) != 0);
            result.add(item.node, rearm);
        }
    }
}
pub const Watches = struct {
    context: ?*anyopaque = null,
    changed: *const fn (?*anyopaque, usize) void,
    failed: bool = false,
    policy_failed: bool = true,
    disabled: bool = false,
    rearm: bool = false,
    count: usize = 0,
    generation: u64 = 0,
    ready_generation: u64 = 0,
    barrier_done: u64 = 0,
    barrier_failed: u64 = 0,
    test_delay_us: c_ulong = 0,
    draft: Plan = .{},
    mutex: c.GMutex = std.mem.zeroes(c.GMutex),
    cond: c.GCond = std.mem.zeroes(c.GCond),
    desired: std.atomic.Value(u64) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    worker_busy: std.atomic.Value(bool) = .init(false),
    builds: std.atomic.Value(usize) = .init(0),
    // Protected by mutex. Only the worker ever owns live descriptors.
    pending: ?Plan = null,
    completed: u64 = 0,
    completed_count: usize = 0,
    completed_failed: bool = false,
    completed_policy_failed: bool = true,
    event_generation: u64 = 0,
    events: Batch = .{},
    barrier_requested: u64 = 0,
    completed_barrier: u64 = 0,
    failed_barrier: u64 = 0,
    pub fn init(self: *Watches) void {
        c.g_mutex_init(&self.mutex);
        c.g_cond_init(&self.cond);
    }
    pub fn deinit(self: *Watches) void {
        std.debug.assert(self.pending == null and !self.worker_busy.load(.acquire));
        self.draft.deinit();
        c.g_cond_clear(&self.cond);
        c.g_mutex_clear(&self.mutex);
    }
    pub fn begin(self: *Watches) void {
        self.draft.deinit();
    }
    pub fn add(self: *Watches, path: []const u8, node: usize, filter: ?[]const u8) void {
        _ = self.draft.add(path, node, filter);
    }
    /// Owned, bounded lexical/expected root inputs; all resolution is worker-only.
    pub fn addRoot(self: *Watches, lexical: []const u8, canonical: ?[]const u8) void {
        self.draft.addRoot(lexical, canonical);
    }
    pub fn submit(self: *Watches, manifest_path: ?[]const u8) u64 {
        self.generation += 1;
        self.ready_generation = 0;
        self.count = 0;
        self.draft.generation = self.generation;
        self.draft.disabled = self.disabled;
        self.draft.delay_us = self.test_delay_us;
        self.test_delay_us = 0;
        if (manifest_path) |path| {
            if (path.len + 1 <= byte_limit - self.draft.bytes) {
                self.draft.manifest = u.z(path);
                self.draft.bytes += path.len + 1;
            } else {
                self.draft.failed = true;
                self.draft.policy_failed = true;
            }
        }
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        if (self.pending) |*old| old.deinit();
        self.pending = self.draft;
        self.draft = .{};
        self.desired.store(self.generation, .release);
        c.g_cond_signal(&self.cond);
        return self.generation;
    }
    pub fn clear(self: *Watches) void {
        self.begin();
        _ = self.submit(null);
        self.failed = false;
    }
    pub fn stop(self: *Watches) void {
        self.stopping.store(true, .release);
        c.g_mutex_lock(&self.mutex);
        c.g_cond_signal(&self.cond);
        c.g_mutex_unlock(&self.mutex);
    }
    fn obsolete(self: *Watches, generation: u64) bool {
        return self.stopping.load(.acquire) or self.desired.load(.acquire) != generation;
    }
    pub fn queued(self: *Watches) struct { count: usize, bytes: usize } {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        return .{ .count = @intFromBool(self.pending != null), .bytes = if (self.pending) |plan| plan.bytes else 0 };
    }
    pub fn ready(self: *const Watches) bool {
        return self.ready_generation == self.generation;
    }
    /// Explorer fallback is not authorization to execute with partial ancestry.
    pub fn policyReady(self: *const Watches) bool {
        return self.ready() and !self.policy_failed;
    }
    pub fn barrier(self: *Watches) u64 {
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        self.barrier_requested += 1;
        c.g_cond_signal(&self.cond);
        return self.barrier_requested;
    }
    /// GTK source: only mailbox copying/callback delivery, no filesystem I/O.
    pub fn poll(self: *Watches) void {
        c.g_mutex_lock(&self.mutex);
        const completed = self.completed;
        const count = self.completed_count;
        const failed = self.completed_failed;
        const policy_failed = self.completed_policy_failed;
        const event_generation = self.event_generation;
        const events = self.events;
        const barrier_done = self.completed_barrier;
        const barrier_failed = self.failed_barrier;
        self.events = .{};
        c.g_mutex_unlock(&self.mutex);
        if (completed == self.generation) {
            self.ready_generation = completed;
            self.count = count;
            self.failed = failed;
            self.policy_failed = policy_failed;
            self.barrier_done = barrier_done;
            self.barrier_failed = barrier_failed;
        }
        if (event_generation != self.generation) return;
        self.deliver(events);
    }
    fn deliver(self: *Watches, events: Batch) void {
        if (events.overflow) {
            self.rearm = true;
            self.changed(self.context, overflow_index);
        }
        for (events.items[0..events.len]) |event| {
            self.rearm = event.rearm;
            self.changed(self.context, event.node);
        }
        self.rearm = false;
    }
    // Isolated native overflow injection follows the production parser/delivery.
    pub fn dispatch(self: *Watches, bytes: []const u8) void {
        var events: Batch = .{};
        parse(&events, &.{}, bytes);
        self.deliver(events);
    }
    fn readTurn(self: *Watches, active: *Snapshot) ReadResult {
        c.g_mutex_lock(&self.mutex);
        const barrier_requested = self.barrier_requested;
        c.g_mutex_unlock(&self.mutex);
        // Exactly one nonblocking read per turn, including EINTR. An unfinished
        // barrier remains requested across turns; stop/plan changes run first.
        const result = active.read();
        c.g_mutex_lock(&self.mutex);
        defer c.g_mutex_unlock(&self.mutex);
        self.completed = active.plan.generation;
        self.completed_failed = active.plan.failed;
        self.completed_policy_failed = active.plan.policy_failed;
        self.completed_count = 0;
        for (active.plan.items.items) |item| {
            if (item.descriptor >= 0) self.completed_count += 1;
        }
        if (self.event_generation != active.plan.generation) self.events = .{};
        self.event_generation = active.plan.generation;
        if (result.events.overflow) self.events.overflow = true;
        for (result.events.items[0..result.events.len]) |event| self.events.add(event.node, event.rearm);
        switch (result.state) {
            .drained => self.completed_barrier = barrier_requested,
            .unavailable => self.failed_barrier = barrier_requested,
            .pending => {},
        }
        return result;
    }
    pub fn run(self: *Watches) void {
        self.runOwned(.{});
    }
    fn runOwned(self: *Watches, initial: Snapshot) void {
        var active = initial;
        defer active.deinit();
        defer {
            c.g_mutex_lock(&self.mutex);
            if (self.pending) |*plan| plan.deinit();
            self.pending = null;
            c.g_mutex_unlock(&self.mutex);
            self.worker_busy.store(false, .release);
        }
        while (!self.stopping.load(.acquire)) {
            c.g_mutex_lock(&self.mutex);
            var next = self.pending;
            self.pending = null;
            c.g_mutex_unlock(&self.mutex);
            if (next) |*plan| {
                self.worker_busy.store(true, .release);
                _ = self.builds.fetchAdd(1, .monotonic);
                var built: Snapshot = .{ .plan = .{ .generation = plan.generation, .failed = plan.failed or plan.disabled, .policy_failed = true } };

                if (!plan.disabled and !self.obsolete(plan.generation) and (plan.items.items.len != 0 or plan.manifest != null or plan.roots.items.len != 0)) {
                    const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
                    if (linux.errno(fd) == .SUCCESS) built.fd = @intCast(fd) else built.plan.failed = true;
                    if (built.fd >= 0) {
                        // Test delay models a blocked registration while both
                        // the old and the building handle remain worker-owned.
                        if (plan.delay_us != 0) c.g_usleep(plan.delay_us);
                        // Critical identity chains get the bounded slots first.
                        // Later Explorer overflow cannot hide a truncated root.
                        built.identities(self, plan);
                        for (plan.items.items) |item| _ = built.register(self, item.path, item.node, item.filter);
                    }
                }
                plan.deinit();
                if (self.obsolete(built.plan.generation)) built.deinit() else {
                    // Registration and retirement are serial on this worker.
                    // GTK never closes a descriptor a blocked registration uses.
                    active.deinit();
                    active = built;
                }
                self.worker_busy.store(false, .release);
            }
            if (!self.obsolete(active.plan.generation)) _ = self.readTurn(&active);
            c.g_mutex_lock(&self.mutex);
            if (self.pending == null and !self.stopping.load(.acquire)) _ = c.g_cond_wait_until(&self.cond, &self.mutex, c.g_get_monotonic_time() + 25000);
            c.g_mutex_unlock(&self.mutex);
        }
    }
};

const WatchTestObserver = struct {
    policy: usize = 0,
    overflow: usize = 0,
    fn changed(context: ?*anyopaque, node: usize) void {
        const self: *WatchTestObserver = @ptrCast(@alignCast(context.?));
        if (node == manifest_index) self.policy += 1;
        if (node == overflow_index) self.overflow += 1;
    }
};

fn queuedPolicyFixture(owner: *Watches, fixture: *@import("manifest_test_support.zig").Fixture) !Snapshot {
    owner.generation = 1;
    owner.desired.store(1, .release);
    var snapshot: Snapshot = .{ .plan = .{ .generation = 1 } };
    errdefer snapshot.deinit();
    const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    snapshot.fd = @intCast(fd);
    _ = snapshot.register(owner, fixture.base, manifest_index, "policy.json");
    try std.testing.expect(!snapshot.plan.failed);
    // Each empty sibling generates CREATE + CLOSE_WRITE, with 48-byte records.
    // The kernel cannot split the next record to fill a 32768-byte read.
    for (0..350) |i| {
        var name: [17]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "sibling-{d:0>9}", .{i});
        try fixture.write(text, "");
    }
    try fixture.write("policy.json", "{\"exclude\":[\"secret.txt\"]}");
    return snapshot;
}

test "watch barrier waits for real EAGAIN after whole-record short read and queued policy" {
    const testing = std.testing;
    var fixture = try @import("manifest_test_support.zig").Fixture.init();
    defer fixture.deinit();
    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    var snapshot = try queuedPolicyFixture(&watches, &fixture);
    defer snapshot.deinit();
    const first_barrier = watches.barrier();
    const first = watches.readTurn(&snapshot);
    try testing.expectEqual(@as(usize, 32736), first.bytes);
    try testing.expectEqual(.pending, first.state);
    try testing.expectEqual(@as(usize, 0), first.events.len);
    watches.poll();
    try testing.expect(watches.barrier_done < first_barrier);
    try testing.expectEqual(@as(usize, 0), observer.policy);

    const second_barrier = watches.barrier();
    const second = watches.readTurn(&snapshot);
    try testing.expectEqual(@as(usize, 960), second.bytes);
    try testing.expectEqual(.pending, second.state);
    watches.poll();
    try testing.expectEqual(@as(usize, 1), observer.policy);
    try testing.expect(watches.barrier_done < first_barrier);
    try testing.expectEqual(@as(usize, 0), observer.overflow);
    for ([_]ReadResult{ first, second }) |result| {
        try testing.expect(result.bytes <= read_byte_limit);
        try testing.expect(result.events.len <= limit);
        try testing.expect(!result.events.overflow);
    }

    const last = watches.readTurn(&snapshot);
    try testing.expectEqual(.drained, last.state);
    try testing.expectEqual(@as(usize, 0), last.bytes);
    watches.poll();
    try testing.expectEqual(second_barrier, watches.barrier_done);
    try testing.expectEqual(@as(u64, 0), watches.barrier_failed);
}

test "watch EINTR stays pending and unavailable descriptors never acknowledge drain" {
    const testing = std.testing;
    var snapshot: Snapshot = .{};
    try testing.expectEqual(.pending, snapshot.readResult(&.{}, .INTR).state);
    try testing.expect(!snapshot.plan.failed);
    try testing.expectEqual(.drained, snapshot.readResult(&.{}, .AGAIN).state);
    try testing.expectEqual(.unavailable, snapshot.readResult(&.{}, .SUCCESS).state);
    try testing.expect(snapshot.plan.failed);
    snapshot.plan.failed = false;
    const hard_error = snapshot.readResult(&.{}, .BADF);
    try testing.expectEqual(.unavailable, hard_error.state);
    try testing.expect(hard_error.events.overflow and snapshot.plan.failed);

    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    const barrier = watches.barrier();
    // An empty no-workspace snapshot is unavailable, but is not a watch failure.
    snapshot.plan.failed = false;
    try testing.expectEqual(.unavailable, watches.readTurn(&snapshot).state);
    watches.poll();
    try testing.expect(!watches.failed);
    try testing.expectEqual(@as(u64, 0), watches.barrier_done);
    snapshot.plan.failed = true;
    _ = watches.readTurn(&snapshot);
    watches.poll();
    try testing.expect(watches.failed);
    try testing.expectEqual(barrier, watches.barrier_failed);
    try testing.expectEqual(@as(u64, 0), watches.barrier_done);

    // A real successful zero-byte read is EOF, never EAGAIN.
    snapshot.fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try testing.expect(snapshot.fd >= 0);
    defer snapshot.deinit();
    snapshot.plan.failed = false;
    const eof = watches.readTurn(&snapshot);
    try testing.expectEqual(.unavailable, eof.state);
    watches.poll();
    try testing.expect(watches.failed);
    try testing.expectEqual(barrier, watches.barrier_failed);
    try testing.expectEqual(@as(u64, 0), watches.barrier_done);
    try testing.expectEqual(@as(usize, 1), observer.overflow);
}

const WatchStopTest = struct {
    watches: *Watches,
    snapshot: Snapshot,
    first: ReadResult = .{},
    first_done: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    fn run(data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *WatchStopTest = @ptrCast(@alignCast(data.?));
        self.first = self.watches.readTurn(&self.snapshot);
        self.first_done.store(true, .release);
        // Test-only pause at the turn boundary, with an undrained kernel queue.
        while (!self.proceed.load(.acquire)) c.g_usleep(100);
        self.watches.runOwned(self.snapshot);
        self.finished.store(true, .release);
        return null;
    }
};

test "watch stop retires owned descriptor within 250ms without finishing pending barrier" {
    const testing = std.testing;
    var fixture = try @import("manifest_test_support.zig").Fixture.init();
    defer fixture.deinit();
    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    var runner: WatchStopTest = .{ .watches = &watches, .snapshot = try queuedPolicyFixture(&watches, &fixture) };
    const barrier = watches.barrier();
    const thread = c.g_thread_new("watch-stop-test", &WatchStopTest.run, &runner) orelse {
        runner.snapshot.deinit();
        return error.ThreadCreationFailed;
    };
    defer {
        watches.stop();
        runner.proceed.store(true, .release);
        _ = c.g_thread_join(thread);
    }
    const start_deadline = c.g_get_monotonic_time() + 5_000_000;
    while (!runner.first_done.load(.acquire)) {
        if (c.g_get_monotonic_time() >= start_deadline) return error.WorkerStartTimedOut;
        c.g_usleep(100);
    }
    try testing.expectEqual(@as(usize, 32736), runner.first.bytes);
    try testing.expectEqual(.pending, runner.first.state);
    watches.poll();
    try testing.expect(watches.barrier_done < barrier);
    const stop_deadline = c.g_get_monotonic_time() + 250_000;
    watches.stop();
    runner.proceed.store(true, .release);
    while (!runner.finished.load(.acquire)) {
        if (c.g_get_monotonic_time() >= stop_deadline) return error.WorkerStopTimedOut;
        c.g_usleep(100);
    }
    watches.poll();
    try testing.expectEqual(@as(u64, 0), watches.barrier_done);
    try testing.expectEqual(@as(usize, 0), observer.policy);
    try testing.expectEqual(@as(usize, 0), watches.queued().count);
}

fn identityWatchFixture(owner: *Watches) !Snapshot {
    owner.generation = 1;
    owner.desired.store(1, .release);
    const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    return .{ .fd = @intCast(fd), .plan = .{ .generation = 1 } };
}

fn drainIdentityWatch(owner: *Watches, snapshot: *Snapshot) !void {
    for (0..32) |_| {
        const result = owner.readTurn(snapshot);
        owner.poll();
        if (result.state == .drained) return;
        try std.testing.expectEqual(.pending, result.state);
    }
    return error.WatchDidNotDrain;
}

test "root chain subscriptions retain intermediate targets and drain retarget before publication" {
    const testing = std.testing;
    var fixture = try @import("manifest_test_support.zig").Fixture.init();
    defer fixture.deinit();
    try fixture.mkdir("root0");
    try fixture.mkdir("root1");
    try fixture.mkdir("resolver");
    try fixture.symlink("../root0", "resolver/middle");
    try fixture.symlink("resolver/middle", "alias");
    const alias = try fixture.path("alias");
    defer testing.allocator.free(alias);
    const middle = try fixture.path("resolver/middle");
    defer testing.allocator.free(middle);
    const root = try fixture.path("root0");
    defer testing.allocator.free(root);
    var plan: Plan = .{};
    defer plan.deinit();
    plan.addRoot(alias, root);
    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    var snapshot = try identityWatchFixture(&watches);
    defer snapshot.deinit();
    snapshot.identities(&watches, &plan);
    try testing.expect(!snapshot.plan.failed and !snapshot.plan.policy_failed);
    try fixture.write("root0/save.zig", "const saved = 1;\n");
    try drainIdentityWatch(&watches, &snapshot);
    try testing.expect(watches.policyReady());
    try testing.expectEqual(@as(usize, 0), observer.policy);

    // The lexical alias and old canonical root are untouched. Only the hidden
    // intermediate target changes after successful watch registration.
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(middle));
    try testing.expectEqual(@as(c_int, 0), std.c.symlink("../root1", middle));
    const barrier = watches.barrier();
    try testing.expectEqual(.pending, watches.readTurn(&snapshot).state);
    watches.poll();
    try testing.expect(observer.policy != 0);
    try testing.expect(watches.barrier_done < barrier);
    try drainIdentityWatch(&watches, &snapshot);
    try testing.expectEqual(barrier, watches.barrier_done);

    var raced = try identityWatchFixture(&watches);
    defer raced.deinit();
    raced.identities(&watches, &plan);
    try testing.expect(raced.plan.policy_failed); // The candidate still names root0.
    try drainIdentityWatch(&watches, &raced);
    try testing.expect(!watches.policyReady());
}

test "root chains preserve physical dot-dot and fail closed on missing or looping links" {
    const testing = std.testing;
    var fixture = try @import("manifest_test_support.zig").Fixture.init();
    defer fixture.deinit();
    try fixture.mkdir("route");
    try fixture.mkdir("physical");
    try fixture.mkdir("physical/deep");
    try fixture.mkdir("physical/root");
    try fixture.symlink("../physical/deep", "route/middle");
    try fixture.symlink("route/middle/../root", "alias");
    try fixture.symlink("loop", "loop");
    const alias = try fixture.path("alias");
    defer testing.allocator.free(alias);
    const root = try fixture.path("physical/root");
    defer testing.allocator.free(root);
    const loop = try fixture.path("loop");
    defer testing.allocator.free(loop);
    const missing = try fixture.path("missing");
    defer testing.allocator.free(missing);
    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    var snapshot = try identityWatchFixture(&watches);
    defer snapshot.deinit();
    try testing.expect(snapshot.identityPath(&watches, alias, .{ .lexical = alias, .canonical = root }));
    try testing.expect(!snapshot.identityPath(&watches, loop, .{ .lexical = loop, .canonical = root }));
    try testing.expect(!snapshot.identityPath(&watches, missing, .{ .lexical = missing, .canonical = null }));
    // Watching a resolved runtime ancestor is essential even when neither the
    // original root spelling nor the final canonical path mentions it.
    const route = try fixture.path("route");
    defer testing.allocator.free(route);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(route, 0o750));
    try drainIdentityWatch(&watches, &snapshot);
    try testing.expect(observer.policy != 0);
}

test "identity watch input and subscription caps cannot authorize partial root chains" {
    const testing = std.testing;
    var plan: Plan = .{};
    defer plan.deinit();
    plan.bytes = byte_limit;
    plan.addRoot("/", "/");
    try testing.expect(plan.policy_failed and plan.failed and plan.roots.items.len == 0);
    plan.deinit();
    for (0..root_limit + 1) |_| plan.addRoot("/", "/");
    try testing.expect(plan.policy_failed and plan.roots.items.len == root_limit);
    plan.deinit();
    plan.addRoot("/", "/");
    var observer: WatchTestObserver = .{};
    var watches: Watches = .{ .context = &observer, .changed = &WatchTestObserver.changed };
    watches.init();
    defer watches.deinit();
    var snapshot = try identityWatchFixture(&watches);
    defer snapshot.deinit();
    for (0..limit) |i| _ = snapshot.plan.add("/", i, "unrelated");
    snapshot.identities(&watches, &plan);
    try testing.expect(snapshot.plan.policy_failed and snapshot.plan.failed);
    try drainIdentityWatch(&watches, &snapshot);
    try testing.expect(!watches.policyReady());
    try testing.expectEqual(limit, snapshot.plan.items.items.len);
    plan.deinit();
    // A self-only policy watch must never deduplicate with a wildcard watch.
    try testing.expect(plan.add("/", manifest_index, null).? != plan.add("/", manifest_index, "").?);
    plan.deinit();
    plan.bytes = byte_limit;
    try testing.expect(plan.add("/", 0, null) == null and !plan.policy_failed);
    try testing.expect(plan.add("/", manifest_index, ".coral") == null and plan.policy_failed);
}
