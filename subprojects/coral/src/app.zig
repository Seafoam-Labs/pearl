const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const W = u.W;
const Document = @import("document.zig").Document;
const codec = @import("platform/codec.zig");
const spell = @import("spelling/checker.zig");
const Settings = @import("platform/settings.zig").Settings;
const test_hooks = @import("build_options").test_hooks;
pub var instance: *App = undefined;
pub const App = struct {
    application: *c.GtkApplication,
    window: W,
    notebook: W,
    new_button: W,
    search_button: W,
    searchbox: W,
    query: W,
    replacement: W,
    matches: W,
    status: W,
    spell_button: W,
    notice: W,
    docs: std.ArrayList(*Document) = .empty,
    next_id: u64 = 1,
    settings: Settings,
    worker: *spell.Worker,
    timer: c_uint = 0,
    generation: u64 = 1,
    max_spell_tick_us: i64 = 0,
    languages: std.ArrayList([:0]u8) = .empty,
    dictionary: bool = false,
    enumerated: bool = false,
    quitting: bool = false,
    closing: bool = false,
    css: *c.GtkCssProvider,
    font_css: *c.GtkCssProvider,
    dialog: ?W = null,
    dialog_doc: ?*Document = null,
    popover: ?W = null,
    menu_start: c_int = 0,
    menu_end: c_int = 0,
    menu_revision: u64 = 0,
    menu_word: ?[:0]u8 = null,
    dialog_kind: DialogKind = .close,
    goto_input: ?W = null,
    pub fn create(application: *c.GtkApplication, settings: Settings, width: c_int, height: c_int) *App {
        const self = a.create(App) catch unreachable;
        instance = self;
        const window = c.gtk_application_window_new(application).?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), "Coral");
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), width, height);
        const root = u.box(false, 0);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), root);
        const header = c.gtk_header_bar_new().?;
        c.gtk_window_set_titlebar(u.cast(c.GtkWindow, window), header);
        const title = u.label("Coral");
        c.gtk_header_bar_set_title_widget(u.cast(c.GtkHeaderBar, header), title);
        const open = u.icon("document-open-symbolic", "Open files · Ctrl+O");
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), open);
        u.connect(open, "clicked", &onOpen, self);
        const new = u.icon("list-add-symbolic", "New document · Ctrl+N");
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), new);
        u.connect(new, "clicked", &onNew, self);
        const menu = c.gtk_menu_button_new().?;
        c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, menu), "open-menu-symbolic");
        c.gtk_widget_set_tooltip_text(menu, "Editor menu");
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), menu);
        const search = u.icon("edit-find-symbolic", "Find and replace · Ctrl+F");
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), search);
        u.connect(search, "clicked", &onSearch, self);
        const save_button = u.icon("document-save-symbolic", "Save · Ctrl+S");
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), save_button);
        u.connect(save_button, "clicked", &onSave, self);
        const model = c.g_menu_new().?;
        defer c.g_object_unref(model);
        for ([_][2][*:0]const u8{ .{ "New document", "app.new" }, .{ "Open…", "app.open" }, .{ "Save", "app.save" }, .{ "Save As…", "app.save-as" }, .{ "Find / Replace", "app.find" }, .{ "Go to Line…", "app.goto" }, .{ "Spelling suggestions", "app.spelling" }, .{ "Preferences…", "app.preferences" }, .{ "About Coral", "app.about" }, .{ "Close tab", "app.close" }, .{ "Quit", "app.quit" } }) |item| c.g_menu_append(model, item[0], item[1]);
        c.gtk_menu_button_set_menu_model(u.cast(c.GtkMenuButton, menu), u.cast(c.GMenuModel, model));
        const notebook = c.gtk_notebook_new().?;
        c.gtk_notebook_set_scrollable(u.cast(c.GtkNotebook, notebook), 1);
        c.gtk_widget_set_vexpand(notebook, 1);
        const searchbox = u.box(false, 4);
        c.gtk_widget_add_css_class(searchbox, "search");
        const row = u.box(true, 6);
        u.append(searchbox, row);
        const query = c.gtk_search_entry_new().?;
        c.gtk_widget_set_hexpand(query, 1);
        c.gtk_widget_set_size_request(query, 80, -1);
        u.append(row, query);
        const matches = u.label("");
        u.append(row, matches);
        const prev = u.icon("go-up-symbolic", "Previous match · Shift+F3");
        u.append(row, prev);
        u.connect(prev, "clicked", &onPrev, self);
        const next = u.icon("go-down-symbolic", "Next match · F3");
        u.append(row, next);
        u.connect(next, "clicked", &onNext, self);
        const hide = u.icon("window-close-symbolic", "Close search · Escape");
        u.append(row, hide);
        u.connect(hide, "clicked", &onHideSearch, self);
        const replace_row = u.box(true, 6);
        u.append(searchbox, replace_row);
        const replacement = c.gtk_entry_new().?;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, replacement), "Replace with");
        c.gtk_widget_set_hexpand(replacement, 1);
        c.gtk_widget_set_size_request(replacement, 80, -1);
        u.append(replace_row, replacement);
        const replace_button = u.button("Replace");
        u.append(replace_row, replace_button);
        u.connect(replace_button, "clicked", &onReplace, self);
        const all = u.button("Replace all");
        u.append(replace_row, all);
        u.connect(all, "clicked", &onReplaceAll, self);
        u.append(root, searchbox);
        c.gtk_widget_set_visible(searchbox, 0);
        const notice = u.label("");
        c.gtk_widget_add_css_class(notice, "notice");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, notice), 1);
        u.append(root, notice);
        c.gtk_widget_set_visible(notice, 0);
        u.append(root, notebook);
        const footer = u.box(true, 8);
        c.gtk_widget_add_css_class(footer, "status");
        const status = u.label("");
        c.gtk_widget_set_hexpand(status, 1);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_END);
        u.append(footer, status);
        const spell_button = u.button("Checking dictionaries…");
        u.append(footer, spell_button);
        u.connect(spell_button, "clicked", &onSpelling, self);
        u.append(root, footer);
        self.* = .{ .application = application, .window = window, .notebook = notebook, .new_button = new, .search_button = search, .searchbox = searchbox, .query = query, .replacement = replacement, .matches = matches, .status = status, .spell_button = spell_button, .notice = notice, .settings = settings, .worker = spell.Worker.start(), .css = c.gtk_css_provider_new().?, .font_css = c.gtk_css_provider_new().? };
        c.gtk_css_provider_load_from_string(self.css, @embedFile("style"));
        c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.css), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.font_css), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        c.gtk_widget_add_css_class(window, "coral");
        u.connect(window, "close-request", &onCloseWindow, self);
        u.connect(notebook, "switch-page", &onSwitch, self);
        u.connect(query, "search-changed", &onQuery, self);
        u.connect(query, "activate", &onNext, self);
        const keys = c.gtk_event_controller_key_new().?;
        c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
        u.connect(keys, "key-pressed", &onKey, self);
        c.gtk_widget_add_controller(window, keys);
        const names = [_][*:0]const u8{ "new", "open", "save", "save-as", "find", "goto", "spelling", "preferences", "about", "close", "quit" };
        for (names) |name| {
            const action = c.g_simple_action_new(name, null).?;
            u.connect(action, "activate", &onAction, self);
            c.g_action_map_add_action(u.cast(c.GActionMap, application), u.cast(c.GAction, action));
            c.g_object_unref(action);
        }
        self.applySettings();
        self.timer = c.g_timeout_add(20, &tick, self);
        self.worker.submit(spell.Job.create(.list, "", ""));
        c.gtk_window_present(u.cast(c.GtkWindow, window));
        return self;
    }
    pub fn deinit(self: *App) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.worker.stop();
        // File operations keep the application alive and prevent window closure.
        for (self.docs.items) |d| d.destroy();
        self.docs.deinit(a);
        for (self.languages.items) |lang| a.free(lang);
        self.languages.deinit(a);
        if (self.menu_word) |word| a.free(word);
        c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.css));
        c.g_object_unref(self.css);
        c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.font_css));
        c.g_object_unref(self.font_css);
        a.destroy(self);
    }
    pub fn active(self: *App) ?*Document {
        if (self.closing) return null;
        const index = c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, self.notebook));
        if (index < 0) return null;
        const page = c.gtk_notebook_get_nth_page(u.cast(c.GtkNotebook, self.notebook), index);
        for (self.docs.items) |d| if (d.page == page) return d;
        return null;
    }
    fn find(self: *App, id: u64) ?*Document {
        for (self.docs.items) |d| if (d.id == id) return d;
        return null;
    }
    fn focus(self: *App, d: *Document) void {
        c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, self.notebook), c.gtk_notebook_page_num(u.cast(c.GtkNotebook, self.notebook), d.page));
        _ = c.gtk_widget_grab_focus(d.view);
    }
    pub fn newDocument(self: *App) *Document {
        const d = a.create(Document) catch unreachable;
        const source = c.gtk_source_buffer_new(null).?;
        const buffer = u.cast(c.GtkTextBuffer, source);
        c.gtk_text_buffer_set_enable_undo(buffer, 1);
        const view = c.gtk_source_view_new_with_buffer(source).?;
        c.gtk_text_view_set_monospace(u.cast(c.GtkTextView, view), 1);
        c.gtk_text_view_set_left_margin(u.cast(c.GtkTextView, view), 18);
        c.gtk_text_view_set_right_margin(u.cast(c.GtkTextView, view), 18);
        c.gtk_text_view_set_top_margin(u.cast(c.GtkTextView, view), 22);
        c.gtk_text_view_set_bottom_margin(u.cast(c.GtkTextView, view), 22);
        const page = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, page), view);
        c.gtk_widget_set_hexpand(page, 1);
        c.gtk_widget_set_vexpand(page, 1);
        const tab = u.box(true, 6);
        const tab_label = u.label("Untitled");
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, tab_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, tab_label), 28);
        c.gtk_label_set_width_chars(u.cast(c.GtkLabel, tab_label), 18);
        u.append(tab, tab_label);
        const close = u.icon("window-close-symbolic", "Close document");
        c.gtk_widget_add_css_class(close, "flat");
        u.append(tab, close);
        u.connect(close, "clicked", &onCloseTab, d);
        const settings = c.gtk_source_search_settings_new().?;
        c.gtk_source_search_settings_set_wrap_around(settings, 1);
        const search = c.gtk_source_search_context_new(source, settings).?;
        const tag = c.gtk_text_buffer_create_tag(buffer, "coral-spelling", "underline", @as(c_int, c.PANGO_UNDERLINE_ERROR), @as(?*anyopaque, null)).?;
        d.* = .{ .id = self.next_id, .buffer = buffer, .view = view, .page = page, .tab = tab, .tab_label = tab_label, .search = search, .search_settings = settings, .tag = tag };
        self.next_id += 1;
        self.docs.append(a, d) catch unreachable;
        u.connect(buffer, "changed", &onChanged, d);
        u.connect(buffer, "modified-changed", &onModified, d);
        u.connect(buffer, "mark-set", &onMark, d);
        u.connect(buffer, "insert-text", &onInsert, d);
        u.connect(buffer, "delete-range", &onDelete, d);
        const click = c.gtk_gesture_click_new().?;
        c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, click), 3);
        c.gtk_event_controller_set_propagation_phase(u.cast(c.GtkEventController, click), c.GTK_PHASE_CAPTURE);
        u.connect(click, "pressed", &onContext, d);
        c.gtk_widget_add_controller(view, u.cast(c.GtkEventController, click));
        const index = c.gtk_notebook_append_page(u.cast(c.GtkNotebook, self.notebook), page, tab);
        c.gtk_notebook_set_tab_reorderable(u.cast(c.GtkNotebook, self.notebook), page, 1);
        c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, self.notebook), index);
        self.configure(d);
        self.update();
        _ = c.gtk_widget_grab_focus(view);
        return d;
    }
    fn configure(self: *App, d: *Document) void {
        const view = u.cast(c.GtkSourceView, d.view);
        c.gtk_source_view_set_show_line_numbers(view, @intFromBool(self.settings.lines));
        c.gtk_source_view_set_tab_width(view, @intCast(self.settings.indent));
        c.gtk_source_view_set_insert_spaces_instead_of_tabs(view, @intFromBool(self.settings.spaces));
        c.gtk_source_view_set_auto_indent(view, 1);
        c.gtk_source_view_set_highlight_current_line(view, 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, d.view), if (self.settings.wrap) c.GTK_WRAP_WORD_CHAR else c.GTK_WRAP_NONE);
        const manager = c.gtk_source_style_scheme_manager_get_default();
        var prefer_dark: c_int = 0;
        c.g_object_get(c.gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &prefer_dark, @as(?*anyopaque, null));
        const name: [*:0]const u8 = if (self.settings.theme == 2) (if (prefer_dark != 0) "Adwaita-dark" else "Adwaita") else if (self.settings.theme == 1) "coral-light" else "coral-dark";
        const scheme = c.gtk_source_style_scheme_manager_get_scheme(manager, name);
        c.gtk_source_buffer_set_style_scheme(u.cast(c.GtkSourceBuffer, d.buffer), scheme);
        var underline: c.GdkRGBA = undefined;
        _ = c.gdk_rgba_parse(&underline, if (self.settings.theme == 1) "#9b2a21" else "#ffb4ab");
        c.g_object_set(d.tag, "underline-rgba", &underline, @as(?*anyopaque, null));
        const language_manager = c.gtk_source_language_manager_get_default();
        const language = if (d.path) |p| c.gtk_source_language_manager_guess_language(language_manager, p, null) else null;
        c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, d.buffer), language);
        c.gtk_source_buffer_set_highlight_syntax(u.cast(c.GtkSourceBuffer, d.buffer), @intFromBool(!d.large));
    }
    fn styleWindow(self: *App, widget: W) void {
        if (self.settings.theme == 2) c.gtk_widget_remove_css_class(widget, "coral") else c.gtk_widget_add_css_class(widget, "coral");
        if (self.settings.theme == 1) c.gtk_widget_add_css_class(widget, "light") else c.gtk_widget_remove_css_class(widget, "light");
    }
    fn applySettings(self: *App) void {
        if (self.dialog) |dialog| self.styleWindow(dialog);
        if (self.settings.theme == 2) c.gtk_widget_remove_css_class(self.window, "coral") else c.gtk_widget_add_css_class(self.window, "coral");
        if (self.settings.theme == 1) c.gtk_widget_add_css_class(self.window, "light") else c.gtk_widget_remove_css_class(self.window, "light");
        const css = u.fmt("textview {{ font-family: monospace; font-size: {d:.3}em; }}", .{@as(f64, @floatFromInt(self.settings.font)) / 14.667});
        defer a.free(css);
        c.gtk_css_provider_load_from_string(self.font_css, css);
        for (self.docs.items) |d| self.configure(d);
    }
    fn message(self: *App, text: []const u8) void {
        u.setLabel(self.notice, text);
        c.gtk_widget_set_visible(self.notice, @intFromBool(text.len > 0));
    }
    fn update(self: *App) void {
        if (self.closing) return;
        const wide = c.gtk_widget_get_width(self.window) >= 620;
        c.gtk_widget_set_visible(self.new_button, @intFromBool(wide));
        c.gtk_widget_set_visible(self.search_button, @intFromBool(wide));
        for (self.docs.items) |d| {
            var name: []const u8 = if (d.path) |p| std.fs.path.basename(p) else "Untitled";
            if (d.path) |p| {
                for (self.docs.items) |other| {
                    if (other == d) continue;
                    if (other.path) |q| {
                        if (std.mem.eql(u8, std.fs.path.basename(q), name)) {
                            name = p;
                            break;
                        }
                    }
                }
            }
            const title = u.fmt("{s}{s}", .{ name, if (d.dirty()) " •" else "" });
            u.setLabel(d.tab_label, title);
            a.free(title);
            if (d.path) |p| c.gtk_widget_set_tooltip_text(d.tab, p);
        }
        const d = self.active() orelse return;
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(d.buffer, &iter, c.gtk_text_buffer_get_insert(d.buffer));
        const status = u.fmt("Ln {d}, Col {d}   ·   UTF-8{s} · {s}{s}", .{ c.gtk_text_iter_get_line(&iter) + 1, c.gtk_text_iter_get_line_offset(&iter) + 1, if (d.bom) " BOM" else "", @tagName(d.newline), if (d.busy) " · Working…" else if (d.large) " · Large file" else "" });
        u.setLabel(self.status, status);
        a.free(status);
        const spelling_text: [*:0]const u8 = if (!self.enumerated) "Checking dictionaries…" else if (!self.dictionary) "Dictionary unavailable" else if (!self.spellingEnabled(d)) "Spelling off" else "Spelling";
        c.gtk_button_set_label(u.cast(c.GtkButton, self.spell_button), spelling_text);
        const count = c.gtk_source_search_context_get_occurrences_count(d.search);
        const count_text = u.fmt("{d} matches", .{@max(count, 0)});
        u.setLabel(self.matches, count_text);
        a.free(count_text);
        const title = u.fmt("{s}{s} — Coral", .{ if (d.path) |p| std.fs.path.basename(p) else "Untitled", if (d.dirty()) " •" else "" });
        c.gtk_window_set_title(u.cast(c.GtkWindow, self.window), title);
        a.free(title);
    }
    fn spellingEnabled(self: *App, d: *Document) bool {
        if (d.large) return false;
        if (d.spell_override) |enabled| return enabled;
        if (!self.settings.spelling) return false;
        if (d.path) |path| {
            const ext = std.fs.path.extension(path);
            return ext.len == 0 or std.mem.eql(u8, ext, ".txt") or std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown");
        }
        return true;
    }
    fn invalidate(self: *App, d: *Document) void {
        _ = self;
        d.check_from = 0;
        d.priority_revision = std.math.maxInt(u64);
        d.due = c.g_get_monotonic_time() + 250000;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_bounds(d.buffer, &start, &end);
        c.gtk_text_buffer_remove_tag(d.buffer, d.tag, &start, &end);
    }
    fn hidePopover(self: *App) void {
        if (self.popover) |pop| {
            self.popover = null;
            c.gtk_popover_popdown(u.cast(c.GtkPopover, pop));
            c.gtk_widget_unparent(pop);
            self.popover = null;
        }
    }
    pub fn openPath(self: *App, path: []const u8) void {
        const p = u.z(path);
        defer a.free(p);
        const file = c.g_file_new_for_commandline_arg(p).?;
        defer c.g_object_unref(file);
        if (c.g_file_is_native(file) == 0) {
            self.message("Only local files are supported.");
            return;
        }
        const raw = c.g_file_get_path(file);
        defer c.g_free(raw);
        if (raw == null) return;
        const real = c.realpath(raw, null);
        defer if (real != null) c.free(real);
        const canonical = if (real != null) std.mem.span(real) else std.mem.span(raw);
        for (self.docs.items) |d| {
            if (d.path) |existing| {
                if (std.mem.eql(u8, existing, canonical)) {
                    self.focus(d);
                    return;
                }
            }
        }
        const d = self.newDocument();
        d.path = u.z(canonical);
        self.load(d, false);
    }
    fn load(self: *App, d: *Document, reload: bool) void {
        if (d.busy) return;
        const path = d.path orelse return;
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        const op = a.create(LoadOp) catch unreachable;
        op.* = .{ .doc = d, .reload = reload };
        d.busy = true;
        d.loading = true;
        d.cancellable = c.g_cancellable_new();
        c.gtk_text_view_set_editable(u.cast(c.GtkTextView, d.view), 0);
        c.g_application_hold(u.cast(c.GApplication, self.application));
        c.g_file_load_partial_contents_async(file, d.cancellable, &readMore, &loaded, op);
        self.update();
    }
    fn commitLoad(self: *App, d: *Document, text: []const u8) void {
        c.gtk_text_buffer_begin_irreversible_action(d.buffer);
        c.gtk_text_buffer_set_text(d.buffer, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_end_irreversible_action(d.buffer);
        c.gtk_text_buffer_set_modified(d.buffer, 0);
        d.saved_revision = d.revision;
        d.loading = false;
        self.configure(d);
        self.invalidate(d);
        self.update();
    }
    fn save(self: *App, d: *Document, save_as: bool, force: bool) void {
        if (d.busy) {
            self.message("Wait for the current file operation to finish.");
            return;
        }
        if (d.newline == .mixed) {
            d.normalize_save_as = save_as;
            self.ask(.mixed, d, "Choose a line ending", "This file mixes LF and CRLF line endings. Choose a format before saving; Coral will normalize line endings explicitly.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Use LF", .id = 1 }, .{ .text = "Use CRLF", .id = 2 } });
            return;
        }
        if (save_as or d.path == null) {
            self.chooseSave(d);
            return;
        }
        self.saveTo(d, d.path.?, force, false);
    }
    fn saveTo(self: *App, d: *Document, requested_path: []const u8, force: bool, as: bool) void {
        if (d.busy) return;
        const path = u.canonicalPath(requested_path);
        defer a.free(path);
        for (self.docs.items) |other| {
            if (other != d) {
                if (other.path) |p| {
                    if (std.mem.eql(u8, p, path)) {
                        self.message("That file is already open in another tab. Save to a different name.");
                        d.close_after_save = false;
                        self.quitting = false;
                        return;
                    }
                }
            }
        }
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const bytes = codec.encode(a, text, d.bom, d.newline) catch {
            self.message("Choose a line ending before saving.");
            return;
        };
        const op = a.create(SaveOp) catch unreachable;
        op.* = .{ .doc = d, .path = u.z(path), .data = bytes, .revision = d.revision, .etag = if (!force and !as) if (d.etag) |e| u.z(e) else null else null };
        const file = c.g_file_new_for_path(op.path).?;
        defer c.g_object_unref(file);
        d.busy = true;
        d.cancellable = c.g_cancellable_new();
        c.g_application_hold(u.cast(c.GApplication, self.application));
        if (!force and !as) c.g_file_query_info_async(file, "etag::value", c.G_FILE_QUERY_INFO_NONE, c.G_PRIORITY_DEFAULT, d.cancellable, &savePreflight, op) else startReplace(file, op);
        self.update();
    }
    fn chooseOpen(self: *App) void {
        const chooser = c.gtk_file_dialog_new().?;
        c.gtk_file_dialog_set_title(chooser, "Open text files");
        c.g_application_hold(u.cast(c.GApplication, self.application));
        c.gtk_file_dialog_open_multiple(chooser, u.cast(c.GtkWindow, self.window), null, &chosenOpen, self);
        c.g_object_unref(chooser);
    }
    fn chooseSave(self: *App, d: *Document) void {
        const chooser = c.gtk_file_dialog_new().?;
        c.gtk_file_dialog_set_title(chooser, "Save document");
        c.gtk_file_dialog_set_initial_name(chooser, if (d.path) |p| std.fs.path.basename(p).ptr else "Untitled.txt");
        d.busy = true;
        c.g_application_hold(u.cast(c.GApplication, self.application));
        c.gtk_file_dialog_save(chooser, u.cast(c.GtkWindow, self.window), null, &chosenSave, d);
        c.g_object_unref(chooser);
    }
    fn ask(self: *App, kind: DialogKind, d: ?*Document, title: [*:0]const u8, detail: [*:0]const u8, buttons: []const Button) void {
        if (self.dialog != null) return;
        self.hidePopover();
        const dialog = c.gtk_message_dialog_new(u.cast(c.GtkWindow, self.window), c.GTK_DIALOG_MODAL, c.GTK_MESSAGE_QUESTION, c.GTK_BUTTONS_NONE, "%s", title).?;
        c.gtk_message_dialog_format_secondary_text(u.cast(c.GtkMessageDialog, dialog), "%s", detail);
        for (buttons) |b| _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), b.text, b.id);
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), 0);
        self.styleWindow(dialog);
        self.dialog = dialog;
        self.dialog_kind = kind;
        self.dialog_doc = d;
        u.connect(dialog, "response", &dialogResponse, self);
        testKeys(self, dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn closeDocument(self: *App, d: *Document) void {
        self.hidePopover();
        if (d.busy) {
            if (d.loading) {
                d.cancelled_close = true;
                if (d.cancellable) |p| c.g_cancellable_cancel(p);
            } else {
                self.message("Saving is still in progress. Close this document after it finishes.");
                self.quitting = false;
            }
            return;
        }
        if (d.dirty()) {
            self.focus(d);
            self.ask(.close, d, "Save your changes?", "Save this document before closing it? Discarding loses the unsaved edits.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Discard", .id = 1 }, .{ .text = "Save", .id = 2 } });
            return;
        }
        self.remove(d);
    }
    fn remove(self: *App, d: *Document) void {
        self.hidePopover();
        var index: usize = 0;
        while (index < self.docs.items.len) : (index += 1) {
            if (self.docs.items[index] == d) {
                _ = self.docs.orderedRemove(index);
                break;
            }
        }
        const page = c.gtk_notebook_page_num(u.cast(c.GtkNotebook, self.notebook), d.page);
        c.gtk_notebook_remove_page(u.cast(c.GtkNotebook, self.notebook), page);
        d.destroy();
        if (self.docs.items.len == 0) {
            self.shutdownWindow();
            return;
        }
        self.update();
        if (self.quitting) self.closeDocument(self.docs.items[self.docs.items.len - 1]);
    }
    fn shutdownWindow(self: *App) void {
        self.closing = true;
        if (self.timer != 0) {
            _ = c.g_source_remove(self.timer);
            self.timer = 0;
        }
        c.gtk_window_destroy(u.cast(c.GtkWindow, self.window));
    }
    fn quit(self: *App) void {
        if (self.dialog != null) return;
        self.quitting = true;
        if (self.docs.items.len > 0) self.closeDocument(self.docs.items[self.docs.items.len - 1]) else self.shutdownWindow();
    }
    fn showSearch(self: *App, show: bool) void {
        c.gtk_widget_set_visible(self.searchbox, @intFromBool(show));
        if (show) {
            _ = c.gtk_widget_grab_focus(self.query);
        } else {
            for (self.docs.items) |d| c.gtk_source_search_settings_set_search_text(d.search_settings, null);
            if (self.active()) |d| _ = c.gtk_widget_grab_focus(d.view);
        }
    }
    fn findMatch(self: *App, back: bool) void {
        const d = self.active() orelse return;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        _ = c.gtk_text_buffer_get_selection_bounds(d.buffer, &start, &end);
        var at = if (back) start else end;
        const found = if (back) c.gtk_source_search_context_backward(d.search, &at, &start, &end, null) else c.gtk_source_search_context_forward(d.search, &at, &start, &end, null);
        if (found != 0) {
            c.gtk_text_buffer_select_range(d.buffer, &start, &end);
            _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, d.view), &start, 0.1, 0, 0, 0);
        }
        self.update();
    }
    fn replace(self: *App, all: bool) void {
        const d = self.active() orelse return;
        if (d.loading) return;
        const replacement = u.z(u.entryText(self.replacement));
        defer a.free(replacement);
        if (all) {
            c.gtk_text_buffer_begin_user_action(d.buffer);
            _ = c.gtk_source_search_context_replace_all(d.search, replacement, @intCast(replacement.len), null);
            c.gtk_text_buffer_end_user_action(d.buffer);
        } else {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            if (c.gtk_text_buffer_get_selection_bounds(d.buffer, &start, &end) == 0) {
                self.findMatch(false);
                _ = c.gtk_text_buffer_get_selection_bounds(d.buffer, &start, &end);
            }
            if (c.gtk_source_search_context_get_occurrence_position(d.search, &start, &end) > 0) {
                _ = c.gtk_source_search_context_replace(d.search, &start, &end, replacement, @intCast(replacement.len), null);
            }
            self.findMatch(false);
        }
        self.update();
    }
    fn preferences(self: *App) void {
        if (self.dialog != null) return;
        self.hidePopover();
        const dialog = c.gtk_dialog_new().?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), "Coral preferences");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 440, 520);
        const box = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        u.margin(box, 20);
        const heading = u.label("Make yourself at home");
        c.gtk_widget_add_css_class(heading, "title-2");
        u.append(box, heading);
        const theme = c.gtk_combo_box_text_new().?;
        for ([_][*:0]const u8{ "Pearl dark", "Pearl light", "Native GTK" }) |name| c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, theme), name);
        c.gtk_combo_box_set_active(u.cast(c.GtkComboBox, theme), self.settings.theme);
        self.prefRow(box, "Appearance", theme);
        u.connect(theme, "changed", &prefTheme, self);
        const font = c.gtk_spin_button_new_with_range(8, 32, 1).?;
        c.gtk_spin_button_set_value(u.cast(c.GtkSpinButton, font), @floatFromInt(self.settings.font));
        self.prefRow(box, "Text size", font);
        u.connect(font, "value-changed", &prefFont, self);
        const indent = c.gtk_spin_button_new_with_range(1, 8, 1).?;
        c.gtk_spin_button_set_value(u.cast(c.GtkSpinButton, indent), @floatFromInt(self.settings.indent));
        self.prefRow(box, "Indent width", indent);
        u.connect(indent, "value-changed", &prefIndent, self);
        inline for (.{ .{ "Line numbers", "lines" }, .{ "Wrap text", "wrap" }, .{ "Insert spaces", "spaces" }, .{ "Check spelling by default", "spelling" } }) |entry| {
            const check = c.gtk_check_button_new().?;
            c.gtk_check_button_set_active(u.cast(c.GtkCheckButton, check), @intFromBool(@field(self.settings, entry[1])));
            self.prefRow(box, entry[0], check);
            c.g_object_set_data(u.cast(c.GObject, check), "coral-pref", @constCast(entry[1]));
            u.connect(check, "toggled", &prefToggle, self);
        }
        const language = c.gtk_combo_box_text_new().?;
        c.gtk_combo_box_text_append(u.cast(c.GtkComboBoxText, language), "", "Choose dictionary");
        for (self.languages.items) |lang| c.gtk_combo_box_text_append(u.cast(c.GtkComboBoxText, language), lang, lang);
        _ = c.gtk_combo_box_set_active_id(u.cast(c.GtkComboBox, language), &self.settings.language);
        self.prefRow(box, "Spelling language", language);
        u.connect(language, "changed", &prefLanguage, self);
        if (self.active()) |d| {
            const check = c.gtk_check_button_new().?;
            c.gtk_check_button_set_active(u.cast(c.GtkCheckButton, check), @intFromBool(self.spellingEnabled(d)));
            self.prefRow(box, "Check current document", check);
            u.connect(check, "toggled", &prefDocument, d);
        }
        const note = u.label(if (self.languages.items.len == 0) "No dictionaries found. Install an Enchant provider and a language dictionary, then restart Coral." else "Personal dictionary words may be shared with other Enchant applications.");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, note), 1);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, note), 42);
        u.margin(note, 8);
        u.append(box, note);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Done", 0);
        self.styleWindow(dialog);
        self.dialog = dialog;
        self.dialog_kind = .preferences;
        u.connect(dialog, "response", &dialogResponse, self);
        testKeys(self, dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn prefRow(_: *App, box: W, name: []const u8, control: W) void {
        const row = u.box(true, 12);
        u.margin(row, 6);
        const text = u.label(name);
        const accessible = u.z(name);
        defer a.free(accessible);
        c.gtk_accessible_update_property(u.cast(c.GtkAccessible, control), @as(c_int, c.GTK_ACCESSIBLE_PROPERTY_LABEL), accessible.ptr, @as(c_int, -1));
        c.gtk_label_set_mnemonic_widget(u.cast(c.GtkLabel, text), control);
        c.gtk_widget_set_hexpand(text, 1);
        u.append(row, text);
        u.append(row, control);
        u.append(box, row);
    }
    fn gotoLine(self: *App) void {
        if (self.dialog != null) return;
        const d = self.active() orelse return;
        self.ask(.goto, d, "Go to line", "Enter a line number.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Go", .id = 1 } });
        const input = c.gtk_spin_button_new_with_range(1, @floatFromInt(@max(c.gtk_text_buffer_get_line_count(d.buffer), 1)), 1).?;
        self.goto_input = input;
        u.append(u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, self.dialog.?))), input);
        _ = c.gtk_widget_grab_focus(input);
    }
    fn requestSuggestions(self: *App, d: *Document) void {
        if (!self.dictionary or !self.spellingEnabled(d)) {
            self.preferences();
            return;
        }
        self.hidePopover();
        var start: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(d.buffer, &start, c.gtk_text_buffer_get_insert(d.buffer));
        if (c.gtk_text_iter_has_tag(&start, d.tag) == 0) {
            c.gtk_text_buffer_get_start_iter(d.buffer, &start);
            if (c.gtk_text_iter_has_tag(&start, d.tag) == 0 and c.gtk_text_iter_forward_to_tag_toggle(&start, d.tag) == 0) {
                self.message("No spelling suggestions in this document.");
                return;
            }
        }
        var end = start;
        if (c.gtk_text_iter_starts_tag(&start, d.tag) == 0) _ = c.gtk_text_iter_backward_to_tag_toggle(&start, d.tag);
        _ = c.gtk_text_iter_forward_to_tag_toggle(&end, d.tag);
        const text = c.gtk_text_buffer_get_text(d.buffer, &start, &end, 1);
        defer c.g_free(text);
        const job = spell.Job.create(.suggest, std.mem.span(text), std.mem.sliceTo(&self.settings.language, 0));
        job.id = d.id;
        job.revision = d.revision;
        job.generation = self.generation;
        job.offset = c.gtk_text_iter_get_offset(&start);
        job.end = c.gtk_text_iter_get_offset(&end);
        self.worker.submit(job);
    }
    fn showSuggestions(self: *App, d: *Document, job: *spell.Job) void {
        if (self.active() != d or self.dialog != null) return;
        self.hidePopover();
        if (self.menu_word) |word| a.free(word);
        self.menu_word = u.z(job.text);
        self.menu_start = job.offset;
        self.menu_end = job.end;
        self.menu_revision = d.revision;
        const pop = c.gtk_popover_new().?;
        self.popover = pop;
        u.connect(pop, "closed", &popoverClosed, self);
        self.dialog_doc = d;
        testKeys(self, pop);
        c.gtk_widget_set_parent(pop, d.view);
        const box = u.box(false, 3);
        u.margin(box, 8);
        c.gtk_popover_set_child(u.cast(c.GtkPopover, pop), box);
        const title = u.label(job.text);
        c.gtk_widget_add_css_class(title, "heading");
        u.margin(title, 4);
        u.append(box, title);
        for (job.words.items) |word| {
            const button = u.button(word);
            const owned = u.z(word);
            c.g_object_set_data_full(u.cast(c.GObject, button), "correction", owned.ptr, &freeString);
            u.connect(button, "clicked", &correctWord, self);
            u.append(box, button);
        }
        if (job.words.items.len == 0) u.append(box, u.label("No replacements found"));
        for ([_]struct { title: [*:0]const u8, callback: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void }{ .{ .title = "Ignore for this document", .callback = &ignoreWord }, .{ .title = "Add to dictionary", .callback = &addWord }, .{ .title = "Language…", .callback = &onPreferences } }) |item| {
            const button = u.button(item.title);
            u.connect(button, "clicked", item.callback, self);
            u.append(box, button);
        }
        const separator = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?;
        u.append(box, separator);
        for ([_][2][*:0]const u8{ .{ "Cut", "clipboard.cut" }, .{ "Copy", "clipboard.copy" }, .{ "Paste", "clipboard.paste" } }) |item| {
            const button = u.button(item[0]);
            c.g_object_set_data(u.cast(c.GObject, button), "edit-action", @constCast(item[1]));
            u.connect(button, "clicked", &editAction, self);
            u.append(box, button);
        }
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(d.buffer, &iter, job.offset);
        _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, d.view), &iter, 0.1, 0, 0, 0);
        var rect: c.GdkRectangle = undefined;
        c.gtk_text_view_get_iter_location(u.cast(c.GtkTextView, d.view), &iter, &rect);
        c.gtk_text_view_buffer_to_window_coords(u.cast(c.GtkTextView, d.view), c.GTK_TEXT_WINDOW_WIDGET, rect.x, rect.y, &rect.x, &rect.y);
        c.gtk_popover_set_pointing_to(u.cast(c.GtkPopover, pop), &rect);
        c.gtk_popover_popup(u.cast(c.GtkPopover, pop));
    }
    fn resetSpelling(self: *App) void {
        self.generation += 1;
        self.hidePopover();
        for (self.docs.items) |d| self.invalidate(d);
        self.update();
    }
    fn probe(self: *App) void {
        const d = self.active() orelse return;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        var start: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_start_iter(d.buffer, &start);
        var count: usize = 0;
        while (c.gtk_text_iter_forward_to_tag_toggle(&start, d.tag) != 0) {
            if (c.gtk_text_iter_starts_tag(&start, d.tag) != 0) count += 1;
        }
        c.gtk_text_buffer_get_start_iter(d.buffer, &start);
        if (c.gtk_text_iter_has_tag(&start, d.tag) != 0) count += 1;
        c.g_print("CORAL_PROBE {\"tabs\":%zu,\"id\":%llu,\"dirty\":%s,\"busy\":%s,\"revision\":%llu,\"chars\":%d,\"spelling\":%zu,\"dictionary\":%s,\"enumerated\":%s,\"search\":%d,\"dialog\":%d,\"popover\":%s,\"theme\":%d,\"font\":%d,\"lines\":%s,\"bom\":%s,\"newline\":%d,\"check_from\":%d,\"inflight\":%s,\"checking_enabled\":%s,\"large\":%s,\"max_spell_tick_us\":%lld}\n", self.docs.items.len, @as(c_ulonglong, d.id), boolZ(d.dirty()), boolZ(d.busy), @as(c_ulonglong, d.revision), c.gtk_text_buffer_get_char_count(d.buffer), count, boolZ(self.dictionary), boolZ(self.enumerated), c.gtk_source_search_context_get_occurrences_count(d.search), @as(c_int, if (self.dialog != null) @intCast(@intFromEnum(self.dialog_kind)) else -1), boolZ(self.popover != null), self.settings.theme, self.settings.font, boolZ(self.settings.lines), boolZ(d.bom), @as(c_int, @intCast(@intFromEnum(d.newline))), d.check_from, boolZ(d.inflight), boolZ(self.spellingEnabled(d)), boolZ(d.large), @as(c_longlong, self.max_spell_tick_us));
    }
};
const DialogKind = enum { close, mixed, conflict, large, reload, preferences, goto };
const Button = struct { text: [*:0]const u8, id: c_int };
const LoadOp = struct { doc: *Document, reload: bool };
const SaveOp = struct { doc: *Document, path: [:0]u8, data: []u8, revision: u64, etag: ?[:0]u8 = null };
fn boolZ(v: bool) [*:0]const u8 {
    return if (v) "true" else "false";
}
fn readMore(_: [*c]const u8, size: i64, _: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(size <= 128 * 1024 * 1024);
}
fn loaded(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = instance;
    const op = u.cast(LoadOp, data.?);
    const d = op.doc;
    defer a.destroy(op);
    defer c.g_application_release(u.cast(c.GApplication, self.application));
    var contents: [*c]u8 = null;
    var size: usize = 0;
    var etag: [*c]u8 = null;
    var err: ?*c.GError = null;
    const ok = c.g_file_load_partial_contents_finish(u.cast(c.GFile, source.?), result, &contents, &size, &etag, &err) != 0;
    defer c.g_free(contents);
    defer c.g_free(etag);
    d.busy = false;
    d.loading = false;
    if (d.cancellable) |p| c.g_object_unref(p);
    d.cancellable = null;
    c.gtk_text_view_set_editable(u.cast(c.GtkTextView, d.view), 1);
    if (d.cancelled_close) {
        if (err) |e| c.g_error_free(e);
        self.remove(d);
        return;
    }
    if (!ok) {
        if (err) |e| {
            self.message(std.mem.span(e.message));
            c.g_error_free(e);
        }
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        self.quitting = false;
        self.update();
        return;
    }
    if (size > 128 * 1024 * 1024) {
        self.message("This file exceeds Coral's 128 MiB safety limit.");
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        return;
    }
    const decoded = codec.decode(a, contents[0..size]) catch |e| {
        self.message(switch (e) {
            error.InvalidUtf8 => "This file is not valid UTF-8. Convert its encoding before opening it in Coral.",
            error.UnsupportedLineEnding => "Standalone CR line endings are not supported. Convert this file to LF or CRLF.",
            else => "This file contains binary data and cannot be edited as text.",
        });
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        self.update();
        return;
    };
    d.pending = decoded;
    if (etag != null) d.pending_etag = u.z(std.mem.span(etag));
    if (size > 10 * 1024 * 1024) {
        self.ask(.large, d, "Open in large-file mode?", "This file is larger than 10 MiB. Automatic spelling and syntax highlighting will be disabled.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Open large file", .id = 1 } });
    } else acceptLoaded(self, d, false);
}
fn acceptLoaded(self: *App, d: *Document, large: bool) void {
    const decoded = d.pending orelse return;
    d.pending = null;
    defer a.free(decoded.text);
    d.bom = decoded.bom;
    d.newline = decoded.newline;
    d.large = large;
    if (d.etag) |p| a.free(p);
    d.etag = d.pending_etag;
    d.pending_etag = null;
    self.commitLoad(d, decoded.text);
    self.message(if (d.newline == .mixed) "Mixed line endings detected. Choose LF or CRLF when you save." else "");
}
fn startReplace(file: *c.GFile, op: *SaveOp) void {
    c.g_file_replace_contents_async(file, op.data.ptr, op.data.len, if (op.etag) |e| e.ptr else null, 0, c.G_FILE_CREATE_NONE, op.doc.cancellable, &saved, op);
}
fn savePreflight(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op = u.cast(SaveOp, data.?);
    var err: ?*c.GError = null;
    const info = c.g_file_query_info_finish(u.cast(c.GFile, source.?), result, &err);
    if (info != null) {
        c.g_object_unref(info);
        startReplace(u.cast(c.GFile, source.?), op);
        return;
    }
    if (err) |e| {
        if (e.domain == c.g_io_error_quark() and e.code == c.G_IO_ERROR_NOT_FOUND) {
            c.g_error_free(e);
            err = c.g_error_new_literal(c.g_io_error_quark(), c.G_IO_ERROR_WRONG_ETAG, "The file was removed from disk.");
        }
    }
    finishSave(op, false, null, err);
}
fn saved(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op = u.cast(SaveOp, data.?);
    var etag: [*c]u8 = null;
    var err: ?*c.GError = null;
    const ok = c.g_file_replace_contents_finish(u.cast(c.GFile, source.?), result, &etag, &err) != 0;
    defer c.g_free(etag);
    finishSave(op, ok, etag, err);
}
fn finishSave(op: *SaveOp, ok: bool, etag: [*c]u8, err: ?*c.GError) void {
    const self = instance;
    const d = op.doc;
    defer {
        a.free(op.path);
        a.free(op.data);
        if (op.etag) |e| a.free(e);
        a.destroy(op);
        c.g_application_release(u.cast(c.GApplication, self.application));
    }
    d.busy = false;
    if (d.cancellable) |p| c.g_object_unref(p);
    d.cancellable = null;
    if (ok) {
        if (d.path) |p| a.free(p);
        d.path = u.z(op.path);
        if (d.etag) |p| a.free(p);
        d.etag = if (etag != null) u.z(std.mem.span(etag)) else null;
        d.saved_revision = op.revision;
        if (!codec.saveKeepsDirty(op.revision, d.revision)) c.gtk_text_buffer_set_modified(d.buffer, 0);
        self.configure(d);
        self.update();
        self.message("Saved.");
        if (d.close_after_save) {
            d.close_after_save = false;
            if (!d.dirty()) {
                self.remove(d);
            } else {
                self.quitting = false;
                self.message("Saved the earlier revision. Newer edits are still unsaved.");
            }
        }
    } else {
        self.quitting = false;
        d.close_after_save = false;
        if (err) |e| {
            if (e.domain == c.g_io_error_quark() and e.code == c.G_IO_ERROR_WRONG_ETAG) {
                self.message("File changed on disk. Save again to review the conflict; your edits are preserved.");
                self.ask(.conflict, d, "This file changed elsewhere", "Your edits are preserved. Save a copy, reload the file, or explicitly overwrite the version on disk.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Reload", .id = 1 }, .{ .text = "Save As…", .id = 2 }, .{ .text = "Overwrite", .id = 3 } });
            } else self.message(std.mem.span(e.message));
            c.g_error_free(e);
        }
        self.update();
    }
}
fn chosenOpen(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    defer c.g_application_release(u.cast(c.GApplication, self.application));
    var err: ?*c.GError = null;
    const files = c.gtk_file_dialog_open_multiple_finish(u.cast(c.GtkFileDialog, source.?), result, &err);
    if (files) |list| {
        defer c.g_object_unref(list);
        const n = c.g_list_model_get_n_items(list);
        for (0..n) |i| {
            const file = c.g_list_model_get_item(list, @intCast(i)).?;
            defer c.g_object_unref(file);
            const path = c.g_file_get_path(u.cast(c.GFile, file));
            if (path != null) {
                self.openPath(std.mem.span(path));
                c.g_free(path);
            } else self.message("Only local files are supported.");
        }
    }
    if (err) |e| c.g_error_free(e);
}
fn chosenSave(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = instance;
    const d = u.cast(Document, data.?);
    d.busy = false;
    defer c.g_application_release(u.cast(c.GApplication, self.application));
    var err: ?*c.GError = null;
    const file = c.gtk_file_dialog_save_finish(u.cast(c.GtkFileDialog, source.?), result, &err);
    if (file) |f| {
        defer c.g_object_unref(f);
        const path = c.g_file_get_path(f);
        defer c.g_free(path);
        if (path != null) {
            self.saveTo(d, std.mem.span(path), false, true);
            return;
        }
        self.message("Only local files are supported.");
    }
    if (err) |e| c.g_error_free(e);
    d.close_after_save = false;
    self.quitting = false;
    self.update();
}
fn dialogResponse(dialog: ?*c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const kind = self.dialog_kind;
    const doc = self.dialog_doc;
    const line = if (kind == .goto) c.gtk_spin_button_get_value_as_int(u.cast(c.GtkSpinButton, self.goto_input.?)) else 1;
    self.dialog = null;
    self.dialog_doc = null;
    c.gtk_window_destroy(u.cast(c.GtkWindow, dialog.?));
    switch (kind) {
        .close => {
            const d = doc.?;
            if (response == 1) self.remove(d) else if (response == 2) {
                d.close_after_save = true;
                self.save(d, false, false);
            } else self.quitting = false;
        },
        .mixed => {
            if (response == 1 or response == 2) {
                doc.?.newline = if (response == 1) .lf else .crlf;
                self.save(doc.?, doc.?.normalize_save_as, false);
            } else {
                doc.?.close_after_save = false;
                self.quitting = false;
            }
        },
        .conflict => {
            if (response == 1) self.ask(.reload, doc, "Discard unsaved edits?", "Reloading replaces your current edits with the version on disk.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Discard and reload", .id = 1 } }) else if (response == 2) self.save(doc.?, true, false) else if (response == 3) self.save(doc.?, false, true);
        },
        .reload => {
            if (response == 1) self.load(doc.?, true);
        },
        .large => {
            const d = doc.?;
            if (response == 1) acceptLoaded(self, d, true) else {
                if (d.pending) |p| a.free(p.text);
                d.pending = null;
                if (d.pending_etag) |p| a.free(p);
                d.pending_etag = null;
                if (c.gtk_text_buffer_get_char_count(d.buffer) == 0) {
                    if (d.path) |p| a.free(p);
                    d.path = null;
                }
                self.update();
            }
        },
        .preferences => {
            if (!self.settings.save()) self.message("Could not save preferences. Check the configuration directory permissions.");
        },
        .goto => {
            if (response == 1) {
                var iter: c.GtkTextIter = undefined;
                _ = c.gtk_text_buffer_get_iter_at_line(doc.?.buffer, &iter, line - 1);
                c.gtk_text_buffer_place_cursor(doc.?.buffer, &iter);
                _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, doc.?.view), &iter, 0.1, 0, 0, 0);
                _ = c.gtk_widget_grab_focus(doc.?.view);
            }
        },
    }
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, data.?);
    const tick_start = c.g_get_monotonic_time();
    while (self.worker.take()) |job| {
        defer job.destroy();
        if (job.kind == .list) {
            self.enumerated = true;
            for (job.words.items) |word| self.languages.append(a, u.z(word)) catch unreachable;
            var chosen: []const u8 = "";
            const saved_lang = std.mem.sliceTo(&self.settings.language, 0);
            for (self.languages.items) |lang| {
                if (std.mem.eql(u8, lang, saved_lang)) chosen = lang;
            }
            if (chosen.len == 0) {
                const locales = c.g_get_language_names();
                var i: usize = 0;
                while (locales[i] != null and chosen.len == 0) : (i += 1) {
                    const locale = std.mem.span(locales[i]);
                    for (self.languages.items) |lang| {
                        if (std.mem.eql(u8, locale, lang) or (std.mem.indexOfScalar(u8, locale, '_') == null and std.mem.startsWith(u8, lang, locale))) {
                            chosen = lang;
                            break;
                        }
                    }
                }
            }
            self.settings.setLanguage(chosen);
            self.dictionary = chosen.len > 0;
            self.update();
            continue;
        }
        if (job.kind == .add) {
            if (job.failed or !job.available) self.message("The personal dictionary could not be updated.") else {
                self.message("Added to the personal dictionary shared by Enchant applications.");
                self.resetSpelling();
            }
            continue;
        }
        const d = self.find(job.id) orelse continue;
        if (job.kind == .check) d.inflight = false;
        if (job.revision != d.revision or job.generation != self.generation) continue;
        self.dictionary = job.available;
        if (job.kind == .suggest) {
            self.showSuggestions(d, job);
            continue;
        }
        if (job.kind == .check) {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, job.offset);
            c.gtk_text_buffer_get_iter_at_offset(d.buffer, &end, job.end);
            c.gtk_text_buffer_remove_tag(d.buffer, d.tag, &start, &end);
            if (job.available and !job.failed and self.spellingEnabled(d)) {
                for (job.ranges.items) |range| {
                    c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, range.start);
                    c.gtk_text_buffer_get_iter_at_offset(d.buffer, &end, range.end);
                    const word = c.gtk_text_buffer_get_text(d.buffer, &start, &end, 1);
                    defer c.g_free(word);
                    if (!d.ignored.contains(std.mem.span(word))) c.gtk_text_buffer_apply_tag(d.buffer, d.tag, &start, &end);
                }
            }
            if (job.priority) {
                d.priority_start = job.offset;
                d.priority_end = job.end;
                d.priority_revision = d.revision;
            } else d.check_from = job.end;
            if (job.failed) self.message("The spelling provider reported an error. Editing remains available.");
        }
    }
    const now = c.g_get_monotonic_time();
    for (self.docs.items) |d| {
        if (d.pending != null and self.dialog == null) {
            self.focus(d);
            self.ask(.large, d, "Open in large-file mode?", "This file exceeds 10 MiB. Automatic spelling and syntax highlighting will be disabled.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Open large file", .id = 1 } });
        }
        const count = c.gtk_text_buffer_get_char_count(d.buffer);
        if (!self.enumerated or !self.dictionary or !self.spellingEnabled(d) or d.inflight or d.loading or now < d.due or d.check_from >= count) continue;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        var offset = d.check_from;
        var priority = false;
        if (self.active() == d) {
            var visible: c.GdkRectangle = undefined;
            c.gtk_text_view_get_visible_rect(u.cast(c.GtkTextView, d.view), &visible);
            var first: c.GtkTextIter = undefined;
            var last: c.GtkTextIter = undefined;
            _ = c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, d.view), &first, visible.x, visible.y);
            _ = c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, d.view), &last, visible.x + visible.width, visible.y + visible.height);
            const first_offset = c.gtk_text_iter_get_offset(&first);
            const last_offset = c.gtk_text_iter_get_offset(&last);
            if (first_offset > d.check_from and (d.priority_revision != d.revision or first_offset < d.priority_start or last_offset > d.priority_end)) {
                if (c.gtk_text_iter_inside_word(&first) != 0) _ = c.gtk_text_iter_backward_word_start(&first);
                offset = c.gtk_text_iter_get_offset(&first);
                priority = true;
            }
        }
        c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, offset);
        c.gtk_text_buffer_get_iter_at_offset(d.buffer, &end, @min(count, offset + 8192));
        // Include the remainder of an ordinary word without copying an unbounded line.
        var extra: u32 = 0;
        while (c.gtk_text_iter_inside_word(&end) != 0 and extra < 128 and c.gtk_text_iter_forward_char(&end) != 0) : (extra += 1) {}
        const text = c.gtk_text_buffer_get_text(d.buffer, &start, &end, 1);
        defer c.g_free(text);
        const job = spell.Job.create(.check, std.mem.span(text), std.mem.sliceTo(&self.settings.language, 0));
        job.id = d.id;
        job.revision = d.revision;
        job.generation = self.generation;
        job.offset = offset;
        job.priority = priority;
        job.end = c.gtk_text_iter_get_offset(&end);
        d.inflight = true;
        self.worker.submit(job);
    }
    self.update();
    self.max_spell_tick_us = @max(self.max_spell_tick_us, c.g_get_monotonic_time() - tick_start);
    return 1;
}
fn dirtyRange(d: *Document, at: *const c.GtkTextIter) void {
    var start = at.*;
    c.gtk_text_iter_set_line_offset(&start, 0);
    _ = c.gtk_text_iter_backward_char(&start);
    d.check_from = @min(d.check_from, c.gtk_text_iter_get_offset(&start));
    d.due = c.g_get_monotonic_time() + 250000;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_end_iter(d.buffer, &end);
    c.gtk_text_buffer_remove_tag(d.buffer, d.tag, &start, &end);
}
fn onInsert(_: ?*c.GtkTextBuffer, at: ?*c.GtkTextIter, _: [*c]const u8, _: c_int, data: ?*anyopaque) callconv(.c) void {
    dirtyRange(u.cast(Document, data.?), at.?);
}
fn onDelete(_: ?*c.GtkTextBuffer, start: ?*c.GtkTextIter, _: ?*c.GtkTextIter, data: ?*anyopaque) callconv(.c) void {
    dirtyRange(u.cast(Document, data.?), start.?);
}
fn onChanged(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    d.revision += 1;
    d.due = c.g_get_monotonic_time() + 250000;
    instance.hidePopover();
    instance.update();
}
fn onModified(_: ?*c.GtkTextBuffer, _: ?*anyopaque) callconv(.c) void {
    instance.update();
}
fn onMark(_: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, _: ?*c.GtkTextMark, _: ?*anyopaque) callconv(.c) void {
    instance.update();
}
fn onSwitch(_: ?*c.GtkNotebook, _: ?*c.GtkWidget, _: c_uint, _: ?*anyopaque) callconv(.c) void {
    instance.hidePopover();
    instance.update();
}
fn onCloseWindow(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
    u.cast(App, data.?).quit();
    return 1;
}
fn onCloseTab(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    instance.closeDocument(u.cast(Document, data.?));
}
fn onNew(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    _ = u.cast(App, data.?).newDocument();
}
fn onOpen(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).chooseOpen();
}
fn onSave(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    if (self.active()) |d| self.save(d, false, false);
}
fn onSearch(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).showSearch(true);
}
fn onHideSearch(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).showSearch(false);
}
fn onNext(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).findMatch(false);
}
fn onPrev(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).findMatch(true);
}
fn onReplace(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).replace(false);
}
fn onReplaceAll(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).replace(true);
}
fn onSpelling(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    if (self.active()) |d| self.requestSuggestions(d);
}
fn onPreferences(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).preferences();
}
fn onQuery(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const text = u.z(u.entryText(self.query));
    defer a.free(text);
    for (self.docs.items) |d| c.gtk_source_search_settings_set_search_text(d.search_settings, text);
    self.update();
}
fn onContext(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    var bx: c_int = 0;
    var by: c_int = 0;
    c.gtk_text_view_window_to_buffer_coords(u.cast(c.GtkTextView, d.view), c.GTK_TEXT_WINDOW_WIDGET, @intFromFloat(x), @intFromFloat(y), &bx, &by);
    var iter: c.GtkTextIter = undefined;
    if (c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, d.view), &iter, bx, by) != 0 and c.gtk_text_iter_has_tag(&iter, d.tag) != 0) {
        c.gtk_text_buffer_place_cursor(d.buffer, &iter);
        _ = c.gtk_gesture_set_state(u.cast(c.GtkGesture, gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
        instance.requestSuggestions(d);
    }
}
fn prefTheme(widget: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.theme = c.gtk_combo_box_get_active(widget);
    self.applySettings();
}
fn prefFont(widget: ?*c.GtkSpinButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.font = c.gtk_spin_button_get_value_as_int(widget);
    self.applySettings();
}
fn prefIndent(widget: ?*c.GtkSpinButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.indent = c.gtk_spin_button_get_value_as_int(widget);
    self.applySettings();
}
fn prefToggle(widget: ?*c.GtkCheckButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const key: [*:0]const u8 = @ptrCast(c.g_object_get_data(u.cast(c.GObject, widget.?), "coral-pref").?);
    inline for (.{ "lines", "wrap", "spaces", "spelling" }) |name| {
        if (std.mem.eql(u8, std.mem.span(key), name)) @field(self.settings, name) = c.gtk_check_button_get_active(widget) != 0;
    }
    self.applySettings();
    self.resetSpelling();
}
fn prefLanguage(widget: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const id = c.gtk_combo_box_get_active_id(widget);
    if (id != null) {
        self.settings.setLanguage(std.mem.span(id));
        self.dictionary = std.mem.span(id).len > 0;
        self.resetSpelling();
    }
}
fn prefDocument(widget: ?*c.GtkCheckButton, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    d.spell_override = c.gtk_check_button_get_active(widget) != 0;
    instance.resetSpelling();
}
fn freeString(data: ?*anyopaque) callconv(.c) void {
    const p: [*:0]u8 = @ptrCast(data.?);
    a.free(std.mem.span(p));
}
fn validMenu(self: *App) ?*Document {
    const d = self.dialog_doc orelse return null;
    if (self.find(d.id) == null or d.revision != self.menu_revision) {
        self.hidePopover();
        return null;
    }
    return d;
}
fn correctWord(button: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const d = validMenu(self) orelse return;
    const raw: [*:0]const u8 = @ptrCast(c.g_object_get_data(u.cast(c.GObject, button.?), "correction").?);
    const word = u.z(std.mem.span(raw));
    defer a.free(word);
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, self.menu_start);
    c.gtk_text_buffer_get_iter_at_offset(d.buffer, &end, self.menu_end);
    self.hidePopover();
    c.gtk_text_buffer_begin_user_action(d.buffer);
    c.gtk_text_buffer_delete(d.buffer, &start, &end);
    c.gtk_text_buffer_insert(d.buffer, &start, word, @intCast(word.len));
    c.gtk_text_buffer_end_user_action(d.buffer);
}
fn ignoreWord(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const d = validMenu(self) orelse return;
    const word = self.menu_word orelse return;
    if (!d.ignored.contains(word)) d.ignored.put(a, u.z(word), {}) catch unreachable;
    self.hidePopover();
    self.invalidate(d);
}
fn addWord(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    _ = validMenu(self) orelse return;
    self.worker.submit(spell.Job.create(.add, self.menu_word.?, std.mem.sliceTo(&self.settings.language, 0)));
    self.hidePopover();
}
fn editAction(button: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const d = self.active() orelse return;
    const action: [*:0]const u8 = @ptrCast(c.g_object_get_data(u.cast(c.GObject, button.?), "edit-action").?);
    _ = c.gtk_widget_activate_action_variant(d.view, action, null);
    self.hidePopover();
}
fn onAction(action: ?*c.GSimpleAction, _: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const name = std.mem.span(c.g_action_get_name(u.cast(c.GAction, action.?)));
    if (std.mem.eql(u8, name, "new")) {
        _ = self.newDocument();
    } else if (std.mem.eql(u8, name, "open")) self.chooseOpen() else if (std.mem.eql(u8, name, "save")) {
        if (self.active()) |d| self.save(d, false, false);
    } else if (std.mem.eql(u8, name, "save-as")) {
        if (self.active()) |d| self.save(d, true, false);
    } else if (std.mem.eql(u8, name, "find")) self.showSearch(true) else if (std.mem.eql(u8, name, "goto")) self.gotoLine() else if (std.mem.eql(u8, name, "spelling")) {
        if (self.active()) |d| self.requestSuggestions(d);
    } else if (std.mem.eql(u8, name, "preferences")) self.preferences() else if (std.mem.eql(u8, name, "close")) {
        if (self.active()) |d| self.closeDocument(d);
    } else if (std.mem.eql(u8, name, "quit")) self.quit() else if (std.mem.eql(u8, name, "about")) c.gtk_show_about_dialog(u.cast(c.GtkWindow, self.window), "program-name", @as([*:0]const u8, "Coral"), "version", @as([*:0]const u8, "0.1.0"), "comments", @as([*:0]const u8, "A focused Zig and GTK4 text editor with offline spelling."), @as(?*anyopaque, null));
}
fn onKey(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, data.?);
    const ctrl = state & c.GDK_CONTROL_MASK != 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    if (test_hooks and key == c.GDK_KEY_F11) {
        testCommand(self);
        return 1;
    }
    if (test_hooks and key == c.GDK_KEY_F12) {
        self.probe();
        return 1;
    }
    if (test_hooks and key == c.GDK_KEY_F8 and self.dialog != null) {
        c.gtk_dialog_response(u.cast(c.GtkDialog, self.dialog.?), if (shift) 2 else 1);
        return 1;
    }
    if (test_hooks and key == c.GDK_KEY_F9) {
        self.replace(true);
        return 1;
    }
    if (test_hooks and key == c.GDK_KEY_F7) {
        if (self.active()) |d| self.requestSuggestions(d);
        return 1;
    }
    if (self.dialog != null) return 0;
    if (key == c.GDK_KEY_Escape) {
        if (self.popover != null) {
            self.hidePopover();
            return 1;
        }
        self.showSearch(false);
        self.message("");
        return 1;
    }
    if (ctrl) {
        switch (key) {
            c.GDK_KEY_n => {
                _ = self.newDocument();
            },
            c.GDK_KEY_o => self.chooseOpen(),
            c.GDK_KEY_s, c.GDK_KEY_S => {
                if (self.active()) |d| self.save(d, shift, false);
            },
            c.GDK_KEY_w => {
                if (self.active()) |d| self.closeDocument(d);
            },
            c.GDK_KEY_q => self.quit(),
            c.GDK_KEY_f, c.GDK_KEY_h => self.showSearch(true),
            c.GDK_KEY_g => self.gotoLine(),
            c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => {
                const current = c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, self.notebook));
                const count = c.gtk_notebook_get_n_pages(u.cast(c.GtkNotebook, self.notebook));
                if (count > 0) c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, self.notebook), @mod(current + if (shift) @as(c_int, -1) else 1, count));
                if (self.active()) |d| _ = c.gtk_widget_grab_focus(d.view);
            },
            c.GDK_KEY_plus, c.GDK_KEY_equal, c.GDK_KEY_minus, c.GDK_KEY_0 => {
                self.settings.font = if (key == c.GDK_KEY_0) 14 else std.math.clamp(self.settings.font + if (key == c.GDK_KEY_minus) @as(c_int, -1) else 1, 8, 32);
                self.applySettings();
                _ = self.settings.save();
            },
            c.GDK_KEY_z, c.GDK_KEY_Z, c.GDK_KEY_y => {
                if (self.active()) |d| {
                    if (c.gtk_window_get_focus(u.cast(c.GtkWindow, self.window)) != d.view) return 0;
                    if (shift or key == c.GDK_KEY_y) {
                        if (c.gtk_text_buffer_get_can_redo(d.buffer) != 0) c.gtk_text_buffer_redo(d.buffer);
                    } else if (c.gtk_text_buffer_get_can_undo(d.buffer) != 0) c.gtk_text_buffer_undo(d.buffer);
                }
            },
            c.GDK_KEY_comma => self.preferences(),
            else => return 0,
        }
        return 1;
    }
    if (key == c.GDK_KEY_F3) {
        self.findMatch(shift);
        return 1;
    }
    if (key == c.GDK_KEY_F10 and shift) {
        if (self.active()) |d| self.requestSuggestions(d);
        return 1;
    }
    return 0;
}
fn testKeys(self: *App, widget: W) void {
    if (!test_hooks) return;
    const keys = c.gtk_event_controller_key_new().?;
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    u.connect(keys, "key-pressed", &onKey, self);
    c.gtk_widget_add_controller(widget, keys);
}
fn testCommand(self: *App) void {
    if (!test_hooks) return;
    const path = c.g_getenv("CORAL_TEST_COMMAND");
    if (path == null) return;
    const file = c.g_key_file_new().?;
    defer c.g_key_file_unref(file);
    if (c.g_key_file_load_from_file(file, path, 0, null) == 0) return;
    const raw = c.g_key_file_get_string(file, "Test", "action", null);
    if (raw == null) return;
    defer c.g_free(raw);
    const action = std.mem.span(raw);
    const value = c.g_key_file_get_string(file, "Test", "value", null);
    defer c.g_free(value);
    const d = self.active();
    if (std.mem.eql(u8, action, "respond")) {
        if (self.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.g_key_file_get_integer(file, "Test", "response", null));
    } else if (std.mem.eql(u8, action, "save-path")) {
        if (d) |doc| {
            if (value != null) self.saveTo(doc, std.mem.span(value), false, true);
        }
    } else if (std.mem.eql(u8, action, "save-race")) {
        if (d) |doc| {
            self.save(doc, false, false);
            c.gtk_text_buffer_insert_at_cursor(doc.buffer, " plus", 5);
        }
    } else if (std.mem.eql(u8, action, "save-cancel")) {
        if (d) |doc| {
            self.save(doc, false, false);
            if (doc.cancellable) |cancel| c.g_cancellable_cancel(cancel);
        }
    } else if (std.mem.eql(u8, action, "open")) {
        if (value != null) self.openPath(std.mem.span(value));
    } else if (std.mem.eql(u8, action, "correct")) {
        if (self.popover) |pop| {
            const box = c.gtk_popover_get_child(u.cast(c.GtkPopover, pop));
            const title = c.gtk_widget_get_first_child(box);
            if (c.gtk_widget_get_next_sibling(title)) |button| correctWord(u.cast(c.GtkButton, button), self);
        }
    } else if (std.mem.eql(u8, action, "ignore")) ignoreWord(null, self) else if (std.mem.eql(u8, action, "add")) addWord(null, self) else if (std.mem.eql(u8, action, "preferences")) self.preferences() else if (std.mem.eql(u8, action, "settings")) {
        self.settings.theme = c.g_key_file_get_integer(file, "Test", "theme", null);
        self.settings.font = std.math.clamp(c.g_key_file_get_integer(file, "Test", "font", null), 8, 32);
        self.applySettings();
        _ = self.settings.save();
    } else if (std.mem.eql(u8, action, "language")) {
        if (value != null) {
            self.settings.setLanguage(std.mem.span(value));
            self.dictionary = std.mem.span(value).len > 0;
            self.resetSpelling();
            _ = self.settings.save();
        }
    } else if (std.mem.eql(u8, action, "replace-all")) {
        if (value != null) c.gtk_editable_set_text(u.cast(c.GtkEditable, self.replacement), value);
        self.replace(true);
    } else if (std.mem.eql(u8, action, "cancel-io")) {
        if (d) |doc| if (doc.cancellable) |cancel| c.g_cancellable_cancel(cancel);
    }
    c.g_print("CORAL_COMMAND_DONE\n");
}

fn popoverClosed(pop: ?*c.GtkPopover, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    if (self.popover == u.cast(c.GtkWidget, pop.?)) {
        self.popover = null;
        c.gtk_widget_unparent(u.cast(c.GtkWidget, pop.?));
    }
}
