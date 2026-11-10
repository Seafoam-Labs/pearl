const chooser = @import("file_chooser");
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const W = u.W;
const Document = @import("document.zig").Document;
const DocumentRegistry = @import("editor/registry.zig").DocumentRegistry;
const EditorView = @import("editor/view.zig").EditorView;
const transactions = @import("editor/transactions.zig");
const History = @import("editor/history.zig").History;
const group_model = @import("editor_groups.zig");
const workspace_identity = @import("workspace/identity.zig");
const excerpt_model = @import("editor/excerpt.zig");
const ExcerptEditor = @import("editor/excerpt_editor.zig").Editor;
const ExcerptPane = struct {
    id: u64,
    app: *App,
    document: *Document,
    editor: *ExcerptEditor,
    tab: W,
    label: W,
    close: W,
    search: *c.GtkSourceSearchContext,
    spelling_tag: *c.GtkTextTag,
    spelling_dirty: bool = true,
    context_controller: ?*c.GtkEventController = null,
};
const WorkspaceController = @import("workspace/controller.zig").Controller;
const WorkspaceSearch = @import("workspace/search_controller.zig").Controller;
const WorkspacePolicy = @import("workspace/policy_controller.zig").Controller;
const WorkspaceSession = @import("workspace/session_controller.zig").Controller;
const WorkspaceOperations = @import("workspace/operations_controller.zig").Controller;
const safe_settings = @import("workspace/settings.zig");
// c.h imports the manager but not the language accessor header. Keep this
// narrow existing-library ABI declaration local to the native integration.
extern "gtksourceview-5" fn gtk_source_language_get_id(language: *c.GtkSourceLanguage) [*:0]const u8;
const load_file = @import("platform/load_file.zig");
const commands = @import("workbench/commands.zig");
const Palette = @import("workbench/palette.zig").Palette;
const chrome_ui = @import("workbench/chrome.zig");
const dock_ui = @import("workbench/dock.zig");
const dock_layout = @import("workbench/layout.zig");
const codec = @import("platform/codec.zig");
const spell = @import("spelling/checker.zig");
const Settings = @import("platform/settings.zig").Settings;
const diagnostics = @import("diagnostics");
const file_error = @import("platform/file_error.zig");
const test_hooks = @import("build_options").test_hooks;
const log = std.log.scoped(.platform);

pub const App = struct {
    application: *c.GtkApplication,
    manager: ?*@import("application.zig").Manager = null,
    window_id: u64 = 0,
    scope_class: [:0]const u8 = "",
    holds: usize = 0,
    workspace: workspace_identity.Scope,
    // Document lifecycle scope above is independent of the browser model's scope.
    browser: WorkspaceController = undefined,
    workspace_search: WorkspaceSearch = undefined,
    workspace_policy: WorkspacePolicy = undefined,
    session: WorkspaceSession = undefined,
    workspace_operations: WorkspaceOperations = undefined,
    workspace_roots: @import("workspace/roots_controller.zig").Controller = undefined,
    projects: @import("workspace/project_controller.zig").Controller = undefined,
    recovery_claimed: bool = false,
    close_resolved: std.ArrayList(u64) = .empty,
    close_focus: ?u64 = null,
    project_close_committed: bool = false,
    project_close_waiting: bool = false,
    close_without_session: bool = false,
    close_guard: ?[]CloseDocument = null,
    final_close_guard: ?[]CloseDocument = null,
    file_open_choosers: usize = 0,
    pending_file_loads: usize = 0,
    window: W,
    dock: dock_ui.Controller = undefined,
    /// Alias of the active group's notebook, retained for tab cycling.
    notebook: W,
    groups: group_model.Groups,
    active_page: ?W = null,
    excerpts: std.ArrayList(*ExcerptPane) = .empty,
    next_excerpt_id: u64 = 1 << 63,
    history: History = History.init(a, .{}),
    closing_group: ?u64 = null,
    /// GTK-thread callback; snapshots are coherent here. Must not mutate/reenter App.
    recovery_context: ?*anyopaque = null,
    recovery_checkpoint: ?*const fn (?*anyopaque, *App) void = null,
    recovery_suspended: bool = false,
    checkpoint_idle: c_uint = 0,
    checkpoint_running: bool = false,
    test_checkpoint_count: u64 = 0,
    test_save_delay_ms: c_uint = 0,
    new_button: W,
    search_button: W,
    searchbox: W,
    query: W,
    replacement: W,
    matches: W,
    status: W,
    chrome: ?chrome_ui.Chrome = null,
    spell_button: W,
    notice: W,
    documents: DocumentRegistry = DocumentRegistry.init(a),
    views: std.ArrayList(*EditorView) = .empty,
    palette: ?*Palette = null,
    palette_focus: c.GWeakRef = undefined,
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
    appearance: @import("appearance.zig").Appearance = undefined,
    dialog: ?W = null,
    dialog_doc: ?*Document = null,
    popover: ?W = null,
    menu_start: c_int = 0,
    menu_end: c_int = 0,
    menu_revision: u64 = 0,
    suggestion_view: u64 = 0,
    menu_word: ?[:0]u8 = null,
    dialog_kind: DialogKind = .close,
    goto_input: ?W = null,
    pub fn create(application: *c.GtkApplication, settings: Settings, width: c_int, height: c_int, manager: *@import("application.zig").Manager, window_id: u64) *App {
        const self = a.create(App) catch unreachable;

        const window = c.gtk_application_window_new(application).?;
        c.gtk_widget_add_css_class(window, "coral-workbench");
        c.gtk_window_set_title(u.cast(c.GtkWindow, window), @import("i18n").dtr("coral", "Coral"));
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, window), width, height);
        const root = u.box(false, 0);
        c.gtk_window_set_child(u.cast(c.GtkWindow, window), root);
        const header = c.gtk_header_bar_new().?;
        c.gtk_window_set_titlebar(u.cast(c.GtkWindow, window), header);
        const footer = u.box(true, 8);
        c.gtk_widget_add_css_class(footer, "status");
        var chrome = chrome_ui.Chrome.init(header, footer);
        const open = u.icon("document-open-symbolic", @import("i18n").dtr("coral", "Open files · Ctrl+O"));
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), open);
        u.connect(open, "clicked", &onOpen, self);
        chrome.open_button = open;
        const new = u.icon("list-add-symbolic", @import("i18n").dtr("coral", "New document · Ctrl+N"));
        c.gtk_header_bar_pack_start(u.cast(c.GtkHeaderBar, header), new);
        u.connect(new, "clicked", &onNew, self);
        const menu = c.gtk_menu_button_new().?;
        c.gtk_menu_button_set_icon_name(u.cast(c.GtkMenuButton, menu), "open-menu-symbolic");
        c.gtk_widget_set_tooltip_text(menu, @import("i18n").dtr("coral", "Editor menu"));
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), menu);
        const search = u.icon("edit-find-symbolic", @import("i18n").dtr("coral", "Find and replace · Ctrl+F"));
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), search);
        u.connect(search, "clicked", &onSearch, self);
        const save_button = u.icon("document-save-symbolic", @import("i18n").dtr("coral", "Save · Ctrl+S"));
        c.gtk_header_bar_pack_end(u.cast(c.GtkHeaderBar, header), save_button);
        u.connect(save_button, "clicked", &onSave, self);
        chrome.save_button = save_button;
        const model = c.g_menu_new().?;
        defer c.g_object_unref(model);
        chrome_ui.populateMenu(model);
        inline for (.{ open, new, search, save_button, menu }) |button| c.gtk_widget_add_css_class(button, "flat");
        c.gtk_menu_button_set_menu_model(u.cast(c.GtkMenuButton, menu), u.cast(c.GMenuModel, model));
        var groups = group_model.Groups.init();
        const first_group = groups.add() catch @panic("Could not create editor group");
        const notebook = first_group.notebook;
        dock_ui.wrapEditorGroup(groups.root, first_group.chrome.root);
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
        const prev = u.icon("go-up-symbolic", @import("i18n").dtr("coral", "Previous match · Shift+F3"));
        u.append(row, prev);
        u.connect(prev, "clicked", &onPrev, self);
        const next = u.icon("go-down-symbolic", @import("i18n").dtr("coral", "Next match · F3"));
        u.append(row, next);
        u.connect(next, "clicked", &onNext, self);
        const hide = u.icon("window-close-symbolic", @import("i18n").dtr("coral", "Close search · Escape"));
        u.append(row, hide);
        u.connect(hide, "clicked", &onHideSearch, self);
        const replace_row = u.box(true, 6);
        u.append(searchbox, replace_row);
        const replacement = c.gtk_entry_new().?;
        c.gtk_entry_set_placeholder_text(u.cast(c.GtkEntry, replacement), @import("i18n").dtr("coral", "Replace with"));
        c.gtk_widget_set_hexpand(replacement, 1);
        c.gtk_widget_set_size_request(replacement, 80, -1);
        u.append(replace_row, replacement);
        const replace_button = u.button(@import("i18n").dtr("coral", "Replace"));
        u.append(replace_row, replace_button);
        u.connect(replace_button, "clicked", &onReplace, self);
        const all = u.button(@import("i18n").dtr("coral", "Replace all"));
        u.append(replace_row, all);
        u.connect(all, "clicked", &onReplaceAll, self);
        u.append(root, searchbox);
        c.gtk_widget_set_visible(searchbox, 0);
        const notice = u.label("");
        c.gtk_widget_add_css_class(notice, "notice");
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, notice), 1);
        u.append(root, notice);
        c.gtk_widget_set_visible(notice, 0);
        const dock = dock_ui.Controller.init(groups.root);
        u.append(root, dock.root);
        const status = u.label("");
        c.gtk_widget_add_css_class(status, "status-document");
        c.gtk_label_set_xalign(u.cast(c.GtkLabel, status), 1);
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, status), c.PANGO_ELLIPSIZE_END);
        u.append(footer, status);
        const spell_button = u.button(@import("i18n").dtr("coral", "Checking dictionaries…"));
        c.gtk_widget_add_css_class(spell_button, "flat");
        u.append(footer, spell_button);
        u.connect(spell_button, "clicked", &onSpelling, self);
        u.append(root, footer);
        self.* = .{ .application = application, .workspace = .init(), .window = window, .notebook = notebook, .groups = groups, .new_button = new, .search_button = search, .searchbox = searchbox, .query = query, .replacement = replacement, .matches = matches, .status = status, .spell_button = spell_button, .notice = notice, .settings = settings, .worker = spell.Worker.start(), .css = c.gtk_css_provider_new().?, .font_css = c.gtk_css_provider_new().? };
        self.chrome = chrome;
        self.manager = manager;
        self.window_id = window_id;
        self.scope_class = u.fmt("coral-window-{d}", .{window_id});
        _ = c.g_object_ref(window); // Keep the widget tree rooted until all callbacks drain.
        self.dock = dock;
        self.workspace_search = WorkspaceSearch.init(self, self.dock.search_slot);
        self.workspace_search.present = &presentWorkspaceSearch;
        self.workspace_search.dismiss = &dismissWorkspaceSearch;
        self.workspace_search.attach();
        // Dock slots own visibility, including a restored search dock with no
        // query yet. Restoring presentation never starts a worker or takes focus.
        self.workspace_search.mode = .text;
        self.workspace_search.view.setMode(.text);
        c.gtk_widget_set_visible(self.workspace_search.view.panel, 1);
        self.browser = WorkspaceController.init(self, self.dock.explorer_slot);
        self.browser.attach();
        self.dock.attach();
        self.workspace_policy = WorkspacePolicy.init(self);
        self.session = .{ .app = self };
        self.workspace_operations = .init(self);
        self.workspace_roots = .init(self);
        self.projects = .init(self);
        c.g_weak_ref_init(&self.palette_focus, null);
        c.gtk_css_provider_load_from_string(self.css, @embedFile("style"));
        c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.css), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.font_css), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        self.appearance = .{ .context = self, .changed = appearanceChanged, .scope = self.scope_class };
        self.appearance.setMode(@import("appearance.zig").modeFrom(settings.theme));
        c.gtk_widget_add_css_class(window, "coral");
        u.connect(window, "close-request", &onCloseWindow, self);
        u.connect(notebook, "switch-page", &onSwitch, self);
        u.connect(notebook, "page-reordered", &onPageReordered, self);
        u.connect(query, "search-changed", &onQuery, self);
        u.connect(query, "activate", &onNext, self);
        u.connect(query, "stop-search", &onStopSearch, self);
        const shortcuts = c.gtk_event_controller_key_new().?;
        c.gtk_event_controller_set_propagation_phase(shortcuts, c.GTK_PHASE_CAPTURE);
        u.connect(shortcuts, "key-pressed", &onShortcut, self);
        c.gtk_widget_add_controller(window, shortcuts);
        const keys = c.gtk_event_controller_key_new().?;
        // Only explicit workbench shortcuts are captured. Text editing, IME
        // composition and widget-local keys get first refusal before fallback.
        c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_BUBBLE);
        u.connect(keys, "key-pressed", &onKey, self);
        c.gtk_widget_add_controller(window, keys);
        for (commands.entries) |entry| {
            const action = c.g_simple_action_new(entry.action, null).?;
            u.connect(action, "activate", &onAction, self);
            c.g_action_map_add_action(u.cast(c.GActionMap, window), u.cast(c.GAction, action));
            c.g_object_unref(action);
        }
        self.applySettings();
        // Start compact before the first allocation, including a 390px launch.
        self.update();
        self.timer = c.g_timeout_add(20, &tick, self);
        self.worker.submit(spell.Job.create(.list, "", ""));
        c.gtk_window_present(u.cast(c.GtkWindow, window));

        return self;
    }
    pub fn snapshotDockLayout(self: *App) dock_layout.State {
        return self.dock.snapshot();
    }
    pub fn restoreDockLayout(self: *App, state: dock_layout.State) void {
        self.dock.restore(state);
    }
    pub fn focusEditor(self: *App) void {
        if (self.closing) return;
        if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
    }
    fn focusExplorer(self: *App) void {
        if (self.dock.picking) self.workspace_search.hide();
        self.dock.show(.explorer);
        _ = c.gtk_widget_grab_focus(self.browser.rows);
    }
    fn hidePanel(self: *App, panel: dock_layout.Panel) void {
        if (panel == .search) self.workspace_search.hide() else {
            self.dock.hide(panel);
            self.focusEditor();
        }
    }
    /// GTK-thread ownership. Release never frees inline: the manager reaps on
    /// a later loop turn, after callback stacks and recovery work have drained.
    pub fn hold(self: *App) void {
        self.holds += 1;
        c.g_application_hold(u.cast(c.GApplication, self.application));
    }
    pub fn release(self: *App) void {
        std.debug.assert(self.holds > 0);
        self.holds -= 1;
        c.g_application_release(u.cast(c.GApplication, self.application));
    }
    pub fn deinit(self: *App) void {
        std.debug.assert(self.holds == 0);
        if (self.close_guard) |guard| a.free(guard);
        if (self.final_close_guard) |guard| a.free(guard);
        self.close_resolved.deinit(a);
        if (self.manager != null) {
            self.projects.deinit();
            self.workspace_roots.deinit();
            self.workspace_operations.deinit();
        }
        self.disconnectCallbacks(self.window);
        inline for (.{ self.browser.view, self.workspace_search.view.list }) |view| {
            self.disconnectObject(view.selection);
            self.disconnectObject(c.gtk_list_view_get_factory(u.cast(c.GtkListView, view.widget)).?);
        }
        for (commands.entries) |entry| {
            if (c.g_action_map_lookup_action(u.cast(c.GActionMap, self.window), entry.action)) |action| self.disconnectObject(action);
            c.g_action_map_remove_action(u.cast(c.GActionMap, self.window), entry.action);
        }
        self.dock.shutdown();
        self.session.deinit();
        self.browser.deinit();
        self.workspace_policy.deinit();
        self.workspace_search.deinit();
        self.workspace.close();
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.checkpoint_idle != 0) _ = c.g_source_remove(self.checkpoint_idle);
        self.appearance.deinit();
        self.worker.stop();
        if (self.palette) |palette| palette.close();
        // Async operations retain this exact App until their callbacks are reaped;
        // watcher queries allow tabs/windows to close while that hold is active.
        // Views release their buffer references and callbacks before documents.
        while (self.views.items.len > 0) self.detachView(self.views.items[self.views.items.len - 1]);
        while (self.excerpts.items.len > 0) self.detachExcerpt(self.excerpts.items[self.excerpts.items.len - 1]);
        self.views.deinit(a);
        self.excerpts.deinit(a);
        for (self.groups.items.items) |group| _ = c.g_signal_handlers_disconnect_matched(group.notebook, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        self.groups.deinit();
        self.history.deinit();
        self.documents.deinit();
        c.g_weak_ref_clear(&self.palette_focus);
        for (self.languages.items) |lang| a.free(lang);
        self.languages.deinit(a);
        if (self.menu_word) |word| a.free(word);
        c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.css));
        c.g_object_unref(self.css);
        c.gtk_style_context_remove_provider_for_display(c.gdk_display_get_default(), u.cast(c.GtkStyleProvider, self.font_css));
        c.g_object_unref(self.font_css);
        c.gtk_window_destroy(u.cast(c.GtkWindow, self.window));
        c.g_object_unref(self.window);
        a.free(self.scope_class);
        a.destroy(self);
    }
    pub fn active(self: *App) ?*Document {
        if (self.activeView()) |view| return view.document;
        if (self.activeExcerpt()) |pane| return pane.document;
        return null;
    }
    pub fn activeView(self: *App) ?*EditorView {
        if (self.closing) return null;
        for (self.views.items) |view| if (view.page == self.active_page) return view;
        return null;
    }
    fn activeExcerpt(self: *App) ?*ExcerptPane {
        if (self.closing) return null;
        for (self.excerpts.items) |pane| if (pane.editor.root == self.active_page) return pane;
        return null;
    }
    pub fn activeBuffer(self: *App) ?*c.GtkTextBuffer {
        if (self.activeView()) |view| return view.buffer;
        if (self.activeExcerpt()) |pane| return pane.editor.display;
        return null;
    }
    pub fn activeWidget(self: *App) ?W {
        if (self.activeView()) |view| return view.widget;
        if (self.activeExcerpt()) |pane| return pane.editor.widget;
        return null;
    }
    fn activeSearch(self: *App) ?*c.GtkSourceSearchContext {
        if (self.activeView()) |view| return view.projection.search;
        if (self.activeExcerpt()) |pane| return pane.search;
        return null;
    }
    fn find(self: *App, id: u64) ?*Document {
        return self.documents.get(id);
    }
    pub fn activeViewId(self: *App) ?u64 {
        if (self.activeView()) |view| return view.id;
        if (self.activeExcerpt()) |pane| return pane.id;
        return null;
    }
    fn activeFocusWidget(self: *App) ?W {
        if (self.activeView()) |view| if (view.layout_guard.blocked) return view.layout_guard.button;
        if (self.activeExcerpt()) |pane| if (pane.editor.layout_guard.blocked) return pane.editor.layout_guard.button;
        return self.activeWidget();
    }
    fn scrollActiveTo(self: *App, iter: *c.GtkTextIter) void {
        const guard = if (self.activeView()) |view| view.layout_guard else if (self.activeExcerpt()) |pane| pane.editor.layout_guard else return;
        if (guard.blocked) {
            // Search/go-to can still select canonical text, but must not force
            // the giant detached paragraph through Pango. Offer its location to
            // the bounded-excerpt action instead.
            c.gtk_spin_button_set_value(guard.offset, @floatFromInt(c.gtk_text_iter_get_offset(iter)));
        } else if (self.activeWidget()) |widget| {
            _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, widget), iter, 0.1, 0, 0, 0);
        }
    }
    fn focus(self: *App, d: *Document) void {
        if (self.active() == d) {
            if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
            return;
        }
        for (self.views.items) |view| if (view.document == d) {
            self.focusView(view);
            return;
        };
        for (self.excerpts.items) |pane| if (pane.document == d) {
            self.focusPage(pane.editor.root, pane.editor.widget);
            return;
        };
    }
    pub fn focusView(self: *App, view: *EditorView) void {
        self.focusPage(view.page, view.widget);
    }
    fn focusPage(self: *App, page: W, widget: W) void {
        const group = self.groups.forPage(page) orelse return;
        self.hidePopover();
        self.notebook = group.notebook;
        self.active_page = page;
        c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, self.notebook), c.gtk_notebook_page_num(u.cast(c.GtkNotebook, self.notebook), page));
        _ = c.gtk_widget_grab_focus(self.activeFocusWidget() orelse widget);
        self.update();
        self.scheduleCheckpoint();
    }
    pub fn newDocument(self: *App) *Document {
        std.debug.assert(!self.editingFrozen());
        const d = self.documents.create(self) catch @panic("Could not create document");
        self.observeDocument(d);
        _ = self.addView(d, self.activeGroupId()) catch @panic("Could not create editor view");
        return d;
    }
    fn observeDocument(self: *App, d: *Document) void {
        _ = self;
        const buffer = d.buffer;
        u.connect(buffer, "changed", &onChanged, d);
        u.connect(buffer, "modified-changed", &onModified, d);
        u.connect(buffer, "notify::language", &syntaxChanged, d);
        u.connect(buffer, "apply-tag", &onSpellingTag, d);
        u.connect(buffer, "remove-tag", &onSpellingTag, d);

        u.connect(buffer, "insert-text", &onInsert, d);
        u.connect(buffer, "delete-range", &onDelete, d);
    }
    pub fn addView(self: *App, d: *Document, group_id: u64) !*EditorView {
        if (self.editingFrozen()) return error.Closing;
        const group = self.groups.get(group_id) orelse return error.UnknownGroup;
        const presentation = try EditorView.create(d);
        errdefer presentation.destroy();
        try @import("editor_primary.zig").attach(presentation.widget, presentation.buffer);
        try self.views.append(a, presentation);
        self.observeScroll(presentation.widget, true);
        presentation.focus_context = self;
        presentation.on_focus = &viewFocused;
        presentation.layout_guard.setHandler(presentation, &openGuardedView);
        const view = presentation.widget;
        const page = presentation.page;
        const tab = presentation.tab;
        u.connect(presentation.close_button, "clicked", &onCloseTab, presentation);
        u.connect(presentation.buffer, "mark-set", &onViewMark, presentation);
        const click = c.gtk_gesture_click_new().?;
        c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, click), 3);
        c.gtk_event_controller_set_propagation_phase(u.cast(c.GtkEventController, click), c.GTK_PHASE_CAPTURE);
        u.connect(click, "pressed", &onContext, presentation);
        presentation.context_menu_controller = u.cast(c.GtkEventController, click);
        c.gtk_widget_add_controller(view, presentation.context_menu_controller);
        _ = c.gtk_notebook_append_page(u.cast(c.GtkNotebook, group.notebook), page, tab);
        c.gtk_notebook_set_tab_reorderable(u.cast(c.GtkNotebook, group.notebook), page, 1);
        self.configure(d, false);
        self.focusView(presentation);
        return presentation;
    }
    pub fn activeGroupId(self: *App) u64 {
        for (self.groups.items.items) |group| if (group.notebook == self.notebook) return group.id;
        return self.groups.items.items[0].id;
    }
    pub fn createGroup(self: *App) !u64 {
        if (self.editingFrozen()) return error.Closing;
        const group = try self.groups.add();
        dock_ui.wrapEditorGroup(self.groups.root, group.chrome.root);
        u.connect(group.notebook, "switch-page", &onSwitch, self);
        u.connect(group.notebook, "page-reordered", &onPageReordered, self);
        self.scheduleCheckpoint();
        return group.id;
    }
    pub fn splitGroup(self: *App) !void {
        const d = self.active() orelse return;
        const id = try self.createGroup();
        errdefer self.removeGroup(id);
        _ = try self.addView(d, id);
    }
    fn removeGroup(self: *App, id: u64) void {
        const group = self.groups.get(id) orelse return;
        dock_ui.unwrapEditorGroup(self.groups.root, group.chrome.root);
        self.groups.remove(id);
    }
    pub fn focusGroup(self: *App, id: u64) void {
        const group = self.groups.get(id) orelse return;
        self.notebook = group.notebook;
        self.active_page = c.gtk_notebook_get_nth_page(u.cast(c.GtkNotebook, group.notebook), c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, group.notebook)));
        if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
        self.hidePopover();
        self.update();
        self.scheduleCheckpoint();
    }
    fn cycleGroup(self: *App, back: bool) void {
        for (self.groups.items.items, 0..) |group, index| if (group.notebook == self.notebook) {
            const n = self.groups.items.items.len;
            self.focusGroup(self.groups.items.items[(index + if (back) n - 1 else 1) % n].id);
            return;
        };
    }
    pub fn closeGroup(self: *App) void {
        if (self.editingFrozen() or self.rejectOperationClose()) return;
        if (self.dialog != null or self.closing) return;
        self.closing_group = self.activeGroupId();
        self.continueCloseGroup();
    }
    fn continueCloseGroup(self: *App) void {
        const id = self.closing_group orelse return;
        const group = self.groups.get(id) orelse {
            self.closing_group = null;
            return;
        };
        while (c.gtk_notebook_get_n_pages(u.cast(c.GtkNotebook, group.notebook)) > 0) {
            self.focusGroup(id);
            const d = self.active() orelse return;
            if (self.viewCount(d) == 1) {
                self.closeDocument(d);
                return; // remove() resumes after synchronous close or async approval.
            }
            self.detachActive();
        }
        self.closing_group = null;
        self.repairActive();
        self.update();
        self.scheduleCheckpoint();
    }
    fn viewCount(self: *App, d: *Document) usize {
        var count: usize = 0;
        for (self.views.items) |view| {
            if (view.document == d) count += 1;
        }
        for (self.excerpts.items) |pane| {
            if (pane.document == d) count += 1;
        }
        return count;
    }
    pub fn closeActiveView(self: *App) void {
        if (self.editingFrozen() or self.rejectOperationClose()) return;
        if (self.dialog != null or self.closing or self.quitting) return;
        if (self.manager) |manager| if (manager.quitting) return;
        const d = self.active() orelse return;
        if (self.viewCount(d) == 1) self.closeDocument(d) else {
            self.detachActive();
            self.repairActive();
            self.update();
            self.scheduleCheckpoint();
        }
    }
    fn detachActive(self: *App) void {
        self.hidePopover();
        if (self.activeView()) |view| self.detachView(view) else if (self.activeExcerpt()) |pane| self.detachExcerpt(pane);
    }
    fn unparentPage(self: *App, page: W) void {
        if (self.active_page == page) self.active_page = null;
        if (self.groups.forPage(page)) |group| {
            const notebook = u.cast(c.GtkNotebook, group.notebook);
            c.gtk_notebook_remove_page(notebook, c.gtk_notebook_page_num(notebook, page));
        }
    }
    fn observeScroll(self: *App, widget: W, connect: bool) void {
        const scrollable = u.cast(c.GtkScrollable, widget);
        for ([_]?*c.GtkAdjustment{ c.gtk_scrollable_get_hadjustment(scrollable), c.gtk_scrollable_get_vadjustment(scrollable) }) |optional| if (optional) |adjustment| {
            if (connect) u.connect(adjustment, "value-changed", &scrollChanged, self) else _ = c.g_signal_handlers_disconnect_matched(adjustment, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        };
    }
    fn detachView(self: *App, view: *EditorView) void {
        self.observeScroll(view.widget, false);
        _ = c.g_signal_handlers_disconnect_matched(view.close_button, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, view);
        _ = c.g_signal_handlers_disconnect_matched(view.buffer, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, view);
        if (view.context_menu_controller) |controller| _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, view);
        view.disconnectDocumentCallbacks();
        for (self.views.items, 0..) |item, index| if (item == view) {
            _ = self.views.orderedRemove(index);
            break;
        };
        self.unparentPage(view.page);
        view.destroy();
    }
    fn detachExcerpt(self: *App, pane: *ExcerptPane) void {
        self.observeScroll(pane.editor.widget, false);
        _ = c.g_signal_handlers_disconnect_matched(pane.close, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, pane);
        _ = c.g_signal_handlers_disconnect_matched(pane.editor.display, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, pane);
        if (pane.context_controller) |controller| {
            _ = c.g_signal_handlers_disconnect_matched(controller, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, pane);
            c.gtk_widget_remove_controller(pane.editor.widget, controller);
        }
        // The focus controller is removed before a retained widget can outlive pane.
        const controller = c.g_object_get_data(u.cast(c.GObject, pane.editor.widget), "coral-excerpt-focus");
        if (controller) |p| {
            _ = c.g_signal_handlers_disconnect_matched(p, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, pane);
            c.gtk_widget_remove_controller(pane.editor.widget, u.cast(c.GtkEventController, p));
            c.g_object_set_data(u.cast(c.GObject, pane.editor.widget), "coral-excerpt-focus", null);
        }
        for (self.excerpts.items, 0..) |item, index| if (item == pane) {
            _ = self.excerpts.orderedRemove(index);
            break;
        };
        self.unparentPage(pane.editor.root);
        c.g_object_unref(pane.search);
        pane.editor.destroy();
        c.g_object_unref(pane.tab);
        a.destroy(pane);
    }
    fn repairActive(self: *App) void {
        if (self.closing) return;
        var index: usize = 0;
        while (index < self.groups.items.items.len and self.groups.items.items.len > 1) {
            const group = self.groups.items.items[index];
            if (c.gtk_notebook_get_n_pages(u.cast(c.GtkNotebook, group.notebook)) == 0 and self.closing_group != group.id) {
                if (self.notebook == group.notebook) self.notebook = self.groups.items.items[if (index == 0) 1 else 0].notebook;
                _ = c.g_signal_handlers_disconnect_matched(group.notebook, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
                self.removeGroup(group.id);
            } else index += 1;
        }
        self.active_page = c.gtk_notebook_get_nth_page(u.cast(c.GtkNotebook, self.notebook), c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, self.notebook)));
        if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
    }
    pub fn openExcerpt(self: *App, d: *Document, group_id: u64, range: excerpt_model.Range) !u64 {
        if (self.editingFrozen()) return error.Closing;
        const group = self.groups.get(group_id) orelse return error.UnknownGroup;
        try self.excerpts.ensureUnusedCapacity(a, 1);
        const pane = try a.create(ExcerptPane);
        errdefer a.destroy(pane);
        var excerpt = try excerpt_model.Excerpt.init(a, editTarget(d, d.revision), range, false, .{});
        const header = u.fmt("Excerpt · {s}", .{if (d.path) |path| path else "Untitled"});
        defer a.free(header);
        const editor = ExcerptEditor.create(a, excerpt, header, .{ .context = self, .resolve = &resolveExcerpt, .history = &self.history, .committed = &excerptCommitted, .failed = &excerptFailed }) catch |err| {
            excerpt.deinit();
            return err;
        };
        // The full source path is useful in a tooltip, not as a minimum width
        // for every homogeneous split in the central editor area.
        const source_label = c.gtk_widget_get_first_child(editor.root).?;
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, source_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_tooltip_text(source_label, header);
        @import("editor_primary.zig").attach(editor.widget, editor.display) catch |err| {
            editor.destroy();
            return err;
        };
        const tab = u.box(true, 6);
        c.gtk_widget_add_css_class(tab, "editor-tab");
        _ = c.g_object_ref_sink(tab);
        const label = u.label(@import("i18n").dtr("coral", "Excerpt"));
        c.gtk_label_set_ellipsize(u.cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 36);
        const close = u.icon("window-close-symbolic", @import("i18n").dtr("coral", "Close excerpt"));
        c.gtk_widget_add_css_class(close, "flat");
        u.append(tab, label);
        u.append(tab, close);
        pane.* = .{ .id = self.next_excerpt_id, .app = self, .document = d, .editor = editor, .tab = tab, .label = label, .close = close, .search = c.gtk_source_search_context_new(u.cast(c.GtkSourceBuffer, editor.display), d.search_settings).?, .spelling_tag = c.gtk_text_buffer_create_tag(editor.display, "coral-excerpt-spelling", "underline", @as(c_int, c.PANGO_UNDERLINE_ERROR), @as(?*anyopaque, null)).? };
        self.next_excerpt_id += 1;
        self.excerpts.appendAssumeCapacity(pane);
        editor.layout_guard.setHandler(pane, &openGuardedExcerpt);
        self.observeScroll(editor.widget, true);
        u.connect(close, "clicked", &closeExcerpt, pane);
        u.connect(editor.display, "mark-set", &excerptMark, pane);
        const click = c.gtk_gesture_click_new().?;
        c.gtk_gesture_single_set_button(u.cast(c.GtkGestureSingle, click), 3);
        pane.context_controller = u.cast(c.GtkEventController, click);
        c.gtk_event_controller_set_propagation_phase(pane.context_controller, c.GTK_PHASE_CAPTURE);
        u.connect(click, "pressed", &excerptContext, pane);
        c.gtk_widget_add_controller(editor.widget, pane.context_controller);
        const controller = c.gtk_event_controller_focus_new().?;
        u.connect(controller, "enter", &excerptFocused, pane);
        c.g_object_set_data(u.cast(c.GObject, editor.widget), "coral-excerpt-focus", controller);
        c.gtk_widget_add_controller(editor.widget, controller);
        _ = c.gtk_notebook_append_page(u.cast(c.GtkNotebook, group.notebook), editor.root, tab);
        c.gtk_notebook_set_tab_reorderable(u.cast(c.GtkNotebook, group.notebook), editor.root, 1);
        self.configure(d, false);
        self.focusPage(editor.root, editor.widget);
        return pane.id;
    }
    /// Open a usable long-line window without laying out the complete paragraph.
    /// Offsets are canonical GTK characters; history still edits the full source.
    pub fn openBoundedExcerpt(self: *App, d: *Document, group_id: u64, offset: c_int) !u64 {
        if (offset < 0 or offset > c.gtk_text_buffer_get_char_count(d.buffer)) return error.OutOfBounds;
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const start = excerpt_model.byteAtChar(text, @intCast(offset));
        const end = start + excerpt_model.byteAtChar(text[start..], @import("editor/presentation_policy.zig").excerpt_char_limit);
        return self.openExcerpt(d, group_id, .{ .start = start, .end = end });
    }
    fn openGuardedView(context: ?*anyopaque, offset: c_int) void {
        const view = u.cast(EditorView, context.?);
        const self = u.cast(App, view.focus_context.?);
        self.focusView(view);
        _ = self.openBoundedExcerpt(view.document, self.activeGroupId(), offset) catch |err| self.editFailure(err);
    }
    fn openGuardedExcerpt(context: ?*anyopaque, offset: c_int) void {
        const pane = u.cast(ExcerptPane, context.?);
        const self = pane.app;
        self.focusPage(pane.editor.root, pane.editor.widget);
        _ = self.openBoundedExcerpt(pane.document, self.activeGroupId(), excerptBase(pane) + offset) catch |err| self.editFailure(err);
    }
    fn excerptSelection(self: *App) !void {
        const d = self.active() orelse return;
        const buffer = self.activeBuffer() orelse return;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        if (c.gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == 0) {
            c.gtk_text_buffer_get_iter_at_mark(buffer, &start, c.gtk_text_buffer_get_insert(buffer));
            if (c.gtk_text_iter_get_bytes_in_line(&start) > @import("editor/presentation_policy.zig").paragraph_byte_limit) {
                const base = if (self.activeExcerpt()) |pane| excerptBase(pane) else 0;
                _ = try self.openBoundedExcerpt(d, self.activeGroupId(), base + c.gtk_text_iter_get_offset(&start));
                return;
            }
            c.gtk_text_iter_set_line_offset(&start, 0);
            end = start;
            _ = c.gtk_text_iter_forward_to_line_end(&end);
        }
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const base = if (self.activeExcerpt()) |pane| excerptBase(pane) else 0;
        const range = excerpt_model.Range{ .start = excerpt_model.byteAtChar(text, @intCast(base + c.gtk_text_iter_get_offset(&start))), .end = excerpt_model.byteAtChar(text, @intCast(base + c.gtk_text_iter_get_offset(&end))) };
        _ = try self.openExcerpt(d, self.activeGroupId(), range);
    }
    pub fn performGrouped(self: *App, label: []const u8, changes: []const transactions.Change) !void {
        // External producers cannot introduce a second authority for a registry ID.
        const targets = try a.alloc(transactions.Target, changes.len);
        defer a.free(targets);
        for (changes, targets) |change, *target| {
            const d = self.find(change.target.id) orelse return error.TargetMismatch;
            if (change.target.buffer != d.buffer or change.target.revision != &d.revision) return error.TargetMismatch;
            target.* = editTarget(d, change.target.expected_revision);
        }
        var pending = try self.history.prepare(label, changes);
        defer pending.deinit();
        try self.history.commit(&pending, targets);
        self.scheduleCheckpoint();
        self.update();
    }
    pub fn replayGrouped(self: *App, redo: bool) !void {
        const targets = try a.alloc(transactions.Target, self.documents.entries.items.len);
        defer a.free(targets);
        for (self.documents.entries.items, targets) |d, *target| target.* = editTarget(d, d.revision);
        if (redo) try self.history.redo(targets) else try self.history.undo(targets);
        for (self.excerpts.items) |pane| pane.editor.refresh() catch |err| self.editFailure(err);
        self.scheduleCheckpoint();
        self.update();
    }
    fn undo(self: *App, redo: bool) void {
        if (self.editingFrozen()) return;
        const d = self.active() orelse return;
        if (d.loading or d.pending != null) return;
        const record = if (redo) self.history.redoRecord() else self.history.undoRecord();
        if (record) |r| {
            var current = false;
            var valid = true;
            for (r.entries) |entry| {
                if (entry.id == d.id) current = true;
                const target = self.find(entry.id) orelse {
                    valid = false;
                    break;
                };
                if (target.revision != entry.guard_revision) valid = false;
            }
            if (current and valid) {
                self.replayGrouped(redo) catch |err| self.editFailure(err);
                return;
            }
        }
        if (self.activeExcerpt() != null) {
            self.message("Grouped history is no longer current. Undo newer edits in the source view first.");
            return;
        }
        const view = self.activeView() orelse return;
        view.syncSelectionToDocument();
        const guarded = self.history.replayNative(editTarget(d, d.revision), redo) catch |err| {
            if (err == error.GroupedBoundary) {
                self.message("Reached a protected grouped-history boundary. Earlier canonical typing history is retained, but cannot be replayed independently across this boundary.");
            } else self.editFailure(err);
            return;
        };
        // Only documents never protected by grouped history may use their raw
        // canonical GTK stack: adjacent actions on that stack can merge.
        if (!guarded) {
            if (redo) {
                if (c.gtk_text_buffer_get_can_redo(d.buffer) != 0) c.gtk_text_buffer_redo(d.buffer);
            } else if (c.gtk_text_buffer_get_can_undo(d.buffer) != 0) c.gtk_text_buffer_undo(d.buffer);
        }
        view.syncSelectionFromDocument();
        self.scheduleCheckpoint();
    }
    /// Borrowed canonical documents; valid only until the next App mutation.
    /// Cheap automatic-session change detection: no buffer text extraction.
    pub fn projectFingerprint(self: *App) !u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.snapshotDocuments()) |doc| {
            try hashMetadata(&hash, .{ doc.id, doc.revision, doc.dirty(), doc.path, doc.etag, doc.bom, doc.newline });
        }
        for (self.groups.items.items) |group| try hashMetadata(&hash, .{ group.id, group.notebook == self.notebook, c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, group.notebook)) });
        for (self.views.items) |view| try hashMetadata(&hash, self.viewState(view.id, view.document, view.page, view.widget, view.buffer));
        for (self.excerpts.items) |pane| {
            try hashMetadata(&hash, self.viewState(pane.id, pane.document, pane.editor.root, pane.editor.widget, pane.editor.display));
            if (pane.editor.excerpt.source) |source| {
                var end: c.GtkTextIter = undefined;
                c.gtk_text_buffer_get_iter_at_mark(pane.document.buffer, &end, source.end);
                try hashMetadata(&hash, .{ excerptBase(pane), c.gtk_text_iter_get_offset(&end) });
            }
        }
        try hashMetadata(&hash, self.snapshotDockLayout());
        if (self.browser.model) |current| {
            hash.update(&current.policy_fingerprint);
            if (current.manifest_path) |path| hash.update(path);
            for (current.roots) |root| {
                hash.update(root.lexical_path);
                hash.update(root.display_name);
            }
        }
        return hash.final();
    }
    pub fn snapshotDocuments(self: *App) []const *Document {
        return self.documents.entries.items;
    }
    pub fn snapshotGroups(self: *App, allocator: std.mem.Allocator) ![]group_model.GroupState {
        const result = try allocator.alloc(group_model.GroupState, self.groups.items.items.len);
        for (self.groups.items.items, result) |group, *state| state.* = .{ .id = group.id, .active = group.notebook == self.notebook };
        return result;
    }
    pub fn snapshotViews(self: *App, allocator: std.mem.Allocator) ![]group_model.ViewState {
        const result = try allocator.alloc(group_model.ViewState, self.views.items.len + self.excerpts.items.len);
        for (self.views.items, result[0..self.views.items.len]) |view, *state| state.* = self.viewState(view.id, view.document, view.page, view.widget, view.buffer);
        for (self.excerpts.items, result[self.views.items.len..]) |pane, *state| {
            state.* = self.viewState(pane.id, pane.document, pane.editor.root, pane.editor.widget, pane.editor.display);
            const text = u.bufferText(pane.document.buffer);
            defer a.free(text);
            const source = pane.editor.excerpt.source.?;
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_mark(pane.document.buffer, &end, source.end);
            state.excerpt_start = excerpt_model.byteAtChar(text, @intCast(excerptBase(pane)));
            state.excerpt_end = excerpt_model.byteAtChar(text, @intCast(c.gtk_text_iter_get_offset(&end)));
        }
        return result;
    }
    fn viewState(self: *App, id: u64, d: *Document, page: W, widget: W, buffer: *c.GtkTextBuffer) group_model.ViewState {
        const group = self.groups.forPage(page).?;
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(buffer, &insertion, c.gtk_text_buffer_get_insert(buffer));
        c.gtk_text_buffer_get_iter_at_mark(buffer, &bound, c.gtk_text_buffer_get_selection_bound(buffer));
        const scroll = @import("editor_scroll.zig").capture(widget);
        const index = c.gtk_notebook_page_num(u.cast(c.GtkNotebook, group.notebook), page);
        return .{ .id = id, .document_id = d.id, .group_id = group.id, .page = index, .active = self.active_page == page, .selected = c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, group.notebook)) == index, .insertion = c.gtk_text_iter_get_offset(&insertion), .bound = c.gtk_text_iter_get_offset(&bound), .scroll_x = scroll.x, .scroll_y = scroll.y };
    }
    pub const RestoreDocument = struct {
        text: []const u8,
        path: ?[]const u8 = null,
        etag: ?[]const u8 = null,
        dirty: bool = true,
        bom: bool = false,
        newline: codec.Newline = .lf,
        external_changed: bool = false,
    };
    /// Creates a canonical document without a view. Call restoreView before yielding.
    /// Caller owns disk identity verification and maps old IDs to the returned ID.
    pub fn restoreDocument(self: *App, state: RestoreDocument) !*Document {
        if (self.editingFrozen()) return error.Closing;
        if (self.fileOperationBarrier()) return error.FileOperationBusy;
        if (!std.unicode.utf8ValidateSlice(state.text) or std.mem.indexOfScalar(u8, state.text, 0) != null) return error.InvalidUtf8;
        if (state.text.len > 128 * 1024 * 1024) return error.LimitExceeded;
        if (state.path) |path| if (self.documents.findPath(path) != null) return error.DuplicateTarget;
        const d = try self.documents.create(self);
        self.observeDocument(d);
        d.path = if (state.path) |path| u.z(path) else null;
        d.etag = if (state.etag) |etag| u.z(etag) else null;
        d.bom = state.bom;
        d.newline = state.newline;
        d.external_changed = state.external_changed;
        d.large = state.text.len > 10 * 1024 * 1024;
        self.commitLoad(d, state.text);
        c.gtk_text_buffer_set_modified(d.buffer, @intFromBool(state.dirty));
        self.watch(d);
        self.scheduleCheckpoint();
        return d;
    }
    /// group_id/document are fresh identities. Restore pages in saved page order,
    /// then restore focus with focusGroup/focusView (or restoreFocus for excerpts).
    pub fn restoreView(self: *App, d: *Document, group_id: u64, state: group_model.ViewState) !u64 {
        if (!std.math.isFinite(state.scroll_x) or !std.math.isFinite(state.scroll_y) or state.scroll_x < 0 or state.scroll_y < 0) return error.InvalidScroll;
        if ((state.excerpt_start == null) != (state.excerpt_end == null)) return error.InvalidAnchor;
        const id = if (state.excerpt_start) |start| try self.openExcerpt(d, group_id, .{ .start = start, .end = state.excerpt_end orelse return error.InvalidAnchor }) else (try self.addView(d, group_id)).id;
        const buffer = self.activeBuffer().?;
        var insertion: c.GtkTextIter = undefined;
        var bound: c.GtkTextIter = undefined;
        const count = c.gtk_text_buffer_get_char_count(buffer);
        c.gtk_text_buffer_get_iter_at_offset(buffer, &insertion, std.math.clamp(state.insertion, 0, count));
        c.gtk_text_buffer_get_iter_at_offset(buffer, &bound, std.math.clamp(state.bound, 0, count));
        c.gtk_text_buffer_select_range(buffer, &insertion, &bound);
        const widget = self.activeWidget().?;
        try @import("editor_scroll.zig").restore(widget, .{ .x = state.scroll_x, .y = state.scroll_y });
        return id;
    }
    /// Roll back only the documents/groups appended by an explicit restore.
    /// Unlike user close, this neither prompts nor shuts down the last window.
    pub fn rollbackSessionRestore(self: *App, documents: usize, groups: usize, previous_focus: ?u64) void {
        while (self.documents.entries.items.len > documents) {
            const d = self.documents.entries.items[self.documents.entries.items.len - 1];
            var i: usize = 0;
            while (i < self.excerpts.items.len) {
                if (self.excerpts.items[i].document == d) self.detachExcerpt(self.excerpts.items[i]) else i += 1;
            }
            i = 0;
            while (i < self.views.items.len) {
                if (self.views.items[i].document == d) self.detachView(self.views.items[i]) else i += 1;
            }
            _ = self.documents.remove(d.id);
        }
        self.notebook = self.groups.items.items[0].notebook;
        while (self.groups.items.items.len > groups) {
            const group = self.groups.items.items[self.groups.items.items.len - 1];
            _ = c.g_signal_handlers_disconnect_matched(group.notebook, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            self.removeGroup(group.id);
        }
        self.repairActive();
        if (previous_focus) |id| self.restoreFocus(id);
        self.scheduleCheckpoint();
    }
    pub fn restoreFocus(self: *App, view_id: u64) void {
        for (self.views.items) |view| if (view.id == view_id) {
            self.focusView(view);
            return;
        };
        for (self.excerpts.items) |pane| if (pane.id == view_id) {
            self.focusPage(pane.editor.root, pane.editor.widget);
            return;
        };
    }
    pub fn checkpoint(self: *App) void {
        if (self.checkpoint_idle != 0) {
            _ = c.g_source_remove(self.checkpoint_idle);
            self.checkpoint_idle = 0;
        }
        if (self.recovery_suspended or self.checkpoint_running or transactions.isApplying() or self.history.active) return;
        // An initial asynchronous path resolution is not an empty, closed session.
        if (!self.quitting and self.documents.entries.items.len == 0 and self.browser.hasPendingFiles()) return;
        self.checkpoint_running = true;
        defer self.checkpoint_running = false;
        // Excerpt source notifications use an idle refresh, which may have been
        // enqueued after this checkpoint. Capture current presentation state too.
        for (self.excerpts.items) |pane| if (!pane.document.loading and pane.document.pending == null) {
            pane.editor.refresh() catch |err| self.editFailure(err);
        };
        if (self.recovery_checkpoint) |callback| callback(self.recovery_context, self);
        if (self.manager != null) self.projects.changed();
    }
    pub fn scheduleCheckpoint(self: *App) void {
        if (self.closing or self.recovery_suspended or self.checkpoint_running or self.recovery_checkpoint == null or self.checkpoint_idle != 0) return;
        self.checkpoint_idle = c.g_idle_add(&checkpointIdle, self);
    }
    pub fn effectiveSettings(self: *App, d: *Document) safe_settings.Effective {
        const id: ?[]const u8 = if (d.language) |lang| std.mem.span(gtk_source_language_get_id(lang)) else null;
        if (self.browser.model) |*model| if (d.path) |path| {
            const root = model.ownerOfCanonicalPath(path) catch null;
            if (root != null) return model.effectiveSettings(root, id, self.settings.baseline(), self.settings.present);
        };
        // Scratch and outside-root documents must not inherit manifest policy.
        return safe_settings.resolve(self.settings.baseline(), self.settings.present, .{}, .{}, .{ .language = id });
    }
    fn configureWidget(_: *App, widget: W, effective: safe_settings.Effective) void {
        const values = effective.values;
        const view = u.cast(c.GtkSourceView, widget);
        c.gtk_source_view_set_show_line_numbers(view, @intFromBool(values.lines));
        c.gtk_source_view_set_tab_width(view, values.indent);
        c.gtk_source_view_set_indent_width(view, values.indent);
        c.gtk_source_view_set_insert_spaces_instead_of_tabs(view, @intFromBool(values.spaces));
        c.gtk_source_view_set_auto_indent(view, 1);
        c.gtk_source_view_set_highlight_current_line(view, 1);
        c.gtk_text_view_set_wrap_mode(u.cast(c.GtkTextView, widget), if (values.wrap) c.GTK_WRAP_WORD_CHAR else c.GTK_WRAP_NONE);
    }
    pub fn configurePolicy(self: *App, d: *Document) void {
        const effective = self.effectiveSettings(d);
        for (self.views.items) |view| if (view.document == d) self.configureWidget(view.widget, effective);
        for (self.excerpts.items) |pane| if (pane.document == d) self.configureWidget(pane.editor.widget, effective);
    }
    pub fn refreshPolicySettings(self: *App) void {
        for (self.documents.entries.items) |d| self.configurePolicy(d);
    }
    pub fn setDocumentLanguage(self: *App, d: *Document, language: ?*c.GtkSourceLanguage) void {
        d.setLanguage(language);
        d.language_applying = true;
        defer d.language_applying = false;
        // Update the presentation owner's retained selection even when its
        // parser is already detached (and setting null would emit no notify).
        const presentation = @import("editor/presentation_policy.zig").get(d.buffer);
        const was_applying = if (presentation) |policy| policy.applying else false;
        defer if (presentation) |policy| {
            policy.applying = was_applying;
        };
        if (presentation) |policy| {
            policy.applying = true;
            const desired = if (d.large) null else language;
            if (policy.language != desired) {
                if (desired) |value| _ = c.g_object_ref(value);
                if (policy.language) |value| c.g_object_unref(value);
                policy.language = desired;
            }
        }
        const limited = d.large or @import("editor/presentation_policy.zig").limited(d.buffer);
        c.gtk_source_buffer_set_language(u.cast(c.GtkSourceBuffer, d.buffer), if (limited) null else language);
        self.configurePolicy(d);
    }
    fn configure(self: *App, d: *Document, detect_language: bool) void {
        for (self.views.items) |view| if (view.document == d) view.setEditable(!self.editingFrozen());
        const manager = c.gtk_source_style_scheme_manager_get_default();
        var prefer_dark: c_int = 0;
        c.g_object_get(c.gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &prefer_dark, @as(?*anyopaque, null));
        const following = self.settings.theme == 3 and self.appearance.revision != null;
        const native_look = std.mem.eql(u8, "native", self.appearance.themeClass());
        const name: [*:0]const u8 = if (native_look) (if (prefer_dark != 0) "Adwaita-dark" else "Adwaita") else if (following) self.appearance.ensureScheme() else if (self.settings.theme == 1) "coral-light" else "coral-dark";
        const scheme = c.gtk_source_style_scheme_manager_get_scheme(manager, name);
        c.gtk_source_buffer_set_style_scheme(u.cast(c.GtkSourceBuffer, d.buffer), scheme);
        var underline: c.GdkRGBA = undefined;
        const underline_hex: [:0]u8 = if (following) u.z(self.appearance.palette.error_color) else if (self.settings.theme == 1) u.z("#9b2a21") else u.z("#ffb4ab");
        defer a.free(underline_hex);
        _ = c.gdk_rgba_parse(&underline, underline_hex);
        c.g_object_set(d.tag, "underline-rgba", &underline, @as(?*anyopaque, null));
        const language_manager = c.gtk_source_language_manager_get_default();
        const language = if (detect_language) (if (d.path) |p| c.gtk_source_language_manager_guess_language(language_manager, p, null) else null) else d.language;
        _ = @import("editor/presentation_policy.zig").attach(d.buffer) catch |err| {
            self.editFailure(err);
            return;
        };
        // highlight-syntax=false still runs GtkSource's context engine. Remove
        // the language as well when the explicit large-file policy is selected.
        if (detect_language) self.setDocumentLanguage(d, language);
        c.gtk_source_buffer_set_highlight_syntax(u.cast(c.GtkSourceBuffer, d.buffer), @intFromBool(!d.large));
        self.configurePolicy(d);
        for (self.excerpts.items) |pane| if (pane.document == d) {
            const source = u.cast(c.GtkSourceBuffer, pane.editor.display);
            c.gtk_source_buffer_set_style_scheme(source, scheme);
            const limited = d.large or @import("editor/presentation_policy.zig").limited(d.buffer);
            c.gtk_source_buffer_set_language(source, if (limited) null else language);
            c.gtk_source_buffer_set_highlight_syntax(source, @intFromBool(!limited));
            c.g_object_set(pane.spelling_tag, "underline-rgba", &underline, @as(?*anyopaque, null));
            pane.spelling_dirty = true;
            pane.editor.refresh() catch {};
        };
    }
    fn setEditable(self: *App, d: *Document, editable: bool) void {
        for (self.views.items) |view| if (view.document == d) view.setEditable(editable and !self.editingFrozen());
        for (self.excerpts.items) |pane| if (pane.document == d) {
            c.gtk_text_view_set_editable(u.cast(c.GtkTextView, pane.editor.widget), @intFromBool(editable and !self.editingFrozen() and !d.loading and d.pending == null));
        };
    }
    fn disconnectObject(self: *App, object: anytype) void {
        inline for (.{ self, &self.browser, &self.browser.view, &self.workspace_search, &self.workspace_search.view, &self.workspace_search.view.list, &self.workspace_policy, &self.session }) |context| {
            _ = c.g_signal_handlers_disconnect_matched(@ptrCast(object), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, context);
        }
    }
    fn disconnectCallbacks(self: *App, widget: W) void {
        self.disconnectObject(widget);
        // Transient action groups hold a GObject reference to the owner window.
        // Drop it even when GTK or an async chooser retains a closed dialog.
        c.gtk_widget_insert_action_group(widget, "win", null);
        const controllers = c.gtk_widget_observe_controllers(widget).?;
        defer c.g_object_unref(controllers);
        for (0..c.g_list_model_get_n_items(controllers)) |i| {
            const controller = c.g_list_model_get_item(controllers, @intCast(i)).?;
            self.disconnectObject(controller);
            c.g_object_unref(controller);
        }
        var child = c.gtk_widget_get_first_child(widget);
        while (child) |current| : (child = c.gtk_widget_get_next_sibling(current)) self.disconnectCallbacks(current);
    }
    /// Shared chooser/about APIs return no widget. Resolve their exact transient
    /// ancestry, never the display's focused/active window, and retain the list
    /// while destroying children (which mutates GTK's toplevel model).
    pub fn transients(self: *App, close: bool) void {
        const model = c.gtk_window_get_toplevels().?;
        var owned: std.ArrayList(*c.GtkWindow) = .empty;
        defer owned.deinit(a);
        const count = c.g_list_model_get_n_items(model);
        for (0..count) |i| {
            const object = c.g_list_model_get_item(model, @intCast(i)) orelse continue;
            const window = u.cast(c.GtkWindow, object);
            var parent = c.gtk_window_get_transient_for(window);
            var depth: usize = 0;
            while (parent != null and parent != u.cast(c.GtkWindow, self.window) and depth < 32) : (depth += 1) parent = c.gtk_window_get_transient_for(parent);
            if (parent == u.cast(c.GtkWindow, self.window)) owned.append(a, window) catch unreachable else c.g_object_unref(object);
        }
        for (owned.items) |window| {
            const is_chooser = c.g_object_get_data(u.cast(c.GObject, window), "pearl-chooser") != null;
            if (close) {
                self.disconnectCallbacks(u.cast(c.GtkWidget, window));
                // The chooser's task itself retains its dialog. A destroy signal
                // can wait for finalization; response completes the task now.
                if (is_chooser) c.gtk_dialog_response(u.cast(c.GtkDialog, window), c.GTK_RESPONSE_CANCEL) else c.gtk_window_destroy(window);
            } else {
                self.styleWindow(u.cast(c.GtkWidget, window));
                if (test_hooks and is_chooser) testKeys(self, u.cast(c.GtkWidget, window));
            }
            c.g_object_unref(window);
        }
    }
    pub fn installTestKeys(self: *App, widget: W) void {
        testKeys(self, widget);
    }
    pub fn styleWindow(self: *App, widget: W) void {
        self.themeClasses(widget);
        // Transient roots do not inherit their parent's widget action groups.
        c.gtk_widget_insert_action_group(widget, "win", u.cast(c.GActionGroup, self.window));
    }
    fn themeClasses(self: *App, widget: W) void {
        c.gtk_widget_add_css_class(widget, self.scope_class);
        const class = self.appearance.themeClass();
        if (std.mem.eql(u8, "native", class)) c.gtk_widget_remove_css_class(widget, "coral") else c.gtk_widget_add_css_class(widget, "coral");
        inline for (.{ "dark", "light" }) |name| {
            if (std.mem.eql(u8, name, class)) c.gtk_widget_add_css_class(widget, name) else c.gtk_widget_remove_css_class(widget, name);
        }
    }
    fn savePreferences(self: *App) void {
        if (self.manager) |manager| manager.savePreferences(self.settings);
    }
    pub fn receivePreferences(self: *App, settings: Settings) void {
        self.settings = settings;
        self.appearance.setMode(@import("appearance.zig").modeFrom(settings.theme));
        self.applySettings();
        self.resetSpelling();
    }
    fn applySettings(self: *App) void {
        self.workspace_policy.userSettingsChanged();
        self.transients(false);
        self.themeClasses(self.window);
        const css = u.fmt(".{s} textview {{ font-family: monospace; font-size: {d:.3}em; }}", .{ self.scope_class, @as(f64, @floatFromInt(self.settings.font)) / 14.667 });
        defer a.free(css);
        c.gtk_css_provider_load_from_string(self.font_css, css);
        for (self.documents.entries.items) |d| self.configure(d, false);
    }
    fn appearanceChanged(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.closing) return;
        self.applySettings();
    }
    pub fn editingFrozen(self: *const App) bool {
        return self.closing or self.quitting or self.project_close_waiting or self.close_guard != null or
            (if (self.manager) |manager| manager.quitting or self.projects.frozen != null or self.projects.retiring else false);
    }
    pub fn fileOperationBarrier(self: *const App) bool {
        return if (self.manager) |manager| manager.file_operation_owner != null else false;
    }
    pub fn workspaceOperationBusy(self: *const App) bool {
        // Lightweight widget-test Apps have no manager/controller lifecycle.
        return self.manager != null and (self.workspace_operations.busy() or self.workspace_roots.busy());
    }
    pub fn openDialogs(self: *const App) bool {
        return self.dialog != null or self.workspaceOperationBusy() or
            self.file_open_choosers != 0 or self.browser.choosing or
            (self.manager != null and (self.projects.dialog != null or self.projects.picker != null));
    }
    pub fn rejectFileOperationBarrier(self: *App) bool {
        if (!self.fileOperationBarrier()) return false;
        self.message("A workspace file operation is applying. Retry after it finishes; existing document edits are kept.");
        return true;
    }
    fn rejectOperationClose(self: *App) bool {
        if (!self.workspaceOperationBusy() and !self.fileOperationBarrier()) return false;
        self.cancelClosing();
        self.message("Finish or cancel the workspace file operation and wait for its worker cleanup before closing. Quit All was cancelled; your documents are kept.");
        return true;
    }
    pub fn message(self: *App, text: []const u8) void {
        if (self.closing) return;
        u.setLabel(self.notice, text);
        c.gtk_widget_set_visible(self.notice, @intFromBool(text.len > 0));
    }
    pub fn refreshWorkspaceLabels(self: *App) void {
        self.update();
    }
    fn update(self: *App) void {
        if (self.closing) return;

        const width = c.gtk_widget_get_width(self.window);
        const wide = width >= 760;
        if (self.chrome) |*chrome| chrome.update(self, width);
        c.gtk_widget_set_visible(self.new_button, @intFromBool(wide));
        c.gtk_widget_set_visible(self.search_button, @intFromBool(wide));
        for (self.groups.items.items) |group| group.chrome.clearIfEmpty();
        for (self.views.items) |presentation| {
            self.updateBreadcrumb(presentation.page, presentation.document, false);
            const d = presentation.document;
            var name: []const u8 = if (d.path) |p| std.fs.path.basename(p) else @import("i18n").dtr("coral", "Untitled");
            if (d.path) |p| {
                for (self.documents.entries.items) |other| {
                    if (other == d) continue;
                    if (other.path) |q| {
                        if (std.mem.eql(u8, std.fs.path.basename(q), name)) {
                            name = p;
                            break;
                        }
                    }
                }
            }
            var qualified: ?[:0]u8 = null;
            defer if (qualified) |text| a.free(text);
            if (d.path) |path| if (self.browser.model) |*snapshot| {
                if (snapshot.ownerOfCanonicalPath(path) catch null) |id| {
                    const root = snapshot.rootById(id).?;
                    const base = root.canonical_path.?;
                    // Keep the distinguishing identity at the visible start, even
                    // when both root names collide and GTK ellipsizes a long tab.
                    qualified = u.fmt("#{d} {s} · {s}", .{ @backingInt(root.id), root.display_name, path[@min(path.len, base.len + @as(usize, if (base.len == 1) 0 else 1))..] });
                    name = qualified.?;
                }
            };
            const title = u.fmt("{s}{s}", .{ name, if (d.dirty()) " •" else "" });
            u.setLabel(presentation.tab_label, title);
            self.updateTabClass(presentation.tab, presentation.tab_label, presentation.page);
            a.free(title);
            if (d.path) |p| c.gtk_widget_set_tooltip_text(presentation.tab, p);
            presentation.setEditable(!self.editingFrozen());
        }
        for (self.excerpts.items) |pane| {
            self.updateBreadcrumb(pane.editor.root, pane.document, true);
            const title = u.fmt("Excerpt · {s}{s}", .{ if (pane.document.path) |path| std.fs.path.basename(path) else "Untitled", if (pane.document.dirty()) " •" else "" });
            defer a.free(title);
            u.setLabel(pane.label, title);
            self.updateTabClass(pane.tab, pane.label, pane.editor.root);
            c.gtk_text_view_set_editable(u.cast(c.GtkTextView, pane.editor.widget), @intFromBool(!self.editingFrozen() and !pane.document.loading and pane.document.pending == null));
        }
        const d = self.active() orelse {
            u.setLabel(self.status, "");
            c.gtk_widget_set_tooltip_text(self.status, null);
            c.gtk_widget_set_visible(self.spell_button, 0);
            c.gtk_window_set_title(u.cast(c.GtkWindow, self.window), @import("i18n").dtr("coral", "Coral"));
            return;
        };
        var iter: c.GtkTextIter = undefined;
        const buffer = self.activeBuffer() orelse return;
        c.gtk_text_buffer_get_iter_at_mark(buffer, &iter, c.gtk_text_buffer_get_insert(buffer));
        var status_buffer: [2048]u8 = undefined;
        const status = @import("i18n").dfmt("coral", &status_buffer, "Ln {d}, Col {d}   ·   UTF-8{s} · {s}{s}{s}", .{ c.gtk_text_iter_get_line(&iter) + 1, c.gtk_text_iter_get_line_offset(&iter) + 1, if (d.bom) " BOM" else "", @tagName(d.newline), if (d.busy) @import("i18n").dtr("coral", " · Working…") else if (d.large or @import("editor/presentation_policy.zig").limited(d.buffer)) @import("i18n").dtr("coral", " · Syntax/spelling off (presentation budget)") else "", if (d.external_changed) @import("i18n").dtr("coral", " · Changed on disk") else "" });
        // Keep the complete document state available even when metadata collapses.
        const status_tooltip = u.z(status);
        defer a.free(status_tooltip);
        c.gtk_widget_set_tooltip_text(self.status, status_tooltip);
        var caret_buffer: [256]u8 = undefined;
        const caret = @import("i18n").dfmt("coral", &caret_buffer, "Ln {d}, Col {d}{s}", .{ c.gtk_text_iter_get_line(&iter) + 1, c.gtk_text_iter_get_line_offset(&iter) + 1, if (d.external_changed) " !" else if (d.busy) " …" else "" });
        u.setLabel(self.status, if (wide) status else caret);
        const spelling_text: [*:0]const u8 = if (!self.enumerated) @import("i18n").dtr("coral", "Checking dictionaries…") else if (!self.dictionary) @import("i18n").dtr("coral", "Dictionary unavailable") else if (!self.spellingEnabled(d)) @import("i18n").dtr("coral", "Spelling off") else @import("i18n").dtr("coral", "Spelling");
        c.gtk_button_set_label(u.cast(c.GtkButton, self.spell_button), spelling_text);
        const count = c.gtk_source_search_context_get_occurrences_count(self.activeSearch());
        var count_buffer: [32]u8 = undefined;
        var matches_buffer: [256]u8 = undefined;
        const number = std.fmt.bufPrint(&count_buffer, "{d}", .{@max(count, 0)}) catch unreachable;
        const count_text = @import("i18n").dnmessage("coral", &matches_buffer, "{count} match", "{count} matches", @intCast(@max(count, 0)), &.{.{ .name = "count", .value = number }});
        u.setLabel(self.matches, count_text);
        const title = u.fmt("{s}{s} — Coral", .{ if (d.path) |p| std.fs.path.basename(p) else @import("i18n").dtr("coral", "Untitled"), if (d.dirty()) " •" else "" });
        c.gtk_window_set_title(u.cast(c.GtkWindow, self.window), title);
        a.free(title);
    }
    fn updateBreadcrumb(self: *App, page: W, document: *Document, excerpt: bool) void {
        const group = self.groups.forPage(page) orelse return;
        group.chrome.showDocument(page, document.path, if (self.browser.model) |*model| model else null, excerpt);
    }
    fn updateTabClass(self: *App, tab: W, label: W, page: W) void {
        const group = self.groups.forPage(page) orelse return;
        @import("editor/view.zig").sizeTabLabel(label, c.gtk_widget_get_width(group.notebook));
        const notebook = u.cast(c.GtkNotebook, group.notebook);
        const selected = c.gtk_notebook_get_nth_page(notebook, c.gtk_notebook_get_current_page(notebook)) == page;
        if (selected) c.gtk_widget_add_css_class(tab, "active") else c.gtk_widget_remove_css_class(tab, "active");
    }
    fn spellingEnabled(self: *App, d: *Document) bool {
        if (d.large or @import("editor/presentation_policy.zig").limited(d.buffer)) return false;
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
    /// Browser opens include a typed root boundary. Both CLI and browser metadata
    /// checks run on workers; the existing descriptor-safe loader owns file reads.
    pub fn openExisting(self: *App, path: []const u8, root: ?@import("workspace/model.zig").RootId) void {
        if (self.editingFrozen()) return;
        self.browser.openFile(path, root);
    }
    pub fn existingFailed(self: *App, err: anyerror) void {
        if (self.closing) return;
        self.message(switch (err) {
            error.NotFound => @import("i18n").dtr("coral", "File not found. Use New document and Save As to create a file."),
            error.NonLocalUri => @import("i18n").dtr("coral", "Only local files are supported."),
            error.IsDirectory, error.NotRegularFile => @import("i18n").dtr("coral", "Choose an existing regular file, not a folder or device."),
            error.PermissionDenied => @import("i18n").dtr("coral", "Permission denied while opening the file."),
            error.OutsideRoot, error.UnavailableOrSymlink => "Browser open rejected: symlink, unavailable path, or path outside the selected root.",
            else => @import("i18n").dtr("coral", "Could not resolve this file. Check the path and permissions."),
        });
        if (!self.editingFrozen() and self.documents.entries.items.len == 0 and !self.browser.hasPendingFiles()) _ = self.newDocument();
    }
    pub fn acceptExisting(self: *App, canonical: []const u8) void {
        if (self.editingFrozen() or self.rejectFileOperationBarrier() or self.workspaceOperationBusy()) return;
        if (self.documents.findPath(canonical)) |d| {
            self.focus(d);
            return;
        }
        const d = self.newDocument();
        d.path = u.z(canonical);
        self.load(d, false);
    }
    /// Search always targets a full document view in the group active at activation.
    /// Positions are Unicode scalars; validate the loaded text before selecting it.
    pub fn navigateSearch(self: *App, d: *Document, group_id: u64, result: @import("workspace/search.zig").Result, mode: @import("workspace/search.zig").Mode, query: []const u8) !void {
        _ = self.groups.get(group_id) orelse return error.UnknownGroup;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        if (mode == .text) {
            var column = result.column;
            var end_column = result.end_column;
            // The file decoder removes a leading BOM; search positions describe
            // the raw disk source, whereas overlay positions already describe GTK.
            if (result.source == .disk and d.bom) {
                if (result.line == 0) column -|= 1;
                if (result.end_line == 0) end_column -|= 1;
            }
            if (c.gtk_text_buffer_get_iter_at_line_offset(d.buffer, &start, @intCast(result.line), @intCast(column)) == 0 or
                c.gtk_text_buffer_get_iter_at_line_offset(d.buffer, &end, @intCast(result.end_line), @intCast(end_column)) == 0) return error.StaleSearchLocation;
            const length = c.gtk_text_iter_get_offset(&end) - c.gtk_text_iter_get_offset(&start);
            if (length < 0 or length > 4096) return error.StaleSearchLocation;
            const selected = c.gtk_text_buffer_get_slice(d.buffer, &start, &end, 1);
            defer c.g_free(selected);
            // CRLF is normalized by the document loader, not by the search engine.
            const normalized = try std.mem.replaceOwned(u8, a, query, "\r\n", "\n");
            defer a.free(normalized);
            var expected = (try std.unicode.Utf8View.init(normalized)).iterator();
            var actual = (try std.unicode.Utf8View.init(std.mem.span(selected))).iterator();
            while (expected.nextCodepoint()) |scalar| {
                const found = actual.nextCodepoint() orelse return error.StaleSearchLocation;
                if (c.g_unichar_tolower(scalar) != c.g_unichar_tolower(found)) return error.StaleSearchLocation;
            }
            if (actual.nextCodepoint() != null) return error.StaleSearchLocation;
        }
        var target: ?*EditorView = null;
        for (self.views.items) |view| if (view.document == d) {
            if (self.groups.forPage(view.page)) |group| if (group.id == group_id) {
                target = view;
                break;
            };
        };
        const view = target orelse try self.addView(d, group_id);
        self.focusView(view);
        if (mode == .text) {
            var view_start: c.GtkTextIter = undefined;
            var view_end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(view.buffer, &view_start, c.gtk_text_iter_get_offset(&start));
            c.gtk_text_buffer_get_iter_at_offset(view.buffer, &view_end, c.gtk_text_iter_get_offset(&end));
            c.gtk_text_buffer_select_range(view.buffer, &view_start, &view_end);
            self.scrollActiveTo(&view_start);
        }
        self.scheduleCheckpoint();
    }
    /// Retire requests before a future workspace transition. Cancellation is
    /// advisory: callbacks retain their holds/resources and still finish.
    /// The caller must reestablish watches/loads for any retained documents.
    pub fn invalidateWorkspaceAsync(self: *App) void {
        self.workspace_search.invalidate("Stale — document lifecycle changed. Refresh required.");
        self.workspace.invalidate();
        for (self.documents.entries.items) |d| {
            d.stopWatching();
            d.watch_query = null;
            if (d.loading) {
                if (d.cancellable) |cancel| {
                    c.g_cancellable_cancel(cancel);
                    c.g_object_unref(cancel);
                }
                d.cancellable = null;
                d.busy = false;
                d.loading = false;
                if (!self.closing) self.setEditable(d, true);
            }
        }
    }
    fn watch(self: *App, d: *Document) void {
        if (self.workspace.capture() == null) return;
        d.stopWatching();
        const path = d.path orelse return;
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        var err: ?*c.GError = null;
        d.monitor = c.g_file_monitor_file(file, c.G_FILE_MONITOR_WATCH_MOVES, null, &err);
        if (d.monitor) |monitor| {
            u.connect(monitor, "changed", &diskChanged, self);
        } else {
            logFileFailure("event=document-monitor-failed domain={f} code={d}", err);
            self.message(@import("i18n").dtr("coral", "Could not monitor this file for external changes."));
        }
        if (err) |e| c.g_error_free(e);
        // Close the load/save-to-monitor gap against the committed etag, not a
        // new baseline sampled from disk (which could already be another writer).
        self.queryDisk(d);
    }
    fn queryDisk(self: *App, d: *Document) void {
        const workspace = self.workspace.capture() orelse return;
        if (d.watch_query != null) {
            d.watch_pending = true;
            return;
        }
        const path = d.path orelse return;
        const op = a.create(WatchOp) catch unreachable;
        op.* = .{ .app = self, .workspace = workspace, .id = d.id, .generation = d.watch_generation, .cancel = c.g_cancellable_new().? };
        d.watch_query = op.cancel;
        d.watch_pending = false;
        const file = c.g_file_new_for_path(path).?;
        defer c.g_object_unref(file);
        self.hold();
        c.g_file_query_info_async(file, "standard::type,etag::value", c.G_FILE_QUERY_INFO_NONE, c.G_PRIORITY_DEFAULT, op.cancel, &diskQueried, op);
    }
    fn requestReload(self: *App, d: *Document) void {
        if (self.rejectFileOperationBarrier() or self.workspaceOperationBusy()) return;
        if (d.busy or d.pending != null or d.path == null) return;
        if (d.dirty()) {
            self.ask(.reload, d, @import("i18n").dtr("coral", "Discard unsaved edits?"), @import("i18n").dtr("coral", "Reloading replaces your current edits with the version on disk."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Discard and reload"), .id = 1 } });
        } else self.load(d, true);
    }
    fn load(self: *App, d: *Document, reload: bool) void {
        if (self.editingFrozen()) return;
        if (self.rejectFileOperationBarrier()) return;
        const workspace = self.workspace.capture() orelse return;
        if (d.busy) return;
        const path = d.path orelse return;
        self.workspace_search.loadStarted(d);
        const op = a.create(LoadOp) catch unreachable;
        op.* = .{ .app = self, .workspace = workspace, .id = d.id, .cancel = c.g_cancellable_new().?, .reload = reload, .revision = d.revision };
        d.stopWatching();
        d.busy = true;
        d.loading = true;
        // The operation owns its cancellation handle even if the document is
        // removed or a new generation replaces the document's request.
        d.cancellable = u.cast(c.GCancellable, c.g_object_ref(op.cancel).?);
        self.setEditable(d, false);
        self.hold();
        self.pending_file_loads += 1;
        load_file.load(path, d.cancellable.?, &loaded, op);
        self.update();
    }
    fn commitLoad(self: *App, d: *Document, text: []const u8) void {
        if (self.editingFrozen()) return;
        self.workspace_search.beforeLoad(d);
        c.gtk_text_buffer_begin_irreversible_action(d.buffer);
        c.gtk_text_buffer_set_text(d.buffer, text.ptr, @intCast(text.len));
        c.gtk_text_buffer_end_irreversible_action(d.buffer);
        d.recordSavedRevision(d.revision);
        d.loading = false;
        self.configure(d, true);
        // A late load can replace a focused editor with the long-line notice.
        // Reestablish a rooted focus target after all load/layout callbacks.
        if (self.activeView()) |view| if (view.document == d and view.layout_guard.blocked) {
            const focused = c.gtk_widget_grab_focus(view.layout_guard.button);
            if (test_hooks) c.g_print("CORAL_GUARD document=%llu long_line=1 focused=%d\n", @as(c_ulonglong, d.id), focused);
        };
        self.invalidate(d);
        self.update();
        self.workspace_search.afterLoad(d);
    }
    fn save(self: *App, d: *Document, save_as: bool, force: bool) void {
        if (self.rejectFileOperationBarrier() or self.workspaceOperationBusy()) {
            d.close_after_save = false;
            self.cancelClosing();
            return;
        }
        if (d.busy) {
            self.message(@import("i18n").dtr("coral", "Wait for the current file operation to finish."));
            return;
        }
        if (d.newline == .mixed) {
            d.normalize_save_as = save_as;
            self.ask(.mixed, d, @import("i18n").dtr("coral", "Choose a line ending"), @import("i18n").dtr("coral", "This file mixes LF and CRLF line endings. Choose a format before saving; Coral will normalize line endings explicitly."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Use LF"), .id = 1 }, .{ .text = @import("i18n").dtr("coral", "Use CRLF"), .id = 2 } });
            return;
        }
        if (save_as or d.path == null) {
            self.chooseSave(d);
            return;
        }
        self.saveTo(d, d.path.?, force, false);
    }
    fn saveTo(self: *App, d: *Document, requested_path: []const u8, force: bool, as: bool) void {
        if (self.rejectFileOperationBarrier()) {
            d.close_after_save = false;
            self.cancelClosing();
            return;
        }
        if (d.busy) return;
        // A missing baseline must not turn an ordinary Save into an unchecked
        // replacement (including independent copies open in another window).
        if (!force and !as and d.etag == null) {
            d.close_after_save = false;
            self.cancelClosing();
            self.ask(.conflict, d, "Cannot verify the saved version", "This document has no saved file identity. Save a copy instead of overwriting an unverified version on disk.", &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Save As…", .id = 2 } });
            return;
        }
        const path = u.canonicalPath(requested_path);
        defer a.free(path);
        for (self.documents.entries.items) |other| {
            if (other != d) {
                if (other.path) |p| {
                    if (std.mem.eql(u8, p, path)) {
                        self.message(@import("i18n").dtr("coral", "That file is already open in another tab. Save to a different name."));
                        d.close_after_save = false;
                        self.cancelClosing();
                        return;
                    }
                }
            }
        }
        const reservation = if (self.manager) |manager| manager.reserveSave(self.window_id, d.id, path) catch |err| {
            d.close_after_save = false;
            self.cancelClosing();
            self.message(switch (err) {
                error.SaveDestinationBusy => "Save destination is busy in another window. Wait for that save to finish, then retry; your edits are preserved.",
                error.SaveLimit => "Coral allows 16 in-flight saves. Wait for a save to finish, then retry; your edits are preserved.",
                error.SavePathTooLong => "Save destination exceeds the 4095-byte path limit; your edits are preserved.",
                else => "Could not reserve the save destination; your edits are preserved.",
            });
            return;
        } else null;
        var admitted = false;
        defer if (!admitted) {
            if (reservation) |slot| self.manager.?.releaseSave(slot);
        };
        const text = u.bufferText(d.buffer);
        defer a.free(text);
        const bytes = codec.encode(a, text, d.bom, d.newline) catch {
            self.message(@import("i18n").dtr("coral", "Choose a line ending before saving."));
            return;
        };
        const op = a.create(SaveOp) catch unreachable;
        op.* = .{ .doc = d, .path = u.z(path), .data = bytes, .revision = d.revision, .etag = if (!force and !as) if (d.etag) |e| u.z(e) else null else null, .reservation = reservation };
        admitted = true;
        d.stopWatching();
        d.busy = true;
        d.cancellable = c.g_cancellable_new();
        self.hold();
        if (test_hooks and self.test_save_delay_ms != 0) {
            _ = c.g_timeout_add(self.test_save_delay_ms, &delayedSave, op);
            self.test_save_delay_ms = 0;
        } else dispatchSave(op);
        self.update();
    }
    fn chooseOpen(self: *App) void {
        if (self.editingFrozen()) return;
        if (self.rejectFileOperationBarrier() or self.workspaceOperationBusy()) return;
        self.file_open_choosers += 1;
        self.hold();
        chooser.openAsync(@ptrCast(self.window), 1, @ptrCast(&chosenOpen), self);
        self.transients(false);
    }
    fn chooseSave(self: *App, d: *Document) void {
        if (self.rejectFileOperationBarrier() or self.workspaceOperationBusy()) return;
        d.busy = true;
        self.hold();
        const name = u.z(if (d.path) |p| std.fs.path.basename(p) else "Untitled.txt");
        defer a.free(name);
        chooser.saveAsync(@ptrCast(self.window), name, @ptrCast(&chosenSave), d);
        self.transients(false);
    }
    fn ask(self: *App, kind: DialogKind, d: ?*Document, title: [*:0]const u8, detail: [*:0]const u8, buttons: []const Button) void {
        if (self.dialog != null or self.workspaceOperationBusy()) return;
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
        if (self.rejectOperationClose()) return;
        if (!self.quitting and self.snapshotDocuments().len == 1) {
            self.quit();
            return;
        }
        self.hidePopover();
        if (d.busy) {
            if (d.loading) {
                d.cancelled_close = true;
                if (d.cancellable) |p| c.g_cancellable_cancel(p);
            } else {
                self.message(@import("i18n").dtr("coral", "Saving is still in progress. Close this document after it finishes."));
                self.cancelClosing();
            }
            return;
        }
        if (d.dirty()) {
            self.focus(d);
            self.ask(.close, d, @import("i18n").dtr("coral", "Save your changes?"), @import("i18n").dtr("coral", "Save this document before closing it? Discarding loses the unsaved edits."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Discard"), .id = 1 }, .{ .text = @import("i18n").dtr("coral", "Save"), .id = 2 } });
            return;
        }
        if (self.quitting) self.resolveClose(d, false) else self.remove(d);
    }
    fn resolveClose(self: *App, d: *Document, discard: bool) void {
        if (!self.quitting) {
            self.remove(d);
            return;
        }
        if (discard) self.projects.discard(d.id);
        self.close_resolved.append(a, d.id) catch {
            self.cancelClosing();
            self.message("Could not allocate close bookkeeping. All documents were kept.");
            return;
        };
        self.continueWindowClose();
    }
    fn continueWindowClose(self: *App) void {
        if (self.project_close_waiting) return;
        for (self.snapshotDocuments()) |doc| {
            if (std.mem.indexOfScalar(u64, self.close_resolved.items, doc.id) == null) {
                self.closeDocument(doc);
                return;
            }
        }
        if (self.close_guard) |guard| if (!self.closeDocumentsMatch(guard, false)) {
            self.cancelClosing();
            self.message("Documents changed during close. Nothing was removed; review the changes and retry.");
            return;
        };
        if (self.final_close_guard) |guard| a.free(guard);
        self.final_close_guard = self.closeDocuments() catch {
            self.cancelClosing();
            return;
        };
        if (self.close_without_session) {
            self.project_close_waiting = true;
            self.projects.closeWithoutSession() catch |err| {
                self.cancelClosing();
                self.message(@errorName(err));
            };
            return;
        }
        const reopen = if (self.manager) |manager| manager.shouldReopenOnClose(self) else true;
        if (self.manager != null and self.projects.frozen != null) {
            self.project_close_waiting = true;
            self.projects.finishClose(reopen) catch |err| {
                self.automaticCloseFailed(err);
            };
        } else self.projectCloseCompleted(true);
    }
    pub fn projectCloseCompleted(self: *App, success: bool) void {
        self.project_close_waiting = false;
        if (!success) {
            self.cancelClosing();
            return;
        }
        if (self.final_close_guard) |guard| if (!self.closeDocumentsMatch(guard, true)) {
            self.cancelClosing();
            self.message("Documents changed while the automatic session was being written. The window was kept open; no documents were removed.");
            return;
        };
        self.project_close_committed = true;
        while (self.snapshotDocuments().len != 0) self.remove(self.snapshotDocuments()[self.snapshotDocuments().len - 1]);
        self.shutdownWindow();
    }
    pub fn automaticCloseFailed(self: *App, err: anyerror) void {
        self.project_close_waiting = false;
        if (self.close_guard == null) {
            self.cancelClosing();
            self.message("Finish pending operations before closing this window.");
            return;
        }
        const detail = u.fmt("Automatic session retention failed: {s}. Close without retaining this window's automatic session? Existing startup membership will be cleared durably before closing. You must still Save or Discard every unsaved document. Files and explicit checkpoints are not deleted.", .{@errorName(err)});
        defer a.free(detail);
        self.ask(.close_without_session, null, "Close without retaining this automatic session?", detail, &.{ .{ .text = "Cancel", .id = 0 }, .{ .text = "Close without automatic session", .id = 1 } });
    }
    fn remove(self: *App, d: *Document) void {
        self.workspace_search.documentChanged(d);
        self.hidePopover();
        var excerpt_index: usize = 0;
        while (excerpt_index < self.excerpts.items.len) {
            const pane = self.excerpts.items[excerpt_index];
            if (pane.document == d) self.detachExcerpt(pane) else excerpt_index += 1;
        }
        var index: usize = 0;
        while (index < self.views.items.len) {
            const view = self.views.items[index];
            if (view.document != d) {
                index += 1;
                continue;
            }
            self.detachView(view);
        }
        _ = self.documents.remove(d.id);
        self.repairActive();
        self.scheduleCheckpoint();
        if (self.documents.entries.items.len == 0) {
            self.shutdownWindow();
            return;
        }
        self.update();
        if (self.quitting and !self.project_close_committed) {
            self.continueWindowClose();
        } else if (self.closing_group != null) {
            self.continueCloseGroup();
        } else if (self.activeWidget()) |widget| {
            _ = c.gtk_widget_grab_focus(widget);
        }
    }
    fn shutdownWindow(self: *App) void {
        if (self.closing or self.rejectOperationClose()) return;
        self.checkpoint();
        if (self.manager != null) {
            self.projects.shutdown();
            self.workspace_roots.shutdown();
            self.workspace_operations.shutdown();
        }
        self.closing = true;
        self.dock.shutdown();
        self.session.shutdown();
        self.workspace_policy.shutdown();
        self.workspace_search.shutdown();
        self.browser.shutdown();
        self.workspace.close();
        if (self.palette) |palette| {
            self.disconnectCallbacks(palette.window);
            palette.close();
        }
        if (self.timer != 0) {
            _ = c.g_source_remove(self.timer);
            self.timer = 0;
        }
        while (self.views.items.len > 0) self.detachView(self.views.items[self.views.items.len - 1]);
        while (self.excerpts.items.len > 0) self.detachExcerpt(self.excerpts.items[self.excerpts.items.len - 1]);
        if (self.checkpoint_idle != 0) {
            _ = c.g_source_remove(self.checkpoint_idle);
            self.checkpoint_idle = 0;
        }
        // Remove the native window now, but do not destroy its widget tree while
        // chooser/worker callbacks still own this App. Recovery observes removal.
        c.gtk_widget_set_visible(self.window, 0);
        c.gtk_application_remove_window(self.application, u.cast(c.GtkWindow, self.window));
        self.transients(true);
    }
    pub const CloseDocument = struct {
        id: u64,
        revision: u64,
        path: u64,
        etag: u64,
        dirty: bool,

        fn capture(doc: *Document) CloseDocument {
            return .{ .id = doc.id, .revision = doc.revision, .path = std.hash.Wyhash.hash(0, doc.path orelse ""), .etag = std.hash.Wyhash.hash(0, doc.etag orelse ""), .dirty = doc.dirty() };
        }
        fn matches(self: CloseDocument, other: CloseDocument, baselines: bool) bool {
            return self.id == other.id and self.revision == other.revision and
                (!baselines or (self.path == other.path and self.etag == other.etag and self.dirty == other.dirty));
        }
    };
    fn closeDocuments(self: *App) ![]CloseDocument {
        const result = try a.alloc(CloseDocument, self.snapshotDocuments().len);
        for (self.snapshotDocuments(), result) |doc, *out| out.* = CloseDocument.capture(doc);
        return result;
    }
    fn closeDocumentsMatch(self: *App, guard: []const CloseDocument, baselines: bool) bool {
        if (self.snapshotDocuments().len != guard.len) return false;
        for (self.snapshotDocuments(), guard) |doc, baseline| {
            if (!baseline.matches(CloseDocument.capture(doc), baselines)) return false;
        }
        return true;
    }
    pub fn prepareProjectClose(self: *App) !void {
        if (self.recovery_suspended or self.browser.hasPendingOperations() or self.pending_file_loads != 0 or self.session.work != null or self.projects.restoring or self.projects.restore_cleanup or self.projects.retiring or self.openDialogs()) return error.Loading;
        for (self.snapshotDocuments()) |doc| if (doc.busy or doc.loading or doc.pending != null) return error.Loading;
        if (self.close_guard == null) self.close_guard = try self.closeDocuments();
        if (self.close_focus == null) self.close_focus = self.activeViewId();
        for (self.snapshotDocuments()) |doc| self.setEditable(doc, false);
        if (!self.close_without_session) try self.projects.freeze();
    }
    pub fn thawProjectClose(self: *App) void {
        self.projects.cancelClose();
        if (self.close_guard) |guard| a.free(guard);
        self.close_guard = null;
        if (self.final_close_guard) |guard| a.free(guard);
        self.final_close_guard = null;
        self.close_without_session = false;
        for (self.snapshotDocuments()) |doc| self.setEditable(doc, !doc.busy);
        if (self.close_focus) |id| self.restoreFocus(id);
        self.close_focus = null;
    }
    fn cancelClosing(self: *App) void {
        if (self.manager) |manager| {
            manager.cancelQuit(self.window_id);
            self.thawProjectClose();
        }
        self.quitting = false;
        self.project_close_waiting = false;
        self.close_resolved.clearRetainingCapacity();
        self.closing_group = null;
        for (self.snapshotDocuments()) |doc| self.setEditable(doc, !doc.busy);
        if (self.close_focus) |id| self.restoreFocus(id);
        self.close_focus = null;
    }
    pub fn quit(self: *App) void {
        if (self.closing) return;
        if (self.rejectOperationClose()) return;
        if (self.quitting) return;
        if (self.manager) |manager| if (manager.quitting and manager.quit_waiting != self.window_id) {
            self.message("Quit All is resolving another window. Cancel its prompt to stop quitting.");
            return;
        };
        if (self.dialog != null or self.recovery_suspended) {
            self.cancelClosing();
            self.message("Finish the current dialog or startup recovery before closing this window.");
            return;
        }
        if (self.manager != null) self.prepareProjectClose() catch |err| {
            self.automaticCloseFailed(err);
            return;
        };
        if (self.close_focus == null) self.close_focus = self.activeViewId();
        self.close_resolved.clearRetainingCapacity();
        self.quitting = true;
        for (self.snapshotDocuments()) |doc| self.setEditable(doc, false);
        self.continueWindowClose();
    }
    fn showSearch(self: *App, show: bool) void {
        c.gtk_widget_set_visible(self.searchbox, @intFromBool(show));
        if (show) {
            _ = c.gtk_widget_grab_focus(self.query);
        } else {
            for (self.documents.entries.items) |d| c.gtk_source_search_settings_set_search_text(d.search_settings, null);
            if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
        }
    }
    fn findMatch(self: *App, back: bool) void {
        const buffer = self.activeBuffer() orelse return;
        const search = self.activeSearch() orelse return;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        _ = c.gtk_text_buffer_get_selection_bounds(buffer, &start, &end);
        var at = if (back) start else end;
        const found = if (back) c.gtk_source_search_context_backward(search, &at, &start, &end, null) else c.gtk_source_search_context_forward(search, &at, &start, &end, null);
        if (found != 0) {
            c.gtk_text_buffer_select_range(buffer, &start, &end);
            self.scrollActiveTo(&start);
        }
        self.update();
    }
    fn replace(self: *App, all: bool) void {
        const d = self.active() orelse return;
        const buffer = self.activeBuffer() orelse return;
        const search = self.activeSearch() orelse return;
        if (d.loading or d.pending != null) return;
        if (c.gtk_text_buffer_get_char_count(d.buffer) > 16 * 1024 * 1024) {
            self.message(@import("i18n").dtr("coral", "This buffer is too large for a safe edit transaction."));
            return;
        }
        const replacement = u.z(u.entryText(self.replacement));
        defer a.free(replacement);
        const text = u.bufferText(buffer);
        defer a.free(text);
        const revision = d.revision;
        var edits: std.ArrayList(transactions.Replacement) = .empty;
        defer edits.deinit(a);
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        var byte_cursor: usize = 0;
        var char_cursor: c_int = 0;
        if (all) {
            var at: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_start_iter(buffer, &at);
            var wrapped: c_int = 0;
            while (c.gtk_source_search_context_forward(search, &at, &start, &end, &wrapped) != 0 and wrapped == 0) {
                if (c.gtk_text_iter_compare(&start, &end) >= 0) break;
                if (edits.items.len >= 65_536) {
                    self.message(@import("i18n").dtr("coral", "Too many replacements. Narrow the search before replacing."));
                    return;
                }
                const from = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&start));
                const to = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&end));
                edits.append(a, .{ .start = from, .end = to, .text = replacement }) catch {
                    self.message(@import("i18n").dtr("coral", "Not enough memory to prepare the edit. Nothing was changed."));
                    return;
                };
                at = end;
            }
        } else {
            if (c.gtk_text_buffer_get_selection_bounds(buffer, &start, &end) == 0) {
                self.findMatch(false);
                _ = c.gtk_text_buffer_get_selection_bounds(buffer, &start, &end);
            }
            if (c.gtk_source_search_context_get_occurrence_position(search, &start, &end) > 0) {
                const from = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&start));
                const to = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&end));
                edits.append(a, .{ .start = from, .end = to, .text = replacement }) catch return;
            }
        }
        if (edits.items.len > 0) {
            if (self.activeExcerpt()) |pane| {
                var mapped = pane.editor.excerpt.map(a, editTarget(d, revision), edits.items) catch |err| {
                    self.editFailure(err);
                    return;
                };
                defer mapped.deinit();
                self.performGrouped("Replace in excerpt", &.{mapped.change}) catch |err| self.editFailure(err);
                pane.editor.refresh() catch |err| self.editFailure(err);
            } else self.applyEdits(d, revision, edits.items);
        }
        if (!all) self.findMatch(false);
        self.update();
    }
    fn applyEdits(self: *App, d: *Document, revision: u64, edits: []const transactions.Replacement) void {
        self.performGrouped("Edit document", &.{.{ .target = editTarget(d, revision), .replacements = edits }}) catch |err| self.editFailure(err);
    }
    fn editFailure(self: *App, err: anyerror) void {
        log.warn("event=edit-rejected reason={s}", .{@errorName(err)});
        self.message(switch (err) {
            error.StaleRevision, error.SnapshotMismatch, error.TargetMismatch => @import("i18n").dtr("coral", "The document changed. Retry the edit against the current text."),
            error.LimitExceeded => @import("i18n").dtr("coral", "The edit exceeds the transaction safety limit. Nothing was changed."),
            else => @import("i18n").dtr("coral", "Could not safely apply this edit. Nothing was changed."),
        });
    }
    fn showPalette(self: *App) void {
        if (self.dialog != null or self.workspaceOperationBusy() or self.closing) return;
        self.hidePopover();
        if (self.palette) |palette| {
            palette.show();
            return;
        }
        c.g_weak_ref_set(&self.palette_focus, @ptrCast(c.gtk_window_get_focus(u.cast(c.GtkWindow, self.window))));
        self.palette = Palette.create(self.window, self, &paletteCommand, &paletteClosed) catch {
            c.g_weak_ref_set(&self.palette_focus, null);
            self.message(@import("i18n").dtr("coral", "Could not open the command palette."));
            return;
        };
        self.styleWindow(self.palette.?.window);
        testKeys(self, self.palette.?.window);
        self.palette.?.show();
    }
    fn execute(self: *App, command: commands.Command) void {
        if (self.closing) return;
        // New Window must be rejected even when a quit prompt is modal.
        if (command == .new_window) {
            if (self.manager) |manager| manager.create(self);
            return;
        }
        if (command == .quit or command == .close_window) {
            if (self.rejectOperationClose()) return;
        }
        if (self.dialog != null or self.workspaceOperationBusy() or self.editingFrozen()) return;
        if (self.manager) |manager| if (manager.quitting) return;
        switch (command) {
            .recent_projects => self.projects.showProjects(false),
            .open_buffers => self.projects.showBuffers(),
            .forget_project_session => self.projects.showProjects(true),
            .add_workspace_root => self.workspace_roots.request(.add),
            .remove_workspace_root => self.workspace_roots.request(.remove),
            .save_workspace_as => self.workspace_roots.request(.save_as),
            .new => {
                _ = self.newDocument();
            },
            .open => self.chooseOpen(),
            .open_folder => self.browser.choose(.folder),
            .open_workspace => self.browser.choose(.manifest),

            .workspace_roots => {
                self.browser.roots();
                self.focusExplorer();
            },
            .workspace_back => self.browser.back(),
            .workspace_rescan => self.browser.rescan(),
            .create_workspace_file => self.workspace_operations.request(.create_file),
            .create_workspace_directory => self.workspace_operations.request(.create_directory),
            .rename_workspace_entry => self.workspace_operations.request(.rename),
            .move_workspace_entry => self.workspace_operations.request(.move),
            .delete_workspace_entry => self.workspace_operations.request(.delete),
            .close_workspace => self.browser.closeWorkspace(),
            .quick_open => self.workspace_search.show(.quick_open),
            .workspace_search, .focus_search => self.workspace_search.show(.text),
            .focus_explorer => self.focusExplorer(),
            .toggle_explorer => if (self.dock.visible(.explorer)) self.hidePanel(.explorer) else self.focusExplorer(),
            .toggle_search => if (self.dock.visible(.search)) self.hidePanel(.search) else self.workspace_search.show(.text),
            .focus_editor => {
                if (self.dock.picking) self.workspace_search.hide();
                self.focusEditor();
            },
            .hide_panel => if (self.dock.picking) self.workspace_search.hide() else self.hidePanel(self.dock.state.active),
            .dock_left => self.dock.move(.left),
            .dock_right => self.dock.move(.right),
            .dock_bottom => self.dock.move(.bottom),
            .dock_grow => self.dock.grow(true),
            .dock_shrink => self.dock.grow(false),
            .reset_docks => {
                if (self.dock.picking) self.workspace_search.hide();
                self.dock.restore(.{});
                self.focusEditor();
            },
            .workspace_policy => self.showPolicy(false),
            .workspace_trust => self.showPolicy(true),
            .workspace_revoke => self.workspace_policy.revoke(),
            .save_workspace_session => self.session.start(.save),
            .restore_workspace_session => self.session.start(.restore),
            .save, .save_as => if (self.active()) |d| {
                self.save(d, command == .save_as, false);
            },
            .reload => if (self.active()) |d| {
                self.requestReload(d);
            },
            .find => self.showSearch(true),
            .goto_line => self.gotoLine(),
            .spelling => if (self.active()) |d| {
                self.requestSuggestions(d);
            },
            .preferences => self.preferences(),
            .close => self.closeActiveView(),
            .split_group => self.splitGroup() catch |err| self.editFailure(err),
            .next_tab, .previous_tab => {
                const current = c.gtk_notebook_get_current_page(u.cast(c.GtkNotebook, self.notebook));
                const count = c.gtk_notebook_get_n_pages(u.cast(c.GtkNotebook, self.notebook));
                if (count > 0) c.gtk_notebook_set_current_page(u.cast(c.GtkNotebook, self.notebook), @mod(current + if (command == .previous_tab) @as(c_int, -1) else 1, count));
                self.focusEditor();
            },
            .focus_next_group => self.cycleGroup(false),
            .focus_previous_group => self.cycleGroup(true),
            .close_group => self.closeGroup(),
            .excerpt => self.excerptSelection() catch |err| self.editFailure(err),
            .grouped_undo => self.replayGrouped(false) catch |err| self.editFailure(err),
            .grouped_redo => self.replayGrouped(true) catch |err| self.editFailure(err),

            .close_window => self.quit(),
            .next_window, .previous_window => if (self.manager) |manager| manager.cycle(self.window_id, command == .previous_window),
            .quit => if (self.manager) |manager| manager.quitAll(self) else self.quit(),
            .command_palette => self.showPalette(),
            .new_window => unreachable,
            .about => {
                c.gtk_show_about_dialog(u.cast(c.GtkWindow, self.window), "program-name", @as([*:0]const u8, "Coral"), "version", @as([*:0]const u8, "0.1.1"), "comments", @as([*:0]const u8, "A focused Zig and GTK4 text editor with offline spelling."), @as(?*anyopaque, null));
                self.transients(false);
            },
        }
    }
    fn showPolicy(self: *App, confirmation: bool) void {
        if (self.dialog != null or self.workspaceOperationBusy() or self.closing) return;
        if (confirmation and !self.workspace_policy.prepareConfirmation()) return;
        const text = self.workspace_policy.describe();
        defer a.free(text);
        const dialog = c.gtk_dialog_new().?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), if (confirmation) "Trust workspace…" else "Workspace: Settings and Trust…");
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 700, 600);
        const box = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        const scroll = c.gtk_scrolled_window_new().?;
        c.gtk_widget_set_vexpand(scroll, 1);
        const label = u.label(text);
        c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
        c.gtk_label_set_xalign(u.cast(c.GtkLabel, label), 0);
        c.gtk_label_set_max_width_chars(u.cast(c.GtkLabel, label), 85);
        u.margin(label, 16);
        c.gtk_scrolled_window_set_child(u.cast(c.GtkScrolledWindow, scroll), label);
        u.append(box, scroll);
        _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), if (confirmation) "Cancel" else "Close", 0);
        if (confirmation) {
            _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Trust these exact roots and policy", 1);
        } else {
            _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Recheck", 3);
            _ = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Revoke trust", 2);
            const button = c.gtk_dialog_add_button(u.cast(c.GtkDialog, dialog), "Trust workspace…", 1);
            c.gtk_widget_set_sensitive(button, @intFromBool(self.workspace_policy.canConfirm()));
        }
        c.gtk_dialog_set_default_response(u.cast(c.GtkDialog, dialog), 0);
        self.styleWindow(dialog);
        self.dialog = dialog;
        self.dialog_doc = null;
        self.dialog_kind = if (confirmation) .trust else .policy;
        u.connect(dialog, "response", &dialogResponse, self);
        testKeys(self, dialog);
        c.gtk_window_present(u.cast(c.GtkWindow, dialog));
    }
    fn preferences(self: *App) void {
        if (self.dialog != null or self.workspaceOperationBusy()) return;
        self.hidePopover();
        const dialog = c.gtk_dialog_new().?;
        c.gtk_window_set_title(u.cast(c.GtkWindow, dialog), @import("i18n").dtr("coral", "Coral preferences"));
        c.gtk_window_set_transient_for(u.cast(c.GtkWindow, dialog), u.cast(c.GtkWindow, self.window));
        c.gtk_window_set_modal(u.cast(c.GtkWindow, dialog), 1);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, dialog), 440, 520);
        const box = u.cast(c.GtkWidget, c.gtk_dialog_get_content_area(u.cast(c.GtkDialog, dialog)));
        u.margin(box, 20);
        const heading = u.label(@import("i18n").dtr("coral", "Make yourself at home"));
        c.gtk_widget_add_css_class(heading, "title-2");
        u.append(box, heading);
        const theme = c.gtk_combo_box_text_new().?;
        for ([_][*:0]const u8{ @import("i18n").dtr("coral", "Pearl dark"), @import("i18n").dtr("coral", "Pearl light"), @import("i18n").dtr("coral", "Native GTK"), @import("i18n").dtr("coral", "Follow Pearl") }) |name| c.gtk_combo_box_text_append_text(u.cast(c.GtkComboBoxText, theme), name);
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
        const note = u.label(if (self.languages.items.len == 0) @import("i18n").dtr("coral", "No dictionaries found. Install an Enchant provider and a language dictionary, then restart Coral.") else @import("i18n").dtr("coral", "Personal dictionary words may be shared with other Enchant applications."));
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
        if (self.dialog != null or self.workspaceOperationBusy()) return;
        const d = self.active() orelse return;
        self.ask(.goto, d, @import("i18n").dtr("coral", "Go to line"), @import("i18n").dtr("coral", "Enter a line number."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Go"), .id = 1 } });
        const input = c.gtk_spin_button_new_with_range(1, @floatFromInt(@max(c.gtk_text_buffer_get_line_count(self.activeBuffer()), 1)), 1).?;
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
        self.suggestion_view = self.activeViewId() orelse return;
        const buffer = self.activeBuffer() orelse return;
        var start: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_mark(buffer, &start, c.gtk_text_buffer_get_insert(buffer));
        const base = if (self.activeExcerpt()) |pane| excerptBase(pane) else 0;
        const limit = base + c.gtk_text_buffer_get_char_count(buffer);
        c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, base + c.gtk_text_iter_get_offset(&start));
        if (c.gtk_text_iter_has_tag(&start, d.tag) == 0) {
            c.gtk_text_buffer_get_iter_at_offset(d.buffer, &start, base);
            if (c.gtk_text_iter_has_tag(&start, d.tag) == 0 and c.gtk_text_iter_forward_to_tag_toggle(&start, d.tag) == 0) {
                self.message(@import("i18n").dtr("coral", "No spelling suggestions in this document."));
                return;
            }
        }
        var end = start;
        if (c.gtk_text_iter_starts_tag(&start, d.tag) == 0) _ = c.gtk_text_iter_backward_to_tag_toggle(&start, d.tag);
        _ = c.gtk_text_iter_forward_to_tag_toggle(&end, d.tag);
        if (c.gtk_text_iter_get_offset(&start) < base or c.gtk_text_iter_get_offset(&end) > limit) {
            self.message("No complete spelling suggestions in this excerpt.");
            return;
        }
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
        if (self.active() != d or self.dialog != null or self.activeViewId() != self.suggestion_view) return;
        const widget = self.activeWidget() orelse return;
        if (c.gtk_widget_get_mapped(widget) == 0) return;
        const buffer = self.activeBuffer() orelse return;
        const base = if (self.activeExcerpt()) |pane| excerptBase(pane) else 0;
        if (job.offset < base or job.end > base + c.gtk_text_buffer_get_char_count(buffer)) return;
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
        c.gtk_widget_set_parent(pop, widget);
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
        if (job.words.items.len == 0) u.append(box, u.label(@import("i18n").dtr("coral", "No replacements found")));
        for ([_]struct { title: [*:0]const u8, callback: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void }{ .{ .title = @import("i18n").dtr("coral", "Ignore for this document"), .callback = &ignoreWord }, .{ .title = @import("i18n").dtr("coral", "Add to dictionary"), .callback = &addWord }, .{ .title = @import("i18n").dtr("coral", "Language…"), .callback = &onPreferences } }) |item| {
            const button = u.button(item.title);
            u.connect(button, "clicked", item.callback, self);
            u.append(box, button);
        }
        const separator = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?;
        u.append(box, separator);
        for ([_][2][*:0]const u8{ .{ @import("i18n").dtr("coral", "Cut"), "clipboard.cut" }, .{ @import("i18n").dtr("coral", "Copy"), "clipboard.copy" }, .{ @import("i18n").dtr("coral", "Paste"), "clipboard.paste" } }) |item| {
            const button = u.button(item[0]);
            c.g_object_set_data(u.cast(c.GObject, button), "edit-action", @constCast(item[1]));
            u.connect(button, "clicked", &editAction, self);
            u.append(box, button);
        }
        var iter: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_iter_at_offset(buffer, &iter, job.offset - base);
        _ = c.gtk_text_view_scroll_to_iter(u.cast(c.GtkTextView, widget), &iter, 0.1, 0, 0, 0);
        var rect: c.GdkRectangle = undefined;
        c.gtk_text_view_get_iter_location(u.cast(c.GtkTextView, widget), &iter, &rect);
        c.gtk_text_view_buffer_to_window_coords(u.cast(c.GtkTextView, widget), c.GTK_TEXT_WINDOW_WIDGET, rect.x, rect.y, &rect.x, &rect.y);
        c.gtk_popover_set_pointing_to(u.cast(c.GtkPopover, pop), &rect);
        c.gtk_popover_popup(u.cast(c.GtkPopover, pop));
    }
    fn resetSpelling(self: *App) void {
        self.generation += 1;
        self.hidePopover();
        for (self.documents.entries.items) |d| self.invalidate(d);
        self.update();
    }
    fn probeWorkspace(self: *App) void {
        const Doc = struct { id: u64, revision: u64, dirty: bool, text: []u8, path: ?[]const u8 };
        const docs = a.alloc(Doc, self.documents.entries.items.len) catch return;
        defer a.free(docs);
        for (self.documents.entries.items, docs) |d, *item| item.* = .{ .id = d.id, .revision = d.revision, .dirty = d.dirty(), .text = u.bufferText(d.buffer), .path = d.path };
        defer for (docs) |doc| a.free(doc.text);
        const views = self.snapshotViews(a) catch return;
        defer a.free(views);
        const groups = self.snapshotGroups(a) catch return;
        defer a.free(groups);
        const blocked = if (self.activeView()) |view| view.layout_guard.blocked else if (self.activeExcerpt()) |pane| pane.editor.layout_guard.blocked else false;
        const labels = a.alloc([]const u8, self.views.items.len) catch return;
        defer a.free(labels);
        for (self.views.items, labels) |view, *label| label.* = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, view.tab_label)));
        const font = if (self.activeWidget()) |widget| c.pango_context_get_font_description(c.gtk_widget_get_pango_context(widget)) else null;
        const json = std.json.Stringify.valueAlloc(a, .{ .window_id = self.window_id, .editor_font_size = if (font) |description| c.pango_font_description_get_size(description) else @as(c_int, 0), .editor_font_absolute = if (font) |description| c.pango_font_description_get_size_is_absolute(description) != 0 else false, .settings = self.settings, .session = self.session.testState(), .tab_labels = labels, .notice = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, self.notice))), .layout_blocked = blocked, .syntax_limited = if (self.active()) |d| @import("editor/presentation_policy.zig").limited(d.buffer) else false, .documents = docs, .views = views, .groups = groups, .history_cursor = self.history.cursor, .history_records = self.history.records.items.len, .active_view = self.activeViewId(), .dialog = self.dialog != null, .checkpoints = self.test_checkpoint_count, .editor_focused = self.activeWidget() == c.gtk_window_get_focus(u.cast(c.GtkWindow, self.window)), .editable = if (self.activeWidget()) |widget| c.gtk_text_view_get_editable(u.cast(c.GtkTextView, widget)) != 0 else false }, .{}) catch return;
        defer a.free(json);
        const line = u.z(json);
        defer a.free(line);
        c.g_print("CORAL_WORKSPACE %s\n", line.ptr);
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
        c.g_print("CORAL_PROBE {\"tabs\":%zu,\"id\":%llu,\"dirty\":%s,\"external_changed\":%s,\"busy\":%s,\"revision\":%llu,\"chars\":%d,\"spelling\":%zu,\"dictionary\":%s,\"enumerated\":%s,\"search\":%d,\"dialog\":%d,\"popover\":%s,\"theme\":%d,\"font\":%d,\"lines\":%s,\"bom\":%s,\"newline\":%d,\"check_from\":%d,\"inflight\":%s,\"checking_enabled\":%s,\"large\":%s,\"max_spell_tick_us\":%lld}\n", self.documents.entries.items.len, @as(c_ulonglong, d.id), boolZ(d.dirty()), boolZ(d.external_changed), boolZ(d.busy), @as(c_ulonglong, d.revision), c.gtk_text_buffer_get_char_count(d.buffer), count, boolZ(self.dictionary), boolZ(self.enumerated), c.gtk_source_search_context_get_occurrences_count(d.search), @as(c_int, if (self.dialog != null) @intCast(@backingInt(self.dialog_kind)) else -1), boolZ(self.popover != null), self.settings.theme, self.settings.font, boolZ(self.settings.lines), boolZ(d.bom), @as(c_int, @intCast(@backingInt(d.newline))), d.check_from, boolZ(d.inflight), boolZ(self.spellingEnabled(d)), boolZ(d.large), @as(c_longlong, self.max_spell_tick_us));
    }
};

fn hashMetadata(hash: *std.hash.Wyhash, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(json);
    hash.update(json);
}
fn scrollChanged(_: ?*c.GtkAdjustment, context: ?*anyopaque) callconv(.c) void {
    u.cast(App, context.?).scheduleCheckpoint();
}
fn viewFocused(view: *EditorView) void {
    const self = owner(view.document);
    const group = self.groups.forPage(view.page) orelse return;
    const switched = self.active_page != view.page;
    self.notebook = group.notebook;
    self.active_page = view.page;
    // Focus-enter includes descendants and seat reentry. During popup(), that
    // can be the spelling popover itself; unparenting it here strands GTK focus.
    if (switched) self.hidePopover();
    self.update();
    self.scheduleCheckpoint();
}
fn resolveExcerpt(context: ?*anyopaque, id: u64) ?transactions.Target {
    const self = u.cast(App, context.?);
    const d = self.find(id) orelse return null;
    return editTarget(d, d.revision);
}
fn excerptCommitted(context: ?*anyopaque) void {
    const self = u.cast(App, context.?);
    self.scheduleCheckpoint();
    self.update();
}
fn excerptFailed(context: ?*anyopaque, err: anyerror) void {
    u.cast(App, context.?).editFailure(err);
}
fn excerptFocused(_: ?*c.GtkEventControllerFocus, context: ?*anyopaque) callconv(.c) void {
    const pane = u.cast(ExcerptPane, context.?);
    const self = pane.app;
    const group = self.groups.forPage(pane.editor.root) orelse return;
    const switched = self.active_page != pane.editor.root;
    self.notebook = group.notebook;
    self.active_page = pane.editor.root;
    if (switched) self.hidePopover();
    self.update();
    self.scheduleCheckpoint();
}
fn excerptMark(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, mark: ?*c.GtkTextMark, context: ?*anyopaque) callconv(.c) void {
    if (!@import("editor/view.zig").isSelectionMark(buffer orelse return, mark orelse return)) return;
    const pane = u.cast(ExcerptPane, context.?);
    pane.app.update();
    pane.app.scheduleCheckpoint();
}
fn closeExcerpt(_: ?*c.GtkButton, context: ?*anyopaque) callconv(.c) void {
    const pane = u.cast(ExcerptPane, context.?);
    const self = pane.app;
    self.focusPage(pane.editor.root, pane.editor.widget);
    self.closeActiveView();
}
fn excerptContext(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, context: ?*anyopaque) callconv(.c) void {
    const pane = u.cast(ExcerptPane, context.?);
    pane.app.focusPage(pane.editor.root, pane.editor.widget);
    var bx: c_int = 0;
    var by: c_int = 0;
    const widget = u.cast(c.GtkTextView, pane.editor.widget);
    c.gtk_text_view_window_to_buffer_coords(widget, c.GTK_TEXT_WINDOW_WIDGET, @intFromFloat(x), @intFromFloat(y), &bx, &by);
    var local: c.GtkTextIter = undefined;
    if (c.gtk_text_view_get_iter_at_location(widget, &local, bx, by) == 0) return;
    var canonical: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(pane.document.buffer, &canonical, excerptBase(pane) + c.gtk_text_iter_get_offset(&local));
    if (c.gtk_text_iter_has_tag(&canonical, pane.document.tag) == 0) return;
    c.gtk_text_buffer_place_cursor(pane.editor.display, &local);
    _ = c.gtk_gesture_set_state(u.cast(c.GtkGesture, gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
    pane.app.requestSuggestions(pane.document);
}
fn onSpellingTag(_: ?*c.GtkTextBuffer, tag: ?*c.GtkTextTag, _: ?*c.GtkTextIter, _: ?*c.GtkTextIter, context: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, context.?);
    if (tag != d.tag) return;
    for (owner(d).excerpts.items) |pane| if (pane.document == d) {
        pane.spelling_dirty = true;
    };
}
fn refreshExcerptSpelling(pane: *ExcerptPane) void {
    pane.spelling_dirty = false;
    const display = pane.editor.display;
    const canonical = pane.document.buffer;
    const base = excerptBase(pane);
    const limit = base + c.gtk_text_buffer_get_char_count(display);
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(display, &start, &end);
    c.gtk_text_buffer_remove_tag(display, pane.spelling_tag, &start, &end);
    var at: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(canonical, &at, base);
    while (c.gtk_text_iter_get_offset(&at) < limit) {
        if (c.gtk_text_iter_has_tag(&at, pane.document.tag) != 0) {
            const from = c.gtk_text_iter_get_offset(&at);
            _ = c.gtk_text_iter_forward_to_tag_toggle(&at, pane.document.tag);
            const to = @min(limit, c.gtk_text_iter_get_offset(&at));
            if (to <= from) break;
            c.gtk_text_buffer_get_iter_at_offset(display, &start, from - base);
            c.gtk_text_buffer_get_iter_at_offset(display, &end, to - base);
            c.gtk_text_buffer_apply_tag(display, pane.spelling_tag, &start, &end);
        } else if (c.gtk_text_iter_forward_to_tag_toggle(&at, pane.document.tag) == 0) break;
    }
}
fn excerptBase(pane: *ExcerptPane) c_int {
    var iter: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_mark(pane.document.buffer, &iter, pane.editor.excerpt.source.?.start);
    return c.gtk_text_iter_get_offset(&iter);
}
fn testCheckpoint(_: ?*anyopaque, self: *App) void {
    if (!test_hooks) return;
    std.debug.assert(!transactions.isApplying() and !self.history.active);
    for (self.views.items) |view| {
        const canonical = u.bufferText(view.document.buffer);
        defer a.free(canonical);
        const presented = u.bufferText(view.buffer);
        defer a.free(presented);
        std.debug.assert(std.mem.eql(u8, canonical, presented));
    }
    self.test_checkpoint_count += 1;
}
fn checkpointIdle(context: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, context.?);
    self.checkpoint_idle = 0;
    self.checkpoint();
    return 0;
}
test "close guards permit Save baselines only before the final write and reject changed documents" {
    const original: App.CloseDocument = .{ .id = 1, .revision = 7, .path = 10, .etag = 20, .dirty = true };
    var baseline = original;
    baseline.path = 11;
    baseline.etag = 21;
    baseline.dirty = false;
    try std.testing.expect(original.matches(baseline, false));
    try std.testing.expect(!original.matches(baseline, true));
    try std.testing.expect(baseline.matches(baseline, true));
    var changed = baseline;
    changed.revision += 1;
    try std.testing.expect(!baseline.matches(changed, false));
    try std.testing.expect(!baseline.matches(changed, true));
    changed = baseline;
    changed.id += 1;
    try std.testing.expect(!baseline.matches(changed, false));
}

const DialogKind = enum { close, close_without_session, mixed, conflict, large, reload, preferences, goto, policy, trust };
const Button = struct { text: [*:0]const u8, id: c_int };
const WatchOp = struct { app: *App, workspace: workspace_identity.Token, id: u64, generation: u64, cancel: *c.GCancellable };
fn diskChanged(monitor: ?*c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c.GFileMonitorEvent, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    for (self.documents.entries.items) |d| {
        if (d.monitor == monitor) {
            self.workspace_search.invalidate("Stale — an open file changed on disk. Refresh required.");
            self.queryDisk(d);
            return;
        }
    }
}
fn diskQueried(source: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op = u.cast(WatchOp, data.?);
    const self = op.app;
    defer self.release();
    defer {
        c.g_object_unref(op.cancel);
        a.destroy(op);
    }
    var err: ?*c.GError = null;
    const info = c.g_file_query_info_finish(u.cast(c.GFile, source.?), result, &err);
    defer if (info) |p| c.g_object_unref(p);
    defer if (err) |e| c.g_error_free(e);
    const d = self.find(op.id) orelse return;
    if (d.watch_query != op.cancel) return;
    d.watch_query = null;
    if (!self.workspace.accepts(op.workspace)) return;
    if (d.watch_generation == op.generation and !d.watch_pending) {
        const etag = if (info) |p| c.g_file_info_get_etag(p) else null;
        d.external_changed = if (info) |p| c.g_file_info_get_file_type(p) != c.G_FILE_TYPE_REGULAR or etag == null or d.etag == null or !std.mem.eql(u8, std.mem.span(etag), d.etag.?) else true;
        self.update();
    }
    // Even across generations the old query must finish before starting a new
    // one. A closed document is never dereferenced and each op owns its hold.
    if (d.watch_pending) self.queryDisk(d);
}
const LoadOp = struct { app: *App, workspace: workspace_identity.Token, id: u64, cancel: *c.GCancellable, reload: bool, revision: u64 };
const SaveOp = struct { doc: *Document, path: [:0]u8, data: []u8, revision: u64, etag: ?[:0]u8 = null, reservation: ?usize = null };
fn editTarget(d: *Document, expected_revision: u64) transactions.Target {
    return .{ .id = d.id, .buffer = d.buffer, .revision = &d.revision, .expected_revision = expected_revision, .busy = d.loading or d.pending != null, .writable = !owner(d).editingFrozen() };
}
// Search walks forward through a stable UTF-8 snapshot, so each byte is scanned
// at most once even when replace-all has many matches.
fn byteOffset(text: []const u8, byte_cursor: *usize, char_cursor: *c_int, target: c_int) usize {
    std.debug.assert(target >= char_cursor.*);
    while (char_cursor.* < target) : (char_cursor.* += 1) {
        byte_cursor.* += std.unicode.utf8ByteSequenceLength(text[byte_cursor.*]) catch unreachable;
    }
    return byte_cursor.*;
}
fn boolZ(v: bool) [*:0]const u8 {
    return if (v) "true" else "false";
}
/// Logs a file-operation failure with its closed category. A cancelled
/// operation (a dismissed dialog, an aborted transfer) is dropped rather than
/// written as an error. `format` carries the literal event name plus the
/// `{f}`/`{d}` placeholders for the redacted domain name and numeric code; the
/// GError message and any path stay out of the journal.
fn logFileFailure(comptime format: []const u8, err: ?*c.GError) void {
    const cat = file_error.classify(err) orelse return;
    log.err(format, .{ diagnostics.safe(cat.domain), cat.code });
}
fn loaded(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const op = u.cast(LoadOp, data.?);
    const self = op.app;
    std.debug.assert(self.pending_file_loads > 0);
    defer self.pending_file_loads -= 1;
    defer a.destroy(op);
    defer c.g_object_unref(op.cancel);
    defer self.release();
    var contents: [*c]u8 = null;
    var size: usize = 0;
    var etag: [*c]u8 = null;
    var err: ?*c.GError = null;
    const ok = load_file.finish(result.?, &contents, &size, &etag, &err) != 0;
    defer c.g_free(contents);
    defer c.g_free(etag);
    defer if (err) |e| c.g_error_free(e);
    const d = self.find(op.id) orelse return;
    if (d.cancellable != op.cancel) return;
    defer self.workspace_search.loadSettled(op.id);
    d.busy = false;
    d.loading = false;
    if (d.cancellable) |p| c.g_object_unref(p);
    d.cancellable = null;
    if (!self.workspace.accepts(op.workspace) or self.editingFrozen()) return;
    defer if (self.workspace.accepts(op.workspace)) {
        if (self.find(op.id)) |remaining| {
            if (remaining.monitor == null and remaining.pending == null) self.watch(remaining);
        }
    };
    self.setEditable(d, true);
    if (self.rejectFileOperationBarrier()) return;
    if (d.cancelled_close) {
        self.remove(d);
        return;
    }
    if (!ok) {
        logFileFailure("event=document-load-failed domain={f} code={d}", err);
        if (err) |e| {
            self.message(std.mem.span(e.message));
        }
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        self.cancelClosing();
        self.update();
        return;
    }
    if (size > 128 * 1024 * 1024) {
        self.message(@import("i18n").dtr("coral", "This file exceeds Coral's 128 MiB safety limit."));
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        return;
    }
    if (d.revision != op.revision) {
        self.message(@import("i18n").dtr("coral", "The document changed during loading. Your edits were kept; reload again to review the disk version."));
        self.update();
        return;
    }
    const decoded = codec.decode(a, contents[0..size]) catch |e| {
        self.message(switch (e) {
            error.InvalidUtf8 => @import("i18n").dtr("coral", "This file is not valid UTF-8. Convert its encoding before opening it in Coral."),
            error.UnsupportedLineEnding => @import("i18n").dtr("coral", "Standalone CR line endings are not supported. Convert this file to LF or CRLF."),
            else => @import("i18n").dtr("coral", "This file contains binary data and cannot be edited as text."),
        });
        if (!op.reload) {
            if (d.path) |p| a.free(p);
            d.path = null;
        }
        self.update();
        return;
    };
    d.pending = decoded;
    d.pending_revision = op.revision;
    d.pending_reload = op.reload;
    if (etag != null) d.pending_etag = u.z(std.mem.span(etag));
    if (size > 10 * 1024 * 1024) {
        self.ask(.large, d, @import("i18n").dtr("coral", "Open in large-file mode?"), @import("i18n").dtr("coral", "This file is larger than 10 MiB. Automatic spelling and syntax highlighting will be disabled."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Open large file"), .id = 1 } });
    } else acceptLoaded(self, d, false);
}
fn acceptLoaded(self: *App, d: *Document, large: bool) void {
    if (self.editingFrozen() or self.rejectFileOperationBarrier()) return;
    const decoded = d.pending orelse return;
    d.pending = null;
    defer a.free(decoded.text);
    if (d.revision != d.pending_revision) {
        if (d.pending_etag) |etag| a.free(etag);
        d.pending_etag = null;
        self.watch(d);
        self.message(@import("i18n").dtr("coral", "The document changed while awaiting the load decision. Your edits were kept."));
        self.update();
        return;
    }
    d.bom = decoded.bom;
    d.newline = decoded.newline;
    d.large = large;
    if (d.etag) |p| a.free(p);
    d.etag = d.pending_etag;
    d.pending_etag = null;
    self.commitLoad(d, decoded.text);
    self.watch(d);
    self.message(if (d.newline == .mixed) @import("i18n").dtr("coral", "Mixed line endings detected. Choose LF or CRLF when you save.") else "");
}
fn dispatchSave(op: *SaveOp) void {
    const file = c.g_file_new_for_path(op.path).?;
    defer c.g_object_unref(file);
    if (op.etag != null) c.g_file_query_info_async(file, "etag::value", c.G_FILE_QUERY_INFO_NONE, c.G_PRIORITY_DEFAULT, op.doc.cancellable, &savePreflight, op) else startReplace(file, op);
}
fn delayedSave(data: ?*anyopaque) callconv(.c) c_int {
    dispatchSave(u.cast(SaveOp, data.?));
    return 0;
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
    const d = op.doc;
    const self = owner(d);
    defer {
        if (op.reservation) |slot| self.manager.?.releaseSave(slot);
        a.free(op.path);
        a.free(op.data);
        if (op.etag) |e| a.free(e);
        a.destroy(op);
        self.release();
    }
    d.busy = false;
    if (d.cancellable) |p| c.g_object_unref(p);
    d.cancellable = null;
    if (ok) {
        if (d.path) |p| a.free(p);
        d.path = u.z(op.path);
        if (d.etag) |p| a.free(p);
        d.etag = if (etag != null) u.z(std.mem.span(etag)) else null;
        d.recordSavedRevision(op.revision);
        self.watch(d);
        self.configure(d, true);
        self.update();
        self.message(@import("i18n").dtr("coral", "Saved."));
        self.scheduleCheckpoint();
        if (d.close_after_save) {
            d.close_after_save = false;
            if (!d.dirty()) {
                if (self.quitting) self.resolveClose(d, false) else self.remove(d);
            } else {
                self.cancelClosing();
                self.message(@import("i18n").dtr("coral", "Saved the earlier revision. Newer edits are still unsaved."));
            }
        }
    } else {
        self.watch(d);
        self.cancelClosing();
        d.close_after_save = false;
        logFileFailure("event=document-save-failed domain={f} code={d}", err);
        if (err) |e| {
            if (e.domain == c.g_io_error_quark() and e.code == c.G_IO_ERROR_WRONG_ETAG) {
                self.message(@import("i18n").dtr("coral", "File changed on disk. Save again to review the conflict; your edits are preserved."));
                self.ask(.conflict, d, @import("i18n").dtr("coral", "This file changed elsewhere"), @import("i18n").dtr("coral", "Your edits are preserved. Save a copy, reload the file, or explicitly overwrite the version on disk."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Reload"), .id = 1 }, .{ .text = @import("i18n").dtr("coral", "Save As…"), .id = 2 }, .{ .text = @import("i18n").dtr("coral", "Overwrite"), .id = 3 } });
            } else self.message(std.mem.span(e.message));
            c.g_error_free(e);
        }
        self.update();
    }
}
fn chosenOpen(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    std.debug.assert(self.file_open_choosers > 0);
    defer self.file_open_choosers -= 1;
    defer self.release();
    var err: ?*c.GError = null;
    const files: ?*c.GListModel = @ptrCast(chooser.openFinish(@ptrCast(result.?), @ptrCast(&err)));
    if (files) |list| {
        defer c.g_object_unref(list);
        if (self.closing or self.rejectFileOperationBarrier()) return;
        const n = c.g_list_model_get_n_items(list);
        for (0..n) |i| {
            const file = c.g_list_model_get_item(list, @intCast(i)).?;
            defer c.g_object_unref(file);
            const path = c.g_file_get_path(u.cast(c.GFile, file));
            if (path != null) {
                self.openExisting(std.mem.span(path), null);
                c.g_free(path);
            } else self.message(@import("i18n").dtr("coral", "Only local files are supported."));
        }
    }
    logFileFailure("event=file-chooser-failed domain={f} code={d}", err);
    if (err) |e| c.g_error_free(e);
}
fn chosenSave(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    const self = owner(d);
    d.busy = false;
    defer self.release();
    var err: ?*c.GError = null;
    const file: ?*c.GFile = @ptrCast(chooser.saveFinish(@ptrCast(result.?), @ptrCast(&err)));
    if (file) |f| {
        defer c.g_object_unref(f);
        const path = c.g_file_get_path(f);
        defer c.g_free(path);
        if (path != null) {
            self.saveTo(d, std.mem.span(path), false, true);
            return;
        }
        self.message(@import("i18n").dtr("coral", "Only local files are supported."));
    }
    logFileFailure("event=file-chooser-failed domain={f} code={d}", err);
    if (err) |e| c.g_error_free(e);
    d.close_after_save = false;
    self.cancelClosing();
    self.update();
}
fn dialogResponse(dialog: ?*c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const kind = self.dialog_kind;
    const doc = self.dialog_doc;
    const line = if (kind == .goto) c.gtk_spin_button_get_value_as_int(u.cast(c.GtkSpinButton, self.goto_input.?)) else 1;
    self.dialog = null;
    self.dialog_doc = null;
    self.disconnectCallbacks(u.cast(c.GtkWidget, dialog.?));
    c.gtk_window_destroy(u.cast(c.GtkWindow, dialog.?));
    switch (kind) {
        .policy => switch (response) {
            1 => self.showPolicy(true),
            2 => self.workspace_policy.revoke(),
            3 => self.workspace_policy.recheck(),
            else => {},
        },
        .trust => self.workspace_policy.confirm(response == 1),
        .close_without_session => {
            if (response != 1) {
                self.cancelClosing();
                return;
            }
            self.close_without_session = true;
            if (self.quitting) self.continueWindowClose() else self.quit();
        },
        .close => {
            const d = doc.?;
            if (response == 1) self.resolveClose(d, true) else if (response == 2) {
                d.close_after_save = true;
                self.save(d, false, false);
            } else {
                self.cancelClosing();
            }
        },
        .mixed => {
            if (response == 1 or response == 2) {
                doc.?.newline = if (response == 1) .lf else .crlf;
                self.save(doc.?, doc.?.normalize_save_as, false);
            } else {
                doc.?.close_after_save = false;
                self.cancelClosing();
            }
        },
        .conflict => {
            if (response == 1) self.requestReload(doc.?) else if (response == 2) self.save(doc.?, true, false) else if (response == 3) self.save(doc.?, false, true);
        },
        .reload => {
            if (response == 1) self.load(doc.?, true);
        },
        .large => {
            const d = doc.?;
            defer self.workspace_search.loadSettled(d.id);
            if (response == 1) acceptLoaded(self, d, true) else {
                if (d.pending) |p| a.free(p.text);
                d.pending = null;
                if (d.pending_etag) |p| a.free(p);
                d.pending_etag = null;
                if (!d.pending_reload and c.gtk_text_buffer_get_char_count(d.buffer) == 0) {
                    if (d.path) |p| a.free(p);
                    d.path = null;
                }
                self.watch(d);
                self.update();
            }
        },
        .preferences => self.savePreferences(),
        .goto => {
            if (response == 1) {
                var iter: c.GtkTextIter = undefined;
                const buffer = self.activeBuffer() orelse return;
                const widget = self.activeWidget() orelse return;
                _ = c.gtk_text_buffer_get_iter_at_line(buffer, &iter, line - 1);
                c.gtk_text_buffer_place_cursor(buffer, &iter);
                self.scrollActiveTo(&iter);
                _ = c.gtk_widget_grab_focus(self.activeFocusWidget() orelse widget);
            }
        },
    }
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, data.?);
    self.workspace_policy.pump();
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
            const language_changed = !std.mem.eql(u8, saved_lang, chosen);
            self.settings.setLanguage(chosen);
            self.dictionary = chosen.len > 0;
            // Dictionary discovery changes the user snapshot too; do not leave
            // another window holding a stale language for its next preference save.
            if (language_changed) self.savePreferences();
            self.update();
            continue;
        }
        if (job.kind == .add) {
            if (job.failed or !job.available) self.message(@import("i18n").dtr("coral", "The personal dictionary could not be updated.")) else {
                self.message(@import("i18n").dtr("coral", "Added to the personal dictionary shared by Enchant applications."));
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
            if (job.failed) self.message(@import("i18n").dtr("coral", "The spelling provider reported an error. Editing remains available."));
        }
    }
    const now = c.g_get_monotonic_time();
    for (self.documents.entries.items) |d| {
        if (d.pending != null and self.dialog == null) {
            self.focus(d);
            self.ask(.large, d, @import("i18n").dtr("coral", "Open in large-file mode?"), @import("i18n").dtr("coral", "This file exceeds 10 MiB. Automatic spelling and syntax highlighting will be disabled."), &.{ .{ .text = @import("i18n").dtr("coral", "Cancel"), .id = 0 }, .{ .text = @import("i18n").dtr("coral", "Open large file"), .id = 1 } });
        }
        const count = c.gtk_text_buffer_get_char_count(d.buffer);
        if (!self.enumerated or !self.dictionary or !self.spellingEnabled(d) or d.inflight or d.loading or now < d.due or d.check_from >= count) continue;
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        var offset = d.check_from;
        var priority = false;
        if (self.active() == d) {
            var visible: c.GdkRectangle = undefined;
            const widget = self.activeWidget().?;
            const base = if (self.activeExcerpt()) |pane| excerptBase(pane) else 0;
            c.gtk_text_view_get_visible_rect(u.cast(c.GtkTextView, widget), &visible);
            var first: c.GtkTextIter = undefined;
            var last: c.GtkTextIter = undefined;
            _ = c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, widget), &first, visible.x, visible.y);
            _ = c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, widget), &last, visible.x + visible.width, visible.y + visible.height);
            const first_offset = base + c.gtk_text_iter_get_offset(&first);
            const last_offset = base + c.gtk_text_iter_get_offset(&last);
            if (first_offset > d.check_from and (d.priority_revision != d.revision or first_offset < d.priority_start or last_offset > d.priority_end)) {
                if (c.gtk_text_iter_inside_word(&first) != 0) _ = c.gtk_text_iter_backward_word_start(&first);
                offset = base + c.gtk_text_iter_get_offset(&first);
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
    for (self.excerpts.items) |pane| if (pane.spelling_dirty and pane.editor.revision == pane.document.revision) refreshExcerptSpelling(pane);
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
fn owner(document: *Document) *App {
    return u.cast(App, document.context.?);
}
fn onChanged(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    d.due = c.g_get_monotonic_time() + 250000;
    owner(d).workspace_search.documentChanged(d);
    owner(d).hidePopover();
    for (owner(d).excerpts.items) |pane| if (pane.document == d) {
        pane.spelling_dirty = true;
    };
    owner(d).update();
    owner(d).scheduleCheckpoint();
}
fn syntaxChanged(_: ?*c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    const presentation = @import("editor/presentation_policy.zig").get(d.buffer);
    if (!d.language_applying and (presentation == null or !presentation.?.applying)) {
        const language = c.gtk_source_buffer_get_language(u.cast(c.GtkSourceBuffer, d.buffer));
        // A budget transition is not a user selection of Plain Text.
        if (language != null or presentation == null or !presentation.?.limited) d.setLanguage(language);
    }
    owner(d).configurePolicy(d);
}
fn onModified(_: ?*c.GtkTextBuffer, data: ?*anyopaque) callconv(.c) void {
    const self = owner(u.cast(Document, data.?));
    self.workspace_search.documentChanged(u.cast(Document, data.?));
    self.update();
    self.scheduleCheckpoint();
}
fn onViewMark(buffer: ?*c.GtkTextBuffer, _: ?*c.GtkTextIter, mark: ?*c.GtkTextMark, data: ?*anyopaque) callconv(.c) void {
    if (!@import("editor/view.zig").isSelectionMark(buffer orelse return, mark orelse return)) return;
    const view = u.cast(EditorView, data.?);
    const self = owner(view.document);
    self.update();
    self.scheduleCheckpoint();
}
fn onSwitch(notebook: ?*c.GtkNotebook, page: ?*c.GtkWidget, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    if (self.closing) return;
    self.notebook = u.cast(c.GtkWidget, notebook.?);
    self.active_page = page;
    self.hidePopover();
    self.update();
    self.scheduleCheckpoint();
}
fn onPageReordered(_: ?*c.GtkNotebook, _: ?*c.GtkWidget, _: c_uint, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).scheduleCheckpoint();
}
fn onCloseWindow(_: ?*c.GtkWindow, data: ?*anyopaque) callconv(.c) c_int {
    u.cast(App, data.?).quit();
    return 1;
}
fn onCloseTab(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    const view = u.cast(EditorView, data.?);
    const self = owner(view.document);
    self.focusView(view);
    self.closeActiveView();
}
fn onNew(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    if (u.cast(App, data.?).editingFrozen()) return;
    u.cast(App, data.?).execute(.new);
}
fn onOpen(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).execute(.open);
}
fn onSave(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).execute(.save);
}
fn onSearch(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).execute(.find);
}
fn onStopSearch(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    if (!self.closing) self.showSearch(false);
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
    u.cast(App, data.?).execute(.spelling);
}
fn onPreferences(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
    u.cast(App, data.?).execute(.preferences);
}
fn onQuery(_: ?*c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const text = u.z(u.entryText(self.query));
    defer a.free(text);
    for (self.documents.entries.items) |d| c.gtk_source_search_settings_set_search_text(d.search_settings, text);
    self.update();
}
fn onContext(gesture: ?*c.GtkGestureClick, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const view = u.cast(EditorView, data.?);
    const d = view.document;
    const self = owner(d);
    self.focusView(view);
    var bx: c_int = 0;
    var by: c_int = 0;
    c.gtk_text_view_window_to_buffer_coords(u.cast(c.GtkTextView, view.widget), c.GTK_TEXT_WINDOW_WIDGET, @intFromFloat(x), @intFromFloat(y), &bx, &by);
    var iter: c.GtkTextIter = undefined;
    if (c.gtk_text_view_get_iter_at_location(u.cast(c.GtkTextView, view.widget), &iter, bx, by) != 0 and c.gtk_text_iter_has_tag(&iter, d.tag) != 0) {
        c.gtk_text_buffer_place_cursor(view.buffer, &iter);
        view.syncSelectionToDocument();
        _ = c.gtk_gesture_set_state(u.cast(c.GtkGesture, gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
        self.requestSuggestions(d);
    }
}

fn prefTheme(widget: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.theme = c.gtk_combo_box_get_active(widget);
    self.appearance.setMode(@import("appearance.zig").modeFrom(self.settings.theme));
    self.savePreferences();
    self.applySettings();
}
fn prefFont(widget: ?*c.GtkSpinButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.font = c.gtk_spin_button_get_value_as_int(widget);
    self.savePreferences();
}
fn prefIndent(widget: ?*c.GtkSpinButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    self.settings.indent = c.gtk_spin_button_get_value_as_int(widget);
    self.settings.present.indent = true;
    self.savePreferences();
}
fn prefToggle(widget: ?*c.GtkCheckButton, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const key: [*:0]const u8 = @ptrCast(c.g_object_get_data(u.cast(c.GObject, widget.?), "coral-pref").?);
    inline for (.{ "lines", "wrap", "spaces", "spelling" }) |name| {
        if (std.mem.eql(u8, std.mem.span(key), name)) {
            @field(self.settings, name) = c.gtk_check_button_get_active(widget) != 0;
            if (comptime !std.mem.eql(u8, name, "spelling")) @field(self.settings.present, name) = true;
        }
    }
    self.savePreferences();
}
fn prefLanguage(widget: ?*c.GtkComboBox, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const id = c.gtk_combo_box_get_active_id(widget);
    if (id != null) {
        self.settings.setLanguage(std.mem.span(id));
        self.dictionary = std.mem.span(id).len > 0;
        self.savePreferences();
    }
}
fn prefDocument(widget: ?*c.GtkCheckButton, data: ?*anyopaque) callconv(.c) void {
    const d = u.cast(Document, data.?);
    d.spell_override = c.gtk_check_button_get_active(widget) != 0;
    owner(d).resetSpelling();
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
    const text = u.bufferText(d.buffer);
    defer a.free(text);
    var byte_cursor: usize = 0;
    var char_cursor: c_int = 0;
    const from = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&start));
    const to = byteOffset(text, &byte_cursor, &char_cursor, c.gtk_text_iter_get_offset(&end));
    const revision = self.menu_revision;
    self.hidePopover();
    self.applyEdits(d, revision, &.{.{ .start = from, .end = to, .text = word }});
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
    const widget = self.activeWidget() orelse return;
    const action: [*:0]const u8 = @ptrCast(c.g_object_get_data(u.cast(c.GObject, button.?), "edit-action").?);
    _ = c.gtk_widget_activate_action_variant(widget, action, null);
    self.hidePopover();
}
fn onAction(action: ?*c.GSimpleAction, _: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
    const self = u.cast(App, data.?);
    const name = std.mem.span(c.g_action_get_name(u.cast(c.GAction, action.?)));
    if (commands.fromAction(name)) |command| self.execute(command);
}
fn presentWorkspaceSearch(self: *App, mode: @import("workspace/search.zig").Mode) void {
    if (mode == .quick_open) self.dock.presentPicker() else {
        self.dock.dismissPicker();
        self.dock.show(.search);
    }
}
fn dismissWorkspaceSearch(self: *App, cancelled: bool) void {
    if (self.closing) return;
    if (self.dock.picking) self.dock.dismissPicker() else if (cancelled) self.dock.hide(.search);
    if (cancelled) self.focusEditor();
}
fn paletteCommand(context: *anyopaque, command: commands.Command) void {
    u.cast(App, context).execute(command);
}
fn paletteClosed(context: *anyopaque) void {
    const self = u.cast(App, context);
    if (self.palette) |palette| self.disconnectCallbacks(palette.window);
    self.palette = null;
    const previous = c.g_weak_ref_get(&self.palette_focus);
    defer if (previous) |object| c.g_object_unref(object);
    c.g_weak_ref_set(&self.palette_focus, null);
    if (self.closing) return;
    if (previous) |object| {
        const widget = u.cast(c.GtkWidget, object);
        if (c.gtk_widget_get_root(widget) == u.cast(c.GtkRoot, self.window) and c.gtk_widget_is_visible(widget) != 0 and c.gtk_widget_is_sensitive(widget) != 0) {
            if (c.gtk_widget_grab_focus(widget) != 0) return;
        }
    }
    if (self.activeFocusWidget()) |widget| _ = c.gtk_widget_grab_focus(widget);
}
fn onTestKey(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, data.?);
    if (!test_hooks or self.closing) return 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    if (key == c.GDK_KEY_F11) {
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
    return 0;
}
fn onShortcut(controller: ?*c.GtkEventControllerKey, key: c_uint, code: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    if (onTestKey(controller, key, code, state, data) != 0) return 1;
    const self = u.cast(App, data.?);
    if (self.closing or self.dialog != null or self.palette != null) return 0;
    if (commands.fromKey(key, state)) |command| {
        self.execute(command);
        return 1;
    }
    return 0;
}
fn onKey(_: ?*c.GtkEventControllerKey, key: c_uint, _: c_uint, state: c.GdkModifierType, data: ?*anyopaque) callconv(.c) c_int {
    const self = u.cast(App, data.?);
    if (self.editingFrozen()) return 0;
    if (self.closing or self.dialog != null or self.palette != null) return 0;
    const ctrl = state & c.GDK_CONTROL_MASK != 0;
    const shift = state & c.GDK_SHIFT_MASK != 0;
    if (key == c.GDK_KEY_Escape) {
        if (self.dock.picking or dock_ui.inside(c.gtk_window_get_focus(u.cast(c.GtkWindow, self.window)), self.dock.search_slot)) {
            self.workspace_search.hide();
            return 1;
        }
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
            c.GDK_KEY_plus, c.GDK_KEY_equal, c.GDK_KEY_minus, c.GDK_KEY_0 => {
                self.settings.font = if (key == c.GDK_KEY_0) 14 else std.math.clamp(self.settings.font + if (key == c.GDK_KEY_minus) @as(c_int, -1) else 1, 8, 32);
                self.applySettings();
                self.savePreferences();
            },
            c.GDK_KEY_z, c.GDK_KEY_Z, c.GDK_KEY_y => {
                if (self.active()) |d| {
                    if (d.loading or d.pending != null) return 1;
                    if (c.gtk_window_get_focus(u.cast(c.GtkWindow, self.window)) != self.activeWidget()) return 0;
                    self.undo(shift or key == c.GDK_KEY_y);
                }
            },

            else => return 0,
        }
        return 1;
    }
    if (key == c.GDK_KEY_F3) {
        self.findMatch(shift);
        return 1;
    }

    return 0;
}
fn testKeys(self: *App, widget: W) void {
    if (!test_hooks) return;
    if (c.g_object_get_data(u.cast(c.GObject, widget), "coral-test-keys") != null) return;
    c.g_object_set_data(u.cast(c.GObject, widget), "coral-test-keys", self);
    const keys = c.gtk_event_controller_key_new().?;
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    u.connect(keys, "key-pressed", &onTestKey, self);
    c.gtk_widget_add_controller(widget, keys);
}
fn testCommand(receiver: *App) void {
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
    // Test-only routing by registry identity, never GtkApplication.active-window.
    const targeted = c.g_key_file_has_key(file, "Test", "window", null) != 0;
    var target_error: ?*c.GError = null;
    const target_window = if (targeted) c.g_key_file_get_uint64(file, "Test", "window", &target_error) else 0;
    if (target_error) |err| {
        c.g_error_free(err);
        c.g_print("CORAL_COMMAND_REJECTED invalid-window\nCORAL_COMMAND_DONE\n");
        return;
    }
    const self = if (!targeted) receiver else if (receiver.manager) |manager| manager.find(target_window) orelse {
        c.g_print("CORAL_COMMAND_REJECTED unknown-window\nCORAL_COMMAND_DONE\n");
        return;
    } else return;
    if (std.mem.eql(u8, action, "windows-probe")) {
        if (self.manager) |manager| manager.probe();
        c.g_print("CORAL_COMMAND_DONE\n");
        return;
    }
    if (self.closing) {
        c.g_print("CORAL_COMMAND_REJECTED closing-window\nCORAL_COMMAND_DONE\n");
        return;
    }

    const value = c.g_key_file_get_string(file, "Test", "value", null);
    defer c.g_free(value);
    const d = self.active();
    if (std.mem.eql(u8, action, "project-probe") or std.mem.eql(u8, action, "projects-probe")) {
        self.projects.probe();
    } else if (std.mem.eql(u8, action, "project-insert-canonical")) {
        // Fault injection: bypass the read-only view bridge to test the final
        // close revision guard against an unexpected canonical-buffer writer.
        if (value != null) if (d) |doc| c.gtk_text_buffer_insert_at_cursor(doc.buffer, value, -1);
    } else if (std.mem.eql(u8, action, "lifecycle-probe")) {
        var full_editable: usize = 0;
        var excerpts_editable: usize = 0;
        for (self.views.items) |view| if (c.gtk_text_view_get_editable(u.cast(c.GtkTextView, view.widget)) != 0) {
            full_editable += 1;
        };
        for (self.excerpts.items) |pane| if (c.gtk_text_view_get_editable(u.cast(c.GtkTextView, pane.editor.widget)) != 0) {
            excerpts_editable += 1;
        };
        const json = std.json.Stringify.valueAlloc(a, .{ .window = self.window_id, .frozen = self.editingFrozen(), .quitting = self.quitting, .dialog = if (self.dialog != null) @as(?DialogKind, self.dialog_kind) else null, .documents = self.snapshotDocuments().len, .full_editable = full_editable, .excerpts_editable = excerpts_editable, .full_views = self.views.items.len, .excerpt_views = self.excerpts.items.len, .active_revision = if (d) |doc| @as(?u64, doc.revision) else null, .active_dirty = if (d) |doc| doc.dirty() else false, .recovery_claimed = self.recovery_claimed, .notice = std.mem.span(c.gtk_label_get_text(u.cast(c.GtkLabel, self.notice))) }, .{}) catch return;
        defer a.free(json);
        const line = u.z(json);
        defer a.free(line);
        c.g_print("CORAL_LIFECYCLE %s\n", line.ptr);
    } else if (std.mem.eql(u8, action, "project-refresh")) {
        self.projects.refresh();
    } else if (std.mem.eql(u8, action, "project-checkpoint")) {
        self.projects.checkpoint();
    } else if (std.mem.eql(u8, action, "project-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.projects.test_next_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "project-open")) {
        if (value != null) if (self.projects.targetFromText(std.mem.span(value))) |target| self.projects.open(target);
    } else if (std.mem.eql(u8, action, "project-forget")) {
        if (value != null) {
            if (std.mem.eql(u8, std.mem.span(value), "accept")) self.projects.confirmForget(true) else if (std.mem.eql(u8, std.mem.span(value), "cancel")) self.projects.confirmForget(false) else if (self.projects.targetFromText(std.mem.span(value))) |target| self.projects.requestForget(target);
        }
    } else if (std.mem.eql(u8, action, "project-respond")) {
        self.projects.confirmForget(value != null and std.mem.eql(u8, std.mem.span(value), "accept"));
    } else if (std.mem.eql(u8, action, "picker-probe")) {
        self.projects.pickerProbe();
    } else if (std.mem.eql(u8, action, "picker-show")) {
        if (value != null and std.mem.eql(u8, std.mem.span(value), "buffers")) self.projects.showBuffers() else self.projects.showProjects(value != null and std.mem.eql(u8, std.mem.span(value), "forget"));
    } else if (std.mem.eql(u8, action, "picker-query")) {
        if (self.projects.picker) |picker| if (value != null) picker.setFilter(std.mem.span(value)) catch |err| self.editFailure(err);
    } else if (std.mem.eql(u8, action, "picker-activate")) {
        if (self.projects.picker) |picker| picker.activate();
    } else if (std.mem.eql(u8, action, "picker-select")) {
        if (self.projects.picker) |picker| if (value != null) {
            _ = picker.select(std.fmt.parseInt(usize, std.mem.span(value), 10) catch 0);
        };
    } else if (std.mem.eql(u8, action, "roots-probe")) {
        self.workspace_roots.probe();
    } else if (std.mem.eql(u8, action, "roots-request")) {
        if (value != null) if (std.meta.stringToEnum(@import("workspace/roots_controller.zig").Kind, std.mem.span(value))) |kind| {
            const root_path = c.g_key_file_get_string(file, "Test", "path", null);
            defer c.g_free(root_path);
            self.workspace_roots.testRequest(kind, if (root_path != null) std.mem.span(root_path) else "");
        };
    } else if (std.mem.eql(u8, action, "roots-respond")) {
        self.workspace_roots.respond(value != null and std.mem.eql(u8, std.mem.span(value), "accept"));
    } else if (std.mem.eql(u8, action, "roots-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_roots.test_next_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "operations-probe")) {
        self.workspace_operations.probe();
    } else if (std.mem.eql(u8, action, "operations-request")) {
        if (value != null) if (std.meta.stringToEnum(@import("workspace/operations_fs.zig").Kind, std.mem.span(value))) |kind| {
            const source = c.g_key_file_get_string(file, "Test", "source", null);
            defer c.g_free(source);
            const destination = c.g_key_file_get_string(file, "Test", "destination", null);
            defer c.g_free(destination);
            const root = c.g_key_file_get_integer(file, "Test", "root", null);
            if (root >= 0) self.workspace_operations.testRequest(kind, @intCast(root), if (source != null) std.mem.span(source) else "", if (destination != null) std.mem.span(destination) else "");
        };
    } else if (std.mem.eql(u8, action, "operations-respond")) {
        self.workspace_operations.respond(value != null and std.mem.eql(u8, std.mem.span(value), "accept"));
    } else if (std.mem.eql(u8, action, "operations-input")) {
        if (self.workspace_operations.entry) |entry| if (value != null) c.gtk_editable_set_text(u.cast(c.GtkEditable, entry), value);
        if (self.workspace_operations.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_ACCEPT);
    } else if (std.mem.eql(u8, action, "operations-cancel")) {
        if (self.workspace_operations.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
    } else if (std.mem.eql(u8, action, "operations-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_operations.test_next_delay_us = @as(u64, @min(delay, 2000)) * 1000;
    } else if (std.mem.eql(u8, action, "dock-probe")) {
        self.dock.probe(self.window);
    } else if (std.mem.eql(u8, action, "dock-resize")) {
        if (value != null) if (std.meta.stringToEnum(dock_layout.Dock, std.mem.span(value))) |side| {
            const size = c.g_key_file_get_integer(file, "Test", "size", null);
            self.dock.resize(side, @intCast(std.math.clamp(size, 0, 65535)));
        };
    } else if (std.mem.eql(u8, action, "window-resize")) {
        const width = c.g_key_file_get_integer(file, "Test", "width", null);
        const height = c.g_key_file_get_integer(file, "Test", "height", null);
        c.gtk_window_set_default_size(u.cast(c.GtkWindow, self.window), std.math.clamp(width, 320, 4096), std.math.clamp(height, 240, 2160));
    } else if (std.mem.eql(u8, action, "session-probe")) {
        self.session.probe();
    } else if (std.mem.eql(u8, action, "session-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.session.test_next_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "policy-probe")) {
        self.workspace_policy.probe();
    } else if (std.mem.eql(u8, action, "policy-show")) {
        self.showPolicy(false);
    } else if (std.mem.eql(u8, action, "policy-trust-confirm")) {
        self.showPolicy(true);
    } else if (std.mem.eql(u8, action, "policy-revoke")) {
        self.workspace_policy.revoke();
    } else if (std.mem.eql(u8, action, "policy-recheck")) {
        self.workspace_policy.recheck();
    } else if (std.mem.eql(u8, action, "policy-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_policy.test_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "policy-delivery-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_policy.test_delivery_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "policy-fail-write")) {
        self.workspace_policy.test_fail_write = true;
    } else if (std.mem.eql(u8, action, "policy-gate")) {
        self.workspace_policy.fixtureGate();
    } else if (std.mem.eql(u8, action, "policy-checks")) {
        self.workspace_policy.fixtureCheck() catch |err| {
            const name = u.z(@errorName(err));
            defer a.free(name);
            c.g_print("CORAL_POLICY_CHECKS error=%s\n", name.ptr);
            return;
        };
        c.g_print("CORAL_POLICY_CHECKS ok=1\n");
    } else if (std.mem.eql(u8, action, "policy-user")) {
        // Exercise explicit-default presence independently of repository values.
        inline for (.{ "lines", "wrap", "spaces" }) |key| {
            if (c.g_key_file_has_key(file, "Test", key, null) != 0) {
                @field(self.settings, key) = c.g_key_file_get_boolean(file, "Test", key, null) != 0;
                @field(self.settings.present, key) = true;
            }
        }
        if (c.g_key_file_has_key(file, "Test", "indent", null) != 0) {
            self.settings.indent = std.math.clamp(c.g_key_file_get_integer(file, "Test", "indent", null), 1, 8);
            self.settings.present.indent = true;
        }
        self.applySettings();
        self.savePreferences();
    } else if (std.mem.eql(u8, action, "policy-language")) {
        if (d) |doc| {
            const lang = if (value != null) c.gtk_source_language_manager_get_language(c.gtk_source_language_manager_get_default(), value) else null;
            self.setDocumentLanguage(doc, lang);
        }
    } else if (std.mem.eql(u8, action, "respond")) {
        if (self.dialog) |dialog| c.gtk_dialog_response(u.cast(c.GtkDialog, dialog), c.g_key_file_get_integer(file, "Test", "response", null));
    } else if (std.mem.eql(u8, action, "save-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u32, std.mem.span(value), 10) catch 0 else 0;
        self.test_save_delay_ms = @min(delay, 5000);
    } else if (std.mem.eql(u8, action, "save-path")) {
        if (d) |doc| {
            if (value != null) self.saveTo(doc, std.mem.span(value), false, true);
        }
    } else if (std.mem.eql(u8, action, "save-race")) {
        if (d) |doc| {
            self.save(doc, false, false);
            c.gtk_text_buffer_insert_at_cursor(doc.buffer, " plus", 5);
        }
    } else if (std.mem.eql(u8, action, "save-undo-race")) {
        if (d) |doc| {
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_end_iter(doc.buffer, &end);
            c.gtk_text_buffer_begin_user_action(doc.buffer);
            c.gtk_text_buffer_insert(doc.buffer, &end, " pending", 8);
            c.gtk_text_buffer_end_user_action(doc.buffer);
            self.save(doc, false, false);
            self.undo(false);
        }
    } else if (std.mem.eql(u8, action, "save-cancel")) {
        if (d) |doc| {
            self.save(doc, false, false);
            if (doc.cancellable) |cancel| c.g_cancellable_cancel(cancel);
        }
    } else if (std.mem.eql(u8, action, "open")) {
        if (value != null) self.openExisting(std.mem.span(value), null);
    } else if (std.mem.eql(u8, action, "open-folder")) {
        if (value != null) self.browser.load(.folder, std.mem.span(value)) else self.execute(.open_folder);
    } else if (std.mem.eql(u8, action, "open-workspace")) {
        if (value != null) self.browser.load(.manifest, std.mem.span(value)) else self.execute(.open_workspace);
    } else if (std.mem.eql(u8, action, "search-query")) {
        const mode = c.g_key_file_get_string(file, "Test", "mode", null);
        defer c.g_free(mode);
        self.workspace_search.setQuery(if (mode != null and std.mem.eql(u8, std.mem.span(mode), "text")) .text else .quick_open, if (value != null) std.mem.span(value) else "");
    } else if (std.mem.eql(u8, action, "search-probe")) {
        self.workspace_search.probe();
    } else if (std.mem.eql(u8, action, "search-activate")) {
        const index = c.g_key_file_get_integer(file, "Test", "index", null);
        if (index >= 0) self.workspace_search.activate(@intCast(index));
    } else if (std.mem.eql(u8, action, "search-refresh")) {
        self.workspace_search.refresh();
    } else if (std.mem.eql(u8, action, "search-cancel")) {
        self.workspace_search.invalidate("Search cancelled by request. Refresh to restart.");
    } else if (std.mem.eql(u8, action, "search-routing-checks")) {
        const checks = @import("workspace/search_controller.zig");
        const outcome: ?anyerror = blk: {
            checks.validateStreamingNavigationGtk() catch |err| break :blk err;
            checks.validateActivationRoutingGtk() catch |err| break :blk err;
            checks.validateReloadRoutingGtk() catch |err| break :blk err;
            break :blk null;
        };
        if (outcome) |err| {
            const name = u.z(@errorName(err));
            defer a.free(name);
            c.g_print("CORAL_SEARCH_ROUTING_CHECKS error=%s\n", name.ptr);
        } else c.g_print("CORAL_SEARCH_ROUTING_CHECKS ok=1\n");
    } else if (std.mem.eql(u8, action, "search-activation-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_search.test_activation_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "search-activation-fail")) {
        self.workspace_search.test_activation_fail = true;
    } else if (std.mem.eql(u8, action, "search-delay")) {
        const delay = if (value != null) std.fmt.parseInt(u64, std.mem.span(value), 10) catch 0 else 0;
        self.workspace_search.test_delay_us = @as(u64, @min(delay, 5000)) * 1000;
    } else if (std.mem.eql(u8, action, "browser-probe")) {
        self.browser.probe();
    } else if (std.mem.eql(u8, action, "browser-browse-relative")) {
        if (value != null) if (self.browser.model) |*snapshot| if (snapshot.roots.len > 0) self.browser.browse(snapshot.roots[0].id, std.mem.span(value));
    } else if (std.mem.startsWith(u8, action, "budget-")) {
        // All burst submissions happen within one GTK dispatch. Delayed workers
        // retain their holds even when cancelled; the immediate probe is exact.
        const snapshot = if (self.browser.model) |*m| m else return;
        if (snapshot.roots.len == 0 or value == null) return;
        const id = snapshot.roots[0].id;
        const burst_path = std.mem.span(value);
        const base = snapshot.roots[0].canonical_path.?;
        if (std.mem.eql(u8, action, "budget-chooser") or std.mem.eql(u8, action, "budget-mixed")) self.browser.choose(.folder);
        for (0..64) |i| {
            self.browser.test_next_delay_us = 500000;
            if (std.mem.eql(u8, action, "budget-load")) {
                if (i < @import("workspace/controller.zig").limits.in_flight) self.browser.load(.manifest, burst_path) else self.browser.load(.folder, "/");
            } else if (std.mem.eql(u8, action, "budget-scan")) {
                const target = u.fmt("budget-missing-{d}", .{i});
                defer a.free(target);
                self.browser.browse(id, if (i < 7) target else if (i == 7) "nested" else "not-accepted");
            } else if (std.mem.eql(u8, action, "budget-files")) {
                const target = u.fmt("{s}/entry-{d:0>4}.txt", .{ burst_path, i });
                defer a.free(target);
                self.openExisting(target, null);
            } else if (std.mem.eql(u8, action, "budget-dedup")) {
                self.openExisting(burst_path, if (i % 2 == 0) id else null);
            } else if (std.mem.eql(u8, action, "budget-bytes")) {
                var target: [64 * 1024]u8 = @splat('x');
                target[0] = '/';
                target[target.len - 1] = @intCast('A' + i % 26);
                self.openExisting(&target, null);
            } else if (std.mem.eql(u8, action, "budget-chooser")) {
                self.browser.choose(.manifest);
            } else if (std.mem.eql(u8, action, "budget-mixed")) {
                switch (i % 3) {
                    0 => self.browser.load(.manifest, burst_path),
                    1 => self.browser.browse(id, ""),
                    else => {
                        const target = u.fmt("{s}/same.txt", .{base});
                        defer a.free(target);
                        self.openExisting(target, id);
                    },
                }
            }
        }
        self.browser.test_next_delay_us = 0;
        self.browser.probe();
        // This proves over-budget failures are visible before any completion.
        self.probeWorkspace();
    } else if (std.mem.eql(u8, action, "browser-activate")) {
        const index = c.g_key_file_get_integer(file, "Test", "index", null);
        if (index >= 0) self.browser.activate(@intCast(index));
    } else if (std.mem.eql(u8, action, "explorer-activate")) {
        const index = c.g_key_file_get_integer(file, "Test", "index", null);
        if (index >= 0) c.g_signal_emit_by_name(self.browser.rows, "activate", @as(c_uint, @intCast(index)));
    } else if (std.mem.eql(u8, action, "browser-more")) {
        self.browser.more();
    } else if (std.mem.eql(u8, action, "explorer-drain")) {
        self.browser.test_drain = true;
    } else if (std.mem.eql(u8, action, "explorer-overflow")) {
        const Watch = @import("workspace/explorer_watch.zig");
        const event: Watch.Event = .{ .wd = -1, .mask = std.os.linux.IN.Q_OVERFLOW, .cookie = 0, .len = 0 };
        self.browser.watches.dispatch(std.mem.asBytes(&event));
    } else if (std.mem.eql(u8, action, "explorer-reset")) {
        self.browser.resetTree();
    } else if (std.mem.eql(u8, action, "explorer-watch-fail")) {
        self.browser.watches.disabled = true;
        self.browser.rescan();
    } else if (std.mem.eql(u8, action, "explorer-watch-restore")) {
        self.browser.watches.disabled = false;
        self.browser.rescan();
    } else if (std.mem.eql(u8, action, "explorer-watch-delay")) {
        const milliseconds = if (value != null) std.fmt.parseInt(c_ulong, std.mem.span(value), 10) catch 750 else 750;
        self.browser.watches.test_delay_us = @as(c_ulong, @min(milliseconds, 2000)) * 1000;
    } else if (std.mem.eql(u8, action, "explorer-watch-storm")) {
        self.browser.testWatchStorm();
    } else if (std.mem.eql(u8, action, "explorer-delay")) {
        self.browser.test_next_delay_us = 500000;
    } else if (std.mem.eql(u8, action, "browser-close-race")) {
        self.browser.test_next_delay_us = 500000;
        if (self.browser.model) |*snapshot| if (snapshot.roots.len > 0) self.browser.browse(snapshot.roots[0].id, "");
        self.browser.closeWorkspace();
    } else if (std.mem.eql(u8, action, "browser-swap-race")) {
        self.browser.test_next_delay_us = 500000;
        if (self.browser.model) |*snapshot| if (snapshot.roots.len > 0) self.browser.browse(snapshot.roots[0].id, "");
        if (value != null) self.browser.load(.manifest, std.mem.span(value));
    } else if (std.mem.eql(u8, action, "browser-file-close-race")) {
        self.browser.test_next_delay_us = 500000;
        if (value != null) if (self.browser.model) |*snapshot| if (snapshot.roots.len > 0) self.openExisting(std.mem.span(value), snapshot.roots[0].id);
        self.browser.closeWorkspace();
    } else if (std.mem.eql(u8, action, "workspace-quit-race")) {
        self.browser.test_next_delay_us = 500000;
        if (value != null) self.browser.load(.manifest, std.mem.span(value));
        self.execute(.quit);
    } else if (std.mem.eql(u8, action, "browser-open-path")) {
        if (value != null) if (self.browser.model) |*snapshot| if (snapshot.roots.len > 0) self.openExisting(std.mem.span(value), snapshot.roots[0].id);
    } else if (std.mem.eql(u8, action, "workspace-race")) {
        if (value != null) {
            self.browser.test_next_delay_us = 500000;
            self.browser.load(.folder, "/");
            self.browser.load(.manifest, std.mem.span(value));
        }
    } else if (std.mem.eql(u8, action, "reload")) {
        self.execute(.reload);
    } else if (std.mem.eql(u8, action, "reload-race")) {
        if (d) |doc| {
            self.load(doc, true);
            c.gtk_text_buffer_insert_at_cursor(doc.buffer, " plus", 5);
        }
    } else if (std.mem.eql(u8, action, "edit-pending-load")) {
        if (d) |doc| {
            if (doc.pending != null) c.gtk_text_buffer_insert_at_cursor(doc.buffer, " plus", 5);
        }
    } else if (std.mem.eql(u8, action, "watch-close")) {
        if (d) |doc| {
            self.queryDisk(doc);
            self.queryDisk(doc);
            self.queryDisk(doc);
            std.debug.assert(doc.watch_query != null and doc.watch_pending);
            self.closeDocument(doc);
        }
    } else if (std.mem.eql(u8, action, "watch-save-as")) {
        if (d) |doc| {
            if (value != null) {
                self.queryDisk(doc);
                std.debug.assert(doc.watch_query != null);
                self.saveTo(doc, std.mem.span(value), false, true);
            }
        }
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
        self.savePreferences();
    } else if (std.mem.eql(u8, action, "language")) {
        if (value != null) {
            self.settings.setLanguage(std.mem.span(value));
            self.dictionary = std.mem.span(value).len > 0;
            self.resetSpelling();
            self.savePreferences();
        }
    } else if (std.mem.eql(u8, action, "replace-all")) {
        if (value != null) c.gtk_editable_set_text(u.cast(c.GtkEditable, self.replacement), value);
        self.replace(true);
    } else if (std.mem.eql(u8, action, "cancel-io")) {
        if (d) |doc| if (doc.cancellable) |cancel| c.g_cancellable_cancel(cancel);
    } else if (std.mem.eql(u8, action, "guard-offset")) {
        const guard = if (self.activeView()) |view| view.layout_guard else if (self.activeExcerpt()) |pane| pane.editor.layout_guard else null;
        if (guard) |g| {
            c.gtk_spin_button_set_value(g.offset, @floatFromInt(c.g_key_file_get_integer(file, "Test", "offset", null)));
            _ = c.gtk_widget_grab_focus(g.button);
        }
    } else if (std.mem.eql(u8, action, "workspace-probe")) {
        self.probeWorkspace();
    } else if (std.mem.eql(u8, action, "observe-checkpoints")) {
        if (self.recovery_checkpoint == null) self.recovery_checkpoint = &testCheckpoint;
    } else if (std.mem.eql(u8, action, "checkpoint")) {
        self.checkpoint();
    } else if (std.mem.eql(u8, action, "restore-copy")) {
        if (d) |doc| {
            const states = self.snapshotViews(a) catch return;
            defer a.free(states);
            const text = u.bufferText(doc.buffer);
            defer a.free(text);
            const copy = self.restoreDocument(.{ .text = text, .dirty = true, .bom = doc.bom, .newline = doc.newline }) catch |err| {
                self.editFailure(err);
                return;
            };
            const group = self.createGroup() catch return;
            for (states) |state| if (state.document_id == doc.id) {
                _ = self.restoreView(copy, group, state) catch |err| self.editFailure(err);
            };
        }
    } else if (std.mem.eql(u8, action, "focus-group")) {
        const index = c.g_key_file_get_integer(file, "Test", "index", null);
        if (index >= 0 and index < self.groups.items.items.len) self.focusGroup(self.groups.items.items[@intCast(index)].id);
    } else if (std.mem.eql(u8, action, "focus-view")) {
        const index = c.g_key_file_get_integer(file, "Test", "index", null);
        const states = self.snapshotViews(a) catch return;
        defer a.free(states);
        if (index >= 0 and index < states.len) self.restoreFocus(states[@intCast(index)].id);
    } else if (std.mem.eql(u8, action, "scroll")) {
        if (self.activeWidget()) |widget| {
            c.gtk_adjustment_set_value(c.gtk_scrollable_get_vadjustment(u.cast(c.GtkScrollable, widget)), @floatFromInt(c.g_key_file_get_integer(file, "Test", "y", null)));
        }
    } else if (std.mem.eql(u8, action, "select")) {
        if (self.activeBuffer()) |buffer| {
            var start: c.GtkTextIter = undefined;
            var end: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_iter_at_offset(buffer, &start, c.g_key_file_get_integer(file, "Test", "start", null));
            c.gtk_text_buffer_get_iter_at_offset(buffer, &end, c.g_key_file_get_integer(file, "Test", "end", null));
            c.gtk_text_buffer_select_range(buffer, &start, &end);
        }
    } else if (std.mem.eql(u8, action, "insert")) {
        if (value != null) if (self.activeBuffer()) |buffer| {
            c.gtk_text_buffer_begin_user_action(buffer);
            c.gtk_text_buffer_insert_at_cursor(buffer, value, -1);
            c.gtk_text_buffer_end_user_action(buffer);
        };
    } else if (std.mem.eql(u8, action, "undo")) {
        self.undo(false);
    } else if (std.mem.eql(u8, action, "redo")) {
        self.undo(true);
    } else if (std.mem.eql(u8, action, "grouped-append")) {
        if (value != null) {
            const n = self.documents.entries.items.len;
            const changes = a.alloc(transactions.Change, n) catch return;
            defer a.free(changes);
            const edits = a.alloc(transactions.Replacement, n) catch return;
            defer a.free(edits);
            for (self.documents.entries.items, changes, edits) |doc, *change, *edit| {
                const text = u.bufferText(doc.buffer);
                defer a.free(text);
                edit.* = .{ .start = text.len, .end = text.len, .text = std.mem.span(value) };
                change.* = .{ .target = editTarget(doc, doc.revision), .replacements = @as([*]transactions.Replacement, @ptrCast(edit))[0..1] };
            }
            self.performGrouped("Native grouped edit", changes) catch |err| self.editFailure(err);
        }
    } else if (commands.fromAction(action)) |command| {
        self.execute(command);
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
