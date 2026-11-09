//! Optional M0 embedding candidate, not a full terminal/task service.
//! GTK owns emulation/input/resize; pty.zig owns spawning and the ONLY waiter.
//! No command registry, URL opener, clipboard OSC handler or shell integration
//! is reachable from output. Never connect terminal metadata to action dispatch.
const std = @import("std");
pub const c = @import("spike_abi.zig");
pub const transport = @import("pty.zig");

/// Stable address required from start through finish. UI calls cancel; worker
/// starts/waits. Acquire/release publishes the handle and completion, not GTK.
pub const Job = struct {
    config: transport.Config,
    handle: ?transport.Pty = null,
    failure: ?transport.Error = null,
    phase: std.atomic.Value(u8) = .init(0), // 0 starting, 1 running, 2 complete
    thread: ?*c.Object = null,

    pub fn start(self: *Job) void {
        self.thread = c.g_thread_new("coral-terminal", work, self);
    }
    fn work(data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.handle = transport.start(self.config) catch |err| {
            self.failure = err;
            self.phase.store(2, .release);
            return null;
        };
        self.phase.store(1, .release);
        _ = self.handle.?.wait();
        self.phase.store(2, .release);
        return null;
    }
    pub fn ready(self: *const Job) bool {
        return self.phase.load(.acquire) != 0;
    }
    pub fn done(self: *const Job) bool {
        return self.phase.load(.acquire) == 2;
    }
    pub fn cancel(self: *Job) void {
        std.debug.assert(self.ready());
        if (self.handle) |*handle| handle.cancel();
    }
    /// Only after done and after detaching the widget. No UI-thread wait for a
    /// live command: the worker has already published its completed wait.
    pub fn finish(self: *Job) ?transport.Report {
        std.debug.assert(self.done());
        if (self.thread) |thread| _ = c.g_thread_join(thread);
        self.thread = null;
        if (self.handle) |*handle| {
            const report = handle.completion.?;
            handle.deinit();
            self.handle = null;
            return report;
        }
        return null;
    }
};

pub const View = struct {
    widget: *c.Object,

    pub fn init() View {
        const widget = c.vte_terminal_new();
        _ = c.g_object_ref_sink(widget);
        c.gtk_widget_set_hexpand(widget, 1);
        c.gtk_widget_set_vexpand(widget, 1);
        c.vte_terminal_set_scrollback_lines(widget, 1000);
        c.vte_terminal_set_allow_hyperlink(widget, 0);
        c.vte_terminal_set_enable_sixel(widget, 0);
        c.vte_terminal_set_audible_bell(widget, 0);
        return .{ .widget = widget };
    }
    /// Sole PTY reader/writer is VTE after attachment. The duplicate shares file
    /// status flags; do not read/write/change flags through the original handle.
    /// In particular, DO NOT call vte_terminal_watch_child: Job owns waitpid.
    pub fn attach(self: *View, handle: *const transport.Pty) !void {
        const fd = transport.os.fcntl(handle.master, 1030, @as(c_int, 3)); // F_DUPFD_CLOEXEC
        if (fd < 0) return error.DuplicatePty;
        var failure: ?*c.Object = null;
        // VtePty consumes fd, including initialization failure finalization.
        const foreign = c.vte_pty_new_foreign_sync(fd, null, &failure) orelse {
            if (failure) |err| c.g_error_free(err);
            return error.ForeignPty;
        };
        defer c.g_object_unref(foreign);
        c.vte_terminal_set_pty(self.widget, foreign);
    }
    pub fn detach(self: *View) void {
        c.vte_terminal_set_pty(self.widget, null);
    }
    /// Unparent first. Retaining a reference keeps callbacks and teardown safe
    /// while close-request cancels and the ownership worker finishes reaping.
    pub fn deinit(self: *View) void {
        self.detach();
        c.g_object_unref(self.widget);
    }
};
