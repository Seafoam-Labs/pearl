//! GTK-only presentation. Desired layout survives compact allocations; editor
//! groups never leave their central parent when auxiliary panels move.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const layout = @import("layout.zig");

pub const Dock = layout.Dock;
pub const Panel = layout.Panel;
const docks = [_]Dock{ .left, .right, .bottom };

pub const Controller = struct {
    root: u.W,
    overlay: u.W,
    editor: u.W,
    rail: u.W,
    activities: [2]u.W,
    picker: u.W,
    explorer_slot: u.W,
    search_slot: u.W,
    hosts: [3]u.W,
    frames: [3]u.W,
    search_placeholder: u.W,
    dragging: [3]bool = @splat(false),
    tabs: [3][2]u.W,
    paneds: [3]*c.GtkPaned,
    state: layout.State = .{},
    effective: [2]bool = .{ true, false },
    compact: bool = false,
    picking: bool = false,
    closed: bool = false,
    applying: bool = false,
    tick_id: c_uint = 0,
    controllers: [9]*c.GtkEventController = undefined,
    controller_count: usize = 0,
    pending_focus: c.GWeakRef = undefined,
    pending_focus_frames: u8 = 0,
    width: c_int = -1,
    height: c_int = -1,
    applied: [3]c_int = @splat(-1),
    extents: [3]c_int = @splat(-1),
    pub fn init(editor: u.W) Controller {
        const root = u.box(true, 0);
        c.gtk_widget_set_hexpand(root, 1);
        c.gtk_widget_set_vexpand(root, 1);
        const rail = u.box(false, 5);
        c.gtk_widget_add_css_class(rail, "activity-rail");
        u.append(root, rail);
        const overlay = c.gtk_overlay_new().?;
        c.gtk_widget_set_hexpand(overlay, 1);
        c.gtk_widget_set_vexpand(overlay, 1);
        u.append(root, overlay);
        var hosts: [3]u.W = undefined;
        var frames: [3]u.W = undefined;
        var tabs: [3][2]u.W = undefined;
        var paneds: [3]*c.GtkPaned = undefined;
        for (docks, 0..) |dock, i| {
            const host = u.box(false, 0);
            c.gtk_widget_add_css_class(host, "dock");
            const bar = u.box(true, 0);
            c.gtk_widget_add_css_class(bar, "dock-header");
            u.append(host, bar);
            tabs[i] = .{ actionButton("Explorer", "win.focus-explorer"), actionButton("Search", "win.focus-search") };
            for (tabs[i]) |tab| {
                c.gtk_widget_add_css_class(tab, "dock-tab");
                u.append(bar, tab);
            }
            const spacer = u.box(true, 0);
            c.gtk_widget_set_hexpand(spacer, 1);
            u.append(bar, spacer);
            const menu = c.gtk_menu_button_new().?;
            c.gtk_widget_add_css_class(menu, "dock-menu");
            c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, menu), "view-more-symbolic");
            c.gtk_widget_set_tooltip_text(menu, "Panel options");
            c.gtk_accessible_update_property(u.cast(c.GtkAccessible, menu), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), @as([*:0]const u8, "Panel options"), @as(c_int, -1));
            const model = c.g_menu_new().?;
            defer c.g_object_unref(model);
            inline for (.{ .{ "Move panel left", "win.dock-left" }, .{ "Move panel right", "win.dock-right" }, .{ "Move panel bottom", "win.dock-bottom" }, .{ "Grow dock · Ctrl+Alt+PageUp", "win.dock-grow" }, .{ "Shrink dock · Ctrl+Alt+PageDown", "win.dock-shrink" }, .{ "Reset dock layout", "win.reset-docks" } }) |item| {
                c.g_menu_append(model, item[0], item[1]);
            }
            c.gtk_menu_button_set_menu_model(u.cast(c.GtkMenuButton, menu), u.cast(c.GMenuModel, model));
            u.append(bar, menu);
            const hide_button = u.icon("window-close-symbolic", "Hide panel");
            c.gtk_widget_add_css_class(hide_button, "flat");
            c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, hide_button), "win.hide-panel");
            u.append(bar, hide_button);
            hosts[i] = host;
            const frame = c.gtk_scrolled_window_new().?;
            // Overflow is only a sizing fallback, not an extra keyboard target.
            c.gtk_widget_set_focusable(frame, 0);
            c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, frame), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
            c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, frame), host);
            frames[i] = frame;
            const paned = u.cast(c.GtkPaned, c.gtk_paned_new(if (dock == .bottom) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL).?);
            c.gtk_widget_add_css_class(u.cast(c.GtkWidget, paned), "dock-split");
            c.gtk_paned_set_wide_handle(paned, 1);
            c.gtk_paned_set_shrink_start_child(paned, 1);
            c.gtk_paned_set_shrink_end_child(paned, 1);
            c.gtk_paned_set_resize_start_child(paned, @intFromBool(dock != .left));
            c.gtk_paned_set_resize_end_child(paned, @intFromBool(dock == .left));
            paneds[i] = paned;
        }
        c.gtk_paned_set_start_child(paneds[0], frames[0]);
        c.gtk_paned_set_end_child(paneds[0], u.cast(c.GtkWidget, paneds[1]));
        c.gtk_paned_set_start_child(paneds[1], u.cast(c.GtkWidget, paneds[2]));
        c.gtk_paned_set_end_child(paneds[1], frames[1]);
        c.gtk_paned_set_start_child(paneds[2], editor);
        c.gtk_paned_set_end_child(paneds[2], frames[2]);
        c.gtk_overlay_set_child(u.cast(c.GtkOverlay, overlay), u.cast(c.GtkWidget, paneds[0]));
        const explorer_slot = u.box(false, 0);
        const search_slot = u.box(false, 0);
        for ([_]u.W{ explorer_slot, search_slot }) |slot| c.gtk_widget_set_vexpand(slot, 1);
        u.append(hosts[0], explorer_slot);
        u.append(hosts[2], search_slot);
        const search_placeholder = u.label("Quick Open is using the shared search query and results.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, search_placeholder), 1);
        c.gtk_widget_set_vexpand(search_placeholder, 1);
        u.append(hosts[2], search_placeholder);
        c.gtk_widget_set_visible(search_placeholder, 0);
        const picker = u.box(false, 0);
        c.gtk_widget_add_css_class(picker, "quick-picker");
        c.gtk_widget_set_halign(picker, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(picker, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_top(picker, 12);
        c.gtk_overlay_add_overlay(u.cast(c.GtkOverlay, overlay), picker);
        c.gtk_overlay_set_measure_overlay(u.cast(c.GtkOverlay, overlay), picker, 0);
        c.gtk_overlay_set_clip_overlay(u.cast(c.GtkOverlay, overlay), picker, 1);
        c.gtk_widget_set_visible(picker, 0);
        var activities: [2]u.W = undefined;
        inline for (.{ .{ "system-file-manager-symbolic", "Explorer · Ctrl+Shift+E", "win.toggle-explorer" }, .{ "edit-find-symbolic", "Workspace search · Ctrl+Shift+F", "win.toggle-search" }, .{ "input-keyboard-symbolic", "Focus editor · Ctrl+1", "win.focus-editor" }, .{ "view-refresh-symbolic", "Reset dock layout", "win.reset-docks" } }, 0..) |item, i| {
            if (i == 2) {
                const spacer = u.box(false, 0);
                c.gtk_widget_set_vexpand(spacer, 1);
                u.append(rail, spacer);
            }
            const button = u.icon(item[0], item[1]);
            c.gtk_widget_add_css_class(button, "activity");
            if (i < 2) activities[i] = button;
            c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, button), item[2]);
            u.append(rail, button);
        }
        return .{ .root = root, .overlay = overlay, .editor = editor, .rail = rail, .activities = activities, .picker = picker, .explorer_slot = explorer_slot, .search_slot = search_slot, .hosts = hosts, .frames = frames, .search_placeholder = search_placeholder, .tabs = tabs, .paneds = paneds };
    }

    /// Call only once the controller is at its stable address.
    pub fn attach(self: *Controller) void {
        c.g_weak_ref_init(&self.pending_focus, null);
        for (self.paneds) |paned| {
            u.connect(paned, "notify::position", &positionChanged, self);
            const press = c.gtk_gesture_click_new().?;
            c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, press), 1);
            c.gtk_event_controller_set_propagation_phase(u.cast(c.GtkEventController, press), c.GTK_PHASE_CAPTURE);
            u.connect(press, "pressed", &handlePressed, self);
            self.addController(u.cast(c.GtkWidget, paned), u.cast(c.GtkEventController, press));
        }
        for (self.hosts) |host| {
            const focus = c.gtk_event_controller_focus_new().?;
            u.connect(focus, "enter", &hostFocused, self);
            self.addController(host, focus);
        }
        for ([_]u.W{ self.explorer_slot, self.search_slot }, 0..) |slot, i| {
            const focus = c.gtk_event_controller_focus_new().?;
            u.connect(focus, "enter", if (i == 0) &explorerFocused else &searchFocused, self);
            self.addController(slot, focus);
        }
        // The Paned's own gesture claims the drag, cancelling observers. Watch
        // the actual release instead of treating gesture cancellation as release.
        const release = c.gtk_event_controller_legacy_new().?;
        c.gtk_event_controller_set_propagation_phase(release, c.GTK_PHASE_CAPTURE);
        u.connect(release, "event", &pointerEvent, self);
        self.addController(self.root, release);
        // Frame allocation, not window default-size, is authoritative on Wayland.
        self.tick_id = c.gtk_widget_add_tick_callback(self.root, &allocated, self, null);
        self.apply();
    }

    fn addController(self: *Controller, widget: u.W, controller: *c.GtkEventController) void {
        self.controllers[self.controller_count] = controller;
        self.controller_count += 1;
        c.gtk_widget_add_controller(widget, controller);
    }
    /// Stop before destroying the window. No callback outlives the App context.
    pub fn shutdown(self: *Controller) void {
        if (self.closed) return;
        self.closed = true;
        c.g_weak_ref_clear(&self.pending_focus);
        if (self.tick_id != 0) c.gtk_widget_remove_tick_callback(self.root, self.tick_id);
        self.tick_id = 0;
        for (self.controllers[0..self.controller_count]) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            if (c.gtk_event_controller_get_widget(controller)) |widget| c.gtk_widget_remove_controller(widget, controller);
        }
        self.controller_count = 0;
        for (self.paneds) |paned| _ = c.g_signal_handlers_disconnect_matched(paned, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
    }
    pub fn snapshot(self: *Controller) layout.State {
        return self.state;
    }
    pub fn restore(self: *Controller, state: layout.State) void {
        if (self.closed) return;
        self.state = layout.normalized(state);
        self.apply();
    }
    pub fn visible(self: *Controller, panel: Panel) bool {
        return if (panel == .explorer) self.state.explorer_visible else self.state.search_visible;
    }
    pub fn show(self: *Controller, panel: Panel) void {
        if (self.closed) return;
        if (panel == .explorer) self.state.explorer_visible = true else self.state.search_visible = true;
        self.state.active = panel;
        self.apply();
    }
    pub fn hide(self: *Controller, panel: Panel) void {
        if (self.closed) return;
        if (panel == .explorer) self.state.explorer_visible = false else self.state.search_visible = false;
        if (self.state.active == panel) self.state.active = if (panel == .explorer) .search else .explorer;
        self.apply();
    }
    pub fn move(self: *Controller, dock: Dock) void {
        if (self.closed) return;
        if (self.state.active == .explorer) self.state.explorer = dock else self.state.search = dock;
        self.apply();
    }
    pub fn grow(self: *Controller, larger: bool) void {
        const side = self.presentationDock(if (self.state.active == .explorer) self.state.explorer else self.state.search);
        const size = switch (side) {
            .left => self.state.left_size,
            .right => self.state.right_size,
            .bottom => self.state.bottom_size,
        };
        self.resize(side, if (larger) size +| 40 else size -| 40);
    }
    pub fn resize(self: *Controller, dock: Dock, size: u16) void {
        if (self.closed) return;
        switch (dock) {
            .left => self.state.left_size = size,
            .right => self.state.right_size = size,
            .bottom => self.state.bottom_size = size,
        }
        self.state = layout.normalized(self.state);
        self.apply();
    }
    pub fn presentPicker(self: *Controller) void {
        if (self.closed) return;
        self.picking = true;
        self.apply();
    }
    /// Presentation only: must not invalidate an in-flight search navigation.
    pub fn dismissPicker(self: *Controller) void {
        if (self.closed) return;
        self.picking = false;
        self.apply();
    }
    // A side strip narrower than its controls is not usable. Reflow only the
    // presentation on small windows; desired placement survives widening.
    fn presentationDock(self: *const Controller, dock: Dock) Dock {
        return if (self.width > 0 and self.width < 520) .bottom else dock;
    }
    fn apply(self: *Controller) void {
        if (self.closed) return;
        self.applying = true;
        defer self.applying = false;
        const explorer_dock = self.presentationDock(self.state.explorer);
        const search_dock = self.presentationDock(self.state.search);
        const root = c.gtk_widget_get_root(self.root);
        const focused = if (root) |r| c.gtk_root_get_focus(r) else null;

        if (focused) |widget| {
            _ = c.g_object_ref(widget);
            const search_parent = if (self.picking) self.picker else self.hosts[index(search_dock)];
            const moving_focus = (inside(widget, self.search_slot) and c.gtk_widget_get_parent(self.search_slot) != search_parent) or
                (inside(widget, self.explorer_slot) and c.gtk_widget_get_parent(self.explorer_slot) != self.hosts[index(explorer_dock)]);
            if (moving_focus) {
                c.g_weak_ref_set(&self.pending_focus, @ptrCast(widget));
                self.pending_focus_frames = 4;
            }
        }
        defer if (focused) |widget| {
            // Reparenting a panel can clear GTK focus. Preserve it only if the
            // same widget remains visible; allocation must never reopen UI.
            if (c.gtk_widget_get_root(widget) == root and c.gtk_widget_is_visible(widget) != 0 and root != null and c.gtk_root_get_focus(root.?) != widget) {
                if (c.gtk_widget_grab_focus(widget) == 0) {
                    c.g_weak_ref_set(&self.pending_focus, @ptrCast(widget));
                    self.pending_focus_frames = 4;
                }
            }
            c.g_object_unref(widget);
        };
        var shown = [2]bool{ self.state.explorer_visible, self.state.search_visible };
        if (shown[0] and shown[1] and (self.compact or self.state.explorer == self.state.search)) {
            shown[if (self.state.active == .explorer) @as(usize, 1) else 0] = false;
        }
        self.effective = shown;
        reparent(self.explorer_slot, self.hosts[index(explorer_dock)]);
        reparent(self.search_slot, if (self.picking) self.picker else self.hosts[index(search_dock)]);
        reparent(self.search_placeholder, self.hosts[index(search_dock)]);
        c.gtk_widget_set_visible(self.search_placeholder, @intFromBool(self.picking and shown[1]));
        c.gtk_widget_set_visible(self.explorer_slot, @intFromBool(shown[0]));
        c.gtk_widget_set_visible(self.search_slot, @intFromBool(shown[1] or self.picking));
        c.gtk_widget_set_visible(self.picker, @intFromBool(self.picking));
        for (docks, 0..) |dock, i| {
            const explorer_here = explorer_dock == dock;
            const search_here = search_dock == dock;
            c.gtk_widget_set_visible(self.frames[i], @intFromBool((shown[0] and explorer_here) or (shown[1] and search_here)));
            c.gtk_widget_set_visible(self.tabs[i][0], @intFromBool(explorer_here and self.state.explorer_visible));
            c.gtk_widget_set_visible(self.tabs[i][1], @intFromBool(search_here and self.state.search_visible));
            for (self.tabs[i], 0..) |tab, panel| setActive(tab, shown[panel]);
        }
        for (self.activities, 0..) |activity, panel| setActive(activity, shown[panel]);
        self.setPositions();
    }
    fn setPositions(self: *Controller) void {
        const was_applying = self.applying;
        self.applying = true;
        defer self.applying = was_applying;
        const sizes = [3]u16{ self.state.left_size, self.state.right_size, self.state.bottom_size };
        for (self.paneds, 0..) |paned, i| {
            const widget = u.cast(c.GtkWidget, paned);
            const extent = if (i == 2) c.gtk_widget_get_height(widget) else c.gtk_widget_get_width(widget);
            self.extents[i] = extent;
            if (extent <= 1 or c.gtk_widget_get_visible(self.frames[i]) == 0) continue;
            // Reserve a useful central editor, even for oversized saved values.
            const reserve: c_int = if (i == 2) 165 else 245;
            const shared = i != 2 and c.gtk_widget_get_visible(self.frames[0]) != 0 and c.gtk_widget_get_visible(self.frames[1]) != 0;
            const size = @min(@as(c_int, sizes[i]), @max(0, @divTrunc(extent - reserve, if (shared) @as(c_int, 2) else 1)));
            const position = if (i == 0) size else @max(0, extent - size);
            self.applied[i] = position;
            c.gtk_paned_set_position(paned, position);
        }
        c.gtk_widget_set_size_request(self.picker, @max(1, @min(640, self.width - 24)), @max(1, @min(420, self.height - 24)));
    }
    fn restorePendingFocus(self: *Controller) void {
        const object = c.g_weak_ref_get(&self.pending_focus) orelse return;
        defer c.g_object_unref(object);
        const widget = u.cast(c.GtkWidget, object);
        const root = c.gtk_widget_get_root(self.root) orelse return;
        const focused = c.gtk_root_get_focus(root);

        var wrapper_focus = false;
        for (self.frames) |frame| if (focused == frame and inside(widget, frame)) {
            wrapper_focus = true;
        };
        for (self.paneds) |paned| if (focused == u.cast(c.GtkWidget, paned) and inside(widget, focused.?)) {
            wrapper_focus = true;
        };
        // Nested paneds can temporarily unmap a reparented panel on the next
        // allocation, moving focus to its paned (or scrolled-window wrapper).
        // Allow the subsequent remap before repairing focus, bounded to four
        // frames. Only ancestor fallbacks qualify, not another control/editor;
        // hidden panels must never be reopened.
        if (c.gtk_widget_get_root(widget) != root or c.gtk_widget_is_visible(widget) == 0 or
            (focused != null and focused != widget and !wrapper_focus))
        {
            c.g_weak_ref_set(&self.pending_focus, null);
            return;
        }
        if (c.gtk_widget_get_mapped(widget) != 0) _ = c.gtk_widget_grab_focus(widget);

        self.pending_focus_frames -|= 1;
        if (self.pending_focus_frames == 0) c.g_weak_ref_set(&self.pending_focus, null);
    }
    pub fn probe(self: *Controller, window: u.W) void {
        const focus = c.gtk_window_get_focus(u.cast(c.GtkWindow, window));

        const Bounds = struct { x: f32, y: f32, width: f32, height: f32 };
        var bounds: [3]Bounds = undefined;
        for (self.paneds, &bounds) |paned, *rect| {
            var native: c.graphene_rect_t = std.mem.zeroes(c.graphene_rect_t);
            _ = c.gtk_widget_compute_bounds(u.cast(c.GtkWidget, paned), window, &native);
            rect.* = .{ .x = native.origin.x, .y = native.origin.y, .width = native.size.width, .height = native.size.height };
        }
        var editor_bounds: c.graphene_rect_t = std.mem.zeroes(c.graphene_rect_t);
        _ = c.gtk_widget_compute_bounds(self.editor, window, &editor_bounds);
        var group_bounds: std.ArrayList(Bounds) = .empty;
        defer group_bounds.deinit(u.a);
        var group = c.gtk_widget_get_first_child(self.editor);
        while (group) |widget| : (group = c.gtk_widget_get_next_sibling(widget)) {
            var native: c.graphene_rect_t = std.mem.zeroes(c.graphene_rect_t);
            _ = c.gtk_widget_compute_bounds(widget, window, &native);
            group_bounds.append(u.a, .{ .x = native.origin.x, .y = native.origin.y, .width = native.size.width, .height = native.size.height }) catch unreachable;
        }
        const text = std.json.Stringify.valueAlloc(u.a, .{
            .desired = self.snapshot(),
            .compact = self.compact,
            .explorer_visible = self.effective[0],
            .search_visible = self.effective[1],
            .picker_visible = self.picking,
            .shared_search = true,
            .left_visible = c.gtk_widget_get_visible(self.frames[0]) != 0,
            .right_visible = c.gtk_widget_get_visible(self.frames[1]) != 0,
            .bottom_visible = c.gtk_widget_get_visible(self.frames[2]) != 0,
            .paned_bounds = bounds,
            .positions = [3]c_int{ c.gtk_paned_get_position(self.paneds[0]), c.gtk_paned_get_position(self.paneds[1]), c.gtk_paned_get_position(self.paneds[2]) },
            .width = c.gtk_widget_get_width(window),
            .height = c.gtk_widget_get_height(window),
            .editor_bounds = Bounds{ .x = editor_bounds.origin.x, .y = editor_bounds.origin.y, .width = editor_bounds.size.width, .height = editor_bounds.size.height },
            .editor_group_bounds = group_bounds.items,
            .editor_width = c.gtk_widget_get_width(self.editor),
            .editor_height = c.gtk_widget_get_height(self.editor),
            .focus = if (inside(focus, self.picker)) "picker" else if (inside(focus, self.explorer_slot)) "explorer" else if (inside(focus, self.search_slot)) "search" else if (inside(focus, self.editor)) "editor" else "other",
        }, .{}) catch unreachable;
        defer u.a.free(text);
        const z = u.z(text);
        defer u.a.free(z);
        c.g_print("CORAL_DOCK %s\n", z.ptr);
    }
};
/// Keep each split independently allocated even when a notebook page or tab
/// has a larger minimum width. One viewport around the whole editor would let
/// the first/active group push its siblings offscreen instead.
pub fn wrapEditorGroup(root: u.W, notebook: u.W) void {
    const frame = c.gtk_scrolled_window_new().?;
    c.gtk_widget_set_hexpand(frame, 1);
    c.gtk_widget_set_vexpand(frame, 1);
    c.gtk_widget_set_focusable(frame, 0);
    c.gtk_scrolled_window_set_policy(u.cast(c.GtkScrolledWindow, frame), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_width(u.cast(c.GtkScrolledWindow, frame), 0);
    c.gtk_scrolled_window_set_propagate_natural_height(u.cast(c.GtkScrolledWindow, frame), 0);
    _ = c.g_object_ref(notebook);
    defer c.g_object_unref(notebook);
    c.gtk_box_remove(u.cast(c.GtkBox, root), notebook);
    c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, frame), notebook);
    u.append(root, frame);
}

/// Restore the model's direct-parent contract immediately before removing an
/// empty group. No live page is unparented or replaced when docks move/resize.
pub fn unwrapEditorGroup(root: u.W, notebook: u.W) void {
    var frame = c.gtk_widget_get_parent(notebook) orelse return;
    if (frame == root) return;
    while (c.gtk_widget_get_parent(frame)) |parent| {
        if (parent == root) break;
        frame = parent;
    }
    std.debug.assert(c.gtk_widget_get_parent(frame) == root);
    _ = c.g_object_ref(notebook);
    defer c.g_object_unref(notebook);
    // GtkScrolledWindow inserts a GtkViewport for the non-scrollable notebook.
    const viewport = c.gtk_widget_get_parent(notebook).?;
    c.gtk_viewport_set_child(u.cast(c.GtkViewport, viewport), null);
    c.gtk_box_remove(u.cast(c.GtkBox, root), frame);
    u.append(root, notebook);
}

fn setActive(widget: u.W, active: bool) void {
    if (active) c.gtk_widget_add_css_class(widget, "active") else c.gtk_widget_remove_css_class(widget, "active");
}
fn actionButton(text: [*:0]const u8, action: [*:0]const u8) u.W {
    const button = u.button(text);
    c.gtk_widget_set_tooltip_text(button, text);
    c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, button), action);
    return button;
}
fn index(dock: Dock) usize {
    return switch (dock) {
        .left => 0,
        .right => 1,
        .bottom => 2,
    };
}
fn reparent(widget: u.W, parent: u.W) void {
    const old = c.gtk_widget_get_parent(widget);
    if (old == parent) return;
    _ = c.g_object_ref(widget);
    defer c.g_object_unref(widget);
    if (old) |box| c.gtk_box_remove(u.cast(c.GtkBox, box), widget);
    u.append(parent, widget);
}
pub fn inside(widget: ?u.W, parent: u.W) bool {
    return if (widget) |w| w == parent or c.gtk_widget_is_ancestor(w, parent) != 0 else false;
}
fn allocated(_: ?*c.GtkWidget, _: ?*c.GdkFrameClock, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    if (self.closed) return 0;
    const width = c.gtk_widget_get_width(self.overlay);
    const height = c.gtk_widget_get_height(self.overlay);
    if (width != self.width or height != self.height) {
        self.width = width;
        self.height = height;
        self.compact = width < 900 or height < 420;
        self.apply();
    } else {
        for (self.paneds, 0..) |paned, i| {
            const w = u.cast(c.GtkWidget, paned);
            const extent = if (i == 2) c.gtk_widget_get_height(w) else c.gtk_widget_get_width(w);
            if (extent != self.extents[i]) {
                self.setPositions();
                break;
            }
        }
    }
    self.restorePendingFocus();
    return 1;
}
fn positionChanged(paned: ?*c.GtkPaned, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.closed or self.applying) return;
    for (self.paneds, 0..) |p, i| if (p == paned) {
        const widget = u.cast(c.GtkWidget, p);
        const extent = if (i == 2) c.gtk_widget_get_height(widget) else c.gtk_widget_get_width(widget);
        const position = c.gtk_paned_get_position(p);
        // Ignore allocation-driven adjustments, including hidden/compact docks.
        if ((!self.dragging[i] and c.gtk_widget_has_focus(widget) == 0) or extent != self.extents[i] or position == self.applied[i] or c.gtk_widget_get_visible(self.frames[i]) == 0) return;
        const size = if (i == 0) position else extent - position;
        self.resize(docks[i], @intCast(std.math.clamp(size, 0, 1200)));
        return;
    };
}
fn handlePressed(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.closed) return;
    const widget = c.gtk_event_controller_get_widget(u.cast(c.GtkEventController, gesture.?));
    for (self.paneds, 0..) |paned, i| if (u.cast(c.GtkWidget, paned) == widget) {
        const position: f64 = @floatFromInt(c.gtk_paned_get_position(paned));
        self.dragging[i] = @abs((if (i == 2) y else x) - position) < 16;
        // A deliberate splitter interaction supersedes reparent focus repair.
        if (self.dragging[i]) c.g_weak_ref_set(&self.pending_focus, null);
    };
}
fn pointerEvent(_: ?*c.GtkEventControllerLegacy, event: ?*c.GdkEvent, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(Controller, data.?);
    if (self.closed) return 0;
    switch (c.gdk_event_get_event_type(event.?)) {
        c.GDK_BUTTON_RELEASE, c.GDK_TOUCH_END, c.GDK_TOUCH_CANCEL, c.GDK_GRAB_BROKEN => self.dragging = @splat(false),
        else => {},
    }
    return 0;
}
fn hostFocused(controller: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (self.closed or self.applying) return;
    const widget = c.gtk_event_controller_get_widget(u.cast(c.GtkEventController, controller.?));
    for (self.hosts, 0..) |host, i| if (host == widget) {
        self.state.active = if (self.effective[0] and index(self.presentationDock(self.state.explorer)) == i) .explorer else .search;
    };
}
fn explorerFocused(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (!self.closed and !self.applying) self.state.active = .explorer;
}
fn searchFocused(_: ?*c.GtkEventControllerFocus, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(Controller, data.?);
    if (!self.closed and !self.applying and !self.picking) self.state.active = .search;
}
