const std = @import("std");
const u = @import("ui.zig");
const gio = u.gio;
const a = u.a;
pub const Kind = @import("core/context.zig").Kind;
pub const Item = struct { file: *gio.File, info: ?*gio.FileInfo = null };
pub const Context = struct {
    kind: Kind,
    directory: *gio.File,
    directory_info: ?*gio.FileInfo = null,
    items: std.ArrayList(Item) = .empty,
    tab_id: u64,
    generation: u64,
    pane: usize,
    mount: ?*gio.Mount = null,
    volume: ?*gio.Volume = null,
    pub fn init(tab: *@import("tab.zig").Tab, kind: Kind) Context {
        return .{ .kind = kind, .directory = gio.File.newForUri(tab.uri), .tab_id = tab.id, .generation = tab.generation, .pane = tab.pane };
    }
    pub fn add(self: *Context, file: *gio.File, info: ?*gio.FileInfo) void {
        file.ref();
        if (info) |i| i.ref();
        self.items.append(a, .{ .file = file, .info = info }) catch unreachable;
    }
    pub fn capture(tab: *@import("tab.zig").Tab) Context {
        var c = init(tab, .selection);
        const model = tab.selection.as(gio.ListModel);
        const selected = tab.selection.as(u.gtk.SelectionModel).getSelection();
        defer selected.unref();
        var i: c_uint = 0;
        while (i < selected.getSize()) : (i += 1) {
            const info: *gio.FileInfo = @ptrCast(model.getItem(selected.getNth(i)) orelse continue);
            defer info.unref();
            c.add(u.file(info), info);
        }
        if (c.items.items.len == 0) c.kind = .background;
        if (tab.directory_info) |info| {
            info.ref();
            c.directory_info = info;
        }
        return c;
    }
    pub fn clone(self: *const Context) Context {
        self.directory.ref();
        var c: Context = .{ .kind = self.kind, .directory = self.directory, .tab_id = self.tab_id, .generation = self.generation, .pane = self.pane };
        for (self.items.items) |i| c.add(i.file, i.info);
        if (self.directory_info) |i| {
            i.ref();
            c.directory_info = i;
        }
        if (self.mount) |m| {
            m.ref();
            c.mount = m;
        }
        if (self.volume) |v| {
            v.ref();
            c.volume = v;
        }
        return c;
    }
    pub fn deinit(self: *Context) void {
        self.directory.unref();
        if (self.directory_info) |i| i.unref();
        for (self.items.items) |i| {
            i.file.unref();
            if (i.info) |info| info.unref();
        }
        self.items.deinit(a);
        if (self.mount) |m| m.unref();
        if (self.volume) |v| v.unref();
    }
    pub fn target(self: *const Context) *gio.File {
        return if (self.items.items.len == 1) self.items.items[0].file else self.directory;
    }
    pub fn isTrash(self: *const Context) bool {
        const uri = self.directory.getUri();
        defer u.glib.free(uri);
        return std.mem.startsWith(u8, std.mem.span(uri), "trash:");
    }
    pub fn facts(self: *const Context, clipboard: bool, busy: bool) @import("core/context.zig").Facts {
        var f: @import("core/context.zig").Facts = .{ .kind = self.kind, .count = self.items.items.len, .all_directories = self.items.items.len > 0, .clipboard = clipboard, .trash = self.isTrash(), .busy = busy, .can_rename = true, .can_delete = true, .can_trash = true };
        for (self.items.items) |item| {
            const info = item.info orelse {
                f.all_directories = false;
                f.can_rename = false;
                f.can_delete = false;
                f.can_trash = false;
                continue;
            };
            f.all_directories = f.all_directories and info.getFileType() == .directory;
            f.can_rename = f.can_rename and info.getAttributeBoolean("access::can-rename") != 0;
            f.can_delete = f.can_delete and info.getAttributeBoolean("access::can-delete") != 0;
            f.can_trash = f.can_trash and info.getAttributeBoolean("access::can-trash") != 0;
        }
        const dest_info = if (self.items.items.len == 1 and f.all_directories) self.items.items[0].info else self.directory_info;
        if (dest_info) |info| f.can_write = info.getAttributeBoolean("access::can-write") != 0;
        const path = self.target().getPath();
        if (path) |p| u.glib.free(p);
        f.local = path != null;
        return f;
    }
};
