//! Pearl editor facade. Borrows the session preference authority; never owns a
//! popup, window, persistence writer, service agent or frontend widget.
const std = @import("std");
const glib = @import("glib2");
const Service = @import("../config/service.zig").Service;
const model = @import("../config/preferences.zig");
const protocol = @import("protocol.zig");
const p = @import("editor_protocol.zig");
const Transfer = @import("transfer.zig").Transfer;
const a = std.heap.c_allocator;
fn now() i64 {
    return @divTrunc(glib.getMonotonicTime(), 1000);
}
pub const Peer = struct {
    scope: @import("live_backend.zig").Scope = .{},
    target: ?protocol.navigation.Target = null,
    view: u64 = 0,
    serial: u64 = 0,
    subscribed: bool = false,
    transfer: ?Transfer = null,
    pub fn clearTransfer(self: *Peer) void {
        if (self.transfer) |*t| t.deinit(a);
        self.transfer = null;
    }
    pub fn deinit(self: *Peer) void {
        self.clearTransfer();
        self.* = .{};
    }
    pub fn expire(self: *Peer) void {
        if (self.transfer) |t| if (now() >= t.deadline) self.clearTransfer();
    }
    fn next(self: *Peer) !u64 {
        if (self.serial == std.math.maxInt(u64)) return error.ResourceLimit;
        self.serial += 1;
        return self.serial;
    }
};
const Receipt = struct {
    nonce: [32]u8,
    fingerprint: [64]u8,
    state: enum { pending, succeeded, failed } = .pending,
    job: ?u64 = null,
    completed: i64 = 0,
    failure: ?anyerror = null,
    aqueous_job: ?u64 = null,
    aqueous_reload: bool = false,
    live_pending: @import("live_backend.zig").Pending = .none,
    draft_revision: u64 = 0,
    revision: u64 = 0,
};
pub const Backend = struct {
    service: *Service,
    live: ?@import("live_backend.zig").Live = null,
    aqueous: ?*@import("../config/aqueous_client.zig").Client = null,
    preview_owner: ?*Peer = null,
    context: *anyopaque,
    allowed: *const fn (*anyopaque) anyerror!void,
    revision: u64 = 1,
    ledger: [64]?Receipt = @splat(null),
    pub fn locked(self: *Backend) bool {
        self.allowed(self.context) catch return true;
        return false;
    }
    pub fn release(self: *Backend, peer: *Peer) void {
        if (self.live) |*live| live.release(&peer.scope);
        if (self.preview_owner == peer) {
            if (self.aqueous) |client| client.choose(false) catch {};
            self.preview_owner = null;
        }
    }
    pub fn changed(self: *Backend) void {
        self.revision +|= 1;
        for (&self.ledger) |*slot| if (slot.*) |*entry| {
            if (entry.state != .pending) continue;
            if (self.aqueous) |client| {
                if (entry.aqueous_job != null and entry.aqueous_job == client.completed_job) self.complete(entry, client.completed_error);
                if (entry.aqueous_reload and client.reload_ticket == null) self.complete(entry, if (client.reload_state == .applied) null else error.ReloadFailed);
            }
            if (entry.job != null and entry.job == self.service.completed_job) self.complete(entry, self.service.completed_error);
            if (entry.live_pending != .none) if (self.live) |*live| {
                if (!live.busy(entry.live_pending)) self.complete(entry, if (live.failure(entry.live_pending) != null) error.ServiceFailed else null);
            };
        };
    }
    fn complete(self: *Backend, entry: *Receipt, err: ?anyerror) void {
        entry.state = if (err == null) .succeeded else .failed;
        entry.failure = err;
        entry.completed = now();
        entry.draft_revision = self.service.draft.revision;
        entry.revision = self.service.revision;
    }
    fn receipt(_: *Backend, alloc: std.mem.Allocator, entry: Receipt) ![]const u8 {
        return std.json.Stringify.valueAlloc(alloc, .{ .operation = entry.nonce[0..], .state = entry.state, .receipt = .{ .draft_revision = p.num(entry.draft_revision), .revision = p.num(entry.revision) }, .error_code = if (entry.failure) |err| @errorName(err) else null }, .{});
    }
    fn find(self: *Backend, nonce: []const u8) ?*Receipt {
        for (&self.ledger) |*slot| if (slot.*) |*entry| {
            if (std.mem.eql(u8, &entry.nonce, nonce)) return entry;
        };
        return null;
    }
    fn reserve(self: *Backend, nonce: []const u8, fingerprint: [64]u8) !struct { entry: *Receipt, fresh: bool } {
        try @import("../aqueous/entities.zig").sessionToken(nonce);
        if (self.find(nonce)) |entry| {
            if (!std.mem.eql(u8, &entry.fingerprint, &fingerprint)) return error.Conflict;
            return .{ .entry = entry, .fresh = false };
        }
        for (&self.ledger) |*slot| {
            if (slot.*) |entry| if (entry.state == .pending or now() - entry.completed < 600000) continue;
            slot.* = .{ .nonce = nonce[0..32].*, .fingerprint = fingerprint };
            return .{ .entry = &slot.*.?, .fresh = true };
        }
        return error.Busy;
    }
    fn validation(self: *Backend, alloc: std.mem.Allocator) ?anyerror {
        const text = self.service.draft.text orelse return null;
        _ = model.parse(alloc, text) catch |err| return err;
        return null;
    }
    pub fn snapshot(self: *Backend, alloc: std.mem.Allocator) ![]const u8 {
        const s = self.service;
        const validation_error = self.validation(alloc);
        return std.json.Stringify.valueAlloc(alloc, .{
            .revision = p.num(s.revision),
            .draft_revision = p.num(s.draft.revision),
            .base_revision = p.num(if (s.draft.text != null) s.draft.base_revision else s.revision),
            .dirty = s.draft.text != null,
            .valid = validation_error == null,
            .validation = if (validation_error) |err| @errorName(err) else null,
            .conflict = s.draft.text != null and s.draft.base_revision != s.revision,
            .busy = s.job != null or s.pending_reload,
            .error_code = if (s.err) |err| @errorName(err) else null,
            .export_error = if (s.export_error) |err| @errorName(err) else null,
            .locked = self.locked(),
        }, .{});
    }
    fn envelope(self: *Backend, peer: *Peer, alloc: std.mem.Allocator) ![]const u8 {
        const target = peer.target orelse return error.NoView;
        const available = target.page != .aqueous or self.aqueous != null;
        const state = try self.snapshot(alloc);
        const metadata = try std.json.Stringify.valueAlloc(alloc, .{ .page = target.page, .view = p.num(peer.view), .revision = p.num(self.revision), .available = available and !self.locked(), .reason = @as(?[]const u8, if (self.locked()) "Locked" else if (!available) "Unavailable" else null) }, .{});
        const data = if (self.live) |*live| if (!self.locked()) try std.json.Stringify.valueAlloc(alloc, try live.page(alloc, &peer.scope, target.page, self.revision, 0), .{}) else "null" else "null";
        return std.fmt.allocPrint(alloc, "{s},\"snapshot\":{s},\"live\":{s}}}", .{ metadata[0 .. metadata.len - 1], state, data });
    }
    pub fn handle(self: *Backend, peer: *Peer, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        const params = request.params orelse return error.InvalidRequest;
        peer.expire();
        switch (request.op) {
            .@"aqueous.get" => {
                _ = try p.fields(struct {}, alloc, params);
                peer.subscribed = true;
                return self.aqueousState(peer, alloc);
            },
            .@"aqueous.action" => return self.aqueousAction(peer, request, alloc),
            .@"page.enter" => {
                const v = try p.fields(p.Enter, alloc, params);
                const target: protocol.navigation.Target = .{ .page = v.page, .section = v.section };
                try target.validate();
                if (self.live) |*live| {
                    if (!self.locked()) {
                        const needs_lease = switch (target.page) {
                            .network => peer.scope.network == null,
                            .bluetooth => peer.scope.bluetooth == null,
                            .power => peer.scope.power == null,
                            .overview => !peer.scope.media,
                            else => false,
                        };
                        if (peer.target == null or peer.target.?.page != target.page or needs_lease) try live.enter(&peer.scope, target.page);
                    } else live.release(&peer.scope);
                }
                peer.view = try peer.next();
                // Canonical section storage never borrows a request arena.
                peer.target = .{ .page = v.page, .section = if (v.section) |section| protocol.navigation.aqueous_sections[try protocol.navigation.aqueousSectionIndex(section)] else null };
                peer.subscribed = true;
                return self.envelope(peer, alloc);
            },
            .@"page.leave" => {
                const v = try p.fields(p.Leave, alloc, params);
                if (try p.number(v.view) != peer.view) return error.StaleView;
                self.release(peer);
                peer.target = null;
                return "{}";
            },
            .@"page.get" => {
                const v = try p.fields(p.GetPage, alloc, params);
                if (try p.number(v.view) != peer.view or peer.target == null) return error.StaleView;
                if (v.revision) |revision| if (try p.number(revision) == self.revision) return "{\"unchanged\":true}";
                return self.envelope(peer, alloc);
            },
            .@"list.get" => {
                const v = try p.fields(@import("live_protocol.zig").List, alloc, params);
                if (try p.number(v.view) != peer.view or peer.target == null) return error.StaleView;
                if (try p.number(v.revision) != self.revision) return error.Stale;
                try self.allowed(self.context);
                const live = if (self.live) |*live| live else return error.Unsupported;
                const offset = try p.number(v.offset);
                if (offset > 128) return error.InvalidOffset;
                return std.json.Stringify.valueAlloc(alloc, try live.page(alloc, &peer.scope, peer.target.?.page, self.revision, @intCast(offset)), .{});
            },
            .@"audio.set", .@"brightness.set", .@"profile.set", .@"network.action", .@"network.editor", .@"bluetooth.action", .@"prompt.answer", .@"notifications.action", .@"lifecycle.action", .@"power.action", .@"media.action", .@"layout.get", .@"layout.set" => return self.liveMutate(peer, request, alloc),
            .@"document.get" => {
                const v = try p.fields(p.GetDocument, alloc, params);
                if (peer.transfer != null) return error.TransferBusy;
                if (v.domain == .aqueous) return self.aqueousDocument(peer, v, alloc);
                const expected = if (v.kind == .committed) self.service.revision else self.service.draft.revision;
                if (try p.number(v.revision) != expected) return error.StaleDraft;
                const bytes = switch (v.kind) {
                    .committed => try std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{}),
                    .draft => self.service.draft.text orelse try std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{}),
                    .base => self.service.draft.base orelse try std.json.Stringify.valueAlloc(alloc, self.service.prefs(), .{}),
                    else => return error.InvalidRequest,
                };
                const id = try peer.next();
                const hash = p.digest(bytes);
                const t = try Transfer.create(a, id, bytes.len, hash, now(), false);
                @memcpy(t.data, bytes);
                peer.transfer = t;
                return std.json.Stringify.valueAlloc(alloc, .{ .transfer = p.num(id), .revision = p.num(expected), .bytes = p.num(bytes.len), .sha256 = hash[0..], .chunks = p.num((bytes.len + 32767) / 32768) }, .{});
            },
            .@"document.read" => {
                const v = try p.fields(p.ReadDocument, alloc, params);
                const t = if (peer.transfer) |*t| t else return error.StaleTransfer;
                const offset = try p.number(v.offset);
                const chunk = try t.read(try p.number(v.transfer), offset, now());
                const payload = try std.json.Stringify.valueAlloc(alloc, .{ .offset = p.num(offset), .text = chunk, .done = t.offset == t.data.len }, .{});
                if (t.offset == t.data.len) peer.clearTransfer();
                return payload;
            },
            .@"document.begin" => {
                const v = try p.fields(p.BeginDocument, alloc, params);
                try self.allowed(self.context);
                if (peer.transfer != null) return error.TransferBusy;
                const expected = try p.number(v.expected_draft_revision);
                const base = try p.number(v.base_revision);
                if (v.domain == .aqueous) {
                    const client = self.aqueous orelse return error.Unsupported;
                    try client.checkDraft(expected, base);
                    var t = try Transfer.createBounded(a, try peer.next(), std.math.cast(usize, try p.number(v.bytes)) orelse return error.DocumentTooLarge, try p.hash(v.sha256), now(), true, (protocol.Limits{}).aqueous_request_bytes);
                    t.domain = .aqueous;
                    t.draft_revision = expected;
                    t.base_revision = base;
                    peer.transfer = t;
                    return std.json.Stringify.valueAlloc(alloc, .{ .transfer = p.num(t.id) }, .{});
                }
                try self.service.draft.check(expected);
                if (base != (if (self.service.draft.text != null) self.service.draft.base_revision else self.service.revision)) return error.Conflict;
                var t = try Transfer.create(a, try peer.next(), std.math.cast(usize, try p.number(v.bytes)) orelse return error.DocumentTooLarge, try p.hash(v.sha256), now(), true);
                t.draft_revision = expected;
                t.base_revision = base;
                peer.transfer = t;
                return std.json.Stringify.valueAlloc(alloc, .{ .transfer = p.num(t.id) }, .{});
            },
            .@"document.write" => {
                const v = try p.fields(p.WriteDocument, alloc, params);
                try self.allowed(self.context);
                const t = if (peer.transfer) |*t| t else return error.StaleTransfer;
                try t.write(try p.number(v.transfer), try p.number(v.offset), v.text, now());
                return std.json.Stringify.valueAlloc(alloc, .{ .next_offset = p.num(t.offset) }, .{});
            },
            .@"document.cancel" => {
                const v = try p.fields(p.CancelDocument, alloc, params);
                if (peer.transfer) |t| if (t.id != try p.number(v.transfer)) return error.StaleTransfer;
                peer.clearTransfer();
                return "{}";
            },
            .@"operation.get" => {
                const v = try p.fields(p.GetOperation, alloc, params);
                try @import("../aqueous/entities.zig").sessionToken(v.operation);
                return if (self.find(v.operation)) |entry| self.receipt(alloc, entry.*) else "{\"state\":\"not_found\"}";
            },
            .@"frontend.close" => {
                const v = try p.fields(p.Close, alloc, params);
                // Later acknowledgments from another editor also prove retention.
                if (v.last_draft_revision) |revision| if (try p.number(revision) > self.service.draft.revision) return error.StaleDraft;
                if (self.preview_owner == peer) if (self.aqueous) |client| {
                    if (client.job != null) {
                        client.choose(false) catch {};
                        return error.PreviewPending;
                    }
                };
                self.release(peer);
                peer.deinit();
                return "{\"closed\":true}";
            },
            .@"document.finish", .@"draft.discard", .@"draft.merge", .@"draft.validate", .@"draft.apply" => return self.mutate(peer, request, alloc),
            else => return error.Unsupported,
        }
    }
    fn liveMutate(self: *Backend, peer: *Peer, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        const ui = @import("live_protocol.zig");
        const e = @import("../aqueous/entities.zig");
        const params = request.params.?;
        const operation = try e.read([]const u8, alloc, try e.field(params, "operation"));
        const view = try e.read([]const u8, alloc, try e.field(params, "view"));
        try self.allowed(self.context);
        if (try p.number(view) != peer.view or peer.target == null) return error.StaleView;
        const canonical = switch (request.op) {
            inline .@"audio.set", .@"brightness.set", .@"profile.set", .@"network.action", .@"network.editor", .@"bluetooth.action", .@"prompt.answer", .@"notifications.action", .@"lifecycle.action", .@"power.action", .@"media.action", .@"layout.get", .@"layout.set" => |op| blk: {
                const T = switch (op) {
                    .@"audio.set" => ui.Audio,
                    .@"brightness.set" => ui.Brightness,
                    .@"profile.set" => ui.Profile,
                    .@"network.action" => ui.Network,
                    .@"network.editor" => ui.NetworkEditor,
                    .@"bluetooth.action" => ui.Bluetooth,
                    .@"prompt.answer" => ui.Answer,
                    .@"notifications.action" => ui.Notifications,
                    .@"lifecycle.action" => ui.Lifecycle,
                    .@"power.action" => ui.Power,
                    .@"media.action" => ui.Media,
                    .@"layout.get", .@"layout.set" => ui.Layout,
                    else => unreachable,
                };
                break :blk try std.json.Stringify.valueAlloc(alloc, .{ .op = op, .params = try p.fields(T, alloc, params) }, .{});
            },
            else => return error.Unsupported,
        };
        const reserved = try self.reserve(operation, p.digest(canonical));
        if (!reserved.fresh) return self.receipt(alloc, reserved.entry.*);
        const live = if (self.live) |*live| live else return error.Unsupported;
        const pending = live.perform(&peer.scope, peer.target.?.page, self.revision, request.op, params, alloc) catch |err| {
            self.complete(reserved.entry, err);
            return self.receipt(alloc, reserved.entry.*);
        };
        reserved.entry.live_pending = pending;
        if (pending == .none or !live.busy(pending)) self.complete(reserved.entry, null);
        self.revision +|= 1;
        return self.receipt(alloc, reserved.entry.*);
    }
    fn mutate(self: *Backend, peer: *Peer, request: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        const params = request.params.?;
        const nonce = switch (request.op) {
            .@"document.finish" => (try p.fields(p.FinishDocument, alloc, params)).operation,
            .@"draft.apply" => (try p.fields(p.ApplyDraft, alloc, params)).operation,
            else => (try p.fields(p.DraftAction, alloc, params)).operation,
        };
        const canonical = switch (request.op) {
            .@"document.finish" => try std.json.Stringify.valueAlloc(alloc, .{ .op = request.op, .params = try p.fields(p.FinishDocument, alloc, params) }, .{}),
            .@"draft.apply" => try std.json.Stringify.valueAlloc(alloc, .{ .op = request.op, .params = try p.fields(p.ApplyDraft, alloc, params) }, .{}),
            else => try std.json.Stringify.valueAlloc(alloc, .{ .op = request.op, .params = try p.fields(p.DraftAction, alloc, params) }, .{}),
        };
        try self.allowed(self.context);
        const reserved = try self.reserve(nonce, p.digest(canonical));
        if (!reserved.fresh) return self.receipt(alloc, reserved.entry.*);
        self.perform(peer, request, alloc, reserved.entry) catch |err| {
            self.complete(reserved.entry, err);
            return self.receipt(alloc, reserved.entry.*);
        };
        if (reserved.entry.job == null) self.complete(reserved.entry, null);
        return self.receipt(alloc, reserved.entry.*);
    }
    fn perform(self: *Backend, peer: *Peer, r: protocol.Request, alloc: std.mem.Allocator, receipt_: *Receipt) !void {
        const params = r.params.?;
        switch (r.op) {
            .@"document.finish" => {
                const v = try p.fields(p.FinishDocument, alloc, params);
                const t = peer.transfer orelse return error.StaleTransfer;
                defer peer.clearTransfer();
                const bytes = try t.finish(try p.number(v.transfer), now());
                if (t.domain == .aqueous) {
                    const client = self.aqueous orelse return error.Unsupported;
                    try client.keepDraftExpected(bytes, t.draft_revision, t.base_revision);
                } else _ = try self.service.keepDraft(bytes, t.draft_revision, t.base_revision);
            },
            .@"draft.apply" => {
                const v = try p.fields(p.ApplyDraft, alloc, params);
                if (v.domain != .pearl) return error.InvalidRequest;
                try self.service.applyDraft(try p.number(v.expected_draft_revision), try p.number(v.base_revision));
                receipt_.job = self.service.jobs;
            },
            else => {
                const v = try p.fields(p.DraftAction, alloc, params);
                if (v.domain != .pearl) return error.InvalidRequest;
                const expected = try p.number(v.expected_draft_revision);
                switch (r.op) {
                    .@"draft.discard" => try self.service.discardDraft(expected),
                    .@"draft.merge" => try self.service.mergeDraft(expected),
                    .@"draft.validate" => {
                        try self.service.draft.check(expected);
                        if (self.validation(alloc)) |err| return err;
                    },
                    else => unreachable,
                }
            },
        }
    }
    fn aqueousState(self: *Backend, peer: *Peer, alloc: std.mem.Allocator) ![]const u8 {
        const c = self.aqueous orelse return error.Unsupported;
        return std.json.Stringify.valueAlloc(alloc, .{
            .version = p.num(c.version),
            .revision = p.num(c.revision),
            .review_version = p.num(c.review_version),
            .report_version = p.num(c.report_version),
            .review_revision = if (c.review_revision) |revision| @as(?p.Number, p.num(revision)) else null,
            .live = c.live != null,
            .draft = c.draft != null,
            .busy = c.job != null or c.reload_ticket != null,
            .locked = self.locked(),
            .can_record = c.can_record(c.context),
            .can_reload = c.can_reload(c.context),
            .conflict = c.conflict(),
            .unresolved = c.unresolved,
            .outcome = c.outcome,
            .reload_state = c.reload_state,
            .toolkit = c.toolkit,
            .save_state = c.save_state,
            .receipt = c.receipt,
            .display_state = c.display_state,
            .impact_route = c.impact_route,
            .error_code = if (c.err) |err| @errorName(err) else null,
            .detail = std.mem.sliceTo(&c.detail, 0),
            .phase = c.previewPhase(),
            .seconds = c.remaining(),
            .owns_preview = self.preview_owner == peer,
        }, .{});
    }
    fn aqueousDocument(self: *Backend, peer: *Peer, v: p.GetDocument, alloc: std.mem.Allocator) ![]const u8 {
        try self.allowed(self.context);
        const c = self.aqueous orelse return error.Unsupported;
        const revision = switch (v.kind) {
            .committed => c.version,
            .draft, .base => c.revision,
            .review => c.review_version,
            .report, .preview => c.report_version,
        };
        if (try p.number(v.revision) != revision) return error.StaleDraft;
        const generated: ?[]u8 = switch (v.kind) {
            .committed => try std.json.Stringify.valueAlloc(a, c.value(), .{}),
            .base => try std.json.Stringify.valueAlloc(a, c.baseValue(), .{}),
            else => null,
        };
        defer if (generated) |bytes| a.free(bytes);
        const bytes = switch (v.kind) {
            .committed, .base => generated.?,
            .draft => c.draft orelse "null",
            .review => c.review orelse "null",
            .report => c.report orelse "null",
            .preview => c.preview_report orelse "null",
        };
        const hash = p.digest(bytes);
        var t = try Transfer.createBounded(a, try peer.next(), bytes.len, hash, now(), false, (protocol.Limits{}).aqueous_response_bytes);
        t.domain = .aqueous;
        @memcpy(t.data, bytes);
        peer.transfer = t;
        return std.json.Stringify.valueAlloc(alloc, .{ .transfer = p.num(t.id), .revision = p.num(revision), .bytes = p.num(bytes.len), .sha256 = hash[0..], .chunks = p.num((bytes.len + 32767) / 32768) }, .{});
    }
    fn aqueousAction(self: *Backend, peer: *Peer, r: protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
        const v = try p.fields(@import("aqueous_protocol.zig").Action, alloc, r.params.?);
        try self.allowed(self.context);
        const c = self.aqueous orelse return error.Unsupported;
        const canonical = try std.json.Stringify.valueAlloc(alloc, .{ .op = r.op, .params = v }, .{});
        const reserved = try self.reserve(v.operation, p.digest(canonical));
        if (!reserved.fresh) return self.receipt(alloc, reserved.entry.*);
        self.aqueousPerform(peer, c, v, reserved.entry) catch |err| {
            self.complete(reserved.entry, err);
            return self.receipt(alloc, reserved.entry.*);
        };
        if (reserved.entry.aqueous_job == null and !reserved.entry.aqueous_reload) self.complete(reserved.entry, null);
        c.changed(c.context);
        return self.receipt(alloc, reserved.entry.*);
    }
    fn aqueousPerform(self: *Backend, peer: *Peer, c: *@import("../config/aqueous_client.zig").Client, v: @import("aqueous_protocol.zig").Action, entry: *Receipt) !void {
        if (v.action == .revert) {
            if (self.preview_owner != peer) return error.NotOwner;
            return c.choose(false);
        }
        try c.checkDraft(try p.number(v.expected_draft_revision), try p.number(v.version));
        switch (v.action) {
            .refresh, .validate, .apply => {
                try c.begin(switch (v.action) {
                    .refresh => .refresh,
                    .validate => .validate,
                    else => .apply,
                });
                entry.aqueous_job = c.jobs;
                if (v.action == .apply) self.preview_owner = peer;
            },
            .discard => {
                if (c.job != null) return error.Busy;
                c.discard();
            },
            .rebase => try c.rebase(),
            .reload => {
                try c.requestReload();
                entry.aqueous_reload = true;
            },
            .keep => {
                if (self.preview_owner != peer) return error.NotOwner;
                try c.choose(true);
            },
            .revert => unreachable,
        }
    }
};
