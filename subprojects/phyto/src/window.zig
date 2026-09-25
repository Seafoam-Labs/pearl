const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const gdk = @import("gdk4");
const a = u.a;
const Tab = @import("tab.zig").Tab;
const model = @import("core/model.zig");
const Operations = @import("operations.zig").Operations;

pub const Options = struct { light: bool = false, compact: bool = false, native: bool = false, width: c_int = 1180, height: c_int = 760 };
const Pane = struct { host: *gtk.Box, tabs_row: *gtk.Box, stack: *gtk.Stack, tabs: std.ArrayList(*Tab) = .empty, selected: usize = 0 };
const Command = @import("actions.zig").Command;
const Action = struct { owner: *Window, command: Command };

pub const Window = struct {
    app: *gtk.Application,
    window: *gtk.Window,
    root: *gtk.Box,
    sidebar: *gtk.ScrolledWindow,
    sidebar_content: *gtk.Box,
    popup_content: *gtk.Box,
    places_button: *gtk.MenuButton,
    places_popover: *gtk.Popover,
    location_button: *gtk.Button,
    path: *gtk.Entry,
    search: *gtk.SearchEntry,
    search_row: *gtk.Box,
    search_scope: *gtk.Label,
    navigation: *gtk.Stack,
    details: *gtk.ScrolledWindow,
    details_body: *gtk.Box,
    status: *gtk.Label,
    pane_switch: *gtk.Button,
    grid_button: *gtk.Button,
    list_button: *gtk.Button,
    back_button: *gtk.Button,
    forward_button: *gtk.Button,
    up_button: *gtk.Button,
    home_button: *gtk.Button,
    details_button: *gtk.Button,
    split_button: *gtk.Button,
    jobs_button: *gtk.Button,
    paned: *gtk.Paned,
    panes: [2]Pane,
    active: usize = 0,
    split: bool = false,
    show_details: bool = true,
    quick_preview: ?*@import("preview.zig").Quick = null,
    details_key: ?[:0]u8 = null,
    width: c_int = 1180,
    closed: bool = false,
    syncing: bool = false,
    update_id: c_uint = 0,
    resize_id: c_uint = 0,
    home: *gio.File,
    options: Options,
    actions: [std.enums.values(Command).len]Action = undefined,
    clipboard: @import("platform/clipboard.zig").Clipboard = undefined,
    context: @import("context_menu.zig").Menu = undefined,
    preferences: *@import("platform/preferences.zig").Preferences = undefined,
    next_tab_id: u64 = 0,
    background_cancel: *gio.Cancellable = undefined,
    volume_monitor: *gio.VolumeMonitor = undefined,
    volume_signals: [6]c_ulong = undefined,
    operations: Operations = undefined,
    message_dialog: ?*gtk.Dialog = null,
    status_message: ?[:0]u8 = null,
    native_surface: ?*gdk.Surface = null,
    native_signal: c_ulong = 0,

    pub fn create(app: *gtk.Application, initial: *gio.File, opts: Options) *Window {
        const self = a.create(Window) catch @panic("Out of memory");
        const win = gtk.ApplicationWindow.new(app).as(gtk.Window);
        win.setTitle("Phyto");
        win.setDefaultSize(opts.width, opts.height);
        win.setIconName("org.aqueous.Phyto");
        win.as(gtk.Widget).addCssClass("phyto-root");
        const root = u.box(.vertical, 0, null);
        win.setChild(root.as(gtk.Widget));
        const header = gtk.HeaderBar.new();
        const brand = u.box(.horizontal, 10, "brand");
        brand.append(u.image("folder-symbolic", 20).as(gtk.Widget));
        brand.append(u.label("Phyto", null).as(gtk.Widget));
        header.packStart(brand.as(gtk.Widget));
        header.setTitleWidget(u.label("Files", "secondary").as(gtk.Widget));
        win.setTitlebar(header.as(gtk.Widget));
        const work = u.box(.horizontal, 0, null);
        work.as(gtk.Widget).setVexpand(1);
        root.append(work.as(gtk.Widget));
        const sidebar_box = u.box(.vertical, 2, "places");
        const sidebar = u.scroll(sidebar_box.as(gtk.Widget));
        sidebar.as(gtk.Widget).addCssClass("sidebar");
        sidebar.as(gtk.Widget).setSizeRequest(208, -1);
        sidebar.as(gtk.Widget).setHexpand(0);
        work.append(sidebar.as(gtk.Widget));
        const browser = u.box(.vertical, 0, "browser");
        browser.as(gtk.Widget).setHexpand(1);
        work.append(browser.as(gtk.Widget));
        const toolbar = u.box(.horizontal, 4, "toolbar");
        browser.append(toolbar.as(gtk.Widget));
        const places_button = gtk.MenuButton.new();
        places_button.setIconName("sidebar-show-symbolic");
        places_button.as(gtk.Widget).addCssClass("icon-button");
        places_button.as(gtk.Widget).setTooltipText("Places");
        u.name(places_button.as(gtk.Widget), "Places");
        const popover = gtk.Popover.new();
        const popup_places = u.box(.vertical, 2, "places");
        const popup_scroll = u.scroll(popup_places.as(gtk.Widget));
        popup_scroll.setMinContentHeight(320);
        popup_scroll.setMaxContentHeight(520);
        popup_scroll.setPropagateNaturalHeight(1);
        popover.setChild(popup_scroll.as(gtk.Widget));
        places_button.setPopover(popover);
        toolbar.append(places_button.as(gtk.Widget));
        const back = u.iconButton("go-previous-symbolic", "Back · Alt+Left");
        const forward = u.iconButton("go-next-symbolic", "Forward · Alt+Right");
        const up = u.iconButton("go-up-symbolic", "Parent folder · Alt+Up");
        const home_button = u.iconButton("user-home-symbolic", "Home");
        for ([_]*gtk.Button{ back, forward, up, home_button }) |b| toolbar.append(b.as(gtk.Widget));
        const navigation = gtk.Stack.new();
        navigation.setHhomogeneous(0);
        navigation.setVhomogeneous(0);
        navigation.as(gtk.Widget).setHexpand(1);
        const location = gtk.Button.newWithLabel("Home");
        location.as(gtk.Widget).addCssClass("breadcrumb");
        location.as(gtk.Widget).setHalign(.start);
        object.ext.cast(gtk.Label, location.getChild().?).?.setEllipsize(.middle);
        object.ext.cast(gtk.Label, location.getChild().?).?.setMaxWidthChars(32);
        _ = navigation.addNamed(location.as(gtk.Widget), "breadcrumb");
        const path = gtk.Entry.new();
        u.name(path.as(gtk.Widget), "Location path or URI");
        _ = navigation.addNamed(path.as(gtk.Widget), "entry");
        toolbar.append(navigation.as(gtk.Widget));
        const search_button = u.iconButton("system-search-symbolic", "Search this folder · Ctrl+F");
        toolbar.append(search_button.as(gtk.Widget));
        const pane_switch = u.iconButton("go-next-symbolic", "Switch active pane · F6");
        toolbar.append(pane_switch.as(gtk.Widget));
        const jobs_button = u.iconButton("folder-download-symbolic", "File operations");
        toolbar.append(jobs_button.as(gtk.Widget));
        const split_button = u.iconButton("view-dual-symbolic", "Split panes · F3");
        toolbar.append(split_button.as(gtk.Widget));
        const views = u.box(.horizontal, 0, "segmented");
        const grid_button = u.iconButton("view-grid-symbolic", "Icon view · Ctrl+1");
        const list_button = u.iconButton("view-list-symbolic", "Detailed list · Ctrl+2");
        views.append(grid_button.as(gtk.Widget));
        views.append(list_button.as(gtk.Widget));
        toolbar.append(views.as(gtk.Widget));
        const details_button = u.iconButton("sidebar-show-right-symbolic", "File details · Alt+Enter");
        toolbar.append(details_button.as(gtk.Widget));
        const menu_button = gtk.MenuButton.new();
        menu_button.setIconName("open-menu-symbolic");
        menu_button.as(gtk.Widget).addCssClass("icon-button");
        menu_button.as(gtk.Widget).setTooltipText("More options");
        u.name(menu_button.as(gtk.Widget), "More options");
        toolbar.append(menu_button.as(gtk.Widget));
        const search_row = u.box(.horizontal, 12, "search-row");
        const search = gtk.SearchEntry.new();
        search.as(gtk.Widget).setHexpand(1);
        search.setPlaceholderText("Search filenames in this folder…");
        u.name(search.as(gtk.Widget), "Search filenames in current folder");
        search_row.append(search.as(gtk.Widget));
        const search_scope = u.label("Current folder", "secondary");
        search_row.append(search_scope.as(gtk.Widget));
        const search_close = u.iconButton("window-close-symbolic", "Close search");
        search_row.append(search_close.as(gtk.Widget));
        search_row.as(gtk.Widget).setVisible(0);
        browser.append(search_row.as(gtk.Widget));
        const content = u.box(.horizontal, 12, "content");
        content.as(gtk.Widget).setVexpand(1);
        content.as(gtk.Widget).setHexpand(1);
        browser.append(content.as(gtk.Widget));
        const paned = gtk.Paned.new(.horizontal);
        paned.setWideHandle(1);
        paned.setShrinkStartChild(1);
        paned.setShrinkEndChild(1);
        paned.as(gtk.Widget).setHexpand(1);
        content.append(paned.as(gtk.Widget));
        var panes: [2]Pane = undefined;
        for (&panes) |*p| {
            const host = u.box(.vertical, 0, "pane");
            host.as(gtk.Widget).setOverflow(.hidden);
            const tabs = u.box(.horizontal, 4, "tabs");
            const tabs_scroll = gtk.ScrolledWindow.new();
            tabs_scroll.setPolicy(.automatic, .never);
            tabs_scroll.setChild(tabs.as(gtk.Widget));
            host.append(tabs_scroll.as(gtk.Widget));
            const stack = gtk.Stack.new();
            stack.setHhomogeneous(0);
            stack.setVhomogeneous(0);
            stack.as(gtk.Widget).setVexpand(1);
            host.append(stack.as(gtk.Widget));
            p.* = .{ .host = host, .tabs_row = tabs, .stack = stack };
        }
        paned.setStartChild(panes[0].host.as(gtk.Widget));
        paned.setEndChild(panes[1].host.as(gtk.Widget));
        const details_body = u.box(.vertical, 12, "details-body");
        const details = u.scroll(details_body.as(gtk.Widget));
        details.as(gtk.Widget).setHexpand(0);
        details.as(gtk.Widget).setSizeRequest(224, -1);
        details.as(gtk.Widget).addCssClass("details");
        content.append(details.as(gtk.Widget));
        const status = u.label("Loading folder…", "status");
        status.setEllipsize(.end);
        browser.append(status.as(gtk.Widget));
        self.* = .{ .app = app, .window = win, .root = root, .sidebar = sidebar, .sidebar_content = sidebar_box, .popup_content = popup_places, .places_button = places_button, .places_popover = popover, .location_button = location, .path = path, .search = search, .search_row = search_row, .search_scope = search_scope, .navigation = navigation, .details = details, .details_body = details_body, .status = status, .pane_switch = pane_switch, .grid_button = grid_button, .list_button = list_button, .back_button = back, .forward_button = forward, .up_button = up, .home_button = home_button, .details_button = details_button, .split_button = split_button, .jobs_button = jobs_button, .paned = paned, .panes = panes, .options = opts, .home = gio.File.newForPath(glib.getHomeDir()), .width = opts.width };
        self.preferences = @import("platform/preferences.zig").Preferences.acquire();
        self.operations = Operations.init(self);
        self.background_cancel = gio.Cancellable.new();
        self.clipboard = @import("platform/clipboard.zig").Clipboard.init(self);
        self.context = @import("context_menu.zig").Menu.init(self);
        self.context.start();
        self.volume_monitor = gio.VolumeMonitor.get();
        inline for (.{ "mount-added", "mount-removed", "mount-changed", "volume-added", "volume-removed", "volume-changed" }, 0..) |name, i| {
            self.volume_signals[i] = object.signalConnectData(self.volume_monitor.as(object.Object), name, @ptrCast(&volumesChanged), self, null, .{});
        }
        for (std.enums.values(Command)) |command| {
            const idx = @intFromEnum(command);
            self.actions[idx] = .{ .owner = self, .command = command };
            const action = if (command == .advanced or command == .allow_delete or command == .thumbnails or command == .preview_details) gio.SimpleAction.newStateful(@tagName(command), null, glib.Variant.newBoolean(@intFromBool(switch (command) {
                .advanced => self.preferences.advanced,
                .thumbnails => self.preferences.thumbnails,
                .preview_details => self.preferences.preview_details,
                else => self.preferences.allow_delete,
            }))) else gio.SimpleAction.new(@tagName(command), null);
            _ = gio.SimpleAction.signals.activate.connect(action, *Action, actionActivated, &self.actions[idx], .{});
            object.ext.cast(gtk.ApplicationWindow, win).?.as(gio.ActionMap).addAction(action.as(gio.Action));
            action.unref();
        }
        self.connect(back, .back);
        self.connect(forward, .forward);
        self.connect(up, .up);
        self.connect(home_button, .home);
        self.connect(location, .location);
        self.connect(search_button, .search);
        self.connect(search_close, .search);
        self.connect(split_button, .split);
        self.connect(jobs_button, .operations);
        self.connect(pane_switch, .switch_pane);
        self.connect(grid_button, .grid);
        self.connect(list_button, .list);
        self.connect(details_button, .details);
        const menu = gio.Menu.new();
        inline for (.{ .{ "New tab", "new_tab" }, .{ "Close tab", "close_tab" }, .{ "New window", "new_window" }, .{ "Split panes", "split" }, .{ "New folder…", "new_folder" }, .{ "Rename…", "rename" }, .{ "Cut", "cut" }, .{ "Copy", "copy" }, .{ "Paste", "paste" }, .{ "Undo", "undo" }, .{ "Redo", "redo" }, .{ "File view options…", "menu_settings" }, .{ "Move to Trash…", "trash" }, .{ "File operations", "operations" }, .{ "Properties", "properties" }, .{ "Preview", "preview" }, .{ "Show / hide hidden files", "hidden" }, .{ "Refresh", "refresh" }, .{ "Light / dark appearance", "light" }, .{ "Compact density", "compact" }, .{ "Use system GTK theme", "native" } }) |entry| menu.append(entry[0], "win." ++ entry[1]);
        menu_button.setMenuModel(menu.as(gio.MenuModel));
        menu.unref();
        self.fillPlaces(sidebar_box);
        self.fillPlaces(popup_places);
        _ = gtk.Entry.signals.activate.connect(path, *Window, pathEntered, self, .{});
        _ = gtk.SearchEntry.signals.search_changed.connect(search, *Window, searchChanged, self, .{});
        _ = gtk.SearchEntry.signals.stop_search.connect(search, *Window, stopSearch, self, .{});
        _ = gtk.Window.signals.close_request.connect(win, *Window, closing, self, .{});
        _ = gtk.Widget.signals.realize.connect(win.as(gtk.Widget), *Window, realized, self, .{});
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, keyPressed, self, .{});
        win.as(gtk.Widget).addController(keys.as(gtk.EventController));
        const location_click = gtk.GestureClick.new();
        location_click.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(location_click, *Window, locationContext, self, .{});
        location.as(gtk.Widget).addController(location_click.as(gtk.EventController));
        self.addTab(0, initial);
        self.addTab(1, initial);
        self.applyTheme();
        self.sync();
        self.layout();
        self.clipboard.start();
        win.present();
        return self;
    }
    fn connect(self: *Window, button: *gtk.Button, command: Command) void {
        _ = gtk.Button.signals.clicked.connect(button, *Action, buttonClicked, &self.actions[@intFromEnum(command)], .{});
    }
    fn actionActivated(_: *gio.SimpleAction, _: ?*glib.Variant, action: *Action) callconv(.c) void {
        action.owner.dispatch(action.command);
    }
    fn buttonClicked(_: *gtk.Button, action: *Action) callconv(.c) void {
        action.owner.dispatch(action.command);
    }
    pub fn current(self: *Window) *Tab {
        const p = &self.panes[self.active];
        return p.tabs.items[p.selected];
    }
    pub fn addTab(self: *Window, pane: usize, file: *gio.File) void {
        const p = &self.panes[pane];
        if (p.tabs.items.len >= 32) {
            self.message("Tab limit reached", "Close an unused tab before opening another.");
            return;
        }
        const tab = Tab.create(self, pane, file);
        p.tabs.append(a, tab) catch unreachable;
        p.selected = p.tabs.items.len - 1;
        _ = p.stack.addChild(tab.root.as(gtk.Widget));
        p.stack.setVisibleChild(tab.root.as(gtk.Widget));
        self.rebuildTabs(pane);
    }
    pub fn rebuildTabs(self: *Window, pane: usize) void {
        self.context.close();
        const p = &self.panes[pane];
        u.clear(p.tabs_row);
        for (p.tabs.items, 0..) |tab, i| {
            const b = gtk.Button.newWithLabel(tab.title);
            b.as(gtk.Widget).addCssClass("tab");
            if (i == p.selected) b.as(gtk.Widget).addCssClass("selected-tab");
            object.ext.cast(gtk.Label, b.getChild().?).?.setEllipsize(.end);
            object.ext.cast(gtk.Label, b.getChild().?).?.setMaxWidthChars(20);
            b.as(gtk.Widget).setTooltipText(tab.uri);
            _ = gtk.Button.signals.clicked.connect(b, *Tab, tabClicked, tab, .{});
            b.as(object.Object).setData("phyto-tab", tab);
            const right = gtk.GestureClick.new();
            right.as(gtk.GestureSingle).setButton(3);
            _ = gtk.GestureClick.signals.pressed.connect(right, *Tab, tabContext, tab, .{});
            b.as(gtk.Widget).addController(right.as(gtk.EventController));
            p.tabs_row.append(b.as(gtk.Widget));
        }
        const add = u.iconButton("list-add-symbolic", "New tab · Ctrl+T");
        _ = gtk.Button.signals.clicked.connect(add, *Tab, addTabClicked, p.tabs.items[p.selected], .{});
        p.tabs_row.append(add.as(gtk.Widget));
    }
    fn addTabClicked(_: *gtk.Button, tab: *Tab) callconv(.c) void {
        tab.owner.active = tab.pane;
        tab.owner.dispatch(.new_tab);
    }
    fn tabClicked(_: *gtk.Button, tab: *Tab) callconv(.c) void {
        const self = tab.owner;
        self.context.close();
        const p = &self.panes[tab.pane];
        for (p.tabs.items, 0..) |t, i| if (t == tab) {
            p.selected = i;
            break;
        };
        p.stack.setVisibleChild(tab.root.as(gtk.Widget));
        self.active = tab.pane;
        self.rebuildTabs(tab.pane);
        self.sync();
    }
    pub fn activatePane(self: *Window, pane: usize) void {
        if (self.active != pane) {
            self.context.close();
            self.active = pane;
            self.sync();
        }
    }
    fn place(self: *Window, container: *gtk.Box, title: [*:0]const u8, symbol: [*:0]const u8, file: *gio.File) void {
        const button = gtk.Button.new();
        button.as(gtk.Widget).addCssClass("place");
        const row = u.box(.horizontal, 12, null);
        row.append(u.image(symbol, 18).as(gtk.Widget));
        const caption = u.label(title, null);
        caption.as(gtk.Widget).setHexpand(1);
        row.append(caption.as(gtk.Widget));
        button.setChild(row.as(gtk.Widget));
        file.ref();
        button.as(object.Object).setDataFull("phyto-file", file, unrefFile);
        _ = gtk.Button.signals.clicked.connect(button, *Window, placeClicked, self, .{});
        const right = gtk.GestureClick.new();
        right.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(right, *Window, placeContext, self, .{});
        button.as(gtk.Widget).addController(right.as(gtk.EventController));
        container.append(button.as(gtk.Widget));
    }
    fn unrefFile(data: ?*anyopaque) callconv(.c) void {
        const f: *gio.File = @ptrCast(@alignCast(data.?));
        f.unref();
    }
    fn fillPlaces(self: *Window, container: *gtk.Box) void {
        container.append(u.label("PLACES", "section-label").as(gtk.Widget));
        self.place(container, "Home", "user-home-symbolic", self.home);
        inline for (.{ .{ "Documents", "folder-documents-symbolic", glib.UserDirectory.directory_documents }, .{ "Downloads", "folder-download-symbolic", glib.UserDirectory.directory_download }, .{ "Pictures", "folder-pictures-symbolic", glib.UserDirectory.directory_pictures }, .{ "Music", "folder-music-symbolic", glib.UserDirectory.directory_music }, .{ "Videos", "folder-videos-symbolic", glib.UserDirectory.directory_videos } }) |entry| {
            const f = if (glib.getUserSpecialDir(entry[2])) |path| gio.File.newForPath(path) else self.home.getChild(entry[0]);
            defer f.unref();
            self.place(container, entry[0], entry[1], f);
        }
        const trash = gio.File.newForUri("trash:///");
        defer trash.unref();
        self.place(container, "Trash", "user-trash-symbolic", trash);
        container.append(u.label("LOCATIONS", "section-label").as(gtk.Widget));
        const root = gio.File.newForPath("/");
        defer root.unref();
        self.place(container, "File System", "drive-harddisk-symbolic", root);
        const network = gio.File.newForUri("network:///");
        defer network.unref();
        self.place(container, "Network", "network-workgroup-symbolic", network);
        inline for (.{ .{ "bookmarks", "BOOKMARKS" }, .{ "favorites", "FAVORITES" } }) |group| {
            if (self.preferences.strings(group[0])) |values| {
                defer glib.strfreev(values);
                if (values[0] != null) container.append(u.label(group[1], "section-label").as(gtk.Widget));
                for (std.mem.span(values)) |uri| {
                    const f = gio.File.newForUri(uri.?);
                    defer f.unref();
                    const name_ = self.preferences.bookmarkName(f);
                    defer glib.free(name_);
                    self.place(container, name_, if (std.mem.eql(u8, group[0], "favorites")) "starred-symbolic" else "folder-symbolic", f);
                }
            }
        }
        const mounts = g_volume_monitor_get_mounts(self.volume_monitor);
        if (mounts) |head| {
            defer head.free();
            var node: ?*glib.List = head;
            while (node) |n| : (node = n.f_next) {
                const mount_: *gio.Mount = @ptrCast(@alignCast(n.f_data.?));
                const f = mount_.getRoot();
                defer f.unref();
                const name_ = mount_.getName();
                defer glib.free(name_);
                self.place(container, name_, "drive-removable-media-symbolic", f);
                container.as(gtk.Widget).getLastChild().?.as(object.Object).setDataFull("phyto-mount", mount_, unrefObject);
            }
        }
        const volumes = g_volume_monitor_get_volumes(self.volume_monitor);
        if (volumes) |head| {
            defer head.free();
            var node: ?*glib.List = head;
            while (node) |n| : (node = n.f_next) {
                const v: *gio.Volume = @ptrCast(@alignCast(n.f_data.?));
                if (v.getMount()) |mounted| {
                    mounted.unref();
                    v.unref();
                    continue;
                }
                const f = v.getActivationRoot() orelse gio.File.newForUri("computer:///");
                defer f.unref();
                const name_ = v.getName();
                defer glib.free(name_);
                self.place(container, name_, "drive-removable-media-symbolic", f);
                container.as(gtk.Widget).getLastChild().?.as(object.Object).setDataFull("phyto-volume", v, unrefObject);
            }
        }
    }
    fn locationContext(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Window) callconv(.c) void {
        var c = @import("context.zig").Context.init(self.current(), .location);
        c.add(c.directory, self.current().directory_info);
        self.context.show(c, gesture.as(gtk.EventController).getWidget().?, x, y);
        _ = gesture.as(gtk.Gesture).setState(.claimed);
    }
    fn tabContext(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, tab: *Tab) callconv(.c) void {
        const c = @import("context.zig").Context.init(tab, .tab);
        tab.owner.context.show(c, gesture.as(gtk.EventController).getWidget().?, x, y);
        _ = gesture.as(gtk.Gesture).setState(.claimed);
    }
    fn placeContext(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, self: *Window) callconv(.c) void {
        const widget = gesture.as(gtk.EventController).getWidget().?;
        self.showPlaceContext(widget, x, y);
        _ = gesture.as(gtk.Gesture).setState(.claimed);
    }
    fn showPlaceContext(self: *Window, widget: *gtk.Widget, x: f64, y: f64) void {
        const file: *gio.File = @ptrCast(@alignCast(widget.as(object.Object).getData("phyto-file").?));
        var c = @import("context.zig").Context.init(self.current(), if (self.preferences.contains("bookmarks", file)) .bookmark else .place);
        c.add(file, null);
        if (widget.as(object.Object).getData("phyto-mount")) |raw| {
            const m: *gio.Mount = @ptrCast(@alignCast(raw));
            m.ref();
            c.mount = m;
            c.kind = .device;
        }
        if (widget.as(object.Object).getData("phyto-volume")) |raw| {
            const v: *gio.Volume = @ptrCast(@alignCast(raw));
            v.ref();
            c.volume = v;
            c.kind = .device;
        }
        self.context.show(c, widget, x, y);
    }
    fn volumesChanged(_: *gio.VolumeMonitor, _: *object.Object, self: *Window) callconv(.c) void {
        if (!self.closed) self.refreshPlaces();
    }
    fn unrefObject(data: ?*anyopaque) callconv(.c) void {
        const obj: *object.Object = @ptrCast(@alignCast(data.?));
        obj.unref();
    }
    pub fn refreshPlaces(self: *Window) void {
        if (self.closed) return;
        self.context.close();
        u.clear(self.sidebar_content);
        self.fillPlaces(self.sidebar_content);
        u.clear(self.popup_content);
        self.fillPlaces(self.popup_content);
        self.queueUpdate();
        if (self.preferences.save_error) self.message("Preferences were not saved", "The preferences file could not be written. Check the configuration directory permissions.");
    }
    pub fn findTab(self: *Window, id: u64) ?*Tab {
        for (self.panes) |pane| for (pane.tabs.items) |tab| if (tab.id == id) return tab;
        return null;
    }
    pub fn setStatus(self: *Window, text: []const u8) void {
        if (self.status_message) |old| a.free(old);
        self.status_message = a.dupeZ(u8, text) catch unreachable;
        self.queueUpdate();
    }
    pub fn resort(self: *Window) void {
        self.context.close();
        for (self.panes) |pane| for (pane.tabs.items) |tab| {
            var selected = @import("context.zig").Context.capture(tab);
            defer selected.deinit();
            tab.sorter.as(gtk.Sorter).changed(.different);
            const model_ = tab.selection.as(gio.ListModel);
            const selection = tab.selection.as(gtk.SelectionModel);
            _ = selection.unselectAll();
            var i: c_uint = 0;
            while (i < model_.getNItems()) : (i += 1) {
                const info: *gio.FileInfo = @ptrCast(model_.getItem(i).?);
                defer info.unref();
                for (selected.items.items) |item| if (item.file.equal(u.file(info)) != 0) {
                    _ = selection.selectItem(i, 0);
                    break;
                };
            }
        };
        self.preferences.save();
        self.queueUpdate();
    }
    pub fn tabCommand(self: *Window, tab: *Tab, command: Command) void {
        self.context.close();
        const pane = tab.pane;
        const p = &self.panes[pane];
        var index: usize = 0;
        for (p.tabs.items, 0..) |t, i| if (t == tab) {
            index = i;
            break;
        };
        switch (command) {
            .tab_duplicate => {
                const file = gio.File.newForUri(tab.uri);
                defer file.unref();
                self.addTab(pane, file);
            },
            .tab_left, .tab_right => {
                const other = if (command == .tab_left) (if (index == 0) return else index - 1) else (if (index + 1 == p.tabs.items.len) return else index + 1);
                std.mem.swap(*Tab, &p.tabs.items[index], &p.tabs.items[other]);
                if (p.selected == index) p.selected = other else if (p.selected == other) p.selected = index;
            },
            .tab_other => {
                if (!self.split or self.panes[1 - pane].tabs.items.len >= 32) return;
                if (p.tabs.items.len == 1) self.addTab(pane, self.home);
                _ = p.tabs.orderedRemove(index);
                p.stack.remove(tab.root.as(gtk.Widget));
                p.selected = @min(p.selected, p.tabs.items.len - 1);
                p.stack.setVisibleChild(p.tabs.items[p.selected].root.as(gtk.Widget));
                const other = &self.panes[1 - pane];
                tab.pane = 1 - pane;
                other.tabs.append(a, tab) catch unreachable;
                _ = other.stack.addChild(tab.root.as(gtk.Widget));
                other.selected = other.tabs.items.len - 1;
                other.stack.setVisibleChild(tab.root.as(gtk.Widget));
                self.active = 1 - pane;
                self.rebuildTabs(1 - pane);
            },
            .tab_close_others => {
                var i = p.tabs.items.len;
                while (i > 0) {
                    i -= 1;
                    if (p.tabs.items[i] == tab) continue;
                    const old = p.tabs.orderedRemove(i);
                    p.stack.remove(old.root.as(gtk.Widget));
                    old.destroy();
                }
                p.selected = 0;
                p.stack.setVisibleChild(tab.root.as(gtk.Widget));
            },
            .close_tab => {
                if (p.tabs.items.len == 1) {
                    if (self.split) {
                        self.split = false;
                        self.active = 1 - pane;
                        self.sync();
                    } else self.window.close();
                    return;
                }
                const selected_tab = p.tabs.items[p.selected];
                _ = p.tabs.orderedRemove(index);
                p.stack.remove(tab.root.as(gtk.Widget));
                tab.destroy();
                if (selected_tab == tab) p.selected = @min(index, p.tabs.items.len - 1) else {
                    for (p.tabs.items, 0..) |t, i| if (t == selected_tab) {
                        p.selected = i;
                        break;
                    };
                }
                p.stack.setVisibleChild(p.tabs.items[p.selected].root.as(gtk.Widget));
            },
            else => {},
        }
        self.rebuildTabs(pane);
        self.sync();
    }
    fn placeClicked(button: *gtk.Button, self: *Window) callconv(.c) void {
        const f: *gio.File = @ptrCast(@alignCast(button.as(object.Object).getData("phyto-file").?));
        if (button.as(object.Object).getData("phyto-volume")) |raw| {
            const volume: *gio.Volume = @ptrCast(@alignCast(raw));
            var c = @import("context.zig").Context.init(self.current(), .device);
            defer c.deinit();
            c.add(f, null);
            volume.ref();
            c.volume = volume;
            @import("platform/applications.zig").volume(self, &c, .mount);
        } else if (self.preferences.contains("favorites", f)) {
            self.app.as(gio.Application).hold();
            const request = a.create(FavoriteRequest) catch unreachable;
            request.* = .{ .owner = self, .tab_id = self.current().id, .generation = self.current().generation };
            f.queryInfoAsync("standard::*,access::*", .{}, 0, self.background_cancel, favoriteQueried, request);
        } else self.current().navigate(f, true);
        self.places_popover.popdown();
    }
    const FavoriteRequest = struct { owner: *Window, tab_id: u64, generation: u64 };
    fn favoriteQueried(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const request: *FavoriteRequest = @ptrCast(@alignCast(data.?));
        const self = request.owner;
        defer {
            self.app.as(gio.Application).release();
            a.destroy(request);
        }
        const file: *gio.File = @ptrCast(source.?);
        var err: ?*glib.Error = null;
        const info = file.queryInfoFinish(result, &err);
        defer if (err) |e| e.free();
        defer if (info) |i| i.unref();
        if (self.closed) return;
        const tab = self.findTab(request.tab_id) orelse return;
        if (tab.generation != request.generation) return;
        if (info) |i| {
            if (i.getFileType() == .directory) tab.navigate(file, true) else self.openFile(file, i);
        } else self.message("Favorite is unavailable", if (err) |e| e.f_message orelse "The item could not be opened." else "The item could not be opened.");
    }
    fn keyboardContext(self: *Window) void {
        var node = self.window.getFocus();
        while (node) |widget| : (node = widget.getParent()) {
            if (widget.as(object.Object).getData("phyto-file") != null) {
                self.showPlaceContext(widget, 8, @floatFromInt(widget.getHeight()));
                return;
            }
            if (widget.as(object.Object).getData("phyto-tab")) |raw| {
                const tab: *Tab = @ptrCast(@alignCast(raw));
                self.context.show(@import("context.zig").Context.init(tab, .tab), widget, 8, @floatFromInt(widget.getHeight()));
                return;
            }
            if (widget == self.location_button.as(gtk.Widget)) {
                var c = @import("context.zig").Context.init(self.current(), .location);
                c.add(c.directory, self.current().directory_info);
                self.context.show(c, widget, 8, @floatFromInt(widget.getHeight()));
                return;
            }
        }
        self.context.keyboard(self.current());
    }
    pub fn sync(self: *Window) void {
        if (self.closed or self.panes[0].tabs.items.len == 0 or self.panes[1].tabs.items.len == 0) return;
        self.syncing = true;
        defer self.syncing = false;
        const tab = self.current();
        self.location_button.setLabel(tab.title);
        self.location_button.as(gtk.Widget).setTooltipText(tab.uri);
        object.ext.cast(gtk.Label, self.location_button.getChild().?).?.setEllipsize(.middle);
        object.ext.cast(gtk.Label, self.location_button.getChild().?).?.setMaxWidthChars(if (self.width < 760) 12 else 26);
        self.search.as(gtk.Editable).setText(tab.query);
        const scope = u.format("In {s}", .{tab.title});
        defer a.free(scope);
        self.search_scope.setText(scope);
        const title = u.format("{s} — Phyto", .{tab.title});
        defer a.free(title);
        self.window.setTitle(title);
        selectedClass(self.split_button.as(gtk.Widget), self.split);
        selectedClass(self.grid_button.as(gtk.Widget), !tab.list_mode);
        selectedClass(self.list_button.as(gtk.Widget), tab.list_mode);
        selectedClass(self.details_button.as(gtk.Widget), self.show_details);
        self.back_button.as(gtk.Widget).setSensitive(@intFromBool(tab.history.cursor > 0));
        self.forward_button.as(gtk.Widget).setSensitive(@intFromBool(tab.history.cursor + 1 < tab.history.items.items.len));
        const f = gio.File.newForUri(tab.uri);
        defer f.unref();
        const parent = f.getParent();
        self.up_button.as(gtk.Widget).setSensitive(@intFromBool(parent != null));
        if (parent) |p| p.unref();
        for (&self.panes, 0..) |*p, i| {
            if (self.split and i == self.active) p.host.as(gtk.Widget).addCssClass("active-pane") else p.host.as(gtk.Widget).removeCssClass("active-pane");
        }
        self.updatePlaceSelection(self.sidebar.getChild().?, f);
        self.queueUpdate();
        self.layout();
    }
    fn updatePlaceSelection(self: *Window, parent: *gtk.Widget, file: *gio.File) void {
        if (parent.as(object.Object).getData("phyto-file")) |data| {
            const target: *gio.File = @ptrCast(@alignCast(data));
            selectedClass(parent, file.equal(target) != 0);
        }
        var child = parent.getFirstChild();
        while (child) |w| : (child = w.getNextSibling()) self.updatePlaceSelection(w, file);
    }
    fn selectedClass(widget: *gtk.Widget, selected: bool) void {
        if (selected) widget.addCssClass("selected") else widget.removeCssClass("selected");
    }
    pub fn queueUpdate(self: *Window) void {
        if (!self.closed and self.update_id == 0) self.update_id = glib.idleAdd(updateIdle, self);
    }
    fn updateIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.update_id = 0;
        if (self.closed) return 0;
        for (&self.panes) |*p| for (p.tabs.items) |t| t.update();
        const tab = self.current();
        const set = tab.selection.as(gtk.SelectionModel).getSelection();
        defer set.unref();
        const text = u.format("{d} items · {d} selected{s}{s}", .{ tab.selection.as(gio.ListModel).getNItems(), set.getSize(), if (tab.directory.isLoading() != 0) " · Loading…" else "", if (tab.directory.getError() != null) " · Folder could not be fully read" else "" });
        defer a.free(text);
        self.status.setText(if (self.status_message) |msg| msg else text);
        self.updateDetails();
        self.context.update();
        var current_context = @import("context.zig").Context.capture(tab);
        defer current_context.deinit();
        for (std.enums.values(Command)) |cmd| if (@import("actions.zig").fileAction(cmd)) {
            const action: *gio.SimpleAction = @ptrCast(object.ext.cast(gtk.ApplicationWindow, self.window).?.as(gio.ActionMap).lookupAction(@tagName(cmd)).?);
            action.setEnabled(@intFromBool(self.context.allowed(&current_context, cmd)));
        };
        return 0;
    }
    fn updateDetails(self: *Window) void {
        const selection = self.current().selection.as(gtk.SelectionModel).getSelection();
        defer selection.unref();
        const visible = self.show_details and !self.split and self.width >= 1000;
        const selected_info = if (visible and selection.getSize() == 1) self.current().selected() else null;
        defer if (selected_info) |i| i.unref();
        const source_key = if (selected_info) |i| @import("platform/thumbnails.zig").identity(i, 512, self.preferences.thumbnail_limit, true) else u.format("selection:{d}:{d}", .{ selection.getSize(), @intFromBool(visible) });
        defer a.free(source_key);
        const key = u.format("{d}:{d}:{s}", .{ self.current().id, self.current().generation, source_key });
        if (self.details_key) |old| {
            if (std.mem.eql(u8, old, key)) {
                a.free(key);
                return;
            }
            a.free(old);
        }
        self.details_key = key;
        u.clear(self.details_body);
        if (!visible) return;
        const top = u.box(.horizontal, 8, null);
        const heading = u.label("File details", "secondary");
        heading.as(gtk.Widget).setHexpand(1);
        top.append(heading.as(gtk.Widget));
        const close = u.iconButton("window-close-symbolic", "Close details");
        self.connect(close, .details);
        top.append(close.as(gtk.Widget));
        self.details_body.append(top.as(gtk.Widget));
        const info = selected_info orelse {
            const selection_message = if (selection.getSize() > 1) u.format("{d} items selected. Open Properties for selection details.", .{selection.getSize()}) else u.format("Select a file to see its details.", .{});
            defer a.free(selection_message);
            const empty = u.label(selection_message, "secondary");
            empty.setWrap(1);
            self.details_body.append(empty.as(gtk.Widget));
            return;
        };
        const preview = @import("preview.zig").Slot.create(.details);
        preview.set(info);
        self.details_body.append(preview.root.as(gtk.Widget));
        const name = u.label(info.getDisplayName(), "file-title");
        name.setWrap(1);
        name.setWrapMode(.word_char);
        name.setMaxWidthChars(24);
        name.setSelectable(1);
        self.details_body.append(name.as(gtk.Widget));
        const type_ = if (info.getContentType()) |t| gio.contentTypeGetDescription(t) else glib.strdup("File");
        defer glib.free(type_);
        self.detail("Type", type_);
        self.detail("Location", self.current().title);
        const size = u.sizeText(info);
        defer glib.free(size);
        self.detail("Size", size);
        const date = u.dateText(info);
        defer glib.free(date);
        self.detail("Modified", date);
        self.detail("Access", if (info.hasAttribute("access::can-write") == 0) "Not reported" else if (info.getAttributeBoolean("access::can-write") != 0) "You can read and write" else "Read only");
        const properties = gtk.Button.newWithLabel("Properties");
        properties.as(gtk.Widget).addCssClass("tonal");
        self.connect(properties, .properties);
        self.details_body.append(properties.as(gtk.Widget));
    }
    fn detail(self: *Window, title: [*:0]const u8, value: [*:0]const u8) void {
        const row = u.box(.vertical, 4, "metadata");
        row.append(u.label(title, "secondary").as(gtk.Widget));
        const text = u.label(value, null);
        text.setWrap(1);
        text.setWrapMode(.word_char);
        text.setMaxWidthChars(24);
        text.setSelectable(1);
        row.append(text.as(gtk.Widget));
        self.details_body.append(row.as(gtk.Widget));
    }
    fn layout(self: *Window) void {
        @import("preview.zig").schedule();
        self.queueUpdate();
        if (self.closed) return;
        const narrow = self.width < 760;
        self.sidebar.as(gtk.Widget).setVisible(@intFromBool(!narrow));
        self.places_button.as(gtk.Widget).setVisible(@intFromBool(narrow));
        self.split_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1100));
        self.jobs_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1100));
        self.forward_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1000));
        self.up_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1000));
        self.home_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1000));
        self.back_button.as(gtk.Widget).setVisible(@intFromBool(!narrow));
        self.details_button.as(gtk.Widget).setVisible(@intFromBool(self.width >= 1000));
        self.details.as(gtk.Widget).setVisible(@intFromBool(self.show_details and !self.split and self.width >= 1000));
        self.search_scope.as(gtk.Widget).setVisible(@intFromBool(!narrow));
        self.pane_switch.as(gtk.Widget).setVisible(@intFromBool(self.split));
        for (&self.panes, 0..) |*p, i| {
            const visible = if (!self.split) i == self.active else if (self.width < 980) i == self.active else true;
            p.host.as(gtk.Widget).setVisible(@intFromBool(visible));
            for (p.tabs.items) |t| {
                const columns = t.list.getColumns();
                const modified: *gtk.ColumnViewColumn = @ptrCast(columns.getItem(2).?);
                modified.setVisible(@intFromBool(!narrow and !self.split));
                modified.unref();
            }
        }
        if (narrow) self.window.as(gtk.Widget).addCssClass("narrow") else self.window.as(gtk.Widget).removeCssClass("narrow");
    }
    fn realized(_: *gtk.Widget, self: *Window) callconv(.c) void {
        self.native_surface = self.window.as(gtk.Native).getSurface();
        if (self.native_surface) |surface| {
            surface.ref();
            self.native_signal = gdk.Surface.signals.layout.connect(surface, *Window, resized, self, .{});
        }
    }
    fn resized(_: *gdk.Surface, _: c_int, _: c_int, self: *Window) callconv(.c) void {
        if (!self.closed and self.resize_id == 0) self.resize_id = glib.idleAdd(resizeIdle, self);
    }
    fn resizeIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.resize_id = 0;
        self.width = self.window.as(gtk.Widget).getWidth();
        self.layout();
        return 0;
    }
    fn applyTheme(self: *Window) void {
        for ([_][*:0]const u8{ "dark", "light", "native", "compact" }) |class| self.window.as(gtk.Widget).removeCssClass(class);
        self.window.as(gtk.Widget).addCssClass(if (self.options.native) "native" else if (self.options.light) "light" else "dark");
        if (self.options.compact) self.window.as(gtk.Widget).addCssClass("compact");
    }
    fn pathEntered(entry: *gtk.Entry, self: *Window) callconv(.c) void {
        const text = entry.as(gtk.Editable).getText();
        if (text[0] == 0) return;
        const parent = gio.File.newForUri(self.current().uri);
        defer parent.unref();
        const value = std.mem.span(text);
        const file = if (std.mem.eql(u8, value, "~")) blk: {
            self.home.ref();
            break :blk self.home;
        } else if (std.mem.startsWith(u8, value, "~/")) self.home.resolveRelativePath(text + 2) else if (std.mem.indexOf(u8, value, "://") != null or std.fs.path.isAbsolute(value)) gio.File.newForCommandlineArg(text) else parent.resolveRelativePath(text);
        defer file.unref();
        self.current().navigate(file, true);
        self.navigation.setVisibleChildName("breadcrumb");
        _ = (if (self.current().list_mode) self.current().list.as(gtk.Widget) else self.current().grid.as(gtk.Widget)).grabFocus();
    }
    fn searchChanged(entry: *gtk.SearchEntry, self: *Window) callconv(.c) void {
        if (!self.syncing) self.current().setQuery(std.mem.span(entry.as(gtk.Editable).getText()));
    }
    fn stopSearch(_: *gtk.SearchEntry, self: *Window) callconv(.c) void {
        self.closeSearch();
    }
    fn closeSearch(self: *Window) void {
        self.search_row.as(gtk.Widget).setVisible(0);
        self.current().setQuery("");
        self.sync();
    }
    pub fn dispatch(self: *Window, command: Command) void {
        if (self.closed) return;
        if (@import("actions.zig").fileAction(command)) {
            self.context.fresh(command);
            return;
        }
        self.context.close();
        if (self.status_message) |msg| {
            a.free(msg);
            self.status_message = null;
        }
        const t = self.current();
        switch (command) {
            .back, .forward => {
                const uri = (if (command == .back) t.history.back() else t.history.forward()) orelse return;
                const f = gio.File.newForUri(uri);
                defer f.unref();
                t.navigate(f, false);
            },
            .up => {
                const f = gio.File.newForUri(t.uri);
                defer f.unref();
                const parent = f.getParent() orelse return;
                defer parent.unref();
                t.navigate(parent, true);
            },
            .home => t.navigate(self.home, true),
            .location => {
                t.focus_pending = false;
                const f = gio.File.newForUri(t.uri);
                defer f.unref();
                const text = f.getParseName();
                defer glib.free(text);
                self.path.as(gtk.Editable).setText(text);
                self.navigation.setVisibleChildName("entry");
                _ = self.path.as(gtk.Widget).grabFocus();
                self.path.as(gtk.Editable).selectRegion(0, -1);
            },
            .search => {
                t.focus_pending = false;
                if (self.search_row.as(gtk.Widget).getVisible() != 0) self.closeSearch() else {
                    self.search_row.as(gtk.Widget).setVisible(1);
                    _ = self.search.as(gtk.Widget).grabFocus();
                }
            },
            .refresh => t.refresh(),
            .grid => t.setView(false),
            .list => t.setView(true),
            .split => {
                self.split = !self.split;
                if (!self.split) self.active = 0;
                self.paned.setPosition(@divTrunc(@max(400, self.width - 256), 2));
                self.sync();
            },
            .switch_pane => {
                if (self.split) self.activatePane(1 - self.active);
            },
            .details => {
                self.show_details = !self.show_details;
                self.sync();
            },
            .hidden => {
                t.hidden = !t.hidden;
                t.filter.as(gtk.Filter).changed(.different);
                self.queueUpdate();
            },
            .new_tab => {
                const f = gio.File.newForUri(t.uri);
                defer f.unref();
                self.addTab(self.active, f);
                self.sync();
            },
            .close_tab => self.tabCommand(t, .close_tab),
            .new_window => {
                const f = gio.File.newForUri(t.uri);
                defer f.unref();
                @import("main.zig").newWindow(self.app, f, self.options);
            },
            .light => {
                self.options.native = false;
                self.options.light = !self.options.light;
                self.applyTheme();
            },
            .compact => {
                self.options.compact = !self.options.compact;
                self.applyTheme();
            },
            .native => {
                self.options.native = !self.options.native;
                self.applyTheme();
            },
            .operations => self.operations.present(),
            .sort_name, .sort_size, .sort_type, .sort_modified => {
                self.preferences.sort = switch (command) {
                    .sort_size => .size,
                    .sort_type => .type,
                    .sort_modified => .modified,
                    else => .name,
                };
                self.resort();
            },
            .reverse => {
                self.preferences.reverse = !self.preferences.reverse;
                self.resort();
            },
            .folders_first => {
                self.preferences.folders_first = !self.preferences.folders_first;
                self.resort();
            },
            .thumbnails, .preview_details => {
                if (command == .thumbnails) self.preferences.thumbnails = !self.preferences.thumbnails else self.preferences.preview_details = !self.preferences.preview_details;
                self.preferences.save();
                @import("main.zig").previewPreferencesChanged();
            },
            .advanced, .allow_delete => {
                if (command == .advanced) self.preferences.advanced = !self.preferences.advanced else self.preferences.allow_delete = !self.preferences.allow_delete;
                self.preferences.save();
                const action: *gio.SimpleAction = @ptrCast(object.ext.cast(gtk.ApplicationWindow, self.window).?.as(gio.ActionMap).lookupAction(@tagName(command)).?);
                action.setState(glib.Variant.newBoolean(@intFromBool(if (command == .advanced) self.preferences.advanced else self.preferences.allow_delete)));
            },
            else => {},
        }
    }
    pub fn keyPressed(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, mods: gdk.ModifierType, self: *Window) callconv(.c) c_int {
        if (@import("build_options").test_hooks and key == gdk.KEY_F12) {
            self.probe();
            return 1;
        }
        if (self.context.active) {
            if (key == gdk.KEY_Escape) {
                self.context.close();
                return 1;
            }
            // Let the native menu process arrows, activation and mnemonics.
            if (!mods.control_mask and !mods.alt_mask) return 0;
        }
        if (mods.control_mask) {
            const command: ?Command = switch (key) {
                gdk.KEY_l => .location,
                gdk.KEY_f => .search,
                gdk.KEY_h => .hidden,
                gdk.KEY_t => .new_tab,
                gdk.KEY_w => .close_tab,
                gdk.KEY_n, gdk.KEY_N => if (mods.shift_mask) .new_folder else .new_window,
                gdk.KEY_1 => .grid,
                gdk.KEY_2 => .list,
                else => null,
            };
            if (command) |c| {
                self.dispatch(c);
                return 1;
            }
            if (key == gdk.KEY_Tab or key == gdk.KEY_ISO_Left_Tab) {
                const p = &self.panes[self.active];
                p.selected = (p.selected + (if (mods.shift_mask) p.tabs.items.len - 1 else @as(usize, 1))) % p.tabs.items.len;
                p.stack.setVisibleChild(p.tabs.items[p.selected].root.as(gtk.Widget));
                self.rebuildTabs(self.active);
                self.sync();
                return 1;
            }
        }
        if (mods.alt_mask) {
            const command: ?Command = switch (key) {
                gdk.KEY_Left => .back,
                gdk.KEY_Right => .forward,
                gdk.KEY_Up => .up,
                gdk.KEY_Return => .properties,
                else => null,
            };
            if (command) |c| {
                self.dispatch(c);
                return 1;
            }
        }
        const focus = self.window.getFocus();
        const editing = self.navigation.getVisibleChild() == self.path.as(gtk.Widget) or (if (focus) |f| f == self.search.as(gtk.Widget) or f.isAncestor(self.search.as(gtk.Widget)) != 0 else false);
        if (!editing) {
            const view = if (self.current().list_mode) self.current().list.as(gtk.Widget) else self.current().grid.as(gtk.Widget);
            const in_files = if (focus) |f| f == view or f.isAncestor(view) != 0 else false;
            if (in_files and key == gdk.KEY_space and !mods.control_mask and !mods.shift_mask and !mods.alt_mask and !mods.super_mask) {
                const set = self.current().selection.as(gtk.SelectionModel).getSelection();
                defer set.unref();
                if (set.getSize() == 1) {
                    const selected_info = self.current().selected() orelse return 0;
                    defer selected_info.unref();
                    if (selected_info.getFileType() == .directory) return 0;
                    self.dispatch(.preview);
                    return 1;
                }
            }
            if (key == gdk.KEY_Menu or (key == gdk.KEY_F10 and mods.shift_mask)) {
                self.keyboardContext();
                return 1;
            }
            if (mods.control_mask and key == gdk.KEY_x) {
                self.dispatch(.cut);
                return 1;
            }
            if (mods.control_mask and (key == gdk.KEY_z or key == gdk.KEY_Z)) {
                self.dispatch(if (mods.shift_mask) .redo else .undo);
                return 1;
            }
            if (mods.control_mask and key == gdk.KEY_o) {
                self.dispatch(.open);
                return 1;
            }
            if (key == gdk.KEY_F4 and mods.shift_mask) {
                self.dispatch(.terminal);
                return 1;
            }
            if (mods.control_mask and key == gdk.KEY_c) {
                self.dispatch(.copy);
                return 1;
            }
            if (mods.control_mask and key == gdk.KEY_v) {
                self.dispatch(.paste);
                return 1;
            }
            if (key == gdk.KEY_F2) {
                self.dispatch(.rename);
                return 1;
            }
            if (key == gdk.KEY_Delete) {
                self.dispatch(if (mods.shift_mask) .delete else .trash);
                return 1;
            }
        }
        if (key == gdk.KEY_F3) {
            self.dispatch(.split);
            return 1;
        }
        if (key == gdk.KEY_F5) {
            self.dispatch(.refresh);
            return 1;
        }
        if (key == gdk.KEY_F6) {
            self.dispatch(.switch_pane);
            return 1;
        }
        if (key == gdk.KEY_Escape) {
            self.navigation.setVisibleChildName("breadcrumb");
            self.closeSearch();
            self.places_popover.popdown();
            return 1;
        }
        return 0;
    }
    const ProbeWidget = struct { label: []const u8, kind: []const u8, x: f64, y: f64, width: c_int, height: c_int, menu: bool, sensitive: bool, thumbnail_uri: []const u8 = "" };
    fn probeWidgets(self: *Window, widget: *gtk.Widget, result: *std.ArrayList(ProbeWidget)) void {
        if (widget.getMapped() == 0) return;
        var label: ?[*:0]const u8 = null;
        var kind: []const u8 = "label";
        var thumbnail_uri: []const u8 = "";
        if (widget.as(object.Object).getData("phyto-item")) |raw| {
            const item: *gtk.ListItem = @ptrCast(@alignCast(raw));
            if (item.getItem()) |obj| {
                const info = object.ext.cast(gio.FileInfo, obj).?;
                label = info.getDisplayName();
                kind = "file";
                if (widget.getFirstChild()) |visual| if (visual.as(object.Object).getData("phyto-preview") != null) {
                    const slot = @import("preview.zig").Slot.from(visual);
                    if (slot.entry) |e| if (e.texture != null) {
                        thumbnail_uri = e.uri;
                    };
                };
            }
        } else if (object.ext.cast(gtk.Label, widget)) |text| label = text.getText();
        if (label) |text| if (text[0] != 0) {
            var x: f64 = 0;
            var y: f64 = 0;
            if (widget.translateCoordinates(self.window.as(gtk.Widget), 0, 0, &x, &y) != 0) result.append(a, .{ .label = std.mem.span(text), .kind = kind, .x = x, .y = y, .width = widget.getWidth(), .height = widget.getHeight(), .menu = if (self.context.popover) |p| widget.isAncestor(p.as(gtk.Widget)) != 0 else false, .sensitive = widget.isSensitive() != 0, .thumbnail_uri = thumbnail_uri }) catch unreachable;
        };
        var child = widget.getFirstChild();
        while (child) |w| : (child = w.getNextSibling()) self.probeWidgets(w, result);
    }
    pub fn probe(self: *Window) void {
        const t = self.current();
        const selection = t.selection.as(gtk.SelectionModel).getSelection();
        defer selection.unref();
        const selected = t.selected();
        defer if (selected) |i| i.unref();
        var realized_rows: usize = 0;
        var child = t.grid.as(gtk.Widget).getFirstChild();
        while (child) |c| : (child = c.getNextSibling()) {
            realized_rows += 1;
        }
        var widgets: std.ArrayList(ProbeWidget) = .empty;
        defer widgets.deinit(a);
        self.probeWidgets(self.window.as(gtk.Widget), &widgets);
        const json = std.json.Stringify.valueAlloc(a, .{
            .realized_grid_children = realized_rows,
            .thumbnail_slots_ready = @import("preview.zig").readyCount(),
            .preview_memory = @import("platform/thumbnails.zig").memory,
            .preview_jobs = @import("platform/thumbnails.zig").running,
            .preview_started = @import("platform/thumbnails.zig").started,
            .preview_max_main_loop_gap_us = @import("platform/thumbnails.zig").max_main_loop_gap_us,
            .preview_cache_hits = @import("platform/thumbnails.zig").hits,
            .quick_preview = self.quick_preview != null,
            .quick_surface = if (self.quick_preview) |q| std.mem.span(q.slot.root.getVisibleChildName() orelse "none") else "closed",
            .quick_paintable = if (self.quick_preview) |q| q.slot.picture.getPaintable() != null else false,
            .quick_kind = if (self.quick_preview) |q| if (q.slot.entry) |e| if (e.state == .ready) @tagName(e.kind) else "pending" else "pending" else "closed",
            .thumbnails_enabled = self.preferences.thumbnails,
            .details_preview_enabled = self.preferences.preview_details,
            .focus_name = if (self.window.getFocus()) |f| std.mem.span(f.getName()) else "none",
            .uri = t.uri,
            .title = t.title,
            .query = t.query,
            .count = t.selection.as(gio.ListModel).getNItems(),
            .loading = t.directory.isLoading() != 0,
            .failed = t.directory.getError() != null,
            .selected = selection.getSize(),
            .selected_name = if (selected) |i| std.mem.span(i.getDisplayName()) else "",
            .list = t.list_mode,
            .split = self.split,
            .active = self.active,
            .tabs = .{ self.panes[0].tabs.items.len, self.panes[1].tabs.items.len },
            .left_visible = self.panes[0].host.as(gtk.Widget).getVisible() != 0,
            .right_visible = self.panes[1].host.as(gtk.Widget).getVisible() != 0,
            .width = self.width,
            .height = self.window.as(gtk.Widget).getHeight(),
            .details = self.details.as(gtk.Widget).getVisible() != 0,
            .sidebar = self.sidebar.as(gtk.Widget).getVisible() != 0,
            .widgets = widgets.items,
            .write_capable = if (t.directory_info) |i| i.getAttributeBoolean("access::can-write") != 0 else false,
            .operation_result = self.operations.result,
            .context_open = self.context.active,
            .context_count = if (self.context.snapshot) |c| c.items.items.len else 0,
            .context_kind = if (self.context.snapshot) |c| @tagName(c.kind) else "none",
            .clipboard_count = self.clipboard.files.items.len,
            .clipboard_cut = self.clipboard.cut,
            .undo_count = self.operations.undo_stack.items.len,
            .redo_count = self.operations.redo_stack.items.len,
            .busy = self.operations.busy,
            .conflict = self.operations.conflict,
        }, .{}) catch return;
        defer a.free(json);
        const text = u.format("PHYTO_PROBE {s}\n", .{json});
        defer a.free(text);
        glib.print("%s", text.ptr);
    }
    pub fn message(self: *Window, title: [*:0]const u8, text: [*:0]const u8) void {
        if (self.closed) return;
        if (self.message_dialog) |old| old.as(gtk.Window).destroy();
        const dialog = gtk.Dialog.new();
        self.message_dialog = dialog;
        dialog.as(gtk.Widget).addCssClass("phyto-root");
        dialog.as(gtk.Widget).addCssClass(if (self.options.native) "native" else if (self.options.light) "light" else "dark");
        dialog.as(gtk.Window).setTitle(title);
        dialog.as(gtk.Window).setTransientFor(self.window);
        dialog.as(gtk.Window).setModal(1);
        dialog.as(gtk.Window).setDefaultSize(420, -1);
        const body = dialog.getContentArea();
        body.as(gtk.Widget).addCssClass("dialog-body");
        body.append(u.label(title, "state-title").as(gtk.Widget));
        const caption = u.label(text, null);
        caption.setWrap(1);
        caption.setWrapMode(.word_char);
        caption.setMaxWidthChars(50);
        caption.setSelectable(1);
        const scroll = u.scroll(caption.as(gtk.Widget));
        scroll.setMaxContentHeight(420);
        scroll.setPropagateNaturalHeight(1);
        body.append(scroll.as(gtk.Widget));
        _ = dialog.addButton("Close", @intFromEnum(gtk.ResponseType.close));
        _ = gtk.Dialog.signals.response.connect(dialog, *Window, messageResponse, self, .{});
        dialog.as(gtk.Window).present();
    }
    fn messageResponse(dialog: *gtk.Dialog, _: c_int, self: *Window) callconv(.c) void {
        self.message_dialog = null;
        dialog.as(gtk.Window).destroy();
    }
    pub fn openFile(self: *Window, file: *gio.File, info: *gio.FileInfo) void {
        if (info.getAttributeBoolean("access::can-execute") != 0 or std.mem.endsWith(u8, std.mem.span(info.getName()), ".desktop")) {
            self.message("Executable file", "Executable files are not launched by double-click. Open them deliberately using another application.");
            return;
        }
        const uri = file.getUri();
        defer glib.free(uri);
        const context = gdk.Display.getDefault().?.getAppLaunchContext();
        defer context.unref();
        self.app.as(gio.Application).hold();
        gio.AppInfo.launchDefaultForUriAsync(uri, context.as(gio.AppLaunchContext), null, launched, self);
    }
    fn launched(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        if (gio.AppInfo.launchDefaultForUriFinish(result, &err) == 0) if (err) |e| {
            defer e.free();
            self.message("Could not open file", e.f_message orelse "Unknown I/O error");
        };
        self.app.as(gio.Application).release();
    }
    fn closing(_: *gtk.Window, self: *Window) callconv(.c) c_int {
        if (self.operations.busy) {
            self.operations.present();
            return 1;
        }
        self.context.stop();
        self.clipboard.stop();
        self.background_cancel.cancel();
        for (self.volume_signals) |signal| object.signalHandlerDisconnect(self.volume_monitor.as(object.Object), signal);
        self.closed = true;
        if (self.quick_preview) |q| q.window.close();
        if (self.update_id != 0) {
            _ = glib.Source.remove(self.update_id);
            self.update_id = 0;
        }
        if (self.resize_id != 0) {
            _ = glib.Source.remove(self.resize_id);
            self.resize_id = 0;
        }
        if (self.native_surface) |s| {
            object.signalHandlerDisconnect(s.as(object.Object), self.native_signal);
            s.unref();
            self.native_surface = null;
        }
        self.operations.closeDialogs();
        if (self.message_dialog) |d| {
            d.as(gtk.Window).destroy();
            self.message_dialog = null;
        }
        for (&self.panes) |*p| for (p.tabs.items) |t| {
            t.ready = false;
            t.directory.setFile(null);
        };
        // Release closed-window widgets/models immediately, even if another
        // window or an outstanding launch request keeps the process alive.
        self.window.setChild(null);
        for (&self.panes) |*p| {
            for (p.tabs.items) |t| t.destroy();
            p.tabs.clearRetainingCapacity();
        }
        return 0;
    }
    pub fn destroy(self: *Window) void {
        if (!self.closed) {
            _ = closing(self.window, self);
            self.window.destroy();
        }
        for (&self.panes) |*p| {
            for (p.tabs.items) |t| t.destroy();
            p.tabs.deinit(a);
        }
        self.operations.deinit();
        self.home.unref();
        self.context.deinit();
        self.clipboard.deinit();
        self.preferences.release();
        if (self.details_key) |key| a.free(key);
        self.volume_monitor.unref();
        self.background_cancel.unref();
        if (self.status_message) |msg| a.free(msg);
        a.destroy(self);
    }
};

extern "c" fn g_volume_monitor_get_mounts(*gio.VolumeMonitor) ?*glib.List;
extern "c" fn g_volume_monitor_get_volumes(*gio.VolumeMonitor) ?*glib.List;
