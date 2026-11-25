//! Opt-in local assistant permissions section of the Assistant page. Folder
//! grants and the app-opening toggle are draft settings: they follow the shared
//! editor and only reach the shell through Apply & save, exactly like the
//! semantic search section. Path and right validation lives in the assistant
//! config; this view only collects the user's intent.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const object = @import("gobject2");
const w = @import("../ui/components/widgets.zig");
const layout = @import("assistant_layout.zig");
const prefs = @import("../config/preferences.zig");
const cfg = @import("../agent/config.zig");
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Right = enum { read, create, delete };
/// One heap record per displayed grant. The three right switches share it; the
/// emitting switch identifies which right changed, so a single allocation keeps
/// the remove button and the switches aligned by grant index.
const GrantRow = struct { view: *View, index: usize, rights: [3]*gtk.Switch };
pub const View = struct {
    editor: *Editor,
    expander: *gtk.Expander,
    summary: *gtk.Label,
    host: *gtk.Box,
    enabled: *gtk.Switch,
    open_apps: *gtk.Switch,
    grants_box: *gtk.Box,
    warning: *gtk.Label,
    status: *gtk.Label,
    picker: ?*gtk.FileChooserNative = null,
    dead: bool = false,
    filling: bool = false,
    editing: bool = false,
    rows: std.ArrayList(*GrantRow) = .empty,
    shown_paths: std.ArrayList([]const u8) = .empty,

    pub fn create(host: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        const section = layout.Section.create(host, "Local files & apps", "Grant the assistant access to specific folders and allow it to open apps");
        const body = section.body;
        const enabled = gtk.Switch.new();
        enabled.as(gtk.Widget).setHalign(.start);
        layout.row(body, @import("i18n").dtr("pearl", "Enable local file tools"), enabled.as(gtk.Widget));
        _ = label(body, @import("i18n").dtr("pearl", "When enabled and saved, the assistant can read and, with permission, create or delete files only inside the folders you grant below. It can never run shell commands or programs."));
        const open_apps = gtk.Switch.new();
        open_apps.as(gtk.Widget).setHalign(.start);
        layout.row(body, @import("i18n").dtr("pearl", "Open apps"), open_apps.as(gtk.Widget));
        _ = label(body, @import("i18n").dtr("pearl", "Allow the assistant to open applications you ask for. Opening apps is separate from file access."));
        const grants_card = layout.card(body, @import("i18n").dtr("pearl", "Folder grants"));
        _ = label(grants_card, @import("i18n").dtr("pearl", "Grants take effect only after Apply & save. Symbolic links and hidden files are skipped, and existing files are never overwritten."));
        _ = label(grants_card, @import("i18n").dtr("pearl", "Creating or deleting a file always shows a native confirmation with the exact change first. Deletes go to the Trash when available; permanent deletion happens only when Trash is unsupported and you explicitly confirm it."));
        const grants_box = w.column(6);
        grants_card.append(grants_box.as(gtk.Widget));
        const add_folder = button(grants_card, @import("i18n").dtr("pearl", "Add folder…"));
        const warning = label(grants_card, "");
        warning.as(gtk.Widget).setVisible(0);
        const status = label(body, "");
        self.* = .{
            .editor = editor,
            .expander = section.expander,
            .summary = section.summary,
            .host = body,
            .enabled = enabled,
            .open_apps = open_apps,
            .grants_box = grants_box,
            .warning = warning,
            .status = status,
        };
        _ = object.Object.signals.notify.connect(enabled.as(object.Object), *View, changed, self, .{ .detail = "active" });
        _ = object.Object.signals.notify.connect(open_apps.as(object.Object), *View, changed, self, .{ .detail = "active" });
        _ = gtk.Button.signals.clicked.connect(add_folder, *View, addFolder, self, .{});
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        self.dead = true;
        if (self.picker) |picker| {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
            self.picker = null;
        }
        self.clearRows();
        self.rows.deinit(a);
        for (self.shown_paths.items) |path| a.free(path);
        self.shown_paths.deinit(a);
        a.destroy(self);
    }
    fn clearRows(self: *View) void {
        for (self.rows.items) |row| a.destroy(row);
        self.rows.clearRetainingCapacity();
        while (self.grants_box.as(gtk.Widget).getFirstChild()) |child| self.grants_box.remove(child);
    }
    fn document(self: *View, alloc: std.mem.Allocator) !prefs.Preferences {
        try prefs.boundedJson(self.editor.text(), prefs.max_bytes, 24);
        var value = try std.json.parseFromSliceLeaky(prefs.Preferences, alloc, self.editor.text(), .{});
        // Same migration the sibling views apply so a read-modify-write here
        // never resets the runtime selection of an older draft.
        const raw = try std.json.parseFromSliceLeaky(std.json.Value, alloc, self.editor.text(), .{});
        if (raw == .object) if (raw.object.get("assistant")) |assistant| {
            if (assistant == .object and !assistant.object.contains("runtime")) value.assistant.runtime.source = .packaged;
        };
        return value;
    }
    fn commit(self: *View, value: prefs.Preferences, alloc: std.mem.Allocator) !void {
        const text = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
        try self.editor.edit(text);
    }
    fn save(self: *View) void {
        if (self.filling or self.editing or !self.editor.editable()) return;
        self.editing = true;
        defer {
            self.editing = false;
            self.update();
        }
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        value.assistant.local.enabled = self.enabled.getActive() != 0;
        value.assistant.local.open_apps = self.open_apps.getActive() != 0;
        self.commit(value, alloc) catch |err| self.editor.error_code.set(@errorName(err));
    }
    pub fn update(self: *View) void {
        if (self.dead or self.editing) return;
        self.filling = true;
        defer self.filling = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const value = self.document(alloc) catch return;
        const local = value.assistant.local;
        self.enabled.setActive(@intFromBool(local.enabled));
        self.open_apps.setActive(@intFromBool(local.open_apps));
        var paths_changed = self.shown_paths.items.len != local.roots.len;
        if (!paths_changed) for (local.roots, 0..) |grant, i| {
            if (!std.mem.eql(u8, self.shown_paths.items[i], grant.path)) paths_changed = true;
        };
        if (paths_changed) {
            self.clearRows();
            for (self.shown_paths.items) |path| a.free(path);
            self.shown_paths.clearRetainingCapacity();
            for (local.roots, 0..) |grant, i| {
                self.shown_paths.append(a, a.dupe(u8, grant.path) catch continue) catch continue;
                self.buildRow(alloc, grant, i);
            }
        }
        for (local.roots, 0..) |grant, i| {
            if (i >= self.rows.items.len) break;
            const row = self.rows.items[i];
            row.rights[0].setActive(@intFromBool(grant.read));
            row.rights[1].setActive(@intFromBool(grant.create));
            row.rights[2].setActive(@intFromBool(grant.delete));
        }
        var broad = false;
        for (local.roots) |grant| if (isBroad(grant.path)) {
            broad = true;
            break;
        };
        self.warning.as(gtk.Widget).setVisible(@intFromBool(broad));
        if (broad) self.warning.setText(@import("i18n").dtr("pearl", "A grant covers a very broad location, such as the whole home folder. This is not recommended; grant only the folders you need."));
        self.summary.setText(std.fmt.allocPrintSentinel(alloc, "{s} · {d} folder(s){s}", .{ if (local.enabled) @as([]const u8, "On in draft") else "Off", local.roots.len, if (local.open_apps) @as([]const u8, " · opens apps") else "" }, 0) catch "Local files & apps");
        self.host.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
    }
    fn buildRow(self: *View, alloc: std.mem.Allocator, grant: cfg.FolderGrant, index: usize) void {
        const grant_box = w.column(4);
        const top = w.row(8);
        const path_label = gtk.Label.new(alloc.dupeSentinel(u8, grant.path, 0) catch return);
        path_label.setXalign(0);
        path_label.as(gtk.Widget).setHexpand(1);
        path_label.setEllipsize(.middle);
        top.append(path_label.as(gtk.Widget));
        const remove_button = w.wrappingButton(@import("i18n").dtr("pearl", "Remove"));
        w.name(remove_button.as(gtk.Widget), std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ @import("i18n").dtr("pearl", "Remove"), grant.path }, 0) catch return);
        top.append(remove_button.as(gtk.Widget));
        grant_box.append(top.as(gtk.Widget));
        const rights_row = w.row(16);
        var rights: [3]*gtk.Switch = undefined;
        inline for (.{ Right.read, Right.create, Right.delete }, 0..) |right, k| {
            const title = rightTitle(right);
            const pair = w.row(4);
            const caption = gtk.Label.new(title);
            pair.append(caption.as(gtk.Widget));
            const switch_ = gtk.Switch.new();
            switch_.as(gtk.Widget).setValign(.center);
            w.name(switch_.as(gtk.Widget), std.fmt.allocPrintSentinel(alloc, "{s} · {s}", .{ title, grant.path }, 0) catch title);
            rights[k] = switch_;
            pair.append(switch_.as(gtk.Widget));
            rights_row.append(pair.as(gtk.Widget));
        }
        grant_box.append(rights_row.as(gtk.Widget));
        const row = a.create(GrantRow) catch return;
        row.* = .{ .view = self, .index = index, .rights = rights };
        self.rows.append(a, row) catch {
            a.destroy(row);
            return;
        };
        _ = gtk.Button.signals.clicked.connect(remove_button, *GrantRow, grantRemove, row, .{});
        for (rights) |switch_| {
            _ = object.Object.signals.notify.connect(switch_.as(object.Object), *GrantRow, rightChanged, row, .{ .detail = "active" });
        }
        self.grants_box.append(grant_box.as(gtk.Widget));
    }
    fn grantRemove(_: *gtk.Button, row: *GrantRow) callconv(.c) void {
        const self = row.view;
        if (self.dead or self.editing or !self.editor.editable()) return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.local.roots;
        if (row.index >= old.len) return;
        const list = alloc.alloc(cfg.FolderGrant, old.len - 1) catch return;
        @memcpy(list[0..row.index], old[0..row.index]);
        @memcpy(list[row.index..], old[row.index + 1 ..]);
        value.assistant.local.roots = list;
        self.commit(value, alloc) catch return;
        self.update();
    }
    fn rightChanged(emitter: *object.Object, _: *object.ParamSpec, row: *GrantRow) callconv(.c) void {
        const self = row.view;
        if (self.dead or self.filling or self.editing or !self.editor.editable()) return;
        const switch_ = object.ext.cast(gtk.Switch, emitter) orelse return;
        const k = for (row.rights, 0..) |s, i| {
            if (s == switch_) break i;
        } else return;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const old = value.assistant.local.roots;
        if (row.index >= old.len) return;
        const list = alloc.dupe(cfg.FolderGrant, old) catch return;
        const active = switch_.getActive() != 0;
        switch (@as(Right, @fromBackingInt(@intCast(k)))) {
            .read => list[row.index].read = active,
            .create => list[row.index].create = active,
            .delete => list[row.index].delete = active,
        }
        value.assistant.local.roots = list;
        self.commit(value, alloc) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return;
        };
        self.update();
    }
    fn addFolder(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.picker != null or !self.editor.editable()) return;
        const parent = object.ext.cast(gtk.Window, self.host.as(gtk.Widget).getRoot().?).?;
        const picker = gtk.FileChooserNative.new(@import("i18n").dtr("pearl", "Choose a folder to grant"), parent, .select_folder, @import("i18n").dtr("pearl", "Choose"), @import("i18n").dtr("pearl", "Cancel"));
        self.picker = picker;
        _ = gtk.NativeDialog.signals.response.connect(picker.as(gtk.NativeDialog), *View, picked, self, .{});
        picker.as(gtk.NativeDialog).show();
    }
    fn picked(_: *gtk.NativeDialog, response: c_int, self: *View) callconv(.c) void {
        const picker = self.picker orelse return;
        self.picker = null;
        defer {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
        }
        if (response != @backingInt(gtk.ResponseType.accept) or !self.editor.editable()) return;
        const file = picker.as(gtk.FileChooser).getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var value = self.document(alloc) catch return;
        const folder = std.mem.span(path);
        for (value.assistant.local.roots) |grant| if (std.mem.eql(u8, grant.path, folder)) {
            self.status.setText(@import("i18n").dtr("pearl", "That folder is already granted."));
            return;
        };
        const id = newGrantId(alloc) catch |err| {
            self.status.setText(@errorName(err));
            return;
        };
        const old = value.assistant.local.roots;
        const list = alloc.alloc(cfg.FolderGrant, old.len + 1) catch return;
        @memcpy(list[0..old.len], old);
        list[old.len] = .{ .id = id, .path = alloc.dupe(u8, folder) catch return, .read = true, .create = false, .delete = false };
        value.assistant.local.roots = list;
        self.commit(value, alloc) catch |err| {
            self.editor.error_code.set(@errorName(err));
            return;
        };
        self.status.setText("");
        self.update();
    }
    fn changed(_: *object.Object, _: *object.ParamSpec, self: *View) callconv(.c) void {
        self.save();
    }
};
fn rightTitle(right: Right) [:0]const u8 {
    return switch (right) {
        .read => @import("i18n").dtr("pearl", "Read"),
        .create => @import("i18n").dtr("pearl", "Create"),
        .delete => @import("i18n").dtr("pearl", "Delete"),
    };
}
/// Host-generated opaque grant id: kernel randomness rendered as hex, matching
/// the id style used elsewhere in the agent. The config validates the shape.
fn newGrantId(alloc: std.mem.Allocator) ![]const u8 {
    var rnd: [8]u8 = undefined;
    if (std.os.linux.getrandom(&rnd, rnd.len, 0) != rnd.len) return error.RandomUnavailable;
    return std.fmt.allocPrint(alloc, "grant-{s}", .{std.fmt.bytesToHex(rnd, .lower)});
}
/// A root at "/" , a single top-level directory, or the whole home folder is a
/// broad grant. Advisory only; the config still decides what is permitted.
fn isBroad(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/")) return true;
    if (std.mem.eql(u8, path, std.mem.span(glib.getHomeDir()))) return true;
    if (path.len >= 2 and path[0] == '/' and std.mem.indexOfScalarPos(u8, path, 1, '/') == null) return true;
    return false;
}
fn label(host: *gtk.Box, text: [:0]const u8) *gtk.Label {
    const l = w.label(text, "pearl-secondary");
    l.setWrap(1);
    host.append(l.as(gtk.Widget));
    return l;
}
fn button(host: *gtk.Box, title: [:0]const u8) *gtk.Button {
    const b = w.wrappingButton(title);
    b.as(gtk.Widget).addCssClass("settings-value");
    b.as(gtk.Widget).setHalign(.start);
    host.append(b.as(gtk.Widget));
    return b;
}
