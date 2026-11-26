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
    if (response == @backingInt(gtk.ResponseType.ok)) {
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
    const path = directory.getPath();
    defer if (path) |p| glib.free(p);
    // Single-instance terminals hand off to a running process that keeps its
    // own cwd, so the launcher's cwd alone never reaches the new window.
    if (path) |p| if (terminalDirectoryFlag(program)) |flag| {
        const arg = u.format("{s}={s}", .{ flag, p });
        defer a.free(arg);
        spawn(owner, &.{ program, arg }, directory);
        return;
    };
    spawn(owner, &.{program}, directory);
}
fn terminalDirectoryFlag(program: [:0]const u8) ?[:0]const u8 {
    if (std.mem.eql(u8, program, "konsole")) return "--workdir";
    inline for (.{ "ghostty", "gnome-terminal", "foot" }) |p| if (std.mem.eql(u8, program, p)) return "--working-directory";
    return null;
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
const PropertyRequest = struct { owner: *Window, context: Context, text: std.ArrayList(u8) = .empty, info: ?*gio.FileInfo = null, folder_size: ?u64 = null, folder_partial: bool = false };
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
    if (c.items.items.len == 1) {
        propertiesSingle(r, c.items.items[0].file);
        task.returnBoolean(1);
        return;
    }
    var bytes: u64 = 0;
    var folders: usize = 0;
    var unmeasured: usize = 0;
    var partial: usize = 0;
    for (c.items.items, 0..) |item, index| {
        if (r.owner.background_cancel.isCancelled() != 0) break;
        var err: ?*glib.Error = null;
        const info = item.file.queryInfo("standard::*,access::*,unix::mode,time::modified,trash::*", .{ .nofollow_symlinks = true }, r.owner.background_cancel, &err);
        defer if (info) |i| i.unref();
        defer if (err) |e| e.free();
        const path = item.file.getParseName();
        defer glib.free(path);
        if (info) |i| {
            var folder_size: ?u64 = null;
            if (i.getFileType() == .directory) {
                folders += 1;
                // Enumeration-based recursion works on network backends too;
                // unreadable subtrees are skipped and reported as partial.
                if (@import("measure.zig").folderSize(item.file, r.owner.background_cancel)) |m| {
                    folder_size = m.bytes;
                    bytes += m.bytes;
                    if (!m.complete) partial += 1;
                } else unmeasured += 1;
            } else bytes += @intCast(@max(i.getSize(), 0));
            if (index < 20) {
                const size = if (folder_size) |s| glib.formatSize(s) else u.sizeText(i);
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
    const skipped = unmeasured + partial;
    const total = if (skipped > 0) u.format("{d} selected · {d} folders · {s} total\n{d} folders could not be fully measured.", .{ c.items.items.len, folders, size, skipped }) else u.format("{d} selected · {d} folders · {s} total", .{ c.items.items.len, folders, size });
    defer a.free(total);
    r.text.appendSlice(a, total) catch unreachable;
    r.text.append(a, 0) catch unreachable;
    task.returnBoolean(1);
}
fn propertiesSingle(r: *PropertyRequest, file: *gio.File) void {
    var err: ?*glib.Error = null;
    const info = file.queryInfo("standard::*,access::*,unix::mode,unix::user,unix::group,time::modified,trash::*", .{ .nofollow_symlinks = true }, r.owner.background_cancel, &err);
    defer if (err) |e| e.free();
    if (info) |i| {
        if (i.getFileType() == .directory) {
            // Enumeration-based recursion works on network backends too;
            // unreadable subtrees are skipped and reported as partial.
            if (@import("measure.zig").folderSize(file, r.owner.background_cancel)) |m| {
                r.folder_size = m.bytes;
                r.folder_partial = !m.complete;
            }
        }
        r.info = i;
    } else {
        const path = file.getParseName();
        defer glib.free(path);
        const line = u.format("{s}: {s}\n", .{ path, if (err) |e| e.f_message orelse "Unavailable" else "Unavailable" });
        defer a.free(line);
        r.text.appendSlice(a, line) catch unreachable;
        r.text.append(a, 0) catch unreachable;
    }
}
fn propertiesReady(_: ?*u.object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const r: *PropertyRequest = @ptrCast(@alignCast(data.?));
    defer {
        r.context.deinit();
        r.text.deinit(a);
        r.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    if (r.owner.closed) return;
    if (r.info) |info| {
        defer info.unref();
        propertiesDialog(r.owner, r.context.items.items[0].file, info, r.folder_size, r.folder_partial);
    } else r.owner.message("Properties", @ptrCast(r.text.items.ptr));
}
const PropertiesState = struct {
    owner: *Window,
    file: *gio.File,
    mode: u32 = 0,
    checks: [9]*gtk.CheckButton = undefined,
    mode_label: *gtk.Label,
    error_label: *gtk.Label,
    updating: bool = false,
};
fn propertiesDialog(owner: *Window, file: *gio.File, info: *gio.FileInfo, folder_size: ?u64, folder_partial: bool) void {
    const i18n = @import("i18n");
    const title = i18n.dtr("phyto", "Properties");
    if (owner.properties_dialog) |old| old.as(gtk.Window).destroy();
    const dialog = gtk.Dialog.new();
    owner.properties_dialog = dialog;
    dialog.as(gtk.Widget).addCssClass("phyto-root");
    dialog.as(gtk.Widget).addCssClass(@import("../appearance.zig").themeClass());
    dialog.as(gtk.Window).setTitle(title);
    dialog.as(gtk.Window).setTransientFor(owner.window);
    dialog.as(gtk.Window).setDestroyWithParent(1);
    dialog.as(gtk.Window).setModal(1);
    dialog.as(gtk.Window).setDefaultSize(460, -1);
    const body = dialog.getContentArea();
    body.as(gtk.Widget).addCssClass("dialog-body");
    const header = u.box(.horizontal, 12, null);
    const icon = gtk.Image.new();
    u.infoIcon(info, icon);
    icon.setPixelSize(48);
    header.append(icon.as(gtk.Widget));
    const name = u.label(info.getDisplayName(), "state-title");
    name.setWrap(1);
    name.setWrapMode(.word_char);
    name.setMaxWidthChars(30);
    name.as(gtk.Widget).setValign(.center);
    header.append(name.as(gtk.Widget));
    body.append(header.as(gtk.Widget));
    const details = gtk.Grid.new();
    details.setRowSpacing(6);
    details.setColumnSpacing(16);
    var row: c_int = 0;
    if (info.getFileType() == .directory) {
        detail(details, &row, i18n.dtr("phyto", "Type"), i18n.dtr("phyto", "Folder"));
    } else if (info.getFileType() == .symbolic_link) {
        detail(details, &row, i18n.dtr("phyto", "Type"), i18n.dtr("phyto", "Symbolic link"));
    } else if (info.getContentType()) |mime| {
        const description = gio.contentTypeGetDescription(mime);
        defer glib.free(description);
        detail(details, &row, i18n.dtr("phyto", "Type"), std.mem.span(description));
    }
    if (folder_size) |s| {
        const text = glib.formatSize(s);
        defer glib.free(text);
        const value = if (folder_partial) u.format("{s} ({s})", .{ text, i18n.dtr("phyto", "partial") }) else u.format("{s}", .{text});
        defer a.free(value);
        detail(details, &row, i18n.dtr("phyto", "Size"), value);
    } else {
        const text = u.sizeText(info);
        defer glib.free(text);
        detail(details, &row, i18n.dtr("phyto", "Size"), text);
    }
    if (file.getParent()) |parent| {
        defer parent.unref();
        if (parent.getPath()) |p| {
            defer glib.free(p);
            detail(details, &row, i18n.dtr("phyto", "Location"), p);
        }
    }
    const date = u.dateText(info);
    defer glib.free(date);
    detail(details, &row, i18n.dtr("phyto", "Modified"), date);
    if (info.getAttributeString("unix::user")) |user| detail(details, &row, i18n.dtr("phyto", "Owner"), user);
    if (info.getAttributeString("unix::group")) |group| detail(details, &row, i18n.dtr("phyto", "Group"), group);
    if (info.getSymlinkTarget()) |target| detail(details, &row, i18n.dtr("phyto", "Target"), target);
    if (info.getAttributeByteString("trash::orig-path")) |original| {
        if (original[0] != 0) detail(details, &row, i18n.dtr("phyto", "Original location"), original);
    }
    body.append(details.as(gtk.Widget));
    file.ref();
    const state = a.create(PropertiesState) catch unreachable;
    state.* = .{ .owner = owner, .file = file, .mode_label = u.label("", "secondary"), .error_label = u.label("", "error") };
    state.error_label.setWrap(1);
    state.error_label.setWrapMode(.word_char);
    state.error_label.setMaxWidthChars(40);
    state.error_label.as(gtk.Widget).setVisible(0);
    dialog.as(u.object.Object).setDataFull("phyto-properties", state, propertiesFreed);
    if (info.hasAttribute("unix::mode") != 0) {
        state.mode = info.getAttributeUint32("unix::mode") & 0o7777;
        body.append(u.label(i18n.dtr("phyto", "Permissions"), "section-label").as(gtk.Widget));
        const card = u.box(.vertical, 8, "permission-card");
        const permissions = gtk.Grid.new();
        permissions.setRowSpacing(6);
        permissions.setColumnSpacing(12);
        var who_row: c_int = 0;
        var index: usize = 0;
        inline for (.{ "Owner", "Group", "Other" }) |who| {
            permissions.attach(u.label(i18n.dtr("phyto", who), null).as(gtk.Widget), 0, who_row, 1, 1);
            var check_col: c_int = 1;
            inline for (.{ "Read", "Write", "Execute" }) |bit| {
                const check = gtk.CheckButton.newWithLabel(i18n.dtr("phyto", bit));
                check.setActive(if (state.mode & (@as(u32, 0o400) >> @intCast(index)) != 0) 1 else 0);
                const accessible = u.format("{s} {s}", .{ i18n.dtr("phyto", who), i18n.dtr("phyto", bit) });
                defer a.free(accessible);
                u.name(check.as(gtk.Widget), accessible);
                _ = gtk.CheckButton.signals.toggled.connect(check, *PropertiesState, permissionToggled, state, .{});
                state.checks[index] = check;
                permissions.attach(check.as(gtk.Widget), check_col, who_row, 1, 1);
                check_col += 1;
                index += 1;
            }
            who_row += 1;
        }
        card.append(permissions.as(gtk.Widget));
        updateModeLabel(state);
        card.append(state.mode_label.as(gtk.Widget));
        card.append(state.error_label.as(gtk.Widget));
        body.append(card.as(gtk.Widget));
    }
    const close_button = dialog.addButton(i18n.dtr("phyto", "Close"), @backingInt(gtk.ResponseType.close));
    _ = gtk.Dialog.signals.response.connect(dialog, *PropertiesState, propertiesResponse, state, .{});
    if (@import("build_options").test_hooks) {
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *PropertiesState, propertiesKey, state, .{});
        dialog.as(gtk.Widget).addController(keys.as(gtk.EventController));
    }
    dialog.as(gtk.Window).present();
    // Focus Close so the dialog does not open with a text caret in a selectable detail.
    dialog.as(gtk.Window).setFocus(close_button);
}
fn propertiesKey(_: *gtk.EventControllerKey, key: c_uint, _: c_uint, _: @import("gdk4").ModifierType, state: *PropertiesState) callconv(.c) c_int {
    if (key == @import("gdk4").KEY_F12) {
        state.owner.probe();
        return 1;
    }
    return 0;
}
fn detail(grid: *gtk.Grid, row: *c_int, label: [*:0]const u8, value: [*:0]const u8) void {
    grid.attach(u.label(label, "secondary").as(gtk.Widget), 0, row.*, 1, 1);
    const text = u.label(value, null);
    text.setWrap(1);
    text.setWrapMode(.word_char);
    text.setMaxWidthChars(36);
    text.setSelectable(1);
    text.as(gtk.Widget).setHexpand(1);
    grid.attach(text.as(gtk.Widget), 1, row.*, 1, 1);
    row.* += 1;
}
fn updateModeLabel(state: *PropertiesState) void {
    const text = u.format("{s} {o:0>4}", .{ @import("i18n").dtr("phyto", "Mode:"), state.mode });
    defer a.free(text);
    state.mode_label.setText(text);
}
fn permissionToggled(_: *gtk.CheckButton, state: *PropertiesState) callconv(.c) void {
    if (state.updating) return;
    // setuid/setgid/sticky bits are preserved; only the nine access bits are editable.
    var mode: u32 = state.mode & ~@as(u32, 0o777);
    for (state.checks, 0..) |check, i| {
        if (check.getActive() != 0) mode |= @as(u32, 0o400) >> @intCast(i);
    }
    if (mode == state.mode) return;
    const attributes = gio.FileInfo.new();
    defer attributes.unref();
    attributes.setAttributeUint32("unix::mode", mode);
    var err: ?*glib.Error = null;
    if (state.file.setAttributesFromInfo(attributes, .{}, null, &err) == 0) {
        state.updating = true;
        for (state.checks, 0..) |check, i| check.setActive(if (state.mode & (@as(u32, 0o400) >> @intCast(i)) != 0) 1 else 0);
        state.updating = false;
        const fallback = @import("i18n").dtr("phyto", "The permissions could not be changed.");
        const text: [*:0]const u8 = if (err) |e| e.f_message orelse fallback else fallback;
        state.error_label.setText(text);
        state.error_label.as(gtk.Widget).setVisible(1);
        if (err) |e| e.free();
        return;
    }
    if (err) |e| e.free();
    state.mode = mode;
    state.error_label.as(gtk.Widget).setVisible(0);
    updateModeLabel(state);
}
fn propertiesResponse(dialog: *gtk.Dialog, _: c_int, state: *PropertiesState) callconv(.c) void {
    state.owner.properties_dialog = null;
    dialog.as(gtk.Window).destroy();
}
fn propertiesFreed(data: ?*anyopaque) callconv(.c) void {
    const state: *PropertiesState = @ptrCast(@alignCast(data.?));
    state.file.unref();
    a.destroy(state);
}
pub fn runnable(info: *gio.FileInfo) ?bool {
    if (info.getAttributeBoolean("access::can-execute") != 0) return false;
    const mime = std.mem.span(info.getContentType() orelse "");
    if (std.mem.indexOf(u8, mime, "executable") != null or std.mem.indexOf(u8, mime, "shellscript") != null or std.mem.indexOf(u8, mime, "x-sh") != null) return true;
    return null;
}
pub fn makeExecutable(owner: *Window, file: *gio.File) bool {
    const path = file.getPath() orelse return false;
    defer glib.free(path);
    var err: ?*glib.Error = null;
    const fresh = file.queryInfo("unix::mode", .{ .nofollow_symlinks = true }, null, &err) orelse {
        const text = if (err) |e| e.f_message else null;
        defer if (err) |e| e.free();
        owner.message(@import("i18n").dtr("phyto", "Could not run file"), text orelse @import("i18n").dtr("phyto", "The file could not be read."));
        return false;
    };
    defer fresh.unref();
    const mode: u16 = @truncate(fresh.getAttributeUint32("unix::mode"));
    if (g_chmod(path, @as(c_int, mode | 0o111)) != 0) {
        owner.message(@import("i18n").dtr("phyto", "Could not run file"), "The file could not be made executable. Check the folder permissions.");
        return false;
    }
    return true;
}
pub fn runExecutable(owner: *Window, file: *gio.File) void {
    const path = file.getPath() orelse return;
    defer glib.free(path);
    const dir = file.getParent() orelse return;
    defer dir.unref();
    spawn(owner, &.{path}, dir);
}
pub fn archiveMime(mime: []const u8) bool {
    return std.mem.indexOf(u8, mime, "zip") != null or std.mem.indexOf(u8, mime, "tar") != null or std.mem.indexOf(u8, mime, "compressed") != null or std.mem.indexOf(u8, mime, "archive") != null;
}
pub fn archive(c: *const Context) bool {
    if (c.items.items.len != 1) return false;
    const info = c.items.items[0].info orelse return false;
    return archiveMime(std.mem.span(info.getContentType() orelse ""));
}
pub const Extractor = enum { file_roller, bsdtar, unzip, tar };
pub fn extractorForMime(mime: []const u8) ?Extractor {
    if (!archiveMime(mime)) return null;
    if (available("file-roller")) return .file_roller;
    if (available("bsdtar")) return .bsdtar;
    if (std.mem.indexOf(u8, mime, "zip") != null) return if (available("unzip")) Extractor.unzip else null;
    return if (available("tar")) Extractor.tar else null;
}
pub fn extractor(c: *const Context) ?Extractor {
    if (c.items.items.len != 1) return null;
    const info = c.items.items[0].info orelse return null;
    return extractorForMime(std.mem.span(info.getContentType() orelse ""));
}
pub fn extractHere(owner: *Window, file: *gio.File, tool: Extractor) void {
    const path = file.getPath() orelse return;
    defer glib.free(path);
    const dir = file.getParent() orelse return;
    defer dir.unref();
    var args: std.ArrayList([*:0]const u8) = .empty;
    defer args.deinit(a);
    switch (tool) {
        .file_roller => args.appendSlice(a, &.{ "file-roller", "--extract", "--" }) catch unreachable,
        .bsdtar => args.appendSlice(a, &.{ "bsdtar", "-xf" }) catch unreachable,
        .unzip => args.appendSlice(a, &.{ "unzip", "-q" }) catch unreachable,
        .tar => args.appendSlice(a, &.{ "tar", "-xf" }) catch unreachable,
    }
    args.append(a, path) catch unreachable;
    spawn(owner, args.items, dir);
}
pub fn sendArchiveAvailable() bool {
    return available("bsdtar") or (available("tar") and available("xz")) or available("file-roller");
}
/// One-click compressed tar.xz beside the selection: "name.tar.xz", then
/// "name (2).tar.xz", … like numbered paste copies. tar tools store relative
/// basenames; file-roller (--add-to, non-interactive) is the last fallback.
pub fn sendArchive(owner: *Window, c: *const Context) void {
    if (c.items.items.len == 0) return;
    const base = if (c.items.items.len == 1) c.items.items[0].file.getBasename() else c.directory.getBasename();
    defer if (base) |b| glib.free(b);
    const stem = if (base) |b| std.mem.span(b) else "Archive";
    var target: ?*gio.File = null;
    var n: usize = 1;
    while (n < 10_000) : (n += 1) {
        const name = if (n == 1) u.format("{s}.tar.xz", .{stem}) else u.format("{s} ({d}).tar.xz", .{ stem, n });
        defer a.free(name);
        const candidate = c.directory.getChild(name);
        if (candidate.queryExists(null) == 0) {
            target = candidate;
            break;
        }
        candidate.unref();
    }
    const dest = target orelse return;
    defer dest.unref();
    const dest_path = dest.getPath() orelse return;
    defer glib.free(dest_path);
    var args: std.ArrayList([*:0]const u8) = .empty;
    defer args.deinit(a);
    var names: std.ArrayList([*:0]u8) = .empty;
    defer {
        for (names.items) |p| glib.free(p);
        names.deinit(a);
    }
    var add_flag: ?[:0]u8 = null;
    defer if (add_flag) |f| a.free(f);
    if (available("bsdtar") or (available("tar") and available("xz"))) {
        args.appendSlice(a, &.{ if (available("bsdtar")) "bsdtar" else "tar", "-cJf", dest_path, "--" }) catch unreachable;
        for (c.items.items) |item| {
            const name = item.file.getBasename() orelse return;
            names.append(a, name) catch unreachable;
            args.append(a, name) catch unreachable;
        }
    } else {
        add_flag = u.format("--add-to={s}", .{dest_path});
        args.appendSlice(a, &.{ "file-roller", add_flag.?, "--" }) catch unreachable;
        for (c.items.items) |item| {
            const path = item.file.getPath() orelse return;
            names.append(a, path) catch unreachable;
            args.append(a, path) catch unreachable;
        }
    }
    spawn(owner, args.items, c.directory);
}
pub fn integration(owner: *Window, c: *const Context, cmd: Command) void {
    if (cmd == .admin) {
        openAdmin(owner, c);
        return;
    }
    if (cmd == .extract) {
        extractHere(owner, c.items.items[0].file, extractor(c) orelse return);
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
const AdminRequest = struct { owner: *Window, pane: usize, file: *gio.File, operation: *gtk.MountOperation };
/// The GVFS admin backend is mountable: it must be mounted (which spawns
/// gvfsd-admin through pkexec and authenticates via polkit) before its contents
/// can be enumerated. Opening the tab without mounting first leaves it empty
/// with G_IO_ERROR_NOT_MOUNTED (issue: "Open as administrator" shows no files).
fn openAdmin(owner: *Window, c: *const Context) void {
    const path = c.target().getPath() orelse return;
    defer glib.free(path);
    const escaped = glib.Uri.escapeString(path, "/", 0);
    defer glib.free(escaped);
    const uri = u.format("admin://{s}", .{escaped});
    defer a.free(uri);
    const file = gio.File.newForUri(uri);
    const r = a.create(AdminRequest) catch {
        file.unref();
        return;
    };
    r.* = .{ .owner = owner, .pane = c.pane, .file = file, .operation = gtk.MountOperation.new(owner.window) };
    owner.app.as(gio.Application).hold();
    file.mountEnclosingVolume(.{}, r.operation.as(gio.MountOperation), null, adminMounted, r);
}
fn adminMounted(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const r: *AdminRequest = @ptrCast(@alignCast(data.?));
    defer {
        r.file.unref();
        r.operation.unref();
        r.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    var err: ?*glib.Error = null;
    if (r.file.mountEnclosingVolumeFinish(result, &err) == 0) {
        defer if (err) |e| e.free();
        r.owner.message("Could not open as administrator", if (err) |e| e.f_message orelse "Authentication failed or the admin backend is unavailable." else "Authentication failed or the admin backend is unavailable.");
        return;
    }
    if (r.owner.closed) return;
    r.owner.addTab(r.pane, r.file);
    r.owner.sync();
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
            p.* = .{ .name = a.dupeSentinel(u8, std.mem.span(name_), 0) catch unreachable, .argv = argv, .directories = key.getBoolean("Phyto Action", "Directories", null) != 0 };
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
extern "c" fn g_chmod([*:0]const u8, c_int) c_int;
