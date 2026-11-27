//! Default applications page. Choices are written straight to the XDG
//! defaults (mimeapps.list through GIO, xdg-terminals.list for terminals), so
//! they apply immediately and are honored outside Pearl as well.
//! Each row is a button opening the same chooser-dialog pattern the Startup
//! applications page uses; dropdown popups proved unreliable for dynamic
//! candidate lists in this GTK build.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const unix = @import("giounix2");
const w = @import("../ui/components/widgets.zig");
const builder = @import("rule_builder.zig");
const policy = @import("../services/default_apps.zig");
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
const Connection = struct { obj: *object.Object, id: c_ulong };

pub const View = struct {
    root: *gtk.Box,
    status: *gtk.Label,
    rows: []Row,
    picker: ?Picker = null,

    const Row = struct {
        view: *View,
        spec: *const policy.Spec,
        title: [:0]const u8,
        line: *gtk.FlowBox,
        button: *gtk.Button,
        signal: c_ulong = 0,
    };

    const Picker = struct {
        view: *View,
        row: *Row,
        shell: builder.Shell,
        list: *gtk.ListBox,
        ids: std.ArrayList([:0]const u8) = .empty,
        connections: std.ArrayList(Connection) = .empty,
    };

    pub fn create(host: *gtk.Box) !*View {
        const self = try a.create(View);
        errdefer a.destroy(self);
        self.* = .{ .root = w.column(16), .status = undefined, .rows = try a.alloc(Row, policy.specs.len) };
        errdefer a.free(self.rows);
        host.append(self.root.as(gtk.Widget));
        // Form rows carry their own padding and flush separators, so the card
        // itself must stay spacing-free like the other preference pages.
        const card = w.column(0);
        card.as(gtk.Widget).addCssClass("settings-card");
        self.root.append(card.as(gtk.Widget));
        // Immediacy and scope are stated once, in the window footer; the card
        // only surfaces failures, so the rows start at the top.
        self.status = w.label("", "pearl-secondary");
        self.status.setWrap(1);
        self.status.as(gtk.Widget).setVisible(0);
        card.append(self.status.as(gtk.Widget));
        for (&policy.specs, self.rows) |*spec, *row| {
            const line = w.flow(2);
            line.setHomogeneous(0);
            line.as(gtk.Widget).addCssClass("settings-form-row");
            const titles = w.column(4);
            const title = w.label(@import("i18n").dtr("pearl", spec.label), "settings-row-title");
            titles.append(title.as(gtk.Widget));
            const detail = w.label(@import("i18n").dtr("pearl", spec.description), "pearl-secondary");
            detail.as(gtk.Widget).setHalign(.start);
            titles.append(detail.as(gtk.Widget));
            line.insert(titles.as(gtk.Widget), -1);
            const button = gtk.Button.newWithLabel(@import("i18n").dtr("pearl", "Not set"));
            // The card surface is $high$ too; without the value-control tint the
            // button chrome would be invisible against it.
            button.as(gtk.Widget).addCssClass("settings-value");
            button.as(gtk.Widget).setHalign(.end);
            button.as(gtk.Widget).setValign(.center);
            w.name(button.as(gtk.Widget), title.getText());
            line.insert(button.as(gtk.Widget), -1);
            card.append(line.as(gtk.Widget));
            row.* = .{ .view = self, .spec = spec, .title = std.mem.span(title.getText()), .line = line, .button = button };
            row.signal = gtk.Button.signals.clicked.connect(button, *Row, buttonClicked, row, .{});
        }
        self.update();
        return self;
    }

    pub fn destroy(self: *View) void {
        self.closePicker();
        for (self.rows) |*row| {
            if (row.signal != 0) object.signalHandlerDisconnect(row.button.as(object.Object), row.signal);
        }
        a.free(self.rows);
        a.destroy(self);
    }

    /// Re-read the current defaults; called when the page is shown so choices
    /// made elsewhere stay visible.
    pub fn update(self: *View) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        for (self.rows) |*row| {
            const current = self.currentDefault(alloc, row.spec) catch null;
            const label: [:0]const u8 = if (current) |id| named: {
                const idz = alloc.dupeSentinel(u8, id, 0) catch break :named @import("i18n").dtr("pearl", "Not set");
                const desktop = unix.DesktopAppInfo.new(idz) orelse break :named idz;
                defer desktop.as(object.Object).unref();
                break :named alloc.dupeSentinel(u8, std.mem.span(desktop.as(gio.AppInfo).getDisplayName()), 0) catch idz;
            } else @import("i18n").dtr("pearl", "Not set");
            row.button.setLabel(label);
        }
    }

    fn currentDefault(_: *View, alloc: std.mem.Allocator, spec: *const policy.Spec) !?[]const u8 {
        return @import("launch.zig").defaultDesktopId(alloc, spec.category);
    }

    fn buttonClicked(_: *gtk.Button, row: *Row) callconv(.c) void {
        row.view.openPicker(row) catch |err| {
            log.warn("event=default-apps-apply-failed category={s} app={s} error={s}", .{ @tagName(row.spec.category), "", @errorName(err) });
        };
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

    fn openPicker(self: *View, row: *Row) !void {
        if (self.picker != null) return;
        const parent = self.parentWindow() orelse return error.NoWindow;
        const shell = builder.open(parent, row.title);
        self.picker = .{ .view = self, .row = row, .shell = shell, .list = undefined };
        errdefer self.closePicker();
        const picker = &self.picker.?;
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.never, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        const list = gtk.ListBox.new();
        list.setSelectionMode(.none);
        scroll.setChild(list.as(gtk.Widget));
        shell.body.append(scroll.as(gtk.Widget));
        picker.list = list;
        var connections = picker.connections;
        const activate_connection = try connections.addOne(a);
        activate_connection.* = .{ .obj = list.as(gtk.Widget).as(object.Object), .id = gtk.ListBox.signals.row_activated.connect(list, *Picker, rowActivated, picker, .{}) };
        const response_connection = try connections.addOne(a);
        response_connection.* = .{ .obj = shell.dialog.as(gtk.Widget).as(object.Object), .id = gtk.Dialog.signals.response.connect(shell.dialog, *View, pickerResponse, self, .{}) };
        self.populate(picker);
        shell.dialog.as(gtk.Window).setDefaultSize(480, 520);
        shell.dialog.as(gtk.Window).present();
    }

    fn pickerResponse(_: *gtk.Dialog, _: c_int, self: *View) callconv(.c) void {
        self.closePicker();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, picker: *Picker) callconv(.c) void {
        const self = picker.view;
        const index = row.getIndex();
        if (index < 0 or @as(usize, @intCast(index)) >= picker.ids.items.len) return;
        const id = picker.ids.items[@intCast(index)];
        self.apply(picker.row.spec, id) catch |err| {
            log.warn("event=default-apps-apply-failed category={s} app={s} error={s}", .{ @tagName(picker.row.spec.category), id, @errorName(err) });
            self.status.setText(@import("i18n").dtr("pearl", "The default application could not be changed."));
            self.status.as(gtk.Widget).setVisible(1);
            self.closePicker();
            self.update();
            return;
        };
        self.status.as(gtk.Widget).setVisible(0);
        self.closePicker();
        self.update();
    }

    /// Installed applications able to handle the row's category.
    fn populate(_: *View, picker: *Picker) void {
        const spec = picker.row.spec;
        const get: *const fn ([*:0]const u8) callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAllForType);
        const get_all: *const fn () callconv(.c) ?*glib.List = @ptrCast(&gio.AppInfo.getAll);
        const list = if (spec.category == .terminal) get_all() else get(spec.mimes[0]);
        defer if (list) |head| {
            var it: ?*glib.List = head;
            while (it) |node| : (it = node.f_next) {
                const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
                info.as(object.Object).unref();
            }
            head.free();
        };
        var it = list;
        while (it) |node| : (it = node.f_next) {
            if (picker.ids.items.len >= 256) break;
            const info: *gio.AppInfo = @ptrCast(@alignCast(node.f_data.?));
            if (spec.category == .terminal) {
                const desktop = object.ext.cast(unix.DesktopAppInfo, info) orelse continue;
                const raw = desktop.getCategories() orelse continue;
                // Menu visibility does not remove terminal capability.
                if (!policy.hasCategory(std.mem.span(raw), "TerminalEmulator")) continue;
            } else if (info.shouldShow() == 0) continue;
            const raw_id = info.getId() orelse continue;
            const id = std.mem.span(raw_id);
            var seen = false;
            for (picker.ids.items) |existing| if (std.mem.eql(u8, existing, id)) {
                seen = true;
            };
            if (seen) continue;
            const owned = a.dupeSentinel(u8, id, 0) catch continue;
            picker.ids.append(a, owned) catch {
                a.free(owned);
                continue;
            };
            const name = std.mem.span(info.getDisplayName());
            const list_row = gtk.ListBoxRow.new();
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
            list_row.setChild(box.as(gtk.Widget));
            picker.list.append(list_row.as(gtk.Widget));
        }
        if (picker.ids.items.len == 0) {
            const empty = w.label(@import("i18n").dtr("pearl", "No matching applications."), "pearl-secondary");
            picker.shell.body.append(empty.as(gtk.Widget));
        }
    }

    fn apply(_: *View, spec: *const policy.Spec, id: [:0]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        if (spec.category == .terminal) {
            const dir = try @import("launch.zig").configHome(alloc);
            return policy.setTerminalDefault(alloc, dir, id);
        }
        const desktop = unix.DesktopAppInfo.new(id) orelse return error.ApplicationNotFound;
        defer desktop.as(object.Object).unref();
        for (spec.mimes) |mime| {
            var err: ?*glib.Error = null;
            if (gio.AppInfo.setAsDefaultForType(desktop.as(gio.AppInfo), mime, &err) == 0) {
                if (err) |e| {
                    log.warn("event=default-apps-set-failed mime={s} detail={s}", .{ mime, if (e.f_message) |m| std.mem.span(m) else "" });
                    e.free();
                }
                return error.SetDefaultFailed;
            }
        }
    }
};
