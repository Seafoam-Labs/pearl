//! GTK-thread-only editor presentation. The registry owns the document; destroy
//! every view before destroying its document. No application callbacks live here.
//!
//! Saved caret/selection positions are independent, but GTK's visible insertion
//! and selection_bound marks belong to the BUFFER. Inactive panes can therefore
//! show the active pane's selection/caret; this is not independent pane rendering.
//! Each page has its own scroll adjustments. Restoring selection does not request
//! scrolling; callers may explicitly scroll the active view for navigation.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const Document = @import("../document.zig").Document;

// Process-wide, never recycled, and only accessed on the GTK thread.
var next_id: u64 = 1;

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
    /// Borrowed from page; never replace its buffer or reparent its child.
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
        const widget = c.gtk_source_view_new_with_buffer(u.cast(c.GtkSourceBuffer, document.buffer)).?;
        const text_view = u.cast(c.GtkTextView, widget);
        c.gtk_text_view_set_monospace(text_view, 1);
        c.gtk_text_view_set_left_margin(text_view, 18);
        c.gtk_text_view_set_right_margin(text_view, 18);
        c.gtk_text_view_set_top_margin(text_view, 22);
        c.gtk_text_view_set_bottom_margin(text_view, 22);
        const page = c.gtk_scrolled_window_new().?;
        _ = c.g_object_ref_sink(page);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), widget);
        c.gtk_widget_set_hexpand(page, 1);
        c.gtk_widget_set_vexpand(page, 1);
        const tab = u.box(true, 6);
        _ = c.g_object_ref_sink(tab);
        const tab_label = u.label(@import("i18n").dtr("coral", "Untitled"));
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, tab_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, tab_label), 28);
        c.gtk_label_set_width_chars(u.cast(c.GtkLabel, tab_label), 18);
        u.append(tab, tab_label);
        const close_button = u.icon("window-close-symbolic", @import("i18n").dtr("coral", "Close document"));
        c.gtk_widget_add_css_class(close_button, "flat");
        u.append(tab, close_button);
        self.* = .{
            .id = next_id,
            .document = document,
            .widget = widget,
            .page = page,
            .tab = tab,
            .tab_label = tab_label,
            .close_button = close_button,
            .selection = Selection.init(document.buffer),
        };
        next_id += 1;
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
        if (self.focus_controller) |controller| {
            // Removing/unrefing widgets may emit leave: disconnect before marks
            // are deleted so teardown cannot capture into a dead Selection.
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.gtk_widget_remove_controller(self.widget, controller);
        }
        self.selection.deinit();
        c.g_object_unref(self.tab);
        c.g_object_unref(self.page);
        u.a.destroy(self);
    }

    /// GTK or accessibility consumers may retain widgets after tab removal.
    /// Detach document-bound callbacks before unparenting, not only at finalization.
    pub fn disconnectDocumentCallbacks(self: *EditorView) void {
        _ = c.g_signal_handlers_disconnect_matched(self.close_button, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self.document);
        if (self.context_menu_controller) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self.document);
            c.gtk_widget_remove_controller(self.widget, controller);
            self.context_menu_controller = null;
        }
    }

    /// Capture global marks only when they represent THIS view. Also call this
    /// after programmatic navigation (goto/search/menu), BEFORE giving focus back
    /// to the view when focus selection is enabled, or enter would restore stale
    /// positions. This is the explicit adoption API for caller-moved cursors.
    pub fn saveSelection(self: *EditorView) void {
        self.selection.save();
    }

    /// For explicit pane switches: save outgoing, restore incoming. Never restore
    /// an inactive pane just to inspect it: GTK's visible marks are buffer-wide.
    pub fn restoreSelection(self: *EditorView) void {
        self.selection.restore();
    }

    /// Optional split-demo behavior; NOT installed by create(). Single-tab callers
    /// need no automatic restoration, which could undo menu/code navigation.
    /// Enables GtkEventControllerFocus leave/save and enter/restore, idempotently.
    /// Install before first focus, or saveSelection() first if already focused.
    /// Do not combine with a second controller-driven save/restore mechanism.
    /// Navigation while outside the editor must adopt the new cursor with
    /// saveSelection() before focus returns. Marks track edits, not global cursor
    /// moves; there is no reliable automatic distinction between other panes and
    /// application navigation. This controller connects no application callbacks.
    pub fn enableFocusSelection(self: *EditorView) void {
        if (self.focus_controller != null) return;
        const controller = c.gtk_event_controller_focus_new().?;
        u.connect(controller, "enter", &focusEnter, self);
        u.connect(controller, "leave", &focusLeave, self);
        self.focus_controller = controller;
        c.gtk_widget_add_controller(self.widget, controller);
    }

    fn focusEnter(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
        u.cast(EditorView, data.?).restoreSelection();
    }

    fn focusLeave(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
        u.cast(EditorView, data.?).saveSelection();
    }
};
