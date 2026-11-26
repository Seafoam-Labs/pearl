//! Project switcher for open GTK workspace windows. A button stores the stable
//! window id so closing a project cannot leave a borrowed App pointer behind.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const App = @import("app.zig").App;
const Manager = @import("application.zig").Manager;
const i18n = @import("i18n");

pub fn create(parent: u.W) u.W {
    const header = u.box(true, 4);
    const title = u.label(i18n.dtr("coral", "Projects"));
    c.gtk_widget_add_css_class(title, "workspace-section");
    c.gtk_widget_set_hexpand(title, 1);
    u.append(header, title);
    const recent = u.icon("document-open-recent-symbolic", i18n.dtr("coral", "Recent projects"));
    c.gtk_widget_add_css_class(recent, "flat");
    c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, recent), "win.recent-projects");
    u.append(header, recent);
    u.append(parent, header);
    const rows = u.box(false, 2);
    const scroll = c.gtk_scrolled_window_new().?;
    const scrolled = u.cast(c.GtkScrolledWindow, scroll);
    c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(scrolled, 1);
    c.gtk_scrolled_window_set_max_content_height(scrolled, 148);
    c.gtk_scrolled_window_set_child(scrolled, rows);
    u.append(parent, scroll);
    return rows;
}

pub fn refresh(manager: *Manager) void {
    for (manager.entries) |entry| if (entry) |owner| {
        const rows = owner.app.project_rows orelse continue;
        if (owner.app.closing) continue;
        while (c.gtk_widget_get_first_child(rows)) |old| c.gtk_box_remove(u.cast(c.GtkBox, rows), old);
        for (manager.entries) |item| if (item) |project| {
            if (project.app.closing) continue;
            const model = project.app.browser.model orelse continue;
            const path = model.manifest_path orelse if (model.roots.len > 0) model.roots[0].lexical_path else continue;
            const name = if (model.manifest_path != null) std.fs.path.basename(path) else model.roots[0].display_name;
            const button = c.gtk_button_new().?;
            c.gtk_widget_add_css_class(button, "flat");
            c.gtk_widget_add_css_class(button, "workspace-project");
            if (owner == project) c.gtk_widget_add_css_class(button, "workspace-current-project");
            const content = u.box(true, 8);
            const icon = c.gtk_image_new_from_icon_name("folder-symbolic").?;
            c.gtk_widget_add_css_class(icon, "workspace-project-icon");
            u.append(content, icon);
            const labels = u.box(false, 1);
            const title = u.label(name);
            const detail = u.label(path);
            c.gtk_widget_add_css_class(title, "workspace-project-name");
            c.gtk_widget_add_css_class(detail, "caption");
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, detail), c.PANGO_ELLIPSIZE_START);
            u.append(labels, title);
            u.append(labels, detail);
            u.append(content, labels);
            c.gtk_button_set_child(u.cast(c.GtkButton, button), content);
            const full = u.z(path);
            defer u.a.free(full);
            c.gtk_widget_set_tooltip_text(button, full);
            var buf: [4096]u8 = undefined;
            const accessible = i18n.dfmt("coral", &buf, "Show project {s}", .{name});
            c.gtk_accessible_update_property(u.cast(c.GtkAccessible, button), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), accessible.ptr, @as(c_int, -1));
            const id = u.a.create(u64) catch unreachable;
            id.* = project.app.window_id;
            c.g_object_set_data_full(u.cast(c.GObject, button), "project-window", id, &destroyId);
            u.connect(button, "clicked", &presentProject, manager);
            u.append(rows, button);
        };
        if (c.gtk_widget_get_first_child(rows) == null) {
            const open = u.button(i18n.dtr("coral", "Open Folder…"));
            c.gtk_widget_add_css_class(open, "flat");
            c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, open), "win.open-folder");
            u.append(rows, open);
        }
    };
}

fn destroyId(data: ?*anyopaque) callconv(.c) void {
    u.a.destroy(u.cast(u64, data.?));
}

fn presentProject(button: ?*c.GtkButton, context: ?*anyopaque) callconv(.c) void {
    const id = u.cast(u64, c.g_object_get_data(u.cast(c.GObject, button.?), "project-window").?).*;
    if (u.cast(Manager, context.?).find(id)) |app| {
        if (!app.closing) c.gtk_window_present(u.cast(c.GtkWindow, app.window));
    }
}
