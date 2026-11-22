//! Startup applications on the System page. Entries live in the standard XDG
//! autostart directories, so other sessions honor them too; Pearl adds its
//! managed entries to the user directory and disables entries with Hidden.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const unix = @import("giounix2");
const w = @import("../ui/components/widgets.zig");
const builder = @import("rule_builder.zig");
const policy = @import("../services/autostart_policy.zig");
const Service = @import("../services/autostart.zig").Service;
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };

pub const View = struct {
    service: *Service,
    root: *gtk.Box,
    status: *gtk.Label,
    entries_host: *gtk.Box,
    add_button: *gtk.Button,
    /// Owns everything built from the current entry list.
    arena: std.heap.ArenaAllocator = .init(a),
    connections: std.ArrayList(Connection) = .empty,
    signature: u64 = 0,
    built: bool = false,
    updating: bool = false,
    picker: ?Picker = null,

    const Binding = struct { view: *View, file: [:0]const u8 };
    const Picker = struct {
        shell: builder.Shell,
        search: *gtk.Entry,
        list: *gtk.ListBox,
        empty: *gtk.Label,
        /// Desktop IDs matching the current row order.
        ids: std.ArrayList([:0]const u8) = .empty,
        connections: std.ArrayList(Connection) = .empty,
        view: *View,
    };

    pub fn create(host: *gtk.Box, service: *Service) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .service = service, .root = w.column(16), .status = undefined, .entries_host = undefined, .add_button = undefined };
        errdefer self.arena.deinit();
        host.append(self.root.as(gtk.Widget));
        const card = w.card();
        self.root.append(card.as(gtk.Widget));
        const header = w.row(8);
        const title = w.label(@import("i18n").dtr("pearl", "Startup applications"), "pearl-section-title");
        title.as(gtk.Widget).setHexpand(1);
        header.append(title.as(gtk.Widget));
        self.add_button = w.wrappingButton(@import("i18n").dtr("pearl", "Add application…"));
        self.add_button.as(gtk.Widget).setValign(.center);
        header.append(self.add_button.as(gtk.Widget));
        card.append(header.as(gtk.Widget));
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        card.append(self.status.as(gtk.Widget));
        self.entries_host = w.column(8);
        card.append(self.entries_host.as(gtk.Widget));
        _ = gtk.Button.signals.clicked.connect(self.add_button, *View, addClicked, self, .{});
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        self.closePicker();
        self.disconnect();
        self.connections.deinit(a);
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn update(self: *View) void {
        const signature = self.listSignature();
        if (self.built and signature == self.signature) return;
        self.rebuild() catch |err| {
            self.built = false;
            log.warn("event=autostart-view-failed error={s}", .{@errorName(err)});
            return;
        };
        self.signature = signature;
        self.built = true;
    }

    fn listSignature(self: *const View) u64 {
        var hash = std.hash.Wyhash.init(0);
        for (self.service.entries) |entry| {
            hash.update(entry.file);
            hash.update(entry.name);
            hash.update(&[_]u8{ @intFromBool(entry.hidden), @intFromBool(entry.masks_system), @intFromBool(entry.managed), @backingInt(entry.source), @intFromBool(entry.autostart_enabled != null and !entry.autostart_enabled.?) });
        }
        return hash.final();
    }

    fn disconnect(self: *View) void {
        for (self.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
        self.connections.clearRetainingCapacity();
    }

    fn enabled(entry: policy.Entry) bool {
        return !entry.hidden and (entry.autostart_enabled orelse true);
    }

    fn rebuild(self: *View) !void {
        self.disconnect();
        while (self.entries_host.as(gtk.Widget).getFirstChild()) |child| self.entries_host.remove(child);
        _ = self.arena.reset(.retain_capacity);
        const alloc = self.arena.allocator();
        if (self.service.err) |message| {
            self.status.setText(message);
        } else self.status.setText(@import("i18n").dtr("pearl", "These applications start when you log in. Changes apply at the next login."));
        if (self.service.entries.len == 0) {
            self.entries_host.append(w.label(@import("i18n").dtr("pearl", "No startup applications."), "pearl-secondary").as(gtk.Widget));
            return;
        }
        for (self.service.entries) |entry| {
            const row = w.row(10);
            row.as(gtk.Widget).addCssClass("pearl-row-card");
            const image = appImage(entry);
            image.as(gtk.Widget).setValign(.center);
            row.append(image.as(gtk.Widget));
            const labels = w.column(2);
            labels.as(gtk.Widget).setHexpand(1);
            const name = w.label(try alloc.dupeSentinel(u8, entry.name, 0), null);
            name.setEllipsize(.end);
            labels.append(name.as(gtk.Widget));
            const detail = w.label(try detailText(alloc, entry), "pearl-secondary");
            detail.setEllipsize(.end);
            labels.append(detail.as(gtk.Widget));
            row.append(labels.as(gtk.Widget));
            const binding = try alloc.create(Binding);
            binding.* = .{ .view = self, .file = try alloc.dupeSentinel(u8, entry.file, 0) };
            const toggle = gtk.Switch.new();
            toggle.setActive(@intFromBool(enabled(entry)));
            toggle.as(gtk.Widget).setValign(.center);
            w.name(toggle.as(gtk.Widget), try alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "Start {s} at login", .{entry.name}), 0));
            const connection = try self.connections.addOne(a);
            connection.* = .{ .obj = toggle.as(gtk.Widget).as(object.Object), .id = object.Object.signals.notify.connect(toggle.as(gtk.Widget).as(object.Object), *Binding, toggled, binding, .{ .detail = "active" }) };
            row.append(toggle.as(gtk.Widget));
            const remove = w.wrappingButton(@import("i18n").dtr("pearl", "Remove"));
            remove.as(gtk.Widget).setValign(.center);
            w.name(remove.as(gtk.Widget), try alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "Remove {s} from startup applications", .{entry.name}), 0));
            const remove_connection = try self.connections.addOne(a);
            remove_connection.* = .{ .obj = remove.as(gtk.Widget).as(object.Object), .id = gtk.Button.signals.clicked.connect(remove, *Binding, removeClicked, binding, .{}) };
            row.append(remove.as(gtk.Widget));
            self.entries_host.append(row.as(gtk.Widget));
        }
    }

    fn detailText(alloc: std.mem.Allocator, entry: policy.Entry) ![:0]const u8 {
        const origin: []const u8 = if (entry.source == .system)
            @import("i18n").dtr("pearl", "System entry")
        else if (entry.masks_system)
            @import("i18n").dtr("pearl", "Overrides a system entry")
        else if (entry.managed)
            @import("i18n").dtr("pearl", "Added through Pearl")
        else
            @import("i18n").dtr("pearl", "User entry");
        if (entry.exec.len == 0) return alloc.dupeSentinel(u8, origin, 0);
        return alloc.dupeSentinel(u8, try std.fmt.allocPrint(alloc, "{s} · {s}", .{ origin, entry.exec }), 0);
    }

    fn appImage(entry: policy.Entry) *gtk.Image {
        if (entry.app_id) |id| {
            const sentinel = a.dupeSentinel(u8, id, 0) catch null;
            defer if (sentinel) |value| a.free(value);
            if (sentinel) |value| if (unix.DesktopAppInfo.new(value)) |desktop| {
                defer desktop.unref();
                if (desktop.as(gio.AppInfo).getIcon()) |icon| {
                    // Borrowed reference; the image takes its own ref.
                    const image = gtk.Image.new();
                    image.setFromGicon(icon);
                    image.setPixelSize(32);
                    return image;
                }
            };
        }
        if (entry.icon.len > 0) {
            const sentinel = a.dupeSentinel(u8, entry.icon, 0) catch null;
            defer if (sentinel) |value| a.free(value);
            if (sentinel) |value| {
                const image = gtk.Image.newFromIconName(value);
                image.setPixelSize(32);
                return image;
            }
        }
        const image = gtk.Image.newFromIconName("application-x-executable");
        image.setPixelSize(32);
        return image;
    }

    fn toggled(source: *object.Object, _: *object.ParamSpec, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        if (self.updating) return;
        const toggle = object.ext.cast(gtk.Switch, source).?;
        self.service.setEnabled(binding.file, toggle.getActive() != 0) catch |err| {
            log.warn("event=autostart-toggle-failed file={s} error={s}", .{ binding.file, @errorName(err) });
            self.showError(@import("i18n").dtr("pearl", "The entry could not be changed."));
        };
        self.update();
    }

    fn removeClicked(_: *gtk.Button, binding: *Binding) callconv(.c) void {
        const self = binding.view;
        self.service.remove(binding.file) catch |err| {
            log.warn("event=autostart-remove-failed file={s} error={s}", .{ binding.file, @errorName(err) });
            self.showError(@import("i18n").dtr("pearl", "The entry could not be removed."));
        };
        self.update();
    }

    fn showError(self: *View, text: [:0]const u8) void {
        self.status.setText(text);
    }

    fn addClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.openPicker() catch |err| log.warn("event=autostart-picker-failed error={s}", .{@errorName(err)});
    }

    fn parentWindow(self: *View) ?*gtk.Window {
        const root = self.root.as(gtk.Widget).getRoot() orelse return null;
        return object.ext.cast(gtk.Window, root);
    }

    fn closePicker(self: *View) void {
        if (self.picker) |*picker| {
            for (picker.connections.items) |c| object.signalHandlerDisconnect(c.obj, c.id);
            picker.connections.deinit(a);
            for (picker.ids.items) |id| a.free(id);
            picker.ids.deinit(a);
            picker.shell.dialog.as(gtk.Window).destroy();
            picker.shell.dialog.unref();
        }
        self.picker = null;
    }

    fn openPicker(self: *View) !void {
        if (self.picker != null) return;
        const parent = self.parentWindow() orelse return error.NoWindow;
        const shell = builder.open(parent, @import("i18n").dtr("pearl", "Add a startup application"));
        self.picker = .{ .shell = shell, .search = undefined, .list = undefined, .empty = undefined, .view = self };
        errdefer self.closePicker();
        const picker = &self.picker.?;
        const search = gtk.Entry.new();
        search.setPlaceholderText(@import("i18n").dtr("pearl", "Search applications"));
        search.setMaxLength(256);
        search.as(gtk.Widget).addCssClass("search");
        shell.body.append(search.as(gtk.Widget));
        picker.search = search;
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const list = gtk.ListBox.new();
        list.setSelectionMode(.none);
        scroll.setChild(list.as(gtk.Widget));
        shell.body.append(scroll.as(gtk.Widget));
        picker.list = list;
        picker.empty = w.label(@import("i18n").dtr("pearl", "No matching applications."), "pearl-secondary");
        picker.empty.as(gtk.Widget).setVisible(0);
        shell.body.append(picker.empty.as(gtk.Widget));
        _ = shell.dialog.addButton(@import("i18n").dtr("pearl", "Cancel"), @backingInt(gtk.ResponseType.cancel));
        var connections = picker.connections;
        const search_connection = try connections.addOne(a);
        search_connection.* = .{ .obj = search.as(gtk.Widget).as(object.Object), .id = gtk.Editable.signals.changed.connect(search.as(gtk.Editable), *Picker, searchChanged, picker, .{}) };
        const activate_connection = try connections.addOne(a);
        activate_connection.* = .{ .obj = list.as(gtk.Widget).as(object.Object), .id = gtk.ListBox.signals.row_activated.connect(list, *Picker, rowActivated, picker, .{}) };
        const response_connection = try connections.addOne(a);
        response_connection.* = .{ .obj = shell.dialog.as(gtk.Widget).as(object.Object), .id = gtk.Dialog.signals.response.connect(shell.dialog, *View, pickerResponse, self, .{}) };
        populate(picker);
        shell.dialog.as(gtk.Window).setDefaultSize(480, 520);
        shell.dialog.as(gtk.Window).present();
    }

    fn pickerResponse(_: *gtk.Dialog, _: c_int, self: *View) callconv(.c) void {
        self.closePicker();
    }

    fn searchChanged(_: *gtk.Editable, picker: *Picker) callconv(.c) void {
        populate(picker);
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, picker: *Picker) callconv(.c) void {
        const self = picker.view;
        const index = row.getIndex();
        if (index < 0 or @as(usize, @intCast(index)) >= picker.ids.items.len) return;
        const id = picker.ids.items[@intCast(index)];
        self.service.add(id) catch |err| {
            log.warn("event=autostart-add-failed app={s} error={s}", .{ id, @errorName(err) });
            self.showError(switch (err) {
                error.StaleApplication => @import("i18n").dtr("pearl", "That application could not be resolved. It may have been uninstalled."),
                else => @import("i18n").dtr("pearl", "The application could not be added."),
            });
            self.closePicker();
            self.update();
            return;
        };
        self.closePicker();
        self.update();
    }

    /// Fills the picker list with installed, launchable applications that are
    /// not startup entries yet, filtered by the search text.
    fn populate(picker: *Picker) void {
        const self = picker.view;
        for (picker.ids.items) |id| a.free(id);
        picker.ids.clearRetainingCapacity();
        while (picker.list.getRowAtIndex(0)) |row| picker.list.remove(row.as(gtk.Widget));
        const needle = glib.utf8Casefold(picker.search.as(gtk.Editable).getText(), -1);
        defer glib.free(needle);
        const needle_slice: []const u8 = std.mem.span(needle);
        // GIR marks this list non-null, but the C API returns NULL for no apps.
        const get: *const fn () callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAll);
        const all = get();
        defer if (all) |head| {
            var it: ?*glib.List = head;
            while (it) |node| : (it = node.f_next) {
                const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
                info.as(object.Object).unref();
            }
            head.free();
        };
        var it = all;
        while (it) |node| : (it = node.f_next) {
            if (picker.ids.items.len >= 256) break;
            const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
            if (info.shouldShow() == 0) continue;
            if (object.ext.cast(unix.DesktopAppInfo, info) == null) continue;
            const raw_id = info.getId() orelse continue;
            const id = std.mem.span(raw_id);
            if (!policy.desktopId(id)) continue;
            if (self.service.find(id) != null) continue;
            const name = std.mem.span(info.getDisplayName());
            if (needle_slice.len > 0) {
                const folded = glib.utf8Casefold(name.ptr, @intCast(name.len));
                defer glib.free(folded);
                if (std.mem.indexOf(u8, std.mem.span(folded), needle_slice) == null) continue;
            }
            const row = gtk.ListBoxRow.new();
            const box = w.row(10);
            const image = if (info.getIcon()) |icon| blk: {
                // AppInfo.getIcon is borrowed; the image takes its own ref.
                const from_icon = gtk.Image.new();
                from_icon.setFromGicon(icon);
                from_icon.setPixelSize(24);
                break :blk from_icon;
            } else blk: {
                const fallback = gtk.Image.newFromIconName("application-x-executable");
                fallback.setPixelSize(24);
                break :blk fallback;
            };
            box.append(image.as(gtk.Widget));
            const label = w.label(name.ptr, null);
            label.setEllipsize(.end);
            box.append(label.as(gtk.Widget));
            row.setChild(box.as(gtk.Widget));
            picker.list.append(row.as(gtk.Widget));
            picker.ids.append(a, a.dupeSentinel(u8, id, 0) catch continue) catch break;
        }
        picker.empty.as(gtk.Widget).setVisible(@intFromBool(picker.ids.items.len == 0));
    }
};
