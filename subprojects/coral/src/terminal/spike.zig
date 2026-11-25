//! Optional M0 embedding candidate, not a full terminal/task service.
//! GTK owns emulation/input/resize; pty.zig owns spawning and the ONLY waiter.
//! No command registry, URL opener, clipboard OSC handler or shell integration
//! is reachable from output. Never connect terminal metadata to action dispatch.
const std = @import("std");
pub const c = @import("vte_abi.zig");
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

pub const View = @import("vte_view.zig").View;
