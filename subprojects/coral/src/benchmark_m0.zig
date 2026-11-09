//! Bounded engine measurements, NOT input-to-paint or application startup.
//! Run via tests/benchmarks.py for private Wayland, watchdogs and provenance.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const Document = @import("document.zig").Document;
const View = @import("editor/view.zig").EditorView;
const tx = @import("editor/transactions.zig");
const Excerpt = @import("editor/excerpt.zig").Excerpt;
const ExcerptEditor = @import("editor/excerpt_editor.zig").Editor;
const History = @import("editor/history.zig").History;
const policy = @import("editor/presentation_policy.zig");
const process = @import("tasks/process.zig");
const pty = @import("terminal/pty.zig");
const a = std.heap.c_allocator;
extern "c" fn alarm(c_uint) c_uint;

fn env(name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = c.g_getenv(name);
    return if (value == null) fallback else std.mem.span(value);
}
fn number(name: [:0]const u8, fallback: usize) usize {
    return std.fmt.parseInt(usize, env(name, ""), 10) catch fallback;
}
fn now() i64 {
    return c.g_get_monotonic_time();
}
fn sample(metric: []const u8, index: usize, start: i64) void {
    std.debug.print("{{\"kind\":\"sample\",\"metric\":\"{s}\",\"index\":{d},\"us\":{d}}}\n", .{ metric, index, now() - start });
}
fn hash(label: []const u8, id: usize, bytes: []const u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    std.debug.print("{{\"kind\":\"hash\",\"label\":\"{s}\",\"id\":{d},\"bytes\":{d},\"sha256\":\"{x}\"}}\n", .{ label, id, bytes.len, digest });
}
fn memory(stage: []const u8, cycle: usize, documents: usize, views: usize) void {
    var bytes: [*c]u8 = null;
    var size: usize = 0;
    if (c.g_file_get_contents("/proc/self/status", &bytes, &size, null) == 0) return;
    defer c.g_free(bytes);
    var rss: usize = 0;
    var peak: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes[0..size], '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const key = tokens.next() orelse continue;
        if (std.mem.eql(u8, key, "VmRSS:")) rss = std.fmt.parseInt(usize, tokens.next() orelse "0", 10) catch 0;
        if (std.mem.eql(u8, key, "VmHWM:")) peak = std.fmt.parseInt(usize, tokens.next() orelse "0", 10) catch 0;
    }
    std.debug.print("{{\"kind\":\"memory\",\"stage\":\"{s}\",\"cycle\":{d},\"documents\":{d},\"views\":{d},\"rss_kib\":{d},\"peak_kib\":{d}}}\n", .{ stage, cycle, documents, views, rss, peak });
}
fn drain() !void {
    const deadline = now() + 10_000_000;
    while (true) {
        const start = now();
        const dispatched = c.g_main_context_iteration(null, 0);
        const elapsed = now() - start;
        if (elapsed > 50_000) std.debug.print("{{\"kind\":\"stall\",\"dispatch_us\":{d}}}\n", .{elapsed});
        if (dispatched == 0) return;
        if (now() > deadline) return error.MainLoopDidNotSettle;
    }
}
fn settle() !void {
    for (0..20) |_| {
        try drain();
        c.g_usleep(1000);
    }
}
fn fixture(size: usize, id: usize, single_line: bool) ![]u8 {
    const bytes = try a.alloc(u8, size);
    var line: [64]u8 = @splat(' ');
    _ = try std.fmt.bufPrint(line[0..63], "// {d:0>3} const café = \"λ🌱\"; // deterministic", .{id});
    line[63] = if (single_line) ' ' else '\n';
    for (bytes, 0..) |*byte, i| byte.* = line[i % line.len];
    hash(if (single_line) "fixture-no-LF" else "fixture-LF", id, bytes);
    return bytes;
}
fn document(id: usize, bytes: []const u8) !*Document {
    const d = try Document.create(id, null);
    c.gtk_text_buffer_begin_irreversible_action(d.buffer);
    c.gtk_text_buffer_set_text(d.buffer, bytes.ptr, @intCast(bytes.len));
    c.gtk_text_buffer_end_irreversible_action(d.buffer);
    c.gtk_text_buffer_set_modified(d.buffer, 0);
    const language = c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), "c");
    c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, d.buffer), language);
    return d;
}
fn verify(buffer: *c.GtkTextBuffer, bytes: []const u8) !void {
    const text = u.bufferText(buffer);
    defer a.free(text);
    if (!std.mem.eql(u8, text, bytes)) return error.TextDiverged;
}
fn target(d: *Document) tx.Target {
    return .{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = d.revision };
}
fn window(child: *c.GtkWidget) !*c.GtkWidget {
    const w = c.gtk_window_new().?;
    c.gtk_window_set_default_size(u.cast(c.GtkWindow, w), 1000, 700);
    c.gtk_window_set_child(u.cast(c.GtkWindow, w), child);
    c.gtk_window_present(u.cast(c.GtkWindow, w));
    const deadline = now() + 5_000_000;
    while (c.gtk_widget_get_mapped(w) == 0) {
        try drain();
        if (now() > deadline) return error.MapTimeout;
        c.g_usleep(1000);
    }
    try settle();
    std.debug.print("{{\"kind\":\"window\",\"width\":{d},\"height\":{d},\"scale\":{d}}}\n", .{ c.gtk_widget_get_width(w), c.gtk_widget_get_height(w), c.gtk_widget_get_scale_factor(w) });
    return w;
}
fn editCycle(d: *Document, v: *View, index: usize, measured: bool) !void {
    const count = c.gtk_text_buffer_get_char_count(v.buffer);
    // Includes non-ASCII locations in the first source line; GTK uses characters.
    const offset: c_int = switch (index % 3) {
        0 => 20,
        1 => @divTrunc(count, 2),
        else => count - 1,
    };
    var it: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    var start = now();
    c.gtk_text_buffer_get_iter_at_offset(v.buffer, &it, offset);
    c.gtk_text_buffer_begin_user_action(v.buffer);
    c.gtk_text_buffer_insert(v.buffer, &it, "Ω", 2);
    c.gtk_text_buffer_end_user_action(v.buffer);
    try drain();
    if (measured) sample("insert-buffer-drain", index, start);
    start = now();
    c.gtk_text_buffer_get_iter_at_offset(v.buffer, &it, offset);
    c.gtk_text_buffer_get_iter_at_offset(v.buffer, &end, offset + 1);
    c.gtk_text_buffer_begin_user_action(v.buffer);
    c.gtk_text_buffer_delete(v.buffer, &it, &end);
    c.gtk_text_buffer_end_user_action(v.buffer);
    try drain();
    if (measured) sample("delete-buffer-drain", index, start);
    start = now();
    c.gtk_text_buffer_undo(d.buffer);
    try drain();
    if (measured) sample("undo-delete-buffer-drain", index, start);
    start = now();
    c.gtk_text_buffer_undo(d.buffer);
    try drain();
    if (measured) sample("undo-insert-buffer-drain", index, start);
    if (c.gtk_text_buffer_get_char_count(d.buffer) != count or c.gtk_text_buffer_get_char_count(v.buffer) != count) return error.TextLengthDiverged;
}
fn input(single_line: bool) !void {
    const bytes = try fixture(number("BENCH_BYTES", 1048576), 0, single_line);
    defer a.free(bytes);
    const panes = number("BENCH_PANES", 1);
    const wrap = number("BENCH_WRAP", 0) != 0;
    const start = now();
    if (single_line) _ = alarm(10);
    const d = try document(1, bytes);
    defer d.destroy();
    const v = try View.create(d);
    defer v.destroy();
    const second = if (panes == 2) try View.create(d) else null;
    defer if (second) |s| s.destroy();
    // Full B03 must not accidentally time a hidden widget after the production
    // guard engages. A separate raw view renders the entire presentation buffer;
    // the separately named bounded-excerpt workload exercises the real fallback.
    const rendered = if (single_line) c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, v.buffer)).? else v.widget;
    c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, rendered), 1);
    c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, rendered), if (wrap) c.GTK_WRAP_CHAR else c.GTK_WRAP_NONE);
    const page = if (single_line) c.gtk_scrolled_window_new().? else v.page;
    if (single_line) {
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), rendered);
        std.debug.print("{{\"kind\":\"policy\",\"variant\":\"full-render-control\",\"layout_guard_bypassed\":true,\"syntax_limited\":{}}}\n", .{policy.limited(d.buffer)});
    }
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
    c.gtk_box_append(u.cast(c.GtkBox, box), page);
    if (second) |s| {
        if (s.buffer == v.buffer or s.buffer == d.buffer) return error.SharedPresentationBuffer;
        c.gtk_box_append(u.cast(c.GtkBox, box), s.page);
        var it: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(s.buffer, &it, 3);
        c.gtk_text_buffer_place_cursor(s.buffer, &it);
    }
    const w = try window(box);
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, w));
    try settle();
    sample("load-map-settle", 0, start);
    _ = alarm(0);
    memory("opened", 0, 1, panes);
    for (0..10) |i| try editCycle(d, v, i, false);
    // Four separately timed operations per cycle: exactly 1,000 input samples.
    for (0..250) |i| {
        try editCycle(d, v, i, true);
        if (single_line) {
            const caret_start = now();
            var it: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(v.buffer, &it, if (i % 2 == 0) 20 else c.gtk_text_buffer_get_char_count(v.buffer) - 1);
            c.gtk_text_buffer_place_cursor(v.buffer, &it);
            _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, rendered), &it, 0, 1, 1, 0);
            try drain();
            sample("caret-scroll-request-drain", i, caret_start);
        }
        if (i % 100 == 0) {
            try verify(d.buffer, bytes);
            try verify(v.buffer, bytes);
        }
        if (second) |s| {
            var it: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_mark(s.buffer, &it, c.gtk_text_buffer_get_insert(s.buffer));
            if (c.gtk_text_iter_get_offset(&it) != 3) return error.OtherPaneSelectionMoved;
            if (i % 100 == 0) try verify(s.buffer, bytes);
        }
    }
    try verify(d.buffer, bytes);
    try verify(v.buffer, bytes);
    if (second) |s| try verify(s.buffer, bytes);
    const result = u.bufferText(d.buffer);
    defer a.free(result);
    hash("restored-output", 0, result);
    memory("edited", 0, 1, panes);
}
fn prepareFixtures() !void {
    const directory = env("BENCH_FIXTURE_DIR", "");
    if (directory.len == 0) return error.FixtureDirectoryRequired;
    for ([_]usize{ 0, 1048576 }) |size| {
        const bytes = try fixture(size, 0, false);
        defer a.free(bytes);
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{d}.txt", .{ directory, size }, 0);
        defer a.free(path);
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        if (c.g_file_replace_contents(file, bytes.ptr, bytes.len, null, 0, 0, null, null, null) == 0) return error.SaveFixtureFailed;
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        c.g_cancellable_cancel(cancel);
        if (c.g_file_replace_contents(file, "must not replace", 16, null, 0, 0, null, cancel, null) != 0) return error.CancelledSaveSucceeded;
        var loaded: [*c]u8 = null;
        var length: usize = 0;
        if (c.g_file_load_contents(file, null, &loaded, &length, null, null) == 0) return error.ReadFixtureFailed;
        defer c.g_free(loaded);
        if (!std.mem.eql(u8, bytes, loaded[0..length])) return error.SaveRoundTripFailed;
        hash("saved-fixture-cancel-preserved", size, loaded[0..length]);
    }
}
fn startup() !void {
    const size = number("BENCH_BYTES", 0);
    const path = c.g_getenv("BENCH_FILE");
    if (path == null) return error.FixtureFileRequired;
    const start = now();
    var loaded: [*c]u8 = null;
    var length: usize = 0;
    if (c.g_file_get_contents(path, &loaded, &length, null) == 0) return error.ReadFixtureFailed;
    defer c.g_free(loaded);
    if (length != size) return error.FixtureSizeMismatch;
    const bytes = loaded[0..length];
    hash("opened-fixture", 0, bytes);
    const d = try document(1, bytes);
    defer d.destroy();
    const v = try View.create(d);
    defer v.destroy();
    const w = try window(v.page);
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, w));
    _ = c.gtk_widget_grab_focus(v.widget);
    try settle();
    var it: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_start_iter(v.buffer, &it);
    c.gtk_text_buffer_begin_user_action(v.buffer);
    c.gtk_text_buffer_insert(v.buffer, &it, "x", 1);
    c.gtk_text_buffer_end_user_action(v.buffer);
    c.gtk_text_buffer_undo(d.buffer);
    try verify(d.buffer, bytes);
    sample("construct-map-edit-probe", 0, start);
    // Cross-process CLOCK_MONOTONIC timestamp, not pipe-reader receipt time.
    std.debug.print("{{\"kind\":\"ready\",\"monotonic_us\":{d},\"focus_within\":{}}}\n", .{ now(), c.gtk_widget_is_focus(v.widget) != 0 });
    memory("ready", 0, 1, 1);
}
fn tabs() !void {
    const count = number("BENCH_TABS", 20);
    if (count > 100 or count == 0) return error.InvalidTabCount;
    const notebook = c.gtk_notebook_new().?;
    // Match editor_groups: otherwise 100 tabs request a >20k-pixel surface.
    c.gtk_notebook_set_scrollable(u.cast(c.GtkNotebook, notebook), 1);
    const w = try window(notebook);
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, w));
    for (0..5) |cycle| {
        memory("baseline", cycle, 0, 0);
        var docs: [100]*Document = undefined;
        var views: [100]*View = undefined;
        var fixtures: [100][]u8 = undefined;
        for (0..count) |i| fixtures[i] = try fixture(65536, i, false);
        const start = now();
        for (0..count) |i| {
            docs[i] = try document(i + 1, fixtures[i]);
            views[i] = try View.create(docs[i]);
            _ = c.gtk_notebook_append_page(u.cast(c.GtkNotebook, notebook), views[i].page, views[i].tab);
        }
        try settle();
        sample("open-tabs-map-settle", cycle, start);
        memory("opened", cycle, count, count);
        for (0..count) |i| {
            const switch_start = now();
            c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, notebook), @intCast(i));
            try drain();
            sample("tab-switch-request-drain", cycle * count + i, switch_start);
        }
        for (0..10) |i| try editCycle(docs[0], views[0], i, false);
        // 50 cycles x 4 operations x 5 reopen trials = 1,000 input samples.
        for (0..50) |j| {
            const i = (cycle * 50 + j) % count;
            c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, notebook), @intCast(i));
            try drain();
            try editCycle(docs[i], views[i], cycle * 50 + j, true);
        }
        for (0..count) |i| {
            try verify(docs[i].buffer, fixtures[i]);
            try verify(views[i].buffer, fixtures[i]);
            const text = u.bufferText(docs[i].buffer);
            defer a.free(text);
            hash("tab-restored", i, text);
        }
        memory("edited", cycle, count, count);
        const extra_start = now();
        const extra = try View.create(docs[0]);
        sample("second-view-construct", cycle, extra_start);
        memory("second-view", cycle, count, count + 1);
        try verify(extra.buffer, fixtures[0]);
        extra.destroy();
        for (0..count) |i| {
            c.gtk_notebook_remove_page(u.cast(c.GtkNotebook, notebook), 0);
            views[i].destroy();
            docs[i].destroy();
            a.free(fixtures[i]);
        }
        try settle();
        memory("closed", cycle, 0, 0);
    }
}
const Sources = struct {
    docs: [10]*Document,
    fn resolve(data: ?*anyopaque, id: u64) ?tx.Target {
        const self = u.cast(Sources, data.?);
        for (self.docs) |d| if (d.id == id) return target(d);
        return null;
    }
    fn targets(self: *Sources) [10]tx.Target {
        var result: [10]tx.Target = undefined;
        for (self.docs, &result) |d, *t| t.* = target(d);
        return result;
    }
};
fn excerpts() !void {
    for (0..5) |cycle| {
        var sources: Sources = undefined;
        var fixtures: [10][]u8 = undefined;
        for (&sources.docs, 0..) |*d, i| {
            fixtures[i] = try fixture(65536, i, false);
            d.* = try document(i + 1, fixtures[i]);
        }
        defer for (sources.docs, fixtures) |d, bytes| {
            d.destroy();
            a.free(bytes);
        };
        var history = History.init(a, .{});
        defer history.deinit();
        memory("sources", cycle, 10, 0);
        const start = now();
        var editors: [100]*ExcerptEditor = undefined;
        const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        for (&editors, 0..) |*e, i| {
            const range_start = (i % 10) * 30 * 64;
            const excerpt = try Excerpt.init(a, target(sources.docs[i / 10]), .{ .start = range_start, .end = range_start + 20 * 64 }, false, .{});
            e.* = try ExcerptEditor.create(a, excerpt, "Source excerpt — 20 lines", .{ .context = &sources, .resolve = Sources.resolve, .history = &history });
            c.gtk_box_append(u.cast(c.GtkBox, list), e.*.root);
        }
        defer for (editors) |e| e.destroy();
        const historical = try ExcerptEditor.create(a, try Excerpt.snapshot(a, 1, "Historical café λ🌱\n", .{}), "Read-only history", .{ .context = &sources, .resolve = Sources.resolve });
        defer historical.destroy();
        c.gtk_box_append(u.cast(c.GtkBox, list), historical.root);
        const full = try View.create(sources.docs[0]);
        defer full.destroy();
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), list);
        c.gtk_widget_set_hexpand(scroll, 1);
        const panes = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
        c.gtk_box_append(u.cast(c.GtkBox, panes), scroll);
        c.gtk_box_append(u.cast(c.GtkBox, panes), full.page);
        const w = try window(panes);
        // Explicitly detach excerpt roots before their owned references are freed.
        defer {
            c.gtk_window_destroy(u.cast(c.GtkWindow, w));
        }
        try settle();
        sample("construct-100-excerpts-map-settle", cycle, start);
        memory("opened", cycle, 10, 102);
        if (!historical.excerpt.read_only or c.gtk_text_view_get_editable(u.cast(c.GtkTextView, historical.widget)) != 0) return error.EditableHistory;
        for (0..110) |i| {
            // 10 excluded warmups, then 100 edit/undo pairs x 5 trials = 1,000 samples.
            const begin = now();
            var mapped: [3]@import("editor/excerpt.zig").Mapped = undefined;
            var changes: [3]tx.Change = undefined;
            for ([_]usize{ 0, 50, 99 }, 0..) |idx, j| {
                mapped[j] = try editors[idx].excerpt.map(a, target(sources.docs[idx / 10]), &.{.{ .start = 20, .end = 20, .text = "Ω" }});
                changes[j] = mapped[j].change;
            }
            defer for (&mapped) |*m| m.deinit();
            try history.perform("First/middle/last grouped excerpt edit", &changes);
            // Exercise the actual coalesced source-change idle refresh path,
            // not 100 redundant manual refreshes of unchanged source documents.
            try drain();
            if (i >= 10) sample("grouped-edit-refresh-drain", cycle * 100 + i - 10, begin);
            const undo_start = now();
            try history.undo(&sources.targets());
            try drain();
            if (i >= 10) sample("grouped-undo-refresh-drain", cycle * 100 + i - 10, undo_start);
        }
        // A canonical source edit must refresh its excerpts and full presentation.
        const refresh_start = now();
        try history.perform("External source edit", &.{.{ .target = target(sources.docs[0]), .replacements = &.{.{ .start = 20, .end = 20, .text = "外" }} }});
        try drain();
        for (editors) |e| try e.refresh();
        sample("source-edit-refresh-drain", cycle, refresh_start);
        try history.undo(&sources.targets());
        try drain();
        for (editors, 0..) |e, i| {
            try e.refresh();
            const offset = (i % 10) * 30 * 64;
            try verify(e.display, fixtures[i / 10][offset..][0 .. 20 * 64]);
        }
        for (sources.docs, fixtures, 0..) |d, bytes, i| {
            try verify(d.buffer, bytes);
            const text = u.bufferText(d.buffer);
            defer a.free(text);
            hash("excerpt-restored", i, text);
        }
        try verify(full.buffer, fixtures[0]);
        try verify(historical.display, "Historical café λ🌱\n");
        memory("edited", cycle, 10, 102);
    }
    try settle();
    memory("closed", 5, 0, 0);
}
const BoundedContext = struct {
    d: *Document,
    history: *History,
    box: *c.GtkWidget,
    editor: ?*ExcerptEditor = null,
    failure: ?anyerror = null,
    start_byte: usize = 0,
    end_byte: usize = 0,

    fn resolve(data: ?*anyopaque, id: u64) ?tx.Target {
        const self = u.cast(BoundedContext, data.?);
        return if (id == self.d.id) target(self.d) else null;
    }
    fn open(data: ?*anyopaque, offset: c_int) void {
        const self = u.cast(BoundedContext, data.?);
        self.openAt(offset) catch |err| {
            self.failure = err;
        };
    }
    fn openAt(self: *BoundedContext, offset: c_int) !void {
        // Same byte/character conversion and production limit as App.openBoundedExcerpt.
        // Only controller glue lives here; guard, mapping, widget and history are production.
        const text = u.bufferText(self.d.buffer);
        defer a.free(text);
        self.start_byte = @import("editor/excerpt.zig").byteAtChar(text, @intCast(offset));
        self.end_byte = self.start_byte + @import("editor/excerpt.zig").byteAtChar(text[self.start_byte..], policy.excerpt_char_limit);
        var excerpt = try Excerpt.init(a, target(self.d), .{ .start = self.start_byte, .end = self.end_byte }, false, .{});
        errdefer excerpt.deinit();
        const editor = try ExcerptEditor.create(a, excerpt, "Production long-line policy — bounded 2,048-character excerpt", .{ .context = self, .resolve = resolve, .history = self.history });
        self.editor = editor;
        c.gtk_box_append(u.cast(c.GtkBox, self.box), editor.root);
    }
};
fn boundedExcerpt() !void {
    const bytes = try fixture(number("BENCH_BYTES", 1048576), 0, true);
    defer a.free(bytes);
    const wrap = number("BENCH_WRAP", 0) != 0;
    for (0..5) |cycle| {
        memory("baseline", cycle, 0, 0);
        const begin = now();
        const d = try document(cycle + 1, bytes);
        defer d.destroy();
        const full = try View.create(d);
        var full_alive = true;
        defer if (full_alive) full.destroy();
        var history = History.init(a, .{});
        defer history.deinit();
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
        c.gtk_box_append(u.cast(c.GtkBox, box), full.page);
        var context: BoundedContext = .{ .d = d, .history = &history, .box = box };
        defer if (context.editor) |editor| editor.destroy();
        const w = try window(box);
        defer c.gtk_window_destroy(u.cast(c.GtkWindow, w));
        full.layout_guard.setHandler(&context, &BoundedContext.open);
        defer if (full_alive) full.layout_guard.setHandler(null, null);
        const count = c.gtk_text_buffer_get_char_count(d.buffer);
        const offset: c_int = switch (cycle % 3) {
            0 => 0,
            1 => @divTrunc(count, 2),
            else => count - policy.excerpt_char_limit,
        };
        c.gtk_spin_button_set_value(full.layout_guard.offset, @floatFromInt(offset));
        c.g_signal_emit_by_name(full.layout_guard.button, "clicked");
        if (context.failure) |err| return err;
        const editor = context.editor orelse return error.BoundedExcerptNotOpened;
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, editor.widget), if (wrap) c.GTK_WRAP_CHAR else c.GTK_WRAP_NONE);
        _ = c.gtk_widget_grab_focus(editor.widget);
        try settle();
        if (!full.layout_guard.blocked or !policy.limited(d.buffer) or c.gtk_widget_get_mapped(full.widget) != 0 or c.gtk_widget_get_mapped(full.layout_guard.notice) == 0) return error.FullParagraphNotGuarded;
        if (editor.layout_guard.blocked or c.gtk_widget_get_mapped(editor.widget) == 0 or c.gtk_text_buffer_get_char_count(editor.display) != policy.excerpt_char_limit) return error.BoundedEditorUnavailable;
        if (c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, d.buffer)) != null) return error.SyntaxPolicyNotApplied;
        std.debug.print("{{\"kind\":\"policy\",\"variant\":\"production-bounded-excerpt\",\"cycle\":{d},\"offset_chars\":{d},\"excerpt_chars\":{d},\"full_guarded\":true,\"excerpt_mapped\":true,\"syntax_limited\":true}}\n", .{ cycle, offset, policy.excerpt_char_limit });
        if (number("BENCH_CLOSE_SOURCE_VIEW", 0) != 0) {
            // Explicit production workflow: the excerpt owns no source document,
            // but the registry/caller keeps it alive after closing the full tab.
            full.layout_guard.setHandler(null, null);
            c.gtk_box_remove(u.cast(c.GtkBox, box), full.page);
            full.destroy();
            full_alive = false;
            try settle();
        }
        std.debug.print("{{\"kind\":\"fallback-views\",\"cycle\":{d},\"guarded_source_view_retained\":{}}}\n", .{ cycle, full_alive });
        sample("bounded-construct-map-settle", cycle, begin);
        memory("opened", cycle, 1, if (full_alive) 2 else 1);
        for (0..110) |i| {
            const char_offset: usize = switch (i % 3) {
                0 => 20,
                1 => policy.excerpt_char_limit / 2,
                else => policy.excerpt_char_limit - 1,
            };
            const byte_offset = @import("editor/excerpt.zig").byteAtChar(editor.cached, char_offset);
            var start = now();
            try editor.replace(.{ .start = byte_offset, .end = byte_offset, .text = "Ω" });
            try drain();
            if (i >= 10) sample("bounded-edit-refresh-drain", cycle * 100 + i - 10, start);
            if (c.gtk_text_buffer_get_char_count(d.buffer) != count + 1 or c.gtk_text_buffer_get_char_count(editor.display) != policy.excerpt_char_limit + 1) return error.BoundedEditNotApplied;
            var at: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(d.buffer, &at, offset + @as(c_int, @intCast(char_offset)));
            if (c.gtk_text_iter_get_char(&at) != 'Ω') return error.BoundedEditWrongLocation;
            start = now();
            try history.undo(&.{target(d)});
            try drain();
            if (i >= 10) sample("bounded-undo-refresh-drain", cycle * 100 + i - 10, start);
            if (c.gtk_text_buffer_get_char_count(d.buffer) != count or editor.layout_guard.blocked) return error.BoundedUndoFailed;
        }
        try verify(d.buffer, bytes);
        if (full_alive) try verify(full.buffer, bytes);
        try verify(editor.display, bytes[context.start_byte..context.end_byte]);
        const restored = u.bufferText(d.buffer);
        defer a.free(restored);
        hash("bounded-restored-output", cycle, restored);
        memory("edited", cycle, 1, if (full_alive) 2 else 1);
    }
    try settle();
    memory("closed", 5, 0, 0);
}
fn frameProbe() !void {
    const d = try document(1, "frame probe café\n");
    defer d.destroy();
    const v = try View.create(d);
    defer v.destroy();
    const w = try window(v.page);
    defer c.gtk_window_destroy(u.cast(c.GtkWindow, w));
    const clock = c.gtk_widget_get_frame_clock(v.widget) orelse return error.NoFrameClock;
    for (0..20) |i| {
        const next = c.gdk_frame_clock_get_frame_counter(clock) + 1;
        const begin = now();
        var at: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_end_iter(v.buffer, &at);
        c.gtk_text_buffer_insert(v.buffer, &at, "Ω", 2);
        c.gtk_widget_queue_draw(v.widget);
        c.gdk_frame_clock_request_phase(clock, c.GDK_FRAME_CLOCK_PHASE_PAINT);
        var complete_time: i64 = 0;
        var presented: i64 = 0;
        while (now() - begin < 250_000) {
            try drain();
            if (c.gdk_frame_clock_get_timings(clock, next)) |timings| {
                if (c.gdk_frame_timings_get_complete(timings) != 0) {
                    complete_time = now();
                    presented = c.gdk_frame_timings_get_presentation_time(timings);
                    break;
                }
            }
            c.g_usleep(1000);
        }
        // A complete frame with presentation_time=0 is NOT presentation feedback.
        std.debug.print("{{\"kind\":\"frame-probe\",\"index\":{d},\"requested_frame\":{d},\"operation_us\":{d},\"complete_observed_us\":{d},\"gdk_presentation_us\":{d}}}\n", .{ i, next, begin, complete_time, presented });
        if (presented >= begin and complete_time != 0) {
            std.debug.print("{{\"kind\":\"sample\",\"metric\":\"programmatic-update-to-GDK-reported-presentation\",\"index\":{d},\"us\":{d}}}\n", .{ i, presented - begin });
        }
    }
    const expected = u.bufferText(d.buffer);
    defer a.free(expected);
    try verify(v.buffer, expected);
}
fn complete(_: *process.Job, _: process.Result, _: ?*anyopaque) void {}
fn transport() !void {
    for (0..20) |i| {
        var start = now();
        const job = try process.start(a, .{ .authorization = .approved, .identity = .{ .scope = "benchmark", .request = i, .generation = 1 }, .argv = &.{ "/bin/printf", "héλ🙂" }, .cwd = "/", .output_limit = 4096, .timeout_ms = 3000 }, complete, null);
        defer job.destroy();
        while (!job.isComplete()) {
            try drain();
            if (now() - start > 5_000_000) return error.CaptureTimeout;
            c.g_usleep(100);
        }
        const result = job.result();
        if (result.outcome != .success or !result.reaped or !std.mem.eql(u8, result.stdout, "héλ🙂")) return error.CaptureFailed;
        sample("process-capture-reaped", i, start);
        start = now();
        var handle = try pty.start(.{ .authorization = .approved, .argv = &.{ "/bin/printf", "héλ🙂" }, .cwd = "/" });
        defer handle.deinit();
        try handle.resize(41, 109);
        var buffer: [128]u8 = undefined;
        var used: usize = 0;
        while (true) {
            if (now() - start > 3_000_000) return error.PtyTimeout;
            const n = handle.read(buffer[used..]) catch |err| switch (err) {
                error.WouldBlock => {
                    c.g_usleep(100);
                    continue;
                },
                else => return err,
            };
            if (n == 0) break;
            used += n;
            if (used == buffer.len) return error.PtyOutputLimit;
        }
        const report = handle.wait();
        if (report.reaped != 1 or report.status != 0 or !std.mem.eql(u8, buffer[0..used], "héλ🙂")) return error.PtyFailed;
        sample("pty-spawn-resize-read-reaped", i, start);
    }
}
pub fn main() !void {
    if (c.gtk_init_check() == 0) return error.PrivateDisplayRequired;
    c.gtk_source_init();
    var font: [*c]u8 = null;
    var theme: [*c]u8 = null;
    c.g_object_get(c.gtk_settings_get_default(), "gtk-font-name", &font, "gtk-theme-name", &theme, @as(?*anyopaque, null));
    defer c.g_free(font);
    defer c.g_free(theme);
    const settings = try std.json.Stringify.valueAlloc(a, .{ .kind = "settings", .font = std.mem.span(font), .theme = std.mem.span(theme), .monospace = true }, .{});
    defer a.free(settings);
    std.debug.print("{s}\n", .{settings});
    memory("idle", 0, 0, 0);
    const mode = env("BENCH_MODE", "B01");
    if (std.mem.eql(u8, mode, "fixtures")) try prepareFixtures() else if (std.mem.eql(u8, mode, "B01")) try startup() else if (std.mem.eql(u8, mode, "B02")) try input(false) else if (std.mem.eql(u8, mode, "B03")) try input(true) else if (std.mem.eql(u8, mode, "B04")) try tabs() else if (std.mem.eql(u8, mode, "B05")) try excerpts() else if (std.mem.eql(u8, mode, "B03-bounded-excerpt")) try boundedExcerpt() else if (std.mem.eql(u8, mode, "frame-probe")) try frameProbe() else if (std.mem.eql(u8, mode, "transport")) try transport() else return error.UnknownWorkload;
    try settle();
    memory("closed", 0, 0, 0);
    std.debug.print("{{\"kind\":\"complete\",\"failures\":0}}\n", .{});
}
