//! A GTK4 VTE view attached to a Coral-owned PTY.
const c = @import("vte_abi.zig");
const transport = @import("pty.zig");

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
    /// Unparent first. Finalizing the widget releases VTE's foreign PTY,
    /// including its duplicate fd, even if its EOF callback has not run yet.
    pub fn deinit(self: *View) void {
        c.g_object_unref(self.widget);
    }
};
