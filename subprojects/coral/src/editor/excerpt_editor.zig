//! Native editable excerpt spike, independent of app/registry/view. A GtkSourceView
//! displays ONLY the bounded region; the header is a separate noneditable label.
//! Each insert/delete is intercepted BEFORE GTK's default handler and submitted as
//! a checked canonical transaction (optionally via workspace History). The display
//! has no native undo stack: route app undo/redo to History, never this buffer.
//!
//! create takes ownership of Excerpt ONLY on success. Keep callback context/history
//! alive until destroy; resolve must return fresh registry Targets or null on close.
//! No canonical revision pointer is saved. Source notifications coalesce to an idle
//! refresh; pending stale projections reject input, refresh, and report StaleRevision
//! rather than applying offsets to changed text. GLib OOM follows GTK's fatal policy.
//! Callbacks must not reenter, destroy the editor, or run a nested main loop. This
//! spike records each insert/delete separately; selection replacement should use
//! replace() for a single history record rather than two native buffer operations.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const tx = @import("transactions.zig");
const ex = @import("excerpt.zig");
const History = @import("history.zig").History;
pub const Options = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, u64) ?tx.Target,
    history: ?*History = null,
    /// Called after a complete committed edit. Parent may checkpoint recovery here.
    committed: ?*const fn (?*anyopaque) void = null,
    failed: ?*const fn (?*anyopaque, anyerror) void = null,
};
pub const Editor = struct {
    allocator: std.mem.Allocator,
    excerpt: ex.Excerpt,
    options: Options,
    /// Owned sunk root. Unparent before destroy; widget/display are borrowed.
    root: *c.GtkWidget,
    widget: *c.GtkWidget,
    display: *c.GtkTextBuffer,
    layout_guard: *@import("layout_guard.zig").Guard,
    cached: []u8,
    revision: ?u64,
    cached_bounds: [2]c_int = .{ -1, -1 },
    // A real changed signal invalidates cached bytes even if the owner missed a
    // revision increment. Coalesce signals, but never use revision as a text hash.
    source_dirty: bool = false,
    text_dirty: bool = false,
    observed_bounds: [2]c_int = .{ -1, -1 },
    pending: ?struct { count: c_int, delta: c_int, dirty: bool } = null,
    // Canonical marks disambiguate edits in repeated text, where a string diff
    // alone cannot determine which occurrence was inserted/deleted.
    selection: ?[2]*c.GtkTextMark = null,
    syncing: bool = false,
    idle: c_uint = 0,
    last_error: ?anyerror = null,

    pub fn create(a: std.mem.Allocator, excerpt: ex.Excerpt, header: [:0]const u8, options: Options) !*Editor {
        const target = options.resolve(options.context, excerpt.id);
        const text = try excerpt.text(a, target);
        errdefer a.free(text);
        const self = try a.create(Editor);
        errdefer a.destroy(self);
        const display = u.cast(c.GtkTextBuffer, c.gtk_source_buffer_new(null).?);
        errdefer c.g_object_unref(display);
        c.gtk_text_buffer_set_enable_undo(display, 0);
        c.gtk_text_buffer_set_text(display, text.ptr, @intCast(text.len));
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        _ = c.g_object_ref_sink(root);
        errdefer c.g_object_unref(root);
        const label = c.gtk_label_new(header).?;
        c.gtk_label_set_xalign(u.cast(c.GtkLabel, label), 0);
        c.gtk_box_append(u.cast(c.GtkBox, root), label);
        const widget = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, display)).?;
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, widget), 1);
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), widget);
        c.gtk_box_append(u.cast(c.GtkBox, root), scroll);
        const layout_guard = try @import("layout_guard.zig").Guard.attach(u.cast(c.GtkScrolledWindow, scroll), widget, display);
        self.* = .{ .allocator = a, .excerpt = excerpt, .options = options, .root = root, .widget = widget, .display = display, .layout_guard = layout_guard, .cached = text, .revision = if (target) |t| t.expected_revision else null };
        u.connect(display, "insert-text", &insert, self);
        u.connect(display, "delete-range", &delete, self);
        if (excerpt.source) |source| {
            var at: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_mark(source.buffer, &at, source.start);
            self.selection = .{ c.gtk_text_buffer_create_mark(source.buffer, null, &at, 0).?, c.gtk_text_buffer_create_mark(source.buffer, null, &at, 0).? };
            u.connect(source.buffer, "insert-text", &sourceInsert, self);
            u.connect(source.buffer, "delete-range", &sourceDelete, self);
            u.connect(source.buffer, "insert-child-anchor", &sourceObject, self);
            u.connect(source.buffer, "insert-paintable", &sourceObject, self);
            u.connect(source.buffer, "changed", &sourceChanged, self);
            self.saveSelection();
            u.connect(display, "mark-set", &selectionChanged, self);
        }
        self.cached_bounds = self.bounds();
        self.observed_bounds = self.cached_bounds;
        self.setEditable(target);
        return self;
    }
    pub fn destroy(self: *Editor) void {
        std.debug.assert(c.gtk_widget_get_parent(self.root) == null);
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.excerpt.source) |source| {
            disconnect(source.buffer, self);
            if (self.selection) |marks| for (marks) |mark| c.gtk_text_buffer_delete_mark(source.buffer, mark);
        }
        disconnect(self.display, self);
        self.layout_guard.setHandler(null, null);
        // External widget refs cannot continue editing an orphaned display.
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), 0);
        c.g_object_unref(self.root);
        c.g_object_unref(self.display);
        self.excerpt.deinit();
        self.allocator.free(self.cached);
        self.allocator.destroy(self);
    }
    /// Also call after registry close or policy changes (which need not emit changed).
    pub fn refresh(self: *Editor) !void {
        if (self.idle != 0) {
            _ = c.g_source_remove(self.idle);
            self.idle = 0;
        }
        const target = self.options.resolve(self.options.context, self.excerpt.id);
        self.excerpt.validateRead(target) catch |err| {
            c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), 0);
            return err;
        };
        const current_bounds = self.bounds();
        const revision = if (target) |t| t.expected_revision else null;
        const unchanged = !self.source_dirty and (self.excerpt.historical != null or self.revision == revision) and std.mem.eql(c_int, &self.cached_bounds, &current_bounds);
        const outside = self.source_dirty and !self.text_dirty and std.mem.eql(c_int, &self.observed_bounds, &current_bounds);
        if (unchanged or outside) {
            if (outside) {
                self.revision = revision;
                self.cached_bounds = current_bounds;
                self.source_dirty = false;
                self.syncing = true;
                defer self.syncing = false;
                self.restoreSelection();
            }
            self.setEditable(target);
            return;
        }
        const text = self.excerpt.text(self.allocator, target) catch |err| {
            c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), 0);
            return err;
        };
        self.syncing = true;
        defer self.syncing = false;
        if (!std.mem.eql(u8, self.cached, text)) {
            // Apply only the differing UTF-8 span. GTK moves directed selections,
            // marks and unaffected annotation ranges with the edit; set_text would
            // discard all of them and force a complete layout/highlight pass.
            var prefix: usize = 0;
            while (prefix < @min(self.cached.len, text.len) and self.cached[prefix] == text[prefix]) : (prefix += 1) {}
            while (prefix > 0 and prefix < text.len and text[prefix] & 0xc0 == 0x80) prefix -= 1;
            var suffix: usize = 0;
            while (suffix < @min(self.cached.len, text.len) - prefix and self.cached[self.cached.len - suffix - 1] == text[text.len - suffix - 1]) : (suffix += 1) {}
            while (suffix > 0 and text[text.len - suffix] & 0xc0 == 0x80) suffix -= 1;
            const offset: c_int = @intCast(std.unicode.utf8CountCodepoints(text[0..prefix]) catch unreachable);
            const removed: c_int = @intCast(std.unicode.utf8CountCodepoints(self.cached[prefix .. self.cached.len - suffix]) catch unreachable);
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(self.display, &start, offset);
            c.gtk_text_buffer_get_iter_at_offset(self.display, &end, offset + removed);
            if (removed != 0) c.gtk_text_buffer_delete(self.display, &start, &end);
            const added = text[prefix .. text.len - suffix];
            if (added.len != 0) c.gtk_text_buffer_insert(self.display, &start, added.ptr, @intCast(added.len));
        }
        self.allocator.free(self.cached);
        self.cached = text;
        self.revision = revision;
        self.cached_bounds = current_bounds;
        self.source_dirty = false;
        self.text_dirty = false;
        self.observed_bounds = current_bounds;
        self.restoreSelection();
        self.setEditable(target);
    }
    fn saveSelection(self: *Editor) void {
        const marks = self.selection orelse return;
        const source = self.excerpt.source.?;
        const current = self.options.resolve(self.options.context, self.excerpt.id) orelse return;
        if (self.revision != current.revision.* or current.buffer != source.buffer) return;
        const base = self.bounds()[0];
        for (marks, [_]?*c.GtkTextMark{ c.gtk_text_buffer_get_insert(self.display), c.gtk_text_buffer_get_selection_bound(self.display) }) |mark, local| {
            var at: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_mark(self.display, &at, local);
            const offset = base + c.gtk_text_iter_get_offset(&at);
            c.gtk_text_buffer_get_iter_at_offset(source.buffer, &at, offset);
            c.gtk_text_buffer_move_mark(source.buffer, mark, &at);
        }
    }
    fn restoreSelection(self: *Editor) void {
        const marks = self.selection orelse return;
        const source = self.excerpt.source.?;
        var iters: [2]c.GtkTextIter = undefined;
        const count = c.gtk_text_buffer_get_char_count(self.display);
        for (marks, &iters) |mark, *at| {
            c.gtk_text_buffer_get_iter_at_mark(source.buffer, at, mark);
            const offset = std.math.clamp(c.gtk_text_iter_get_offset(at) - self.cached_bounds[0], 0, count);
            c.gtk_text_buffer_get_iter_at_offset(self.display, at, offset);
        }
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(self.display, &insertion, c.gtk_text_buffer_get_insert(self.display));
        c.gtk_text_buffer_get_iter_at_mark(self.display, &bound, c.gtk_text_buffer_get_selection_bound(self.display));
        // Unaffected excerpts must not emit selection notifications (and trigger
        // status, recovery, PRIMARY ownership and layout) on every source edit.
        if (c.gtk_text_iter_equal(&insertion, &iters[0]) == 0 or c.gtk_text_iter_equal(&bound, &iters[1]) == 0)
            c.gtk_text_buffer_select_range(self.display, &iters[0], &iters[1]);
    }
    fn selectionChanged(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, mark: ?*c.GtkTextMark, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        if (!self.syncing and (mark == c.gtk_text_buffer_get_insert(buffer) or mark == c.gtk_text_buffer_get_selection_bound(buffer))) self.saveSelection();
    }
    fn bounds(self: *const Editor) [2]c_int {
        const source = self.excerpt.source orelse return .{ 0, 0 };
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &start, source.start);
        c.gtk_text_buffer_get_iter_at_mark(source.buffer, &end, source.end);
        return .{ c.gtk_text_iter_get_offset(&start), c.gtk_text_iter_get_offset(&end) };
    }
    /// Checked display-relative UTF-8 replacement, also useful for paste/commands.
    pub fn replace(self: *Editor, replacement: tx.Replacement) !void {
        if (self.syncing or tx.isApplying()) return error.Busy;
        if (self.excerpt.read_only) return error.ReadOnly;
        const target = self.options.resolve(self.options.context, self.excerpt.id) orelse return error.TargetMismatch;
        if (self.source_dirty or self.revision == null or self.revision.? != target.revision.* or target.expected_revision != target.revision.*) {
            try self.refresh();
            return error.StaleRevision;
        }
        var mapped = try self.excerpt.map(self.allocator, target, &.{replacement});
        defer mapped.deinit();
        if (self.options.history) |history| {
            try history.perform("Edit excerpt", &.{mapped.change});
        } else {
            var plan = try tx.prepare(self.allocator, &.{mapped.change}, self.excerpt.limits);
            defer plan.deinit();
            try plan.commit(&.{target});
        }
        // Commit already succeeded: a refresh failure is reported, NOT returned as
        // an edit failure that a caller might retry and apply twice.
        self.refresh() catch |err| self.report(err);
        if (self.options.committed) |callback| callback(self.options.context);
    }
    fn setEditable(self: *Editor, target: ?tx.Target) void {
        const editable = !self.excerpt.read_only and if (target) |t| t.writable and !t.busy else false;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), @intFromBool(editable));
    }
    fn report(self: *Editor, err: anyerror) void {
        self.last_error = err;
        if (self.options.failed) |callback| callback(self.options.context, err);
    }
    fn insert(buffer: ?*c.GtkTextBuffer, iter: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        if (self.syncing) return;
        c.g_signal_stop_emission_by_name(buffer, "insert-text");
        const offset = c.gtk_text_iter_get_offset(iter);
        const byte = ex.byteAtChar(self.cached, @intCast(offset));
        const bytes = text[0..@intCast(len)];
        const added = std.unicode.utf8CountCodepoints(bytes) catch 0;
        self.replace(.{ .start = byte, .end = byte, .text = bytes }) catch |err| {
            self.report(err);
            c.gtk_text_buffer_get_iter_at_offset(self.display, iter, @min(offset, c.gtk_text_buffer_get_char_count(self.display)));
            return;
        };
        c.gtk_text_buffer_get_iter_at_offset(self.display, iter, @min(offset + @as(c_int, @intCast(added)), c.gtk_text_buffer_get_char_count(self.display)));
        c.gtk_text_buffer_place_cursor(self.display, iter);
    }
    fn delete(buffer: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        if (self.syncing) return;
        c.g_signal_stop_emission_by_name(buffer, "delete-range");
        const offset = c.gtk_text_iter_get_offset(start);
        const a = ex.byteAtChar(self.cached, @intCast(offset));
        const b = ex.byteAtChar(self.cached, @intCast(c.gtk_text_iter_get_offset(end)));
        self.replace(.{ .start = a, .end = b, .text = "" }) catch |err| self.report(err);
        c.gtk_text_buffer_get_iter_at_offset(self.display, start, @min(offset, c.gtk_text_buffer_get_char_count(self.display)));
        end.?.* = start.?.*;
        c.gtk_text_buffer_place_cursor(self.display, start);
    }
    fn sourceBounds(self: *const Editor) ?[2]c_int {
        const source = self.excerpt.source orelse return null;
        if (c.gtk_text_mark_get_buffer(source.start) != source.buffer or c.gtk_text_mark_get_buffer(source.end) != source.buffer) return null;
        return self.bounds();
    }
    fn sourceInsert(buffer: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        self.pending = null;
        const region = self.sourceBounds() orelse return;
        const offset = c.gtk_text_iter_get_offset(at);
        self.pending = .{ .count = c.gtk_text_buffer_get_char_count(buffer), .delta = @intCast(c.g_utf8_strlen(text, len)), .dirty = !std.mem.eql(c_int, &region, &self.observed_bounds) or (offset >= region[0] and offset <= region[1]) };
    }
    fn sourceDelete(buffer: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        self.pending = null;
        const region = self.sourceBounds() orelse return;
        const first = c.gtk_text_iter_get_offset(start);
        const last = c.gtk_text_iter_get_offset(end);
        self.pending = .{ .count = c.gtk_text_buffer_get_char_count(buffer), .delta = first - last, .dirty = !std.mem.eql(c_int, &region, &self.observed_bounds) or (first < region[1] and last > region[0]) };
    }
    fn sourceObject(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        // Also discard a pending insert whose default handler was cancelled.
        u.cast(Editor, data.?).pending = null;
    }
    fn sourceChanged(buffer: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Editor, data.?);
        // Only a recognized, matching insert/delete can prove that bounded text
        // did not change. Unknown/object changes always take the checked read path.
        const dirty = if (self.pending) |p| p.dirty or @as(i64, p.count) + p.delta != c.gtk_text_buffer_get_char_count(buffer) else true;
        self.pending = null;
        self.text_dirty = self.text_dirty or dirty;
        self.source_dirty = true;
        self.observed_bounds = self.sourceBounds() orelse .{ -1, -1 };
        if (self.idle == 0) self.idle = c.g_idle_add(&refreshIdle, self);
    }
    fn refreshIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self = u.cast(Editor, data.?);
        self.idle = 0;
        self.refresh() catch |err| self.report(err);
        return 0;
    }
};
fn disconnect(object: anytype, data: *Editor) void {
    _ = c.g_signal_handlers_disconnect_matched(object, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, data);
}
