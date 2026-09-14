//! Asynchronous canonical settings client. Drafts outlive views; jobs own copies.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
pub const model = @import("aqueous_model.zig");
const contract = @import("aqueous_contract.zig");
const operations = @import("aqueous_operations.zig");
const display_ipc = @import("aqueous_display_ipc.zig");
const process = @import("helper_process.zig");
const a = std.heap.c_allocator;
const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: model.Value,
    fn create(bytes: []const u8) !*Document {
        const self = try a.create(Document);
        self.* = .{ .arena = .init(a), .value = .null };
        errdefer self.destroy();
        self.value = try model.parse(self.arena.allocator(), bytes, model.max_response);
        try model.snapshot(self.value);
        try contract.snapshot(self.value);
        return self;
    }
    fn destroy(self: *Document) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Operation = enum { refresh, validate, apply };
const Job = struct {
    owner: *Client,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    op: Operation,
    draft: ?[]const u8 = null,
    base: model.Value = .null,
    revision: u64,
    response: ?*Document = null,
    failure: ?anyerror = null,
    detail: []const u8 = "",
    result: ?contract.Result = null,
    operation_resolved: bool = false,
    route: contract.Route = .unknown,
    report: ?[]const u8 = null,
    review: ?[]const u8 = null,
    operation_id: []const u8 = "",
    saved: bool = false,
    uncertain: bool = false,
    reconciled: bool = false,
    reload_applied: bool = false,
    reload_reported: bool = false,
    phase: process.Choice = .init(0),
    choice: process.Choice = .init(0),
    expires: std.atomic.Value(i64) = .init(0),
    reverted: bool = false,
    invalidated: bool = false,
    fn destroy(self: *Job) void {
        if (self.response) |v| v.destroy();
        self.cancel.unref();
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Client = struct {
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    reload: *const fn (*anyopaque) anyerror!u64,
    can_reload: *const fn (*anyopaque) bool,
    can_record: *const fn (*anyopaque) bool,
    live: ?*Document = null,
    base: ?*Document = null,
    draft: ?[]u8 = null,
    revision: u64 = 0,
    version: u64 = 0,
    job: ?*Job = null,
    running: bool = false,
    helper: ?[:0]u8 = null,
    backups: ?[:0]u8 = null,
    err: ?anyerror = null,
    detail: [256:0]u8 = @splat(0),
    outcome: enum { idle, loaded, validated, saved, reverted, invalidated, failed, uncertain } = .idle,
    reload_state: enum { not_requested, pending, applied, unavailable, failed, unknown } = .not_requested,
    reload_ticket: ?u64 = null,
    toolkit: enum { not_requested, synced, partial, unknown } = .not_requested,
    unresolved: bool = false,
    uncertain_version: u64 = 0,
    save_state: ?contract.Save = null,
    receipt: ?contract.Receipt = null,
    display_state: contract.Display = .not_requested,
    impact_route: contract.Route = .unknown,
    report: ?[]u8 = null,
    review: ?[]u8 = null,
    operation_id: [64:0]u8 = @splat(0),
    recording: bool = false,
    poll: c_uint = 0,
    pub fn rebase(self: *Client) !void {
        if (self.job != null) return error.Busy;
        if (self.unresolved and self.version <= self.uncertain_version) return error.RefreshRequired;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const merged = try model.rebase(alloc, self.baseValue(), self.value(), self.draft orelse return error.NoDraft);
        const base = try Document.create(try std.json.Stringify.valueAlloc(alloc, self.value(), .{}));
        errdefer base.destroy();
        const copy = try a.dupe(u8, merged);
        self.discard();
        self.base = base;
        self.draft = copy;
        self.changed(self.context);
    }
    pub fn previewing(self: *const Client) bool {
        return if (self.job) |j| j.phase.load(.acquire) == 1 else false;
    }
    pub fn remaining(self: *const Client) u32 {
        const j = self.job orelse return 0;
        return @intCast(@max(0, @divTrunc(j.expires.load(.acquire) - glib.getMonotonicTime() + 999999, 1000000)));
    }
    pub fn choose(self: *Client, keep: bool) !void {
        const j = self.job orelse return error.NoPreview;
        if (!self.previewing() or (keep and self.remaining() == 0) or j.revision != self.revision or !self.can_reload(self.context)) {
            j.choice.store(2, .release);
            return error.StalePreview;
        }
        j.choice.store(if (keep) 1 else 2, .release);
    }
    pub fn start(self: *Client) void {
        self.running = true;
    }
    pub fn stop(self: *Client) void {
        self.running = false;
        if (self.poll != 0) _ = glib.Source.remove(self.poll);
        self.poll = 0;
        if (self.job) |j| j.cancel.cancel() else self.free();
    }
    fn free(self: *Client) void {
        self.discard();
        if (self.report) |v| a.free(v);
        if (self.review) |v| a.free(v);
        self.report = null;
        self.review = null;
        if (self.live) |v| v.destroy();
        self.live = null;
        if (self.helper) |v| a.free(v);
        self.helper = null;
        if (self.backups) |v| a.free(v);
        self.backups = null;
    }
    pub fn value(self: *const Client) model.Value {
        return if (self.live) |v| v.value else .null;
    }
    pub fn baseValue(self: *const Client) model.Value {
        return if (self.base) |v| v.value else self.value();
    }
    pub fn generation(self: *const Client) []const u8 {
        return model.str(model.get(self.value(), "generation"));
    }
    pub fn conflict(self: *const Client) bool {
        return self.base != null and !model.equal(model.get(self.baseValue(), "generation"), model.get(self.value(), "generation"));
    }
    pub fn discard(self: *Client) void {
        if (self.draft) |d| a.free(d);
        self.draft = null;
        if (self.base) |v| v.destroy();
        self.base = null;
        self.revision +%= 1;
        // Discard is not permission to retry an uncertain save.
    }
    pub fn keepDraft(self: *Client, bytes: []const u8) !void {
        if (self.job) |j| j.choice.store(2, .release);
        if (bytes.len > model.max_request) return error.RequestTooLarge;
        const copy = try a.dupe(u8, bytes);
        errdefer a.free(copy);
        if (self.base == null) {
            if (self.live == null) return error.NoSnapshot;
            const encoded = try std.json.Stringify.valueAlloc(a, self.value(), .{});
            defer a.free(encoded);
            self.base = try Document.create(encoded);
        }
        if (self.draft) |d| a.free(d);
        self.draft = copy;
        self.revision +%= 1;
    }
    pub fn emptyDraft(self: *Client, alloc: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(alloc, .{ .protocol = @as(u32, 1), .expected_generation = model.str(model.get(self.baseValue(), "generation")), .changes = [_]struct {}{}, .raw_files = struct {}{} }, .{ .whitespace = .indent_2 });
    }
    pub fn editField(self: *Client, id: []const u8, value_: model.Value) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var v = try model.parse(alloc, self.draft orelse try self.emptyDraft(alloc), model.max_request);
        const f = model.field(self.baseValue(), id) orelse return error.UnknownField;
        if (model.get(model.get(v, "raw_files"), model.str(model.get(f, "file"))) != .null) return error.ConflictingEdits;
        if (v != .object) return error.InvalidRequest;
        var changes = model.get(v, "changes");
        if (changes != .array) return error.InvalidRequest;
        var found = false;
        for (changes.array.items) |*c| if (std.mem.eql(u8, model.str(model.get(c.*, "id")), id)) {
            try c.object.put(alloc, "value", value_);
            found = true;
            break;
        };
        if (!found) {
            var change: model.Value = .{ .object = .empty };
            try change.object.put(alloc, "id", .{ .string = id });
            try change.object.put(alloc, "value", value_);
            try changes.array.append(change);
        }
        try v.object.put(alloc, "changes", changes);
        const json = try std.json.Stringify.valueAlloc(alloc, v, .{ .whitespace = .indent_2 });
        try self.keepDraft(json);
    }
    pub fn begin(self: *Client, op: Operation) !void {
        if (!self.running or self.job != null or self.reload_ticket != null) return error.Busy;
        if (op != .refresh and self.draft == null) return error.NoDraft;
        if (op == .apply and !self.can_reload(self.context)) return error.ReloadUnavailable;
        if (op == .apply and self.unresolved) return error.SaveUncertain;
        if (op != .refresh and self.conflict()) return error.StaleDraft;
        if (self.helper == null) {
            const found = glib.findProgramInPath("aqueous-config") orelse return error.HelperUnavailable;
            defer glib.free(found);
            self.helper = try a.dupeZ(u8, std.mem.span(found));
        }
        if (self.backups == null) self.backups = try std.fmt.allocPrintSentinel(a, "{s}/pearl/aqueous-backups", .{std.mem.span(glib.getUserStateDir())}, 0);
        const j = try a.create(Job);
        j.* = .{ .owner = self, .op = op, .arena = .init(a), .cancel = gio.Cancellable.new(), .revision = self.revision };
        errdefer j.destroy();
        const alloc = j.arena.allocator();
        if (op != .refresh) {
            j.draft = try alloc.dupe(u8, self.draft.?);
            j.base = try model.parse(alloc, try std.json.Stringify.valueAlloc(alloc, self.baseValue(), .{}), model.max_response);
        }
        self.job = j;
        self.err = null;
        self.detail = @splat(0);
        self.poll = glib.timeoutAdd(100, pollPreview, self);
        self.app.hold();
        const task = gio.Task.new(null, j.cancel, completed, j);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(j, null);
        task.runInThread(work);
        task.unref();
        self.changed(self.context);
    }
    fn pollPreview(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(data.?));
        if (self.previewing()) {
            if (!self.can_reload(self.context)) self.job.?.choice.store(2, .release);
            self.changed(self.context);
        }
        return 1;
    }
    fn call(j: *Job, op: [:0]const u8, input: ?[]const u8) ![]const u8 {
        std.debug.assert(std.mem.eql(u8, op, "version") or std.mem.eql(u8, op, "snapshot") or std.mem.eql(u8, op, "validate"));
        const alloc = j.arena.allocator();
        const argv: []const [:0]const u8 = if (input == null) &.{ j.owner.helper.?, op, "--shell", "none" } else &.{ j.owner.helper.?, op, "--shell", "none", "--request", "-" };
        const deadline = glib.getMonotonicTime() + 8000000;
        while (true) {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const time_left = @divTrunc(deadline - glib.getMonotonicTime(), 1000);
            if (time_left <= 0) return error.HelperTimedOut;
            const result = try process.run(scratch.allocator(), argv, input, j.cancel, time_left);
            const v = try model.parse(scratch.allocator(), result.stdout, model.max_response);
            model.check(v) catch |err| {
                const code = model.str(model.get(v, "code"));
                if (std.mem.eql(u8, code, "config_writer_busy") and glib.getMonotonicTime() + 150000 < deadline) {
                    if (j.cancel.isCancelled() != 0) return error.Cancelled;
                    glib.usleep(100000);
                    continue;
                }
                j.detail = try alloc.dupe(u8, code);
                return err;
            };
            if (!result.success) return error.HelperFailed;
            return alloc.dupe(u8, result.stdout);
        }
    }
    fn structured(j: *Job, id: []const u8, input: ?[]const u8) !contract.Result {
        const alloc = j.arena.allocator();
        const operation = try alloc.dupeZ(u8, id);
        const argv: []const [:0]const u8 = if (input != null)
            &.{ j.owner.helper.?, "apply", "--shell", "none", "--request", "-", "--result", "v1", "--operation-id", operation }
        else
            &.{ j.owner.helper.?, "operation-status", "--shell", "none", "--operation-id", operation };
        const reply = try process.run(alloc, argv, input, j.cancel, 35000);
        // Even a nonzero exit may describe an already persisted save.
        return contract.Result.read(try model.parse(alloc, reply.stdout, model.max_response), id);
    }
    fn acceptResult(j: *Job, store: operations.Store, pending: model.Value, result: contract.Result) !void {
        const alloc = j.arena.allocator();
        j.result = result;
        var summary = result.value;
        summary.object = try result.value.object.clone(alloc);
        _ = summary.object.swapRemove("snapshot");
        var toolkit = model.get(summary, "toolkit");
        if (toolkit == .object) {
            toolkit.object = try toolkit.object.clone(alloc);
            var typography = model.get(toolkit, "typography");
            if (typography == .object) {
                typography.object = try typography.object.clone(alloc);
                _ = typography.object.swapRemove("faces");
                _ = typography.object.swapRemove("families");
                try toolkit.object.put(alloc, "typography", typography);
            }
            try summary.object.put(alloc, "toolkit", toolkit);
        }
        j.report = try std.json.Stringify.valueAlloc(alloc, summary, .{});
        // Early rejection precedes candidate preparation, so the canonical
        // helper can prove no write without supplying candidate bindings.
        const rejected_before_write = !result.ok and result.save == .failed and
            result.reload == .not_requested and result.display == .not_requested;
        for ([_][2][]const u8{ .{ "before_generation", "generation" }, .{ "candidate_digest", "candidate_digest" } }) |pair| {
            const received = model.get(result.value, pair[0]);
            if (received != .null and !model.equal(received, model.get(pending, pair[1]))) return error.OperationMismatch;
            if (result.certain() and received == .null and !rejected_before_write) return error.InvalidContract;
        }
        j.uncertain = !result.certain();
        j.saved = result.save == .saved or result.save == .unchanged;
        j.reload_applied = result.reload == .applied;
        j.reload_reported = result.reload == .applied or result.reload == .failed;
        j.reconciled = result.receipt == .recovered;
        if (!result.ok) {
            j.failure = error.HelperRejected;
            j.detail = model.str(model.get(model.get(result.value, "failure"), "code"));
        }
        if (j.uncertain) return error.SaveUncertain;
        try store.resolved(model.str(model.get(pending, "operation_id")));
        j.operation_resolved = true;
        const snapshot = model.get(result.value, "snapshot");
        if (snapshot != .null) j.response = try Document.create(try std.json.Stringify.valueAlloc(alloc, snapshot, .{}));
    }
    fn recover(j: *Job, store: operations.Store, pending: model.Value) !void {
        j.uncertain = true;
        if (!std.mem.eql(u8, try contract.text(pending, "helper", 4096), j.owner.helper.?)) return error.OperationHelperChanged;
        const id = model.str(model.get(pending, "operation_id"));
        j.operation_id = id;
        try acceptResult(j, store, pending, try structured(j, id, null));
    }
    fn perform(j: *Job) !void {
        const alloc = j.arena.allocator();
        const version = try model.parse(alloc, try call(j, "version", null), model.max_response);
        for ([_][]const u8{ "shell_none", "schema_fields", "validate", "generation_check", "stdin_requests" }) |cap| if (!model.has(version, cap)) return error.UnsupportedHelper;
        const caps = contract.Capabilities.read(version);
        const store = try operations.Store.open(alloc);
        defer store.close();
        if (store.pending() catch {
            j.uncertain = true;
            return error.InvalidOperationRecord;
        }) |pending| {
            try recover(j, store, pending);
            // Recovery never replays the requested action or its side effects.
            if (j.response == null) j.response = try Document.create(try call(j, "snapshot", null));
            return;
        }
        if (j.op == .refresh) {
            j.response = try Document.create(try call(j, "snapshot", null));
            return;
        }
        if (!caps.apply) return error.HelperUpgradeRequired;
        var req = try model.request(alloc, j.base, j.draft.?, j.owner.backups.?);
        const candidate = try Document.create(try call(j, "validate", try std.json.Stringify.valueAlloc(alloc, req, .{})));
        defer candidate.destroy();
        const impact = try contract.Impact.read(candidate.value, model.str(model.get(j.base, "generation")));
        j.route = impact.route;
        j.review = try std.json.Stringify.valueAlloc(alloc, model.get(candidate.value, "candidate_impact"), .{});
        if (j.op == .validate) return;
        if (impact.route == .unknown) {
            j.detail = impact.reason;
            return error.UnclassifiedCandidate;
        }
        var native: ?display_ipc.Client = null;
        defer if (native) |*client| client.close();
        if (impact.route == .display) {
            if (!caps.display) return error.DisplayCapabilityUnavailable;
            native = try display_ipc.Client.open(alloc, j.cancel);
            const client = &native.?;
            if (!std.mem.eql(u8, &client.session, model.str(model.get(impact.projection, "session")))) return error.DisplaySessionChanged;
            const lease = client.call(alloc, "display.preview.begin", .{
                .display_revision = model.get(impact.projection, "display_revision"),
                .candidate_digest = impact.digest,
                .expected_generation = impact.generation,
                .wm_source = model.get(model.get(candidate.value, "raw_files"), "wm"),
                .outputs_source = model.get(model.get(candidate.value, "raw_files"), "outputs"),
            }) catch |err| {
                j.detail = try alloc.dupe(u8, std.mem.sliceTo(&client.detail, 0));
                return err;
            };
            const token = try contract.hex(lease, "token", 64);
            const deadline = glib.getMonotonicTime() + 25000000;
            while (true) {
                if (j.cancel.isCancelled() != 0) return error.Cancelled;
                var scratch = std.heap.ArenaAllocator.init(a);
                defer scratch.deinit();
                const status_ = try client.call(scratch.allocator(), "display.preview.status", .{ .token = token });
                const state = try contract.text(status_, "state", 64);
                if (std.mem.eql(u8, state, "previewing")) {
                    const ms = model.get(status_, "remaining_ms");
                    if (ms != .integer or ms.integer < 0 or ms.integer > 15000) return error.InvalidContract;
                    j.expires.store(glib.getMonotonicTime() + ms.integer * 1000, .release);
                    j.phase.store(1, .release);
                    if (j.choice.load(.acquire) == 1 and ms.integer > 0) break;
                } else if (!std.mem.eql(u8, state, "applying")) {
                    j.reverted = true;
                    j.invalidated = std.mem.eql(u8, state, "invalidated");
                    j.detail = try alloc.dupe(u8, state);
                    if (!std.mem.eql(u8, state, "reverted") and !j.invalidated) return error.DisplayPreviewFailed;
                    return;
                }
                if (j.choice.load(.acquire) == 2 or glib.getMonotonicTime() >= deadline) {
                    _ = try client.call(scratch.allocator(), "display.preview.revert", .{ .token = token });
                    j.reverted = true;
                    return;
                }
                glib.usleep(100000);
            }
            j.phase.store(2, .release);
            try req.object.put(alloc, "preview_token", .{ .string = token });
        }
        try req.object.put(alloc, "protected_apply", .{ .bool = true });
        try req.object.put(alloc, "candidate_digest", .{ .string = impact.digest });
        const encoded = try std.json.Stringify.valueAlloc(alloc, req, .{});
        try @import("io.zig").mkdir(j.owner.backups.?);
        // Durable before launching: a timeout/crash can only lead to a receipt query.
        const id = try store.begin(j.owner.helper.?, try contract.text(version, "version", 64), encoded, impact);
        j.operation_id = id;
        j.uncertain = true;
        const pending = (try store.pending()).?;
        const result = structured(j, id, encoded) catch {
            try recover(j, store, pending);
            return;
        };
        try acceptResult(j, store, pending, result);
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        perform(j) catch |err| {
            j.failure = err;
        };
        task.returnBoolean(1);
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        const self = j.owner;
        defer self.app.release();
        self.job = null;
        if (self.poll != 0) _ = glib.Source.remove(self.poll);
        self.poll = 0;
        if (!self.running) {
            j.destroy();
            self.free();
            return;
        }
        self.err = j.failure;
        if (j.review != null) self.impact_route = j.route;
        if (j.operation_resolved) self.unresolved = false;
        if (j.result) |result| {
            self.save_state = result.save;
            self.receipt = result.receipt;
            self.display_state = result.display;
        }
        if (j.report) |v| {
            if (self.report) |old| a.free(old);
            self.report = a.dupe(u8, v) catch null;
        }
        if (j.review) |v| {
            if (self.review) |old| a.free(old);
            self.review = a.dupe(u8, v) catch null;
        }
        if (j.operation_id.len > 0) {
            self.operation_id = @splat(0);
            @memcpy(self.operation_id[0..j.operation_id.len], j.operation_id);
        }
        const n = @min(j.detail.len, self.detail.len);
        @memcpy(self.detail[0..n], j.detail[0..n]);
        const refreshed = j.response != null;
        if (j.response) |v| {
            if (self.live) |old| old.destroy();
            self.live = v;
            j.response = null;
            self.version +%= 1;
        }
        if (j.uncertain) {
            self.outcome = .uncertain;
            self.unresolved = true;
            self.uncertain_version = self.version;
            self.toolkit = .unknown;
        } else if (j.saved) {
            self.outcome = .saved;
            self.unresolved = false;
            self.toolkit = .not_requested;
            if (j.reconciled) self.toolkit = .unknown else {
                for ([_][]const u8{ "desktop_typography", "desktop_cursor" }) |key| {
                    const report = model.get(self.value(), key);
                    const applied = model.get(report, "applied");
                    const failed = model.get(report, "failed_count");
                    if (applied == .bool and applied.bool and self.toolkit != .partial) self.toolkit = .synced;
                    if (failed == .integer and failed.integer > 0) self.toolkit = .partial;
                }
            }
            if (self.revision == j.revision and !j.reconciled and refreshed and j.operation_resolved) self.discard();
            self.reload_state = if (j.reconciled or !j.reload_reported) .unknown else if (j.reload_applied) .applied else .failed;
        } else if (j.reverted) self.outcome = if (j.invalidated) .invalidated else .reverted else if (j.failure != null) self.outcome = .failed else if (j.op == .refresh) self.outcome = .loaded else self.outcome = .validated;
        j.destroy();
        self.changed(self.context);
    }
    pub fn requestReload(self: *Client) !void {
        if (self.unresolved) return error.SaveUncertain;
        if (self.job != null or self.reload_ticket != null) return error.Busy;
        self.reload_ticket = self.reload(self.context) catch |err| {
            self.reload_state = if (err == error.Unsupported or err == error.Unavailable) .unavailable else .failed;
            return err;
        };
        self.reload_state = .pending;
        self.changed(self.context);
    }
    pub fn completion(self: *Client, result: @import("../aqueous/client.zig").Completion) bool {
        if (self.reload_ticket == null or result.ticket != self.reload_ticket.?) return false;
        self.reload_ticket = null;
        self.reload_state = switch (result.status) {
            .applied => .applied,
            .unknown => .unknown,
            else => .failed,
        };
        self.changed(self.context);
        return true;
    }
    pub fn status(self: *const Client, alloc: std.mem.Allocator, query: ?[]const u8) ![]u8 {
        const v = self.value();
        const result = if (query) |id| blk: {
            if (std.mem.eql(u8, id, "operation")) break :blk try model.parse(alloc, self.report orelse "null", model.max_response);
            if (std.mem.eql(u8, id, "review")) break :blk try model.parse(alloc, self.review orelse "null", model.max_response);
            if (std.mem.eql(u8, id, "draft")) break :blk try model.parse(alloc, self.draft orelse "null", model.max_request);
            if (std.mem.startsWith(u8, id, "raw:")) break :blk model.get(model.get(v, "raw_files"), id[4..]);
            break :blk if (model.field(v, id)) |f| model.get(f, "value") else model.get(v, id);
        } else model.Value.null;
        return std.json.Stringify.valueAlloc(alloc, .{
            .busy = self.job != null,
            .generation = self.generation(),
            .draft = self.draft != null,
            .revision = self.revision,
            .conflict = self.conflict(),
            .unresolved = self.unresolved,
            .outcome = @tagName(self.outcome),
            .reload = @tagName(self.reload_state),
            .toolkit = @tagName(self.toolkit),
            .err = if (self.err) |err| @errorName(err) else null,
            .detail = std.mem.sliceTo(&self.detail, 0),
            .fields = model.list(model.get(v, "fields")).len,
            .value = result,
            .recording = self.recording,
            .display_preview = if (self.previewing()) "pending" else "idle",
            .preview_seconds = self.remaining(),
            .helper = self.helper,
            .capabilities = contract.Capabilities.read(v),
            .operation_id = std.mem.sliceTo(&self.operation_id, 0),
            .save = if (self.save_state) |v_| @tagName(v_) else null,
            .receipt = if (self.receipt) |v_| @tagName(v_) else null,
            .display = @tagName(self.display_state),
            .impact = @tagName(self.impact_route),
        }, .{});
    }
};
test "first GTK field edit creates a JSON changes array and retains its base" {
    var client: Client = .{ .app = undefined, .context = undefined, .changed = undefined, .reload = undefined, .can_reload = undefined, .can_record = undefined };
    defer client.free();
    client.live = try Document.create("{\"ok\":true,\"protocol\":1,\"generation\":\"123456789abcdef0\",\"raw_files\":{},\"fields\":[{\"id\":\"gap\",\"category\":\"layouts\",\"label\":\"Gap\",\"type\":\"integer\",\"file\":\"layout\",\"value\":1}]}");
    try client.editField("gap", .{ .integer = 2 });
    try client.editField("gap", .{ .integer = 3 });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try model.parse(arena.allocator(), client.draft.?, 4096);
    try std.testing.expect(model.get(v, "raw_files") == .object);
    _ = try model.request(arena.allocator(), client.baseValue(), client.draft.?, "/tmp/backups");
    try std.testing.expectEqual(@as(usize, 1), model.list(model.get(v, "changes")).len);
    try std.testing.expectEqual(@as(i64, 3), model.get(model.list(model.get(v, "changes"))[0], "value").integer);
    try std.testing.expectEqualStrings("123456789abcdef0", model.str(model.get(v, "expected_generation")));
}
