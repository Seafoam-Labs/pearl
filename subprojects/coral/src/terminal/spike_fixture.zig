//! Standalone native fixture. stdin is a PRIVATE HARNESS control pipe, never the
//! PTY or production IPC. It exists so tests do not steal terminal key bindings.
const std = @import("std");
const spike = @import("spike.zig");
const c = spike.c;
const os = spike.transport.os;
const title = "Coral M0 — embedded GTK4 VTE";
const State = struct {
    job: *spike.Job,
    window: *c.Object,
    view: *spike.View,
    closing: bool = false,
    eof: bool = false,
    actions: u32 = 0,
    report: ?spike.transport.Report = null,
    supervisor: c_int = -1,

    fn close(_: *c.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(data.?));
        self.closing = true;
        self.job.cancel();
        c.gtk_widget_set_visible(self.window, 0);
        return 1; // retain state until worker completion; never block GTK on wait
    }
    fn ended(_: *c.Object, data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data.?));
        self.eof = true;
    }
    fn action(_: *c.Object, _: ?*c.Object, data: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(data.?));
        self.actions += 1;
    }
    fn probe(self: *State) !void {
        const text = c.vte_terminal_get_text_format(self.view.widget, 1) orelse return error.NoText;
        defer c.g_free(text);
        try emit("SPIKE_STATE", .{
            .text = std.mem.span(text),
            .rows = c.vte_terminal_get_row_count(self.view.widget),
            .columns = c.vte_terminal_get_column_count(self.view.widget),
            .width = c.gtk_widget_get_width(self.view.widget),
            .height = c.gtk_widget_get_height(self.view.widget),
            .mapped = c.gtk_widget_get_mapped(self.view.widget) != 0,
            .actions = self.actions,
            .eof = self.eof,
            .report = self.report,
        });
    }
};
fn emit(prefix: []const u8, value: anytype) !void {
    // JSON escapes terminal control characters; never relay raw PTY bytes to logs.
    const text = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
    defer std.heap.page_allocator.free(text);
    std.debug.print("{s} {s}\n", .{ prefix, text });
}
fn drain() void {
    for (0..128) |_| {
        if (c.g_main_context_iteration(null, 0) == 0) break;
    }
}
pub fn main() !void {
    const child = c.getenv("CORAL_SPIKE_CHILD") orelse return error.MissingChild;
    const mode = std.mem.span(c.getenv("CORAL_SPIKE_MODE") orelse return error.MissingMode);
    if (!std.mem.eql(u8, mode, "exit") and !std.mem.eql(u8, mode, "cancel") and !std.mem.eql(u8, mode, "close")) return error.BadMode;
    if (c.gtk_init_check() == 0) return error.PrivateWaylandDisplayRequired;
    var mode_buffer: [64]u8 = undefined;
    const mode_env = try std.fmt.bufPrintSentinel(&mode_buffer, "CORAL_SPIKE_MODE={s}", .{mode}, 0);
    const argv = [_:null]?[*:0]const u8{child};
    const environment = [_:null]?[*:0]const u8{ "LANG=C.UTF-8", "TERM=xterm-256color", mode_env };
    var job = spike.Job{ .config = .{
        .authorization = .approved,
        .argv = &argv,
        .environment = &environment,
        .cwd = "/",
    } };
    job.start();
    defer {
        while (!job.ready()) c.g_usleep(1000);
        job.cancel();
        while (!job.done()) {
            drain();
            c.g_usleep(1000);
        }
        if (job.thread != null) _ = job.finish();
    }
    while (!job.ready()) {
        drain();
        c.g_usleep(1000);
    }
    if (job.failure) |failure| return failure;
    var view = spike.View.init();
    defer view.deinit();
    const window = c.gtk_window_new();
    defer c.gtk_window_destroy(window);
    c.gtk_window_set_title(window, title);
    c.gtk_window_set_default_size(window, 820, 500);
    const box = c.gtk_box_new(1, 6); // GTK_ORIENTATION_VERTICAL
    c.gtk_box_append(box, c.gtk_label_new("M0 candidate · real VTE widget · terminal output has no action authority"));
    c.gtk_box_append(box, view.widget);
    c.gtk_window_set_child(window, box);
    var state = State{ .job = &job, .window = window, .view = &view, .supervisor = job.handle.?.owner.pid };
    c.connect(window, "close-request", &State.close, &state);
    c.connect(view.widget, "eof", &State.ended, &state);
    const group = c.g_simple_action_group_new();
    defer c.g_object_unref(group);
    const action = c.g_simple_action_new("tripwire", null);
    defer c.g_object_unref(action);
    c.connect(action, "activate", &State.action, &state);
    c.g_action_map_add_action(group, action);
    c.gtk_widget_insert_action_group(window, "workbench", group);

    try view.attach(&job.handle.?);
    c.gtk_window_present(window);
    _ = c.gtk_widget_grab_focus(view.widget);
    try emit("SPIKE_READY", .{ .vte = .{ c.vte_get_major_version(), c.vte_get_minor_version(), c.vte_get_micro_version() }, .supervisor = state.supervisor });
    var control: [128]u8 = undefined;
    var used: usize = 0;
    const deadline = os.nowMs() + 45_000;
    while (os.nowMs() < deadline) {
        drain();
        if (job.done() and state.report == null and state.eof) {
            view.detach();
            state.report = job.finish() orelse return error.MissingReport;
            try emit("SPIKE_REAP", .{ .supervisor = state.supervisor, .report = state.report.? });
        }
        if (state.closing and state.report != null) return;
        var fds = [_]os.PollFd{.{ .fd = 0, .events = os.POLLIN }};
        if (os.poll(&fds, 1, 2) > 0) {
            const n = os.read(0, control[used..].ptr, control.len - used);
            if (n <= 0) return error.HarnessDisconnected;
            used += @intCast(n);
            while (std.mem.indexOfScalar(u8, control[0..used], '\n')) |end| {
                const command = control[0..end];
                if (std.mem.eql(u8, command, "probe")) {
                    try state.probe();
                } else if (std.mem.eql(u8, command, "clipboard")) {
                    c.gdk_clipboard_set_text(c.gdk_display_get_clipboard(c.gtk_widget_get_display(window)), "CORAL-CLIPBOARD-SENTINEL");
                } else if (std.mem.eql(u8, command, "resize")) {
                    c.gtk_window_set_default_size(window, 1040, 650);
                } else if (std.mem.eql(u8, command, "cancel")) {
                    job.cancel();
                } else if (std.mem.eql(u8, command, "tripwire")) {
                    if (c.gtk_widget_activate_action_variant(view.widget, "workbench.tripwire", null) == 0) return error.MissingAction;
                } else if (std.mem.eql(u8, command, "quit")) {
                    _ = State.close(window, &state);
                } else return error.BadControl;
                const remaining = used - end - 1;
                std.mem.copyForwards(u8, &control, control[end + 1 .. used]);
                used = remaining;
            }
            if (used == control.len) return error.ControlLimit;
        }
    }
    return error.FixtureTimeout;
}
