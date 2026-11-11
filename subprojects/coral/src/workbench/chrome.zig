//! Presentation-only shell. Actions stay on the owning window's guarded dispatcher;
//! geometry classes also apply in native GTK mode, never opting it into Coral colors.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const i18n = @import("i18n");
const commands = @import("commands.zig");

pub const Chrome = struct {
    workspace_button: u.W,
    workspace_label: u.W,
    command_text: u.W,
    command_shortcut: u.W,
    workspace_status: u.W,
    trust_button: u.W,
    trust_label: u.W,
    language_button: u.W,
    language_label: u.W,
    open_button: ?u.W = null,
    save_button: ?u.W = null,

    pub fn init(header: u.W, footer: u.W) Chrome {
        c.gtk_widget_add_css_class(header, "workbench-titlebar");
        c.gtk_widget_set_size_request(header, -1, 43);
        c.gtk_widget_set_size_request(footer, -1, 26);
        const brand = u.label("C.");
        c.gtk_widget_add_css_class(brand, "brand");
        c.gtk_widget_set_tooltip_text(brand, i18n.dtr("coral", "Coral"));
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), brand);

        const workspace_button = c.gtk_menu_button_new().?;
        c.gtk_widget_add_css_class(workspace_button, "workspace-button");
        c.gtk_widget_add_css_class(workspace_button, "flat");
        c.gtk_widget_set_tooltip_text(workspace_button, i18n.dtr("coral", "Workspace and recent projects"));
        const workspace_content = u.box(true, 6);
        const workspace_label = compactLabel(i18n.dtr("coral", "No workspace"), 16);
        u.append(workspace_content, workspace_label);
        u.append(workspace_content, c.gtk_image_new_from_icon_name("pan-down-symbolic").?);
        c.gtk_menu_button_set_child(u.cast(c.GtkMenuButton, workspace_button), workspace_content);
        const workspace_menu = c.g_menu_new().?;
        defer c.g_object_unref(workspace_menu);
        for ([_]commands.Command{ .recent_projects, .open_folder, .open_workspace, .workspace_roots, .add_workspace_root, .save_workspace_as, .close_workspace }) |command| {
            c.g_menu_append(workspace_menu, command.label(), command.metadata().detailed_action);
        }
        c.gtk_menu_button_set_menu_model(u.cast(c.GtkMenuButton, workspace_button), u.cast(c.GMenuModel, workspace_menu));
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), workspace_button);

        const command_button = u.icon("edit-find-symbolic", i18n.dtr("coral", "Command Palette · Ctrl+Shift+P"));
        c.gtk_widget_add_css_class(command_button, "command-button");
        c.gtk_widget_set_hexpand(command_button, 0);
        c.gtk_widget_set_halign(command_button, c.GTK_ALIGN_CENTER);
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, command_button), commands.Command.command_palette.metadata().detailed_action);
        const command_content = u.box(true, 10);
        u.append(command_content, c.gtk_image_new_from_icon_name("edit-find-symbolic").?);
        const command_text = compactLabel(i18n.dtr("coral", "Search commands…"), 28);
        u.append(command_content, command_text);
        const command_shortcut = u.label("Ctrl+Shift+P");
        c.gtk_widget_add_css_class(command_shortcut, "dim-label");
        u.append(command_content, command_shortcut);
        c.gtk_button_set_child(u.cast(c.GtkButton, command_button), command_content);
        c.gtk_header_bar_set_title_widget(u.cast(c.GtkHeaderBar, header), command_button);

        const workspace_status = compactLabel("", 24);
        c.gtk_widget_add_css_class(workspace_status, "status-workspace");
        c.gtk_widget_set_hexpand(workspace_status, 1);
        u.append(footer, workspace_status);
        const trust_button = c.gtk_button_new().?;
        c.gtk_widget_add_css_class(trust_button, "flat");
        c.gtk_widget_add_css_class(trust_button, "status-trust");
        const trust_label = compactLabel("", 24);
        c.gtk_button_set_child(u.cast(c.GtkButton, trust_button), trust_label);
        c.gtk_widget_set_tooltip_text(trust_button, i18n.dtr("coral", "Workspace trust; automatic language servers require exact configuration approval"));
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, trust_button), commands.Command.workspace_policy.metadata().detailed_action);
        u.append(footer, trust_button);
        const language_button = c.gtk_button_new().?;
        c.gtk_widget_add_css_class(language_button, "flat");
        const language_label = compactLabel("Language: automatic", 20);
        c.gtk_button_set_child(u.cast(c.GtkButton, language_button), language_label);
        c.gtk_actionable_set_action_name(u.cast(c.GtkActionable, language_button), commands.Command.language_status.metadata().detailed_action);
        u.append(footer, language_button);
        return .{
            .workspace_button = workspace_button,
            .workspace_label = workspace_label,
            .command_text = command_text,
            .command_shortcut = command_shortcut,
            .workspace_status = workspace_status,
            .trust_button = trust_button,
            .trust_label = trust_label,
            .language_button = language_button,
            .language_label = language_label,
        };
    }

    pub fn update(self: *Chrome, app: *@import("../app.zig").App, width: c_int) void {
        const wide = width >= 760;
        c.gtk_widget_set_visible(self.command_text, @intFromBool(width >= 900));
        c.gtk_widget_set_visible(self.command_shortcut, @intFromBool(width >= 1100));
        if (self.open_button) |button| c.gtk_widget_set_visible(button, @intFromBool(wide));
        if (self.save_button) |button| c.gtk_widget_set_visible(button, @intFromBool(width >= 500));
        c.gtk_widget_set_visible(app.spell_button, @intFromBool(width >= 1100));
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, self.workspace_label), if (wide) 16 else 8);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, self.workspace_status), if (wide) 24 else 8);
        var name: []const u8 = i18n.dtr("coral", "No workspace");
        var path: []const u8 = name;
        if (app.browser.model) |model| {
            if (model.manifest_path) |manifest| {
                name = std.fs.path.basename(manifest);
                path = manifest;
            } else if (model.roots.len > 0) {
                name = model.roots[0].display_name;
                path = model.roots[0].lexical_path;
            }
        }
        u.setLabel(self.workspace_label, name);
        u.setLabel(self.workspace_status, name);
        const full_path = u.z(path);
        defer u.a.free(full_path);
        c.gtk_widget_set_tooltip_text(self.workspace_button, full_path);
        c.gtk_widget_set_tooltip_text(self.workspace_status, full_path);
        const trust_text = switch (app.workspace_policy.status) {
            .verifying => i18n.dtr("coral", "Verifying…"),
            .failed => i18n.dtr("coral", "Trust check failed"),
            .restricted => i18n.dtr("coral", "Restricted"),
            .trusted => if (app.workspace_policy.policy.state == .trusted) i18n.dtr("coral", "Trusted") else i18n.dtr("coral", "Restricted"),
        };
        u.setLabel(self.trust_label, trust_text);
        c.gtk_widget_set_visible(self.trust_button, @intFromBool(app.browser.model != null));
        u.setLabel(self.language_label, app.language.summary());
        const language_tip = u.fmt("{s}\n{s}", .{ app.language.status, app.language.progress });
        defer u.a.free(language_tip);
        c.gtk_widget_set_tooltip_text(self.language_button, language_tip);
        c.gtk_widget_set_visible(self.language_button, @intFromBool(width >= 760));
    }
};

fn compactLabel(text: []const u8, max_chars: c_int) u.W {
    const label = u.label(text);
    c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), max_chars);
    return label;
}

/// A group-level row in space reserved above each notebook page. The page itself
/// stays the original scrolled window (or excerpt root), with its child unchanged.
/// GtkOverlay allocates its main child first, so the row follows the actual page
/// boundary below tabs even with native themes or enlarged interface fonts.
pub const GroupChrome = struct {
    pub const breadcrumb_height = 33;
    root: u.W,
    notebook: u.W,
    breadcrumbs: u.W,
    label: u.W,

    pub fn init(notebook: u.W) GroupChrome {
        const root = c.gtk_overlay_new().?;
        c.gtk_widget_set_hexpand(root, 1);
        c.gtk_widget_set_vexpand(root, 1);
        c.gtk_overlay_set_child(u.cast(c.GtkOverlay, root), notebook);
        const row = u.box(true, 0);
        c.gtk_widget_add_css_class(row, "breadcrumbs");
        const label = compactLabel("", 1);
        c.gtk_label_set_single_line_mode(u.cast(c.GtkLabel, label), 1);
        c.gtk_widget_set_hexpand(label, 1);
        u.append(row, label);
        c.gtk_overlay_add_overlay(u.cast(c.GtkOverlay, root), row);
        c.gtk_overlay_set_measure_overlay(u.cast(c.GtkOverlay, root), row, 0);
        c.gtk_overlay_set_clip_overlay(u.cast(c.GtkOverlay, root), row, 1);
        c.gtk_widget_set_visible(row, 0);
        u.connect(root, "get-child-position", &positionBreadcrumb, notebook);
        u.connect(notebook, "page-added", &reserveBreadcrumb, null);
        u.connect(notebook, "page-removed", &releaseBreadcrumb, null);
        return .{ .root = root, .notebook = notebook, .breadcrumbs = row, .label = label };
    }

    pub fn selected(self: GroupChrome) ?u.W {
        const notebook = u.cast(c.GtkNotebook, self.notebook);
        const index = c.gtk_notebook_get_current_page(notebook);
        return if (index < 0) null else c.gtk_notebook_get_nth_page(notebook, index);
    }

    /// Called for each presentation; only this group's selected page may update
    /// its row. Root ownership is pure snapshot routing, never filesystem I/O.
    pub fn showDocument(self: GroupChrome, page: u.W, path: ?[]const u8, snapshot: ?*const @import("../workspace/model.zig").Model, excerpt: bool) void {
        if (self.selected() != page) return;
        const full_path = path orelse i18n.dtr("coral", "Untitled");
        var qualified: ?[:0]u8 = null;
        defer if (qualified) |text| u.a.free(text);
        if (path) |p| if (snapshot) |model| {
            if (model.ownerOfCanonicalPath(p) catch null) |id| {
                const folder = model.rootById(id).?;
                const base = folder.canonical_path.?;
                const relative = p[@min(p.len, base.len + @as(usize, if (base.len == 1) 0 else 1))..];
                qualified = u.fmt("#{d} {s} › {s}", .{ @backingInt(id), folder.display_name, relative });
            }
        };
        const name: []const u8 = qualified orelse full_path;
        var text_buffer: [8192]u8 = undefined;
        const text = if (excerpt) i18n.dfmt("coral", &text_buffer, "Excerpt · {s}", .{name}) else name;
        u.setLabel(self.label, text);
        const tooltip = if (qualified) |root_path| u.fmt("{s}\n{s}", .{ root_path, full_path }) else u.z(full_path);
        defer u.a.free(tooltip);
        c.gtk_widget_set_tooltip_text(self.breadcrumbs, tooltip);
        c.gtk_widget_set_visible(self.breadcrumbs, 1);
    }

    pub fn clearIfEmpty(self: GroupChrome) void {
        if (self.selected() != null) return;
        u.setLabel(self.label, "");
        c.gtk_widget_set_tooltip_text(self.breadcrumbs, null);
        c.gtk_widget_set_visible(self.breadcrumbs, 0);
    }

    fn reserveBreadcrumb(_: ?*c.GtkNotebook, page: ?*c.GtkWidget, _: c_uint, _: ?*anyopaque) callconv(.c) void {
        c.gtk_widget_set_margin_top(page, breadcrumb_height);
    }
    fn releaseBreadcrumb(_: ?*c.GtkNotebook, page: ?*c.GtkWidget, _: c_uint, _: ?*anyopaque) callconv(.c) void {
        c.gtk_widget_set_margin_top(page, 0);
    }
    fn positionBreadcrumb(overlay: ?*c.GtkOverlay, _: ?*c.GtkWidget, allocation: *c.GtkAllocation, data: ?*anyopaque) callconv(.c) c_int {
        const notebook = u.cast(c.GtkNotebook, data.?);
        const index = c.gtk_notebook_get_current_page(notebook);
        if (index < 0) return 0;
        const page = c.gtk_notebook_get_nth_page(notebook, index) orelse return 0;
        var bounds: c.graphene_rect_t = std.mem.zeroes(c.graphene_rect_t);
        if (c.gtk_widget_compute_bounds(page, u.cast(c.GtkWidget, overlay.?), &bounds) == 0) return 0;
        allocation.* = .{
            .x = @intFromFloat(bounds.origin.x),
            .y = @max(0, @as(c_int, @intFromFloat(bounds.origin.y)) - breadcrumb_height),
            .width = @max(0, @as(c_int, @intFromFloat(bounds.size.width))),
            .height = breadcrumb_height,
        };
        return 1;
    }
};

const Category = enum {
    file,
    edit,
    workspace,
    language,
    git,
    view,
    window,

    fn label(self: Category) [:0]const u8 {
        return switch (self) {
            .file => i18n.dtr("coral", "File"),
            .edit => i18n.dtr("coral", "Edit"),
            .workspace => i18n.dtr("coral", "Workspace"),
            .language => i18n.dtr("coral", "Language"),
            .git => i18n.dtr("coral", "Git"),
            .view => i18n.dtr("coral", "View"),
            .window => i18n.dtr("coral", "Window"),
        };
    }
};

fn category(command: commands.Command) Category {
    return switch (command) {
        .new, .open, .save, .save_as, .reload, .close => .file,
        .git_status, .git_refresh, .git_diff, .git_staged_diff, .git_stage, .git_unstage => .git,
        .language_start, .language_stop, .language_restart, .language_status, .language_completion, .language_hover, .language_signature, .language_definition, .language_declaration, .language_type_definition, .language_implementation, .language_references, .language_document_symbols, .language_workspace_symbols, .language_problems, .language_formatting, .language_range_formatting, .language_rename, .language_code_actions, .language_semantic_tokens, .language_inlay_hints, .language_code_lenses, .language_document_links => .language,
        .find, .goto_line, .spelling, .excerpt, .grouped_undo, .grouped_redo => .edit,
        .open_folder, .open_workspace, .workspace_roots, .workspace_back, .workspace_rescan, .close_workspace, .quick_open, .workspace_search, .workspace_policy, .workspace_trust, .workspace_revoke, .save_workspace_session, .restore_workspace_session, .create_workspace_file, .create_workspace_directory, .rename_workspace_entry, .move_workspace_entry, .delete_workspace_entry, .recent_projects, .forget_project_session, .add_workspace_root, .remove_workspace_root, .save_workspace_as => .workspace,
        .split_group, .focus_next_group, .focus_previous_group, .close_group, .toggle_explorer, .toggle_search, .focus_explorer, .focus_search, .focus_editor, .hide_panel, .dock_left, .dock_right, .dock_bottom, .reset_docks, .dock_grow, .dock_shrink, .next_tab, .previous_tab, .open_buffers => .view,
        .new_window, .close_window, .next_window, .previous_window, .quit, .preferences, .about, .command_palette => .window,
    };
}

pub fn populateMenu(menu: *c.GMenu) void {
    // The palette remains flat/searchable; menu subpages retain every stable action.
    c.g_menu_append(menu, commands.Command.command_palette.label(), commands.Command.command_palette.metadata().detailed_action);
    for ([_]Category{ .file, .edit, .workspace, .language, .git, .view, .window }) |section| {
        const submenu = c.g_menu_new().?;
        defer c.g_object_unref(submenu);
        for (commands.entries) |entry| {
            if (entry.command != .command_palette and category(entry.command) == section)
                c.g_menu_append(submenu, entry.command.label(), entry.detailed_action);
        }
        c.g_menu_append_submenu(menu, section.label(), u.cast(c.GMenuModel, submenu));
    }
}
