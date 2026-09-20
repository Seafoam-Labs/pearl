//! Frontend draft coordinator. All persistence and shared-draft mutations go
//! through Client. Local candidates survive failures; mutations are never replayed.
const std = @import("std");
const glib = @import("glib2");
const Client = @import("client.zig").Client;
const Reply = @import("client.zig").Reply;
const p = @import("editor_protocol.zig");
const nav = @import("../desktop/settings_navigation.zig");
const e = @import("../aqueous/entities.zig");
const model = @import("../config/preferences.zig");
const Text = @import("../services/policy.zig").Text;
const a = std.heap.c_allocator;
pub const Selection = struct { target: nav.Target, external: bool };
pub const Event = union(enum) { changed, selected: Selection, close_ready, close_failed, launch_network_editor, locked: bool };
pub const Action = enum { none, apply, discard, merge, validate };
pub const State = struct {
    revision: u64 = 0,
    draft_revision: u64 = 0,
    base_revision: u64 = 0,
    dirty: bool = false,
    valid: bool = true,
    conflict: bool = false,
    busy: bool = false,
    locked: bool = false,
};
pub const Editor = struct {
    client: *Client,
    context: *anyopaque,
    notify: *const fn (*anyopaque, Event) void,
    state: State = .{},
    error_code: Text(128) = .{},
    validation: Text(128) = .{},
    export_error: Text(128) = .{},
    night_summary: Text(4096) = .{},
    night_generation: u64 = 0,
    night_override: bool = false,
    qt_summary: Text(1024) = .{},
    qt_review_text: Text(16385) = .{},
    qt_review_digest: Text(65) = .{},
    theme_result: ?[]u8 = null,
    profile_result: ?[]u8 = null,
    profile_serial: u64 = 0,
    application_command: bool = false,
    application_review: ?[]u8 = null,
    theme_catalog_generation: u64 = 0,
    theme_discovery_degraded: bool = false,
    application_summary: Text(16384) = .{},
    theme_busy: bool = false,
    theme_serial: u64 = 0,
    theme_poll: c_uint = 0,
    theme_poll_ready: bool = false,
    theme_error: Text(128) = .{},
    theme_progress: Text(128) = .{},
    preview_transfer: ?@import("asset_transfer.zig").Transfer = null,
    preview_provider: @import("../theme/assets.zig").Provider = .{},
    preview_pending: ?[]u8 = null,
    online: bool = false,
    ready: bool = false,
    recovery: bool = false,
    suspended: bool = false,
    failed: bool = false,
    local_valid: bool = true,
    live: ?[]u8 = null,
    live_revision: u64 = 0,
    live_offset: u64 = 0,
    live_more: bool = false,
    live_command: ?struct { op: @import("client.zig").Operation, payload: []u8 } = null,
    live_receipts: [8]?[32]u8 = @splat(null),
    live_poll: usize = 8,
    querying_live: ?usize = null,
    epoch: ?[32]u8 = null,
    acknowledged: ?[]u8 = null,
    base: ?[]u8 = null,
    current: ?[]u8 = null,
    local: ?[]u8 = null,
    local_base: ?[]u8 = null,
    view: u64 = 0,
    target: nav.Target = .{},
    navigation: ?Selection = null,
    entering: Selection = .{ .target = .{}, .external = true },
    needs_snapshot: bool = false,
    want_close: bool = false,
    action: Action = .none,
    submitted: Action = .none,
    operation: ?[32]u8 = null,
    uncertain_operation: bool = false,
    sending: ?[]u8 = null,
    upload: enum { none, begin, write, finish } = .none,
    download: enum { none, draft_get, draft_read, base_get, base_read, current_get, current_read } = .none,
    transfer: u64 = 0,
    offset: usize = 0,
    buffer: ?[]u8 = null,
    hash: [64]u8 = undefined,
    incoming_draft: ?[]u8 = null,
    cancel_transfer: ?u64 = null,
    debounce: c_uint = 0,
    max_delay: c_uint = 0,
    idle: c_uint = 0,
    flushing: bool = false,

    pub fn deinit(self: *Editor) void {
        self.resetThemeJob();
        self.cancelTimers();
        self.clearLiveCommand();
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        inline for (.{ "live", "acknowledged", "base", "current", "local", "local_base", "sending", "buffer", "incoming_draft" }) |name| self.clear(&@field(self, name));
    }
    fn clear(_: *Editor, ptr: *?[]u8) void {
        if (ptr.*) |v| a.free(v);
        ptr.* = null;
    }
    fn copy(self: *Editor, ptr: *?[]u8, value: []const u8) !void {
        const next = try a.dupe(u8, value);
        self.clear(ptr);
        ptr.* = next;
    }
    pub fn text(self: *const Editor) []const u8 {
        return self.local orelse self.acknowledged orelse "{}";
    }
    fn clearLiveCommand(self: *Editor) void {
        if (self.live_command) |command| {
            std.crypto.secureZero(u8, command.payload);
            a.free(command.payload);
        }
        self.live_command = null;
    }
    pub fn themeCommand(self: *Editor, request: @import("../theme/commands.zig").Request) !void {
        if (!self.client.capabilities.community_themes) return error.Unsupported;
        if (!self.editable() or self.live_command != null or self.theme_busy) return error.Busy;
        const text_ = try std.json.Stringify.valueAlloc(a, request, .{});
        defer a.free(text_);
        self.live_command = .{ .op = .@"theme.start", .payload = try std.json.Stringify.valueAlloc(a, .{ .request = text_ }, .{}) };
        self.theme_busy = true;
        self.application_command = switch (request.action) {
            .profiles_catalog, .application_review, .application_install, .application_retry => true,
            else => false,
        };
        self.theme_error.set("");
        if (!self.application_command) self.clear(&self.theme_result);
        self.wake();
    }
    pub fn cancelTheme(self: *Editor) void {
        if (!self.online or self.live_command != null) return;
        if (self.preview_transfer) |*transfer| {
            transfer.deinit();
            self.preview_transfer = null;
            self.clear(&self.preview_pending);
            self.theme_busy = false;
            self.theme_error.set("Cancelled");
            self.wake();
            return;
        }
        self.live_command = .{ .op = .@"theme.cancel", .payload = std.json.Stringify.valueAlloc(a, .{ .serial = p.num(self.theme_serial) }, .{}) catch return };
        self.wake();
    }
    fn themeTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.theme_poll = 0;
        self.theme_poll_ready = true;
        self.wake();
        return 0;
    }
    pub fn liveAction(self: *Editor, op: @import("client.zig").Operation, params: std.json.Value) !void {
        if (!self.online or !self.ready or self.suspended or self.state.locked) return error.Unavailable;
        if (self.live_command != null) return error.Busy;
        var available = false;
        for (self.live_receipts) |slot| {
            if (slot == null) available = true;
        }
        if (!available) return error.Busy;
        var memory: [32768]u8 = undefined;
        defer std.crypto.secureZero(u8, &memory);
        var arena = std.heap.FixedBufferAllocator.init(&memory);
        const alloc = arena.allocator();
        var value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, try std.json.Stringify.valueAlloc(alloc, params, .{}), .{});
        if (value != .object) return error.InvalidRequest;
        try value.object.put(alloc, "view", .{ .string = try std.fmt.allocPrint(alloc, "{d}", .{self.view}) });
        const operation = try nonce();
        try value.object.put(alloc, "operation", .{ .string = &operation });
        self.live_command = .{ .op = op, .payload = try std.json.Stringify.valueAlloc(a, value, .{}) };
        self.wake();
    }
    pub fn livePage(self: *Editor, offset: u64) void {
        self.live_offset = offset;
        self.live_more = true;
        self.wake();
    }
    pub fn editable(self: *const Editor) bool {
        return self.online and self.ready and !self.suspended and !self.state.locked and !self.recovery and self.download == .none and self.submitted != .discard and self.submitted != .merge;
    }
    pub fn connected(self: *Editor, target: nav.Target) void {
        if (self.online) {
            self.wake();
            return;
        }
        if (!self.client.capabilities.pearl_draft) return;
        if (self.epoch) |previous| if (!std.mem.eql(u8, &previous, &self.client.epoch.?)) {
            if (self.local != null and self.base != null) {
                self.clear(&self.local_base);
                self.local_base = self.base;
                self.base = null;
            }
            if (self.operation != null) self.uncertain_operation = true;
            self.operation = null;
        };
        self.epoch = self.client.epoch;
        self.online = true;
        self.failed = false;
        self.ready = false;
        self.view = 0;
        self.target = target;
        self.navigation = .{ .target = target, .external = true };
        self.needs_snapshot = true;
        self.wake();
    }
    pub fn disconnected(self: *Editor) void {
        self.online = false;
        self.resetThemeJob();
        self.clearLiveCommand();
        self.querying_live = null;
        self.cancelTimers();
        // Keep the acknowledged candidate in this process if the backend exits.
        if (self.local == null and self.state.dirty) {
            self.local = self.acknowledged;
            self.acknowledged = null;
            self.clear(&self.local_base);
            self.local_base = self.base;
            self.base = null;
        }
        self.recovery = self.local != null;
        self.action = .none;
        self.submitted = .none;
        self.resetTransfer();
        if (self.want_close) {
            self.want_close = false;
            self.notify(self.context, .close_failed);
        }
        self.notify(self.context, .changed);
    }
    pub fn changed(self: *Editor) void {
        self.live_poll = 0;
        self.needs_snapshot = true;
        self.wake();
    }
    pub fn locked(self: *Editor, value: bool) void {
        self.state.locked = value;
        if (value) {
            self.resetThemeJob();
            self.suspended = true;
            self.clearLiveCommand();
            self.clear(&self.live);
            self.view = 0;
            self.resetTransfer();
            self.action = .none;
            self.cancelTimers();
        }
        self.notify(self.context, .{ .locked = value });
        self.changed();
    }
    fn resetThemeJob(self: *Editor) void {
        self.clear(&self.profile_result);
        self.clear(&self.application_review);
        if (self.preview_transfer) |*transfer| transfer.deinit();
        self.preview_transfer = null;
        self.clear(&self.preview_pending);
        self.preview_provider.deinit();
        if (self.theme_poll != 0) _ = glib.Source.remove(self.theme_poll);
        self.theme_poll = 0;
        self.theme_poll_ready = false;
        self.theme_busy = false;
        self.theme_serial = 0;
        self.clear(&self.theme_result);
        self.theme_error.set("");
    }
    pub fn resumeEditing(self: *Editor) void {
        if (self.state.locked) return;
        self.suspended = false;
        self.changed();
    }
    pub fn edit(self: *Editor, text_: []const u8) !void {
        if (!self.online or !self.ready or self.suspended or self.state.locked or self.download != .none) return error.Unavailable;
        if (text_.len > model.max_bytes) return error.DocumentTooLarge;
        if (!std.unicode.utf8ValidateSlice(text_) or std.mem.indexOfScalar(u8, text_, 0) != null) return error.InvalidText;
        // Allocate both candidate and merge base before replacing either.
        const next = try a.dupe(u8, text_);
        errdefer a.free(next);
        if (self.local_base == null) self.local_base = try a.dupe(u8, self.acknowledged orelse "{}");
        self.clear(&self.local);
        self.local = next;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        self.local_valid = if (model.parse(arena.allocator(), text_)) |_| true else |_| false;
        self.error_code = .{};
        self.failed = false;
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        self.debounce = glib.timeoutAdd(150, debounced, self);
        if (self.max_delay == 0) self.max_delay = glib.timeoutAdd(1000, maximumDelay, self);
        self.notify(self.context, .changed);
    }
    fn cancelTimers(self: *Editor) void {
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        if (self.max_delay != 0) _ = glib.Source.remove(self.max_delay);
        self.debounce = 0;
        self.max_delay = 0;
    }
    fn debounced(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        self.cancelTimers();
        self.wake();
        return 0;
    }
    fn maximumDelay(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.max_delay = 0;
        self.cancelTimers();
        self.wake();
        return 0;
    }
    pub fn navigate(self: *Editor, requested: nav.Target, external: bool) void {
        requested.validate() catch return;
        const target: nav.Target = .{ .page = requested.page, .section = if (requested.section) |section| nav.aqueous_sections[nav.aqueousSectionIndex(section) catch return] else null };
        self.live_offset = 0;
        self.live_more = false;
        self.navigation = .{ .target = target, .external = external };
        if (self.recovery) self.failed = false;
        if (!self.online) {
            self.target = target;
            self.navigation = null;
            self.notify(self.context, .{ .selected = .{ .target = target, .external = external } });
            return;
        }
        self.cancelTimers();
        self.wake();
    }
    pub fn close(self: *Editor) void {
        if (!self.online and self.local == null and self.sending == null) {
            self.notify(self.context, .close_ready);
            return;
        }
        if (!self.online or self.recovery) {
            self.notify(self.context, .close_failed);
            return;
        }
        self.want_close = true;
        self.cancelTimers();
        self.wake();
    }
    pub fn keepOpen(self: *Editor) void {
        self.want_close = false;
    }
    pub fn abandonClose(self: *Editor) void {
        self.want_close = false;
        self.notify(self.context, .close_ready);
    }
    pub fn retryQt(self: *Editor, op: @import("client.zig").Operation) void {
        if (!self.editable() or self.client.waiting) return;
        if (op == .@"qt.reapply") {
            if (self.qt_review_digest.len != 64) return;
            self.client.request(op, .{ .revision = p.num(self.state.revision), .digest = self.qt_review_digest.slice() }) catch |err| self.error_code.set(@errorName(err));
        } else self.client.request(op, .{ .revision = p.num(self.state.revision) }) catch |err| self.error_code.set(@errorName(err));
    }
    pub fn act(self: *Editor, action: Action) void {
        if (!self.online or !self.ready or self.state.locked) return;
        self.error_code = .{};
        self.failed = false;
        if (self.recovery) {
            if (action == .discard) {
                // The first discard in recovery drops only this process's
                // untransferred candidate, preserving the shared backend draft.
                self.clear(&self.local);
                self.clear(&self.local_base);
                self.recovery = false;
                self.uncertain_operation = false;
                self.needs_snapshot = true;
                self.wake();
                return;
            }
            if (action != .merge) return;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const merged = @import("../config/merge.zig").json(arena.allocator(), self.local_base orelse self.base orelse "{}", self.local orelse self.text(), self.acknowledged orelse "{}") catch |err| {
                self.fail(@errorName(err));
                return;
            };
            const next = a.dupe(u8, merged) catch {
                self.fail("OutOfMemory");
                return;
            };
            const next_base = a.dupe(u8, self.acknowledged orelse "{}") catch {
                a.free(next);
                self.fail("OutOfMemory");
                return;
            };
            self.clear(&self.local);
            self.clear(&self.local_base);
            self.local = next;
            self.local_base = next_base;
            self.recovery = false;
            self.uncertain_operation = false;
        }
        self.action = action;
        self.cancelTimers();
        self.wake();
    }
    fn wake(self: *Editor) void {
        if (self.idle == 0) self.idle = glib.idleAdd(pumpIdle, self);
    }
    fn pumpIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Editor = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        self.pump() catch |err| self.fail(@errorName(err));
        return 0;
    }
    fn nonce() ![32]u8 {
        var bytes: [16]u8 = undefined;
        if (std.os.linux.getrandom(&bytes, bytes.len, 0) != bytes.len) return error.RandomUnavailable;
        return std.fmt.bytesToHex(bytes, .lower);
    }
    fn pump(self: *Editor) !void {
        if (!self.online or self.client.waiting or self.suspended) return;
        if (self.preview_transfer) |*transfer| {
            try transfer.request(self.client);
            return;
        }
        if (self.cancel_transfer) |transfer| {
            self.cancel_transfer = null;
            try self.client.request(.@"document.cancel", .{ .transfer = p.num(transfer) });
            return;
        }
        if (self.failed and !self.needs_snapshot) return;
        switch (self.download) {
            .draft_get, .base_get, .current_get => {
                try self.client.request(.@"document.get", .{ .domain = "pearl", .kind = @as([]const u8, if (self.download == .draft_get) "draft" else if (self.download == .base_get) "base" else "committed"), .revision = p.num(if (self.download == .current_get) self.state.revision else self.state.draft_revision) });
                return;
            },
            .draft_read, .base_read, .current_read => {
                try self.client.request(.@"document.read", .{ .transfer = p.num(self.transfer), .offset = p.num(self.offset) });
                return;
            },
            .none => {},
        }
        switch (self.upload) {
            .begin => {
                const hash = p.digest(self.sending.?);
                try self.client.request(.@"document.begin", .{ .domain = "pearl", .expected_draft_revision = p.num(self.state.draft_revision), .base_revision = p.num(self.state.base_revision), .bytes = p.num(self.sending.?.len), .sha256 = hash[0..] });
                return;
            },
            .write => {
                const bytes = self.sending.?;
                var end = @min(bytes.len, self.offset + 32768);
                while (end < bytes.len and end > self.offset and bytes[end] & 0xc0 == 0x80) end -= 1;
                try self.client.request(.@"document.write", .{ .transfer = p.num(self.transfer), .offset = p.num(self.offset), .text = bytes[self.offset..end] });
                return;
            },
            .finish => {
                self.operation = try nonce();
                try self.client.request(.@"document.finish", .{ .transfer = p.num(self.transfer), .operation = self.operation.?[0..] });
                return;
            },
            .none => {},
        }
        if (!self.ready or self.needs_snapshot) {
            self.needs_snapshot = false;
            if (self.view == 0) {
                self.entering = self.navigation orelse .{ .target = self.target, .external = true };
                self.navigation = null;
                try self.client.request(.@"page.enter", .{ .page = self.entering.target.page, .section = self.entering.target.section });
            } else try self.client.request(.@"page.get", .{ .view = p.num(self.view) });
            return;
        }
        if (self.state.locked) return;
        if (self.live_command) |command| {
            var memory: [32768]u8 = undefined;
            defer std.crypto.secureZero(u8, &memory);
            var arena = std.heap.FixedBufferAllocator.init(&memory);
            const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), command.payload, .{});
            try self.client.request(command.op, params);
            self.clearLiveCommand();
            return;
        }
        if (self.live_more and self.view != 0) {
            self.live_more = false;
            try self.client.request(.@"list.get", .{ .view = p.num(self.view), .list = "items", .revision = p.num(self.live_revision), .offset = p.num(self.live_offset) });
            return;
        }
        if (self.theme_poll_ready) {
            self.theme_poll_ready = false;
            try self.client.request(.@"theme.get", .{ .serial = p.num(self.theme_serial) });
            return;
        }
        while (self.live_poll < self.live_receipts.len) {
            const index = self.live_poll;
            self.live_poll += 1;
            if (self.live_receipts[index]) |operation| {
                self.querying_live = index;
                try self.client.request(.@"operation.get", .{ .operation = &operation });
                return;
            }
        }
        if (self.local != null) {
            if (self.recovery) {
                if (self.want_close) {
                    self.want_close = false;
                    self.notify(self.context, .close_failed);
                }
                // Recovery must retain access to Advanced and saved-JSON review.
                // Navigation can change the read-only view without resending the
                // unacknowledged candidate or implying backend retention.
                if (self.navigation) |selection| {
                    self.navigation = null;
                    self.entering = selection;
                    try self.client.request(.@"page.enter", .{ .page = selection.target.page, .section = selection.target.section });
                }
                return;
            }
            if (self.debounce != 0 and self.navigation == null and !self.want_close and self.action == .none) return;
            self.sending = try a.dupe(u8, self.local.?);
            self.upload = .begin;
            self.offset = 0;
            self.transfer = 0;
            try self.pump();
            return;
        }
        if (self.navigation) |selection| {
            self.entering = selection;
            self.navigation = null;
            try self.client.request(.@"page.enter", .{ .page = selection.target.page, .section = selection.target.section });
            return;
        }
        if (self.operation != null and !self.state.busy) {
            try self.client.request(.@"operation.get", .{ .operation = self.operation.?[0..] });
            return;
        }
        if (self.action != .none and !self.state.busy and self.operation == null) {
            const action = self.action;
            self.action = .none;
            if (action == .merge and !self.state.conflict) {
                self.notify(self.context, .changed);
                return;
            }
            self.operation = try nonce();
            self.submitted = action;
            if (action == .apply) try self.client.request(.@"draft.apply", .{ .domain = "pearl", .expected_draft_revision = p.num(self.state.draft_revision), .base_revision = p.num(self.state.base_revision), .operation = self.operation.?[0..] }) else {
                const op: @import("client.zig").Operation = switch (action) {
                    .discard => .@"draft.discard",
                    .merge => .@"draft.merge",
                    .validate => .@"draft.validate",
                    else => unreachable,
                };
                try self.client.request(op, .{ .domain = "pearl", .expected_draft_revision = p.num(self.state.draft_revision), .operation = self.operation.?[0..] });
            }
            return;
        }
        if (self.want_close) try self.client.request(.@"frontend.close", .{ .last_draft_revision = p.num(self.state.draft_revision) });
        self.notify(self.context, .changed);
    }
    fn resetTransfer(self: *Editor) void {
        self.clear(&self.sending);
        self.clear(&self.buffer);
        self.clear(&self.incoming_draft);
        self.upload = .none;
        self.download = .none;
        self.transfer = 0;
        self.offset = 0;
    }
    fn fail(self: *Editor, code: []const u8) void {
        self.failed = true;
        self.error_code.set(code);
        if (self.transfer != 0) self.cancel_transfer = self.transfer;
        self.resetTransfer();
        self.action = .none;
        self.submitted = .none;
        self.recovery = self.local != null;
        if (self.want_close) {
            self.want_close = false;
            self.notify(self.context, .close_failed);
        }
        self.notify(self.context, .changed);
    }
    fn receiveFailure(self: *Editor, op: @import("client.zig").Operation, code: []const u8) void {
        // Another editor may commit between page.get and document.get. A stale
        // read with no local mutation is retried; it must not leave an Apply
        // failure banner after the new committed appearance arrives.
        if (op == .@"document.get" and std.mem.eql(u8, code, "StaleDraft") and self.local == null and self.upload == .none and self.operation == null and self.action == .none and self.submitted == .none) {
            if (self.transfer != 0) self.cancel_transfer = self.transfer;
            self.resetTransfer();
            self.needs_snapshot = true;
            self.failed = false;
            return;
        }
        self.fail(code);
    }
    pub fn reply(self: *Editor, reply_: Reply) void {
        if (self.suspended) {
            self.needs_snapshot = true;
            return;
        }
        self.receive(reply_) catch |err| self.receiveFailure(reply_.op, @errorName(err));
        self.notify(self.context, .changed);
        self.wake();
    }
    fn field(comptime T: type, value: std.json.Value, name: []const u8) !T {
        return e.read(T, a, try e.field(value, name));
    }
    fn count(value: std.json.Value, name: []const u8) !u64 {
        return p.number(try field([]const u8, value, name));
    }
    fn receive(self: *Editor, reply_: Reply) !void {
        if (reply_.op == .@"theme.asset") {
            if (self.preview_transfer) |*transfer| {
                if (reply_.error_code) |code| {
                    transfer.deinit();
                    self.preview_transfer = null;
                    self.clear(&self.preview_pending);
                    self.theme_error.set(code);
                    self.theme_busy = false;
                    return;
                }
                if (try transfer.accept(reply_.result)) {
                    const provider = try @import("../theme/assets.zig").Provider.init(transfer.blobs.items);
                    self.preview_provider.deinit();
                    self.preview_provider = provider;
                    transfer.deinit();
                    self.preview_transfer = null;
                    self.clear(&self.theme_result);
                    self.theme_result = self.preview_pending;
                    self.preview_pending = null;
                    self.theme_busy = false;
                }
            }
            return;
        }
        if (reply_.op == .@"theme.start" or reply_.op == .@"theme.get" or reply_.op == .@"theme.cancel") {
            if (reply_.error_code) |code| {
                self.theme_busy = false;
                self.theme_error.set(code);
                return;
            }
            const result = reply_.result;
            self.theme_serial = try count(result, "serial");
            self.theme_busy = try field(bool, result, "busy");
            const phase = try field([]const u8, result, "phase");
            const label: []const u8 = if (std.mem.eql(u8, phase, "fetching_index")) "Fetching repository" else if (std.mem.eql(u8, phase, "downloading")) "Downloading theme" else if (std.mem.eql(u8, phase, "validating")) "Validating package" else if (std.mem.eql(u8, phase, "installing")) "Installing theme" else if (std.mem.eql(u8, phase, "generating")) "Generating preview colors" else "Working";
            var progress_text: [128]u8 = undefined;
            self.theme_progress.set(try std.fmt.bufPrint(&progress_text, "{s} · {d} / {d} KiB", .{ label, (try count(result, "received")) / 1024, (try count(result, "total")) / 1024 }));
            if (result.object.get("error_code")) |code| if (code == .string) self.theme_error.set(code.string);
            if (result.object.get("result")) |value| if (value != .null) {
                const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
                if (value == .object and value.object.contains("profile_catalog")) {
                    self.clear(&self.profile_result);
                    self.profile_result = bytes;
                    self.profile_serial +%= 1;
                    return;
                }
                if (value == .object and value.object.contains("application_review")) {
                    self.clear(&self.application_review);
                    self.application_review = bytes;
                    return;
                }
                if (value == .object and (value.object.contains("application_action") or value.object.contains("application_status"))) {
                    a.free(bytes);
                    self.needs_snapshot = true;
                    return;
                }
                if (value == .object and value.object.get("images") != null) {
                    var arena = std.heap.ArenaAllocator.init(a);
                    defer arena.deinit();
                    const images = try e.read([]const @import("../theme/assets.zig").Image, arena.allocator(), value.object.get("images").?);
                    if (images.len > 0) {
                        self.preview_transfer = try @import("asset_transfer.zig").Transfer.init(images, self.theme_serial, true);
                        self.clear(&self.preview_pending);
                        self.preview_pending = bytes;
                        self.theme_busy = true;
                        return;
                    }
                }
                self.clear(&self.theme_result);
                self.theme_result = bytes;
            };
            if (self.theme_busy and self.theme_poll == 0) self.theme_poll = glib.timeoutAdd(250, themeTick, self);
            return;
        }
        if (reply_.error_code) |code| {
            if (reply_.op == .@"list.get" and std.mem.eql(u8, code, "Stale")) {
                self.needs_snapshot = true;
                return;
            }
            if (std.mem.eql(u8, code, "StaleDraft") or std.mem.eql(u8, code, "Conflict")) self.needs_snapshot = true;
            self.receiveFailure(reply_.op, code);
            return;
        }
        const v = reply_.result;
        switch (reply_.op) {
            .@"qt.retry", .@"qt.review", .@"qt.reapply" => {
                self.needs_snapshot = true;
            },
            .@"page.enter", .@"page.get" => {
                self.failed = false;
                self.view = try count(v, "view");
                self.live_revision = try count(v, "revision");
                if (v.object.get("live")) |data| if (data != .null) {
                    if (self.live_offset == 0) {
                        const encoded = try std.json.Stringify.valueAlloc(a, data, .{});
                        self.clear(&self.live);
                        self.live = encoded;
                    } else self.live_more = true;
                };
                const snapshot = try e.read(p.Snapshot, a, try e.field(v, "snapshot"));
                const revision = try p.number(snapshot.revision);
                self.theme_catalog_generation = try p.number(snapshot.theme_catalog_generation);
                self.theme_discovery_degraded = snapshot.theme_discovery_degraded;
                var app_summary: std.ArrayList(u8) = .empty;
                defer app_summary.deinit(a);
                for (snapshot.applications.targets, std.enums.values(@import("../theme/matugen_profiles.zig").Application)) |status, application| {
                    const line = try std.fmt.allocPrint(a, "{s}: {s} · {s} · {s}{s}{s}\n{s}\n{s}\n", .{ @tagName(application), @tagName(status.state), status.profile, status.origin, if (status.error_code != null) " · " else "", status.error_code orelse "", status.output, status.instructions });
                    defer a.free(line);
                    try app_summary.appendSlice(a, line);
                }
                self.application_summary.set(app_summary.items);
                const draft_revision = try p.number(snapshot.draft_revision);
                const reload = !self.ready or self.acknowledged == null or self.state.draft_revision != draft_revision or self.state.revision != revision;
                self.state = .{ .revision = revision, .draft_revision = draft_revision, .base_revision = try p.number(snapshot.base_revision), .dirty = snapshot.dirty, .valid = snapshot.valid, .conflict = snapshot.conflict, .busy = snapshot.busy, .locked = snapshot.locked };
                self.validation.set(snapshot.validation orelse "");
                self.export_error.set(snapshot.export_error orelse "");
                const summary = try std.fmt.allocPrint(a, "Qt 5: {s} {s}\nQt 6: {s} {s}\nQtEngine: {s} {s}\nDarkly: {s} {s}\nKDE accents: {s} {s}\nSession: {s} {s}{s}{s}{s}", .{
                    @tagName(snapshot.qt.qt5.state),                                                                       snapshot.qt.qt5.error_code orelse "",
                    @tagName(snapshot.qt.qt6.state),                                                                       snapshot.qt.qt6.error_code orelse "",
                    @tagName(snapshot.qt.engine.state),                                                                    snapshot.qt.engine.error_code orelse "",
                    @tagName(snapshot.qt.darkly.state),                                                                    snapshot.qt.darkly.error_code orelse "",
                    @tagName(snapshot.qt.kde.state),                                                                       snapshot.qt.kde.error_code orelse "",
                    @tagName(snapshot.qt.environment.state),                                                               snapshot.qt.environment.error_code orelse "",
                    if (snapshot.qt.busy) "\nApplying Qt appearance…" else "",
                    if (snapshot.qt.restart_apps) "\nRestart applications that retain their previous appearance." else "", if (snapshot.qt.restart_session) "\nLog in again to update the application launch environment." else "",
                });
                defer a.free(summary);
                self.qt_summary.set(summary);
                self.night_summary = .{};
                self.night_override = false;
                if (snapshot.night_light) |night| {
                    self.night_generation = try p.number(night.generation);
                    self.night_override = night.override != null;
                    var lines: std.ArrayList(u8) = .empty;
                    defer lines.deinit(a);
                    const tr = @import("../desktop/text.zig").tr;
                    const state_text = switch (night.state) {
                        .off => tr("Off", "Aus"),
                        .scheduled => tr("Scheduled", "Geplant"),
                        .unavailable => tr("Unavailable", "Nicht verfügbar"),
                    };
                    const header = try std.fmt.allocPrint(a, "{s} · {d} K\n", .{ state_text, night.temperature_kelvin });
                    defer a.free(header);
                    try lines.appendSlice(a, header);
                    for (night.outputs) |output| {
                        const line = try std.fmt.allocPrint(a, "{s}: {s}\n", .{ output.connector, tr("Display color support unavailable", "Farbunterstützung nicht verfügbar") });
                        defer a.free(line);
                        try lines.appendSlice(a, line);
                    }
                    self.night_summary.set(lines.items);
                }
                self.qt_review_text.set(snapshot.qt_review_text);
                self.qt_review_digest.set(snapshot.qt_review_digest orelse "");
                if (snapshot.error_code) |code| self.error_code.set(code);
                if (reply_.op == .@"page.enter") {
                    self.target = self.entering.target;
                    self.notify(self.context, .{ .selected = self.entering });
                }
                if (snapshot.locked) {
                    self.locked(true);
                    return;
                }
                if (reload) self.download = .draft_get else self.ready = true;
            },
            .@"document.get" => {
                const size = std.math.cast(usize, try count(v, "bytes")) orelse return error.DocumentTooLarge;
                if (size > model.max_bytes) return error.DocumentTooLarge;
                if (try count(v, "revision") != (if (self.download == .current_get) self.state.revision else self.state.draft_revision)) return error.StaleDraft;
                self.hash = try p.hash(try field([]const u8, v, "sha256"));
                self.transfer = try count(v, "transfer");
                self.buffer = try a.alloc(u8, size);
                self.offset = 0;
                self.download = if (self.download == .draft_get) .draft_read else if (self.download == .base_get) .base_read else .current_read;
            },
            .@"document.read" => {
                const text_ = try field([]const u8, v, "text");
                if (try count(v, "offset") != self.offset or text_.len > 32768 or text_.len > self.buffer.?.len - self.offset) return error.InvalidChunk;
                @memcpy(self.buffer.?[self.offset..][0..text_.len], text_);
                self.offset += text_.len;
                if (try field(bool, v, "done")) {
                    if (self.offset != self.buffer.?.len or !std.mem.eql(u8, &self.hash, &p.digest(self.buffer.?))) return error.DigestMismatch;
                    self.transfer = 0;
                    if (self.download == .draft_read) {
                        self.incoming_draft = self.buffer;
                        self.buffer = null;
                        self.download = .base_get;
                    } else if (self.download == .base_read) {
                        self.clear(&self.base);
                        self.base = self.buffer;
                        self.buffer = null;
                        self.download = .current_get;
                    } else {
                        self.clear(&self.current);
                        self.current = self.buffer;
                        self.buffer = null;
                        self.clear(&self.acknowledged);
                        self.acknowledged = self.incoming_draft;
                        self.incoming_draft = null;
                        if (self.local != null and self.local_base != null and !std.mem.eql(u8, self.local_base.?, self.acknowledged.?)) self.recovery = true;
                        self.download = .none;
                        self.ready = true;
                    }
                } else if (text_.len == 0 or self.offset == self.buffer.?.len) return error.InvalidChunk;
            },
            .@"list.get" => {
                const encoded = try std.json.Stringify.valueAlloc(a, v, .{});
                self.clear(&self.live);
                self.live = encoded;
            },
            .@"night-light.action", .@"plugin.refresh", .@"plugin.action", .@"audio.set", .@"brightness.set", .@"profile.set", .@"network.action", .@"network.editor", .@"bluetooth.action", .@"prompt.answer", .@"notifications.action", .@"lifecycle.action", .@"power.action", .@"media.action", .@"layout.get", .@"layout.set" => {
                const outcome = try field([]const u8, v, "state");
                if (std.mem.eql(u8, outcome, "pending")) {
                    const operation = try field([]const u8, v, "operation");
                    try e.sessionToken(operation);
                    for (&self.live_receipts) |*slot| if (slot.* == null) {
                        slot.* = operation[0..32].*;
                        break;
                    };
                } else if (std.mem.eql(u8, outcome, "failed")) {
                    self.error_code.set((try field(?[]const u8, v, "error_code")) orelse "ServiceFailed");
                } else if (reply_.op == .@"network.editor") self.notify(self.context, .launch_network_editor);
                self.needs_snapshot = true;
            },
            .@"document.begin" => {
                self.transfer = try count(v, "transfer");
                self.offset = 0;
                self.upload = if (self.sending.?.len == 0) .finish else .write;
            },
            .@"document.write" => {
                const next = std.math.cast(usize, try count(v, "next_offset")) orelse return error.InvalidOffset;
                if (next <= self.offset or next > self.sending.?.len or next - self.offset > 32768) return error.InvalidOffset;
                self.offset = next;
                self.upload = if (next == self.sending.?.len) .finish else .write;
            },
            .@"document.finish", .@"draft.apply", .@"draft.discard", .@"draft.merge", .@"draft.validate", .@"operation.get" => {
                const state = try field([]const u8, v, "state");
                if (reply_.op == .@"operation.get" and self.querying_live != null) {
                    const index = self.querying_live.?;
                    self.querying_live = null;
                    if (!std.mem.eql(u8, state, "pending")) {
                        self.live_receipts[index] = null;
                        if (std.mem.eql(u8, state, "failed")) self.error_code.set((try field(?[]const u8, v, "error_code")) orelse "ServiceFailed");
                        if (std.mem.eql(u8, state, "not_found")) self.uncertain_operation = true;
                    }
                    return;
                }
                if (std.mem.eql(u8, state, "pending")) {
                    self.needs_snapshot = true;
                    return;
                }
                if (std.mem.eql(u8, state, "not_found")) {
                    self.operation = null;
                    self.uncertain_operation = true;
                    self.fail("UnknownOutcome");
                    return;
                }
                self.operation = null;
                self.submitted = .none;
                if (!std.mem.eql(u8, state, "succeeded")) {
                    const code = (try field(?[]const u8, v, "error_code")) orelse "OperationFailed";
                    self.needs_snapshot = true;
                    self.fail(code);
                    return;
                }
                if (reply_.op == .@"document.finish") {
                    self.state.draft_revision = try count(try e.field(v, "receipt"), "draft_revision");
                    self.state.dirty = true;
                    self.transfer = 0;
                    self.clear(&self.acknowledged);
                    self.acknowledged = self.sending;
                    self.sending = null;
                    if (self.local) |local| if (std.mem.eql(u8, local, self.acknowledged.?)) self.clear(&self.local);
                    self.clear(&self.local_base);
                    if (self.local != null) try self.copy(&self.local_base, self.acknowledged.?);
                    self.upload = .none;
                }
                self.needs_snapshot = true;
                self.error_code = .{};
            },
            .@"document.cancel" => {},
            .@"frontend.close" => {
                self.want_close = false;
                self.notify(self.context, .close_ready);
            },
            else => return error.UnexpectedReply,
        }
    }
};
