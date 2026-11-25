const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const App = @import("app.zig").App;
const language = @import("language/controller.zig");
const i18n = @import("i18n");

pub const Dock = struct {
    app: *App,
    book: *c.GtkNotebook,
    rows: u.W,
    arena: std.heap.ArenaAllocator,
    problems: []language.DockProblem = &.{},
    timer: c_uint = 0,
    pub fn create(app: *App, slot: u.W) *Dock {
        const self = a.create(Dock) catch unreachable;
        const notebook = c.gtk_notebook_new().?;
        c.gtk_widget_add_css_class(notebook, "workspace-tools");
        c.gtk_widget_set_vexpand(notebook, 1);
        const book = u.cast(c.GtkNotebook, notebook);
        u.append(slot, notebook);
        const terminal = u.box(false, 0);
        _ = c.gtk_notebook_append_page(book, terminal, u.label(i18n.dtr("coral", "Terminal")));
        app.terminal.attach(terminal);
        const scroll = c.gtk_scrolled_window_new().?;
        const rows = u.box(false, 2);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), rows);
        _ = c.gtk_notebook_append_page(book, scroll, u.label(i18n.dtr("coral", "Problems")));
        const tasks = u.box(false, 3);
        const tools = u.box(true, 4);
        u.append(tasks, tools);
        const run = u.button(i18n.dtr("coral", "Choose task…"));
        u.append(tools, run);
        u.connect(run, "clicked", &showTasks, app);
        const out_scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(out_scroll, 1);
        const out = c.gtk_text_view_new().?;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, out), 0);
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, out), 1);
        c.gtk_widget_add_css_class(out, "workspace-thread");
        app.tasks.dock_output = u.cast(c.GtkTextView, out);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, out_scroll), out);
        u.append(tasks, out_scroll);
        _ = c.gtk_notebook_append_page(book, tasks, u.label(i18n.dtr("coral", "Task output")));
        self.* = .{ .app = app, .book = book, .rows = rows, .arena = .init(a) };
        self.timer = c.g_timeout_add(400, &refresh, self);
        return self;
    }
    pub fn deinit(self: *Dock) void {
        _ = c.g_source_remove(self.timer);
        self.arena.deinit();
        a.destroy(self);
    }
};
fn refresh(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Dock, data.?);
    if (self.app.closing or c.gtk_notebook_get_current_page(self.book) != 1) return 1;
    var arena = std.heap.ArenaAllocator.init(a);
    const rows = language.workspaceProblems(&self.app.language, arena.allocator()) catch {
        arena.deinit();
        return 1;
    };
    const same = same: {
        if (rows.len != self.problems.len or c.gtk_widget_get_first_child(self.rows) == null) break :same false;
        for (rows, self.problems) |r, old| {
            if (r.document != old.document or r.revision != old.revision or r.start != old.start or r.end != old.end or !std.mem.eql(u8, r.label, old.label)) break :same false;
        }
        break :same true;
    };
    if (same) {
        arena.deinit();
        return 1;
    }
    while (c.gtk_widget_get_first_child(self.rows)) |child| c.gtk_box_remove(u.cast(c.GtkBox, self.rows), child);
    self.arena.deinit();
    self.arena = arena;
    self.problems = rows;
    if (rows.len == 0) u.append(self.rows, u.label(i18n.dtr("coral", "No language diagnostics")));
    for (rows, 0..) |r, i| {
        const label = u.z(r.label);
        defer a.free(label);
        const b = u.button(label);
        c.gtk_widget_add_css_class(b, "flat");
        c.g_object_set_data(u.cast(c.GObject, b), "index", @ptrFromInt(i + 1));
        u.connect(b, "clicked", &navigate, self);
        u.append(self.rows, b);
    }
    return 1;
}
fn navigate(b: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Dock, data.?);
    const index = @intFromPtr(c.g_object_get_data(u.cast(c.GObject, b.?), "index")) - 1;
    const r = self.problems[index];
    const d = self.app.documents.get(r.document) orelse return;
    if (d.revision != r.revision) return;
    self.app.acceptExisting(d.path orelse return);
    const view = self.app.activeView() orelse return;
    if (view.document != d) return;
    const text = u.bufferText(d.buffer);
    defer a.free(text);
    const decoration = @import("language/decorations.zig");
    var start = decoration.iter(d, text, r.start) catch return;
    var end = decoration.iter(d, text, r.end) catch return;
    c.gtk_text_buffer_get_iter_at_offset(view.buffer, &start, c.gtk_text_iter_get_offset(&start));
    c.gtk_text_buffer_get_iter_at_offset(view.buffer, &end, c.gtk_text_iter_get_offset(&end));
    c.gtk_text_buffer_select_range(view.buffer, &start, &end);
    _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, view.widget), &start, 0.15, 0, 0, 0);
}
fn showTasks(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).tasks.show();
}
