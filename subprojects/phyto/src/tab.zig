const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const a = u.a;
const Window = @import("window.zig").Window;
const History = @import("core/model.zig").History;

pub const Tab = struct {
    owner: *Window,
    pane: usize,
    root: *gtk.Stack,
    views: *gtk.Stack,
    grid: *gtk.GridView,
    list: *gtk.ColumnView,
    directory: *gtk.DirectoryList,
    filter: *gtk.CustomFilter,
    selection: *gtk.MultiSelection,
    error_label: *gtk.Label,
    error_title: *gtk.Label,
    history: History = .{ .allocator = a },
    uri: [:0]u8,
    title: [:0]u8,
    query: [:0]u8,
    hidden: bool = false,
    list_mode: bool = false,
    alive: bool = true,
    ready: bool = false,
    focus_pending: bool = false,
    pub fn create(owner: *Window, pane: usize, file: *gio.File) *Tab {
        const self = a.create(Tab) catch @panic("Out of memory");
        const root = gtk.Stack.new();
        root.setHhomogeneous(0);
        root.setVhomogeneous(0);
        _ = root.as(object.Object).refSink();
        root.as(gtk.Widget).setVexpand(1);
        root.as(gtk.Widget).setHexpand(1);
        const directory = gtk.DirectoryList.new("standard::*,time::modified,access::*", null);
        directory.setIoPriority(200);
        directory.setMonitored(1);
        const filter = gtk.CustomFilter.new(matches, self, null);
        directory.ref();
        filter.ref();
        const filtered = gtk.FilterListModel.new(directory.as(gio.ListModel), filter.as(gtk.Filter));
        const sorter = gtk.CustomSorter.new(compare, null, null);
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), sorter.as(gtk.Sorter));
        const selection = gtk.MultiSelection.new(sorted.as(gio.ListModel));
        selection.ref();
        const gf = factory(.grid);
        const grid = gtk.GridView.new(selection.as(gtk.SelectionModel), gf.as(gtk.ListItemFactory));
        grid.setMinColumns(1);
        grid.setMaxColumns(16);
        grid.setEnableRubberband(1);
        grid.as(gtk.Widget).addCssClass("files-grid");
        u.name(grid.as(gtk.Widget), "Files in icon view");
        selection.ref();
        const list = gtk.ColumnView.new(selection.as(gtk.SelectionModel));
        list.setEnableRubberband(1);
        list.as(gtk.Widget).addCssClass("files-list");
        u.name(list.as(gtk.Widget), "Files in detailed list");
        inline for (.{ .{ "Name", Column.name }, .{ "Size", Column.size }, .{ "Modified", Column.modified } }) |col| {
            const f = factory(col[1]);
            const c = gtk.ColumnViewColumn.new(col[0], f.as(gtk.ListItemFactory));
            c.setExpand(@intFromBool(col[1] == .name));
            if (col[1] != .name) c.setFixedWidth(if (col[1] == .size) 88 else 156);
            list.appendColumn(c);
            c.unref();
        }
        const views = gtk.Stack.new();
        views.setHhomogeneous(0);
        views.setVhomogeneous(0);
        _ = views.addNamed(u.scroll(grid.as(gtk.Widget)).as(gtk.Widget), "grid");
        _ = views.addNamed(u.scroll(list.as(gtk.Widget)).as(gtk.Widget), "list");
        _ = root.addNamed(views.as(gtk.Widget), "files");
        const empty = u.box(.vertical, 12, "empty-state");
        empty.as(gtk.Widget).setHalign(.center);
        empty.as(gtk.Widget).setValign(.center);
        empty.append(u.image("folder-symbolic", 48).as(gtk.Widget));
        const error_title = u.label("This folder is empty", "state-title");
        empty.append(error_title.as(gtk.Widget));
        const error_label = u.label("Create a folder, or choose another location.", "secondary");
        error_label.setWrap(1);
        error_label.setMaxWidthChars(42);
        error_label.setJustify(.center);
        empty.append(error_label.as(gtk.Widget));
        const retry = gtk.Button.newWithLabel("Refresh folder");
        _ = gtk.Button.signals.clicked.connect(retry, *Tab, refreshClicked, self, .{});
        retry.as(gtk.Widget).setHalign(.center);
        empty.append(retry.as(gtk.Widget));
        _ = root.addNamed(empty.as(gtk.Widget), "empty");
        self.* = .{ .owner = owner, .pane = pane, .root = root, .views = views, .grid = grid, .list = list, .directory = directory, .filter = filter, .selection = selection, .error_label = error_label, .error_title = error_title, .uri = a.dupeZ(u8, "") catch unreachable, .title = a.dupeZ(u8, "") catch unreachable, .query = a.dupeZ(u8, "") catch unreachable };
        _ = object.Object.signals.notify.connect(directory.as(object.Object), *Tab, directoryChanged, self, .{});
        _ = gtk.SelectionModel.signals.selection_changed.connect(selection.as(gtk.SelectionModel), *Tab, selectionChanged, self, .{});
        _ = gio.ListModel.signals.items_changed.connect(selection.as(gio.ListModel), *Tab, itemsChanged, self, .{});
        _ = gtk.GridView.signals.activate.connect(grid, *Tab, activated, self, .{});
        _ = gtk.ColumnView.signals.activate.connect(list, *Tab, activatedList, self, .{});
        const click = gtk.GestureClick.new();
        click.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Tab, pressed, self, .{});
        root.as(gtk.Widget).addController(click.as(gtk.EventController));
        self.navigate(file, true);
        self.ready = true;
        return self;
    }
    pub fn destroy(self: *Tab) void {
        self.alive = false;
        self.directory.setFile(null);
        self.root.unref();
        self.selection.unref();
        self.filter.unref();
        self.directory.unref();
        self.history.deinit();
        a.free(self.uri);
        a.free(self.title);
        a.free(self.query);
        a.destroy(self);
    }
    pub fn navigate(self: *Tab, file: *gio.File, add_history: bool) void {
        const uri = file.getUri();
        defer glib.free(uri);
        if (add_history) self.history.visit(std.mem.span(uri)) catch return;
        const title = file.getBasename() orelse glib.strdup("Files");
        defer glib.free(title);
        a.free(self.uri);
        a.free(self.title);
        self.uri = a.dupeZ(u8, std.mem.span(uri)) catch unreachable;
        self.title = a.dupeZ(u8, if (file.equal(self.owner.home) != 0) "Home" else std.mem.span(title)) catch unreachable;
        _ = self.selection.as(gtk.SelectionModel).unselectAll();
        self.directory.setFile(file);
        if (self.ready) {
            self.focus_pending = true;
            self.owner.rebuildTabs(self.pane);
            self.owner.sync();
        }
    }
    pub fn refresh(self: *Tab) void {
        const f = gio.File.newForUri(self.uri);
        defer f.unref();
        self.directory.setFile(null);
        self.directory.setFile(f);
    }
    pub fn setQuery(self: *Tab, query: []const u8) void {
        a.free(self.query);
        self.query = a.dupeZ(u8, query) catch unreachable;
        self.filter.as(gtk.Filter).changed(.different);
        self.owner.queueUpdate();
    }
    pub fn setView(self: *Tab, list: bool) void {
        self.list_mode = list;
        self.views.setVisibleChildName(if (list) "list" else "grid");
        self.owner.sync();
    }
    pub fn selected(self: *Tab) ?*gio.FileInfo {
        const set = self.selection.as(gtk.SelectionModel).getSelection();
        defer set.unref();
        if (set.isEmpty() != 0) return null;
        return @ptrCast(self.selection.as(gio.ListModel).getItem(set.getMinimum()) orelse return null);
    }
    pub fn update(self: *Tab) void {
        const count = self.selection.as(gio.ListModel).getNItems();
        if (self.directory.getError()) |err| {
            self.error_title.setText("Cannot open this folder");
            self.error_label.setText(err.f_message orelse "Could not load directory");
        } else if (self.directory.isLoading() != 0) {
            self.error_title.setText("Loading folder…");
            self.error_label.setText("You can navigate elsewhere while files load.");
        } else if (self.query.len != 0) {
            self.error_title.setText("No matching filenames");
            self.error_label.setText("Try a shorter name, or clear the search.");
        } else {
            self.error_title.setText("This folder is empty");
            self.error_label.setText("Create a folder, or choose another location.");
        }
        self.root.setVisibleChildName(if (count == 0) "empty" else "files");
        if (self.focus_pending and self.directory.isLoading() == 0) {
            self.focus_pending = false;
            if (self.owner.current() == self and count > 0) {
                const view = if (self.list_mode) self.list.as(gtk.Widget) else self.grid.as(gtk.Widget);
                _ = view.grabFocus();
                _ = view.childFocus(.tab_forward);
            }
        }
    }
    fn matches(item: *object.Object, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Tab = @ptrCast(@alignCast(data.?));
        const info = object.ext.cast(gio.FileInfo, item).?;
        if (!self.hidden and info.getIsHidden() != 0) return 0;
        if (self.query.len == 0) return 1;
        const folded = glib.utf8Casefold(info.getDisplayName(), -1);
        defer glib.free(folded);
        const needle = glib.utf8Casefold(self.query, -1);
        defer glib.free(needle);
        return @intFromBool(std.mem.indexOf(u8, std.mem.span(folded), std.mem.span(needle)) != null);
    }
    fn compare(left: ?*const anyopaque, right: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const l: *gio.FileInfo = @ptrCast(@alignCast(@constCast(left.?)));
        const r: *gio.FileInfo = @ptrCast(@alignCast(@constCast(right.?)));
        const ld = l.getFileType() == .directory;
        const rd = r.getFileType() == .directory;
        if (ld != rd) return if (ld) -1 else 1;
        return glib.utf8Collate(l.getDisplayName(), r.getDisplayName());
    }
    fn directoryChanged(_: *object.Object, _: *object.ParamSpec, self: *Tab) callconv(.c) void {
        if (self.alive and self.ready) self.owner.queueUpdate();
    }
    fn selectionChanged(_: *gtk.SelectionModel, _: c_uint, _: c_uint, self: *Tab) callconv(.c) void {
        if (self.alive and self.ready) self.owner.queueUpdate();
    }
    fn itemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Tab) callconv(.c) void {
        if (self.alive and self.ready) self.owner.queueUpdate();
    }
    fn pressed(_: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *Tab) callconv(.c) void {
        self.owner.activatePane(self.pane);
    }
    fn refreshClicked(_: *gtk.Button, self: *Tab) callconv(.c) void {
        self.refresh();
    }
    fn activated(_: *gtk.GridView, position: c_uint, self: *Tab) callconv(.c) void {
        self.open(position);
    }
    fn activatedList(_: *gtk.ColumnView, position: c_uint, self: *Tab) callconv(.c) void {
        self.open(position);
    }
    fn open(self: *Tab, position: c_uint) void {
        const info: *gio.FileInfo = @ptrCast(self.selection.as(gio.ListModel).getItem(position) orelse return);
        defer info.unref();
        const f = u.file(info);
        if (info.getFileType() == .directory) self.navigate(f, true) else self.owner.openFile(f, info);
    }
};

const Column = enum(usize) { grid, name, size, modified };
fn factory(kind: Column) *gtk.SignalListItemFactory {
    const f = gtk.SignalListItemFactory.new();
    _ = gtk.SignalListItemFactory.signals.setup.connect(f, ?*anyopaque, setup, @ptrFromInt(@intFromEnum(kind)), .{});
    _ = gtk.SignalListItemFactory.signals.bind.connect(f, ?*anyopaque, bind, @ptrFromInt(@intFromEnum(kind)), .{});
    return f;
}
fn setup(_: *gtk.SignalListItemFactory, item_object: *object.Object, data: ?*anyopaque) callconv(.c) void {
    const item = object.ext.cast(gtk.ListItem, item_object).?;
    const kind: Column = @enumFromInt(@intFromPtr(data));
    if (kind == .grid or kind == .name) {
        const row = u.box(if (kind == .grid) .vertical else .horizontal, if (kind == .grid) 10 else 12, if (kind == .grid) "file-card" else "file-name");
        const image = u.image("folder-symbolic", if (kind == .grid) 48 else 20);
        row.append(image.as(gtk.Widget));
        const text = u.label("", null);
        text.setEllipsize(.end);
        text.setMaxWidthChars(if (kind == .grid) 16 else 48);
        text.setWidthChars(if (kind == .grid) 12 else 10);
        text.as(gtk.Widget).setHexpand(1);
        if (kind == .grid) {
            text.setWrap(1);
            text.setWrapMode(.word_char);
            text.setLines(2);
            text.setXalign(0.5);
            text.setJustify(.center);
        }
        row.append(text.as(gtk.Widget));
        item.setChild(row.as(gtk.Widget));
    } else item.setChild(u.label("", "secondary").as(gtk.Widget));
}
fn bind(_: *gtk.SignalListItemFactory, item_object: *object.Object, data: ?*anyopaque) callconv(.c) void {
    const item = object.ext.cast(gtk.ListItem, item_object).?;
    const info = object.ext.cast(gio.FileInfo, item.getItem().?).?;
    const kind: Column = @enumFromInt(@intFromPtr(data));
    item.setAccessibleLabel(info.getDisplayName());
    if (kind == .grid or kind == .name) {
        const row = item.getChild().?;
        const image = object.ext.cast(gtk.Image, row.getFirstChild().?).?;
        u.infoIcon(info, image);
        object.ext.cast(gtk.Label, row.getLastChild().?).?.setText(info.getDisplayName());
        row.setTooltipText(info.getDisplayName());
    } else {
        const value = if (kind == .size) u.sizeText(info) else u.dateText(info);
        defer glib.free(value);
        object.ext.cast(gtk.Label, item.getChild().?).?.setText(value);
    }
}
