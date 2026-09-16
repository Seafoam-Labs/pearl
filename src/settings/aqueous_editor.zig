//! Window-owned Aqueous model. The authenticated backend is the only writer.
const std = @import("std");
const glib = @import("glib2");
const Transport = @import("client.zig");
const p = @import("editor_protocol.zig");
const api = @import("aqueous_protocol.zig");
const model = @import("../config/aqueous_model.zig");
const contract = @import("../config/aqueous_contract.zig");
const a = std.heap.c_allocator;
const Value = std.json.Value;
const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    fn create(bytes: []const u8) !*Document {
        const self = try a.create(Document);
        self.* = .{ .arena = .init(a), .value = .null };
        errdefer self.destroy();
        self.value = try model.parse(self.arena.allocator(), bytes, model.max_response);
        if (self.value != .null) {
            try model.snapshot(self.value);
            try contract.snapshot(self.value);
        }
        return self;
    }
    fn destroy(self: *Document) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Event = enum { changed, close_ready, close_failed };
const Kind = @FieldType(p.GetDocument, "kind");
const Action = @FieldType(api.Action, "action");
const Mode = enum { idle, state, get, read, begin, write, finish, action, receipt, close, cancel };
pub const Editor = struct {
    transport: Transport.Client = undefined,
    context: *anyopaque,
    notify: *const fn (*anyopaque, Event) void,
    live: ?*Document = null,
    base: ?*Document = null,
    draft: ?[]u8 = null,
    report: ?[]u8 = null,
    preview_report: ?[]u8 = null,
    review: ?[]u8 = null,
    detail: [256:0]u8 = @splat(0),
    err: ?anyerror = null,
    version: u64 = 0,
    revision: u64 = 0,
    review_version: u64 = 0,
    review_revision: ?u64 = null,
    job: ?u8 = 1,
    reload_ticket: ?u64 = null,
    recording: bool = false,
    outcome: @FieldType(api.State, "outcome") = .idle,
    reload_state: @FieldType(api.State, "reload_state") = .not_requested,
    toolkit: @FieldType(api.State, "toolkit") = .not_requested,
    save_state: ?contract.Save = null,
    receipt: ?contract.Receipt = null,
    display_state: contract.Display = .not_requested,
    impact_route: contract.Route = .unknown,
    unresolved: bool = false,
    online: bool = false,
    ready: bool = false,
    locked: bool = false,
    suspended: bool = false,
    recovery: bool = false,
    dirty: bool = false,
    editing: bool = false,
    epoch: ?[32]u8 = null,
    server_revision: u64 = 0,
    server_version: u64 = 0,
    server_review: u64 = 0,
    server_review_revision: ?u64 = null,
    server_report: u64 = 0,
    synced_revision: ?u64 = null,
    synced_version: ?u64 = null,
    synced_review: ?u64 = null,
    synced_report: ?u64 = null,
    remote_draft: bool = false,
    remote_busy: bool = false,
    record_allowed: bool = false,
    phase: u8 = 0,
    seconds: u32 = 0,
    owns_preview: bool = false,
    mode: Mode = .idle,
    needs_state: bool = true,
    queue: [6]?Kind = @splat(null),
    kind: Kind = .committed,
    transfer: u64 = 0,
    cancel_transfer: bool = false,
    offset: usize = 0,
    buffer: ?[]u8 = null,
    hash: [64]u8 = undefined,
    sending: ?[]u8 = null,
    sent_revision: u64 = 0,
    upload_revision: u64 = 0,
    upload_version: u64 = 0,
    action: ?Action = null,
    submitted: ?Action = null,
    operation: ?[32]u8 = null,
    pending_receipt: bool = false,
    timer: c_uint = 0,
    idle: c_uint = 0,
    closing: bool = false,
    close_due: i64 = 0,
    close_sent: bool = false,
    due: i64 = 0,
    first_edit: i64 = 0,
    pub const standalone = true;
    pub fn init(self: *Editor, source: *Transport.Client) void {
        self.transport = .{ .context = self, .notify = event, .runtime = source.runtime, .display = source.display, .aqueous_path = source.aqueous_path };
        self.transport.init();
        self.timer = glib.timeoutAdd(100, tick, self);
    }
    pub fn connect(self: *Editor, native: ?[32]u8) void {
        self.transport.native = native;
        self.transport.begin();
    }
    pub fn deinit(self: *Editor) void {
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.transport.deinit();
        if (self.live) |d| d.destroy();
        if (self.base) |d| d.destroy();
        inline for (.{ "draft", "report", "review", "preview_report", "buffer", "sending" }) |field| if (@field(self, field)) |bytes| a.free(bytes);
    }
    pub fn canRecord(self: *const Editor) bool {
        return self.online and self.ready and !self.locked and !self.suspended and !self.recovery and self.record_allowed;
    }
    pub fn value(self: *const Editor) Value {
        return if (self.live) |d| d.value else .null;
    }
    pub fn baseValue(self: *const Editor) Value {
        return if (self.base) |d| if (d.value != .null) d.value else self.value() else self.value();
    }
    pub fn conflict(self: *const Editor) bool {
        return self.recovery or (self.base != null and !model.equal(model.get(self.baseValue(), "generation"), model.get(self.value(), "generation")));
    }
    pub fn canRevalidate(self: *const Editor) bool {
        if (self.recovery) return false;
        if (!self.conflict()) return true;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const req = model.parse(arena.allocator(), self.draft orelse "{}", model.max_request) catch return false;
        return @import("../config/aqueous_transactions.zig").collectionOnly(req) and contract.Capabilities.read(self.value()).protected_collections;
    }
    pub fn previewing(self: *const Editor) bool {
        return self.phase == 1 and self.owns_preview;
    }
    pub fn previewPhase(self: *const Editor) u8 {
        return self.phase;
    }
    pub fn canChoose(self: *const Editor) bool {
        return self.owns_preview and self.online and !self.locked and !self.suspended;
    }
    pub fn remaining(self: *const Editor) u32 {
        return self.seconds;
    }
    pub fn emptyDraft(self: *Editor, alloc: std.mem.Allocator) ![]u8 {
        return @import("../config/aqueous_draft.zig").empty(alloc, self.baseValue());
    }
    pub fn editField(self: *Editor, id: []const u8, value_: model.Value) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try self.keepDraft(try @import("../config/aqueous_draft.zig").field(arena.allocator(), self.baseValue(), self.draft, id, value_));
    }
    pub fn keepDraft(self: *Editor, bytes: []const u8) !void {
        if (!self.ready or self.locked or self.suspended or self.recovery or self.remote_busy or self.pending_receipt) return error.Unavailable;
        if (bytes.len > model.max_request) return error.RequestTooLarge;
        const copy = try a.dupe(u8, bytes);
        errdefer a.free(copy);
        if (self.base == null) {
            if (self.live == null) return error.NoSnapshot;
            const encoded = try std.json.Stringify.valueAlloc(a, self.value(), .{});
            defer a.free(encoded);
            self.base = try Document.create(encoded);
        }
        if (self.draft) |draft| a.free(draft);
        self.draft = copy;
        const now = glib.getMonotonicTime();
        if (!self.dirty) self.first_edit = now;
        self.dirty = true;
        self.due = @min(now + 150_000, self.first_edit + 1_000_000);
        self.revision +|= 1;
        self.editing = true;
        defer self.editing = false;
        self.notify(self.context, .changed);
    }
    pub fn begin(self: *Editor, op: enum { refresh, validate, apply }) !void {
        try self.command(switch (op) {
            .refresh => .refresh,
            .validate => .validate,
            .apply => .apply,
        });
    }
    pub fn choose(self: *Editor, keep: bool) !void {
        if (!self.owns_preview) return error.NotOwner;
        try self.command(if (keep) .keep else .revert);
    }
    pub fn identify(self: *Editor) !void {
        try self.command(.identify);
    }
    pub fn requestReload(self: *Editor) !void {
        try self.command(.reload);
    }
    pub fn discard(self: *Editor) void {
        if (self.recovery) {
            if (self.draft) |d| a.free(d);
            self.draft = null;
            if (self.base) |d| d.destroy();
            self.base = null;
            self.dirty = false;
            self.recovery = false;
            self.synced_revision = null;
            self.needs_state = true;
            self.revision +|= 1;
            self.notify(self.context, .changed);
            return;
        }
        self.command(.discard) catch |err| self.fail(err);
    }
    pub fn rebase(self: *Editor) !void {
        if (!self.recovery) return self.command(.rebase);
        if (!self.online or !self.ready or self.locked) return error.Unavailable;
        // Reconcile explicitly against a refreshed backend snapshot. Never replay
        // a disconnected candidate automatically or overwrite a concurrent draft.
        if (self.remote_draft) return error.ConcurrentDraft;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const merged = try model.rebase(arena.allocator(), self.baseValue(), self.value(), self.draft orelse return error.NoDraft);
        const base = try Document.create(try std.json.Stringify.valueAlloc(arena.allocator(), self.value(), .{}));
        errdefer base.destroy();
        const copy = try a.dupe(u8, merged);
        if (self.base) |d| d.destroy();
        self.base = base;
        if (self.draft) |d| a.free(d);
        self.draft = copy;
        self.recovery = false;
        self.dirty = true;
        self.synced_revision = self.server_revision;
        self.revision +|= 1;
    }
    fn command(self: *Editor, action: Action) !void {
        if (@import("build_options").test_hooks) std.log.info("event=settings-aqueous-action action={s} pending={}", .{ @tagName(action), self.pending_receipt });
        if (!self.online or self.locked or self.suspended) return error.Unavailable;
        if (self.action != null or (self.pending_receipt and action != .keep and action != .revert)) return error.Busy;
        if (self.recovery and action != .refresh and action != .revert) return error.ReviewRequired;
        self.action = action;
        self.due = 0;
        self.err = null;
    }
    pub fn flush(self: *Editor) void {
        self.due = 0;
        self.wake();
    }
    pub fn close(self: *Editor) void {
        self.closing = true;
        self.due = 0;
        if (!self.online or self.recovery) {
            if (self.dirty or self.sending != null or self.phase != 0) {
                self.closing = false;
                self.notify(self.context, .close_failed);
            } else {
                self.closing = false;
                self.notify(self.context, .close_ready);
            }
        }
    }
    fn fail(self: *Editor, err: anyerror) void {
        self.err = err;
        self.notify(self.context, .changed);
    }
    fn event(context: *anyopaque, value_: Transport.Event) void {
        const self: *Editor = @ptrCast(@alignCast(context));
        switch (value_) {
            .verified => {},
            .connected => {
                if (self.online) return;
                const changed_epoch = self.epoch != null and !std.mem.eql(u8, &self.epoch.?, &self.transport.epoch.?);
                self.epoch = self.transport.epoch;
                self.online = true;
                self.mode = .idle;
                self.needs_state = true;
                self.close_sent = false;
                self.queue = @splat(null);
                self.cancel_transfer = false;
                self.synced_revision = null;
                self.synced_version = null;
                self.synced_review = null;
                self.synced_report = null;
                if (changed_epoch) {
                    self.operation = null;
                    self.pending_receipt = false;
                }
            },
            .reply => |reply_| {
                self.reply(reply_) catch |err| {
                    self.mode = .idle;
                    self.ready = false;
                    self.fail(err);
                };
                self.wake();
            },
            .changed => self.needs_state = true,
            .locked => |locked| {
                self.locked = locked;
                if (locked) {
                    self.suspended = true;
                    self.action = null;
                    self.recording = false;
                    if (self.buffer) |bytes| a.free(bytes);
                    self.buffer = null;
                    if (self.sending) |bytes| a.free(bytes);
                    self.sending = null;
                    self.queue = @splat(null);
                    self.ready = false;
                    self.needs_state = true;
                }
                self.notify(self.context, .changed);
            },
            .failed => |err| {
                self.online = false;
                self.ready = false;
                self.job = 1;
                self.mode = .idle;
                if (self.draft != null) self.dirty = true;
                self.recovery = self.dirty or self.sending != null or self.recovery;
                if (self.sending) |bytes| a.free(bytes);
                self.sending = null;
                if (self.buffer) |bytes| a.free(bytes);
                self.buffer = null;
                self.action = null;
                self.fail(err);
                if (self.closing) {
                    self.closing = false;
                    self.notify(self.context, .close_failed);
                }
            },
        }
    }
    fn wake(self: *Editor) void {
        if (self.idle == 0) self.idle = glib.idleAdd(pumpIdle, self);
    }
    fn pumpIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        self.pump() catch |err| {
            self.mode = .idle;
            self.fail(err);
        };
        return 0;
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.pump() catch |err| {
            self.mode = .idle;
            self.fail(err);
        };
        return 1;
    }
    fn send(self: *Editor, mode: Mode, op: Transport.Operation, params: anytype) !void {
        try self.transport.request(op, params);
        self.mode = mode;
    }
    fn pump(self: *Editor) !void {
        if (!self.online or self.transport.waiting or self.mode != .idle) return;
        if (self.cancel_transfer) {
            self.cancel_transfer = false;
            return self.send(.cancel, .@"document.cancel", .{ .transfer = p.num(self.transfer) });
        }
        if (self.action != null and (self.action.? == .keep or self.action.? == .revert)) {
            const action = self.action.?;
            self.action = null;
            self.submitted = action;
            self.operation = try nonce();
            return self.send(.action, .@"aqueous.action", .{ .operation = &self.operation.?, .expected_draft_revision = p.num(self.server_revision), .version = p.num(self.server_version), .action = action });
        }
        var queued = false;
        for (self.queue) |item| {
            if (item != null) queued = true;
        }
        if (self.needs_state and self.buffer == null and self.sending == null and !queued) {
            self.needs_state = false;
            return self.send(.state, .@"aqueous.get", struct {}{});
        }
        if (self.locked or self.suspended) return;
        if (self.buffer != null) return self.send(.read, .@"document.read", .{ .transfer = p.num(self.transfer), .offset = p.num(self.offset) });
        for (&self.queue) |*slot| if (slot.*) |kind| {
            self.kind = kind;
            slot.* = null;
            const revision = switch (kind) {
                .committed => self.server_version,
                .draft, .base => self.server_revision,
                .review => self.server_review,
                .report, .preview => self.server_report,
            };
            return self.send(.get, .@"document.get", .{ .domain = "aqueous", .kind = kind, .revision = p.num(revision) });
        };
        const next_job: ?u8 = if (self.remote_busy or self.recovery or self.pending_receipt) 1 else null;
        const updated = !self.ready or self.job != next_job;
        self.ready = true;
        self.job = next_job;
        if (updated) self.notify(self.context, .changed);
        if (self.sending) |bytes| {
            if (self.offset < bytes.len) {
                var end = @min(bytes.len, self.offset + 32768);
                while (end < bytes.len and end > self.offset and bytes[end] & 0xc0 == 0x80) end -= 1;
                return self.send(.write, .@"document.write", .{ .transfer = p.num(self.transfer), .offset = p.num(self.offset), .text = bytes[self.offset..end] });
            }
            self.operation = try nonce();
            return self.send(.finish, .@"document.finish", .{ .transfer = p.num(self.transfer), .operation = &self.operation.? });
        }
        if (self.dirty and !self.recovery and glib.getMonotonicTime() >= self.due) {
            self.sending = try a.dupe(u8, self.draft orelse return error.NoDraft);
            self.sent_revision = self.revision;
            self.upload_revision = self.server_revision;
            self.upload_version = self.server_version;
            self.offset = 0;
            const hash = p.digest(self.sending.?);
            return self.send(.begin, .@"document.begin", .{ .domain = "aqueous", .expected_draft_revision = p.num(self.upload_revision), .base_revision = p.num(self.upload_version), .bytes = p.num(self.sending.?.len), .sha256 = &hash });
        }
        if (self.action) |action| {
            self.action = null;
            self.submitted = action;
            // A preview choice gets its own nonce; the Apply receipt remains
            // queryable by the backend and its durable compositor receipt.
            self.operation = try nonce();
            return self.send(.action, .@"aqueous.action", .{ .operation = &self.operation.?, .expected_draft_revision = p.num(self.server_revision), .version = p.num(self.server_version), .action = action });
        }
        if (self.pending_receipt and self.operation != null and !self.remote_busy) return self.send(.receipt, .@"operation.get", .{ .operation = &self.operation.? });
        if (self.closing and !self.dirty and !self.recovery and glib.getMonotonicTime() >= self.close_due) {
            return self.send(.close, .@"frontend.close", struct {}{});
        }
    }
    fn reply(self: *Editor, reply_: Transport.Reply) !void {
        const mode = self.mode;
        self.mode = .idle;
        if (self.suspended and mode != .state) {
            self.needs_state = true;
            return;
        }
        if (reply_.error_code) |code| {
            if (mode == .cancel) {
                self.needs_state = true;
                return;
            }
            if (mode == .close and std.mem.eql(u8, code, "PreviewPending")) {
                self.close_due = glib.getMonotonicTime() + 100_000;
                self.needs_state = true;
                return;
            }
            @memset(&self.detail, 0);
            @memcpy(self.detail[0..@min(code.len, 256)], code[0..@min(code.len, 256)]);
            if (mode == .begin or mode == .write or mode == .finish) {
                if (mode != .begin) self.cancel_transfer = true;
                self.recovery = true;
                if (self.sending) |bytes| a.free(bytes);
                self.sending = null;
            }
            if (mode == .get or mode == .read) {
                if (mode == .read) self.cancel_transfer = true;
                if (self.buffer) |bytes| a.free(bytes);
                self.buffer = null;
                self.queue = @splat(null);
                self.synced_revision = null;
                self.synced_version = null;
            }
            self.needs_state = true;
            self.fail(error.BackendRejected);
            if (self.closing) {
                self.closing = false;
                self.notify(self.context, .close_failed);
            }
            return;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const v = reply_.result;
        switch (mode) {
            .cancel => {
                self.needs_state = true;
            },
            .state => {
                const state = try @import("../aqueous/entities.zig").read(api.State, alloc, v);
                const version = try p.number(state.version);
                const revision = try p.number(state.revision);
                if (self.synced_version != version) self.queue[0] = .committed;
                if (!self.dirty and !self.recovery and self.sending == null and self.synced_revision != revision) {
                    self.queue[1] = .draft;
                    self.queue[2] = .base;
                }
                if (self.synced_revision != null and self.server_revision != revision and self.dirty and self.sending == null) self.recovery = true;
                if (!state.live and !state.busy and self.synced_version == null and self.action == null) self.action = .refresh;
                self.server_version = version;
                self.server_revision = revision;
                self.server_review_revision = if (state.review_revision) |revision_| try p.number(revision_) else null;
                self.server_review = try p.number(state.review_version);
                self.server_report = try p.number(state.report_version);
                if (self.synced_review != self.server_review) self.queue[3] = .review;
                if (self.synced_report != self.server_report) {
                    self.queue[4] = .report;
                    self.queue[5] = .preview;
                }
                for (self.queue) |item| {
                    if (item != null) self.ready = false;
                }
                self.locked = state.locked;
                self.record_allowed = state.can_record;
                self.remote_busy = state.busy;
                self.remote_draft = state.draft;
                self.phase = state.phase;
                self.seconds = state.seconds;
                self.owns_preview = state.owns_preview;
                inline for (.{ "outcome", "reload_state", "toolkit", "save_state", "receipt", "display_state", "impact_route", "unresolved" }) |field| @field(self, field) = @field(state, field);
                if (state.error_code) |code| {
                    self.err = error.BackendOperationFailed;
                    @memset(&self.detail, 0);
                    _ = std.fmt.bufPrintZ(&self.detail, "{s}{s}{s}", .{ code, if (state.detail.len > 0) ": " else "", state.detail }) catch {};
                } else if (state.detail.len > 0) {
                    @memset(&self.detail, 0);
                    @memcpy(self.detail[0..@min(state.detail.len, 256)], state.detail[0..@min(state.detail.len, 256)]);
                }
            },
            .get => {
                const length = try num(v, "bytes");
                if (length > model.max_response) return error.DocumentTooLarge;
                self.transfer = try num(v, "transfer");
                self.offset = 0;
                self.hash = try p.hash(model.str(model.get(v, "sha256")));
                self.buffer = try a.alloc(u8, @intCast(length));
            },
            .read => {
                const offset = try num(v, "offset");
                const chunk = model.str(model.get(v, "text"));
                const bytes = self.buffer orelse return error.InvalidReply;
                if (offset != self.offset or chunk.len > bytes.len - self.offset) return error.InvalidReply;
                @memcpy(bytes[self.offset..][0..chunk.len], chunk);
                self.offset += chunk.len;
                if (model.get(v, "done") == .bool and model.get(v, "done").bool) {
                    defer {
                        a.free(bytes);
                        self.buffer = null;
                    }
                    if (self.offset != bytes.len or !std.mem.eql(u8, &self.hash, &p.digest(bytes))) return error.DigestMismatch;
                    try self.adopt(bytes);
                }
            },
            .begin => self.transfer = try num(v, "transfer"),
            .write => self.offset = @intCast(try num(v, "next_offset")),
            .finish, .action, .receipt => {
                const state = model.str(model.get(v, "state"));
                const success = std.mem.eql(u8, state, "succeeded");
                self.pending_receipt = std.mem.eql(u8, state, "pending");
                if (mode == .finish) {
                    if (self.sending) |bytes| a.free(bytes);
                    self.sending = null;
                    if (success) {
                        if (self.revision == self.sent_revision) self.dirty = false;
                        self.server_revision = self.upload_revision + 1;
                        self.synced_revision = self.server_revision;
                    } else self.recovery = true;
                }
                if (!success and !self.pending_receipt) {
                    const code = model.str(model.get(v, "error_code"));
                    @memset(&self.detail, 0);
                    @memcpy(self.detail[0..@min(code.len, 256)], code[0..@min(code.len, 256)]);
                    self.fail(error.BackendOperationFailed);
                } else if (success) {
                    self.err = null;
                    self.detail = @splat(0);
                }
                if (!self.pending_receipt) self.operation = null;
                self.needs_state = true;
            },
            .close => {
                self.closing = false;
                self.notify(self.context, .close_ready);
                return;
            },
            else => return error.InvalidReply,
        }
        self.notify(self.context, .changed);
    }
    fn adopt(self: *Editor, bytes: []const u8) !void {
        switch (self.kind) {
            .committed => {
                const next = try Document.create(bytes);
                if (self.live) |d| d.destroy();
                self.live = next;
                self.synced_version = self.server_version;
                self.version +|= 1;
            },
            .base => {
                if (!self.dirty and !self.recovery) {
                    const next = if (self.remote_draft) try Document.create(bytes) else null;
                    if (self.base) |d| d.destroy();
                    self.base = next;
                }
            },
            .draft => {
                if (!self.dirty and !self.recovery) {
                    const next = if (std.mem.eql(u8, bytes, "null")) null else try a.dupe(u8, bytes);
                    if (self.draft) |d| a.free(d);
                    self.draft = next;
                    self.synced_revision = self.server_revision;
                    self.revision +|= 1;
                }
            },
            .review, .report, .preview => {
                const ptr = switch (self.kind) {
                    .review => &self.review,
                    .report => &self.report,
                    else => &self.preview_report,
                };
                const next = if (std.mem.eql(u8, bytes, "null")) null else try a.dupe(u8, bytes);
                if (ptr.*) |d| a.free(d);
                ptr.* = next;
                if (self.kind == .review) {
                    self.synced_review = self.server_review;
                    self.review_version +|= 1;
                    self.review_revision = if (!self.dirty and self.server_review_revision == self.server_revision) self.revision else null;
                }
                if (self.kind == .preview) {
                    self.synced_report = self.server_report;
                    self.review_version +|= 1;
                }
            },
        }
    }
};
fn num(v: Value, key: []const u8) !u64 {
    return p.number(model.str(model.get(v, key)));
}
fn nonce() ![32]u8 {
    var bytes: [16]u8 = undefined;
    if (std.c.getrandom(&bytes, bytes.len, 0) != bytes.len) return error.RandomUnavailable;
    return std.fmt.bytesToHex(bytes, .lower);
}
