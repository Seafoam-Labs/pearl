//! Asynchronous canonical settings client. Drafts outlive views; jobs own copies.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
pub const model = @import("aqueous_model.zig");
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
        self.unresolved = false;
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
        const alloc = j.arena.allocator();
        const argv: []const [:0]const u8 = if (input == null) &.{ j.owner.helper.?, op, "--shell", "none" } else &.{ j.owner.helper.?, op, "--shell", "none", "--request", "-", "--report-reload", "true" };
        const result = try process.run(alloc, argv, input, j.cancel, 35000);
        if (std.mem.eql(u8, op, "apply")) {
            const report = model.reloadReport(result.stderr);
            j.reload_applied = report == .applied;
            j.reload_reported = report != .unknown;
        }
        const v = try model.parse(alloc, result.stdout, model.max_response);
        model.check(v) catch |err| {
            j.detail = model.str(model.get(v, "code"));
            return err;
        };
        if (!result.success) return error.HelperFailed;
        return result.stdout;
    }
    fn perform(j: *Job) !void {
        const alloc = j.arena.allocator();
        const version = try model.parse(alloc, try call(j, "version", null), model.max_response);
        for ([_][]const u8{ "shell_none", "schema_fields", "validate", "generation_check", "stdin_requests", "atomic_file_replace" }) |cap| if (!model.has(version, cap)) return error.UnsupportedHelper;
        if (j.op == .refresh) {
            j.response = try Document.create(try call(j, "snapshot", null));
            return;
        }
        const req = try model.request(alloc, j.base, j.draft.?, j.owner.backups.?);
        const encoded = try std.json.Stringify.valueAlloc(alloc, req, .{});
        const candidate = try Document.create(try call(j, "validate", encoded));
        defer candidate.destroy();
        if (j.op == .validate) return;
        if (model.rawDisplayRisk(j.base, req)) return error.ProtectedDisplayPreviewRequired;
        // Gate every route, including raw wm/outputs, until independent rollback
        // has been established. A compatibility rollback_seconds field is not a lease.
        if (model.displayChanged(j.base, candidate.value)) {
            // Only explicit monitor edits can be translated into a live preview.
            // Raw output changes, policies and mirroring remain safely gated.
            if (model.list(model.get(req, "monitor_changes")).len == 0 or model.get(model.get(req, "raw_files"), "outputs") != .null or model.get(model.get(req, "raw_files"), "wm") != .null) return error.ProtectedDisplayPreviewRequired;
            for (model.list(model.get(req, "changes"))) |change| {
                const f = model.field(j.base, model.str(model.get(change, "id"))) orelse return error.UnknownField;
                if (std.mem.eql(u8, model.str(model.get(f, "category")), "displays")) return error.DisplayPolicyPreviewUnsupported;
            }
            try @import("io.zig").mkdir(j.owner.backups.?);
            j.uncertain = true;
            const response = process.preview(alloc, try std.json.Stringify.valueAlloc(alloc, .{ .request = req, .helper = j.owner.helper.? }, .{}), j.cancel, &j.phase, &j.choice, &j.expires) catch |err| {
                if (j.choice.load(.acquire) != 1) j.uncertain = false;
                return err;
            };
            const result = try model.parse(alloc, response, model.max_response);
            if (model.get(result, "ok") != .bool or !model.get(result, "ok").bool) {
                j.detail = model.str(model.get(result, "err"));
                const unknown = model.get(result, "save_uncertain");
                j.uncertain = unknown != .bool or unknown.bool;
                if (j.uncertain) {
                    j.failure = error.DisplayPreviewFailed;
                    j.response = try Document.create(try call(j, "snapshot", null));
                    if (model.equal(model.get(j.response.?.value, "raw_files"), model.get(candidate.value, "raw_files"))) {
                        j.saved = true;
                        j.reconciled = true;
                        j.uncertain = false;
                        return;
                    }
                    if (model.equal(model.get(j.response.?.value, "raw_files"), model.get(j.base, "raw_files"))) j.uncertain = false;
                }
                return error.DisplayPreviewFailed;
            }
            const preview_state = model.str(model.get(result, "preview"));
            if (std.mem.eql(u8, preview_state, "reverted") or std.mem.eql(u8, preview_state, "invalidated")) {
                j.reverted = true;
                j.invalidated = std.mem.eql(u8, preview_state, "invalidated");
                j.uncertain = false;
                return;
            }
            j.response = try Document.create(try std.json.Stringify.valueAlloc(alloc, model.get(result, "result"), .{}));
            j.reload_applied = std.mem.eql(u8, model.str(model.get(result, "reload")), "applied");
            j.reload_reported = j.reload_applied or std.mem.eql(u8, model.str(model.get(result, "reload")), "failed");
            j.saved = true;
            j.uncertain = false;
            return;
        }
        try @import("io.zig").mkdir(j.owner.backups.?);
        const applied = call(j, "apply", encoded) catch |err| {
            // A failed/late response says nothing reliable about the write phase.
            j.uncertain = true;
            j.failure = err;
            j.response = Document.create(try call(j, "snapshot", null)) catch return error.SaveUncertain;
            if (model.equal(model.get(j.response.?.value, "raw_files"), model.get(candidate.value, "raw_files"))) {
                j.saved = true;
                j.reconciled = true;
                j.uncertain = false;
            } else if (model.equal(model.get(j.response.?.value, "raw_files"), model.get(j.base, "raw_files"))) {
                j.uncertain = false;
            }
            return;
        };
        j.uncertain = true;
        j.response = try Document.create(applied);
        if (!model.equal(model.get(j.response.?.value, "raw_files"), model.get(candidate.value, "raw_files"))) return error.SaveUncertain;
        j.saved = true;
        j.uncertain = false;
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
        const n = @min(j.detail.len, self.detail.len);
        @memcpy(self.detail[0..n], j.detail[0..n]);
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
            if (self.revision == j.revision and !j.reconciled) self.discard();
            self.reload_state = if (j.reconciled or !j.reload_reported) .unknown else if (j.reload_applied) .applied else .failed;
        } else if (j.reverted) self.outcome = if (j.invalidated) .invalidated else .reverted else if (j.failure != null) self.outcome = .failed else if (j.op == .refresh) self.outcome = .loaded else self.outcome = .validated;
        j.destroy();
        self.changed(self.context);
    }
    pub fn requestReload(self: *Client) !void {
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
