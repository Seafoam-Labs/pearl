const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const codec = @import("platform/codec.zig");
pub const Document = struct {
    id: u64,
    buffer: *c.GtkTextBuffer,
    view: u.W,
    page: u.W,
    tab: u.W,
    tab_label: u.W,
    search: *c.GtkSourceSearchContext,
    search_settings: *c.GtkSourceSearchSettings,
    tag: *c.GtkTextTag,
    path: ?[:0]u8 = null,
    etag: ?[:0]u8 = null,
    revision: u64 = 0,
    saved_revision: u64 = 0,
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
    pub fn dirty(d: *Document) bool {
        return c.gtk_text_buffer_get_modified(d.buffer) != 0;
    }
    pub fn destroy(d: *Document) void {
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
        c.g_object_unref(d.search);
        c.g_object_unref(d.search_settings);
        c.g_object_unref(d.buffer);
        u.a.destroy(d);
    }
};
