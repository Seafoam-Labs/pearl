//! Native chooser smoke driver; document I/O remains outside the chooser.
const std = @import("std");
const chooser = @import("../chooser.zig");
const u = @import("util.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const cast = u.cast;
var loop: *glib.MainLoop = undefined;
var status: u8 = 0;
var check_choices = false;
fn response(dialog: *gtk.Dialog, code: c_int, _: ?*anyopaque) callconv(.c) void {
    if (code == @intFromEnum(gtk.ResponseType.accept)) {
        if (check_choices) {
            const choices = chooser.getChoices(dialog);
            defer choices.unref();
            const expected = glib.Variant.parse(null, "[('remember', 'true'), ('mode', 'dark')]", null, null, null).?;
            defer expected.unref();
            if (choices.equal(expected) == 0) status = 3;
        }
        if (chooser.getFiles(dialog)) |files| {
            defer u.unref(files);
            for (0..files.getNItems()) |i| {
                const file = u.modelItem(gio.File, files, @intCast(i)).?;
                defer u.unref(file);
                const uri = file.getUri();
                defer glib.free(uri);
                const line = u.fmt("{s}\n", .{uri});
                defer u.a.free(line);
                var written: usize = 0;
                while (written < line.len) {
                    const n = std.c.write(1, line.ptr + written, line.len - written);
                    if (n <= 0) break;
                    written += @intCast(n);
                }
            }
        }
    }
    cast(gtk.Window, dialog).destroy();
    loop.quit();
}
fn findAccept(root: *gtk.Widget) ?*gtk.Widget {
    if (root.hasCssClass("suggested-action") != 0) return root;
    var child = root.getFirstChild();
    while (child) |w| : (child = w.getNextSibling()) {
        if (findAccept(w)) |b| return b;
    }
    return null;
}
fn accept(data: ?*anyopaque) callconv(.c) c_int {
    const b = findAccept(cast(gtk.Widget, data)) orelse return 1;
    if (b.getSensitive() == 0) return 1;
    object.signalEmitByName(cast(object.Object, b), "clicked");
    return 0;
}
fn timeout(_: ?*anyopaque) callconv(.c) c_int {
    status = 2;
    loop.quit();
    return 0;
}
fn cancelled(_: ?*object.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    const files = chooser.openFinish(result, &err);
    defer u.unref(files);
    status = if (files == null and err != null and err.?.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.cancelled)) != 0) 0 else 2;
    loop.quit();
}
fn destroyParent(data: ?*anyopaque) callconv(.c) c_int {
    cast(gtk.Window, data).destroy();
    return 0;
}
pub fn run(args: []const [:0]const u8) u8 {
    gtk.init();
    loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    if (args.len > 1 and std.mem.eql(u8, args[1], "cancel-parent")) {
        const parent = gtk.Window.new();
        parent.present();
        chooser.openAsync(parent, 0, &cancelled, null);
        _ = glib.timeoutAdd(300, &destroyParent, parent);
        _ = glib.timeoutAddSeconds(5, &timeout, null);
        loop.run();
        return status;
    }
    const mode: []const u8 = if (args.len > 1) args[1] else "open";
    const action: gtk.FileChooserAction = if (std.mem.eql(u8, mode, "save") or std.mem.eql(u8, mode, "batch")) .save else if (args.len > 1 and std.mem.eql(u8, args[1], "folder")) .select_folder else .open;
    const dialog = chooser.create("Pearl file chooser", action);
    chooser.setMultiple(dialog, @intFromBool(action == .open));
    if (args.len > 2) {
        const folder = gio.File.newForPath(args[2]);
        defer u.unref(folder);
        chooser.setFolder(dialog, folder);
        if (args.len > 3 and action == .open) {
            const file = folder.getChild(args[3]);
            defer u.unref(file);
            chooser.setFile(dialog, file);
        }
    }
    if (action == .save) chooser.setName(dialog, if (args.len > 3) args[3] else "Untitled.txt");
    if (std.mem.eql(u8, mode, "batch")) {
        const names = glib.Variant.parse(null, "[b'batch one.txt', b'batch two.txt']", null, null, null).?;
        defer names.unref();
        if (chooser.setBatch(dialog, names, null) == 0) return 3;
    }
    if (std.mem.eql(u8, mode, "filtered")) {
        const filter = gtk.FileFilter.new();
        defer u.unref(filter);
        filter.setName("Text files");
        filter.addPattern("*.txt");
        chooser.addFilter(dialog, filter);
        chooser.setFilter(dialog, filter);
        if (chooser.getFilter(dialog) != filter) return 3;
    }
    if (std.mem.eql(u8, mode, "choices")) {
        const choices = glib.Variant.parse(null, "[('remember', 'Remember', @a(ss) [], 'true'), ('mode', 'Mode', [('light', 'Light'), ('dark', 'Dark')], 'dark')]", null, null, null).?;
        defer choices.unref();
        if (chooser.setChoices(dialog, choices, null) == 0) return 3;
        check_choices = true;
    }
    u.connect(dialog, "response", &response, null);
    if (args.len > 4 and std.mem.eql(u8, args[4], "accept")) {
        _ = glib.timeoutAdd(100, &accept, dialog);
        _ = glib.timeoutAddSeconds(5, &timeout, null);
    }
    cast(gtk.Window, dialog).present();
    loop.run();
    return status;
}
