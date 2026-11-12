//! M5 production terminal controller. Owns bounded terminal sessions (tabs),
//! the workspace-trust permit revalidation, and the ONLY waitpid reaper
//! (via the worker Job). The workspace is always trusted, so a user action
//! spawns a session directly with no disclosure prompt. libghostty-vt holds VT
//! state; surface.zig draws and translates input; pty.zig spawns and owns the
//! process group. Terminal output has no action authority: title/pwd metadata
//! only updates labels.
//!
//! Thread boundary: the worker starts and waits on the PTY; the GTK main thread
//! reads the master through a GIO watch and feeds ghostty_terminal_vt_write.
//! Cancellation/reaping never blocks the UI thread: a bounded timeout finalizes
//! sessions once the worker publishes completion.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
const App = @import("../app.zig").App;
const pty = @import("pty.zig");
const g = @import("ghostty.zig");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const test_hooks = @import("build_options").test_hooks;

pub const max_sessions: usize = 8;
const default_cols: u16 = 80;
const default_rows: u16 = 24;
const env_capacity = 24;
/// Bounded outbound PTY queue. Input/effects enqueue without blocking the GTK
/// main thread; a POLLOUT GIO watch drains it. Overflow is dropped.
const out_capacity = 64 * 1024;

const env_allowlist = [_][:0]const u8{
    "PATH",    "HOME",            "LANG",            "LC_ALL",          "LC_CTYPE",       "USER",           "LOGNAME",       "SHELL",
    "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "TZ",
};

pub const Phase = enum { starting, running, exited, closing };

/// Worker-owned spawn/wait. Stable address from start through finish. The UI
/// thread cancels; the worker is the sole waiter (Coral owns only waitpid).
const Job = struct {
    config: pty.Config,
    /// Written by the worker before phase becomes non-zero; read by the main
    /// thread only after ready() (the seq_cst phase publish synchronizes it).
    handle: ?pty.Pty = null,
    failure: ?pty.Error = null,
    phase: std.atomic.Value(u8) = .init(0), // 0 starting, 1 running, 2 complete
    /// Set by cancel() on the main thread; re-checked by the worker after it
    /// publishes the handle so a cancel that races with spawn is not lost.
    cancelled: std.atomic.Value(bool) = .init(false),
    thread: ?*c.GThread = null,

    fn start(self: *Job) void {
        self.thread = c.g_thread_new("coral-terminal", work, self);
    }
    fn work(data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.handle = pty.start(self.config) catch |err| {
            self.failure = err;
            self.phase.store(2, .seq_cst);
            return null;
        };
        // Publish the fully-constructed handle before any main-thread access.
        self.phase.store(1, .seq_cst);
        // Re-cancel after publish (mirrors tasks/process.zig spawnReady): a
        // cancel may have arrived during spawn, before the handle was visible.
        // seq_cst on phase+cancelled orders the store/load pair so neither side
        // can miss the other; ownership.cancel is idempotent.
        if (self.cancelled.load(.seq_cst)) self.handle.?.cancel();
        _ = self.handle.?.wait();
        self.phase.store(2, .seq_cst);
        return null;
    }
    fn ready(self: *const Job) bool {
        return self.phase.load(.seq_cst) != 0;
    }
    fn done(self: *const Job) bool {
        return self.phase.load(.seq_cst) == 2;
    }
    fn cancel(self: *Job) void {
        self.cancelled.store(true, .seq_cst);
        // If the handle is already published, cancel it now; otherwise the
        // worker applies the cancel after publish. Both may run (idempotent).
        if (self.ready()) {
            if (self.handle) |*handle| handle.cancel();
        }
    }
    /// Joins the worker and reaps the PTY. The caller must have cancelled (or
    /// observed done()) first, so the join never waits on a live command: the
    /// worker re-cancel guarantees completion within the ownership grace.
    fn finish(self: *Job) ?pty.Report {
        if (self.thread) |thread| _ = c.g_thread_join(thread);
        self.thread = null;
        if (self.handle) |*handle| {
            const report = handle.completion;
            handle.deinit();
            self.handle = null;
            return report;
        }
        return null;
    }
};

const Session = struct {
    id: u64,
    controller: *Controller,
    surface: Surface,
    job: Job,
    phase: Phase = .starting,
    eof: bool = false,
    finalized: bool = false,
    report: ?pty.Report = null,
    exit_code: ?i32 = null,
    signal: ?i32 = null,
    title: [:0]u8,
    pwd: [:0]u8,
    stack_name: [:0]u8,
    tab: ?u.W = null,
    channel: ?*c.GIOChannel = null,
    watch_id: c_uint = 0,
    // Nonblocking outbound queue (main thread only) drained by a POLLOUT watch.
    out_ring: [out_capacity]u8 = undefined,
    out_head: usize = 0,
    out_tail: usize = 0,
    out_count: usize = 0,
    out_watch_id: c_uint = 0,
    // Owned spawn metadata. The pointer arrays live in the Session so the
    // asynchronously-started worker never borrows freed stack storage.
    shell: [:0]u8,
    cwd: [:0]u8,
    argv_ptrs: [2]?[*:0]const u8,
    env_storage: [env_capacity][:0]u8 = undefined,
    env_ptrs: [env_capacity + 1]?[*:0]const u8 = undefined,
    env_len: usize = 0,

    fn hooks(self: *Session) surface_mod.Hooks {
        return .{
            .context = self,
            .write_pty = &writePty,
            .resize_pty = &resizePty,
            .title_changed = &titleChanged,
            .pwd_changed = &pwdChanged,
        };
    }
    fn writePty(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (self.phase == .exited or self.phase == .closing) return;
        if (!self.job.ready()) return;
        self.enqueueOut(bytes);
        if (self.drainOut()) self.ensureOutWatch() else self.removeOutWatch();
    }
    fn resizePty(ctx: *anyopaque, cols: u16, rows: u16) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (!self.job.ready()) return;
        if (self.job.handle) |*handle| handle.resize(rows, cols) catch {};
    }
    /// Append to the bounded ring; drop bytes that do not fit (overflow).
    fn enqueueOut(self: *Session, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.out_count == out_capacity) return;
            self.out_ring[self.out_tail] = byte;
            self.out_tail = (self.out_tail + 1) % out_capacity;
            self.out_count += 1;
        }
    }
    /// Nonblocking flush. Returns true if data remains blocked (EAGAIN).
    fn drainOut(self: *Session) bool {
        if (self.phase == .exited or self.phase == .closing) {
            self.out_count = 0;
            return false;
        }
        if (!self.job.ready()) return false;
        const handle = &(self.job.handle orelse return false);
        while (self.out_count > 0) {
            const seg = @min(self.out_count, out_capacity - self.out_head);
            const n = handle.write(self.out_ring[self.out_head..][0..seg]) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => {
                    self.out_count = 0;
                    return false;
                },
            };
            if (n == 0) return true;
            self.out_head = (self.out_head + n) % out_capacity;
            self.out_count -= n;
        }
        return false;
    }
    fn ensureOutWatch(self: *Session) void {
        if (self.out_watch_id != 0) return;
        const channel = self.channel orelse return;
        self.out_watch_id = c.g_io_add_watch(channel, c.G_IO_OUT, &outWritable, self);
    }
    fn removeOutWatch(self: *Session) void {
        if (self.out_watch_id != 0) {
            _ = c.g_source_remove(self.out_watch_id);
            self.out_watch_id = 0;
        }
    }
    fn outWritable(_: ?*c.GIOChannel, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Session = @ptrCast(@alignCast(data.?));
        if (self.drainOut()) return 1; // G_SOURCE_CONTINUE
        self.out_watch_id = 0; // G_SOURCE_REMOVE lets GLib drop the watch
        return 0;
    }
    fn titleChanged(ctx: *anyopaque, title: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const bounded = title[0..@min(title.len, 256)];
        const z = a.dupeSentinel(u8, bounded, 0) catch return;
        a.free(self.title);
        self.title = z;
        self.controller.refreshTab(self);
    }
    fn pwdChanged(ctx: *anyopaque, pwd: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        const bounded = pwd[0..@min(pwd.len, 4096)];
        const z = a.dupeSentinel(u8, bounded, 0) catch return;
        a.free(self.pwd);
        self.pwd = z;
    }
    fn freeSpawnMetadata(self: *Session) void {
        a.free(self.title);
        a.free(self.pwd);
        a.free(self.stack_name);
        a.free(self.shell);
        a.free(self.cwd);
        for (self.env_storage[0..self.env_len]) |entry| a.free(entry);
        self.env_len = 0;
    }
};

pub const Controller = struct {
    app: *App,
    root: u.W,
    tab_bar: u.W,
    stack: u.W,
    status: u.W,
    slot: ?u.W = null,
    sessions: [max_sessions]?*Session = @splat(null),
    active: ?usize = null,
    next_id: u64 = 1,
    closed: bool = false,
    timeout_id: c_uint = 0,
    last_error: ?[]const u8 = null,
    spawned: u64 = 0,
    reaped: u64 = 0,
    // Last editor font size pushed to session surfaces; the reaper tick compares
    // it against the live app setting so font changes recompute cell metrics.
    applied_font: c_int = 0,

    pub fn init(app: *App) Controller {
        const root = u.box(false, 0);
        _ = c.g_object_ref_sink(root);
        c.gtk_widget_add_css_class(root, "terminal");
        c.gtk_widget_set_hexpand(root, 1);
        c.gtk_widget_set_vexpand(root, 1);

        const tab_bar = u.box(true, 2);
        c.gtk_widget_add_css_class(tab_bar, "terminal-tabs");
        u.append(root, tab_bar);

        const stack = c.gtk_stack_new().?;
        c.gtk_widget_set_hexpand(stack, 1);
        c.gtk_widget_set_vexpand(stack, 1);
        u.append(root, stack);

        const status = u.label("Terminal");
        c.gtk_widget_add_css_class(status, "terminal-status");
        u.append(root, status);

        return .{
            .app = app,
            .root = root,
            .tab_bar = tab_bar,
            .stack = stack,
            .status = status,
        };
    }

    /// Attach the controller widget into the dock's terminal slot and start the
    /// bounded reaper timeout. Call once the controller is at its stable address.
    pub fn attach(self: *Controller, slot: u.W) void {
        self.slot = slot;
        u.append(slot, self.root);
        self.timeout_id = c.g_timeout_add(50, &reapTick, self);
        self.refresh();
    }

    pub fn focusWidget(self: *Controller) void {
        if (self.activeSession()) |session| session.surface.focus();
    }

    fn activeSession(self: *Controller) ?*Session {
        const index = self.active orelse return null;
        return self.sessions[index];
    }

    fn count(self: *const Controller) usize {
        var n: usize = 0;
        for (self.sessions) |slot| if (slot != null) {
            n += 1;
        };
        return n;
    }

    fn freeSlot(self: *Controller) ?usize {
        for (self.sessions, 0..) |slot, i| if (slot == null) return i;
        return null;
    }

    /// Request a new session. The workspace is always trusted, so a user action
    /// spawns directly with no disclosure prompt. The capability permit is still
    /// re-validated at the spawn boundary. Records last_error when gated.
    pub fn newSession(self: *Controller) !void {
        if (self.closed) return error.Closed;
        if (self.count() >= max_sessions) {
            self.last_error = "SessionLimit";
            self.refresh();
            return error.SessionLimit;
        }
        try self.spawn();
    }

    fn spawn(self: *Controller) !void {
        // Re-validate the capability at the actual spawn boundary (covers new
        // and restart paths); trust is a precondition, not a per-command approval.
        _ = self.app.workspace_policy.issue(.tasks) catch {
            self.last_error = "restricted";
            self.refresh();
            return error.Restricted;
        };
        const index = self.freeSlot() orelse return error.SessionLimit;
        const model = self.app.browser.model orelse return error.NoWorkspace;
        if (model.roots.len == 0) return error.NoWorkspace;
        const root_path = model.roots[0].canonical_path orelse model.roots[0].lexical_path;

        const session = a.create(Session) catch return error.OutOfMemory;
        errdefer a.destroy(session);
        session.* = .{
            .id = self.next_id,
            .controller = self,
            .surface = undefined,
            .job = undefined,
            .title = a.dupeSentinel(u8, "Terminal", 0) catch return error.OutOfMemory,
            .pwd = a.dupeSentinel(u8, "", 0) catch return error.OutOfMemory,
            .stack_name = u.fmt("session-{d}", .{self.next_id}),
            .shell = a.dupeSentinel(u8, userShell(), 0) catch return error.OutOfMemory,
            .cwd = a.dupeSentinel(u8, root_path, 0) catch return error.OutOfMemory,
            .argv_ptrs = .{ null, null },
        };
        self.next_id += 1;
        errdefer session.freeSpawnMetadata();

        buildEnv(session);
        session.argv_ptrs[0] = session.shell.ptr;
        session.argv_ptrs[1] = null;

        session.surface = Surface.init(session.hooks(), default_cols, default_rows) catch |err| return err;
        errdefer session.surface.deinit();
        // Follow the application editor font (family + size) from the start.
        session.surface.setFont(surface_mod.editor_font_family, self.app.settings.font);
        session.surface.attach();

        session.job = .{ .config = .{
            .authorization = .approved,
            .argv = session.argv_ptrs[0..1 :null],
            .environment = session.env_ptrs[0..session.env_len :null],
            .cwd = session.cwd,
            .rows = default_rows,
            .columns = default_cols,
        } };
        session.job.start();

        self.sessions[index] = session;
        self.active = index;
        self.spawned += 1;
        self.applied_font = self.app.settings.font;
        _ = c.gtk_stack_add_named(u.cast(c.GtkStack, self.stack), session.surface.widget, session.stack_name);
        c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.stack), session.stack_name);
        self.refresh();
        session.surface.focus();
    }

    pub fn closeActive(self: *Controller) void {
        const index = self.active orelse return;
        self.closeIndex(index);
    }

    fn closeIndex(self: *Controller, index: usize) void {
        const session = self.sessions[index] orelse return;
        if (session.phase == .closing) return;
        if (session.finalized) {
            // Already exited and reaped: destroy immediately.
            self.destroySession(session, index);
            return;
        }
        session.phase = .closing;
        session.job.cancel();
        self.refresh();
    }

    pub fn restartActive(self: *Controller) void {
        const index = self.active orelse return;
        const session = self.sessions[index] orelse return;
        if (session.phase == .closing) return;
        _ = self.app.workspace_policy.issue(.tasks) catch {
            self.last_error = "restricted";
            self.refresh();
            return;
        };
        session.phase = .closing;
        session.job.cancel();
        self.spawn() catch |err| {
            self.last_error = @errorName(err);
        };
        self.refresh();
    }

    pub fn cancelActive(self: *Controller) void {
        const index = self.active orelse return;
        // Cancel stops the command and reaps/removes the session.
        self.closeIndex(index);
    }

    fn setActive(self: *Controller, index: usize) void {
        const session = self.sessions[index] orelse return;
        self.active = index;
        c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.stack), session.stack_name);
        self.refresh();
        session.surface.focus();
    }

    fn tabClicked(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const session: *Session = @ptrCast(@alignCast(data.?));
        const self = session.controller;
        for (self.sessions, 0..) |slot, i| if (slot == session) {
            self.setActive(i);
        };
    }

    fn refreshTab(self: *Controller, session: *Session) void {
        if (session.tab) |tab| {
            const label = u.fmt("{s}", .{session.title});
            defer a.free(label);
            c.gtk_button_set_label(u.cast(c.GtkButton, tab), label);
        }
        self.refreshStatus();
    }

    fn refresh(self: *Controller) void {
        var child = c.gtk_widget_get_first_child(self.tab_bar);
        while (child) |widget| {
            const next = c.gtk_widget_get_next_sibling(widget);
            c.gtk_box_remove(u.cast(c.GtkBox, self.tab_bar), widget);
            child = next;
        }
        for (self.sessions, 0..) |slot, i| {
            const session = slot orelse continue;
            const label = u.fmt("{s}", .{session.title});
            defer a.free(label);
            const tab = u.button(label);
            c.gtk_widget_add_css_class(tab, "terminal-tab");
            if (self.active == i) c.gtk_widget_add_css_class(tab, "active");
            u.connect(tab, "clicked", &tabClicked, session);
            session.tab = tab;
            u.append(self.tab_bar, tab);
        }
        const new_button = u.icon("list-add-symbolic", "New terminal");
        u.connect(new_button, "clicked", &newClicked, self);
        u.append(self.tab_bar, new_button);
        const close_button = u.icon("window-close-symbolic", "Close terminal");
        u.connect(close_button, "clicked", &closeClicked, self);
        u.append(self.tab_bar, close_button);
        const restart_button = u.icon("view-refresh-symbolic", "Restart terminal");
        u.connect(restart_button, "clicked", &restartClicked, self);
        u.append(self.tab_bar, restart_button);
        self.refreshStatus();
    }

    fn newClicked(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.newSession() catch {};
    }
    fn closeClicked(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.closeActive();
    }
    fn restartClicked(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        self.restartActive();
    }

    fn refreshStatus(self: *Controller) void {
        const session = self.activeSession();
        const text = if (session) |s| blk: {
            const state = @tagName(s.phase);
            const exit = if (s.exit_code) |code| u.fmt(" · exit {d}", .{code}) else if (s.signal) |sig| u.fmt(" · signal {d}", .{sig}) else u.fmt("", .{});
            defer a.free(exit);
            break :blk u.fmt("Terminal {d} · {s}{s} · {d}x{d}", .{ s.id, state, exit, s.surface.cols, s.surface.rows_count });
        } else u.fmt("Terminal · {d}/{d} sessions", .{ self.count(), max_sessions });
        defer a.free(text);
        u.setLabel(self.status, text);
    }

    /// Attach the GIO reader once the worker has published the PTY handle.
    fn ensureReader(self: *Controller, session: *Session) void {
        _ = self;
        if (session.channel != null or !session.job.ready()) return;
        const handle = &(session.job.handle orelse return);
        const channel = c.g_io_channel_unix_new(handle.master) orelse return;
        _ = c.g_io_channel_set_encoding(channel, null, null);
        c.g_io_channel_set_buffered(channel, 0);
        c.g_io_channel_set_close_on_unref(channel, 0); // pty.zig owns the fd
        session.channel = channel;
        session.watch_id = c.g_io_add_watch(channel, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, &readReady, session);
        session.phase = .running;
    }

    fn readReady(channel: ?*c.GIOChannel, condition: c_uint, data: ?*anyopaque) callconv(.c) c_int {
        const session: *Session = @ptrCast(@alignCast(data.?));
        const self = session.controller;
        if (self.closed) return 0;
        var buf: [8192]u8 = undefined;
        while (true) {
            var read: usize = 0;
            var err: ?*c.GError = null;
            const status = c.g_io_channel_read_chars(channel, @ptrCast(&buf), buf.len, &read, &err);
            if (err) |e| c.g_error_free(e);
            if (read > 0) session.surface.write(buf[0..read]);
            if (status == c.G_IO_STATUS_NORMAL) continue;
            if (status == c.G_IO_STATUS_AGAIN) break;
            session.eof = true;
            break;
        }
        if (condition & (c.G_IO_HUP | c.G_IO_ERR) != 0) session.eof = true;
        return 1;
    }

    /// Bounded reaper: finalize sessions whose worker has completed. Never waits
    /// on a live command; the worker has already published its completed wait.
    /// Push the live application editor font to every session surface. The
    /// reaper tick calls this so an editor font-size change recomputes terminal
    /// cell metrics (and the grid) without reopening the session.
    fn syncEditorFont(self: *Controller) void {
        const size = self.app.settings.font;
        if (size == self.applied_font) return;
        self.applied_font = size;
        for (self.sessions) |slot| {
            const session = slot orelse continue;
            session.surface.setFont(surface_mod.editor_font_family, size);
        }
    }

    fn reapTick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Controller = @ptrCast(@alignCast(data.?));
        if (self.closed) return 0;
        self.syncEditorFont();
        for (self.sessions, 0..) |slot, i| {
            const session = slot orelse continue;
            if (session.phase == .starting and session.job.ready()) {
                if (session.job.failure != null) {
                    session.phase = .closing;
                } else {
                    self.ensureReader(session);
                }
            }
            if (session.job.done() and !session.finalized) self.finalize(session, i);
        }
        return 1;
    }

    fn reap(self: *Controller, session: *Session) void {
        session.finalized = true;
        if (session.watch_id != 0) {
            _ = c.g_source_remove(session.watch_id);
            session.watch_id = 0;
        }
        session.removeOutWatch();
        if (session.channel) |channel| {
            c.g_io_channel_unref(channel);
            session.channel = null;
        }
        // finish() joins the worker; after cancel it completes within the
        // ownership cleanup grace, so this never waits on a live command.
        const report = session.job.finish();
        session.report = report;
        if (report) |r| {
            self.reaped += 1;
            if (r.spawn_errno == 0 and r.reaped != 0) {
                const status: c_uint = @bitCast(r.status);
                if (status & 0x7f == 0) {
                    session.exit_code = @intCast((status >> 8) & 0xff);
                } else if (status & 0x7f != 0x7f) {
                    session.signal = @intCast(status & 0x7f);
                }
            }
        }
    }

    fn finalize(self: *Controller, session: *Session, index: usize) void {
        self.reap(session);
        const was_closing = session.phase == .closing;
        session.phase = .exited;
        if (was_closing) {
            self.destroySession(session, index);
        } else {
            self.refresh();
        }
    }

    fn destroySession(self: *Controller, session: *Session, index: usize) void {
        c.gtk_stack_remove(u.cast(c.GtkStack, self.stack), session.surface.widget);
        session.surface.deinit();
        session.freeSpawnMetadata();
        a.destroy(session);
        self.sessions[index] = null;
        if (self.active == index) {
            self.active = null;
            for (self.sessions, 0..) |slot, i| if (slot != null) {
                self.active = i;
                break;
            };
            if (self.active) |i| {
                const next = self.sessions[i].?;
                c.gtk_stack_set_visible_child_name(u.cast(c.GtkStack, self.stack), next.stack_name);
            }
        }
        self.refresh();
    }

    /// Workspace changed: cancel/reap every session. The reaper timeout
    /// completes cleanup asynchronously; deinit drains synchronously.
    pub fn invalidate(self: *Controller) void {
        for (self.sessions, 0..) |slot, i| {
            const session = slot orelse continue;
            if (session.finalized) {
                self.destroySession(session, i);
            } else if (session.phase != .closing) {
                session.phase = .closing;
                session.job.cancel();
            }
        }
        self.refresh();
    }

    pub fn deinit(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        if (self.timeout_id != 0) _ = c.g_source_remove(self.timeout_id);
        self.timeout_id = 0;
        for (self.sessions) |slot| {
            const session = slot orelse continue;
            if (!session.finalized) session.job.cancel();
        }
        for (self.sessions, 0..) |slot, i| {
            const session = slot orelse continue;
            if (!session.finalized) self.reap(session);
            self.destroySession(session, i);
        }
        if (self.slot) |slot| c.gtk_box_remove(u.cast(c.GtkBox, slot), self.root);
        c.g_object_unref(self.root);
    }

    // ---- Probe / fixtures (test hooks only) ----
    pub fn probe(self: *Controller) void {
        if (!test_hooks) return;
        const SessionView = struct {
            id: u64,
            phase: []const u8,
            cols: u16,
            rows: u16,
            eof: bool,
            exit_code: ?i32,
            signal: ?i32,
            title: []const u8,
            pwd: []const u8,
            mapped: bool,
            width: c_int,
            height: c_int,
            font_family: []const u8,
            font_size: c_int,
            cell_width: u32,
            cell_height: u32,
            block_mode: bool,
            kitty_storage_limit: u64,
            kitty_generation: u64,
            kitty_file_medium: bool,
            kitty_shm_medium: bool,
            text: []const u8,
        };
        var views: std.ArrayList(SessionView) = .empty;
        defer views.deinit(a);
        for (self.sessions) |slot| {
            const session = slot orelse continue;
            // Ownership transfers to views; freed after serialization below.
            const text = self.screenText(session);
            const kinfo = session.surface.kittyInfo();
            views.append(a, .{
                .id = session.id,
                .phase = @tagName(session.phase),
                .cols = session.surface.cols,
                .rows = session.surface.rows_count,
                .eof = session.eof,
                .exit_code = session.exit_code,
                .signal = session.signal,
                .title = session.title,
                .pwd = session.pwd,
                .mapped = c.gtk_widget_get_mapped(session.surface.widget) != 0,
                .width = c.gtk_widget_get_width(session.surface.widget),
                .height = c.gtk_widget_get_height(session.surface.widget),
                .font_family = session.surface.font_family[0..session.surface.font_family_len],
                .font_size = session.surface.font_size_px,
                .cell_width = session.surface.cell_width,
                .cell_height = session.surface.cell_height,
                .block_mode = session.surface.block_mode,
                .kitty_storage_limit = kinfo.storage_limit,
                .kitty_generation = kinfo.generation,
                .kitty_file_medium = kinfo.file_medium,
                .kitty_shm_medium = kinfo.shm_medium,
                .text = text,
            }) catch unreachable;
        }
        const text = std.json.Stringify.valueAlloc(a, .{
            .sessions = views.items,
            .count = self.count(),
            .active = if (self.active) |i| self.sessions[i].?.id else null,
            .limit = @as(usize, max_sessions),
            .trust = @tagName(self.app.workspace_policy.policy.state),
            .editor_font = self.app.settings.font,
            .last_error = self.last_error,
            .spawned = self.spawned,
            .reaped = self.reaped,
            .closed = self.closed,
        }, .{}) catch unreachable;
        defer a.free(text);
        // The serialized JSON owns a copy; release the per-session screen text.
        for (views.items) |view| a.free(view.text);
        const z = u.z(text);
        defer a.free(z);
        c.g_print("CORAL_TERMINAL %s\n", z.ptr);
    }

    fn screenText(self: *Controller, session: *Session) []const u8 {
        _ = self;
        const empty = a.dupe(u8, "") catch unreachable;
        var formatter: ?*g.Formatter = null;
        if (!g.ok(g.ghostty_formatter_terminal_new(null, &formatter, session.surface.terminal))) return empty;
        defer g.ghostty_formatter_free(formatter);
        const emit: g.FormatterFormat = .plain;
        _ = g.ghostty_formatter_set(formatter, .emit, &emit);
        var needed: usize = 0;
        if (g.ghostty_formatter_format_buf(formatter, null, 0, &needed) != g.OUT_OF_SPACE or needed == 0) return empty;
        const buf = a.alloc(u8, needed) catch return empty;
        var written: usize = 0;
        if (!g.ok(g.ghostty_formatter_format_buf(formatter, buf.ptr, needed, &written))) {
            a.free(buf);
            return empty;
        }
        a.free(empty);
        return buf[0..written];
    }

    /// Test-only fixture dispatch. Returns true when the action was handled.
    pub fn fixture(self: *Controller, action: []const u8, value: []const u8) bool {
        if (!test_hooks) return false;
        if (std.mem.eql(u8, action, "terminal-probe")) {
            self.probe();
        } else if (std.mem.eql(u8, action, "terminal-block-mode")) {
            if (self.activeSession()) |session| session.surface.setBlockMode(std.mem.eql(u8, value, "1"));
        } else if (std.mem.eql(u8, action, "terminal-select-block")) {
            var it = std.mem.splitScalar(u8, value, ',');
            const x0 = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y0 = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const x1 = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            const y1 = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
            if (self.activeSession()) |session| session.surface.selectRectangle(x0, y0, x1, y1);
        } else if (std.mem.eql(u8, action, "terminal-clear-selection")) {
            if (self.activeSession()) |session| session.surface.clearSelection();
        } else if (std.mem.eql(u8, action, "terminal-new")) {
            self.newSession() catch {};
        } else if (std.mem.eql(u8, action, "terminal-close")) {
            self.closeActive();
        } else if (std.mem.eql(u8, action, "terminal-restart")) {
            self.restartActive();
        } else if (std.mem.eql(u8, action, "terminal-cancel")) {
            self.cancelActive();
        } else if (std.mem.eql(u8, action, "terminal-write")) {
            if (self.activeSession()) |session| Session.writePty(session, value);
        } else if (std.mem.eql(u8, action, "terminal-paste")) {
            if (self.activeSession()) |session| _ = session.surface.paste(value);
        } else if (std.mem.eql(u8, action, "terminal-copy")) {
            if (self.activeSession()) |session| _ = session.surface.copySelection();
        } else if (std.mem.eql(u8, action, "terminal-select-all")) {
            if (self.activeSession()) |session| session.surface.selectAll();
        } else if (std.mem.eql(u8, action, "terminal-scroll")) {
            const delta = std.fmt.parseInt(isize, value, 10) catch 0;
            if (self.activeSession()) |session| session.surface.scroll(delta);
        } else if (std.mem.eql(u8, action, "terminal-resize")) {
            var it = std.mem.splitScalar(u8, value, ',');
            const cols = std.fmt.parseInt(u16, it.next() orelse "80", 10) catch 80;
            const rows = std.fmt.parseInt(u16, it.next() orelse "24", 10) catch 24;
            if (self.activeSession()) |session| session.surface.resizeGrid(cols, rows);
        } else if (std.mem.eql(u8, action, "terminal-focus")) {
            self.focusWidget();
        } else return false;
        return true;
    }
};

fn userShell() []const u8 {
    const shell = c.g_getenv("SHELL");
    if (shell != null) {
        const span = std.mem.span(shell);
        if (span.len > 0 and span[0] == '/') return span;
    }
    return "/bin/sh";
}

/// Complete environment allowlist. Copies only approved host variables, forces
/// TERM=xterm-256color, advertises truecolor and pins PWD to the workspace root.
fn buildEnv(session: *Session) void {
    var n: usize = 0;
    for (env_allowlist) |key| {
        const value = c.g_getenv(key.ptr) orelse continue;
        if (n >= env_capacity) break;
        session.env_storage[n] = u.fmt("{s}={s}", .{ key, std.mem.span(value) });
        session.env_ptrs[n] = session.env_storage[n].ptr;
        n += 1;
    }
    session.env_storage[n] = u.fmt("TERM=xterm-256color", .{});
    session.env_ptrs[n] = session.env_storage[n].ptr;
    n += 1;
    session.env_storage[n] = u.fmt("COLORTERM=truecolor", .{});
    session.env_ptrs[n] = session.env_storage[n].ptr;
    n += 1;
    session.env_storage[n] = u.fmt("PWD={s}", .{session.cwd});
    session.env_ptrs[n] = session.env_storage[n].ptr;
    n += 1;
    session.env_ptrs[n] = null;
    session.env_len = n;
}
