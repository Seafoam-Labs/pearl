const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const codec = @import("platform/codec.zig");
pub const Document = struct {
    id: u64,
    buffer: *c.GtkTextBuffer,
    /// Controller callback context; documents never own editor widgets.
    context: ?*anyopaque = null,
    search: *c.GtkSourceSearchContext,
    search_settings: *c.GtkSourceSearchSettings,
    tag: *c.GtkTextTag,
    path: ?[:0]u8 = null,
    etag: ?[:0]u8 = null,
    external_changed: bool = false,
    monitor: ?*c.GFileMonitor = null,
    watch_generation: u64 = 0,
    /// Borrowed from the async operation; cancellation does not mean it is reaped.
    watch_query: ?*c.GCancellable = null,
    watch_pending: bool = false,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    /// A stale save moved disk away from GTK's clean undo checkpoint. Until a
    /// current-revision save/load establishes a new checkpoint, GTK's modified
    /// flag alone cannot safely authorize closing the document.
    saved_checkpoint_stale: bool = false,
    bom: bool = false,
    newline: codec.Newline = .lf,
    normalize_save_as: bool = false,
    busy: bool = false,
    loading: bool = false,
    close_after_save: bool = false,
    cancelled_close: bool = false,
    cancellable: ?*c.GCancellable = null,
    large: bool = false,
    spell_override: ?bool = null,
    priority_start: c_int = 0,
    priority_end: c_int = 0,
    priority_revision: u64 = 0,
    check_from: c_int = 0,
    inflight: bool = false,
    due: i64 = 0,
    ignored: std.StringHashMapUnmanaged(void) = .empty,
    pending: ?codec.Decoded = null,
    pending_etag: ?[:0]u8 = null,
    pending_revision: u64 = 0,
    pending_reload: bool = false,
    pub fn create(id: u64, context: ?*anyopaque) std.mem.Allocator.Error!*Document {
        const d = try u.a.create(Document);
        const source = c.gtk_source_buffer_new(null).?;
        const buffer = u.cast(c.GtkTextBuffer, source);
        c.gtk_text_buffer_set_enable_undo(buffer, 1);
        const settings = c.gtk_source_search_settings_new().?;
        c.gtk_source_search_settings_set_wrap_around(settings, 1);
        d.* = .{
            .id = id,
            .context = context,
            .buffer = buffer,
            .search = c.gtk_source_search_context_new(source, settings).?,
            .search_settings = settings,
            .tag = c.gtk_text_buffer_create_tag(buffer, "coral-spelling", "underline", @as(c_int, c.PANGO_UNDERLINE_ERROR), @as(?*anyopaque, null)).?,
        };
        // Connect before controller observers: every producer sees the new revision.
        u.connect(buffer, "changed", &changed, d);
        return d;
    }
    fn changed(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const d = u.cast(Document, data.?);
        d.revision = std.math.add(u64, d.revision, 1) catch @panic("Document revision exhausted");
    }
    pub fn dirty(d: *Document) bool {
        return d.saved_checkpoint_stale or c.gtk_text_buffer_get_modified(d.buffer) != 0;
    }
    pub fn recordSavedRevision(d: *Document, revision: u64) void {
        d.saved_revision = revision;
        d.saved_checkpoint_stale = revision != d.revision;
        c.gtk_text_buffer_set_modified(d.buffer, @intFromBool(d.saved_checkpoint_stale));
        @import("editor/native_history.zig").recordSavedCheckpoint(d.buffer, !d.saved_checkpoint_stale);
    }
    pub fn stopWatching(d: *Document) void {
        d.watch_generation = std.math.add(u64, d.watch_generation, 1) catch @panic("Watcher generation exhausted");
        d.watch_pending = false;
        if (d.monitor) |monitor| {
            _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, d.context);
            _ = c.g_file_monitor_cancel(monitor);
            c.g_object_unref(monitor);
            d.monitor = null;
        }
        if (d.watch_query) |query| c.g_cancellable_cancel(query);
    }
    pub fn destroy(d: *Document) void {
        d.stopWatching();
        if (d.cancellable) |p| {
            c.g_cancellable_cancel(p);
            c.g_object_unref(p);
        }
        if (d.pending) |p| u.a.free(p.text);
        if (d.pending_etag) |p| u.a.free(p);
        if (d.path) |p| u.a.free(p);
        if (d.etag) |p| u.a.free(p);
        var it = d.ignored.keyIterator();
        while (it.next()) |key| u.a.free(key.*);
        d.ignored.deinit(u.a);
        // Prepared edits may retain the buffer after its canonical document closes.
        // Those references must not keep callbacks to this destroyed owner.
        _ = c.g_signal_handlers_disconnect_matched(d.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, d);
        c.g_object_unref(d.search);
        c.g_object_unref(d.search_settings);
        c.g_object_unref(d.buffer);
        u.a.destroy(d);
    }
};
