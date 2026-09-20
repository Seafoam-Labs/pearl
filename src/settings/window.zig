//! Ordinary GTK application window. Page bodies own their scroll/focus; host
//! chrome owns navigation, status and footer. No layer-shell or service objects.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const nav = @import("../desktop/settings_navigation.zig");
const w = @import("../ui/components/widgets.zig");
const theme = @import("../theme/theme.zig");
const appearance = @import("appearance.zig");
const a = std.heap.c_allocator;
const count = std.enums.values(nav.Route).len;
const Page = struct { scroll: *gtk.ScrolledWindow, body: *gtk.Widget, focus: ?*gtk.Widget = null };
const navigation_count = count + nav.aqueous_sections.len;
const Link = struct { owner: *Window, target: nav.Target, button: *gtk.ToggleButton };
const SectionState = struct { scroll: f64 = 0, focus: ?*gtk.Widget = null };
fn navigationIndex(route: nav.Route) usize {
    const index = @intFromEnum(route);
    return index + @as(usize, if (index > @intFromEnum(nav.Route.aqueous)) nav.aqueous_sections.len else 0);
}
pub const Window = struct {
    window: *gtk.Window,
    root: *gtk.Box,
    sidebar: *gtk.ScrolledWindow,
    sections: *gtk.MenuButton,
    popover: *gtk.Popover,
    popup_scroll: *gtk.ScrolledWindow,
    heading: *gtk.Label,
    heading_anchor: *gtk.Widget,
    aqueous_section: usize = 0,
    pending_aqueous_selection: ?@import("editor.zig").Selection = null,
    subtitle: *gtk.Label,
    stack: *gtk.Stack,
    footer: *gtk.Box,
    footer_text: *gtk.Label,
    save: *gtk.Button,
    merge_button: *gtk.Button,
    actions: *gtk.Box,
    draft_badge: *gtk.Label,
    editor: *@import("editor.zig").Editor,
    aqueous: *@import("aqueous_editor.zig").Editor,
    aqueous_view: ?*@import("../desktop/aqueous_settings.zig").ViewFor(@import("aqueous_editor.zig").Editor) = null,
    aqueous_footer: *gtk.Box,
    review_button: *gtk.Button,
    plugins_view: ?*@import("plugins_view.zig").View = null,
    preferences_view: ?*@import("preferences_view.zig").View = null,
    preference_pages: [2]?*@import("preference_pages.zig").View = .{ null, null },
    live_pages: [count]?*@import("live_view.zig").View = @splat(null),
    close_dialog: ?*gtk.Dialog = null,
    saved_dialog: ?*gtk.Dialog = null,
    saved_button: *gtk.Button,
    font_size: u8 = 14,
    discard: *gtk.Button,
    retry_button: *gtk.Button,
    status: *gtk.Label,
    aqueous_context: *gtk.Label,
    display_count: *gtk.Label,
    aqueous_states: [nav.aqueous_sections.len]SectionState = @splat(.{}),
    aqueous_rebuilding: bool = false,
    display_focus_id: [64]u8 = @splat(0),
    keep_sections_open: bool = false,
    navigation_signals: [2]c_ulong = @splat(0),
    navigation_reveal_id: c_uint = 0,
    pages: [count]Page = undefined,
    links: [2 * navigation_count]Link = undefined,
    target: nav.Target = .{},
    arena: std.heap.ArenaAllocator,
    css: *gtk.CssProvider,
    native_css: *gtk.CssProvider,
    font_css: *gtk.CssProvider,
    context: *anyopaque,
    retry: *const fn (*anyopaque) void,
    close: *const fn (*anyopaque) void,
    connected: bool = false,
    fixture: bool,
    narrow: bool = false,
    changing: bool = false,
    german: bool,
    styled_revision: ?u64 = null,
    style_mode: []const u8 = "dark",
    appearance_updates: u64 = 0,
    activation_contexts: u64 = 0,
    key_events: u64 = 0,
    layout_id: c_ulong = 0,
    native: ?*gdk.Surface = null,
    resize_id: c_uint = 0,
    restore_id: c_uint = 0,
    pub fn create(app: *gtk.Application, context: *anyopaque, retry: @FieldType(Window, "retry"), close: @FieldType(Window, "close"), fixture: bool, editor: *@import("editor.zig").Editor, aqueous: *@import("aqueous_editor.zig").Editor) !*Window {
        const self = try a.create(Window);
        const win = gtk.ApplicationWindow.new(app).as(gtk.Window);
        _ = win.ref();
        const root = w.column(0);
        const header = gtk.HeaderBar.new();
        header.setShowTitleButtons(1);
        header.setDecorationLayout("menu:minimize,maximize,close");
        const brand = w.row(10);
        const pearl = w.label("●", "settings-pearl");
        pearl.as(gtk.Widget).setHexpand(0);
        brand.append(pearl.as(gtk.Widget));
        const locale = if (glib.getenv("LANG")) |v| std.mem.span(v) else "";
        const german = std.mem.startsWith(u8, locale, "de");
        const brand_name = w.label(if (german) "Pearl Einstellungen" else "Pearl Settings", "settings-brand");
        brand_name.as(gtk.Widget).setHexpand(0);
        brand_name.setWrap(0);
        brand.append(brand_name.as(gtk.Widget));
        header.packStart(brand.as(gtk.Widget));
        header.setTitleWidget(gtk.Box.new(.horizontal, 0).as(gtk.Widget));
        const sections = gtk.MenuButton.new();
        sections.setLabel(if (german) "Bereiche" else "Sections");
        header.packEnd(sections.as(gtk.Widget));
        const popover = gtk.Popover.new();
        sections.setPopover(popover);
        const layout = w.row(0);
        layout.as(gtk.Widget).setVexpand(1);
        const sidebar = gtk.ScrolledWindow.new();
        sidebar.setPolicy(.never, .automatic);
        sidebar.as(gtk.Widget).setSizeRequest(220, -1);
        sidebar.as(gtk.Widget).setHexpand(0);
        sidebar.as(gtk.Widget).addCssClass("settings-sidebar");
        // Begin compact so the first minimum-size hint fits narrow placement.
        // The first surface allocation reveals the sidebar on wide windows.
        sidebar.as(gtk.Widget).setVisible(0);
        const popup_scroll = gtk.ScrolledWindow.new();
        popup_scroll.setPolicy(.never, .automatic);
        popup_scroll.as(gtk.Widget).setSizeRequest(240, -1);
        popover.setChild(popup_scroll.as(gtk.Widget));
        layout.append(sidebar.as(gtk.Widget));
        const main = w.column(0);
        main.as(gtk.Widget).setHexpand(1);
        main.as(gtk.Widget).setVexpand(1);
        const page_header = w.column(7);
        page_header.as(gtk.Widget).addCssClass("settings-page-header");
        const heading = w.label("", "settings-heading");
        heading.as(object.Object).set("accessible-role", @intFromEnum(gtk.AccessibleRole.heading), @as(?[*:0]const u8, null));
        heading.as(gtk.Accessible).updateProperty(.level, @as(c_int, 1), @as(c_int, -1));
        page_header.as(gtk.Widget).setFocusable(1);
        const subtitle = w.label("", "pearl-secondary");
        const aqueous_context = w.label("Aqueous", "pearl-secondary");
        page_header.append(aqueous_context.as(gtk.Widget));
        const heading_row = w.row(16);
        const display_count = w.label("", "pearl-secondary");
        display_count.as(gtk.Widget).setHexpand(0);
        display_count.as(gtk.Widget).setHalign(.end);
        display_count.as(gtk.Widget).setValign(.center);
        display_count.as(gtk.Widget).setVisible(0);
        display_count.setMaxWidthChars(22);
        heading_row.append(heading.as(gtk.Widget));
        heading_row.append(display_count.as(gtk.Widget));
        page_header.append(heading_row.as(gtk.Widget));
        page_header.append(subtitle.as(gtk.Widget));
        const saved_button = w.wrappingButton(if (german) "Gespeichertes JSON anzeigen" else "View saved JSON");
        saved_button.as(gtk.Widget).setHalign(.start);
        saved_button.as(gtk.Widget).setVisible(0);
        page_header.append(saved_button.as(gtk.Widget));
        main.append(page_header.as(gtk.Widget));
        const status_box = w.row(12);
        status_box.as(gtk.Widget).addCssClass("settings-status");
        const status = w.label("", "pearl-secondary");
        const retry_button = w.wrappingButton(if (german) "Erneut versuchen" else "Retry");
        status_box.append(status.as(gtk.Widget));
        status_box.append(retry_button.as(gtk.Widget));
        main.append(status_box.as(gtk.Widget));
        const stack = gtk.Stack.new();
        stack.setHhomogeneous(0);
        stack.setVhomogeneous(0);
        stack.setTransitionType(.none);
        stack.as(gtk.Widget).setVexpand(1);
        main.append(stack.as(gtk.Widget));
        const footer = w.column(8);
        footer.as(gtk.Widget).addCssClass("settings-footer");
        const footer_text = w.label("", "pearl-secondary");
        footer_text.setMaxWidthChars(38);
        const actions = w.row(8);
        actions.as(gtk.Widget).setHalign(.end);
        const discard = w.wrappingButton(if (german) "Verwerfen" else "Discard");
        const save = w.wrappingButton(if (german) "Anwenden und speichern" else "Apply & save");
        save.as(gtk.Widget).addCssClass("pearl-primary");
        const merge_button = w.wrappingButton(if (german) "Änderungen zusammenführen" else "Merge changes");
        if (!fixture) {
            discard.as(gtk.Widget).setSizeRequest(88, -1);
            save.as(gtk.Widget).setSizeRequest(116, -1);
            merge_button.as(gtk.Widget).setSizeRequest(116, -1);
        }
        actions.append(merge_button.as(gtk.Widget));
        merge_button.as(gtk.Widget).setVisible(0);
        actions.append(discard.as(gtk.Widget));
        actions.append(save.as(gtk.Widget));
        const footer_labels = w.column(4);
        const draft_badge = w.label(if (german) "Ungespeicherte Änderungen" else "Unsaved changes", "settings-draft-badge");
        draft_badge.as(gtk.Widget).setVisible(0);
        footer_labels.as(gtk.Widget).setHexpand(1);
        footer_labels.append(draft_badge.as(gtk.Widget));
        footer_labels.append(footer_text.as(gtk.Widget));
        footer.append(footer_labels.as(gtk.Widget));
        footer.append(actions.as(gtk.Widget));
        const review_button = gtk.Button.newWithLabel("Review drafts");
        review_button.as(gtk.Widget).setVisible(0);
        footer_labels.append(review_button.as(gtk.Widget));
        const aqueous_footer = w.column(6);
        aqueous_footer.as(gtk.Widget).setVisible(0);
        footer.append(aqueous_footer.as(gtk.Widget));
        main.append(footer.as(gtk.Widget));
        layout.append(main.as(gtk.Widget));
        root.append(layout.as(gtk.Widget));
        win.setTitle(if (german) "Pearl Einstellungen" else "Pearl Settings");
        win.setTitlebar(header.as(gtk.Widget));
        win.setChild(root.as(gtk.Widget));
        win.as(gtk.Widget).addCssClass("pearl-root");
        win.as(gtk.Widget).addCssClass("settings-window");
        win.as(gtk.Widget).addCssClass("settings-narrow");
        win.setDefaultSize(1040, 760);
        const display = win.as(gtk.Widget).getDisplay();
        const monitors = display.getMonitors();
        if (monitors.getNItems() > 0) {
            const monitor: *gdk.Monitor = @ptrCast(monitors.getItem(0).?);
            defer monitor.unref();
            var rect: gdk.Rectangle = undefined;
            monitor.getGeometry(&rect);
            win.setDefaultSize(@min(1040, @max(240, rect.f_width - 32)), @min(760, @max(200, rect.f_height - 64)));
        }
        self.* = .{ .aqueous = aqueous, .aqueous_footer = aqueous_footer, .review_button = review_button, .window = win, .root = root, .sidebar = sidebar, .sections = sections, .popover = popover, .popup_scroll = popup_scroll, .heading = heading, .heading_anchor = page_header.as(gtk.Widget), .subtitle = subtitle, .stack = stack, .footer = footer, .footer_text = footer_text, .save = save, .discard = discard, .merge_button = merge_button, .actions = actions, .draft_badge = draft_badge, .editor = editor, .saved_button = saved_button, .retry_button = retry_button, .status = status, .aqueous_context = aqueous_context, .display_count = display_count, .arena = .init(a), .context = context, .retry = retry, .close = close, .fixture = fixture, .narrow = true, .german = german, .css = gtk.CssProvider.new(), .native_css = gtk.CssProvider.new(), .font_css = gtk.CssProvider.new() };
        errdefer self.destroy();
        const navbox = self.navigation(0);
        sidebar.setChild(navbox.as(gtk.Widget));
        popup_scroll.setChild(self.navigation(1).as(gtk.Widget));
        for ([_]*gtk.ScrolledWindow{ sidebar, popup_scroll }, 0..) |scroll, i| {
            self.navigation_signals[i] = gtk.Adjustment.signals.changed.connect(scroll.getVadjustment(), *Window, navigationAllocated, self, .{});
        }
        for (std.enums.values(nav.Route)) |route| {
            const body = w.column(16);
            body.as(gtk.Widget).addCssClass("settings-body");
            body.as(gtk.Widget).setValign(.start);
            const scroll = gtk.ScrolledWindow.new();
            scroll.setPolicy(.never, .automatic);
            scroll.setChild(body.as(gtk.Widget));
            _ = stack.addNamed(scroll.as(gtk.Widget), route.id());
            self.pages[@intFromEnum(route)] = .{ .scroll = scroll, .body = body.as(gtk.Widget) };
            self.compose(route, body);
        }
        if (!fixture) {
            const appearance_page = &self.pages[@intFromEnum(nav.Route.appearance)];
            const appearance_body = object.ext.cast(gtk.Box, appearance_page.body).?;
            while (appearance_body.as(gtk.Widget).getFirstChild()) |child| appearance_body.remove(child);
            self.preferences_view = try @import("preferences_view.zig").View.create(win, appearance_body, editor, german);
            const advanced_page = &self.pages[@intFromEnum(nav.Route.advanced)];
            advanced_page.body = self.preferences_view.?.raw_view.as(gtk.Widget);
            advanced_page.scroll.setChild(advanced_page.body);
            for ([_]nav.Route{ .bar, .session }, 0..) |route, i| {
                const host = object.ext.cast(gtk.Box, self.pages[@intFromEnum(route)].body).?;
                while (host.as(gtk.Widget).getFirstChild()) |child| host.remove(child);
                self.preference_pages[i] = try @import("preference_pages.zig").View.create(host, editor, route == .session, self, invalidatePageFocus);
            }
        }
        if (!fixture) {
            const body = object.ext.cast(gtk.Box, self.pages[@intFromEnum(nav.Route.plugins)].body).?;
            while (body.as(gtk.Widget).getFirstChild()) |child| body.remove(child);
            self.plugins_view = try @import("plugins_view.zig").View.create(body, editor, self, invalidatePageFocus);
        }
        if (!fixture) for ([_]nav.Route{ .overview, .network, .bluetooth, .sound, .power, .notifications, .session }) |route| {
            const body = object.ext.cast(gtk.Box, self.pages[@intFromEnum(route)].body).?;
            if (route != .overview and route != .session) while (body.as(gtk.Widget).getFirstChild()) |child| {
                body.remove(child);
            };
            const host = w.column(12);
            body.append(host.as(gtk.Widget));
            self.live_pages[@intFromEnum(route)] = try @import("live_view.zig").View.create(host, win, editor, route, self, invalidatePageFocus);
        };
        if (!fixture) {
            const host = object.ext.cast(gtk.Box, self.pages[@intFromEnum(nav.Route.aqueous)].body).?;
            while (host.as(gtk.Widget).getFirstChild()) |child| host.remove(child);
            self.aqueous_view = try @import("../desktop/aqueous_settings.zig").ViewFor(@import("aqueous_editor.zig").Editor).createIn(host, aqueous, win, aqueous_footer);
            self.aqueous_view.?.rebuild_observer = .{ .context = self, .notify = aqueousRebuilt };
        }
        _ = gtk.Button.signals.clicked.connect(review_button, *Window, reviewClicked, self, .{});
        gtk.StyleContext.addProviderForDisplay(display, self.css.as(gtk.StyleProvider), 600);
        gtk.StyleContext.addProviderForDisplay(display, self.font_css.as(gtk.StyleProvider), 601);
        gtk.StyleContext.addProviderForDisplay(display, self.native_css.as(gtk.StyleProvider), 599);
        _ = gtk.Window.signals.close_request.connect(win, *Window, closing, self, .{});
        _ = object.Object.signals.notify.connect(win.as(object.Object), *Window, focusChanged, self, .{ .detail = "focus-widget" });
        _ = gtk.Button.signals.clicked.connect(retry_button, *Window, retryClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(save, *Window, applyClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(discard, *Window, discardClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(merge_button, *Window, mergeClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(saved_button, *Window, savedClicked, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, keyPressed, self, .{});
        win.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const popup_keys = gtk.EventControllerKey.new();
        popup_keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(popup_keys, *Window, keyPressed, self, .{});
        popover.as(gtk.Widget).addController(popup_keys.as(gtk.EventController));
        _ = gtk.Widget.signals.realize.connect(win.as(gtk.Widget), *Window, realized, self, .{});
        try self.style(.{});
        self.connection(false, null);
        self.select(.{}, true);
        return self;
    }
    pub fn destroy(self: *Window) void {
        if (self.navigation_reveal_id != 0) _ = glib.Source.remove(self.navigation_reveal_id);
        for ([_]*gtk.ScrolledWindow{ self.sidebar, self.popup_scroll }, self.navigation_signals) |scroll, signal| {
            if (signal != 0) object.signalHandlerDisconnect(scroll.getVadjustment().as(object.Object), signal);
        }
        if (self.saved_dialog) |dialog| {
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        if (self.close_dialog) |dialog| {
            dialog.as(gtk.Window).destroy();
            dialog.unref();
        }
        if (self.aqueous_view) |view| {
            view.rebuild_observer = null;
            self.aqueous_rebuilding = true;
            view.destroy();
        }
        if (self.plugins_view) |view| view.destroy();
        for (self.live_pages) |page| if (page) |view| view.destroy();
        for (self.preference_pages) |page| if (page) |view| view.destroy();
        if (self.preferences_view) |view| view.destroy();
        if (self.restore_id != 0) _ = glib.Source.remove(self.restore_id);
        if (self.resize_id != 0) _ = glib.Source.remove(self.resize_id);
        if (self.native) |surface| if (self.layout_id != 0) {
            object.signalHandlerDisconnect(surface.as(object.Object), self.layout_id);
        };
        const display = self.window.as(gtk.Widget).getDisplay();
        for ([_]*gtk.CssProvider{ self.css, self.native_css, self.font_css }) |provider| {
            gtk.StyleContext.removeProviderForDisplay(display, provider.as(gtk.StyleProvider));
            provider.unref();
        }
        self.window.destroy();
        self.window.unref();
        self.arena.deinit();
        a.destroy(self);
    }
    fn t(self: *Window, en: [:0]const u8, de: [:0]const u8) [:0]const u8 {
        return if (self.german) de else en;
    }
    fn title(self: *Window, route: nav.Route) [:0]const u8 {
        if (!self.german) return route.title();
        return switch (route) {
            .overview => "Übersicht",
            .network => "Netzwerk",
            .bluetooth => "Bluetooth",
            .sound => "Klang",
            .power => "Energie und Akku",
            .appearance => "Erscheinungsbild",
            .bar => "Leiste und Dock",
            .notifications => "Benachrichtigungen",
            .session => "Sitzung und Sperre",
            .aqueous => "Aqueous",
            .advanced => "Erweitert",
            .plugins => "Plugins",
        };
    }
    fn description(self: *Window, route: nav.Route) [:0]const u8 {
        return switch (route) {
            .overview => self.t("Your desktop settings, together.", "Alle Desktop-Einstellungen an einem Ort."),
            .appearance => self.t("Make Pearl feel at home on your desktop.", "Gestalte Pearl für deinen Desktop."),
            .network => self.t("Manage your connections and nearby networks.", "Verbindungen und Netzwerke verwalten."),
            .bluetooth => self.t("Connect and manage your wireless devices.", "Drahtlose Geräte verbinden und verwalten."),
            .sound => self.t("Choose where sound plays and how you are heard.", "Wiedergabe und Mikrofon einstellen."),
            .power => self.t("Balance performance and battery life.", "Leistung und Akkulaufzeit einstellen."),
            .bar => self.t("Arrange your desktop bar and dock.", "Desktop-Leiste und Dock anordnen."),
            .notifications => self.t("Manage interruptions and notification history.", "Unterbrechungen und Benachrichtigungen verwalten."),
            .session => self.t("Automatic locking and sleep for your session.", "Automatische Sperre und Ruhemodus einstellen."),
            .aqueous => self.t("Configure your compositor by section.", "Compositor nach Bereichen konfigurieren."),
            .plugins => self.t("Manage installed plugins, permissions and placement.", "Installierte Plugins, Berechtigungen und Platzierung verwalten."),
            .advanced => self.t("Review the complete Pearl preferences document.", "Alle Pearl-Einstellungen als Dokument anzeigen."),
        };
    }
    fn icon(route: nav.Route) [:0]const u8 {
        return switch (route) {
            .overview => "pearl-view-grid-symbolic",
            .network => "pearl-network-wireless-symbolic",
            .bluetooth => "pearl-bluetooth-active-symbolic",
            .sound => "pearl-audio-volume-high-symbolic",
            .power => "pearl-battery-symbolic",
            .appearance => "applications-graphics-symbolic",
            .bar, .aqueous => "pearl-window-symbolic",
            .notifications => "pearl-notifications-symbolic",
            .session => "system-lock-screen-symbolic",
            .advanced, .plugins => "pearl-emblem-system-symbolic",
        };
    }
    fn sectionTitle(self: *Window, index: usize) [:0]const u8 {
        const en = [_][:0]const u8{ "Appearance", "Layouts", "Input", "Shortcuts", "Rules", "Displays", "Advanced" };
        const de = [_][:0]const u8{ "Erscheinungsbild", "Layouts", "Eingabe", "Tastenkürzel", "Regeln", "Bildschirme", "Erweitert" };
        return if (self.german) de[index] else en[index];
    }
    fn navigationLink(self: *Window, box: *gtk.Box, index: usize, target: nav.Target) void {
        const button = gtk.ToggleButton.new();
        button.as(gtk.Widget).setSizeRequest(-1, 44);
        button.as(gtk.Widget).addCssClass("settings-nav-item");
        const row = w.row(10);
        const title_ = if (target.section) |section| self.sectionTitle(nav.aqueousSectionIndex(section) catch unreachable) else self.title(target.page);
        if (target.section != null) {
            button.as(gtk.Widget).addCssClass("settings-nav-child");
            const name = std.fmt.allocPrintSentinel(self.arena.allocator(), "Aqueous / {s}", .{title_}, 0) catch unreachable;
            w.name(button.as(gtk.Widget), name);
        } else {
            row.append(w.icon(icon(target.page)).as(gtk.Widget));
            w.name(button.as(gtk.Widget), title_);
        }
        row.append(w.label(title_, null).as(gtk.Widget));
        button.as(gtk.Button).setChild(row.as(gtk.Widget));
        self.links[index] = .{ .owner = self, .target = target, .button = button };
        _ = gtk.Button.signals.clicked.connect(button.as(gtk.Button), *Link, navigated, &self.links[index], .{});
        box.append(button.as(gtk.Widget));
    }
    fn navigation(self: *Window, index: usize) *gtk.Box {
        const box = w.column(2);
        box.as(gtk.Widget).addCssClass("settings-nav");
        w.name(box.as(gtk.Widget), self.t("Settings sections", "Einstellungsbereiche"));
        for (std.enums.values(nav.Route)) |route| {
            const group: ?[:0]const u8 = switch (route) {
                .overview => self.t("GENERAL", "ALLGEMEIN"),
                .network => self.t("CONNECTIONS", "VERBINDUNGEN"),
                .sound => self.t("DEVICES", "GERÄTE"),
                .appearance => self.t("DESKTOP", "DESKTOP"),
                .session => self.t("SYSTEM", "SYSTEM"),
                else => null,
            };
            if (group) |text| box.append(w.label(text, "settings-group").as(gtk.Widget));
            const offset = index * navigation_count + navigationIndex(route);
            self.navigationLink(box, offset, .{ .page = route });
            if (route == .aqueous) for (nav.aqueous_sections, 0..) |section, i| {
                self.navigationLink(box, offset + 1 + i, .{ .page = .aqueous, .section = section });
            };
        }
        return box;
    }
    fn updateNavigation(self: *Window) void {
        const changing = self.changing;
        self.changing = true;
        defer self.changing = changing;
        for (&self.links) |*link| {
            const child = link.target.section != null;
            const selected = link.target.page == self.target.page and
                (if (link.target.section) |section| std.mem.eql(u8, section, self.target.section orelse "") else self.target.page != .aqueous);
            link.button.setActive(@intFromBool(selected));
            if (child) link.button.as(gtk.Widget).setVisible(@intFromBool(self.target.page == .aqueous));
            if (link.target.page == .aqueous and !child) {
                if (self.target.page == .aqueous) link.button.as(gtk.Widget).addCssClass("settings-nav-parent") else link.button.as(gtk.Widget).removeCssClass("settings-nav-parent");
                link.button.as(gtk.Accessible).updateState(.expanded, @as(c_int, @intFromBool(self.target.page == .aqueous)), @as(c_int, -1));
            }
        }
    }
    fn selectedNavigation(self: *Window) *gtk.Widget {
        const index = navigationIndex(self.target.page) + (if (self.target.page == .aqueous) 1 + self.aqueous_section else @as(usize, 0));
        return self.links[index].button.as(gtk.Widget);
    }
    fn navigationAllocated(_: *gtk.Adjustment, self: *Window) callconv(.c) void {
        // Adjustment ranges change during layout, before rows have their final
        // allocations. Reveal the selected destination after that layout ends.
        if (self.navigation_reveal_id == 0) self.navigation_reveal_id = glib.idleAdd(navigationReady, self);
    }
    fn navigationReady(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(context.?));
        self.navigation_reveal_id = 0;
        self.revealNavigation();
        return 0;
    }
    fn revealNavigation(self: *Window) void {
        const scroll = if (self.narrow) self.popup_scroll else self.sidebar;
        const index = (if (self.narrow) navigation_count else @as(usize, 0)) + navigationIndex(self.target.page) +
            (if (self.target.page == .aqueous) 1 + self.aqueous_section else @as(usize, 0));
        const button = self.links[index].button.as(gtk.Widget);
        var rect: @import("graphene1").Rect = undefined;
        if (button.computeBounds(scroll.as(gtk.Widget), &rect) == 0) return;
        const adjustment = scroll.getVadjustment();
        const top = rect.f_origin.f_y;
        const bottom = top + rect.f_size.f_height;
        if (top < 0) adjustment.setValue(adjustment.getValue() + top) else if (bottom > adjustment.getPageSize()) adjustment.setValue(adjustment.getValue() + bottom - adjustment.getPageSize());
    }
    fn compose(self: *Window, route: nav.Route, body: *gtk.Box) void {
        if (route == .overview) {
            for (std.enums.values(nav.Route)) |target| {
                if (target == .overview) continue;
                const button = gtk.ToggleButton.new();
                button.as(gtk.Widget).addCssClass("settings-category");
                const row = w.row(16);
                row.append(w.icon(icon(target)).as(gtk.Widget));
                const texts = w.column(5);
                texts.append(w.label(self.title(target), "settings-row-title").as(gtk.Widget));
                texts.append(w.label(self.description(target), "pearl-secondary").as(gtk.Widget));
                row.append(texts.as(gtk.Widget));
                button.as(gtk.Button).setChild(row.as(gtk.Widget));
                const link = self.arena.allocator().create(Link) catch unreachable;
                link.* = .{ .owner = self, .target = .{ .page = target }, .button = button };
                _ = gtk.Button.signals.clicked.connect(button.as(gtk.Button), *Link, navigated, link, .{});
                body.append(button.as(gtk.Widget));
            }
            return;
        }
        if (@import("build_options").test_hooks and self.fixture) {
            self.sample(route, body);
            return;
        }
        const card_ = self.card(body);
        card_.append(w.icon(icon(route)).as(gtk.Widget));
        card_.append(w.label(self.t("Waiting for settings", "Einstellungen werden erwartet"), "settings-row-title").as(gtk.Widget));
        card_.append(w.label(self.t("This page needs a compatible Pearl session. Your settings will appear here when they are available.", "Dieser Bereich benötigt eine kompatible Pearl-Sitzung. Verfügbare Einstellungen werden hier angezeigt."), "pearl-secondary").as(gtk.Widget));
    }
    fn card(_: *Window, parent: *gtk.Box) *gtk.Box {
        const card_ = w.column(0);
        card_.as(gtk.Widget).addCssClass("settings-card");
        parent.append(card_.as(gtk.Widget));
        return card_;
    }
    fn sampleRow(_: *Window, card_: *gtk.Box, title_: [:0]const u8, detail: ?[:0]const u8, trailing: *gtk.Widget) void {
        const flow = gtk.FlowBox.new();
        flow.setSelectionMode(.none);
        flow.setHomogeneous(0);
        flow.setMinChildrenPerLine(1);
        flow.setMaxChildrenPerLine(2);
        flow.setColumnSpacing(16);
        flow.setRowSpacing(8);
        flow.as(gtk.Widget).addCssClass("settings-form-row");
        const text = w.column(4);
        text.as(gtk.Widget).setHexpand(1);
        text.append(w.label(title_, "settings-row-title").as(gtk.Widget));
        if (detail) |d| text.append(w.label(d, "pearl-secondary").as(gtk.Widget));
        flow.insert(text.as(gtk.Widget), -1);
        trailing.setHalign(.end);
        trailing.setValign(.center);
        flow.insert(trailing, -1);
        card_.append(flow.as(gtk.Widget));
    }
    fn value(text: [:0]const u8) *gtk.Widget {
        const button = w.wrappingButton(text);
        button.as(gtk.Widget).addCssClass("settings-value");
        return button.as(gtk.Widget);
    }
    fn sample(self: *Window, route: nav.Route, body: *gtk.Box) void {
        switch (route) {
            .appearance => {
                const card_ = self.card(body);
                self.sampleRow(card_, "Theme", "Choose how Pearl is styled", value("Material · static"));
                self.sampleRow(card_, "Color variant", null, value("Dark"));
                const colors = w.row(8);
                for ([_][:0]const u8{ "lavender", "blue", "green", "pink" }) |name| {
                    const b = gtk.Button.new();
                    b.as(gtk.Widget).addCssClass("settings-swatch");
                    b.as(gtk.Widget).addCssClass(name);
                    w.name(b.as(gtk.Widget), name);
                    colors.append(b.as(gtk.Widget));
                }
                self.sampleRow(card_, "Accent color", "Used for selected controls and highlights", colors.as(gtk.Widget));
                const wall = self.card(body);
                const preview = w.column(0);
                preview.as(gtk.Widget).addCssClass("settings-wallpaper");
                preview.as(gtk.Widget).setSizeRequest(-1, 100);
                wall.append(preview.as(gtk.Widget));
                self.sampleRow(wall, "Wallpaper", "Lavender gradient", value("Choose image…"));
                const fonts = self.card(body);
                self.sampleRow(fonts, "Font size", "Pearl interface text", value("14 px"));
                self.sampleRow(fonts, "Density", "Spacing between controls", value("Normal"));
                self.sampleRow(fonts, "Reduced motion", "Keep transitions quiet", gtk.Switch.new().as(gtk.Widget));
            },
            .sound => {
                const output = self.card(body);
                self.sampleRow(output, "Output", "Built-in speakers · Default device", value("Choose output"));
                self.sampleRow(output, "Output volume", null, value("68%"));
                const slider = gtk.Scale.newWithRange(.horizontal, 0, 100, 1);
                slider.as(gtk.Range).setValue(68);
                slider.setDrawValue(0);
                output.append(slider.as(gtk.Widget));
                const input = self.card(body);
                self.sampleRow(input, "Input", "Built-in microphone · Default device", value("Choose input"));
                self.sampleRow(input, "Input volume", null, value("52%"));
                const apps = self.card(body);
                self.sampleRow(apps, "Application sound", "Firefox", value("80%"));
                self.sampleRow(apps, "Music", "Playing audio", value("64%"));
            },
            .network => {
                self.sampleRow(self.card(body), "Wi-Fi", "Wireless adapter · Enabled", gtk.Switch.new().as(gtk.Widget));
                self.sampleRow(self.card(body), "Home network", "Connected · Strong signal", value("Disconnect"));
                const nearby = self.card(body);
                self.sampleRow(nearby, "Nearby networks", "Choose a network to connect", value("Scan"));
                self.sampleRow(nearby, "Studio", "Secured · Strong signal", value("Connect"));
                self.sampleRow(nearby, "Guest", "Secured · Good signal", value("Connect"));
                self.sampleRow(self.card(body), "More connections", "Saved networks, VPN and enterprise settings", value("Network editor…"));
            },
            .bluetooth => {
                self.sampleRow(self.card(body), "Bluetooth", "Built-in adapter · Available", gtk.Switch.new().as(gtk.Widget));
                const devices = self.card(body);
                self.sampleRow(devices, "Studio headphones", "Connected · Trusted", value("Disconnect"));
                self.sampleRow(devices, "Wireless keyboard", "Paired · Not connected", value("Connect"));
                self.sampleRow(self.card(body), "Find nearby devices", "Discovery starts when you choose Find devices.", value("Find devices"));
            },
            .power => {
                self.sampleRow(self.card(body), "Battery", "Charging · About 35 minutes until full", value("82%"));
                self.sampleRow(self.card(body), "Power mode", "Balance performance and energy use", value("Balanced"));
                self.sampleRow(self.card(body), "Brightness", "Built-in display", value("72%"));
                self.sampleRow(self.card(body), "Session & lock", "Automatic locking and sleep", value("Open settings"));
            },
            else => {
                const card_ = self.card(body);
                card_.append(w.label(self.title(route), "settings-row-title").as(gtk.Widget));
                card_.append(w.label("Page composition preview", "pearl-secondary").as(gtk.Widget));
            },
        }
    }
    pub fn requestSelect(self: *Window, requested: nav.Target, external: bool) void {
        requested.validate() catch return;
        self.keep_sections_open = !external and requested.page == .aqueous and requested.section == null and self.popover.as(gtk.Widget).getVisible() != 0;
        const target: nav.Target = .{ .page = requested.page, .section = if (requested.section) |section| nav.aqueous_sections[nav.aqueousSectionIndex(section) catch return] else if (requested.page == .aqueous) nav.aqueous_sections[if (external) 0 else self.aqueous_section] else null };
        if (!self.fixture and self.target.page == .aqueous and self.aqueous.online and !self.aqueous.recovery and (self.aqueous.dirty or self.aqueous.sending != null)) {
            self.pending_aqueous_selection = .{ .target = target, .external = external };
            self.aqueous.flush();
            return;
        }
        self.pending_aqueous_selection = null;
        if (self.fixture) self.select(target, external) else self.editor.navigate(target, external);
    }
    pub fn select(self: *Window, target: nav.Target, external: bool) void {
        target.validate() catch return;
        if (self.aqueous_view) |view| view.stopRecording();
        if (self.restore_id != 0) {
            _ = glib.Source.remove(self.restore_id);
            self.restore_id = 0;
        }
        const previous = &self.pages[@intFromEnum(self.target.page)];
        if (self.target.page == .aqueous) self.aqueous_states[self.aqueous_section].scroll = previous.scroll.getVadjustment().getValue();
        if (self.window.getFocus()) |focus| if (focus == previous.body or focus.isAncestor(previous.body) != 0) {
            self.pageFocus().* = focus;
        };
        self.target = .{ .page = target.page, .section = if (target.section) |section| nav.aqueous_sections[nav.aqueousSectionIndex(section) catch unreachable] else null };
        self.changing = true;
        self.aqueous_context.as(gtk.Widget).setVisible(@intFromBool(target.page == .aqueous));
        if (target.page == .aqueous) {
            self.aqueous_section = if (target.section) |section| nav.aqueousSectionIndex(section) catch 0 else if (external) 0 else self.aqueous_section;
            self.target.section = nav.aqueous_sections[self.aqueous_section];
        }
        self.updateNavigation();
        if (target.page == .aqueous) if (self.aqueous_view) |view| view.showPage(nav.aqueous_sections[self.aqueous_section]) catch {};
        self.changing = false;
        const heading = if (target.page == .aqueous) self.sectionTitle(self.aqueous_section) else self.title(target.page);
        self.heading.setText(heading);
        const context_title = std.fmt.allocPrintSentinel(a, "Aqueous / {s}", .{heading}, 0) catch unreachable;
        defer a.free(context_title);
        w.name(self.heading_anchor, if (target.page == .aqueous) context_title else heading);
        self.subtitle.setText(if (target.page == .aqueous and self.aqueous_section == 5) "Make your screens match your workspace." else self.description(target.page));
        self.stack.setVisibleChildName(target.page.id());
        const keep_open = self.keep_sections_open and !external and self.popover.as(gtk.Widget).getVisible() != 0;
        self.keep_sections_open = false;
        if (!keep_open) self.popover.popdown();
        const page = &self.pages[@intFromEnum(target.page)];
        if (external) {
            page.scroll.getVadjustment().setValue(0);
            self.pageFocus().* = null;
            if (target.page == .aqueous) self.aqueous_states[self.aqueous_section].scroll = 0;
        }
        self.restore_id = glib.idleAdd(restore, self);
        const preference = switch (target.page) {
            .appearance, .bar, .session, .advanced, .plugins => true,
            else => false,
        };
        self.save.as(gtk.Widget).getParent().?.setVisible(@intFromBool(preference));
        self.save.as(gtk.Widget).setSensitive(0);
        self.discard.as(gtk.Widget).setSensitive(0);
        self.footer_text.setText(if (self.fixture) (if (preference) self.t("Pearl preferences · Preview only", "Pearl-Einstellungen · Nur Vorschau") else self.t("Preview only · Sample devices", "Nur Vorschau · Beispielgeräte")) else self.t("Pearl preferences are managed by your session.", "Deine Sitzung verwaltet die Pearl-Einstellungen."));
        self.heading.as(gtk.Accessible).announce(if (target.page == .aqueous) context_title else heading, .medium);
        if (!self.fixture) self.editingChanged();
        std.log.info("event=settings-page page={s}", .{target.page.id()});
    }
    fn restore(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(context.?));
        self.restore_id = 0;
        if (self.popover.as(gtk.Widget).getVisible() != 0) {
            self.revealNavigation();
            return 0;
        }
        const page = &self.pages[@intFromEnum(self.target.page)];
        const scroll = if (self.target.page == .aqueous) self.aqueous_states[self.aqueous_section].scroll else page.scroll.getVadjustment().getValue();
        const focus = self.pageFocus().*;
        if (focus) |widget| {
            if (widget.getMapped() == 0 or widget.isAncestor(page.body) == 0 or widget.grabFocus() == 0) _ = self.heading_anchor.grabFocus();
        } else _ = self.heading_anchor.grabFocus();
        page.scroll.getVadjustment().setValue(scroll);
        self.revealNavigation();
        return 0;
    }
    fn pageFocus(self: *Window) *?*gtk.Widget {
        return if (self.target.page == .aqueous) &self.aqueous_states[self.aqueous_section].focus else &self.pages[@intFromEnum(self.target.page)].focus;
    }
    fn aqueousRebuilt(context: *anyopaque, rebuilding: bool) void {
        const self: *Window = @ptrCast(@alignCast(context));
        self.aqueous_rebuilding = rebuilding;
        if (rebuilding) {
            @memset(&self.display_focus_id, 0);
            const focused = if (self.target.page == .aqueous and self.aqueous_section == 5) self.window.getFocus() else self.aqueous_states[5].focus;
            if (focused) |focus| if (self.aqueous_view) |view| {
                for (view.display_controls.items) |control| if (focus == control.widget or focus.isAncestor(control.widget) != 0) {
                    const length = @min(control.id.len, self.display_focus_id.len - 1);
                    @memcpy(self.display_focus_id[0..length], control.id[0..length]);
                    break;
                };
            };
            if (!self.changing and self.target.page == .aqueous and self.restore_id == 0) self.aqueous_states[self.aqueous_section].scroll = self.pages[@intFromEnum(nav.Route.aqueous)].scroll.getVadjustment().getValue();
            for (&self.aqueous_states) |*state| state.focus = null;
        } else {
            if (self.display_focus_id[0] != 0) if (self.aqueous_view) |view| {
                for (view.display_controls.items) |control| if (std.mem.eql(u8, control.id, std.mem.sliceTo(&self.display_focus_id, 0))) {
                    self.aqueous_states[5].focus = control.widget;
                    break;
                };
            };
            if (!self.changing and self.target.page == .aqueous and self.restore_id == 0 and self.popover.as(gtk.Widget).getVisible() == 0) self.restore_id = glib.idleAdd(restore, self);
        }
    }
    pub fn connection(self: *Window, connected: bool, err: ?anyerror) void {
        self.connected = connected;
        // Revisions belong to one backend incarnation, not the app lifetime.
        if (!connected) self.styled_revision = null;
        self.status.setText(if (connected) self.t("Connected to Pearl.", "Mit Pearl verbunden.") else if (err == null) self.t("Connecting to your Pearl session…", "Verbindung mit deiner Pearl-Sitzung wird hergestellt…") else if (err.? == error.DisplayMismatch) self.t("Session mismatch. Open Settings from the matching Aqueous session.", "Sitzung stimmt nicht überein. Öffne die Einstellungen in der passenden Aqueous-Sitzung.") else if (err.? == error.Version) self.t("This Pearl session uses an incompatible Settings version.", "Diese Pearl-Sitzung verwendet eine inkompatible Einstellungsversion.") else self.t("Pearl session unavailable. Start Pearl, then choose Retry.", "Pearl-Sitzung nicht verfügbar. Starte Pearl und versuche es erneut."));
        self.status.as(gtk.Widget).getParent().?.setVisible(@intFromBool(!self.fixture));
        self.retry_button.as(gtk.Widget).setVisible(@intFromBool(!connected));
        if (connected and !self.fixture) self.editingChanged();
    }
    fn invalidatePageFocus(context: *anyopaque, route: nav.Route) void {
        const self: *Window = @ptrCast(@alignCast(context));
        self.pages[@intFromEnum(route)].focus = null;
    }
    pub fn editingChanged(self: *Window) void {
        if (self.fixture) return;
        const editor = self.editor;
        self.saved_button.as(gtk.Widget).setVisible(@intFromBool(self.target.page == .advanced));
        self.saved_button.as(gtk.Widget).setSensitive(@intFromBool(editor.ready and editor.current != null));
        if (self.plugins_view) |view| view.update();
        if (self.preferences_view) |view| view.update();
        for (self.preference_pages) |page| if (page) |view| view.update();
        for (self.live_pages) |page| if (page) |view| view.update();
        self.aqueousChanged();
        const dirty = editor.local != null or editor.state.dirty;
        self.draft_badge.as(gtk.Widget).setVisible(@intFromBool((dirty or self.aqueous.draft != null) and !(self.target.page == .aqueous and self.aqueous_section == 5)));
        self.review_button.as(gtk.Widget).setVisible(@intFromBool((dirty or self.aqueous.draft != null) and !(self.target.page == .aqueous and self.aqueous_section == 5)));
        const preference_page = self.target.page == .appearance or self.target.page == .bar or self.target.page == .session or self.target.page == .advanced or self.target.page == .plugins;
        self.actions.as(gtk.Widget).setVisible(@intFromBool((editor.ready or dirty) and preference_page));
        self.merge_button.as(gtk.Widget).setVisible(@intFromBool(editor.state.conflict or editor.recovery));
        const available = editor.online and editor.ready and !editor.state.locked and !editor.state.busy and editor.download == .none and editor.operation == null;
        self.save.as(gtk.Widget).setSensitive(@intFromBool(available and dirty and (if (editor.local != null) editor.local_valid else editor.state.valid) and !editor.state.conflict and !editor.recovery));
        self.discard.as(gtk.Widget).setSensitive(@intFromBool(available and dirty));
        self.merge_button.as(gtk.Widget).setSensitive(@intFromBool(available));
        self.footer_text.setText(if (editor.recovery) self.t("Local changes need review. Merge them or discard only the local copy.", "Lokale Änderungen müssen geprüft werden. Zusammenführen oder nur die lokale Kopie verwerfen.") else if (editor.local != null) self.t("Pearl preferences · Retaining draft…", "Pearl-Einstellungen · Entwurf wird behalten…") else if (editor.state.busy) self.t("Pearl preferences · Preparing settings…", "Pearl-Einstellungen · Einstellungen werden vorbereitet…") else if (!preference_page) (if (dirty) self.t("Service controls take effect immediately. Pearl preference draft retained.", "Dienstregler wirken sofort. Der Pearl-Einstellungsentwurf bleibt behalten.") else self.t("Changes on this page take effect immediately.", "Änderungen auf dieser Seite wirken sofort.")) else if (self.target.page == .session) self.t("Apply saves Pearl preferences. Session actions take effect immediately.", "Anwenden speichert Pearl-Einstellungen. Sitzungsaktionen wirken sofort.") else if (editor.state.dirty) self.t("Pearl preferences · Draft retained in this session. Apply saves all Pearl changes.", "Pearl-Einstellungen · Entwurf in dieser Sitzung behalten. Anwenden speichert alle Pearl-Änderungen.") else self.t("Pearl preferences · All changes are applied explicitly.", "Pearl-Einstellungen · Änderungen werden ausdrücklich angewendet."));
        if (!self.connected) return;
        const status_text: [:0]const u8 = if (!editor.ready) self.t("Loading Pearl preferences…", "Pearl-Einstellungen werden geladen…") else if (editor.uncertain_operation) self.t("The connection ended during an operation. Review the current settings before applying again.", "Die Verbindung endete während eines Vorgangs. Prüfe die Einstellungen vor erneutem Anwenden.") else if (editor.recovery or editor.state.conflict) self.t("Settings changed elsewhere. Your changes are retained. Merge independent changes, or review Advanced to resolve a conflict.", "Einstellungen wurden anderswo geändert. Deine Änderungen bleiben erhalten. Zusammenführen oder den Konflikt unter Erweitert prüfen.") else if (editor.error_code.len > 0) self.errorMessage(editor.error_code.slice()) else if (!editor.state.valid) self.t("The draft is invalid. Correct the fields or review the JSON in Advanced before applying.", "Der Entwurf ist ungültig. Korrigiere die Felder oder das JSON unter Erweitert vor dem Anwenden.") else if (editor.export_error.len > 0) self.t("Preferences were saved. An export needs attention; your changes remain applied.", "Einstellungen gespeichert. Ein Export benötigt Aufmerksamkeit; die Änderungen bleiben angewendet.") else "";
        self.status.setText(status_text);
        self.status.as(gtk.Widget).getParent().?.setVisible(@intFromBool(status_text.len > 0));
        self.retry_button.as(gtk.Widget).setVisible(0);
    }
    pub fn aqueousChanged(self: *Window) void {
        self.display_count.as(gtk.Widget).setVisible(@intFromBool(self.target.page == .aqueous and self.aqueous_section == 5));
        var display_text: [80]u8 = undefined;
        const connected_displays = @import("../config/aqueous_display_setup.zig").outputs(self.aqueous.value()).len;
        self.display_count.setWidthChars(if (self.narrow) 12 else 23);
        self.display_count.setText(if (!self.aqueous.ready) "Loading displays…" else std.fmt.bufPrintZ(&display_text, "● {d} {s}{s}", .{ connected_displays, if (connected_displays == 1) @as([]const u8, "display") else "displays", if (self.narrow) @as([]const u8, "") else " connected" }) catch "Displays");
        if (self.fixture) return;
        if (self.pending_aqueous_selection) |selection| {
            if (!self.aqueous.online or self.aqueous.recovery or (!self.aqueous.dirty and self.aqueous.sending == null)) {
                self.pending_aqueous_selection = null;
                self.editor.navigate(selection.target, selection.external);
            }
        }
        if (self.aqueous_view) |view| {
            if (!self.aqueous.editing) view.update();
            view.actions.as(gtk.Widget).setVisible(@intFromBool(self.target.page == .aqueous));
            view.host.as(gtk.Widget).setSensitive(@intFromBool(self.aqueous.online and self.aqueous.ready and !self.aqueous.locked and !self.aqueous.suspended and !self.aqueous.recovery));
            if (self.aqueous.locked or self.aqueous.suspended or self.target.page != .aqueous) view.stopRecording();
        }
        self.aqueous_footer.as(gtk.Widget).setVisible(@intFromBool(self.target.page == .aqueous or self.aqueous.phase != 0));
        self.footer_text.as(gtk.Widget).setVisible(@intFromBool(self.target.page != .aqueous));
        self.footer.as(gtk.Orientable).setOrientation(if (self.narrow or self.font_size > 18 or self.target.page == .aqueous or self.aqueous.phase != 0) .vertical else .horizontal);
        self.review_button.as(gtk.Widget).setVisible(@intFromBool((self.editor.state.dirty or self.editor.local != null or self.aqueous.draft != null) and !(self.target.page == .aqueous and self.aqueous_section == 5)));
    }
    fn reviewClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (self.aqueous.recovery) {
            if (self.saved_dialog) |prior| {
                prior.as(gtk.Window).destroy();
                prior.unref();
                self.saved_dialog = null;
            }
            const text = a.dupeZ(u8, self.aqueous.draft orelse "") catch return;
            defer a.free(text);
            const dialog = gtk.Dialog.new();
            _ = dialog.ref();
            self.saved_dialog = dialog;
            dialog.as(gtk.Window).setTitle("Local Aqueous draft — recovery");
            dialog.as(gtk.Window).setTransientFor(self.window);
            dialog.as(gtk.Window).setModal(1);
            dialog.as(gtk.Window).setDefaultSize(600, 450);
            const view = gtk.TextView.new();
            view.setEditable(0);
            view.setMonospace(1);
            view.setWrapMode(.word_char);
            view.getBuffer().setText(text, -1);
            const scroll = gtk.ScrolledWindow.new();
            scroll.setChild(view.as(gtk.Widget));
            scroll.as(gtk.Widget).setVexpand(1);
            dialog.getContentArea().append(w.label("This local copy has not been resubmitted. Copy it before discarding, or use Rebase to reconcile independent changes.", null).as(gtk.Widget));
            dialog.getContentArea().append(scroll.as(gtk.Widget));
            _ = dialog.addButton("Close", @intFromEnum(gtk.ResponseType.close));
            _ = gtk.Dialog.signals.response.connect(dialog, *Window, savedClosed, self, .{});
            dialog.as(gtk.Window).present();
            return;
        }
        self.requestSelect(.{ .page = if (self.aqueous.draft != null and self.target.page != .aqueous) .aqueous else .advanced }, false);
    }
    fn errorMessage(self: *Window, code: []const u8) [:0]const u8 {
        if (std.mem.eql(u8, code, "NetworkEditorMissing")) return "The NetworkManager connection editor is not installed.";
        if (std.mem.eql(u8, code, "NetworkEditorLaunchFailed")) return "The network connection editor could not be opened. You can keep using this window.";
        if (self.target.page == .network or self.target.page == .bluetooth or self.target.page == .sound or self.target.page == .power or self.target.page == .notifications or self.target.page == .overview) return "The service action could not be completed. Check the status on this page and try again.";

        if (std.mem.eql(u8, code, "DocumentTooLarge")) return self.t("The draft is limited to 64 KiB. The previous text is retained.", "Der Entwurf ist auf 64 KiB begrenzt. Der bisherige Text bleibt erhalten.");
        if (std.mem.eql(u8, code, "MergeConflict")) return self.t("The same field changed in both versions. Review Advanced before resolving or discarding the draft.", "Dasselbe Feld wurde in beiden Versionen geändert. Prüfe Erweitert vor dem Auflösen oder Verwerfen.");
        if (std.mem.eql(u8, code, "InvalidImage") or std.mem.eql(u8, code, "ImageDecodeFailed") or std.mem.eql(u8, code, "ImageRequired")) return self.t("The wallpaper image could not be used. Choose a readable PNG or JPEG, then apply again.", "Das Hintergrundbild konnte nicht verwendet werden. Wähle ein lesbares PNG oder JPEG und wende erneut an.");
        if (std.mem.eql(u8, code, "SaveFailed")) return self.t("Preferences could not be saved. Your draft and working settings are retained.", "Einstellungen konnten nicht gespeichert werden. Entwurf und bisherige Einstellungen bleiben erhalten.");
        if (std.mem.eql(u8, code, "Busy")) return self.t("Pearl is busy. Your changes are retained; try again when the current work completes.", "Pearl ist beschäftigt. Änderungen bleiben erhalten; versuche es nach Abschluss erneut.");
        return self.t("The change could not be completed. Your draft is retained. Review Advanced and try again.", "Die Änderung konnte nicht abgeschlossen werden. Der Entwurf bleibt erhalten. Prüfe Erweitert und versuche es erneut.");
    }
    fn applyClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (!self.fixture) self.editor.act(.apply);
    }
    fn discardClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (!self.fixture) self.editor.act(.discard);
    }
    fn mergeClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (!self.fixture) self.editor.act(.merge);
    }
    pub fn closeFailure(self: *Window) void {
        if (self.close_dialog) |dialog| {
            dialog.as(gtk.Window).present();
            return;
        }
        const dialog = gtk.Dialog.new();
        _ = dialog.ref();
        self.close_dialog = dialog;
        dialog.as(gtk.Window).setTitle(self.t("Keep your changes", "Änderungen behalten"));
        dialog.as(gtk.Window).setTransientFor(self.window);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setDefaultSize(440, 220);
        const box = dialog.getContentArea();
        box.as(gtk.Widget).setMarginStart(20);
        box.as(gtk.Widget).setMarginEnd(20);
        box.as(gtk.Widget).setMarginTop(20);
        box.as(gtk.Widget).setMarginBottom(20);
        box.append(w.label(self.t("Some changes have not reached Pearl. Keep this window open to recover them, or close and discard only those untransferred changes. Drafts already retained by Pearl remain in the session.", "Einige Änderungen haben Pearl noch nicht erreicht. Behalte das Fenster zur Wiederherstellung offen oder schließe es und verwirf nur die nicht übertragenen Änderungen. Bereits von Pearl behaltene Entwürfe bleiben in der Sitzung."), null).as(gtk.Widget));
        _ = dialog.addButton(self.t("Keep open", "Offen halten"), @intFromEnum(gtk.ResponseType.cancel));
        _ = dialog.addButton(self.t("Discard untransferred changes and close", "Nicht übertragene Änderungen verwerfen und schließen"), @intFromEnum(gtk.ResponseType.accept));
        dialog.setDefaultResponse(@intFromEnum(gtk.ResponseType.cancel));
        _ = gtk.Dialog.signals.response.connect(dialog, *Window, closeResponse, self, .{});
        dialog.as(gtk.Window).present();
    }
    fn closeResponse(dialog: *gtk.Dialog, response: c_int, self: *Window) callconv(.c) void {
        self.close_dialog = null;
        dialog.as(gtk.Window).destroy();
        dialog.unref();
        if (response == @intFromEnum(gtk.ResponseType.accept)) self.editor.abandonClose() else self.editor.keepOpen();
    }
    pub fn locked(self: *Window, is_locked: bool) void {
        if (is_locked) {
            if (self.saved_dialog) |dialog| {
                self.saved_dialog = null;
                dialog.as(gtk.Window).destroy();
                dialog.unref();
            }
            if (self.preferences_view) |view| view.closePicker();
            if (self.close_dialog) |dialog| {
                self.close_dialog = null;
                dialog.as(gtk.Window).destroy();
                dialog.unref();
                self.editor.keepOpen();
            }
            self.window.as(gtk.Widget).setVisible(0);
        }
        self.editingChanged();
    }
    fn savedClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        if (self.saved_dialog) |dialog| {
            dialog.as(gtk.Window).present();
            return;
        }
        const text_ = self.editor.current orelse return;
        const dialog = gtk.Dialog.new();
        _ = dialog.ref();
        self.saved_dialog = dialog;
        dialog.as(gtk.Window).setTitle(self.t("Saved Pearl preferences", "Gespeicherte Pearl-Einstellungen"));
        dialog.as(gtk.Window).setTransientFor(self.window);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setDefaultSize(680, 520);
        const box = dialog.getContentArea();
        box.append(w.label(self.t("Read-only saved settings. Your draft stays in Advanced. Copy values from here to resolve overlapping changes, or discard the draft to start from the saved settings.", "Gespeicherte Einstellungen, nur lesbar. Dein Entwurf bleibt unter Erweitert. Kopiere Werte zur Konfliktlösung oder verwirf den Entwurf, um mit den gespeicherten Einstellungen zu beginnen."), "pearl-secondary").as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const view = gtk.TextView.new();
        view.setEditable(0);
        view.setMonospace(1);
        view.setWrapMode(.word_char);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const formatted = if (@import("../config/preferences.zig").parse(arena.allocator(), text_)) |prefs| std.json.Stringify.valueAlloc(arena.allocator(), prefs, .{ .whitespace = .indent_2 }) catch text_ else |_| text_;
        const z = arena.allocator().dupeZ(u8, formatted) catch return;
        view.getBuffer().setText(z, @intCast(z.len));
        scroll.setChild(view.as(gtk.Widget));
        box.append(scroll.as(gtk.Widget));
        _ = dialog.addButton(self.t("Close", "Schließen"), @intFromEnum(gtk.ResponseType.close));
        _ = gtk.Dialog.signals.response.connect(dialog, *Window, savedClosed, self, .{});
        dialog.as(gtk.Window).present();
    }
    fn savedClosed(dialog: *gtk.Dialog, _: c_int, self: *Window) callconv(.c) void {
        self.saved_dialog = null;
        dialog.as(gtk.Window).destroy();
        dialog.unref();
    }
    pub fn present(self: *Window, token: ?[]const u8) void {
        self.editor.resumeEditing();
        if (!self.aqueous.locked) self.aqueous.suspended = false;
        if (token) |value_| if (value_.len > 0 and value_.len <= 4096 and std.mem.indexOfScalar(u8, value_, 0) == null) {
            self.activation_contexts += 1;
            const z = a.dupeZ(u8, value_) catch null;
            if (z) |id| {
                defer a.free(id);
                self.window.setStartupId(id);
            }
        };
        self.window.unminimize();
        self.window.present();
    }
    pub fn style(self: *Window, snapshot: appearance.Snapshot) !void {
        if (self.styled_revision == snapshot.revision) return;
        const display = self.window.as(gtk.Widget).getDisplay();
        self.window.as(gtk.Widget).removeCssClass("pearl-dark");
        self.window.as(gtk.Widget).removeCssClass("pearl-gtk");
        self.window.as(gtk.Widget).addCssClass(if (snapshot.mode == .gtk) "pearl-gtk" else "pearl-dark");
        if (snapshot.reduced_motion) self.window.as(gtk.Widget).addCssClass("pearl-reduced-motion") else self.window.as(gtk.Widget).removeCssClass("pearl-reduced-motion");
        if (snapshot.density == .compact) self.window.as(gtk.Widget).addCssClass("pearl-compact") else self.window.as(gtk.Widget).removeCssClass("pearl-compact");
        const material = try theme.scopedCss(a, @embedFile("settings_base_style"), "pearl-dark", snapshot.palette);
        defer a.free(material);
        const app_style = try theme.scopedCss(a, @embedFile("settings_colors"), "pearl-dark", snapshot.palette);
        defer a.free(app_style);
        const token_template = try @import("../theme/style.zig").tokenCss(a, snapshot.style_tokens, snapshot.reduced_motion);
        defer a.free(token_template);
        const token_css = try theme.scopedCss(a, token_template, "pearl-dark", snapshot.palette);
        defer a.free(token_css);
        const custom_css = try theme.scopedCss(a, snapshot.style_css, "pearl-dark", snapshot.palette);
        defer a.free(custom_css);
        const sheet = try std.fmt.allocPrintSentinel(a, "{s}\n{s}\n{s}\n{s}\n{s}", .{ if (snapshot.mode == .gtk) @embedFile("settings_native") else material, app_style, @embedFile("settings_layout"), token_css, custom_css }, 0);
        defer a.free(sheet);
        self.css.loadFromString(sheet);
        if (snapshot.mode == .gtk and snapshot.gtk_name.len > 0) {
            const name = try a.dupeZ(u8, snapshot.gtk_name);
            defer a.free(name);
            self.native_css.loadNamed(name, if (snapshot.variant == .dark) "dark" else null);
        } else self.native_css.loadFromString("");
        const font = try std.fmt.allocPrintSentinel(a, ".settings-window {{ font-size: {d}px; {s}{s}{s} }}", .{ snapshot.font_size, if (snapshot.font.len > 0) "font-family: \"" else "", snapshot.font, if (snapshot.font.len > 0) "\";" else "" }, 0);
        defer a.free(font);
        self.font_css.loadFromString(font);
        gtk.Settings.getForDisplay(display).as(object.Object).set("gtk-enable-animations", @as(c_int, @intFromBool(!snapshot.reduced_motion)), @as(?*anyopaque, null));
        self.font_size = snapshot.font_size;
        if (self.resize_id == 0) self.resize_id = glib.idleAdd(reflow, self);
        self.styled_revision = snapshot.revision;
        self.style_mode = if (snapshot.mode == .gtk) "gtk" else @tagName(snapshot.variant);
        self.appearance_updates += 1;
    }
    fn navigated(_: *gtk.Button, link: *Link) callconv(.c) void {
        if (!link.owner.changing) {
            // A toggle changes itself before navigation has transferred the draft.
            link.owner.updateNavigation();
            link.owner.requestSelect(link.target, false);
        }
    }
    fn focusChanged(_: *object.Object, _: *object.ParamSpec, self: *Window) callconv(.c) void {
        if (self.changing or self.restore_id != 0 or self.aqueous_rebuilding) return;
        const page = &self.pages[@intFromEnum(self.target.page)];
        const focus = self.window.getFocus() orelse return;
        // Remember body focus before a pointer click moves it to navigation.
        // S2 page widgets remain alive for the window lifetime.
        if (focus == page.body or focus.isAncestor(page.body) != 0) self.pageFocus().* = focus;
    }
    fn retryClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.connection(false, null);
        self.retry(self.context);
    }
    fn closing(_: *gtk.Window, self: *Window) callconv(.c) c_int {
        self.close(self.context);
        return 1;
    }
    fn realized(_: *gtk.Widget, self: *Window) callconv(.c) void {
        self.native = self.window.as(gtk.Native).getSurface();
        if (self.native) |surface| self.layout_id = gdk.Surface.signals.layout.connect(surface, *Window, resized, self, .{});
    }
    fn resized(_: *gdk.Surface, _: c_int, _: c_int, self: *Window) callconv(.c) void {
        if (self.resize_id == 0) self.resize_id = glib.idleAdd(reflow, self);
    }
    fn reflow(context: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(context.?));
        self.resize_id = 0;
        const width = self.window.as(gtk.Widget).getWidth();
        const narrow = width < 760;
        self.sidebar.as(gtk.Widget).setVisible(@intFromBool(!narrow));
        self.sections.as(gtk.Widget).setVisible(@intFromBool(narrow));
        if (!narrow and self.narrow) self.popover.popdown();
        self.narrow = narrow;
        self.popup_scroll.as(gtk.Widget).setSizeRequest(@min(280, @max(160, width - 60)), @max(80, @min(560, self.window.as(gtk.Widget).getHeight() - 120)));
        if (narrow) self.window.as(gtk.Widget).addCssClass("settings-narrow") else self.window.as(gtk.Widget).removeCssClass("settings-narrow");
        self.footer.as(gtk.Orientable).setOrientation(if (narrow or self.font_size > 18 or self.target.page == .aqueous or self.aqueous.phase != 0) .vertical else .horizontal);
        self.actions.as(gtk.Orientable).setOrientation(if (narrow and self.font_size > 18 and !self.fixture) .vertical else .horizontal);
        return 0;
    }
    fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, modifiers: gdk.ModifierType, self: *Window) callconv(.c) c_int {
        if (@import("build_options").test_hooks) self.key_events += 1;
        if (modifiers.control_mask and (key == 'w' or key == 'W')) {
            self.close(self.context);
            return 1;
        }
        if (key == 0xff1b and self.popover.as(gtk.Widget).getVisible() != 0) {
            self.popover.popdown();
            _ = self.sections.as(gtk.Widget).grabFocus();
            return 1;
        }
        const focus = self.window.getFocus() orelse return 0;
        // GtkBox's focusable heading anchor does not traverse backward out of
        // itself. Return explicitly to navigation for both reverse-Tab forms.
        if (focus == self.heading_anchor and (key == 0xfe20 or (key == 0xff09 and modifiers.shift_mask))) {
            _ = (if (self.narrow) self.sections.as(gtk.Widget) else self.selectedNavigation()).grabFocus();
            return 1;
        }
        for (&self.links, 0..) |*link, i| if (focus == link.button.as(gtk.Widget)) {
            const base = i / navigation_count * navigation_count;
            const n = i % navigation_count;
            var next: usize = switch (key) {
                0xff54 => (n + 1) % navigation_count,
                0xff52 => (n + navigation_count - 1) % navigation_count,
                0xff50 => 0,
                0xff57 => navigation_count - 1,
                else => return 0,
            };
            while (self.links[base + next].button.as(gtk.Widget).getVisible() == 0) {
                next = (next + (if (key == 0xff52) navigation_count - 1 else @as(usize, 1))) % navigation_count;
            }
            _ = self.links[base + next].button.as(gtk.Widget).grabFocus();
            return 1;
        };
        return 0;
    }
    fn bounds(self: *Window, widget: *gtk.Widget) ?struct { x: f32, y: f32, width: f32, height: f32 } {
        var rect: @import("graphene1").Rect = undefined;
        if (widget.computeBounds(self.window.as(gtk.Widget), &rect) == 0) return null;
        return .{ .x = rect.f_origin.f_x, .y = rect.f_origin.f_y, .width = rect.f_size.f_width, .height = rect.f_size.f_height };
    }
    pub fn probe(self: *Window, alloc: std.mem.Allocator) ![]const u8 {
        const page = &self.pages[@intFromEnum(self.target.page)];
        var links: [navigation_count]struct { page: nav.Route, section: ?[]const u8, visible: bool, focused: bool, active: bool, bounds: @TypeOf(self.bounds(self.heading.as(gtk.Widget))) } = undefined;
        for (&links, 0..) |*link, i| {
            const item = &self.links[(if (self.narrow) @as(usize, navigation_count) else 0) + i];
            link.* = .{ .page = item.target.page, .section = item.target.section, .visible = item.button.as(gtk.Widget).getVisible() != 0, .focused = self.window.getFocus() == item.button.as(gtk.Widget), .active = item.button.getActive() != 0, .bounds = self.bounds(item.button.as(gtk.Widget)) };
        }
        const ControlProbe = struct { field: []const u8, focused: bool, enabled: bool = true, selected: ?bool = null, text: ?[]const u8 = null, bounds: @TypeOf(self.bounds(self.heading.as(gtk.Widget))) };
        var controls: std.ArrayList(ControlProbe) = .empty;
        const focus = self.window.getFocus();
        if (self.preferences_view) |view| {
            const widgets = [_]*gtk.Widget{ view.mode.as(gtk.Widget), view.variant.as(gtk.Widget), view.source.as(gtk.Widget), view.entries[0].as(gtk.Widget), view.entries[1].as(gtk.Widget), view.entries[2].as(gtk.Widget), view.entries[3].as(gtk.Widget), view.entries[4].as(gtk.Widget), view.font_size.as(gtk.Widget), view.fit.as(gtk.Widget), view.density.as(gtk.Widget), view.motion.as(gtk.Widget), view.choose.as(gtk.Widget), view.greeter_sync.button.as(gtk.Widget), view.raw_view.as(gtk.Widget), self.save.as(gtk.Widget), self.discard.as(gtk.Widget), self.merge_button.as(gtk.Widget) };
            for (widgets, [_][]const u8{ "mode", "variant", "source", "gtk_name", "seed", "wallpaper", "color", "font", "font_size", "fit", "density", "motion", "choose", "greeter_sync", "raw", "apply", "discard", "merge" }) |widget, name| {
                try controls.append(alloc, .{ .field = name, .focused = if (focus) |f| f == widget or f.isAncestor(widget) != 0 else false, .bounds = self.bounds(widget) });
            }
        }
        if (self.preferences_view) |view| {
            for ([_]*gtk.Widget{ view.night_enabled.as(gtk.Widget), view.night_temperature.as(gtk.Widget), view.night_schedule.as(gtk.Widget), view.night_times[0].as(gtk.Widget), view.night_times[1].as(gtk.Widget), view.night_times[2].as(gtk.Widget), view.night_times[3].as(gtk.Widget) }, [_][]const u8{ "night_enabled", "night_temperature", "night_schedule", "night_start_hour", "night_start_minute", "night_end_hour", "night_end_minute" }) |widget, name| {
                try controls.append(alloc, .{ .field = name, .focused = if (focus) |f| f == widget or f.isAncestor(widget) != 0 else false, .enabled = widget.isSensitive() != 0, .bounds = self.bounds(widget) });
            }
            try controls.append(alloc, .{ .field = "sync_borders", .focused = if (focus) |f| f == view.sync_borders.as(gtk.Widget) else false, .bounds = self.bounds(view.sync_borders.as(gtk.Widget)) });
            for ([_][]const @import("themes_view.zig").Control{ view.themes.controls.items, view.themes.row_controls.items }) |bindings| for (bindings) |binding| {
                try controls.append(alloc, .{ .field = binding.id, .focused = if (focus) |f| f == binding.widget else false, .enabled = binding.widget.isSensitive() != 0, .bounds = self.bounds(binding.widget) });
            };
            for ([_]*gtk.Widget{ view.profiles.enabled.as(gtk.Widget), view.profiles.source.as(gtk.Widget), view.profiles.seed.as(gtk.Widget) }, [_][]const u8{ "applications.enabled", "applications.source", "applications.seed" }) |widget, name| {
                try controls.append(alloc, .{ .field = name, .focused = if (focus) |f| f == widget else false, .enabled = widget.isSensitive() != 0, .bounds = self.bounds(widget) });
            }
            for (std.enums.values(@import("../theme/matugen_profiles.zig").Application), 0..) |application, i| {
                for ([_]*gtk.Widget{ view.profiles.modes[i].as(gtk.Widget), view.profiles.pickers[i].as(gtk.Widget) }, [_][]const u8{ "mode", "profile" }) |widget, name| {
                    try controls.append(alloc, .{ .field = try std.fmt.allocPrint(alloc, "applications.{s}.{s}", .{ @tagName(application), name }), .focused = if (focus) |f| f == widget else false, .enabled = widget.isSensitive() != 0, .bounds = self.bounds(widget) });
                }
            }
            for ([_]*gtk.Widget{ view.qt_enabled.as(gtk.Widget), view.qt_retry.as(gtk.Widget), view.qt_review.as(gtk.Widget), view.qt_reapply.as(gtk.Widget), view.qt_kde.as(gtk.Widget) }, [_][]const u8{ "qt_enabled", "qt_retry", "qt_review", "qt_reapply", "qt_kde" }) |widget, name|
                try controls.append(alloc, .{ .field = name, .focused = if (focus) |f| f == widget else false, .bounds = self.bounds(widget) });
        }
        if (self.plugins_view) |view| if (self.target.page == .plugins) {
            try controls.append(alloc, .{ .field = "plugins.refresh", .focused = if (focus) |f| f == view.refresh.as(gtk.Widget) else false, .enabled = view.refresh.as(gtk.Widget).isSensitive() != 0, .bounds = self.bounds(view.refresh.as(gtk.Widget)) });
        };
        if (self.plugins_view) |view| if (self.target.page == .plugins) for (view.rows.items) |row| {
            inline for (.{ "expand", "enabled", "activity", "overlay", "mode", "output", "x", "y", "width", "height", "interactive", "locked", "fullscreen" }) |name| {
                const widget = @field(row, name).as(gtk.Widget);
                try controls.append(alloc, .{ .field = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ row.info.id, name }), .focused = if (focus) |f| f == widget or f.isAncestor(widget) != 0 else false, .enabled = widget.isSensitive() != 0, .bounds = self.bounds(widget) });
            }
        };
        if (self.plugins_view) |view| if (self.target.page == .plugins) for (view.rows.items) |row| {
            for (row.actions, [_][]const u8{ "approve", "bar", "retry", "preview", "reset" }) |button, name| {
                const widget = button.as(gtk.Widget);
                try controls.append(alloc, .{ .field = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ row.info.id, name }), .focused = if (focus) |f| f == widget else false, .enabled = widget.isSensitive() != 0, .bounds = self.bounds(widget) });
            }
        };
        if (self.preference_pages[0]) |view| if (view.bar) |bar| {
            if (bar.repair.as(gtk.Widget).getMapped() != 0) try controls.append(alloc, .{ .field = "bar.repair", .focused = focus == bar.repair.as(gtk.Widget), .enabled = true, .bounds = self.bounds(bar.repair.as(gtk.Widget)) });
            for ([_][]const @import("bar_view.zig").Control{ bar.controls.items, bar.menu_controls.items }) |list| for (list) |control| {
                if (control.widget.getMapped() != 0) try controls.append(alloc, .{ .field = control.id, .focused = if (focus) |f| f == control.widget or f.isAncestor(control.widget) != 0 else false, .enabled = control.widget.isSensitive() != 0, .bounds = self.bounds(control.widget), .selected = if (object.ext.cast(gtk.CheckButton, control.widget)) |choice| choice.getActive() != 0 else null, .text = if (object.ext.cast(gtk.Label, control.widget)) |label| std.mem.span(label.getText()) else null });
            };
        };
        if (self.preference_pages[0]) |view| if (view.launchers) |launchers| {
            const header = launchers.expander.getLabelWidget().?;
            if (header.getMapped() != 0) try controls.append(alloc, .{ .field = "launchers.expand", .focused = false, .bounds = self.bounds(header) });
            for (launchers.controls.items) |control| if (control.widget.getMapped() != 0) {
                try controls.append(alloc, .{ .field = control.id, .focused = focus == control.widget, .enabled = control.widget.isSensitive() != 0, .bounds = self.bounds(control.widget) });
            };
        };
        for (self.preference_pages) |item| if (item) |view| for (view.fields) |field| {
            if (field.widget.getMapped() != 0) try controls.append(alloc, .{ .field = field.spec.path, .focused = if (focus) |f| f == field.widget or f.isAncestor(field.widget) != 0 else false, .bounds = self.bounds(field.widget) });
        };
        if (self.live_pages[@intFromEnum(self.target.page)]) |view| for (view.bindings.items) |binding| {
            try controls.append(alloc, .{ .field = binding.id, .focused = if (focus) |f| f == binding.widget or f.isAncestor(binding.widget) != 0 else false, .bounds = self.bounds(binding.widget) });
        };
        if (self.target.page == .aqueous) if (self.aqueous_view) |view| {
            for (view.editors.items) |field| if (field.widget.getMapped() != 0) {
                const id = @import("../config/aqueous_model.zig").str(@import("../config/aqueous_model.zig").get(field.field, "id"));
                try controls.append(alloc, .{ .field = id, .focused = if (focus) |f| f == field.widget or f.isAncestor(field.widget) != 0 else false, .bounds = self.bounds(field.widget) });
                if (field.record) |record| try controls.append(alloc, .{ .field = try std.fmt.allocPrint(alloc, "record:{s}", .{id}), .focused = false, .bounds = self.bounds(record.as(gtk.Widget)) });
            };
            for (view.display_controls.items) |control| if (control.widget.getMapped() != 0) {
                try controls.append(alloc, .{ .field = control.id, .focused = if (focus) |widget| widget == control.widget or widget.isAncestor(control.widget) != 0 else false, .enabled = control.widget.getSensitive() != 0, .bounds = self.bounds(control.widget) });
            };
            for (view.draft_buttons, [_][]const u8{ "aqueous.discard", "aqueous.rebase" }) |button, id| try controls.append(alloc, .{ .field = id, .focused = false, .bounds = self.bounds(button.as(gtk.Widget)) });
            for (view.buttons, [_][]const u8{ "aqueous.refresh", "aqueous.validate", "aqueous.apply" }) |button, id| try controls.append(alloc, .{ .field = id, .focused = false, .bounds = self.bounds(button.as(gtk.Widget)) });
        };
        defer controls.deinit(alloc);
        const editor_state = .{ .ready = self.editor.ready, .online = self.editor.online, .recovery = self.editor.recovery, .state = self.editor.state, .local = self.editor.local != null, .upload = self.editor.upload, .download = self.editor.download, .error_code = self.editor.error_code.slice(), .validation = self.editor.validation.slice(), .export_error = self.editor.export_error.slice(), .bytes = self.editor.text().len, .sha256 = @import("editor_protocol.zig").digest(self.editor.text())[0..], .picker = if (self.preferences_view) |view| view.picker != null else false, .preview = if (self.preferences_view) |view| view.preview_ready else false, .close_dialog = self.close_dialog != null, .can_apply = self.save.as(gtk.Widget).getSensitive() != 0, .can_edit = self.editor.editable() };
        const focus_name = if (focus == self.heading_anchor) "heading" else blk: {
            for (&self.links) |*link| if (focus == link.button.as(gtk.Widget)) break :blk if (link.target.section) |section| try std.fmt.allocPrint(alloc, "aqueous:{s}", .{section}) else link.target.page.id();
            break :blk "body";
        };
        var bar_groups: [3][]const u8 = .{ "", "", "" };
        if (self.preference_pages[0]) |view| if (view.bar) |bar| {
            for (bar.group_titles, 0..) |group_title, i| if (group_title) |label| {
                bar_groups[i] = std.mem.span(label.getText());
            };
        };
        return std.json.Stringify.valueAlloc(alloc, .{ .launcher_icon_picker = if (self.preference_pages[0]) |view| if (view.bar) |bar| bar.picker != null else false else false, .bar_groups = bar_groups, .links = links, .controls = controls.items, .editor = editor_state, .theme_busy = self.editor.theme_busy, .theme_status = if (self.preferences_view) |view| std.mem.span(view.themes.status.getText()) else "", .service_prompt = if (self.live_pages[@intFromEnum(self.target.page)]) |view| view.prompt != null else false, .aqueous = .{ .online = self.aqueous.online, .ready = self.aqueous.ready, .recovery = self.aqueous.recovery, .dirty = self.aqueous.dirty, .version = self.aqueous.version, .revision = self.aqueous.server_revision, .backend_version = self.aqueous.server_version, .mode = self.aqueous.mode, .phase = self.aqueous.phase, .busy = self.aqueous.job != null, .receipt_pending = self.aqueous.pending_receipt, .recording = self.aqueous.recording, .shared_review = if (self.aqueous_view) |view| view.shared_dialog != null else false, .display_changes = if (self.aqueous_view) |view| view.display_changes else 0, .display_blocked = if (self.aqueous_view) |view| view.display_blocked else false, .fields = if (self.aqueous_view) |view| view.editors.items.len else 0, .err = if (self.aqueous.err) |err| @errorName(err) else null, .detail = std.mem.sliceTo(&self.aqueous.detail, 0) }, .greeter_sync_status = if (self.preferences_view) |view| std.mem.span(view.greeter_sync.status.getText()) else "", .footer_text = std.mem.span(self.footer_text.getText()), .widget_focus = @import("../desktop/aqueous_settings.zig").ViewFor(@import("aqueous_editor.zig").Editor).focusName(self.window), .focus = focus_name, .active = self.window.isActive() != 0, .key_events = self.key_events, .header_bounds = self.bounds(self.heading.as(gtk.Widget)), .footer_bounds = self.bounds(self.footer.as(gtk.Widget)), .body_bounds = self.bounds(page.scroll.as(gtk.Widget)), .retry_bounds = self.bounds(self.retry_button.as(gtk.Widget)), .navigation_bounds = self.bounds((if (self.narrow) self.popup_scroll else self.sidebar).as(gtk.Widget)), .sections_bounds = self.bounds(self.sections.as(gtk.Widget)), .pid = std.os.linux.getpid(), .page = self.target.page, .section = self.target.section, .connected = self.connected, .fixture = self.fixture, .narrow = self.narrow, .width = self.window.as(gtk.Widget).getWidth(), .height = self.window.as(gtk.Widget).getHeight(), .visible = self.window.as(gtk.Widget).getVisible() != 0, .scroll = page.scroll.getVadjustment().getValue(), .heading = std.mem.span(self.heading.getText()), .status = std.mem.span(self.status.getText()), .style = self.style_mode, .appearance_updates = self.appearance_updates, .activation_contexts = self.activation_contexts, .sections_open = self.popover.as(gtk.Widget).getVisible() != 0 }, .{});
    }
};
