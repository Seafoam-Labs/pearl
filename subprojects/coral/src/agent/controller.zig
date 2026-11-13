//! M6/M7 native agent dock controller.
//!
//! Owns the GTK agent panel (thread list, streaming transcript, context
//! attachment chips, provider picker, permission cards, review proposals,
//! skills search, cancel and status) and drives the GTK-free backend Engine.
//!
//! Threading model
//! ---------------
//! The Engine runs each `send` on a worker thread and emits Events into an
//! internal queue. This controller drains that queue ONLY on the GTK main loop
//! via a bounded `g_timeout_add` pump; every GTK mutation happens there. Host
//! callbacks (readFile/listDir/search/writeFile/terminal*/gitDiff/diagnostics/
//! log) are invoked by the Engine on worker threads: they perform their I/O
//! directly on the calling worker (never on the UI thread) and guard the shared
//! terminal registry / workspace-root snapshot with a short-lived mutex that is
//! NEVER held across blocking I/O. The UI thread only ever takes that mutex for
//! O(1) snapshot/registry work, so the main loop is never blocked by agent I/O.
//! `log` is routed to the thread-safe std.log sink; all visible status flows
//! through the main-loop pump. No host callback touches GTK.
//!
//! Trust model
//! -----------
//! The workspace is always trusted: a user action creates a thread and sends
//! directly with NO workspace consent prompt. Tool permissions and multi-file
//! review remain fully enforced by the Engine policy; this controller renders
//! the permission/review cards and answers them, never bypassing them.
//!
//! Bounds: 64 threads, 1 MiB transcript per thread (oldest trimmed), 128 pending
//! attachment chips per thread. Host file reads are capped at 4 MiB.
//!
//! Ownership: the parent App wires this controller later (init/attach/deinit,
//! dock slot, command/fixture dispatch). This file is self-contained and does
//! not modify app.zig, build.zig, the backend agent modules, dock or commands.

const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const engine_mod = @import("engine.zig");
const host_mod = @import("host.zig");
const context = @import("context.zig");
const review_mod = @import("review.zig");
const test_hooks = @import("build_options").test_hooks;

const Engine = engine_mod.Engine;
const Host = engine_mod.Host;
const State = engine_mod.State;
const ProviderSelection = engine_mod.ProviderSelection;
const AttachmentInput = engine_mod.AttachmentInput;
const NewThread = engine_mod.NewThread;
const PermissionResponse = engine_mod.PermissionResponse;
const Event = engine_mod.Event;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_threads: usize = 64;
pub const transcript_limit: usize = 1024 * 1024;
pub const max_attachments: usize = 128;
const pump_interval_ms: c_uint = 30;
const host_io_limit: usize = 4 * 1024 * 1024;
const tool_output_display: usize = 4096;
const max_search_entries: usize = 4096;
const provider_names = [_][:0]const u8{ "fake", "openai", "acp" };

// ---------------------------------------------------------------------------
// Host boundary (heap-stable; shared with Engine worker threads)
// ---------------------------------------------------------------------------

/// Heap-allocated so its address survives the Controller being moved into the
/// App struct. Holds only worker-safe state: an Io (the Engine's), a mutex, a
/// workspace-root snapshot and the terminal registry. It never points back at
/// the Controller and never touches GTK.
const HostState = struct {
    allocator: Allocator,
    io: Io = undefined,
    mutex: Io.Mutex = .init,
    root: ?[:0]u8 = null,
    terminals: std.AutoHashMap(u64, *Terminal),
    next_handle: u64 = 1,
    read_count: usize = 0,
    write_count: usize = 0,
    spawn_count: usize = 0,
    kill_count: usize = 0,
    search_count: usize = 0,
    diff_count: usize = 0,

    const Terminal = struct {
        child: std.process.Child,
        stdout: Io.File,
        output: ?[]u8 = null,
        exit_code: ?i32 = null,
        done: bool = false,
        killed: bool = false,
    };

    fn create(allocator: Allocator) !*HostState {
        const self = try allocator.create(HostState);
        self.* = .{
            .allocator = allocator,
            .terminals = std.AutoHashMap(u64, *Terminal).init(allocator),
        };
        return self;
    }

    fn deinit(self: *HostState) void {
        var it = self.terminals.valueIterator();
        while (it.next()) |term| {
            if (!term.*.done) term.*.child.kill(self.io);
            if (term.*.output) |o| self.allocator.free(o);
            self.allocator.destroy(term.*);
        }
        self.terminals.deinit();
        if (self.root) |r| self.allocator.free(r);
    }

    fn asHost(self: *HostState) Host {
        return .{
            .ctx = self,
            .readFile = readFile,
            .listDir = listDir,
            .search = search,
            .writeFile = writeFile,
            .terminalSpawn = terminalSpawn,
            .terminalWait = terminalWait,
            .terminalKill = terminalKill,
            .gitDiff = gitDiff,
            .diagnostics = diagnostics,
            .log = log,
        };
    }

    /// GTK-thread snapshot update. Brief lock; never held across I/O.
    fn setRoot(self: *HostState, root: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.root) |r| self.allocator.free(r);
        self.root = if (root) |r| self.allocator.dupeSentinel(u8, r, 0) catch null else null;
    }

    fn readFile(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        self.read_count += 1;
        self.mutex.unlock(self.io);
        return Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(host_io_limit));
    }

    fn listDir(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]host_mod.DirEntry {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        var dir = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var list: std.ArrayList(host_mod.DirEntry) = .empty;
        errdefer {
            for (list.items) |e| allocator.free(e.name);
            list.deinit(allocator);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (list.items.len >= max_search_entries) break;
            const kind: host_mod.DirEntry.Kind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            };
            try list.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = kind });
        }
        return list.toOwnedSlice(allocator);
    }

    fn search(ctx: ?*anyopaque, allocator: Allocator, root: []const u8, pattern: []const u8) anyerror![]u8 {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        self.search_count += 1;
        self.mutex.unlock(self.io);
        var dir = try Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true });
        defer dir.close(self.io);
        var out: std.ArrayList(u8) = .empty;
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.indexOf(u8, entry.basename, pattern) != null) {
                try out.print(allocator, "{s}\n", .{entry.path});
                count += 1;
                if (count >= max_search_entries) break;
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn writeFile(ctx: ?*anyopaque, path: []const u8, content: []const u8) anyerror!void {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        self.write_count += 1;
        self.mutex.unlock(self.io);
        // Only invoked by the Engine for accepted reviews / checkpoint reverts.
        if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(self.io, parent) catch {};
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = content });
    }

    fn terminalSpawn(ctx: ?*anyopaque, command: []const u8, cwd: ?[]const u8) anyerror!host_mod.TerminalHandle {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        var cwd_opt: std.process.Child.Cwd = .inherit;
        if (cwd) |cc| cwd_opt = .{ .path = cc };
        const child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .cwd = cwd_opt,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const term = try self.allocator.create(Terminal);
        term.* = .{ .child = child, .stdout = child.stdout.? };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const handle = self.next_handle;
        self.next_handle += 1;
        self.spawn_count += 1;
        try self.terminals.put(handle, term);
        return handle;
    }

    fn terminalWait(ctx: ?*anyopaque, handle: host_mod.TerminalHandle, timeout_ms: u32) anyerror!host_mod.TerminalResult {
        _ = timeout_ms;
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        const term = self.terminals.get(handle) orelse {
            self.mutex.unlock(self.io);
            return error.UnknownTerminal;
        };
        self.mutex.unlock(self.io);
        // I/O runs on the worker without the lock; each handle has one waiter.
        if (!term.done) {
            var buf: [4096]u8 = undefined;
            var reader = term.stdout.reader(self.io, &buf);
            term.output = reader.interface.allocRemaining(self.allocator, .limited(host_io_limit)) catch |err| blk: {
                if (err == error.StreamTooLong) break :blk try self.allocator.dupe(u8, "");
                return err;
            };
            const term_result = if (!term.killed) term.child.wait(self.io) catch std.process.Child.Term{ .unknown = 0 } else std.process.Child.Term{ .unknown = 0 };
            term.exit_code = switch (term_result) {
                .exited => |code| @as(i32, code),
                else => null,
            };
            term.done = true;
        }
        return .{
            .exit_code = term.exit_code,
            .output = try self.allocator.dupe(u8, term.output orelse ""),
            .cancelled = term.killed,
        };
    }

    fn terminalKill(ctx: ?*anyopaque, handle: host_mod.TerminalHandle) void {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        const term = self.terminals.get(handle) orelse {
            self.mutex.unlock(self.io);
            return;
        };
        self.kill_count += 1;
        self.mutex.unlock(self.io);
        term.killed = true;
        if (!term.done) term.child.kill(self.io);
    }

    fn gitDiff(ctx: ?*anyopaque, allocator: Allocator, root: []const u8) anyerror![]u8 {
        const self: *HostState = @ptrCast(@alignCast(ctx.?));
        self.mutex.lockUncancelable(self.io);
        self.diff_count += 1;
        self.mutex.unlock(self.io);
        return self.capture(allocator, &.{ "git", "diff" }, root);
    }

    fn diagnostics(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) anyerror![]u8 {
        _ = ctx;
        _ = path;
        // Live LSP diagnostics live on the GTK-thread language controller; the
        // worker-safe host returns an empty bounded result. The parent may wire
        // a marshalled diagnostics source later without changing this boundary.
        return allocator.dupe(u8, "");
    }

    fn log(ctx: ?*anyopaque, level: host_mod.LogLevel, message: []const u8) void {
        _ = ctx;
        const logger = std.log.scoped(.agent);
        switch (level) {
            .debug => logger.debug("{s}", .{message}),
            .info => logger.info("{s}", .{message}),
            .warn => logger.warn("{s}", .{message}),
            .@"error" => logger.err("{s}", .{message}),
        }
    }

    fn capture(self: *HostState, allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
        var cwd_opt: std.process.Child.Cwd = .inherit;
        if (cwd) |cc| cwd_opt = .{ .path = cc };
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.reader(self.io, &buf);
        const out = reader.interface.allocRemaining(allocator, .limited(host_io_limit)) catch |err| blk: {
            if (err == error.StreamTooLong) break :blk try allocator.dupe(u8, "");
            return err;
        };
        _ = child.wait(self.io) catch {};
        return out;
    }
};

// ---------------------------------------------------------------------------
// Per-thread UI record (heap; bounded by max_threads)
// ---------------------------------------------------------------------------

const ThreadUi = struct {
    id: [:0]u8,
    title: [:0]u8,
    provider: [:0]u8,
    state: State = .idle,
    transcript: std.ArrayList(u8) = .empty,
    messages: usize = 0,
    attachments: std.ArrayList(Chip) = .empty,
    permission: ?Permission = null,
    review: ?Review = null,
    row: u.W,
    row_label: u.W,

    const Chip = struct { kind: context.Kind, label: [:0]u8, content: [:0]u8 };
    const Permission = struct { request_id: [:0]u8, tool: [:0]u8, summary: [:0]u8 };
    const Review = struct { review_id: [:0]u8, title: [:0]u8, file_count: usize, files: [][:0]u8 };

    fn deinit(self: *ThreadUi) void {
        a.free(self.id);
        a.free(self.title);
        a.free(self.provider);
        self.transcript.deinit(a);
        for (self.attachments.items) |chip| {
            a.free(chip.label);
            a.free(chip.content);
        }
        self.attachments.deinit(a);
        if (self.permission) |p| {
            a.free(p.request_id);
            a.free(p.tool);
            a.free(p.summary);
        }
        if (self.review) |r| {
            a.free(r.review_id);
            a.free(r.title);
            for (r.files) |f| a.free(f);
            a.free(r.files);
        }
    }
};

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

pub const Controller = struct {
    app: *App,
    engine: ?*Engine,
    host_state: ?*HostState,

    root: u.W,
    slot: ?u.W = null,
    new_button: u.W,
    close_button: u.W,
    provider_picker: u.W,
    cancel_button: u.W,
    allow_button: u.W,
    deny_button: u.W,
    cancel_permission_button: u.W,
    accept_button: u.W,
    reject_button: u.W,
    thread_list: u.W,
    transcript_view: u.W,
    transcript_buffer: *c.GtkTextBuffer,
    end_mark: *c.GtkTextMark,
    chips_box: u.W,
    permission_card: u.W,
    permission_tool: u.W,
    permission_summary: u.W,
    review_card: u.W,
    review_title: u.W,
    review_files: u.W,
    skills_entry: u.W,
    skills_results: u.W,
    input_entry: u.W,
    send_button: u.W,
    status: u.W,

    threads: [max_threads]?*ThreadUi = @splat(null),
    thread_count: usize = 0,
    active: ?usize = null,
    pump_id: c_uint = 0,
    closed: bool = false,
    last_error: ?[]const u8 = null,
    skills_query: []const u8 = "",
    skills_matches: usize = 0,

    pub fn init(app: *App) Controller {
        var host_state: ?*HostState = null;
        var engine: ?*Engine = null;
        var last_error: ?[]const u8 = null;
        if (HostState.create(a)) |hs| {
            if (Engine.init(a, hs.asHost(), .{})) |e| {
                // restore() never invokes host callbacks, so publishing the
                // Engine Io here (before any worker runs) is safe.
                hs.io = e.io;
                host_state = hs;
                engine = e;
            } else |err| {
                hs.deinit();
                a.destroy(hs);
                last_error = @errorName(err);
            }
        } else |_| {
            last_error = "HostAlloc";
        }

        const root = u.box(false, 0);
        _ = c.g_object_ref_sink(root);
        c.gtk_widget_add_css_class(root, "agent-panel");
        c.gtk_widget_set_hexpand(root, 1);
        c.gtk_widget_set_vexpand(root, 1);

        // Toolbar: new thread, provider picker, cancel, close.
        const bar = u.box(true, 2);
        c.gtk_widget_add_css_class(bar, "agent-toolbar");
        u.append(root, bar);
        const new_button = u.icon("document-new-symbolic", "New agent thread");
        c.gtk_widget_add_css_class(new_button, "flat");
        u.append(bar, new_button);
        var strs = [_][*c]const u8{ "fake", "openai", "acp", null };
        const picker = c.gtk_drop_down_new_from_strings(@ptrCast(&strs)).?;
        c.gtk_widget_set_tooltip_text(picker, "Provider for new threads and the active thread");
        u.append(bar, picker);
        const spacer = u.box(true, 0);
        c.gtk_widget_set_hexpand(spacer, 1);
        u.append(bar, spacer);
        const cancel_button = u.button("Cancel");
        c.gtk_widget_add_css_class(cancel_button, "flat");
        u.append(bar, cancel_button);
        const close_button = u.icon("window-close-symbolic", "Hide agent panel");
        c.gtk_widget_add_css_class(close_button, "flat");
        u.append(bar, close_button);

        // Thread list.
        const thread_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, thread_scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_widget_set_size_request(thread_scroll, -1, 140);
        const thread_list = c.gtk_list_box_new().?;
        c.gtk_list_box_set_selection_mode(u.cast(c.GtkListBox, thread_list), c.GTK_SELECTION_SINGLE);
        c.gtk_widget_add_css_class(thread_list, "agent-threads");
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, thread_scroll), thread_list);
        u.append(root, thread_scroll);

        // Streaming transcript (read-only).
        const transcript_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(transcript_scroll, 1);
        c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, transcript_scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_min_content_height(u.cast(c.GtkScrolledWindow, transcript_scroll), 120);
        const transcript_view = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, transcript_view), 0);
        c.gtk_text_view_set_cursor_visible(u.cast(c.GtkTextView, transcript_view), 0);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, transcript_view), c.GTK_WRAP_WORD_CHAR);
        c.gtk_widget_add_css_class(transcript_view, "agent-transcript");
        const transcript_buffer = c.gtk_text_view_get_buffer(u.cast(c.GtkTextView, transcript_view)).?;
        var end_iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_end_iter(transcript_buffer, &end_iter);
        const end_mark = c.gtk_text_buffer_create_mark(transcript_buffer, "end", &end_iter, 0).?;
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, transcript_scroll), transcript_view);
        u.append(root, transcript_scroll);

        // Context attachment chips.
        const chips_box = c.gtk_flow_box_new().?;
        c.gtk_flow_box_set_selection_mode(u.cast(c.GtkFlowBox, chips_box), c.GTK_SELECTION_NONE);
        c.gtk_flow_box_set_max_children_per_line(u.cast(c.GtkFlowBox, chips_box), 8);
        c.gtk_widget_add_css_class(chips_box, "agent-chips");
        u.append(root, chips_box);

        // Permission card.
        const permission_card = u.box(false, 2);
        c.gtk_widget_add_css_class(permission_card, "agent-card");
        u.margin(permission_card, 4);
        const permission_tool = u.label("");
        c.gtk_widget_add_css_class(permission_tool, "agent-card-title");
        u.append(permission_card, permission_tool);
        const permission_summary = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, permission_summary), 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, permission_summary), 48);
        u.append(permission_card, permission_summary);
        const permission_buttons = u.box(true, 2);
        const allow_button = u.button("Allow");
        const deny_button = u.button("Deny");
        const cancel_permission_button = u.button("Cancel");
        for ([_]u.W{ allow_button, deny_button, cancel_permission_button }) |b| u.append(permission_buttons, b);
        u.append(permission_card, permission_buttons);
        c.gtk_widget_set_visible(permission_card, 0);
        u.append(root, permission_card);

        // Review proposal card.
        const review_card = u.box(false, 2);
        c.gtk_widget_add_css_class(review_card, "agent-card");
        u.margin(review_card, 4);
        const review_title = u.label("");
        c.gtk_widget_add_css_class(review_title, "agent-card-title");
        u.append(review_card, review_title);
        const review_files = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, review_files), 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, review_files), 48);
        c.gtk_widget_add_css_class(review_files, "agent-review-files");
        u.append(review_card, review_files);
        const review_buttons = u.box(true, 2);
        const accept_button = u.button("Accept");
        const reject_button = u.button("Reject");
        for ([_]u.W{ accept_button, reject_button }) |b| u.append(review_buttons, b);
        u.append(review_card, review_buttons);
        c.gtk_widget_set_visible(review_card, 0);
        u.append(root, review_card);

        // Skills search.
        const skills_row = u.box(true, 2);
        const skills_entry = c.gtk_entry_new().?;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, skills_entry), "Search skills…");
        c.gtk_widget_set_hexpand(skills_entry, 1);
        u.append(skills_row, skills_entry);
        u.append(root, skills_row);
        const skills_results = u.label("");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, skills_results), 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, skills_results), 48);
        c.gtk_widget_add_css_class(skills_results, "agent-skills");
        u.append(root, skills_results);

        u.append(root, c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?);

        // Compose row.
        const input_row = u.box(true, 2);
        const input_entry = c.gtk_entry_new().?;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, input_entry), "Message the agent…");
        c.gtk_widget_set_hexpand(input_entry, 1);
        u.append(input_row, input_entry);
        const send_button = u.button("Send");
        u.append(input_row, send_button);
        u.append(root, input_row);

        const status = u.label("Agent ready.");
        c.gtk_widget_add_css_class(status, "agent-status");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_END);
        u.append(root, status);

        return .{
            .app = app,
            .engine = engine,
            .host_state = host_state,
            .root = root,
            .provider_picker = picker,
            .cancel_button = cancel_button,
            .thread_list = thread_list,
            .transcript_view = transcript_view,
            .transcript_buffer = transcript_buffer,
            .end_mark = end_mark,
            .chips_box = chips_box,
            .permission_card = permission_card,
            .permission_tool = permission_tool,
            .permission_summary = permission_summary,
            .review_card = review_card,
            .review_title = review_title,
            .review_files = review_files,
            .skills_entry = skills_entry,
            .skills_results = skills_results,
            .input_entry = input_entry,
            .send_button = send_button,
            .status = status,
            .last_error = last_error,
            .new_button = new_button,
            .close_button = close_button,
            .allow_button = allow_button,
            .deny_button = deny_button,
            .cancel_permission_button = cancel_permission_button,
            .accept_button = accept_button,
            .reject_button = reject_button,
        };
    }

    /// Attach into the dock slot and start the main-loop pump. Call once the
    /// controller is at its stable address (after init's value is stored).
    pub fn attach(self: *Controller, slot: u.W) void {
        self.slot = slot;
        u.append(slot, self.root);
        self.syncWorkspaceRoot();
        u.connect(self.new_button, "clicked", &onNewThread, self);
        u.connect(self.close_button, "clicked", &onClose, self);
        u.connect(self.cancel_button, "clicked", &onCancel, self);
        u.connect(self.send_button, "clicked", &onSend, self);
        u.connect(self.input_entry, "activate", &onSend, self);
        u.connect(self.provider_picker, "notify::selected", &onProviderChanged, self);
        u.connect(self.thread_list, "row-selected", &onRowSelected, self);
        u.connect(self.skills_entry, "changed", &onSkillsChanged, self);
        u.connect(self.allow_button, "clicked", &onAllow, self);
        u.connect(self.deny_button, "clicked", &onDeny, self);
        u.connect(self.cancel_permission_button, "clicked", &onCancelPermission, self);
        u.connect(self.accept_button, "clicked", &onAcceptReview, self);
        u.connect(self.reject_button, "clicked", &onRejectReview, self);
        self.pump_id = c.g_timeout_add(pump_interval_ms, &pump, self);
        self.refreshStatus();
    }

    pub fn deinit(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        if (self.pump_id != 0) _ = c.g_source_remove(self.pump_id);
        self.pump_id = 0;
        for (&self.threads) |*slot| {
            if (slot.*) |t| {
                if (self.engine) |e| e.cancel(t.id);
            }
        }
        if (self.engine) |e| e.deinit();
        self.engine = null;
        if (self.host_state) |hs| {
            hs.deinit();
            a.destroy(hs);
        }
        self.host_state = null;
        for (&self.threads) |*slot| {
            if (slot.*) |t| {
                t.deinit();
                a.destroy(t);
                slot.* = null;
            }
        }
        if (self.skills_query.len > 0) a.free(self.skills_query);
        self.skills_query = "";
        if (self.slot) |slot| c.gtk_box_remove(u.cast(c.GtkBox, slot), self.root);
        c.g_object_unref(self.root);
    }

    /// Workspace changed: cancel running work, drop pending cards and rebind the
    /// host root snapshot. Transcripts are retained; no consent is requested.
    pub fn invalidate(self: *Controller) void {
        if (self.closed) return;
        for (&self.threads) |*slot| {
            const t = slot.* orelse continue;
            if (self.engine) |e| e.cancel(t.id);
            if (t.permission) |p| {
                a.free(p.request_id);
                a.free(p.tool);
                a.free(p.summary);
                t.permission = null;
            }
            if (t.review) |r| {
                a.free(r.review_id);
                a.free(r.title);
                for (r.files) |f| a.free(f);
                a.free(r.files);
                t.review = null;
            }
        }
        self.syncWorkspaceRoot();
        self.renderChips();
        self.renderPermission();
        self.renderReview();
        self.refreshStatus();
    }

    pub fn busy(self: *const Controller) bool {
        for (self.threads) |slot| {
            const t = slot orelse continue;
            switch (t.state) {
                .streaming, .awaiting_permission, .awaiting_review, .cancelling => return true,
                else => {},
            }
        }
        return false;
    }

    pub fn show(self: *Controller) void {
        c.gtk_widget_set_visible(self.root, 1);
        _ = c.gtk_widget_grab_focus(self.input_entry);
    }

    pub fn hide(self: *Controller) void {
        c.gtk_widget_set_visible(self.root, 0);
    }

    pub fn newThread(self: *Controller, opts: NewThread) !void {
        const e = self.engine orelse return error.Closed;
        if (self.thread_count >= max_threads) {
            self.setError("ThreadLimit");
            return error.ThreadLimit;
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var options = opts;
        const root = self.currentRoot();
        if (options.worktree == null) {
            if (root) |r| options.worktree = .{ .root = r };
        }
        var skills_buf: [1][]const u8 = undefined;
        if (options.skills_dirs.len == 0) {
            if (root) |r| {
                skills_buf[0] = try std.fs.path.join(aa, &.{ r, ".coral", "skills" });
                options.skills_dirs = &skills_buf;
            }
        }
        if (options.title.len == 0) {
            options.title = try std.fmt.allocPrint(aa, "Thread {d}", .{self.thread_count + 1});
        }
        const id = try e.newThread(options);
        defer a.free(id);
        const t = try a.create(ThreadUi);
        errdefer a.destroy(t);
        const row = c.gtk_list_box_row_new().?;
        const row_label = u.label(options.title);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, row_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_list_box_row_set_child(u.cast(c.GtkListBoxRow, row), row_label);
        t.* = .{
            .id = try a.dupeSentinel(u8, id, 0),
            .title = try a.dupeSentinel(u8, options.title, 0),
            .provider = try a.dupeSentinel(u8, options.provider.name(), 0),
            .row = row,
            .row_label = row_label,
        };
        c.gtk_list_box_append(u.cast(c.GtkListBox, self.thread_list), row);
        const index = self.freeSlot() orelse unreachable;
        self.threads[index] = t;
        self.thread_count += 1;
        self.selectThread(index);
        self.refreshStatus();
    }

    pub fn send(self: *Controller, thread_id: []const u8, text: []const u8, attachments: []const AttachmentInput) !void {
        const e = self.engine orelse return error.Closed;
        const t = self.findThread(thread_id) orelse return error.UnknownThread;
        const line = std.fmt.allocPrint(a, "\nYou: {s}\n", .{text}) catch return error.OutOfMemory;
        defer a.free(line);
        self.appendTranscript(t, line);
        e.send(thread_id, text, attachments) catch |err| {
            self.setError(@errorName(err));
            return err;
        };
        self.refreshStatus();
    }

    pub fn cancel(self: *Controller, thread_id: []const u8) void {
        const e = self.engine orelse return;
        e.cancel(thread_id);
        self.refreshStatus();
    }

    pub fn respondPermission(self: *Controller, thread_id: []const u8, request_id: []const u8, decision: PermissionResponse) !void {
        const e = self.engine orelse return error.Closed;
        const t = self.findThread(thread_id) orelse return error.UnknownThread;
        const p = t.permission orelse return error.NoPendingPermission;
        if (!std.mem.eql(u8, p.request_id, request_id)) return error.UnknownRequest;
        e.respondPermission(thread_id, request_id, decision) catch |err| {
            self.setError(@errorName(err));
            return err;
        };
        a.free(p.request_id);
        a.free(p.tool);
        a.free(p.summary);
        t.permission = null;
        self.renderPermission();
        self.refreshStatus();
    }

    pub fn acceptReview(self: *Controller, thread_id: []const u8, review_id: []const u8) !void {
        const e = self.engine orelse return error.Closed;
        e.acceptReview(thread_id, review_id) catch |err| {
            self.setError(@errorName(err));
            return err;
        };
        self.refreshStatus();
    }

    pub fn rejectReview(self: *Controller, thread_id: []const u8, review_id: []const u8) !void {
        const e = self.engine orelse return error.Closed;
        e.rejectReview(thread_id, review_id) catch |err| {
            self.setError(@errorName(err));
            return err;
        };
        self.refreshStatus();
    }

    // ---- internals --------------------------------------------------------

    fn syncWorkspaceRoot(self: *Controller) void {
        const hs = self.host_state orelse return;
        hs.setRoot(self.currentRoot());
    }

    fn currentRoot(self: *Controller) ?[]const u8 {
        const model = self.app.browser.model orelse return null;
        for (model.roots) |r| {
            if (r.availability != .available) continue;
            if (r.canonical_path) |p| return p;
        }
        return null;
    }

    fn freeSlot(self: *Controller) ?usize {
        for (self.threads, 0..) |slot, i| {
            if (slot == null) return i;
        }
        return null;
    }

    fn findThread(self: *Controller, id: []const u8) ?*ThreadUi {
        for (self.threads) |slot| {
            const t = slot orelse continue;
            if (std.mem.eql(u8, t.id, id)) return t;
        }
        return null;
    }

    fn activeThread(self: *Controller) ?*ThreadUi {
        const i = self.active orelse return null;
        return self.threads[i];
    }

    fn selectThread(self: *Controller, index: usize) void {
        if (index >= max_threads) return;
        const t = self.threads[index] orelse return;
        self.active = index;
        c.gtk_list_box_select_row(u.cast(c.GtkListBox, self.thread_list), @ptrCast(t.row));
        self.setBufferText(t.transcript.items);
        self.scrollEnd();
        self.renderChips();
        self.renderPermission();
        self.renderReview();
        self.refreshStatus();
    }

    fn appendTranscript(self: *Controller, t: *ThreadUi, text: []const u8) void {
        t.transcript.appendSlice(a, text) catch return;
        var trimmed = false;
        if (t.transcript.items.len > transcript_limit) {
            const drop = t.transcript.items.len - transcript_limit;
            std.mem.copyForwards(u8, t.transcript.items[0..transcript_limit], t.transcript.items[drop..]);
            t.transcript.shrinkRetainingCapacity(transcript_limit);
            trimmed = true;
        }
        if (self.activeThread() == t) {
            if (trimmed) {
                self.setBufferText(t.transcript.items);
            } else {
                var iter: c.GtkTextIter = undefined;
                c.gtk_text_buffer_get_end_iter(self.transcript_buffer, &iter);
                const z = u.z(text);
                defer a.free(z);
                c.gtk_text_buffer_insert(self.transcript_buffer, &iter, z.ptr, -1);
            }
            self.scrollEnd();
        }
    }

    fn setBufferText(self: *Controller, text: []const u8) void {
        const z = u.z(text);
        defer a.free(z);
        c.gtk_text_buffer_set_text(self.transcript_buffer, z.ptr, -1);
    }

    fn scrollEnd(self: *Controller) void {
        c.gtk_text_view_scroll_to_mark(u.cast(c.GtkTextView, self.transcript_view), self.end_mark, 0, 0, 0, 0);
    }

    fn renderChips(self: *Controller) void {
        c.gtk_flow_box_remove_all(u.cast(c.GtkFlowBox, self.chips_box));
        const t = self.activeThread() orelse return;
        for (t.attachments.items, 0..) |chip, i| {
            const box = u.box(true, 2);
            c.gtk_widget_add_css_class(box, "agent-chip");
            const text = std.fmt.allocPrint(a, "{s}:{s}", .{ chip.kind.label(), chip.label }) catch continue;
            defer a.free(text);
            u.append(box, u.label(text));
            const remove = u.icon("window-close-symbolic", "Remove attachment");
            c.gtk_widget_add_css_class(remove, "flat");
            c.g_object_set_data(@ptrCast(remove), "chip", @ptrFromInt(i + 1));
            u.connect(remove, "clicked", &onChipRemove, self);
            u.append(box, remove);
            c.gtk_flow_box_append(u.cast(c.GtkFlowBox, self.chips_box), box);
        }
    }

    fn removeChip(self: *Controller, index: usize) void {
        const t = self.activeThread() orelse return;
        if (index >= t.attachments.items.len) return;
        const chip = t.attachments.orderedRemove(index);
        a.free(chip.label);
        a.free(chip.content);
        self.renderChips();
    }

    fn renderPermission(self: *Controller) void {
        const t = self.activeThread();
        const p = if (t) |tt| tt.permission else null;
        if (p) |perm| {
            const title = std.fmt.allocPrint(a, "Permission required · {s}", .{perm.tool}) catch return;
            defer a.free(title);
            u.setLabel(self.permission_tool, title);
            u.setLabel(self.permission_summary, perm.summary);
            c.gtk_widget_set_visible(self.permission_card, 1);
        } else {
            c.gtk_widget_set_visible(self.permission_card, 0);
        }
    }

    fn renderReview(self: *Controller) void {
        const t = self.activeThread();
        const r = if (t) |tt| tt.review else null;
        if (r) |rev| {
            const title = std.fmt.allocPrint(a, "Review · {s} ({d} files)", .{ rev.title, rev.file_count }) catch return;
            defer a.free(title);
            u.setLabel(self.review_title, title);
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(a);
            for (rev.files) |f| list.print(a, "{s}\n", .{f}) catch {};
            u.setLabel(self.review_files, list.items);
            c.gtk_widget_set_visible(self.review_card, 1);
        } else {
            c.gtk_widget_set_visible(self.review_card, 0);
        }
    }

    /// Read the proposal's file paths under the Engine mutex (the backend keeps
    /// proposals there; there is no public accessor and the engine is not edited).
    fn reviewFiles(self: *Controller, review_id: []const u8) [][:0]u8 {
        const e = self.engine orelse return &.{};
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        var list: std.ArrayList([:0]u8) = .empty;
        for (e.proposals.items) |p| {
            if (std.mem.eql(u8, p.id, review_id)) {
                for (p.files) |f| list.append(a, u.z(f.path)) catch {};
                break;
            }
        }
        return list.toOwnedSlice(a) catch &.{};
    }

    fn refreshThreadRow(self: *Controller, t: *ThreadUi) void {
        _ = self;
        const text = std.fmt.allocPrint(a, "{s} · {s}", .{ t.title, t.state.label() }) catch return;
        defer a.free(text);
        u.setLabel(t.row_label, text);
    }

    fn refreshStatus(self: *Controller) void {
        for (self.threads) |slot| {
            if (slot) |t| self.refreshThreadRow(t);
        }
        const is_busy = self.busy();
        c.gtk_widget_set_sensitive(self.cancel_button, @intFromBool(is_busy));
        c.gtk_widget_set_sensitive(self.send_button, @intFromBool(self.activeThread() != null and !is_busy));
        var buf: [256]u8 = undefined;
        const text = if (self.activeThread()) |t|
            std.fmt.bufPrint(&buf, "{s} · {s} · {d}/{d} threads", .{ t.title, t.state.label(), self.thread_count, max_threads }) catch "Agent"
        else
            std.fmt.bufPrint(&buf, "Agent · {d}/{d} threads", .{ self.thread_count, max_threads }) catch "Agent";
        u.setLabel(self.status, text);
    }

    fn setError(self: *Controller, name: []const u8) void {
        self.last_error = name;
        std.log.scoped(.agent).warn("agent error: {s}", .{name});
    }

    fn pickerSelection(self: *Controller) ProviderSelection {
        const idx = c.gtk_drop_down_get_selected(u.cast(c.GtkDropDown, self.provider_picker));
        return switch (idx) {
            1 => .{ .openai = .{ .base_url = if (self.engine) |e| (e.auth_config.baseUrl("openai") orelse "") else "" } },
            2 => .{ .acp = .{ .argv = &.{} } },
            else => .{ .fake = .{} },
        };
    }

    fn setProviderByName(self: *Controller, name: []const u8) void {
        const idx: c.guint = if (std.mem.eql(u8, name, "openai")) 1 else if (std.mem.eql(u8, name, "acp")) 2 else 0;
        c.gtk_drop_down_set_selected(u.cast(c.GtkDropDown, self.provider_picker), idx);
        self.applyProvider();
    }

    fn applyProvider(self: *Controller) void {
        const sel = self.pickerSelection();
        if (self.activeThread()) |t| {
            if (self.engine) |e| {
                e.setProvider(t.id, sel) catch |err| {
                    self.setError(@errorName(err));
                    self.refreshStatus();
                    return;
                };
            }
            a.free(t.provider);
            t.provider = u.z(sel.name());
            self.refreshThreadRow(t);
        }
        self.refreshStatus();
    }

    fn sendActive(self: *Controller, text: []const u8) void {
        const t = self.activeThread() orelse {
            self.setError("NoThread");
            return;
        };
        if (text.len == 0) return;
        var inputs: std.ArrayList(AttachmentInput) = .empty;
        defer inputs.deinit(a);
        for (t.attachments.items) |chip| {
            inputs.append(a, .{ .kind = chip.kind, .label = chip.label, .content = chip.content }) catch {};
        }
        self.send(t.id, text, inputs.items) catch return;
        for (t.attachments.items) |chip| {
            a.free(chip.label);
            a.free(chip.content);
        }
        t.attachments.clearRetainingCapacity();
        self.renderChips();
        c.gtk_editable_set_text(u.cast(c.GtkEditable, self.input_entry), "");
    }

    fn updateSkills(self: *Controller) void {
        const query = u.entryText(self.skills_entry);
        if (self.skills_query.len > 0) a.free(self.skills_query);
        self.skills_query = u.z(query);
        self.skills_matches = 0;
        const t = self.activeThread();
        const e = self.engine;
        if (t == null or e == null or query.len == 0) {
            u.setLabel(self.skills_results, "");
            return;
        }
        const matches = e.?.searchSkills(t.?.id, query) catch |err| {
            self.setError(@errorName(err));
            u.setLabel(self.skills_results, "");
            return;
        };
        defer a.free(matches);
        self.skills_matches = matches.len;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        out.print(a, "{d} skill match(es)", .{matches.len}) catch {};
        for (matches, 0..) |m, i| {
            if (i >= 8) break;
            out.print(a, "\n#{d} · score {d}", .{ m.index, m.score }) catch {};
        }
        u.setLabel(self.skills_results, out.items);
    }

    fn handleEvent(self: *Controller, event: Event) void {
        switch (event) {
            .state => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    t.state = v.state;
                    self.refreshThreadRow(t);
                }
            },
            .delta => |v| {
                if (self.findThread(v.thread_id)) |t| self.appendTranscript(t, v.text);
            },
            .message_done => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    t.messages += 1;
                    self.appendTranscript(t, "\n");
                }
            },
            .tool_started => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    const line = std.fmt.allocPrint(a, "\n[tool] {s}…\n", .{v.tool}) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                }
            },
            .tool_finished => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    const shown = if (v.output.len > tool_output_display) v.output[0..tool_output_display] else v.output;
                    const line = std.fmt.allocPrint(a, "[tool] {s} {s}: {s}\n", .{ v.tool, if (v.ok) "ok" else "failed", shown }) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                }
            },
            .permission_request => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    if (t.permission) |old| {
                        a.free(old.request_id);
                        a.free(old.tool);
                        a.free(old.summary);
                    }
                    t.permission = .{
                        .request_id = u.z(v.request_id),
                        .tool = u.z(v.tool),
                        .summary = u.z(v.summary),
                    };
                    const line = std.fmt.allocPrint(a, "\n[permission] {s}: {s}\n", .{ v.tool, v.summary }) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                    if (self.activeThread() == t) self.renderPermission();
                }
            },
            .review_proposed => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    if (t.review) |old| {
                        a.free(old.review_id);
                        a.free(old.title);
                        for (old.files) |f| a.free(f);
                        a.free(old.files);
                    }
                    t.review = .{
                        .review_id = u.z(v.review_id),
                        .title = u.z(v.title),
                        .file_count = v.file_count,
                        .files = self.reviewFiles(v.review_id),
                    };
                    const line = std.fmt.allocPrint(a, "\n[review] {s} ({d} files)\n", .{ v.title, v.file_count }) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                    if (self.activeThread() == t) self.renderReview();
                }
            },
            .review_resolved => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    if (t.review) |r| {
                        a.free(r.review_id);
                        a.free(r.title);
                        for (r.files) |f| a.free(f);
                        a.free(r.files);
                        t.review = null;
                    }
                    const line = std.fmt.allocPrint(a, "[review] {s}\n", .{@tagName(v.state)}) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                    if (self.activeThread() == t) self.renderReview();
                }
            },
            .acp_update => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    const shown = if (v.json.len > tool_output_display) v.json[0..tool_output_display] else v.json;
                    const line = std.fmt.allocPrint(a, "[acp] {s}\n", .{shown}) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                }
            },
            .cancelled => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    t.state = .cancelled;
                    self.appendTranscript(t, "\n[cancelled]\n");
                    self.refreshThreadRow(t);
                }
            },
            .failed => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    t.state = .failed;
                    const line = std.fmt.allocPrint(a, "\n[error] {s}\n", .{v.message}) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                    self.refreshThreadRow(t);
                }
            },
            .disclosure => |v| {
                if (self.findThread(v.thread_id)) |t| {
                    const line = std.fmt.allocPrint(a, "[context] {s}\n", .{v.text}) catch return;
                    defer a.free(line);
                    self.appendTranscript(t, line);
                }
            },
        }
    }

    /// Main-loop pump: the ONLY place worker-produced Events become GTK state.
    fn pump(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        if (self.closed) return 0;
        const e = self.engine orelse return 1;
        while (e.pollEvent()) |event| {
            self.handleEvent(event);
            e.freeEvent(event);
        }
        self.refreshStatus();
        return 1;
    }

    // ---- signal callbacks (GTK main thread) -------------------------------

    fn onNewThread(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.newThread(.{ .provider = self.pickerSelection() }) catch |err| self.setError(@errorName(err));
    }

    fn onSend(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.sendActive(u.entryText(self.input_entry));
    }

    fn onCancel(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        if (self.activeThread()) |t| self.cancel(t.id);
    }

    fn onClose(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.hide();
    }

    fn onProviderChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.applyProvider();
    }

    fn onRowSelected(_: ?*c.GtkListBox, row: ?*c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        const r = row orelse return;
        for (self.threads, 0..) |slot, i| {
            const t = slot orelse continue;
            if (t.row == @as(u.W, @ptrCast(r))) {
                if (self.active != i) self.selectThread(i);
                return;
            }
        }
    }

    fn onSkillsChanged(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.updateSkills();
    }

    fn onChipRemove(widget: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        const raw = c.g_object_get_data(@ptrCast(widget), "chip");
        const index = @intFromPtr(raw) -| 1;
        self.removeChip(index);
    }

    fn onAllow(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.answerPermission(.allow);
    }

    fn onDeny(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.answerPermission(.deny);
    }

    fn onCancelPermission(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.answerPermission(.cancel);
    }

    fn answerPermission(self: *Controller, decision: PermissionResponse) void {
        const t = self.activeThread() orelse return;
        const p = t.permission orelse return;
        self.respondPermission(t.id, p.request_id, decision) catch |err| self.setError(@errorName(err));
    }

    fn onAcceptReview(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        const t = self.activeThread() orelse return;
        const r = t.review orelse return;
        self.acceptReview(t.id, r.review_id) catch |err| self.setError(@errorName(err));
    }

    fn onRejectReview(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        const t = self.activeThread() orelse return;
        const r = t.review orelse return;
        self.rejectReview(t.id, r.review_id) catch |err| self.setError(@errorName(err));
    }

    // ---- probe / fixtures (test hooks only) -------------------------------

    /// Print `CORAL_AGENT {json}` describing the live panel and backend state.
    pub fn probe(self: *Controller) void {
        if (!test_hooks) return;
        const ThreadView = struct {
            id: []const u8,
            title: []const u8,
            provider: []const u8,
            state: []const u8,
            transcript_bytes: usize,
            messages: usize,
            attachments: usize,
            permission: ?struct { request_id: []const u8, tool: []const u8, summary: []const u8 },
            review: ?struct { review_id: []const u8, title: []const u8, file_count: usize, files: []const [:0]u8 },
        };
        var views: std.ArrayList(ThreadView) = .empty;
        defer views.deinit(a);
        for (self.threads) |slot| {
            const t = slot orelse continue;
            views.append(a, .{
                .id = t.id,
                .title = t.title,
                .provider = t.provider,
                .state = t.state.label(),
                .transcript_bytes = t.transcript.items.len,
                .messages = t.messages,
                .attachments = t.attachments.items.len,
                .permission = if (t.permission) |p| .{ .request_id = p.request_id, .tool = p.tool, .summary = p.summary } else null,
                .review = if (t.review) |r| .{ .review_id = r.review_id, .title = r.title, .file_count = r.file_count, .files = r.files } else null,
            }) catch unreachable;
        }
        var host_root: ?[:0]u8 = null;
        var reads: usize = 0;
        var writes: usize = 0;
        var spawns: usize = 0;
        var kills: usize = 0;
        var searches: usize = 0;
        var diffs: usize = 0;
        if (self.host_state) |hs| {
            hs.mutex.lockUncancelable(hs.io);
            host_root = if (hs.root) |r| a.dupeSentinel(u8, r, 0) catch null else null;
            reads = hs.read_count;
            writes = hs.write_count;
            spawns = hs.spawn_count;
            kills = hs.kill_count;
            searches = hs.search_count;
            diffs = hs.diff_count;
            hs.mutex.unlock(hs.io);
        }
        defer if (host_root) |r| a.free(r);
        const ProviderProbe = struct { name: []const u8, ok: bool, detail: []const u8 };
        var providers: [3]ProviderProbe = undefined;
        if (self.engine) |e| {
            for (provider_names, 0..) |name, i| {
                const res = e.probe(name) catch engine_mod.ProbeResult{ .ok = false, .detail = "probe failed" };
                providers[i] = .{ .name = name, .ok = res.ok, .detail = res.detail };
            }
        } else {
            for (provider_names, 0..) |name, i| providers[i] = .{ .name = name, .ok = false, .detail = "engine unavailable" };
        }
        const text = std.json.Stringify.valueAlloc(a, .{
            .ok = self.engine != null,
            .count = self.thread_count,
            .limit = @as(usize, max_threads),
            .transcript_limit = @as(usize, transcript_limit),
            .attachment_limit = @as(usize, max_attachments),
            .active = if (self.activeThread()) |t| t.id else null,
            .busy = self.busy(),
            .closed = self.closed,
            .visible = c.gtk_widget_get_visible(self.root) != 0,
            .provider = provider_names[@min(c.gtk_drop_down_get_selected(u.cast(c.GtkDropDown, self.provider_picker)), 2)],
            .last_error = self.last_error,
            .host = .{
                .root = host_root,
                .read = reads,
                .write = writes,
                .spawn = spawns,
                .kill = kills,
                .search = searches,
                .diff = diffs,
            },
            .threads = views.items,
            .skills = .{ .query = self.skills_query, .matches = self.skills_matches },
            .providers = providers,
        }, .{}) catch unreachable;
        defer a.free(text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_AGENT %s\n", z.ptr);
    }

    /// Test-only fixture dispatch. Returns true when the action was handled.
    /// Fixtures drive the real widgets/workflows; they never grant trust or
    /// bypass a tool permission or review.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!test_hooks) return false;
        if (std.mem.eql(u8, action, "agent-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "agent-show")) {
            self.show();
        } else if (std.mem.eql(u8, action, "agent-new-thread")) {
            self.newThread(.{ .title = value, .provider = self.pickerSelection() }) catch |err| self.setError(@errorName(err));
        } else if (std.mem.eql(u8, action, "agent-send")) {
            const text = if (value.len > 0) value else u.entryText(self.input_entry);
            self.sendActive(text);
        } else if (std.mem.eql(u8, action, "agent-cancel")) {
            const t = self.findThread(value) orelse self.activeThread();
            if (t) |tt| self.cancel(tt.id);
        } else if (std.mem.eql(u8, action, "agent-allow")) {
            self.answerPermission(.allow);
        } else if (std.mem.eql(u8, action, "agent-deny")) {
            self.answerPermission(.deny);
        } else if (std.mem.eql(u8, action, "agent-accept-review")) {
            if (self.activeThread()) |t| {
                if (t.review) |r| self.acceptReview(t.id, r.review_id) catch |err| self.setError(@errorName(err));
            }
        } else if (std.mem.eql(u8, action, "agent-reject-review")) {
            if (self.activeThread()) |t| {
                if (t.review) |r| self.rejectReview(t.id, r.review_id) catch |err| self.setError(@errorName(err));
            }
        } else if (std.mem.eql(u8, action, "agent-select-thread")) {
            if (std.fmt.parseInt(usize, value, 10)) |idx| {
                self.selectThread(idx);
            } else |_| {
                if (self.findThread(value)) |t| {
                    for (self.threads, 0..) |slot, i| {
                        if (slot == t) {
                            self.selectThread(i);
                            break;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, action, "agent-set-provider")) {
            self.setProviderByName(value);
        } else if (std.mem.eql(u8, action, "agent-close")) {
            self.hide();
        } else {
            return false;
        }
        return true;
    }
};
