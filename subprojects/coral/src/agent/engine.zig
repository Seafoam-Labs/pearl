//! Coral agent engine: the public backend API for the UI controller.
//!
//! The engine is GTK-free. The host supplies file/terminal/diagnostics
//! callbacks (see host.zig). The engine owns provider streaming, ACP/MCP
//! clients, tool policy, multi-file review with checkpoints, cancellation,
//! worktree binding, and atomic thread persistence.
//!
//! Threading: each `send` runs on a worker thread. A single engine mutex
//! guards shared state; host callbacks are invoked WITHOUT the mutex held.
//! Permission and blocking-review waits use per-thread condition variables.
//! The UI drains events with `pollEvent` and waits for completion with
//! `waitIdle`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const host_mod = @import("host.zig");
const cancel = @import("cancel.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");
const policy_mod = @import("policy.zig");
const review = @import("review.zig");
const thread_mod = @import("thread.zig");
const store_mod = @import("store.zig");
const provider = @import("provider.zig");
const rpc = @import("rpc.zig");
const acp = @import("acp.zig");
const mcp = @import("mcp.zig");
const skills_mod = @import("skills.zig");
const tools = @import("tools.zig");

pub const Host = host_mod.Host;
pub const State = thread_mod.State;
pub const Token = cancel.Token;

pub const WorktreeInput = struct {
    root: []const u8,
    branch: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const AcpConfig = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
};

pub const McpConfig = struct {
    name: []const u8,
    argv: []const []const u8,
};

pub const ProviderSelection = union(enum) {
    fake: provider.FakeConfig,
    openai: provider.OpenAiConfig,
    acp: AcpConfig,

    pub fn name(self: ProviderSelection) []const u8 {
        return switch (self) {
            .fake => "fake",
            .openai => "openai",
            .acp => "acp",
        };
    }
};

pub const AttachmentInput = struct {
    kind: context.Kind,
    label: []const u8,
    content: []const u8,
};

pub const NewThread = struct {
    title: []const u8 = "",
    provider: ProviderSelection = .{ .fake = .{} },
    worktree: ?WorktreeInput = null,
    mcp_servers: []const McpConfig = &.{},
    skills_dirs: []const []const u8 = &.{},
};

pub const Options = struct {
    state_dir: ?[]const u8 = null,
    env: auth.Env = .{},
    auth_path: ?[]const u8 = null,
    budget: context.Budget = .{},
};

pub const PermissionResponse = enum { allow, deny, cancel };

pub const ProbeResult = struct {
    ok: bool,
    detail: []const u8,
};

pub const Event = union(enum) {
    state: struct { thread_id: []const u8, state: State },
    delta: struct { thread_id: []const u8, text: []const u8 },
    message_done: struct { thread_id: []const u8 },
    tool_started: struct { thread_id: []const u8, tool: []const u8 },
    tool_finished: struct { thread_id: []const u8, tool: []const u8, ok: bool, output: []const u8 },
    permission_request: struct { thread_id: []const u8, request_id: []const u8, tool: []const u8, summary: []const u8 },
    review_proposed: struct { thread_id: []const u8, review_id: []const u8, title: []const u8, file_count: usize },
    review_resolved: struct { thread_id: []const u8, review_id: []const u8, state: review.State },
    acp_update: struct { thread_id: []const u8, json: []const u8 },
    cancelled: struct { thread_id: []const u8 },
    failed: struct { thread_id: []const u8, message: []const u8 },
    disclosure: struct { thread_id: []const u8, text: []const u8 },
};

const PendingPermission = struct {
    id: []u8,
    tool: []u8,
    summary: []u8,
    decision: ?PermissionResponse = null,
};

const ReviewResolution = enum { accept, reject };

const PendingReview = struct {
    review_id: []u8,
    resolution: ?ReviewResolution = null,
};

const McpToolRef = struct {
    server: usize,
    tool: mcp.Tool,
};

const AcpContext = struct {
    engine: *Engine,
    slot: *ThreadSlot,
};

const ThreadSlot = struct {
    thread: thread_mod.Thread,
    selection: ProviderSelection,
    provider_instance: ?provider.Provider = null,
    acp_client: ?*acp.AcpClient = null,
    acp_context: ?*AcpContext = null,
    acp_session: ?[]u8 = null,
    acp_terminals: std.StringHashMap(host_mod.TerminalHandle),
    mcp_clients: std.ArrayList(*mcp.McpClient) = .empty,
    mcp_tools: std.ArrayList(McpToolRef) = .empty,
    skills: ?skills_mod.Skills = null,
    token: Token = .{},
    worker: ?std.Thread = null,
    cond: Io.Condition = .init,
    pending_permission: ?PendingPermission = null,
    pending_review: ?PendingReview = null,
    terminals: std.ArrayList(host_mod.TerminalHandle) = .empty,
    assistant_buf: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(provider.ToolCall) = .empty,
    owns_openai: bool = false,
    owns_acp_argv: bool = false,

    fn deinit(self: *ThreadSlot, allocator: Allocator) void {
        // Shut down protocol clients first: their dispatcher callbacks still
        // reference thread/slot state until those threads are joined.
        if (self.acp_client) |c| c.deinit();
        for (self.mcp_clients.items) |c| c.deinit();
        self.thread.deinit();
        freeSelection(allocator, self.selection, self.owns_openai, self.owns_acp_argv);
        if (self.provider_instance) |p| p.deinit(allocator);
        if (self.acp_context) |c| allocator.destroy(c);
        if (self.acp_session) |s| allocator.free(s);
        var term_it = self.acp_terminals.keyIterator();
        while (term_it.next()) |k| allocator.free(k.*);
        self.acp_terminals.deinit();
        self.mcp_clients.deinit(allocator);
        for (self.mcp_tools.items) |*t| t.tool.deinit(allocator);
        self.mcp_tools.deinit(allocator);
        if (self.skills) |*s| s.deinit();
        if (self.pending_permission) |*p| {
            allocator.free(p.id);
            allocator.free(p.tool);
            allocator.free(p.summary);
        }
        if (self.pending_review) |*r| allocator.free(r.review_id);
        self.terminals.deinit(allocator);
        self.assistant_buf.deinit(allocator);
        for (self.tool_calls.items) |*call| {
            allocator.free(call.id);
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        self.tool_calls.deinit(allocator);
    }
};

fn freeSelection(allocator: Allocator, sel: ProviderSelection, owns_openai: bool, owns_acp: bool) void {
    switch (sel) {
        .openai => |cfg| {
            if (owns_openai) {
                allocator.free(cfg.base_url);
                if (cfg.api_key) |k| allocator.free(k);
                allocator.free(cfg.api_key_env);
                allocator.free(cfg.model);
            }
        },
        .acp => |cfg| {
            if (owns_acp) {
                for (cfg.argv) |s| allocator.free(s);
                allocator.free(cfg.argv);
                if (cfg.cwd) |c| allocator.free(c);
            }
        },
        .fake => {},
    }
}

pub const Engine = struct {
    allocator: Allocator,
    threaded: Io.Threaded,
    io: Io,
    host: Host,
    store: store_mod.Store,
    registry: provider.Registry,
    policy: policy_mod.Policy,
    auth_config: auth.AuthConfig,
    env: auth.Env,
    budget: context.Budget,

    mutex: Io.Mutex = .init,
    slots: std.StringHashMap(*ThreadSlot),
    events: std.ArrayList(Event) = .empty,
    proposals: std.ArrayList(*review.Proposal) = .empty,
    checkpoints: std.ArrayList(*review.Checkpoint) = .empty,
    id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    default_selection: ProviderSelection = .{ .fake = .{} },

    pub fn init(allocator: Allocator, host: Host, options: Options) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = Io.Threaded.init(allocator, .{}),
            .io = undefined,
            .host = host,
            .store = undefined,
            .registry = try provider.Registry.withDefaults(allocator),
            .policy = try policy_mod.Policy.withDefaults(allocator),
            .auth_config = auth.AuthConfig.init(allocator),
            .env = options.env,
            .budget = options.budget,
            .slots = std.StringHashMap(*ThreadSlot).init(allocator),
        };
        self.io = self.threaded.io();
        errdefer {
            self.registry.deinit();
            self.policy.deinit();
            self.auth_config.deinit();
            self.threaded.deinit();
        }

        const state_dir = options.state_dir orelse try store_mod.defaultStateDir(allocator, options.env);
        defer if (options.state_dir == null) allocator.free(state_dir);
        self.store = try store_mod.Store.init(allocator, self.io, state_dir);
        errdefer self.store.deinit();

        if (options.auth_path) |path| {
            self.auth_config.deinit();
            self.auth_config = try auth.AuthConfig.load(allocator, self.io, path);
        }

        try self.restore();
        return self;
    }

    pub fn deinit(self: *Engine) void {
        // Wake workers blocked on permission/review decisions so they finish
        // before we join them; a pending review would otherwise keep the ACP
        // dispatcher (and connection shutdown) blocked forever.
        self.mutex.lockUncancelable(self.io);
        var wit = self.slots.valueIterator();
        while (wit.next()) |slot| {
            slot.*.token.cancel();
            slot.*.cond.broadcast(self.io);
        }
        self.mutex.unlock(self.io);
        // Join outstanding workers.
        var it = self.slots.valueIterator();
        while (it.next()) |slot| {
            if (slot.*.worker) |w| w.join();
        }
        it = self.slots.valueIterator();
        while (it.next()) |slot| {
            slot.*.deinit(self.allocator);
            self.allocator.destroy(slot.*);
        }
        var kit = self.slots.keyIterator();
        while (kit.next()) |key| self.allocator.free(key.*);
        self.slots.deinit();
        for (self.events.items) |*e| self.freeEvent(e.*);
        self.events.deinit(self.allocator);
        for (self.proposals.items) |p| {
            p.deinit(self.allocator);
            self.allocator.destroy(p);
        }
        self.proposals.deinit(self.allocator);
        for (self.checkpoints.items) |c| {
            c.deinit(self.allocator);
            self.allocator.destroy(c);
        }
        self.checkpoints.deinit(self.allocator);
        self.store.deinit();
        self.registry.deinit();
        self.policy.deinit();
        self.auth_config.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    // -- public API ---------------------------------------------------------

    pub fn newThread(self: *Engine, opts: NewThread) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const id = try self.makeId("t");
        errdefer self.allocator.free(id);
        const slot = try self.createSlot(id, opts.title, opts.provider, opts.worktree);
        errdefer {
            slot.deinit(self.allocator);
            self.allocator.destroy(slot);
        }
        const key = try self.allocator.dupe(u8, id);
        self.slots.put(key, slot) catch |err| {
            self.allocator.free(key);
            return err;
        };

        // MCP servers and skills are set up outside the lock below.
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        try self.setupMcp(slot, opts.mcp_servers);
        try self.setupSkills(slot, opts.skills_dirs);
        self.persistSlot(slot);
        return id;
    }

    pub fn send(self: *Engine, thread_id: []const u8, text: []const u8, attachments: []const AttachmentInput) !void {
        self.mutex.lockUncancelable(self.io);
        const slot = self.slots.get(thread_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownThread;
        };
        if (slot.thread.state == .closed) {
            self.mutex.unlock(self.io);
            return error.ThreadClosed;
        }
        if (slot.thread.state == .streaming or slot.thread.state == .awaiting_permission or slot.thread.state == .awaiting_review) {
            self.mutex.unlock(self.io);
            return error.Busy;
        }
        if (slot.worker) |w| {
            slot.worker = null;
            self.mutex.unlock(self.io);
            w.join();
            self.mutex.lockUncancelable(self.io);
        }

        // Prepare attachments within budget.
        var remaining = self.budget.total;
        for (attachments) |input| {
            const cap = @min(self.budget.capFor(input.kind), remaining);
            const att = try context.prepare(self.allocator, input.kind, input.label, input.content, cap);
            try slot.thread.attachments.append(self.allocator, att);
            remaining -|= att.content.len;
        }
        const disclosure = try context.disclosure(self.allocator, slot.thread.attachments.items);
        try self.pushEvent(.{ .disclosure = .{ .thread_id = try self.allocator.dupe(u8, thread_id), .text = disclosure } });

        // Append the user message (context block + text). The context block is
        // only injected when there are attachments; an empty preamble would
        // pollute the prompt (ACP agents receive it verbatim as the prompt).
        const user_content = if (slot.thread.attachments.items.len > 0) blk: {
            const rendered = try context.renderPrompt(self.allocator, slot.thread.attachments.items);
            defer self.allocator.free(rendered);
            break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ rendered, text });
        } else try self.allocator.dupe(u8, text);
        defer self.allocator.free(user_content);
        try slot.thread.appendMessage(.user, user_content);

        slot.token.reset();
        slot.assistant_buf.clearRetainingCapacity();
        for (slot.tool_calls.items) |*call| {
            self.allocator.free(call.id);
            self.allocator.free(call.name);
            self.allocator.free(call.arguments_json);
        }
        slot.tool_calls.clearRetainingCapacity();
        try slot.thread.setState(.streaming);
        try self.pushEvent(.{ .state = .{ .thread_id = try self.allocator.dupe(u8, thread_id), .state = .streaming } });
        self.persistSlot(slot);

        const worker = try std.Thread.spawn(.{ .allocator = self.allocator }, workerMain, .{ self, slot });
        slot.worker = worker;
        self.mutex.unlock(self.io);
    }

    pub fn cancel(self: *Engine, thread_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slots.get(thread_id) orelse return;
        slot.token.cancel();
        if (slot.thread.state == .streaming or slot.thread.state == .awaiting_permission or slot.thread.state == .awaiting_review) {
            slot.thread.setState(.cancelling) catch {};
        }
        if (slot.acp_client) |c| {
            if (slot.acp_session) |sid| c.cancel(sid);
        }
        for (slot.terminals.items) |handle| {
            if (self.host.terminalKill) |kill| kill(self.host.ctx, handle);
        }
        slot.cond.broadcast(self.io);
    }

    pub fn respondPermission(self: *Engine, thread_id: []const u8, request_id: []const u8, decision: PermissionResponse) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slots.get(thread_id) orelse return error.UnknownThread;
        const pending = &(slot.pending_permission orelse return error.NoPendingPermission);
        if (!std.mem.eql(u8, pending.id, request_id)) return error.UnknownRequest;
        pending.decision = decision;
        if (decision == .cancel) slot.token.cancel();
        slot.cond.broadcast(self.io);
    }

    pub fn acceptReview(self: *Engine, thread_id: []const u8, review_id: []const u8) !void {
        try self.resolveReview(thread_id, review_id, true);
    }

    pub fn rejectReview(self: *Engine, thread_id: []const u8, review_id: []const u8) !void {
        try self.resolveReview(thread_id, review_id, false);
    }

    pub fn setProvider(self: *Engine, thread_id: ?[]const u8, selection: ProviderSelection) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (thread_id) |tid| {
            const slot = self.slots.get(tid) orelse return error.UnknownThread;
            if (slot.thread.state == .streaming) return error.Busy;
            freeSelection(self.allocator, slot.selection, slot.owns_openai, slot.owns_acp_argv);
            if (slot.provider_instance) |p| {
                p.deinit(self.allocator);
                slot.provider_instance = null;
            }
            const owned = try self.ownSelection(selection);
            slot.selection = owned.selection;
            slot.owns_openai = owned.owns_openai;
            slot.owns_acp_argv = owned.owns_acp;
            const name_copy = try self.allocator.dupe(u8, selection.name());
            self.allocator.free(slot.thread.provider_name);
            slot.thread.provider_name = name_copy;
            self.persistSlot(slot);
        } else {
            self.default_selection = selection;
        }
    }

    pub fn probe(self: *Engine, name: []const u8) !ProbeResult {
        if (std.mem.eql(u8, name, "fake")) return .{ .ok = true, .detail = "deterministic fake provider" };
        if (std.mem.eql(u8, name, "openai")) {
            const base = self.auth_config.baseUrl("openai") orelse "";
            if (base.len == 0) return .{ .ok = false, .detail = "missing base_url" };
            _ = std.Uri.parse(base) catch return .{ .ok = false, .detail = "invalid base_url" };
            const key = try self.auth_config.resolveApiKey(self.allocator, "openai", self.env);
            if (key) |k| {
                self.allocator.free(k);
                return .{ .ok = true, .detail = "configured" };
            }
            if (self.env.lookup("OPENAI_API_KEY") != null) return .{ .ok = true, .detail = "key from env" };
            return .{ .ok = false, .detail = "missing api key" };
        }
        if (!self.registry.contains(name)) return .{ .ok = false, .detail = "unknown provider" };
        return .{ .ok = true, .detail = "registered" };
    }

    pub fn pollEvent(self: *Engine) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn freeEvent(self: *Engine, event: Event) void {
        const a = self.allocator;
        switch (event) {
            .state => |v| a.free(v.thread_id),
            .delta => |v| {
                a.free(v.thread_id);
                a.free(v.text);
            },
            .message_done => |v| a.free(v.thread_id),
            .tool_started => |v| {
                a.free(v.thread_id);
                a.free(v.tool);
            },
            .tool_finished => |v| {
                a.free(v.thread_id);
                a.free(v.tool);
                a.free(v.output);
            },
            .permission_request => |v| {
                a.free(v.thread_id);
                a.free(v.request_id);
                a.free(v.tool);
                a.free(v.summary);
            },
            .review_proposed => |v| {
                a.free(v.thread_id);
                a.free(v.review_id);
                a.free(v.title);
            },
            .review_resolved => |v| {
                a.free(v.thread_id);
                a.free(v.review_id);
            },
            .acp_update => |v| {
                a.free(v.thread_id);
                a.free(v.json);
            },
            .cancelled => |v| a.free(v.thread_id),
            .failed => |v| {
                a.free(v.thread_id);
                a.free(v.message);
            },
            .disclosure => |v| {
                a.free(v.thread_id);
                a.free(v.text);
            },
        }
    }

    /// Block until the thread's worker has finished.
    pub fn waitIdle(self: *Engine, thread_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        const slot = self.slots.get(thread_id) orelse {
            self.mutex.unlock(self.io);
            return;
        };
        const worker = slot.worker;
        slot.worker = null;
        self.mutex.unlock(self.io);
        if (worker) |w| w.join();
    }

    pub fn threadState(self: *Engine, thread_id: []const u8) ?State {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = self.slots.get(thread_id) orelse return null;
        return slot.thread.state;
    }

    pub fn searchSkills(self: *Engine, thread_id: []const u8, query: []const u8) ![]skills_mod.Match {
        self.mutex.lockUncancelable(self.io);
        const slot = self.slots.get(thread_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownThread;
        };
        const skills = slot.skills orelse {
            self.mutex.unlock(self.io);
            return &.{};
        };
        self.mutex.unlock(self.io);
        return skills.search(self.allocator, query);
    }

    /// Revert a previously applied checkpoint (restore original contents).
    pub fn revertCheckpoint(self: *Engine, checkpoint_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        var found: ?*review.Checkpoint = null;
        for (self.checkpoints.items) |c| {
            if (std.mem.eql(u8, c.id, checkpoint_id)) found = c;
        }
        const checkpoint = found orelse {
            self.mutex.unlock(self.io);
            return error.UnknownCheckpoint;
        };
        const files = try self.allocator.alloc(review.Original, checkpoint.files.len);
        for (checkpoint.files, 0..) |f, i| {
            files[i] = .{
                .path = try self.allocator.dupe(u8, f.path),
                .content = if (f.content) |c| try self.allocator.dupe(u8, c) else null,
            };
        }
        self.mutex.unlock(self.io);
        defer {
            for (files) |*f| f.deinit(self.allocator);
            self.allocator.free(files);
        }
        const write = self.host.writeFile orelse return error.Unsupported;
        for (files) |f| {
            if (f.content) |c| {
                try write(self.host.ctx, f.path, c);
            }
        }
    }

    // -- internals ----------------------------------------------------------

    fn makeId(self: *Engine, prefix: []const u8) ![]u8 {
        const seq = self.id_counter.fetchAdd(1, .monotonic);
        const ms = @divTrunc(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms);
        return std.fmt.allocPrint(self.allocator, "{s}-{d}-{d}", .{ prefix, ms, seq });
    }

    const OwnedSelection = struct { selection: ProviderSelection, owns_openai: bool, owns_acp: bool };

    fn ownSelection(self: *Engine, sel: ProviderSelection) !OwnedSelection {
        switch (sel) {
            .fake => return .{ .selection = sel, .owns_openai = false, .owns_acp = false },
            .openai => |cfg| {
                const copy: provider.OpenAiConfig = .{
                    .base_url = try self.allocator.dupe(u8, cfg.base_url),
                    .api_key = if (cfg.api_key) |k| try self.allocator.dupe(u8, k) else null,
                    .api_key_env = try self.allocator.dupe(u8, cfg.api_key_env),
                    .model = try self.allocator.dupe(u8, cfg.model),
                    .env = cfg.env,
                    .transport = cfg.transport,
                };
                return .{ .selection = .{ .openai = copy }, .owns_openai = true, .owns_acp = false };
            },
            .acp => |cfg| {
                const argv = try self.allocator.alloc([]const u8, cfg.argv.len);
                for (cfg.argv, 0..) |s, i| argv[i] = try self.allocator.dupe(u8, s);
                const copy: AcpConfig = .{
                    .argv = argv,
                    .cwd = if (cfg.cwd) |c| try self.allocator.dupe(u8, c) else null,
                };
                return .{ .selection = .{ .acp = copy }, .owns_openai = false, .owns_acp = true };
            },
        }
    }

    fn createSlot(self: *Engine, id: []const u8, title: []const u8, sel: ProviderSelection, worktree: ?WorktreeInput) !*ThreadSlot {
        const owned = try self.ownSelection(sel);
        const slot = try self.allocator.create(ThreadSlot);
        errdefer self.allocator.destroy(slot);
        const now: i64 = @intCast(@divTrunc(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
        slot.* = .{
            .thread = .{
                .allocator = self.allocator,
                .id = try self.allocator.dupe(u8, id),
                .title = try self.allocator.dupe(u8, title),
                .provider_name = try self.allocator.dupe(u8, sel.name()),
                .model = try self.allocator.dupe(u8, switch (sel) {
                    .openai => |c| c.model,
                    else => "",
                }),
                .created_ms = now,
                .updated_ms = now,
            },
            .selection = owned.selection,
            .acp_terminals = std.StringHashMap(host_mod.TerminalHandle).init(self.allocator),
            .owns_openai = owned.owns_openai,
            .owns_acp_argv = owned.owns_acp,
        };
        if (worktree) |wt| {
            slot.thread.worktree = .{
                .root = try self.allocator.dupe(u8, wt.root),
                .branch = if (wt.branch) |b| try self.allocator.dupe(u8, b) else null,
                .id = if (wt.id) |i| try self.allocator.dupe(u8, i) else null,
            };
        }
        return slot;
    }

    fn setupMcp(self: *Engine, slot: *ThreadSlot, servers: []const McpConfig) !void {
        for (servers) |server| {
            const client = try mcp.McpClient.start(self.allocator, self.io, server.argv, .{});
            try slot.mcp_clients.append(self.allocator, client);
            client.initialize(5000) catch |err| {
                self.log(.warn, "MCP initialize failed");
                return err;
            };
            const tools_list = try client.listTools(self.allocator, 5000);
            const server_index = slot.mcp_clients.items.len - 1;
            for (tools_list) |tool| {
                try slot.mcp_tools.append(self.allocator, .{ .server = server_index, .tool = tool });
            }
            self.allocator.free(tools_list);
        }
    }

    fn setupSkills(self: *Engine, slot: *ThreadSlot, dirs: []const []const u8) !void {
        if (dirs.len == 0) return;
        var skills = skills_mod.Skills.init(self.allocator);
        for (dirs) |dir| try skills.loadDir(self.io, dir);
        slot.skills = skills;
    }

    fn restore(self: *Engine) !void {
        const loaded = try self.store.loadAll(self.allocator);
        defer {
            for (loaded) |t| store_mod.freeThread(self.allocator, t);
            self.allocator.free(loaded);
        }
        for (loaded) |persisted| {
            var sel: ProviderSelection = .{ .fake = .{} };
            if (std.mem.eql(u8, persisted.provider, "acp")) {
                if (persisted.acp_argv) |argv| {
                    sel = .{ .acp = .{ .argv = argv } };
                }
            } else if (std.mem.eql(u8, persisted.provider, "openai")) {
                sel = .{ .openai = .{ .base_url = self.auth_config.baseUrl("openai") orelse "" } };
            }
            const wt: ?WorktreeInput = if (persisted.worktree_root) |root| .{
                .root = root,
                .branch = persisted.worktree_branch,
            } else null;
            const slot = try self.createSlot(persisted.id, persisted.title, sel, wt);
            // createSlot borrowed persisted.acp_argv; mark not-owned so we
            // don't double-free (loaded is freed by the defer above).
            slot.owns_acp_argv = false;
            for (persisted.messages) |m| {
                const role = std.meta.stringToEnum(provider.Role, m.role) orelse .user;
                try slot.thread.appendMessage(role, m.content);
            }
            slot.thread.state = normalizeState(persisted.state);
            slot.thread.created_ms = persisted.created_ms;
            slot.thread.updated_ms = persisted.updated_ms;
            const id_copy = try self.allocator.dupe(u8, persisted.id);
            try self.slots.put(id_copy, slot);
        }
    }

    fn normalizeState(label: []const u8) State {
        const s = std.meta.stringToEnum(State, label) orelse return .idle;
        return switch (s) {
            .streaming, .awaiting_permission, .awaiting_review, .cancelling => .idle,
            else => s,
        };
    }

    fn persistSlot(self: *Engine, slot: *ThreadSlot) void {
        const a = self.allocator;
        const msgs = a.alloc(store_mod.PersistedMessage, slot.thread.messages.items.len) catch return;
        defer a.free(msgs);
        for (slot.thread.messages.items, 0..) |m, i| {
            msgs[i] = .{ .role = @tagName(m.role), .content = m.content };
        }
        const acp_argv: ?[]const []const u8 = switch (slot.selection) {
            .acp => |cfg| cfg.argv,
            else => null,
        };
        const persisted: store_mod.PersistedThread = .{
            .id = slot.thread.id,
            .title = slot.thread.title,
            .provider = slot.thread.provider_name,
            .model = slot.thread.model,
            .state = slot.thread.state.label(),
            .worktree_root = if (slot.thread.worktree) |w| w.root else null,
            .worktree_branch = if (slot.thread.worktree) |w| w.branch else null,
            .acp_argv = acp_argv,
            .messages = msgs,
            .created_ms = slot.thread.created_ms,
            .updated_ms = slot.thread.updated_ms,
        };
        self.store.save(persisted) catch |err| self.log(.warn, @errorName(err));
    }

    fn log(self: *Engine, level: host_mod.LogLevel, message: []const u8) void {
        if (self.host.log) |f| f(self.host.ctx, level, message);
    }

    fn pushEvent(self: *Engine, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    fn emitMessageDone(self: *Engine, slot: *ThreadSlot) void {
        const tid = self.allocator.dupe(u8, slot.thread.id) catch return;
        self.pushEvent(.{ .message_done = .{ .thread_id = tid } }) catch self.allocator.free(tid);
    }

    fn emitState(self: *Engine, slot: *ThreadSlot) void {
        const tid = self.allocator.dupe(u8, slot.thread.id) catch return;
        self.pushEvent(.{ .state = .{ .thread_id = tid, .state = slot.thread.state } }) catch self.allocator.free(tid);
    }

    fn emitToolFinished(self: *Engine, slot: *ThreadSlot, tool: []const u8, ok: bool, output: []const u8) void {
        const tid = self.allocator.dupe(u8, slot.thread.id) catch return;
        const t = self.allocator.dupe(u8, tool) catch {
            self.allocator.free(tid);
            return;
        };
        const o = self.allocator.dupe(u8, output) catch {
            self.allocator.free(tid);
            self.allocator.free(t);
            return;
        };
        self.pushEvent(.{ .tool_finished = .{ .thread_id = tid, .tool = t, .ok = ok, .output = o } }) catch {
            self.allocator.free(tid);
            self.allocator.free(t);
            self.allocator.free(o);
        };
    }

    fn findProposal(self: *Engine, review_id: []const u8) ?*review.Proposal {
        for (self.proposals.items) |p| {
            if (std.mem.eql(u8, p.id, review_id)) return p;
        }
        return null;
    }

    fn resolveReview(self: *Engine, thread_id: []const u8, review_id: []const u8, accept: bool) !void {
        self.mutex.lockUncancelable(self.io);
        const slot = self.slots.get(thread_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownThread;
        };
        const proposal = self.findProposal(review_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownReview;
        };
        if (proposal.state != .pending) {
            self.mutex.unlock(self.io);
            return error.NotPending;
        }
        // Snapshot file data under the lock, then do host I/O unlocked.
        const files = try self.allocator.alloc(review.FileEdit, proposal.files.len);
        for (proposal.files, 0..) |f, i| {
            files[i] = .{
                .path = try self.allocator.dupe(u8, f.path),
                .base = f.base,
                .new_content = try self.allocator.dupe(u8, f.new_content),
            };
        }
        self.mutex.unlock(self.io);
        defer {
            for (files) |*f| f.deinit(self.allocator);
            self.allocator.free(files);
        }

        if (!accept) {
            self.mutex.lockUncancelable(self.io);
            proposal.state = .rejected;
            try self.pushEvent(.{ .review_resolved = .{
                .thread_id = try self.allocator.dupe(u8, thread_id),
                .review_id = try self.allocator.dupe(u8, review_id),
                .state = .rejected,
            } });
            self.resolveBlockingReview(slot, review_id, .reject);
            self.persistSlot(slot);
            self.mutex.unlock(self.io);
            return;
        }

        // Stale-revision refusal: read every file, compare base revisions.
        const read = self.host.readFile orelse return error.Unsupported;
        for (files) |f| {
            const current = read(self.host.ctx, self.allocator, f.path) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            defer if (current) |c| self.allocator.free(c);
            if (review.checkStale(current, f.base)) {
                self.mutex.lockUncancelable(self.io);
                proposal.state = .stale;
                try self.pushEvent(.{ .review_resolved = .{
                    .thread_id = try self.allocator.dupe(u8, thread_id),
                    .review_id = try self.allocator.dupe(u8, review_id),
                    .state = .stale,
                } });
                self.resolveBlockingReview(slot, review_id, .reject);
                self.mutex.unlock(self.io);
                return error.StaleRevision;
            }
        }

        // Snapshot originals for a checkpoint, then apply.
        const write = self.host.writeFile orelse return error.Unsupported;
        const originals = try self.allocator.alloc(review.Original, files.len);
        var originals_count: usize = 0;
        var transferred = false;
        defer {
            if (!transferred) {
                for (originals[0..originals_count]) |*o| o.deinit(self.allocator);
                self.allocator.free(originals);
            }
        }
        for (files) |f| {
            const current = read(self.host.ctx, self.allocator, f.path) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            originals[originals_count] = .{ .path = try self.allocator.dupe(u8, f.path), .content = current };
            originals_count += 1;
        }
        for (files) |f| {
            try write(self.host.ctx, f.path, f.new_content);
        }

        self.mutex.lockUncancelable(self.io);
        const checkpoint_id = try self.makeId("cp");
        const checkpoint = try self.allocator.create(review.Checkpoint);
        checkpoint.* = .{ .id = checkpoint_id, .files = originals };
        transferred = true; // ownership of the array and its elements moves to the checkpoint
        try self.checkpoints.append(self.allocator, checkpoint);
        proposal.state = .accepted;
        proposal.checkpoint_id = try self.allocator.dupe(u8, checkpoint_id);
        try self.pushEvent(.{ .review_resolved = .{
            .thread_id = try self.allocator.dupe(u8, thread_id),
            .review_id = try self.allocator.dupe(u8, review_id),
            .state = .accepted,
        } });
        self.resolveBlockingReview(slot, review_id, .accept);
        self.persistSlot(slot);
        self.mutex.unlock(self.io);
    }

    fn resolveBlockingReview(self: *Engine, slot: *ThreadSlot, review_id: []const u8, resolution: ReviewResolution) void {
        if (slot.pending_review) |*pr| {
            if (std.mem.eql(u8, pr.review_id, review_id)) {
                pr.resolution = resolution;
                slot.cond.broadcast(self.io);
            }
        }
    }

    fn createProposal(self: *Engine, slot: *ThreadSlot, title: []const u8, files: []review.FileEdit) !*review.Proposal {
        const id = try self.makeId("rev");
        const proposal = try self.allocator.create(review.Proposal);
        proposal.* = .{
            .id = id,
            .thread_id = try self.allocator.dupe(u8, slot.thread.id),
            .title = try self.allocator.dupe(u8, title),
            .files = files,
        };
        try self.proposals.append(self.allocator, proposal);
        try self.pushEvent(.{ .review_proposed = .{
            .thread_id = try self.allocator.dupe(u8, slot.thread.id),
            .review_id = try self.allocator.dupe(u8, id),
            .title = try self.allocator.dupe(u8, title),
            .file_count = files.len,
        } });
        return proposal;
    }

    // -- worker -------------------------------------------------------------

    fn workerMain(self: *Engine, slot: *ThreadSlot) void {
        switch (slot.selection) {
            .acp => self.acpWorker(slot),
            else => self.providerWorker(slot),
        }
    }

    const SinkContext = struct { engine: *Engine, slot: *ThreadSlot };

    fn sinkText(ctx: *anyopaque, delta: []const u8) anyerror!void {
        const sc: *SinkContext = @ptrCast(@alignCast(ctx));
        const self = sc.engine;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try sc.slot.assistant_buf.appendSlice(self.allocator, delta);
        try self.pushEvent(.{ .delta = .{
            .thread_id = try self.allocator.dupe(u8, sc.slot.thread.id),
            .text = try self.allocator.dupe(u8, delta),
        } });
    }

    fn sinkToolCall(ctx: *anyopaque, call: provider.ToolCall) anyerror!void {
        const sc: *SinkContext = @ptrCast(@alignCast(ctx));
        const self = sc.engine;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try sc.slot.tool_calls.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, call.id),
            .name = try self.allocator.dupe(u8, call.name),
            .arguments_json = try self.allocator.dupe(u8, call.arguments_json),
        });
    }

    fn sinkDone(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn providerWorker(self: *Engine, slot: *ThreadSlot) void {
        var sink_ctx = SinkContext{ .engine = self, .slot = slot };
        const sink: provider.Sink = .{ .ctx = &sink_ctx, .text = sinkText, .toolCall = sinkToolCall, .done = sinkDone };

        self.mutex.lockUncancelable(self.io);
        // Ensure a provider instance.
        if (slot.provider_instance == null) {
            const config: provider.Config = switch (slot.selection) {
                .fake => |c| .{ .fake = c },
                .openai => |c| .{ .openai = c },
                .acp => unreachable,
            };
            slot.provider_instance = self.registry.create(slot.thread.provider_name, self.allocator, config) catch |err| {
                self.finishFailure(slot, @errorName(err));
                self.mutex.unlock(self.io);
                return;
            };
        }
        const instance = slot.provider_instance.?;
        var request_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer request_arena.deinit();
        const request = self.buildRequest(slot, request_arena.allocator()) catch |err| {
            self.finishFailure(slot, @errorName(err));
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);

        instance.stream(instance.ptr, self.allocator, self.io, request, sink, &slot.token) catch |err| {
            self.mutex.lockUncancelable(self.io);
            if (err == error.Cancelled or slot.token.isCancelled()) {
                self.finishCancelled(slot);
            } else {
                self.finishFailure(slot, @errorName(err));
            }
            self.mutex.unlock(self.io);
            return;
        };

        self.mutex.lockUncancelable(self.io);
        // Record the assistant message.
        slot.thread.appendMessage(.assistant, slot.assistant_buf.items) catch {};
        self.emitMessageDone(slot);
        const calls = slot.tool_calls.items;
        self.mutex.unlock(self.io);

        // Execute tool calls (host I/O outside the lock).
        for (calls) |call| {
            if (slot.token.isCancelled()) break;
            const outcome = self.executeTool(slot, call) catch |err| {
                self.mutex.lockUncancelable(self.io);
                if (err == error.Cancelled or slot.token.isCancelled()) {
                    self.finishCancelled(slot);
                } else {
                    self.finishFailure(slot, @errorName(err));
                }
                self.mutex.unlock(self.io);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            slot.thread.appendMessage(.tool, outcome.output) catch {};
            self.emitToolFinished(slot, call.name, outcome.ok, outcome.output);
            self.allocator.free(outcome.output);
            self.mutex.unlock(self.io);
        }

        self.mutex.lockUncancelable(self.io);
        if (slot.token.isCancelled()) {
            self.finishCancelled(slot);
        } else {
            slot.thread.setState(.idle) catch {};
            slot.thread.updated_ms = @intCast(@divTrunc(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
            self.emitState(slot);
            self.persistSlot(slot);
        }
        slot.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn buildRequest(self: *Engine, slot: *ThreadSlot, a: Allocator) !provider.Request {
        _ = self;
        var messages: std.ArrayList(provider.ChatMessage) = .empty;
        var system: std.ArrayList(u8) = .empty;
        try system.appendSlice(a, "You are Coral's coding agent.");
        if (slot.skills) |skills| {
            if (skills.skills.items.len > 0) {
                const indices = try a.alloc(usize, skills.skills.items.len);
                for (indices, 0..) |*idx, i| idx.* = i;
                const prompt = try skills.renderPrompt(a, indices);
                try system.appendSlice(a, "\n\n");
                try system.appendSlice(a, prompt);
            }
        }
        try messages.append(a, .{ .role = .system, .content = system.items });
        for (slot.thread.messages.items) |m| {
            try messages.append(a, .{ .role = m.role, .content = m.content, .tool_call_id = m.tool_call_id });
        }
        var specs: std.ArrayList(provider.ToolSpec) = .empty;
        try specs.appendSlice(a, &tools.builtin_specs);
        for (slot.mcp_tools.items) |ref| {
            const name = try std.fmt.allocPrint(a, "mcp:{s}:{s}", .{ slot.mcp_clients.items[ref.server].server_name, ref.tool.name });
            try specs.append(a, .{ .name = name, .description = ref.tool.description, .parameters_json = ref.tool.input_schema_json });
        }
        return .{ .model = slot.thread.model, .messages = try messages.toOwnedSlice(a), .tools = try specs.toOwnedSlice(a) };
    }

    const ToolOutcome = struct { ok: bool, output: []u8 };

    fn executeTool(self: *Engine, slot: *ThreadSlot, call: provider.ToolCall) !ToolOutcome {
        self.mutex.lockUncancelable(self.io);
        try self.pushEvent(.{ .tool_started = .{
            .thread_id = try self.allocator.dupe(u8, slot.thread.id),
            .tool = try self.allocator.dupe(u8, call.name),
        } });
        // MCP tools carry their own approval semantics (read-only hint plus
        // explicit policy overrides); the generic default-ask gate must not
        // block read-only MCP calls.
        if (std.mem.startsWith(u8, call.name, "mcp:")) {
            self.mutex.unlock(self.io);
            return try self.callMcpTool(slot, call);
        }
        const decision = self.policy.decide(call.name);
        const worktree_root: ?[]const u8 = if (slot.thread.worktree) |w| w.root else null;
        self.mutex.unlock(self.io);

        if (decision == .deny) {
            return .{ .ok = false, .output = try self.allocator.dupe(u8, "denied by policy") };
        }
        if (decision == .ask) {
            const response = try self.requestPermission(slot, call.name, call.arguments_json);
            if (response != .allow) {
                return .{ .ok = false, .output = try self.allocator.dupe(u8, "permission denied") };
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const args = std.json.parseFromSliceLeaky(std.json.Value, a, call.arguments_json, .{}) catch std.json.Value{ .object = .empty };
        const args_obj = if (args == .object) args.object else null;

        if (std.mem.eql(u8, call.name, tools.read_file)) {
            const path = try self.resolveToolPath(worktree_root, args_obj, "path");
            defer self.allocator.free(path);
            const read = self.host.readFile orelse return error.Unsupported;
            const content = try read(self.host.ctx, self.allocator, path);
            return .{ .ok = true, .output = content };
        }
        if (std.mem.eql(u8, call.name, tools.list_dir)) {
            const path = try self.resolveToolPath(worktree_root, args_obj, "path");
            defer self.allocator.free(path);
            const list = self.host.listDir orelse return error.Unsupported;
            const entries = try list(self.host.ctx, self.allocator, path);
            defer self.allocator.free(entries);
            var out: std.ArrayList(u8) = .empty;
            for (entries) |e| {
                try out.print(self.allocator, "{s}\t{s}\n", .{ @tagName(e.kind), e.name });
                self.allocator.free(e.name);
            }
            return .{ .ok = true, .output = try out.toOwnedSlice(self.allocator) };
        }
        if (std.mem.eql(u8, call.name, tools.search)) {
            const pattern = getStringArg(args_obj, "pattern") orelse return error.MissingArgument;
            const root = worktree_root orelse ".";
            const search_fn = self.host.search orelse return error.Unsupported;
            const output = try search_fn(self.host.ctx, self.allocator, root, pattern);
            return .{ .ok = true, .output = output };
        }
        if (std.mem.eql(u8, call.name, tools.propose_edit)) {
            return try self.proposeEditTool(slot, worktree_root, args_obj);
        }
        if (std.mem.eql(u8, call.name, tools.run_terminal)) {
            return try self.runTerminalTool(slot, worktree_root, args_obj);
        }
        if (std.mem.startsWith(u8, call.name, "mcp:")) {
            return try self.callMcpTool(slot, call);
        }
        return .{ .ok = false, .output = try std.fmt.allocPrint(self.allocator, "unknown tool: {s}", .{call.name}) };
    }

    fn resolveToolPath(self: *Engine, root: ?[]const u8, args: ?std.json.ObjectMap, key: []const u8) ![]u8 {
        const path = getStringArg(args, key) orelse return error.MissingArgument;
        return tools.resolvePath(self.allocator, root, path);
    }

    fn proposeEditTool(self: *Engine, slot: *ThreadSlot, root: ?[]const u8, args: ?std.json.ObjectMap) !ToolOutcome {
        const a = self.allocator;
        const files_val = (args orelse return error.MissingArgument).get("files") orelse return error.MissingArgument;
        if (files_val != .array) return error.InvalidArguments;
        const title = getStringArg(args, "title") orelse "Proposed edit";
        const read = self.host.readFile orelse return error.Unsupported;

        var edits: std.ArrayList(review.FileEdit) = .empty;
        errdefer {
            for (edits.items) |*f| f.deinit(a);
            edits.deinit(a);
        }
        for (files_val.array.items) |item| {
            if (item != .object) continue;
            const path = getStringArg(item.object, "path") orelse continue;
            const content = getStringArg(item.object, "content") orelse continue;
            const resolved = try tools.resolvePath(a, root, path);
            const current = read(self.host.ctx, a, resolved) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    a.free(resolved);
                    return err;
                },
            };
            const base = review.revisionOf(current);
            if (current) |c| a.free(c);
            try edits.append(a, .{
                .path = resolved,
                .base = base,
                .new_content = try a.dupe(u8, content),
            });
        }
        const files_owned = try edits.toOwnedSlice(a);
        self.mutex.lockUncancelable(self.io);
        const proposal = try self.createProposal(slot, title, files_owned);
        const id_copy = try a.dupe(u8, proposal.id);
        self.persistSlot(slot);
        self.mutex.unlock(self.io);
        const output = try std.fmt.allocPrint(a, "proposal {s} pending review ({d} files)", .{ id_copy, files_owned.len });
        a.free(id_copy);
        return .{ .ok = true, .output = output };
    }

    fn runTerminalTool(self: *Engine, slot: *ThreadSlot, root: ?[]const u8, args: ?std.json.ObjectMap) !ToolOutcome {
        const command = getStringArg(args, "command") orelse return error.MissingArgument;
        const cwd = getStringArg(args, "cwd") orelse root;
        const spawn = self.host.terminalSpawn orelse return error.Unsupported;
        const wait = self.host.terminalWait orelse return error.Unsupported;
        const handle = try spawn(self.host.ctx, command, cwd);
        self.mutex.lockUncancelable(self.io);
        try slot.terminals.append(self.allocator, handle);
        self.mutex.unlock(self.io);

        const result = try wait(self.host.ctx, handle, 0);
        self.mutex.lockUncancelable(self.io);
        self.removeTerminal(slot, handle);
        self.mutex.unlock(self.io);
        const output = try self.allocator.dupe(u8, result.output);
        self.allocator.free(result.output);
        return .{ .ok = !result.cancelled, .output = output };
    }

    fn removeTerminal(_: *Engine, slot: *ThreadSlot, handle: host_mod.TerminalHandle) void {
        for (slot.terminals.items, 0..) |h, i| {
            if (h == handle) {
                _ = slot.terminals.orderedRemove(i);
                return;
            }
        }
    }

    fn callMcpTool(self: *Engine, slot: *ThreadSlot, call: provider.ToolCall) !ToolOutcome {
        // name format: mcp:<server>:<tool>
        var it = std.mem.splitScalar(u8, call.name, ':');
        _ = it.next(); // "mcp"
        const server_name = it.next() orelse return error.UnknownTool;
        const tool_name = it.rest();
        self.mutex.lockUncancelable(self.io);
        var found: ?McpToolRef = null;
        for (slot.mcp_tools.items) |ref| {
            if (std.mem.eql(u8, slot.mcp_clients.items[ref.server].server_name, server_name) and
                std.mem.eql(u8, ref.tool.name, tool_name))
            {
                found = ref;
            }
        }
        const ref = found orelse {
            self.mutex.unlock(self.io);
            return error.UnknownTool;
        };
        const client = slot.mcp_clients.items[ref.server];
        // Explicit policy rules win; otherwise the tool's read-only hint
        // decides: read-only calls run directly, writable calls need approval.
        const decision = self.policy.rule(call.name) orelse
            (if (ref.tool.requiresApproval()) policy_mod.Decision.ask else policy_mod.Decision.allow);
        self.mutex.unlock(self.io);

        if (decision == .deny) {
            return .{ .ok = false, .output = try self.allocator.dupe(u8, "denied by policy") };
        }
        if (decision == .ask) {
            const response = try self.requestPermission(slot, call.name, call.arguments_json);
            if (response != .allow) return .{ .ok = false, .output = try self.allocator.dupe(u8, "permission denied") };
        }
        const result = try client.call(self.allocator, tool_name, call.arguments_json, &slot.token, 10000);
        return .{ .ok = !result.is_error, .output = @constCast(result.content) };
    }

    fn requestPermission(self: *Engine, slot: *ThreadSlot, tool: []const u8, summary: []const u8) !PermissionResponse {
        self.mutex.lockUncancelable(self.io);
        const id = try self.makeId("perm");
        slot.pending_permission = .{
            .id = id,
            .tool = try self.allocator.dupe(u8, tool),
            .summary = try self.allocator.dupe(u8, summary),
        };
        slot.thread.setState(.awaiting_permission) catch {};
        try self.pushEvent(.{ .permission_request = .{
            .thread_id = try self.allocator.dupe(u8, slot.thread.id),
            .request_id = try self.allocator.dupe(u8, id),
            .tool = try self.allocator.dupe(u8, tool),
            .summary = try self.allocator.dupe(u8, summary),
        } });
        while (slot.pending_permission != null and slot.pending_permission.?.decision == null and !slot.token.isCancelled()) {
            slot.cond.waitUncancelable(self.io, &self.mutex);
        }
        const decision = if (slot.pending_permission) |p| p.decision orelse .cancel else .cancel;
        if (slot.pending_permission) |*p| {
            self.allocator.free(p.id);
            self.allocator.free(p.tool);
            self.allocator.free(p.summary);
        }
        slot.pending_permission = null;
        if (slot.token.isCancelled()) {
            self.mutex.unlock(self.io);
            return error.Cancelled;
        }
        slot.thread.setState(.streaming) catch {};
        self.mutex.unlock(self.io);
        return decision;
    }

    fn finishCancelled(self: *Engine, slot: *ThreadSlot) void {
        slot.thread.setState(.cancelled) catch {};
        self.pushEvent(.{ .cancelled = .{ .thread_id = self.allocator.dupe(u8, slot.thread.id) catch return } }) catch {};
        self.persistSlot(slot);
        slot.cond.broadcast(self.io);
    }

    fn finishFailure(self: *Engine, slot: *ThreadSlot, message: []const u8) void {
        slot.thread.setState(.failed) catch {};
        self.pushEvent(.{ .failed = .{
            .thread_id = self.allocator.dupe(u8, slot.thread.id) catch return,
            .message = self.allocator.dupe(u8, message) catch return,
        } }) catch {};
        self.persistSlot(slot);
        slot.cond.broadcast(self.io);
    }

    // -- ACP worker ---------------------------------------------------------

    fn acpWorker(self: *Engine, slot: *ThreadSlot) void {
        self.mutex.lockUncancelable(self.io);
        if (slot.acp_client == null) {
            const ctx = self.allocator.create(AcpContext) catch {
                self.finishFailure(slot, "OutOfMemory");
                self.mutex.unlock(self.io);
                return;
            };
            ctx.* = .{ .engine = self, .slot = slot };
            slot.acp_context = ctx;
            const cfg = slot.selection.acp;
            const cwd = cfg.cwd orelse (if (slot.thread.worktree) |w| w.root else null);
            const client = acp.AcpClient.start(self.allocator, self.io, cfg.argv, cwd, self.acpHost(ctx), .{}) catch |err| {
                self.allocator.destroy(ctx);
                slot.acp_context = null;
                self.finishFailure(slot, @errorName(err));
                self.mutex.unlock(self.io);
                return;
            };
            slot.acp_client = client;
            client.initialize(5000) catch |err| {
                self.finishFailure(slot, @errorName(err));
                self.mutex.unlock(self.io);
                return;
            };
            const session_cwd = if (slot.thread.worktree) |w| w.root else ".";
            slot.acp_session = client.newSession(self.allocator, session_cwd, 5000) catch |err| {
                self.finishFailure(slot, @errorName(err));
                self.mutex.unlock(self.io);
                return;
            };
        }
        const client = slot.acp_client.?;
        const session = slot.acp_session.?;
        const last_user = blk: {
            const msgs = slot.thread.messages.items;
            var i = msgs.len;
            while (i > 0) {
                i -= 1;
                if (msgs[i].role == .user) break :blk msgs[i].content;
            }
            break :blk "";
        };
        const text = self.allocator.dupe(u8, last_user) catch {
            self.finishFailure(slot, "OutOfMemory");
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);
        defer self.allocator.free(text);

        const stop_reason = client.prompt(self.allocator, session, text, &slot.token, 30000) catch |err| {
            self.mutex.lockUncancelable(self.io);
            if (err == error.Cancelled or slot.token.isCancelled()) {
                self.finishCancelled(slot);
            } else {
                self.finishFailure(slot, @errorName(err));
            }
            self.mutex.unlock(self.io);
            return;
        };
        defer self.allocator.free(stop_reason);

        // Apply any still-queued session updates before recording the message
        // so the assistant text and delta events are complete and ordered.
        client.drain(2000);

        self.mutex.lockUncancelable(self.io);
        slot.thread.appendMessage(.assistant, slot.assistant_buf.items) catch {};
        if (slot.token.isCancelled()) {
            self.finishCancelled(slot);
        } else {
            slot.thread.setState(.idle) catch {};
            self.emitMessageDone(slot);
            self.emitState(slot);
            self.persistSlot(slot);
        }
        slot.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn acpHost(self: *Engine, ctx: *AcpContext) acp.AcpHost {
        _ = self;
        return .{
            .ctx = ctx,
            .onSessionUpdate = acpOnUpdate,
            .requestPermission = acpOnPermission,
            .readTextFile = acpReadFile,
            .writeTextFile = acpWriteFile,
            .terminalCreate = acpTerminalCreate,
            .terminalOutput = acpTerminalOutput,
            .terminalWait = acpTerminalWait,
            .terminalKill = acpTerminalKill,
            .terminalRelease = acpTerminalRelease,
            .onDisconnect = acpOnDisconnect,
        };
    }

    fn acpOnUpdate(ctx: *anyopaque, session_id: []const u8, update: std.json.Value) void {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        const slot = ac.slot;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Accumulate agent message chunks.
        if (update == .object) {
            if (update.object.get("sessionUpdate")) |kind| {
                if (kind == .string and std.mem.eql(u8, kind.string, "agent_message_chunk")) {
                    if (update.object.get("content")) |content| {
                        if (content == .object) {
                            if (content.object.get("text")) |t| {
                                if (t == .string) {
                                    slot.assistant_buf.appendSlice(self.allocator, t.string) catch {};
                                    self.pushEvent(.{ .delta = .{
                                        .thread_id = self.allocator.dupe(u8, slot.thread.id) catch return,
                                        .text = self.allocator.dupe(u8, t.string) catch return,
                                    } }) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }
        const json = std.json.Stringify.valueAlloc(self.allocator, update, .{}) catch return;
        self.pushEvent(.{ .acp_update = .{
            .thread_id = self.allocator.dupe(u8, slot.thread.id) catch {
                self.allocator.free(json);
                return;
            },
            .json = json,
        } }) catch {
            self.allocator.free(json);
        };
        _ = session_id;
    }

    fn acpOnPermission(ctx: *anyopaque, session_id: []const u8, params: std.json.Value) acp.PermissionDecision {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        const slot = ac.slot;
        _ = session_id;
        // Choose option ids by kind.
        var allow_id: ?[]const u8 = null;
        var deny_id: ?[]const u8 = null;
        var first_id: ?[]const u8 = null;
        if (params == .object) {
            if (params.object.get("options")) |options| {
                if (options == .array) {
                    for (options.array.items) |opt| {
                        if (opt != .object) continue;
                        const oid = getStringArg(opt.object, "optionId") orelse continue;
                        if (first_id == null) first_id = oid;
                        const kind = getStringArg(opt.object, "kind") orelse "";
                        if (std.mem.eql(u8, kind, "allow") or std.mem.eql(u8, kind, "allow_always")) allow_id = oid;
                        if (std.mem.eql(u8, kind, "deny") or std.mem.eql(u8, kind, "reject")) deny_id = oid;
                    }
                }
            }
        }
        const summary = if (params == .object) (getStringArg(params.object, "toolCall") orelse "permission") else "permission";
        const response = self.requestPermission(slot, "acp", summary) catch return .cancel;
        return switch (response) {
            .allow => .{ .select = allow_id orelse first_id orelse "allow" },
            .deny => .{ .select = deny_id orelse first_id orelse "deny" },
            .cancel => .cancel,
        };
    }

    fn acpReadFile(ctx: *anyopaque, allocator: Allocator, session_id: []const u8, path: []const u8) anyerror![]u8 {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        const root: ?[]const u8 = if (ac.slot.thread.worktree) |w| w.root else null;
        self.mutex.unlock(self.io);
        const resolved = try tools.resolvePath(allocator, root, path);
        defer allocator.free(resolved);
        const read = self.host.readFile orelse return error.Unsupported;
        return read(self.host.ctx, allocator, resolved);
    }

    fn acpWriteFile(ctx: *anyopaque, session_id: []const u8, path: []const u8, content: []const u8) anyerror!void {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        const slot = ac.slot;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        const root: ?[]const u8 = if (slot.thread.worktree) |w| w.root else null;
        self.mutex.unlock(self.io);
        const resolved = try tools.resolvePath(self.allocator, root, path);
        defer self.allocator.free(resolved);
        const read = self.host.readFile orelse return error.Unsupported;
        const current = read(self.host.ctx, self.allocator, resolved) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const base = review.revisionOf(current);
        if (current) |c| self.allocator.free(c);

        const files = try self.allocator.alloc(review.FileEdit, 1);
        files[0] = .{
            .path = try self.allocator.dupe(u8, resolved),
            .base = base,
            .new_content = try self.allocator.dupe(u8, content),
        };
        self.mutex.lockUncancelable(self.io);
        const proposal = try self.createProposal(slot, "ACP edit", files);
        const review_id = try self.allocator.dupe(u8, proposal.id);
        slot.pending_review = .{ .review_id = review_id };
        slot.thread.setState(.awaiting_review) catch {};
        while (slot.pending_review != null and slot.pending_review.?.resolution == null and !slot.token.isCancelled()) {
            slot.cond.waitUncancelable(self.io, &self.mutex);
        }
        const resolution = if (slot.pending_review) |pr| pr.resolution else null;
        if (slot.pending_review) |*pr| self.allocator.free(pr.review_id);
        slot.pending_review = null;
        self.mutex.unlock(self.io);

        if (slot.token.isCancelled()) return error.Cancelled;
        if (resolution == .accept) return; // acceptReview already applied the write
        return error.Rejected;
    }

    fn acpTerminalCreate(ctx: *anyopaque, session_id: []const u8, command: []const u8, args: []const []const u8, cwd: ?[]const u8) anyerror![]u8 {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        const spawn = self.host.terminalSpawn orelse return error.Unsupported;
        var full: std.ArrayList(u8) = .empty;
        defer full.deinit(self.allocator);
        try full.appendSlice(self.allocator, command);
        for (args) |arg| {
            try full.append(self.allocator, ' ');
            try full.appendSlice(self.allocator, arg);
        }
        const handle = try spawn(self.host.ctx, full.items, cwd);
        const id = try self.makeId("term");
        self.mutex.lockUncancelable(self.io);
        try ac.slot.acp_terminals.put(try self.allocator.dupe(u8, id), handle);
        try ac.slot.terminals.append(self.allocator, handle);
        self.mutex.unlock(self.io);
        return id;
    }

    fn acpTerminalOutput(ctx: *anyopaque, allocator: Allocator, session_id: []const u8, terminal_id: []const u8) anyerror!acp.TerminalOutput {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        const handle = ac.slot.acp_terminals.get(terminal_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownTerminal;
        };
        self.mutex.unlock(self.io);
        const wait = self.host.terminalWait orelse return error.Unsupported;
        const result = try wait(self.host.ctx, handle, 0);
        const output = try allocator.dupe(u8, result.output);
        self.allocator.free(result.output);
        return .{ .output = output, .exit_code = result.exit_code };
    }

    fn acpTerminalWait(ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) anyerror!i32 {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        const handle = ac.slot.acp_terminals.get(terminal_id) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownTerminal;
        };
        self.mutex.unlock(self.io);
        const wait = self.host.terminalWait orelse return error.Unsupported;
        const result = try wait(self.host.ctx, handle, 0);
        self.allocator.free(result.output);
        return result.exit_code orelse 0;
    }

    fn acpTerminalKill(ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) void {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        const handle = ac.slot.acp_terminals.get(terminal_id);
        self.mutex.unlock(self.io);
        if (handle) |h| {
            if (self.host.terminalKill) |kill| kill(self.host.ctx, h);
        }
    }

    fn acpTerminalRelease(ctx: *anyopaque, session_id: []const u8, terminal_id: []const u8) void {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        _ = session_id;
        self.mutex.lockUncancelable(self.io);
        if (ac.slot.acp_terminals.fetchRemove(terminal_id)) |kv| {
            self.allocator.free(kv.key);
        }
        self.mutex.unlock(self.io);
    }

    fn acpOnDisconnect(ctx: *anyopaque) void {
        const ac: *AcpContext = @ptrCast(@alignCast(ctx));
        const self = ac.engine;
        self.mutex.lockUncancelable(self.io);
        self.pushEvent(.{ .failed = .{
            .thread_id = self.allocator.dupe(u8, ac.slot.thread.id) catch {
                self.mutex.unlock(self.io);
                return;
            },
            .message = self.allocator.dupe(u8, "acp disconnected") catch {
                self.mutex.unlock(self.io);
                return;
            },
        } }) catch {};
        ac.slot.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn getStringArg(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const obj = args orelse return null;
        const v = obj.get(key) orelse return null;
        if (v != .string) return null;
        return v.string;
    }
};

test "Engine constructs and probes fake provider" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const path = try tmp.dir.realPathFileAlloc(threaded.io(), ".", a);
    defer a.free(path);
    const engine = try Engine.init(a, .{}, .{ .state_dir = path });
    defer engine.deinit();
    const result = try engine.probe("fake");
    try std.testing.expect(result.ok);
    const unknown = try engine.probe("nope");
    try std.testing.expect(!unknown.ok);
}
