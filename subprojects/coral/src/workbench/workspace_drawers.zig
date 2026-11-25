//! Transient sidebars for the dedicated Workspace window. The bottom dock stays
//! outside this overlay. Reparenting a frame retains its widgets and buffers.
const u = @import("../c.zig");
const c = u.c;
const i18n = @import("i18n");
const layout = @import("layout.zig");

pub const Drawers = struct {
    overlay: u.W,
    scrim: u.W,
    pinned: [2]u.W,
    floating: [2]u.W,
    buttons: [2]u.W,
    collapsed: [2]bool = .{ false, false },
    open: ?layout.Panel = null,
    origin: c.GWeakRef = undefined,
    context: *anyopaque,
    editor: *const fn (*anyopaque) ?u.W,
    metric_context: ?*c.PangoContext = null,
    metric_serial: c_uint = 0,
    column: c_int = 9,

    pub fn init(header: u.W, paneds: [3]*c.GtkPaned, frames: [3]u.W, ctx: *anyopaque, source: *const fn (*anyopaque) ?u.W) Drawers {
        const overlay = c.gtk_overlay_new().?;
        c.gtk_paned_set_start_child(paneds[2], overlay);
        c.gtk_overlay_set_child(u.cast(c.GtkOverlay, overlay), u.cast(c.GtkWidget, paneds[0]));
        const scrim = u.box(false, 0);
        c.gtk_widget_set_focusable(scrim, 0);
        c.gtk_widget_add_css_class(scrim, "workspace-drawer-backdrop");
        c.gtk_overlay_add_overlay(u.cast(c.GtkOverlay, overlay), scrim);
        c.gtk_widget_set_visible(scrim, 0);
        var pinned: [2]u.W = undefined;
        var floating: [2]u.W = undefined;
        var buttons: [2]u.W = undefined;
        for (0..2) |i| {
            pinned[i] = u.box(false, 0);
            floating[i] = u.box(false, 0);
            const frame = frames[i];
            _ = c.g_object_ref(frame);
            if (i == 0) c.gtk_paned_set_start_child(paneds[i], pinned[i]) else c.gtk_paned_set_end_child(paneds[i], pinned[i]);
            u.append(pinned[i], frame);
            c.g_object_unref(frame);
            c.gtk_widget_set_vexpand(frame, 1);
            c.gtk_widget_set_hexpand(frame, 1);
            c.gtk_widget_add_css_class(floating[i], "workspace-drawer");
            c.gtk_widget_set_halign(floating[i], if (i == 0) c.GTK_ALIGN_START else c.GTK_ALIGN_END);
            c.gtk_overlay_add_overlay(u.cast(c.GtkOverlay, overlay), floating[i]);
            c.gtk_overlay_set_clip_overlay(u.cast(c.GtkOverlay, overlay), floating[i], 1);
            c.gtk_widget_set_visible(floating[i], 0);
            const button = if (i == 0) u.icon("sidebar-show-symbolic", i18n.dtr("coral", "Toggle Explorer drawer")) else u.icon("sidebar-show-right-symbolic", i18n.dtr("coral", "Toggle OpenCode drawer"));
            c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, button), if (i == 0) "win.toggle-explorer" else "win.toggle-agent");
            if (i == 0) c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), button) else c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), button);
            c.gtk_widget_set_visible(button, 0);
            buttons[i] = button;
        }
        return .{ .overlay = overlay, .scrim = scrim, .pinned = pinned, .floating = floating, .buttons = buttons, .context = ctx, .editor = source };
    }
    pub fn columnChanged(self: *Drawers) bool {
        const widget = self.editor(self.context) orelse return false;
        const context = c.gtk_widget_get_pango_context(widget).?;
        const serial = c.pango_context_get_serial(context);
        if (context == self.metric_context and serial == self.metric_serial) return false;
        self.metric_context = context;
        self.metric_serial = serial;
        const metrics = c.pango_context_get_metrics(context, null, null).?;
        defer c.pango_font_metrics_unref(metrics);
        const width = @max(1, @divTrunc(c.pango_font_metrics_get_approximate_digit_width(metrics) + c.PANGO_SCALE / 2, c.PANGO_SCALE));
        if (width == self.column) return false;
        self.column = width;
        return true;
    }
    pub fn resize(self: *Drawers, width: c_int) void {
        const reserve = self.column * 60 + 48;
        const min_right = self.column * 26 + 38;
        const min_left = self.column * 21 + 28;
        self.collapsed = .{ width < reserve + min_right + min_left, width < reserve + min_right };
    }
    pub fn uses(self: *const Drawers, dock: layout.Dock) bool {
        return switch (dock) {
            .left => self.collapsed[0],
            .right => self.collapsed[1],
            .bottom => false,
        };
    }
    pub fn remember(self: *Drawers, root: u.W) void {
        if (self.open != null) return;
        const gtk_root = c.gtk_widget_get_root(root) orelse return;
        c.g_weak_ref_set(&self.origin, @ptrCast(c.gtk_root_get_focus(gtk_root)));
    }
    pub fn returnFocus(self: *Drawers) void {
        const ref = c.g_weak_ref_get(&self.origin) orelse return;
        defer c.g_object_unref(ref);
        c.g_weak_ref_set(&self.origin, null);
        const widget = u.cast(c.GtkWidget, ref);
        if (c.gtk_widget_get_mapped(widget) != 0 and c.gtk_widget_is_sensitive(widget) != 0) _ = c.gtk_widget_grab_focus(widget);
    }
    pub fn present(self: *Drawers, i: usize, frame: u.W, shown: bool, width: c_int, preferred: u16) void {
        const collapsed = self.collapsed[i];
        const parent = if (collapsed) self.floating[i] else self.pinned[i];
        if (c.gtk_widget_get_parent(frame) != parent) {
            _ = c.g_object_ref(frame);
            c.gtk_box_remove(u.cast(c.GtkBox, c.gtk_widget_get_parent(frame).?), frame);
            u.append(parent, frame);
            c.g_object_unref(frame);
        }
        c.gtk_widget_set_visible(self.pinned[i], @intFromBool(shown and !collapsed));
        c.gtk_widget_set_visible(self.floating[i], @intFromBool(shown and collapsed));
        const target = @max(@as(c_int, preferred), self.column * @as(c_int, if (i == 0) 24 else 38));
        c.gtk_widget_set_size_request(self.floating[i], @min(target, @max(1, width - 24)), -1);
    }
};
