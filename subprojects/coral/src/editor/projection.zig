//! GTK-thread-only, non-copyable presentation buffer. Documents remain the only
//! text/undo/dirty authority. Detach every projection before destroying Document.
//! Only plain text edits are supported (Coral does not insert child anchors/images).
//!
//! One initial snapshot; subsequent insert/delete signals apply character-offset
//! deltas. Local default handlers are stopped and canonical edits echo back through
//! the same path, so native user actions/history never accumulate on the mirror.
//! Mirror changed/mark observers must not recursively mutate canonical text.
//!
//! A shared tag table preserves tag identity/properties/priorities. Initial ranges
//! and canonical apply/remove signals preserve spelling and other annotations.
//! Each mirror also runs its own syntax engine and search context (shared search
//! settings), because GtkSourceView requests highlighting for its OWN visible
//! region. Language, style scheme and highlighting policies follow the canonical
//! objects. This trades per-pane text/highlighting memory for independent rendering.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;

pub const Projection = struct {
    document: ?*Document,
    canonical: *c.GtkTextBuffer,
    buffer: *c.GtkTextBuffer,
    search: *c.GtkSourceSearchContext,
    canonical_search: *c.GtkSourceSearchContext,
    applying: bool = false,
    user_action: bool = false,
    attached: bool = true,
    editable: bool = true,
    pending: ?Delta = null,

    const Delta = struct {
        before_count: c_int,
        start: c_int,
        end: c_int,
        // Borrowed only during the synchronous canonical insert signal.
        text: [*c]const u8 = null,
        len: c_int = 0,
    };

    pub fn create(document: *Document) !*Projection {
        _ = try @import("presentation_policy.zig").attach(document.buffer);
        const self = try u.a.create(Projection);
        const source = c.gtk_source_buffer_new(c.gtk_text_buffer_get_tag_table(document.buffer)).?;
        const buffer = u.cast(c.GtkTextBuffer, source);
        c.gtk_text_buffer_set_enable_undo(buffer, 0);
        self.* = .{
            .document = document,
            .canonical = u.cast(c.GtkTextBuffer, c.g_object_ref(document.buffer).?),
            .buffer = buffer,
            .search = c.gtk_source_search_context_new(source, document.search_settings).?,
            .canonical_search = u.cast(c.GtkSourceSearchContext, c.g_object_ref(document.search).?),
        };
        const text = u.bufferText(document.buffer);
        defer u.a.free(text);
        c.gtk_text_buffer_set_text(buffer, text.ptr, @intCast(text.len));
        copySelection(document.buffer, buffer);
        c.gtk_text_buffer_set_modified(buffer, 0);
        self.syncStyle();
        self.syncSearch();
        c.gtk_text_tag_table_foreach(c.gtk_text_buffer_get_tag_table(document.buffer), &copyTag, self);

        // Capture RUN_LAST deltas before GTK invalidates deletion iterators, but
        // apply only once canonical text changes. Pre-edit spelling invalidation
        // must still see OLD mirror coordinates, regardless of connection order.
        // Canonical handlers may cancel, but must not transform/reenter edits.
        u.connect(self.canonical, "insert-text", &canonicalInsert, self);
        u.connect(self.canonical, "delete-range", &canonicalDelete, self);
        u.connect(self.canonical, "changed", &canonicalChanged, self);
        u.connect(self.canonical, "apply-tag", &applyTag, self);
        u.connect(self.canonical, "remove-tag", &removeTag, self);
        u.connect(self.canonical, "notify::language", &styleChanged, self);
        u.connect(self.canonical, "notify::style-scheme", &styleChanged, self);
        u.connect(self.canonical, "notify::highlight-syntax", &styleChanged, self);
        u.connect(self.canonical, "notify::highlight-matching-brackets", &styleChanged, self);
        u.connect(self.canonical_search, "notify::highlight", &searchChanged, self);
        u.connect(self.canonical_search, "notify::match-style", &searchChanged, self);
        u.connect(buffer, "insert-text", &localInsert, self);
        u.connect(buffer, "delete-range", &localDelete, self);
        u.connect(buffer, "begin-user-action", &beginAction, self);
        u.connect(buffer, "end-user-action", &endAction, self);
        u.connect(buffer, "modified-changed", &clearModified, self);
        return self;
    }

    /// Terminal, idempotent detach. Retained widgets keep a standalone buffer,
    /// never signal callbacks to a freed projection, view, or document.
    pub fn detach(self: *Projection) void {
        if (!self.attached) return;
        self.attached = false;
        inline for (.{ self.canonical, self.buffer, self.canonical_search }) |object|
            _ = c.g_signal_handlers_disconnect_matched(object, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.user_action) {
            self.user_action = false;
            c.gtk_text_buffer_end_user_action(self.canonical);
        }
        self.document = null;
        self.pending = null;
    }

    pub fn destroy(self: *Projection) void {
        self.detach();
        c.g_object_unref(self.search);
        c.g_object_unref(self.canonical_search);
        c.g_object_unref(self.buffer);
        c.g_object_unref(self.canonical);
        u.a.destroy(self);
    }

    fn writable(self: *Projection) bool {
        const document = self.document orelse return false;
        return self.editable and !document.loading and document.pending == null;
    }

    fn syncStyle(self: *Projection) void {
        const source = u.cast(c.GtkSourceBuffer, self.canonical);
        const target = u.cast(c.GtkSourceBuffer, self.buffer);
        c.gtk_source_buffer_set_language(target, c.gtk_source_buffer_get_language(source));
        c.gtk_source_buffer_set_style_scheme(target, c.gtk_source_buffer_get_style_scheme(source));
        c.gtk_source_buffer_set_highlight_syntax(target, c.gtk_source_buffer_get_highlight_syntax(source));
        c.gtk_source_buffer_set_highlight_matching_brackets(target, c.gtk_source_buffer_get_highlight_matching_brackets(source));
    }

    fn syncSearch(self: *Projection) void {
        c.gtk_source_search_context_set_highlight(self.search, c.gtk_source_search_context_get_highlight(self.canonical_search));
        c.gtk_source_search_context_set_match_style(self.search, c.gtk_source_search_context_get_match_style(self.canonical_search));
    }

    fn styleChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        u.cast(Projection, data.?).syncStyle();
    }

    fn searchChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        u.cast(Projection, data.?).syncSearch();
    }

    fn copyTag(tag: ?*c.GtkTextTag, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        var at: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(self.canonical, &at);
        while (true) {
            if (c.gtk_text_iter_has_tag(&at, tag) != 0) {
                const start = at;
                _ = c.gtk_text_iter_forward_to_tag_toggle(&at, tag);
                self.tagRange(tag, &start, &at, true);
            } else if (c.gtk_text_iter_forward_to_tag_toggle(&at, tag) == 0) break;
            if (c.gtk_text_iter_is_end(&at) != 0) break;
        }
    }

    fn tagRange(self: *Projection, tag: ?*c.GtkTextTag, start: *const c.GtkTextIter, end: *const c.GtkTextIter, apply: bool) void {
        // GtkSource owns this reserved namespace. Each presentation's engine
        // already maintains these ranges; forwarding canonical context churn
        // multiplies suffix retagging. Anonymous/named application tags are NEVER
        // filtered: syntax-style tags are anonymous too and cannot be identified
        // safely through the public API.
        if (c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, self.buffer)) != null and contextTag(tag.?)) return;
        // A changed observer connected before us can already apply new ranges.
        // Flush its text delta first; pre-edit tag signals leave the delta pending.
        self.ensureCurrent();
        var a: c.GtkTextIter = undefined;
        var b: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &a, c.gtk_text_iter_get_offset(start));
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &b, c.gtk_text_iter_get_offset(end));
        if (apply) c.gtk_text_buffer_apply_tag(self.buffer, tag, &a, &b) else c.gtk_text_buffer_remove_tag(self.buffer, tag, &a, &b);
    }

    fn applyTag(_: ?*c.GtkTextBuffer, tag: ?*c.GtkTextTag, a: ?*c.GtkTextIter, b: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        u.cast(Projection, data.?).tagRange(tag, a.?, b.?, true);
    }

    fn removeTag(_: ?*c.GtkTextBuffer, tag: ?*c.GtkTextTag, a: ?*c.GtkTextIter, b: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        u.cast(Projection, data.?).tagRange(tag, a.?, b.?, false);
    }

    fn canonicalInsert(_: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        std.debug.assert(!self.applying);
        self.pending = .{
            .before_count = c.gtk_text_buffer_get_char_count(self.canonical),
            .start = c.gtk_text_iter_get_offset(at.?),
            .end = c.gtk_text_iter_get_offset(at.?),
            .text = text,
            .len = len,
        };
    }

    fn canonicalDelete(_: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        std.debug.assert(!self.applying);
        self.pending = .{
            .before_count = c.gtk_text_buffer_get_char_count(self.canonical),
            .start = c.gtk_text_iter_get_offset(start.?),
            .end = c.gtk_text_iter_get_offset(end.?),
        };
    }

    fn canonicalChanged(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        u.cast(Projection, data.?).ensureCurrent();
    }

    fn ensureCurrent(self: *Projection) void {
        const delta = self.pending orelse return;
        // Also makes a stopped canonical emission harmless: no default mutation,
        // no mirror mutation. A later pre-edit signal replaces the unused delta.
        if (c.gtk_text_buffer_get_char_count(self.canonical) == delta.before_count) return;
        self.pending = null;
        std.debug.assert(!self.applying);
        self.applying = true;
        defer self.applying = false;
        var a: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, &a, delta.start);
        if (delta.text != null) {
            c.gtk_text_buffer_insert(self.buffer, &a, delta.text, delta.len);
        } else {
            var b: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(self.buffer, &b, delta.end);
            c.gtk_text_buffer_delete(self.buffer, &a, &b);
        }
    }

    fn localInsert(buffer: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, text: [*c]const u8, len: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        if (self.applying) return;
        c.g_signal_stop_emission_by_name(buffer, "insert-text");
        if (!self.writable()) return;
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.canonical, &iter, c.gtk_text_iter_get_offset(at.?));
        c.gtk_text_buffer_insert(self.canonical, &iter, text, len);
        // The nested canonical echo invalidates the caller's mirror iterator.
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, at, c.gtk_text_iter_get_offset(&iter));
    }

    fn localDelete(buffer: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, end: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        if (self.applying) return;
        c.g_signal_stop_emission_by_name(buffer, "delete-range");
        if (!self.writable()) return;
        var a: c.GtkTextIter = undefined;
        var b: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(self.canonical, &a, c.gtk_text_iter_get_offset(start.?));
        c.gtk_text_buffer_get_iter_at_offset(self.canonical, &b, c.gtk_text_iter_get_offset(end.?));
        c.gtk_text_buffer_delete(self.canonical, &a, &b);
        c.gtk_text_buffer_get_iter_at_offset(self.buffer, start, c.gtk_text_iter_get_offset(&a));
        end.?.* = start.?.*;
    }

    fn beginAction(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        if (self.applying or !self.writable()) return;
        copySelection(self.buffer, self.canonical);
        self.user_action = true;
        c.gtk_text_buffer_begin_user_action(self.canonical);
    }

    fn endAction(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(Projection, data.?);
        if (!self.user_action) return;
        self.user_action = false;
        c.gtk_text_buffer_end_user_action(self.canonical);
    }

    fn clearModified(buffer: ?*c.GtkTextBuffer, _: ?*anyopaque) callconv(.c) void {
        if (c.gtk_text_buffer_get_modified(buffer) != 0) c.gtk_text_buffer_set_modified(buffer, 0);
    }
};

fn contextTag(tag: *c.GtkTextTag) bool {
    const object = u.cast(c.GObject, tag);
    const key = "coral-source-context-tag";
    if (c.g_object_get_data(object, key)) |value| return @intFromPtr(value) == 1;
    var name: [*c]u8 = null;
    c.g_object_get(tag, "name", &name, @as(?*anyopaque, null));
    defer c.g_free(name);
    const result = name != null and std.mem.startsWith(u8, std.mem.span(name), "gtksourceview:context-classes:");
    c.g_object_set_data(object, key, @ptrFromInt(@as(usize, if (result) 1 else 2)));
    return result;
}

/// Character offsets preserve selection direction; never pass an iterator from
/// one buffer to another. Cursor bridges do not change text or request scrolling.
pub fn copySelection(from: *c.GtkTextBuffer, to: *c.GtkTextBuffer) void {
    var a: c.GtkTextIter = undefined;
    var b: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(from, &a, c.gtk_text_buffer_get_insert(from));
    c.gtk_text_buffer_get_iter_at_mark(from, &b, c.gtk_text_buffer_get_selection_bound(from));
    const insertion = c.gtk_text_iter_get_offset(&a);
    const bound = c.gtk_text_iter_get_offset(&b);
    c.gtk_text_buffer_get_iter_at_offset(to, &a, insertion);
    c.gtk_text_buffer_get_iter_at_offset(to, &b, bound);
    c.gtk_text_buffer_select_range(to, &a, &b);
}
