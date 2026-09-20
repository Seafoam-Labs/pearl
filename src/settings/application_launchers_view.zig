//! Remove remembered launcher choices through the shared preference draft.
const std = @import("std");
const gtk = @import("gtk4");
const glib = @import("glib2");
const model = @import("../config/preferences.zig");
const identity = @import("../desktop/app_identity.zig");
const widgets = @import("../ui/components/widgets.zig");
const tr = @import("../desktop/text.zig").tr;
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const Callback = struct { view: *View, key: identity.Key };
pub const Control = struct { id: []const u8, widget: *gtk.Widget };
pub const View = struct {
    host: *gtk.Box,
    expander: *gtk.Expander,
    editor: *Editor,
    controls: std.ArrayList(Control) = .empty,
    arena: std.heap.ArenaAllocator = .init(a),
    hash: ?u64 = null,
    editing: bool = false,
    idle: c_uint = 0,
    pub fn create(parent: *gtk.Box, editor: *Editor) !*View {
        const self = try a.create(View);
        const expander = gtk.Expander.new(tr("Application launchers", "Anwendungsstarter"));
        const host = gtk.Box.new(.vertical, 8);
        expander.setChild(host.as(gtk.Widget));
        parent.append(expander.as(gtk.Widget));
        self.* = .{ .host = host, .expander = expander, .editor = editor };
        self.update();
        return self;
    }
    pub fn destroy(self: *View) void {
        if (self.idle != 0) _ = glib.Source.remove(self.idle);
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn update(self: *View) void {
        if (self.editing) return;
        var temp = std.heap.ArenaAllocator.init(a);
        defer temp.deinit();
        const prefs = model.parse(temp.allocator(), self.editor.text()) catch {
            self.host.as(gtk.Widget).setSensitive(0);
            return;
        };
        self.host.as(gtk.Widget).setSensitive(@intFromBool(self.editor.editable()));
        const hash = identity.digest(prefs.application_launchers);
        if (self.hash != null and self.hash.? == hash) return;
        self.render(prefs.application_launchers) catch {
            self.hash = null;
            return;
        };
        self.hash = hash;
    }
    fn render(self: *View, choices: []const identity.Association) !void {
        while (self.host.as(gtk.Widget).getFirstChild()) |child| self.host.remove(child);
        _ = self.arena.reset(.retain_capacity);
        self.controls = .empty;
        const alloc = self.arena.allocator();
        const help = widgets.label(tr("Choose a launcher from a running application's dock menu. Removing a choice restores automatic matching; pins stay saved.", "Starter im Dock-Menü einer laufenden Anwendung auswählen. Entfernen stellt die automatische Zuordnung wieder her; angeheftete Einträge bleiben erhalten."), "pearl-secondary");
        help.setWrap(1);
        self.host.append(help.as(gtk.Widget));
        if (choices.len == 0) self.host.append(widgets.label(tr("No launcher choices saved.", "Keine Starter-Zuordnungen gespeichert."), "pearl-secondary").as(gtk.Widget));
        for (choices) |choice| {
            const row = gtk.Box.new(.horizontal, 8);
            const label = widgets.label(try std.fmt.allocPrintSentinel(alloc, "{s} ({s})\n{s}", .{ choice.identity, @tagName(choice.backend), choice.desktop_id }, 0), null);
            label.setEllipsize(.end);
            label.setMaxWidthChars(48);
            label.as(gtk.Widget).setHexpand(1);
            row.append(label.as(gtk.Widget));
            const remove_button = gtk.Button.newWithLabel(tr("Remove choice", "Zuordnung entfernen"));
            try self.controls.append(alloc, .{ .id = try std.fmt.allocPrint(alloc, "launchers.remove.{s}.{s}", .{ @tagName(choice.backend), choice.identity }), .widget = remove_button.as(gtk.Widget) });
            widgets.name(remove_button.as(gtk.Widget), try std.fmt.allocPrintSentinel(alloc, "Remove launcher choice for {s}", .{choice.identity}, 0));
            const cb = try alloc.create(Callback);
            cb.* = .{ .view = self, .key = .{ .backend = choice.backend, .identity = try alloc.dupe(u8, choice.identity) } };
            _ = gtk.Button.signals.clicked.connect(remove_button, *Callback, clicked, cb, .{});
            row.append(remove_button.as(gtk.Widget));
            self.host.append(row.as(gtk.Widget));
        }
    }
    fn clicked(_: *gtk.Button, cb: *Callback) callconv(.c) void {
        const self = cb.view;
        self.remove(cb.key) catch |err| self.editor.error_code.set(@errorName(err));
        if (self.idle == 0) self.idle = glib.idleAdd(refresh, self);
    }
    fn refresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *View = @ptrCast(@alignCast(data.?));
        self.idle = 0;
        self.update();
        return 0;
    }
    fn remove(self: *View, key: identity.Key) !void {
        if (!self.editor.editable()) return error.Unavailable;
        self.editing = true;
        defer self.editing = false;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var prefs = try model.parse(arena.allocator(), self.editor.text());
        if (identity.lookup(prefs.application_launchers, key) == null) return error.Stale;
        prefs.application_launchers = try identity.change(arena.allocator(), prefs.application_launchers, key, null);
        try self.editor.edit(try std.json.Stringify.valueAlloc(arena.allocator(), prefs, .{ .whitespace = .indent_2 }));
    }
};
