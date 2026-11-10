//! GTK-thread-only editor presentation. The registry owns the document; detach
//! every view before destroying its document. Each widget has its own text buffer,
//! visible selection, syntax/search rendering and scroll adjustments. All edits
//! and undo history belong to the canonical Document.buffer (see projection.zig).
//! Parent controllers route undo/redo to the document, never the mirror buffer.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;
const projection = @import("projection.zig");

// Process-wide, never recycled, and only accessed on the GTK thread.
var next_id: u64 = 1;

/// GtkSourceView moves private highlight-region marks while snapshotting. Those
/// are not caret changes: updating shell widgets then invalidates allocations
/// halfway through painting. Full views and excerpts must filter by identity,
/// not by mark names (private marks may be either named or anonymous).
pub fn isSelectionMark(buffer: *c.GtkTextBuffer, mark: *c.GtkTextMark) bool {
    return mark == c.gtk_text_buffer_get_insert(buffer) or mark == c.gtk_text_buffer_get_selection_bound(buffer);
}

/// GtkNotebook allocates scrollable tabs from their minimum requests, not the
/// labels' natural widths. Give each label a text-sized minimum, bounded by its
/// own group's allocation so narrow windows and splits retain scrollable tabs.
pub fn sizeTabLabel(widget: u.W, group_width: c_int) void {
    const label = u.cast(c.GtkLabel, widget);
    const count = c.g_utf8_strlen(c.gtk_label_get_text(label), -1);
    const limit: c_int = if (group_width >= 600) 36 else if (group_width >= 360) 24 else 16;
    c.gtk_label_set_width_chars(label, @intCast(@min(count + 2, limit)));
}

/// Non-copyable owner of two anonymous, invisible marks. Borrows the buffer, which
/// must outlive deinit(). Requires no gtk_init/display and never changes text,
/// modified state, or undo history. Positions use GTK character offsets, not bytes.
pub const Selection = struct {
    buffer: *c.GtkTextBuffer,
    insertion: *c.GtkTextMark,
    bound: *c.GtkTextMark,

    /// Capture the current insertion AND bound (including selection direction).
    pub fn init(buffer: *c.GtkTextBuffer) Selection {
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(buffer, &insertion, c.gtk_text_buffer_get_insert(buffer));
        c.gtk_text_buffer_get_iter_at_mark(buffer, &bound, c.gtk_text_buffer_get_selection_bound(buffer));
        return .{
            .buffer = buffer,
            // Both endpoints have right gravity, like GTK's built-in marks.
            // A collapsed caret stays collapsed when text is inserted at it.
            .insertion = c.gtk_text_buffer_create_mark(buffer, null, &insertion, 0).?,
            .bound = c.gtk_text_buffer_create_mark(buffer, null, &bound, 0).?,
        };
    }

    pub fn deinit(self: *Selection) void {
        c.gtk_text_buffer_delete_mark(self.buffer, self.insertion);
        c.gtk_text_buffer_delete_mark(self.buffer, self.bound);
        self.* = undefined;
    }

    pub fn save(self: *Selection) void {
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &insertion, c.gtk_text_buffer_get_insert(self.buffer));
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &bound, c.gtk_text_buffer_get_selection_bound(self.buffer));
        c.gtk_text_buffer_move_mark(self.buffer, self.insertion, &insertion);
        c.gtk_text_buffer_move_mark(self.buffer, self.bound, &bound);
    }

    /// Changes the buffer-wide visible selection, not any other saved Selection.
    pub fn restore(self: *const Selection) void {
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &insertion, self.insertion);
        c.gtk_text_buffer_get_iter_at_mark(self.buffer, &bound, self.bound);
        c.gtk_text_buffer_select_range(self.buffer, &insertion, &bound);
    }
};

pub const EditorView = struct {
    id: u64,
    document: *Document,
    /// Presentation only: use for widget iterators, navigation and selections.
    buffer: *c.GtkTextBuffer,
    projection: *projection.Projection,
    layout_guard: *@import("layout_guard.zig").Guard,
    /// Optional owner notification, called AFTER focus selection is bridged.
    /// The constructor never invokes this; clear/detach before freeing the owner.
    on_focus: ?*const fn (*EditorView) void = null,
    focus_context: ?*anyopaque = null,
    /// Borrowed from page/guard; callers must not rebind/reparent it. While
    /// layout_guard.blocked, the guard parks this hidden widget on an empty
    /// buffer. `buffer` remains the authoritative presentation/selection.
    widget: u.W,
    /// Owned sunk references, independent of notebook/window lifetime.
    page: u.W,
    tab: u.W,
    /// Borrowed from tab; the controller owns label updates and close callbacks.
    tab_label: u.W,
    close_button: u.W,
    selection: Selection,
    focus_controller: ?*c.GtkEventController = null,
    context_menu_controller: ?*c.GtkEventController = null,

    pub fn create(document: *Document) !*EditorView {
        if (next_id == std.math.maxInt(u64)) return error.IdentityExhausted;
        const self = try u.a.create(EditorView);
        errdefer u.a.destroy(self);
        const mirror = try projection.Projection.create(document);
        errdefer mirror.destroy();
        const widget = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, mirror.buffer)).?;
        const text_view = u.cast(c.GtkTextView, widget);
        c.gtk_text_view_set_monospace(text_view, 1);
        c.gtk_text_view_set_left_margin(text_view, 18);
        c.gtk_text_view_set_right_margin(text_view, 18);
        c.gtk_text_view_set_top_margin(text_view, 22);
        c.gtk_text_view_set_bottom_margin(text_view, 22);
        const page = c.gtk_scrolled_window_new().?;
        _ = c.g_object_ref_sink(page);
        errdefer c.g_object_unref(page);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), widget);
        const layout_guard = try @import("layout_guard.zig").Guard.attach(u.cast(c.GtkScrolledWindow, page), widget, mirror.buffer);
        c.gtk_widget_set_hexpand(page, 1);
        c.gtk_widget_set_vexpand(page, 1);
        const tab = u.box(true, 6);
        c.gtk_widget_add_css_class(tab, "editor-tab");
        _ = c.g_object_ref_sink(tab);
        const tab_label = u.label(@import("i18n").dtr("coral", "Untitled"));
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, tab_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, tab_label), 36);
        sizeTabLabel(tab_label, 0);
        u.append(tab, tab_label);
        const close_button = u.icon("window-close-symbolic", @import("i18n").dtr("coral", "Close document"));
        c.gtk_widget_add_css_class(close_button, "flat");
        u.append(tab, close_button);
        self.* = .{
            .id = next_id,
            .document = document,
            .buffer = mirror.buffer,
            .projection = mirror,
            .layout_guard = layout_guard,
            .widget = widget,
            .page = page,
            .tab = tab,
            .tab_label = tab_label,
            .close_button = close_button,
            .selection = Selection.init(mirror.buffer),
        };
        next_id += 1;
        c.gtk_text_view_set_editable(text_view, @intFromBool(!document.loading and document.pending == null));
        self.enableFocusSelection();
        return self;
    }

    /// Caller removes page/tab from the notebook (or destroys the window) first,
    /// and disconnects its own callbacks that could outlive their context. This
    /// releases widgets and view memory, never the document. Safe after unparenting
    /// because page/tab were ref-sunk, not merely borrowed from the notebook.
    pub fn destroy(self: *EditorView) void {
        self.disconnectDocumentCallbacks();
        std.debug.assert(c.gtk_widget_get_parent(self.page) == null);
        std.debug.assert(c.gtk_widget_get_parent(self.tab) == null);
        self.selection.deinit();
        self.projection.destroy();
        c.g_object_unref(self.tab);
        c.g_object_unref(self.page);
        u.a.destroy(self);
    }

    /// GTK or accessibility consumers may retain widgets after tab removal.
    /// Detach document-bound callbacks before unparenting, not only at finalization.
    pub fn disconnectDocumentCallbacks(self: *EditorView) void {
        self.layout_guard.setHandler(null, null);
        self.projection.detach();
        self.on_focus = null;
        self.focus_context = null;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), 0);
        if (self.focus_controller) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_widget_remove_controller(self.widget, controller);
            self.focus_controller = null;
        }
        _ = c.g_signal_handlers_disconnect_matched(self.close_button, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self.document);
        if (self.context_menu_controller) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self.document);
            c.gtk_widget_remove_controller(self.widget, controller);
            self.context_menu_controller = null;
        }
    }

    /// Compatibility snapshot API, local to this pane. Focus does not restore
    /// snapshots: visible mirror marks are always this pane's authoritative cursor.
    pub fn saveSelection(self: *EditorView) void {
        self.selection.save();
    }

    /// Restore this pane's saved snapshot without affecting any other pane.
    pub fn restoreSelection(self: *EditorView) void {
        self.selection.restore();
    }

    /// Bridge BEFORE canonical selection-dependent commands (search, replace,
    /// spelling). Canonical cursor movement is never broadcast to other panes.
    pub fn syncSelectionToDocument(self: *EditorView) void {
        if (self.projection.attached) projection.copySelection(self.buffer, self.projection.canonical);
    }

    /// Bridge AFTER a canonical command intentionally navigates the active pane.
    pub fn syncSelectionFromDocument(self: *EditorView) void {
        if (!self.projection.attached) return;
        projection.copySelection(self.projection.canonical, self.buffer);
        self.saveSelection();
    }

    /// Parent must apply loading/read-only transitions to EVERY view of a document.
    /// The projection additionally rejects edits while Document.loading/pending.
    pub fn setEditable(self: *EditorView, editable: bool) void {
        self.projection.editable = editable;
        const document = self.projection.document;
        const allowed = if (document) |d| editable and !d.loading and d.pending == null else false;
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, self.widget), @intFromBool(allowed));
    }

    /// Installed by create(), retained for API compatibility and idempotent.
    /// Focus enter bridges the actual visible cursor, not a stale saved snapshot.
    pub fn enableFocusSelection(self: *EditorView) void {
        if (self.focus_controller != null or !self.projection.attached) return;
        const controller = c.gtk_event_controller_focus_new().?;
        u.connect(controller, "enter", &focusEnter, self);
        u.connect(controller, "leave", &focusLeave, self);
        self.focus_controller = controller;
        c.gtk_widget_add_controller(self.widget, controller);
    }

    fn focusEnter(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
        const self = u.cast(EditorView, data.?);
        self.syncSelectionToDocument();
        if (self.on_focus) |callback| callback(self);
    }

    fn focusLeave(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
        u.cast(EditorView, data.?).saveSelection();
    }
};
