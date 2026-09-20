const std = @import("std");
const u = @import("../ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const a = u.a;
const Context = @import("../context.zig").Context;
const Window = @import("../window.zig").Window;
const Command = @import("../actions.zig").Command;
pub fn available(program: [*:0]const u8) bool {
    const p = glib.findProgramInPath(program) orelse return false;
    glib.free(p);
    return true;
}
pub fn terminalProgram() ?[:0]const u8 {
    inline for (.{ "xdg-terminal-exec", "ghostty", "kgx", "gnome-terminal", "konsole", "foot", "xterm" }) |p| if (available(p)) return p;
    return null;
}
pub fn adminAvailable() bool {
    const schemes = gio.Vfs.getDefault().getSupportedUriSchemes();
    for (std.mem.span(schemes)) |s| if (std.mem.eql(u8, std.mem.span(s.?), "admin")) return true;
    return false;
}
pub fn common(c: *const Context) std.ArrayList(*gio.AppInfo) {
    var result: std.ArrayList(*gio.AppInfo) = .empty;
    if (c.items.items.len == 0) return result;
    const first = c.items.items[0].info orelse return result;
    const content = first.getContentType() orelse return result;
    const list = g_app_info_get_all_for_type(content);
    defer if (list) |l| l.free();
    var node: ?*glib.List = list;
    while (node) |n| : (node = n.f_next) {
        const app: *gio.AppInfo = @ptrCast(@alignCast(n.f_data.?));
        var compatible = app.shouldShow() != 0;
        for (c.items.items[1..]) |item| {
            const mime = if (item.info) |info| info.getContentType() else null;
            if (mime == null) {
                compatible = false;
                break;
            }
            const others = g_app_info_get_all_for_type(mime.?);
            defer if (others) |l| l.free();
            var next: ?*glib.List = others;
            var found = false;
            while (next) |entry| : (next = entry.f_next) {
                const other: *gio.AppInfo = @ptrCast(@alignCast(entry.f_data.?));
                if (other.equal(app) != 0) found = true;
                other.unref();
            }
            if (!found) {
                compatible = false;
                break;
            }
        }
        if (compatible and result.items.len < 12) result.append(a, app) catch unreachable else app.unref();
    }
    return result;
}
pub fn launch(owner: *Window, c: *const Context, app: *gio.AppInfo) void {
    var list: ?*glib.List = null;
    defer if (list) |l| l.free();
    for (c.items.items) |item| list = glib.List.append(list, item.file);
    const context = @import("gdk4").Display.getDefault().?.getAppLaunchContext();
    defer context.unref();
    var err: ?*glib.Error = null;
    if (app.launch(list, context.as(gio.AppLaunchContext), &err) == 0) if (err) |e| {
        defer e.free();
        owner.message("Could not open files", e.f_message orelse "Application launch failed");
    };
}
const Chooser = struct { owner: *Window, context: Context };
pub fn choose(owner: *Window, c: *const Context) void {
    if (c.items.items.len == 0) return;
    const dialog = gtk.AppChooserDialog.new(owner.window, .{ .modal = true }, c.target());
    const r = a.create(Chooser) catch unreachable;
    r.* = .{ .owner = owner, .context = c.clone() };
    owner.app.as(gio.Application).hold();
    dialog.as(gtk.Window).setDestroyWithParent(1);
    dialog.as(u.object.Object).setDataFull("phyto-chooser", r, chooserFreed);
    _ = gtk.Dialog.signals.response.connect(dialog.as(gtk.Dialog), *Chooser, chose, r, .{});
    dialog.as(gtk.Window).present();
}
fn chooserFreed(data: ?*anyopaque) callconv(.c) void {
    const r: *Chooser = @ptrCast(@alignCast(data.?));
    r.context.deinit();
    r.owner.app.as(gio.Application).release();
    a.destroy(r);
}
fn chose(dialog: *gtk.Dialog, response: c_int, r: *Chooser) callconv(.c) void {
    if (response == @intFromEnum(gtk.ResponseType.ok)) {
        if (u.object.ext.cast(gtk.AppChooserDialog, dialog).?.as(gtk.AppChooser).getAppInfo()) |app| {
            defer app.unref();
            launch(r.owner, &r.context, app);
        }
    }
    dialog.as(gtk.Window).destroy();
}
pub fn spawn(owner: *Window, args: []const [*:0]const u8, directory: ?*gio.File) void {
    const launcher = gio.SubprocessLauncher.new(.{});
    defer launcher.unref();
    if (directory) |dir| if (dir.getPath()) |p| {
        defer glib.free(p);
        launcher.setCwd(p);
    };
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(a);
    for (args) |arg| argv.append(a, arg) catch unreachable;
    argv.append(a, null) catch unreachable;
    var err: ?*glib.Error = null;
    const child = launcher.spawnv(@ptrCast(argv.items.ptr), &err) orelse {
        if (err) |e| {
            defer e.free();
            owner.message("Could not start application", e.f_message orelse "Launch failed");
        }
        return;
    };
    // GSubprocess reaps its child; external apps must not keep the file manager alive.
    child.unref();
}
pub fn terminal(owner: *Window, directory: *gio.File) void {
    const program = terminalProgram() orelse return;
    spawn(owner, &.{program}, directory);
}
pub fn follow(owner: *Window, c: *const Context) void {
    if (c.items.items.len != 1) return;
    const item = c.items.items[0];
    const info = item.info orelse return;
    const target = info.getSymlinkTarget() orelse {
        owner.message("Link unavailable", "The original target is not available.");
        return;
    };
    const parent = item.file.getParent() orelse return;
    defer parent.unref();
    const dest = parent.resolveRelativePath(target);
    defer dest.unref();
    const containing = dest.getParent() orelse return;
    defer containing.unref();
    (owner.findTab(c.tab_id) orelse return).navigate(containing, true);
}
const PropertyRequest = struct { owner: *Window, context: Context, text: std.ArrayList(u8) = .empty };
pub fn properties(owner: *Window, c: *const Context) void {
    const r = a.create(PropertyRequest) catch unreachable;
    r.* = .{ .owner = owner, .context = c.clone() };
    owner.app.as(gio.Application).hold();
    const task = gio.Task.new(null, owner.background_cancel, propertiesReady, r);
    defer task.unref();
    task.setTaskData(r, null);
    task.runInThread(propertiesWorker);
}
fn propertiesWorker(task: *gio.Task, _: *u.object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    const r: *PropertyRequest = @ptrCast(@alignCast(data.?));
    var c = &r.context;
    if (c.items.items.len == 0) c.add(c.directory, c.directory_info);
    var bytes: u64 = 0;
    var folders: usize = 0;
    for (c.items.items, 0..) |item, index| {
        if (r.owner.background_cancel.isCancelled() != 0) break;
        var err: ?*glib.Error = null;
        const info = item.file.queryInfo("standard::*,access::*,unix::mode,time::modified,trash::*", .{ .nofollow_symlinks = true }, r.owner.background_cancel, &err);
        defer if (info) |i| i.unref();
        defer if (err) |e| e.free();
        const path = item.file.getParseName();
        defer glib.free(path);
        if (info) |i| {
            if (i.getFileType() == .directory) folders += 1 else bytes += @intCast(@max(i.getSize(), 0));
            if (index < 20) {
                const size = u.sizeText(i);
                defer glib.free(size);
                const date = u.dateText(i);
                defer glib.free(date);
                const original = i.getAttributeByteString("trash::orig-path") orelse "";
                const line = u.format("{s}\n{s} · Modified: {s}\nPermissions: {o}{s}{s}\n\n", .{ path, size, date, i.getAttributeUint32("unix::mode") & 0o7777, if (original[0] != 0) "\nOriginal location: " else "", original });
                defer a.free(line);
                r.text.appendSlice(a, line) catch unreachable;
            }
        } else {
            const line = u.format("{s}: {s}\n", .{ path, if (err) |e| e.f_message orelse "Unavailable" else "Unavailable" });
            defer a.free(line);
            r.text.appendSlice(a, line) catch unreachable;
        }
    }
    const size = glib.formatSize(bytes);
    defer glib.free(size);
    const total = u.format("{d} selected · {d} folders · {s} in selected files\nFolder contents are not included in this size.", .{ c.items.items.len, folders, size });
    defer a.free(total);
    r.text.appendSlice(a, total) catch unreachable;
    r.text.append(a, 0) catch unreachable;
    task.returnBoolean(1);
}
fn propertiesReady(_: ?*u.object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const r: *PropertyRequest = @ptrCast(@alignCast(data.?));
    defer {
        r.context.deinit();
        r.text.deinit(a);
        r.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    if (!r.owner.closed) r.owner.message("Properties", @ptrCast(r.text.items.ptr));
}
pub fn archive(c: *const Context) bool {
    if (c.items.items.len != 1) return false;
    const info = c.items.items[0].info orelse return false;
    const mime = std.mem.span(info.getContentType() orelse "");
    return std.mem.indexOf(u8, mime, "zip") != null or std.mem.indexOf(u8, mime, "tar") != null or std.mem.indexOf(u8, mime, "compressed") != null or std.mem.indexOf(u8, mime, "archive") != null;
}
pub fn integration(owner: *Window, c: *const Context, cmd: Command) void {
    if (cmd == .admin) {
        const path = c.target().getPath() orelse return;
        defer glib.free(path);
        const escaped = glib.Uri.escapeString(path, "/", 0);
        defer glib.free(escaped);
        const uri = u.format("admin://{s}", .{escaped});
        defer a.free(uri);
        const file = gio.File.newForUri(uri);
        defer file.unref();
        owner.addTab(c.pane, file);
        owner.sync();
        return;
    }
    var args: std.ArrayList([*:0]const u8) = .empty;
    defer args.deinit(a);
    var paths: std.ArrayList([*:0]u8) = .empty;
    defer {
        for (paths.items) |p| glib.free(p);
        paths.deinit(a);
    }
    args.append(a, if (cmd == .bulk_rename) "bulky" else "file-roller") catch unreachable;
    if (cmd != .bulk_rename) args.append(a, if (cmd == .archive) "--add" else "--extract") catch unreachable;
    args.append(a, "--") catch unreachable;
    for (c.items.items) |item| {
        const path = item.file.getPath() orelse return;
        paths.append(a, path) catch unreachable;
        args.append(a, path) catch unreachable;
    }
    spawn(owner, args.items, c.directory);
}
const VolumeRequest = struct { owner: *Window, context: Context, command: Command, operation: *gtk.MountOperation };
pub fn volume(owner: *Window, c: *const Context, cmd: Command) void {
    const r = a.create(VolumeRequest) catch unreachable;
    r.* = .{ .owner = owner, .context = c.clone(), .command = cmd, .operation = gtk.MountOperation.new(owner.window) };
    owner.app.as(gio.Application).hold();
    if (cmd == .mount) c.volume.?.mount(.{}, r.operation.as(gio.MountOperation), null, volumeReady, r) else if (cmd == .eject and c.mount == null) c.volume.?.ejectWithOperation(.{}, r.operation.as(gio.MountOperation), null, volumeReady, r) else if (cmd == .eject) c.mount.?.ejectWithOperation(.{}, r.operation.as(gio.MountOperation), null, volumeReady, r) else c.mount.?.unmountWithOperation(.{}, r.operation.as(gio.MountOperation), null, volumeReady, r);
}
fn volumeReady(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const r: *VolumeRequest = @ptrCast(@alignCast(data.?));
    defer {
        r.context.deinit();
        r.operation.unref();
        r.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    var err: ?*glib.Error = null;
    _ = if (r.command == .mount) r.context.volume.?.mountFinish(result, &err) else if (r.command == .eject and r.context.mount == null) r.context.volume.?.ejectWithOperationFinish(result, &err) else if (r.command == .eject) r.context.mount.?.ejectWithOperationFinish(result, &err) else r.context.mount.?.unmountWithOperationFinish(result, &err);
    if (err) |e| {
        defer e.free();
        r.owner.message("Device operation failed", e.f_message orelse "The device may be busy or unavailable.");
    }
    if (!r.owner.closed) r.owner.refreshPlaces();
}
pub const Provider = struct {
    name: [:0]u8,
    argv: [*:null]?[*:0]u8,
    selection: enum { any, single, multiple, none } = .any,
    directories: bool = false,
    pub fn matches(self: *const Provider, c: *const Context) bool {
        const n = c.items.items.len;
        if (self.selection == .single and n != 1 or self.selection == .multiple and n < 2 or self.selection == .none and n != 0 or self.selection == .any and n == 0) return false;
        if (self.directories) for (c.items.items) |item| {
            if (item.info == null or item.info.?.getFileType() != .directory) return false;
        };
        for (std.mem.span(self.argv)) |arg| if (std.mem.eql(u8, std.mem.span(arg.?), "%F") or std.mem.eql(u8, std.mem.span(arg.?), "%P")) {
            for (c.items.items) |item| {
                const p = item.file.getPath() orelse return false;
                glib.free(p);
            }
        };
        return true;
    }
};
pub const Providers = struct {
    items: std.ArrayList(*Provider) = .empty,
    templates: std.ArrayList(*gio.File) = .empty,
    pub fn deinit(self: *Providers) void {
        for (self.items.items) |p| {
            a.free(p.name);
            glib.strfreev(p.argv);
            a.destroy(p);
        }
        self.items.deinit(a);
        for (self.templates.items) |f| f.unref();
        self.templates.deinit(a);
    }
    pub fn load(self: *Providers) void {
        // Installed providers only. A browsed folder is never searched for executables.
        const dirpath = u.format("{s}/phyto/actions", .{glib.getUserDataDir()});
        defer a.free(dirpath);
        self.loadDirectory("/usr/share/phyto/actions");
        self.loadDirectory(dirpath);
        const template_path = glib.getUserSpecialDir(.directory_templates) orelse return;
        const dir = gio.File.newForPath(template_path);
        defer dir.unref();
        const entries = dir.enumerateChildren("standard::name,standard::type", .{ .nofollow_symlinks = true }, null, null) orelse return;
        defer entries.unref();
        while (entries.nextFile(null, null)) |info| {
            defer info.unref();
            if (self.templates.items.len >= 30) break;
            if (info.getFileType() == .regular) self.templates.append(a, dir.getChild(info.getName())) catch unreachable;
        }
    }
    fn loadDirectory(self: *Providers, path: [*:0]const u8) void {
        const dir = gio.File.newForPath(path);
        defer dir.unref();
        const entries = dir.enumerateChildren("standard::name,standard::type,standard::size", .{ .nofollow_symlinks = true }, null, null) orelse return;
        defer entries.unref();
        while (entries.nextFile(null, null)) |info| {
            defer info.unref();
            if (self.items.items.len >= 64) break;
            if (info.getFileType() != .regular or info.getSize() > 65536 or !std.mem.endsWith(u8, std.mem.span(info.getName()), ".action")) continue;
            const file = dir.getChild(info.getName());
            defer file.unref();
            const local = file.getPath() orelse continue;
            defer glib.free(local);
            const key = glib.KeyFile.new();
            defer key.unref();
            if (key.loadFromFile(local, .{}, null) == 0) continue;
            const name_ = key.getString("Phyto Action", "Name", null) orelse continue;
            defer glib.free(name_);
            const exec = key.getString("Phyto Action", "Exec", null) orelse continue;
            defer glib.free(exec);
            var argv: [*:null]?[*:0]u8 = undefined;
            if (glib.shellParseArgv(exec, null, &argv, null) == 0) continue;
            if (argv[0] == null or !available(argv[0].?)) {
                glib.strfreev(argv);
                continue;
            }
            var valid = true;
            for (std.mem.span(argv)) |arg| {
                const s = std.mem.span(arg.?);
                if (std.mem.indexOfScalar(u8, s, '%') != null and !std.mem.eql(u8, s, "%F") and !std.mem.eql(u8, s, "%U") and !std.mem.eql(u8, s, "%P") and !std.mem.eql(u8, s, "%%")) valid = false;
            }
            if (!valid) {
                glib.strfreev(argv);
                continue;
            }
            const p = a.create(Provider) catch unreachable;
            p.* = .{ .name = a.dupeZ(u8, std.mem.span(name_)) catch unreachable, .argv = argv, .directories = key.getBoolean("Phyto Action", "Directories", null) != 0 };
            if (key.getString("Phyto Action", "Selection", null)) |sel| {
                defer glib.free(sel);
                p.selection = std.meta.stringToEnum(@FieldType(Provider, "selection"), std.mem.span(sel)) orelse .any;
            }
            self.items.append(a, p) catch unreachable;
        }
    }
};
pub fn templates(menu: *@import("../context_menu.zig").Menu, model: *gio.Menu) void {
    for (menu.providers.templates.items) |f| {
        const name_ = f.getBasename() orelse continue;
        defer glib.free(name_);
        menu.extra(model, name_, .{ .kind = .template, .file = f });
    }
}
pub fn runProvider(owner: *Window, c: *const Context, provider: *Provider) void {
    if (!provider.matches(c)) return;
    var argv: std.ArrayList([*:0]const u8) = .empty;
    defer argv.deinit(a);
    var allocated: std.ArrayList([*:0]u8) = .empty;
    defer {
        for (allocated.items) |s| glib.free(s);
        allocated.deinit(a);
    }
    for (std.mem.span(provider.argv)) |raw| {
        const token = std.mem.span(raw.?);
        if (std.mem.eql(u8, token, "%F") or std.mem.eql(u8, token, "%U")) {
            for (c.items.items) |item| {
                const s = if (token[1] == 'F') item.file.getPath() orelse return else item.file.getUri();
                allocated.append(a, s) catch unreachable;
                argv.append(a, s) catch unreachable;
            }
        } else if (std.mem.eql(u8, token, "%P")) {
            const s = c.directory.getPath() orelse return;
            allocated.append(a, s) catch unreachable;
            argv.append(a, s) catch unreachable;
        } else argv.append(a, if (std.mem.eql(u8, token, "%%")) "%" else raw.?) catch unreachable;
    }
    spawn(owner, argv.items, c.directory);
}

extern "c" fn g_app_info_get_all_for_type([*:0]const u8) ?*glib.List;
