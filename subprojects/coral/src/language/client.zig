//! Single-threaded, bounded LSP session over Transport. No app/UI callbacks.
//! Caller owns one session per (canonical root_uri, language_id, configuration),
//! supplies explicit transport authorization/environment and monotonic tick time,
//! and decides whether/when to create a NEW session after failure. Never restarts.
//! All input slices/JSON are copied before return. nextEvent transfers ownership;
//! Event.deinit is required, and events may outlive the client. Capability values
//! borrow the client until destroy. Keep ticking after stop/failure until drained;
//! destroy returns NotDrained rather than freeing an active transport.
//!
//! Bounds exclude caller-retained events and transport worker/kernel resources:
//! 64 pending requests, 64 server requests, 64 queued events, 128 lifetime URIs,
//! 8 MiB document text, 4 MiB queued JSON, 256 KiB capabilities, 64 KiB per
//! configuration JSON value. Individual outgoing payloads reserve 64 KiB of the
//! protocol message limit for envelopes. Configure transport.input_limit to fit
//! complete frames; backpressure/oversized transport sends terminate the session.
//! JSON DOM overhead is additionally bounded by protocol's byte/depth limits.
//! A tick reads <=64 KiB and dispatches <=16 messages. Saturated event/output
//! queues fail closed (observable failure + final event), never silently drop RPCs.
//!
//! Observed stdout EOF finishes framing independently of process completion.
//! Unexpected EOF stops the child immediately; expected shutdown EOF preserves
//! the shutdown grace period to flush exit, then stops any lingering child.
//! Neither EOF nor a stop request permits destroy before the transport is reaped.
const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const positions = @import("positions.zig");
const uri_util = @import("uri.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Parsed = std.json.Parsed(Value);

pub const max_requests = 64;
pub const max_events = 64;
pub const max_documents = 128;
pub const max_document_bytes = 8 * 1024 * 1024;
pub const max_event_bytes = 4 * 1024 * 1024;
pub const max_capability_bytes = 256 * 1024;
pub const max_config_bytes = 64 * 1024;
pub const messages_per_tick = 16;
pub const bytes_per_tick = 64 * 1024;
const max_name_bytes = 1024;
const max_uri_bytes = 8192;
// Process-wide non-reused identities prevent retained events/review tokens from
// accidentally matching a replacement session, even when allocator addresses,
// caller document IDs and document versions are all reused.
var next_identity: std.atomic.Value(u64) = .init(1);
fn identity() !u64 {
    var current = next_identity.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (next_identity.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual|
            current = actual
        else
            return current;
    }
    return error.GenerationExhausted;
}

pub const State = enum { starting, initializing, ready, stopping, crashed, stopped };
pub const Context = struct {
    /// Filled by the client; reject retained contexts from previous sessions.
    session: ?u64 = null,
    doc_id: ?u64 = null,
    revision: ?i32 = null,
    generation: ?u64 = null,
};
pub const Config = struct {
    transport: transport.Config,
    root: []const u8,
    language_id: []const u8,
    /// JSON value, not a quoted string. null means JSON null.
    initialization_options: ?[]const u8 = null,
    /// JSON object recursively added to the minimal capabilities. Cannot replace
    /// existing leaves. Advertise only features the caller actually implements.
    additional_capabilities: ?[]const u8 = null,
    initialize_timeout_ms: u32 = 10_000,
    request_timeout_ms: u32 = 30_000,
    shutdown_timeout_ms: u32 = 1_000,
    /// Unknown server requests normally receive MethodNotFound. Edit/execute/
    /// showDocument requests ALWAYS go to review, regardless of this setting.
    surface_server_requests: bool = false,
    unversioned_diagnostics: enum { drop, surface_unverified } = .drop,
};
pub const Sync = enum { none, full, incremental };
pub const Capabilities = struct {
    encoding: positions.Encoding = .utf16,
    sync: Sync = .none,
    open_close: bool = false,
    save: bool = false,
    save_include_text: bool = false,
    will_save: bool = false,
    will_save_wait_until: bool = false,
    workspace_folders: bool = false,
    /// Full server capability object, including all options/unknown extensions.
    options: Value = .null,

    /// Standard boolean-or-options providers, e.g. completionProvider. No
    /// assumptions about the UI or special casing of feature request methods.
    pub fn supports(self: Capabilities, name: []const u8) bool {
        const v = protocol.field(self.options, name) orelse return false;
        return switch (v) {
            .bool => v.bool,
            .object => true,
            else => false,
        };
    }
};
pub const Event = struct {
    pub const Kind = enum { ready, response, server_request, notification, diagnostics, progress, status, cancelled, timed_out, finished };
    kind: Kind,
    allocator: Allocator,
    /// Complete owned JSON-RPC envelope. Null only for local events.
    message: ?Parsed = null,
    /// Owned for responses/timeouts/cancellation; borrowed from message otherwise.
    method: []const u8 = "",
    owned_method: ?[]u8 = null,
    id: ?i64 = null,
    context: Context = .{},
    /// Opaque single-use token, not the server's JSON-RPC id.
    token: ?u64 = null,
    version: ?i32 = null,
    /// false for explicitly opted-in, unversioned diagnostics. Never treat these
    /// as authoritative merely because context matches the current document.
    verified: bool = false,
    failure: ?anyerror = null,
    result: ?transport.Result = null,
    charge: usize = 0,

    pub fn value(self: *const Event) Value {
        return if (self.message) |m| m.value else .null;
    }
    pub fn deinit(self: *Event) void {
        if (self.message) |m| m.deinit();
        if (self.owned_method) |m| self.allocator.free(m);
        self.* = undefined;
    }
};
const Pending = struct { id: i64, method: []u8, context: Context, deadline: u64 };
const Incoming = struct { token: u64, id: protocol.Id, deadline: u64 };
const Document = struct {
    uri: []u8,
    text: []u8,
    id: u64,
    version: i32,
    generation: u64,
    open: bool,
};

pub const Client = struct {
    allocator: Allocator,
    pipe: *transport.Transport,
    framer: protocol.Framer,
    root_uri: []u8,
    language_id: []u8,
    session: u64,
    state: State = .starting,
    failure: ?anyerror = null,
    capabilities: Capabilities = .{},
    capability_storage: ?Parsed = null,
    initialize_body: ?[]u8,
    initialize_timeout_ms: u32,
    request_timeout_ms: u32,
    shutdown_timeout_ms: u32,
    surface_server_requests: bool,
    surface_unversioned: bool,
    now: ?u64 = null,
    deadline: u64 = 0,
    next_id: i64 = 2,
    shutdown_id: ?i64 = null,
    exit_sent: bool = false,
    early_stop: bool = false,
    output_closed: bool = false,
    eof_stop_requested: bool = false,
    next_generation: u64 = 1,
    pending: [max_requests]?Pending = @splat(null),
    incoming: [max_requests]?Incoming = @splat(null),
    documents: [max_documents]?Document = @splat(null),
    document_bytes: usize = 0,
    events: [max_events]?Event = @splat(null),
    event_head: usize = 0,
    event_count: usize = 0,
    event_bytes: usize = 0,
    finished: ?Event = null,
    completion_seen: bool = false,

    pub fn init(allocator: Allocator, config: Config) !*Client {
        if (config.transport.authorization != .approved) return error.Unauthorized;
        if (config.root.len > max_uri_bytes or config.language_id.len == 0 or config.language_id.len > max_name_bytes or
            !std.unicode.utf8ValidateSlice(config.language_id) or config.initialize_timeout_ms == 0 or
            config.request_timeout_ms == 0 or config.shutdown_timeout_ms == 0) return error.InvalidConfig;
        const root = try uri_util.fromPath(allocator, config.root);
        errdefer allocator.free(root);
        const language = try allocator.dupe(u8, config.language_id);
        errdefer allocator.free(language);
        const body = try initializeBody(allocator, config, root);
        errdefer allocator.free(body);
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        const session = try identity();
        // No fallible allocation after starting the detached transport worker.
        const pipe = try transport.start(allocator, config.transport);
        self.* = .{
            .allocator = allocator,
            .pipe = pipe,
            .framer = .init(allocator),
            .root_uri = root,
            .language_id = language,
            .session = session,
            .initialize_body = body,
            .initialize_timeout_ms = config.initialize_timeout_ms,
            .request_timeout_ms = config.request_timeout_ms,
            .shutdown_timeout_ms = config.shutdown_timeout_ms,
            .surface_server_requests = config.surface_server_requests,
            .surface_unversioned = config.unversioned_diagnostics == .surface_unverified,
        };
        return self;
    }

    /// Nonblocking. Time is milliseconds in any monotonic caller clock domain.
    /// On error the failure is latched and transport stopped; KEEP ticking to
    /// drain/reap. Terminal errors are returned once, also retained in failure.
    pub fn tick(self: *Client, now_ms: u64) !void {
        if (self.now) |previous| if (now_ms < previous) return error.NonMonotonicTime;
        self.now = now_ms;
        self.tickInner() catch |err| {
            self.fail(err);
            return err;
        };
    }

    fn tickInner(self: *Client) !void {
        if (self.completion_seen) return;
        if (self.state == .starting) {
            try self.sendBody(self.initialize_body.?);
            self.allocator.free(self.initialize_body.?);
            self.initialize_body = null;
            self.state = .initializing;
            self.deadline = self.after(self.initialize_timeout_ms);
        }
        // Expire before reading: responses arriving after a caller-clock deadline
        // cannot revive expired requests merely because they were queued in a pipe.
        if (self.failure == null) {
            if (self.state == .initializing and self.now.? >= self.deadline) return error.InitializeTimeout;
            if (self.state == .ready) try self.expireRequests();
        }
        var buffer: [4096]u8 = undefined;
        var bytes: usize = 0;
        var messages: usize = 0;
        while (messages < messages_per_tick) {
            if (self.failure == null) {
                if (try self.framer.next()) |body| {
                    defer self.allocator.free(body);
                    try self.dispatch(body);
                    messages += 1;
                    continue;
                }
            }
            if (bytes == bytes_per_tick) break;
            const n = self.pipe.read(buffer[0..@min(buffer.len, bytes_per_tick - bytes)]);
            if (n == 0) break;
            bytes += n;
            if (self.failure == null) try self.framer.feed(buffer[0..n]);
        }
        // Transport EOF guarantees drained bytes, not drained Framer messages.
        // In particular, a shutdown response may be behind the dispatch budget.
        if (self.failure == null and !self.output_closed and self.pipe.isOutputClosed()) {
            // This finite queue must also drain before deciding whether shutdown
            // timed out: its final message may be the shutdown acknowledgement.
            if (self.framer.queue.items.len != 0) return;
            try self.framer.finish();
            self.output_closed = true;
            if (!(self.state == .stopping and (self.early_stop or self.exit_sent))) return error.ServerExited;
        }
        // Process completion is separate: errors/forced pipe closure need not
        // publish EOF, so finish framing here too if EOF was not observed.
        if (self.pipe.result()) |result| {
            if (self.failure == null and self.framer.queue.items.len != 0) return;
            if (self.failure == null) {
                if (!self.output_closed) self.framer.finish() catch |err| self.fail(err);
                const expected_result = result.outcome == .success or (self.eof_stop_requested and result.outcome == .cancelled);
                if (self.failure == null and !(self.state == .stopping and (self.early_stop or (self.exit_sent and expected_result))))
                    self.fail(error.ServerExited);
            }
            self.completion_seen = true;
            self.clearRequests();
            self.state = if (self.failure == null) .stopped else .crashed;
            self.finished = .{ .kind = .finished, .allocator = self.allocator, .failure = self.failure, .result = result };
            return;
        }
        if (self.failure == null and self.state == .stopping and !self.early_stop and !self.eof_stop_requested and self.now.? >= self.deadline) {
            // Give the already-accepted exit notification time to flush. Once
            // shutdown + clean EOF have completed, terminating a lingering
            // process is cleanup, not a protocol crash or a shutdown timeout.
            if (!self.output_closed or !self.exit_sent) return error.ShutdownTimeout;
            self.eof_stop_requested = true;
            self.pipe.stop();
        }
    }

    fn expireRequests(self: *Client) !void {
        for (&self.pending) |*slot| {
            if (slot.*) |p| if (self.now.? >= p.deadline) {
                slot.* = null;
                var event: Event = .{ .kind = .timed_out, .allocator = self.allocator, .id = p.id, .method = p.method, .owned_method = p.method, .context = p.context };
                defer event.deinit();
                try self.sendNotification("$/cancelRequest", .{ .id = p.id });
                try self.enqueue(&event);
            };
        }
        for (&self.incoming) |*slot| {
            if (slot.*) |p| if (self.now.? >= p.deadline) {
                try self.sendError(p.id, -32800, "Client review timed out");
                self.freeIncoming(slot);
            };
        }
    }

    pub fn request(self: *Client, method: []const u8, params: Value, context: Context) !i64 {
        try self.requireReady();
        try validMethod(method);
        if (reserved(method)) return error.ReservedMethod;
        try validateValue(params);
        const ctx = try self.resolveContext(context);
        var slot: ?*?Pending = null;
        for (&self.pending) |*s| if (s.* == null) {
            slot = s;
            break;
        };
        const target = slot orelse return error.RequestLimit;
        const id = try self.allocateId();
        const owned = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned);
        const body = try protocol.encodeRequest(self.allocator, .{ .integer = id }, method, params);
        defer self.allocator.free(body);
        try self.sendBody(body);
        target.* = .{ .id = id, .method = owned, .context = ctx, .deadline = self.after(self.request_timeout_ms) };
        return id;
    }

    /// Idempotent for completed/unknown ids. Removes before sending cancellation,
    /// so even a racing response cannot regain authority over a changed document.
    pub fn cancel(self: *Client, id: i64) !void {
        for (&self.pending) |*slot| {
            if (slot.*) |p| if (p.id == id) {
                slot.* = null;
                var event: Event = .{ .kind = .cancelled, .allocator = self.allocator, .id = id, .method = p.method, .owned_method = p.method, .context = p.context };
                defer event.deinit();
                try self.sendNotification("$/cancelRequest", .{ .id = id });
                self.enqueue(&event) catch |err| {
                    self.fail(err);
                    return err;
                };
                return;
            };
        }
    }

    pub fn notify(self: *Client, method: []const u8, params: Value) !void {
        try self.requireReady();
        try validMethod(method);
        if (reserved(method)) return error.ReservedMethod;
        try validateValue(params);
        try self.sendNotification(method, params);
    }

    /// Explicit caller approval/result for a server request. Never performs an
    /// edit, command, filesystem operation, or UI action itself. Tokens expire.
    pub fn respond(self: *Client, token: u64, result: Value) !void {
        try self.requireReady();
        const slot = self.incomingSlot(token) orelse return error.UnknownServerRequest;
        try validateValue(result);
        const body = try protocol.encodeResponse(self.allocator, slot.*.?.id, result);
        defer self.allocator.free(body);
        try self.sendBody(body);
        self.freeIncoming(slot);
    }
    pub fn reject(self: *Client, token: u64, code: i64, message: []const u8) !void {
        try self.requireReady();
        const slot = self.incomingSlot(token) orelse return error.UnknownServerRequest;
        try validateValue(.{ .string = message });
        try self.sendError(slot.*.?.id, code, message);
        self.freeIncoming(slot);
    }

    /// URI must be canonical local file URI. Versions are strictly increasing
    /// across close/reopen of the SAME URI for this session, preventing a delayed
    /// diagnostic from an earlier incarnation matching a newly opened document.
    /// Tombstones consume one of the 128 lifetime URI slots; never evicted.
    pub fn open(self: *Client, uri: []const u8, doc_id: u64, version: i32, text: []const u8) !Context {
        try self.requireReady();
        try self.validateUri(uri);
        try validText(text);
        var target: ?*?Document = null;
        for (&self.documents) |*slot| {
            if (slot.*) |d| {
                if (d.open and d.id == doc_id) return error.DocumentAlreadyOpen;
                if (std.mem.eql(u8, uri, d.uri)) {
                    if (d.open) return error.DocumentAlreadyOpen;
                    if (version <= d.version) return error.StaleVersion;
                    target = slot;
                }
            }
        }
        if (target == null) for (&self.documents) |*slot| if (slot.* == null) {
            target = slot;
            break;
        };
        const slot = target orelse return error.DocumentLimit;
        if (text.len > max_document_bytes - self.document_bytes) return error.DocumentLimit;
        if (self.next_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        if (self.capabilities.open_close) try self.sendNotification("textDocument/didOpen", .{
            .textDocument = .{ .uri = uri, .languageId = self.language_id, .version = version, .text = text },
        });
        if (slot.*) |old| {
            self.allocator.free(old.uri);
            self.allocator.free(old.text);
        }
        slot.* = .{ .uri = owned_uri, .text = owned_text, .id = doc_id, .version = version, .generation = self.next_generation, .open = true };
        self.next_generation += 1;
        self.document_bytes += text.len;
        return self.stamp(slot.*.?);
    }

    /// Full replacement API. For incremental servers this is a single ranged
    /// replacement covering the OLD document in the negotiated position encoding.
    /// Thus callers need not compute diffs, and CRLF/astral boundaries stay valid.
    pub fn change(self: *Client, uri: []const u8, version: i32, text: []const u8) !Context {
        try self.requireReady();
        const d = self.document(uri) orelse return error.DocumentNotOpen;
        if (version <= d.version) return error.StaleVersion;
        try validText(text);
        if (text.len > max_document_bytes - (self.document_bytes - d.text.len)) return error.DocumentLimit;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.cancelDocument(d.id);
        switch (self.capabilities.sync) {
            .none => {},
            .full => try self.sendNotification("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .text = text }} }),
            .incremental => {
                const range: positions.Range = .{ .start = .{ .line = 0, .character = 0 }, .end = try positions.positionAt(d.text, d.text.len, self.capabilities.encoding) };
                try self.sendNotification("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .range = range, .text = text }} });
            },
        }
        self.document_bytes = self.document_bytes - d.text.len + text.len;
        self.allocator.free(d.text);
        d.text = owned;
        d.version = version;
        return self.stamp(d.*);
    }
    pub fn save(self: *Client, uri: []const u8) !void {
        try self.requireReady();
        const d = self.document(uri) orelse return error.DocumentNotOpen;
        if (!self.capabilities.save) return;
        if (self.capabilities.save_include_text)
            try self.sendNotification("textDocument/didSave", .{ .textDocument = .{ .uri = uri }, .text = d.text })
        else
            try self.sendNotification("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    }
    pub fn close(self: *Client, uri: []const u8) !void {
        try self.requireReady();
        const d = self.document(uri) orelse return error.DocumentNotOpen;
        try self.cancelDocument(d.id);
        if (self.capabilities.open_close) try self.sendNotification("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
        self.document_bytes -= d.text.len;
        self.allocator.free(d.text);
        d.text = &.{};
        d.open = false;
    }
    pub fn contextFor(self: *Client, uri: []const u8) ?Context {
        return if (self.document(uri)) |d| self.stamp(d.*) else null;
    }
    /// Recheck immediately before applying a retained response/diagnostics event.
    pub fn isCurrent(self: *const Client, context: Context) bool {
        if (context.session != self.session or self.state != .ready) return false;
        if (context.doc_id) |id| {
            for (self.documents) |slot| if (slot) |d| {
                if (d.open and d.id == id) return context.revision == d.version and context.generation == d.generation;
            };
            return false;
        }
        return context.revision == null and context.generation == null;
    }

    /// Starts shutdown -> response -> exit -> EOF; force-stops after the caller
    /// clock deadline. Transport then applies its independent TERM/KILL/reap bound.
    /// stop before initialization is immediate transport cancellation.
    pub fn stop(self: *Client) !void {
        if (self.state == .stopped or self.state == .crashed or self.state == .stopping) return;
        const was_ready = self.state == .ready;
        self.state = .stopping;
        self.deadline = self.after(self.shutdown_timeout_ms);
        self.clearRequests();
        if (!was_ready) {
            self.early_stop = true;
            self.pipe.stop();
            return;
        }
        const id = self.allocateId() catch |err| {
            self.fail(err);
            return err;
        };
        self.shutdown_id = id;
        const body = protocol.encodeRequest(self.allocator, .{ .integer = id }, "shutdown", null) catch |err| {
            self.fail(err);
            return err;
        };
        defer self.allocator.free(body);
        try self.sendBody(body);
    }

    /// Queued document responses/diagnostics are filtered again on delivery.
    /// A final event is reserved outside the queue, even when overflow caused failure.
    pub fn nextEvent(self: *Client) ?Event {
        while (self.event_count > 0) {
            var event = self.events[self.event_head].?;
            self.events[self.event_head] = null;
            self.event_head = (self.event_head + 1) % max_events;
            self.event_count -= 1;
            self.event_bytes -= event.charge;
            if ((event.kind == .response or event.kind == .diagnostics) and !self.isCurrent(event.context)) {
                event.deinit();
                continue;
            }
            if (event.kind == .server_request and self.incomingSlot(event.token.?) == null) {
                event.deinit();
                continue;
            }
            return event;
        }
        const event = self.finished;
        self.finished = null;
        return event;
    }
    pub fn isDrained(self: *const Client) bool {
        return self.completion_seen;
    }
    /// Frees undelivered events too. Transferred events remain caller-owned.
    pub fn destroy(self: *Client) !void {
        if (!self.isDrained()) return error.NotDrained;
        self.clearRequests();
        while (self.nextEvent()) |e| {
            var event = e;
            event.deinit();
        }
        for (self.documents) |slot| if (slot) |d| {
            self.allocator.free(d.uri);
            self.allocator.free(d.text);
        };
        if (self.initialize_body) |body| self.allocator.free(body);
        if (self.capability_storage) |parsed| parsed.deinit();
        self.framer.deinit();
        self.pipe.destroy();
        self.allocator.free(self.root_uri);
        self.allocator.free(self.language_id);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn dispatch(self: *Client, body: []const u8) !void {
        var event: Event = .{ .kind = .notification, .allocator = self.allocator, .message = try protocol.parseMessage(self.allocator, body), .charge = body.len };
        defer event.deinit();
        const value = event.value();
        if (!eqString(protocol.field(value, "jsonrpc"), "2.0")) return error.InvalidEnvelope;
        if (protocol.field(value, "method")) |m| {
            const method = protocol.string(m) orelse return error.InvalidEnvelope;
            try validMethod(method);
            if (protocol.field(value, "result") != null or protocol.field(value, "error") != null) return error.InvalidEnvelope;
            event.method = method;
            if (protocol.field(value, "params")) |params| if (params != .object and params != .array and params != .null) return error.InvalidEnvelope;
            if (protocol.field(value, "id") != null) {
                try self.serverRequest(&event);
            } else if (self.state == .ready or self.state == .initializing) {
                if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                    if (self.state == .ready) try self.diagnosticsEvent(&event);
                } else if (std.mem.eql(u8, method, "$/cancelRequest")) {
                    const params = protocol.field(value, "params") orelse return error.InvalidEnvelope;
                    const id = try protocol.responseId(params);
                    for (&self.incoming) |*slot| if (slot.*) |p| {
                        if (idsEqual(p.id, id)) {
                            try self.sendError(p.id, -32800, "Client review cancelled");
                            self.freeIncoming(slot);
                        }
                    };
                } else {
                    event.kind = if (std.mem.eql(u8, method, "$/progress")) .progress else if (std.mem.startsWith(u8, method, "window/")) .status else .notification;
                    try self.enqueue(&event);
                }
            }
            return;
        }
        const id = try protocol.responseId(value);
        const result = protocol.field(value, "result");
        const rpc_error = protocol.field(value, "error");
        if ((result == null) == (rpc_error == null)) return error.InvalidEnvelope;
        if (rpc_error) |err| {
            if (protocol.integer(protocol.field(err, "code") orelse .null) == null or protocol.string(protocol.field(err, "message") orelse .null) == null) return error.InvalidEnvelope;
        }
        if (id != .integer) return;
        if (id.integer == 1 and self.state == .initializing) {
            if (rpc_error != null) return error.InitializeRejected;
            try self.negotiate(result.?);
            try self.sendNotification("initialized", struct {}{});
            self.state = .ready;
            event.kind = .ready;
            try self.enqueue(&event);
            return;
        }
        if (self.state == .stopping and self.shutdown_id == id.integer and !self.exit_sent) {
            // Even a shutdown error must not prevent the final exit notification.
            try self.sendNotification("exit", null);
            self.exit_sent = true;
            self.pipe.closeInput();
            return;
        }
        if (self.state != .ready) return;
        for (&self.pending) |*slot| if (slot.*) |p| {
            if (p.id == id.integer) {
                slot.* = null;
                event.kind = .response;
                event.id = p.id;
                event.method = p.method;
                event.owned_method = p.method;
                event.context = p.context;
                if (self.isCurrent(p.context)) try self.enqueue(&event);
                return;
            }
        };
        // Unknown, cancelled, duplicate and late responses have no side effects.
    }

    fn negotiate(self: *Client, result: Value) !void {
        const options = protocol.field(result, "capabilities") orelse return error.InvalidCapabilities;
        if (options != .object) return error.InvalidCapabilities;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, options, .{});
        defer self.allocator.free(bytes);
        if (bytes.len > max_capability_bytes) return error.CapabilityLimit;
        var caps: Capabilities = .{};
        if (protocol.field(options, "positionEncoding")) |v| {
            if (eqString(v, "utf-8")) caps.encoding = .utf8 else if (eqString(v, "utf-16")) caps.encoding = .utf16 else if (eqString(v, "utf-32")) caps.encoding = .utf32 else return error.UnsupportedEncoding;
        }
        if (protocol.field(options, "textDocumentSync")) |v| {
            if (v == .integer) {
                caps.sync = try syncKind(v);
                caps.open_close = caps.sync != .none;
            } else if (v == .object) {
                caps.open_close = try optionalBool(v, "openClose");
                caps.will_save = try optionalBool(v, "willSave");
                caps.will_save_wait_until = try optionalBool(v, "willSaveWaitUntil");
                if (protocol.field(v, "change")) |change_kind| caps.sync = try syncKind(change_kind);
                if (protocol.field(v, "save")) |save_option| switch (save_option) {
                    .bool => caps.save = save_option.bool,
                    .object => {
                        caps.save = true;
                        caps.save_include_text = try optionalBool(save_option, "includeText");
                    },
                    else => return error.InvalidCapabilities,
                };
            } else return error.InvalidCapabilities;
        }
        if (protocol.field(options, "workspace")) |workspace| if (protocol.field(workspace, "workspaceFolders")) |folders| {
            caps.workspace_folders = try optionalBool(folders, "supported");
        };
        self.capability_storage = try protocol.parseMessage(self.allocator, bytes);
        caps.options = self.capability_storage.?.value;
        self.capabilities = caps;
    }

    fn serverRequest(self: *Client, event: *Event) !void {
        const value = event.value();
        const id = try protocol.responseId(value);
        if (id == .string and id.string.len > max_name_bytes) return error.InvalidId;
        for (self.incoming) |slot| if (slot) |p| if (idsEqual(p.id, id)) return error.DuplicateServerRequest;
        if (self.state != .ready and self.state != .initializing) {
            try self.sendError(id, -32002, "Session is stopping");
            return;
        }
        const method = event.method;
        const params = protocol.field(value, "params") orelse @as(Value, .null);
        if (std.mem.eql(u8, method, "workspace/configuration")) {
            const items = protocol.field(params, "items") orelse {
                try self.sendError(id, -32602, "Expected items");
                return;
            };
            if (items != .array or items.array.items.len > 256) {
                try self.sendError(id, -32602, "Too many configuration items");
                return;
            }
            var results: [256]Value = @splat(.null);
            try self.sendResponse(id, results[0..items.array.items.len]);
        } else if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
            try self.sendResponse(id, .{.{ .uri = self.root_uri, .name = self.root_uri }});
        } else if (std.mem.eql(u8, method, "window/workDoneProgress/create")) {
            const token = protocol.field(params, "token") orelse @as(Value, .null);
            if (token != .integer and token != .string) {
                try self.sendError(id, -32602, "Expected progress token");
                return;
            }
            try self.sendResponse(id, null);
        } else if (self.state == .ready and (self.surface_server_requests or reviewMethod(method))) {
            var target: ?*?Incoming = null;
            for (&self.incoming) |*slot| if (slot.* == null) {
                target = slot;
                break;
            };
            const slot = target orelse {
                try self.sendError(id, -32000, "Client request limit");
                return;
            };
            const token = try identity();
            const owned_id: protocol.Id = switch (id) {
                .integer => id,
                .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
            };
            slot.* = .{ .id = owned_id, .token = token, .deadline = self.after(self.request_timeout_ms) };
            event.kind = .server_request;
            event.token = token;
            try self.enqueue(event);
        } else try self.sendError(id, -32601, "Method not supported by client");
    }

    fn diagnosticsEvent(self: *Client, event: *Event) !void {
        const params = protocol.field(event.value(), "params") orelse return error.InvalidDiagnostics;
        const uri = protocol.string(protocol.field(params, "uri") orelse .null) orelse return error.InvalidDiagnostics;
        const diagnostics = protocol.field(params, "diagnostics") orelse return error.InvalidDiagnostics;
        if (diagnostics != .array) return error.InvalidDiagnostics;
        const d = self.document(uri) orelse return;
        const version_value = protocol.field(params, "version") orelse @as(Value, .null);
        if (version_value != .null) {
            const version = protocol.integer(version_value) orelse return error.InvalidDiagnostics;
            if (version != d.version) return;
            event.version = d.version;
            event.verified = true;
        } else if (!self.surface_unversioned) return;
        event.kind = .diagnostics;
        event.context = self.stamp(d.*);
        try self.enqueue(event);
    }

    fn enqueue(self: *Client, event: *Event) !void {
        const cost = event.charge + if (event.owned_method) |m| m.len else @as(usize, 0);
        if (self.event_count == max_events or cost > max_event_bytes - self.event_bytes) return error.EventLimit;
        event.charge = cost;
        self.events[(self.event_head + self.event_count) % max_events] = event.*;
        self.event_count += 1;
        self.event_bytes += cost;
        event.message = null;
        event.owned_method = null;
    }
    fn sendBody(self: *Client, body: []const u8) !void {
        const frame = protocol.encodeFrame(self.allocator, body) catch |err| {
            self.fail(err);
            return err;
        };
        defer self.allocator.free(frame);
        self.pipe.send(frame) catch |err| {
            self.fail(err);
            return err;
        };
    }
    fn sendNotification(self: *Client, method: []const u8, params: anytype) !void {
        const body = try protocol.encodeNotification(self.allocator, method, params);
        defer self.allocator.free(body);
        try self.sendBody(body);
    }
    fn sendResponse(self: *Client, id: protocol.Id, result: anytype) !void {
        const body = try protocol.encodeResponse(self.allocator, id, result);
        defer self.allocator.free(body);
        try self.sendBody(body);
    }
    fn sendError(self: *Client, id: protocol.Id, code: i64, message: []const u8) !void {
        const body = try protocol.encodeErrorResponse(self.allocator, id, code, message, null);
        defer self.allocator.free(body);
        try self.sendBody(body);
    }
    fn fail(self: *Client, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.state = .crashed;
        self.clearRequests();
        self.pipe.stop();
    }
    fn requireReady(self: *Client) !void {
        if (self.state != .ready) return error.NotReady;
    }
    fn after(self: *const Client, delta: u32) u64 {
        return (self.now orelse 0) +| delta;
    }
    fn allocateId(self: *Client) !i64 {
        if (self.next_id == std.math.maxInt(i64)) return error.IdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
    fn incomingSlot(self: *Client, token: u64) ?*?Incoming {
        for (&self.incoming) |*slot| if (slot.*) |p| {
            if (p.token == token) return slot;
        };
        return null;
    }
    fn freeIncoming(self: *Client, slot: *?Incoming) void {
        if (slot.*) |p| if (p.id == .string) self.allocator.free(p.id.string);
        slot.* = null;
    }
    fn clearRequests(self: *Client) void {
        for (&self.pending) |*slot| {
            if (slot.*) |p| self.allocator.free(p.method);
            slot.* = null;
        }
        for (&self.incoming) |*slot| self.freeIncoming(slot);
    }
    fn document(self: *Client, uri: []const u8) ?*Document {
        for (&self.documents) |*slot| if (slot.*) |*d| {
            if (d.open and std.mem.eql(u8, d.uri, uri)) return d;
        };
        return null;
    }
    fn stamp(self: *const Client, d: Document) Context {
        return .{ .session = self.session, .doc_id = d.id, .revision = d.version, .generation = d.generation };
    }
    fn resolveContext(self: *Client, ctx: Context) !Context {
        if (ctx.session != null and ctx.session != self.session) return error.StaleContext;
        if (ctx.doc_id) |id| {
            for (self.documents) |slot| if (slot) |d| {
                if (d.open and d.id == id) {
                    if ((ctx.revision != null and ctx.revision != d.version) or (ctx.generation != null and ctx.generation != d.generation)) return error.StaleContext;
                    return self.stamp(d);
                }
            };
            return error.DocumentNotOpen;
        }
        if (ctx.revision != null or ctx.generation != null) return error.InvalidContext;
        return .{ .session = self.session };
    }
    fn cancelDocument(self: *Client, id: u64) !void {
        for (self.pending) |slot| if (slot) |p| {
            if (p.context.doc_id == id) try self.cancel(p.id);
        };
    }
    fn validateUri(self: *Client, uri: []const u8) !void {
        if (uri.len > max_uri_bytes) return error.InvalidUri;
        const path = try uri_util.toPath(self.allocator, uri);
        defer self.allocator.free(path);
        const canonical = try uri_util.fromPath(self.allocator, path);
        defer self.allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, uri)) return error.NonCanonicalUri;
    }
};

fn validText(text: []const u8) !void {
    if (text.len > max_document_bytes) return error.DocumentLimit;
    try validateValue(.{ .string = text });
}

// protocol's encoders check serialized bytes after allocation. Preflight the
// caller's DOM before invoking them, bounding allocation/recursion even for a
// hand-built cyclic Value, excessive strings, or number_string injection.
fn validateValue(value: Value) !void {
    var budget: usize = protocol.max_message_bytes - 64 * 1024;
    try measureValue(value, &budget, 0);
}
fn charge(budget: *usize, bytes: usize) !void {
    if (bytes > budget.*) return error.MessageTooLarge;
    budget.* -= bytes;
}
fn measureString(text: []const u8, budget: *usize) !void {
    try charge(budget, text.len);
    try charge(budget, 2);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (text) |ch| {
        if (ch < 0x20) try charge(budget, 5) else if (ch == '"' or ch == '\\') try charge(budget, 1);
    }
}
fn measureValue(value: Value, budget: *usize, depth: usize) anyerror!void {
    if (depth >= protocol.max_json_depth - 4) return error.JsonTooDeep;
    try charge(budget, 1); // Delimiter, including the final item (conservative).
    switch (value) {
        .null, .bool => try charge(budget, 5),
        .integer => try charge(budget, 21),
        .float => |v| {
            if (!std.math.isFinite(v)) return error.InvalidJson;
            try charge(budget, 32);
        },
        .number_string => |text| {
            try charge(budget, text.len);
            if (!validNumber(text)) return error.InvalidJson;
        },
        .string => |text| try measureString(text, budget),
        .array => |array| {
            try charge(budget, 2);
            for (array.items) |item| try measureValue(item, budget, depth + 1);
        },
        .object => |object| {
            try charge(budget, 2);
            var it = object.iterator();
            while (it.next()) |entry| {
                try measureString(entry.key_ptr.*, budget);
                try charge(budget, 1);
                try measureValue(entry.value_ptr.*, budget, depth + 1);
            }
        },
    }
}
fn validNumber(text: []const u8) bool {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;
    if (i == text.len) return false;
    if (text[i] == '0') i += 1 else {
        if (text[i] < '1' or text[i] > '9') return false;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == start) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == start) return false;
    }
    return i == text.len;
}
fn validMethod(method: []const u8) !void {
    if (method.len == 0 or method.len > max_name_bytes or !std.unicode.utf8ValidateSlice(method)) return error.InvalidMethod;
}
fn reserved(method: []const u8) bool {
    for ([_][]const u8{ "initialize", "initialized", "shutdown", "exit", "$/cancelRequest", "textDocument/didOpen", "textDocument/didChange", "textDocument/didSave", "textDocument/didClose" }) |m| if (std.mem.eql(u8, method, m)) return true;
    return false;
}
fn reviewMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "workspace/applyEdit") or std.mem.eql(u8, method, "workspace/executeCommand") or std.mem.eql(u8, method, "window/showDocument");
}
fn idsEqual(a: protocol.Id, b: protocol.Id) bool {
    return switch (a) {
        .integer => |n| b == .integer and n == b.integer,
        .string => |s| b == .string and std.mem.eql(u8, s, b.string),
    };
}
fn eqString(value: ?Value, text: []const u8) bool {
    return if (value) |v| if (protocol.string(v)) |s| std.mem.eql(u8, s, text) else false else false;
}
fn optionalBool(object: Value, key: []const u8) !bool {
    const v = protocol.field(object, key) orelse return false;
    if (v != .bool) return error.InvalidCapabilities;
    return v.bool;
}
fn syncKind(v: Value) !Sync {
    return switch (protocol.integer(v) orelse return error.InvalidCapabilities) {
        0 => .none,
        1 => .full,
        2 => .incremental,
        else => error.InvalidCapabilities,
    };
}
fn mergeCapabilities(allocator: Allocator, into: *Value, extra: Value) anyerror!void {
    if (into.* != .object or extra != .object) return error.CapabilityConflict;
    var it = extra.object.iterator();
    while (it.next()) |entry| {
        if (into.object.getPtr(entry.key_ptr.*)) |existing| {
            try mergeCapabilities(allocator, existing, entry.value_ptr.*);
        } else try into.object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
}
fn initializeBody(allocator: Allocator, config: Config, root: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try protocol.parseMessage(a,
        \\{"general":{"positionEncodings":["utf-8","utf-16","utf-32"]},"workspace":{"workspaceFolders":true,"configuration":true},"textDocument":{"synchronization":{"dynamicRegistration":false,"didSave":true},"publishDiagnostics":{"versionSupport":true}}}
    );
    var caps = base.value;
    if (config.additional_capabilities) |bytes| {
        try protocol.boundedJson(bytes, max_config_bytes, protocol.max_json_depth);
        const extra = try protocol.parseMessage(a, bytes);
        try mergeCapabilities(a, &caps, extra.value);
    }
    var options: Value = .null;
    if (config.initialization_options) |bytes| {
        try protocol.boundedJson(bytes, max_config_bytes, protocol.max_json_depth);
        options = (try protocol.parseMessage(a, bytes)).value;
    }
    return protocol.encodeRequest(allocator, .{ .integer = 1 }, "initialize", .{
        .processId = @as(?u32, null),
        .clientInfo = .{ .name = "coral" },
        .rootUri = root,
        .workspaceFolders = .{.{ .uri = root, .name = root }},
        .capabilities = caps,
        .initializationOptions = options,
    });
}
