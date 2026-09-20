//! A bounded set of asynchronous GIO actions for the native design slice.
//! Copy never overwrites; full recursive transfers/undo remain a separate milestone.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const a = u.a;
const Window = @import("window.zig").Window;

pub const Operations = struct {
    owner: *Window,
    busy: bool = false,
    kind: enum { mkdir, rename, trash, copy } = .copy,
    source: ?*gio.File = null,
    destination: ?*gio.File = null,
    cancel: ?*gio.Cancellable = null,
    dialog: ?*gtk.Dialog = null,
    entry: ?*gtk.Entry = null,
    error_label: ?*gtk.Label = null,
    progress: ?*gtk.ProgressBar = null,
    progress_text: ?*gtk.Label = null,
    fraction: f64 = 0,
    last_progress: i64 = 0,
    result: [:0]const u8 = "No file operations are running.",
    conflict: bool = false,
    pub fn init(owner: *Window) Operations {
        return .{ .owner = owner };
    }
    pub fn deinit(self: *Operations) void {
        self.closeDialogs();
        self.clearFiles();
    }
    fn clearFiles(self: *Operations) void {
        if (self.source) |f| f.unref();
        if (self.destination) |f| f.unref();
        if (self.cancel) |c| c.unref();
        self.source = null;
        self.destination = null;
        self.cancel = null;
    }
    pub fn closeDialogs(self: *Operations) void {
        if (self.dialog) |d| d.as(gtk.Window).destroy();
        self.dialog = null;
        self.entry = null;
        self.error_label = null;
        self.progress = null;
        self.progress_text = null;
    }
    fn newDialog(self: *Operations, title: [*:0]const u8) *gtk.Dialog {
        self.closeDialogs();
        const d = gtk.Dialog.new();
        self.dialog = d;
        d.as(gtk.Window).setTitle(title);
        d.as(gtk.Window).setTransientFor(self.owner.window);
        d.as(gtk.Window).setModal(1);
        d.as(gtk.Window).setDefaultSize(460, -1);
        d.as(gtk.Widget).addCssClass("phyto-root");
        d.as(gtk.Widget).addCssClass(if (self.owner.options.light) "light" else "dark");
        d.getContentArea().as(gtk.Widget).addCssClass("dialog-body");
        d.getContentArea().append(u.label(title, "state-title").as(gtk.Widget));
        return d;
    }
    fn oneSelected(self: *Operations) ?*gio.FileInfo {
        const selection = self.owner.current().selection.as(gtk.SelectionModel).getSelection();
        defer selection.unref();
        if (selection.getSize() != 1) {
            self.owner.message("Select one item", "This version performs these file actions one item at a time.");
            return null;
        }
        return self.owner.current().selected();
    }
    pub fn nameDialog(self: *Operations, rename: bool) void {
        if (self.busy) {
            self.present();
            return;
        }
        self.clearFiles();
        self.kind = if (rename) .rename else .mkdir;
        const info = if (rename) self.oneSelected() orelse return else null;
        defer if (info) |i| i.unref();
        self.source = if (info) |i| blk: {
            const f = u.file(i);
            f.ref();
            break :blk f;
        } else gio.File.newForUri(self.owner.current().uri);
        const d = self.newDialog(if (rename) "Rename item" else "New folder");
        const e = gtk.Entry.new();
        self.entry = e;
        u.name(e.as(gtk.Widget), "Name");
        if (info) |i| e.as(gtk.Editable).setText(i.getDisplayName());
        e.setActivatesDefault(1);
        d.getContentArea().append(e.as(gtk.Widget));
        const error_label = u.label("", "error");
        error_label.setWrap(1);
        self.error_label = error_label;
        d.getContentArea().append(error_label.as(gtk.Widget));
        _ = d.addButton("Cancel", 0);
        const ok = d.addButton(if (rename) "Rename" else "Create", 1);
        ok.addCssClass("suggested-action");
        d.setDefaultResponse(1);
        _ = gtk.Dialog.signals.response.connect(d, *Operations, nameResponse, self, .{});
        d.as(gtk.Window).present();
        _ = e.as(gtk.Widget).grabFocus();
    }
    fn nameResponse(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        if (response != 1) {
            self.closeDialogs();
            self.clearFiles();
            return;
        }
        const text = self.entry.?.as(gtk.Editable).getText();
        if (!@import("core/model.zig").validName(std.mem.span(text))) {
            self.error_label.?.setText("Enter a name without /; . and .. are not allowed.");
            return;
        }
        const name = a.dupeZ(u8, std.mem.span(text)) catch unreachable;
        defer a.free(name);
        if (self.kind == .mkdir) self.destination = self.source.?.getChildForDisplayName(name, null);
        if (self.kind == .mkdir and self.destination == null) {
            self.error_label.?.setText("This filesystem does not accept that name.");
            return;
        }
        self.closeDialogs();
        self.begin();
        if (self.kind == .mkdir) self.destination.?.makeDirectoryAsync(0, self.cancel, completed, self) else self.source.?.setDisplayNameAsync(name, 0, self.cancel, completed, self);
    }
    pub fn trashDialog(self: *Operations) void {
        if (self.busy) {
            self.present();
            return;
        }
        const info = self.oneSelected() orelse return;
        defer info.unref();
        self.clearFiles();
        self.kind = .trash;
        self.source = u.file(info);
        self.source.?.ref();
        const d = self.newDialog("Move to Trash?");
        const text = u.format("Move “{s}” to Trash? If this location does not support Trash, the item will remain in place.", .{info.getDisplayName()});
        defer a.free(text);
        const caption = u.label(text, null);
        caption.setWrap(1);
        caption.setMaxWidthChars(50);
        d.getContentArea().append(caption.as(gtk.Widget));
        _ = d.addButton("Cancel", 0);
        _ = d.addButton("Move to Trash", 1);
        d.setDefaultResponse(0);
        _ = gtk.Dialog.signals.response.connect(d, *Operations, trashResponse, self, .{});
        d.as(gtk.Window).present();
    }
    fn trashResponse(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        self.closeDialogs();
        if (response != 1) {
            self.clearFiles();
            return;
        }
        self.begin();
        self.source.?.trashAsync(0, self.cancel, completed, self);
    }
    pub fn copySelection(self: *Operations) void {
        const info = self.oneSelected() orelse return;
        defer info.unref();
        if (info.getFileType() != .regular) {
            self.owner.message("Copy files", "This version copies individual regular files. Recursive folder transfers are planned separately.");
            return;
        }
        if (self.owner.clipboard) |old| old.unref();
        const source = u.file(info);
        source.ref();
        self.owner.clipboard = source;
        self.owner.status_message = u.format("Copied “{s}” · Navigate to a destination, then Paste file", .{info.getDisplayName()});
        self.owner.queueUpdate();
    }
    pub fn paste(self: *Operations) void {
        if (self.busy) {
            self.present();
            return;
        }
        const copied = self.owner.clipboard orelse {
            self.owner.message("Nothing to paste", "Select one file and use Copy file first. The copy buffer is local to this window.");
            return;
        };
        self.clearFiles();
        self.kind = .copy;
        self.source = copied;
        copied.ref();
        const parent = gio.File.newForUri(self.owner.current().uri);
        defer parent.unref();
        const name = copied.getBasename() orelse return;
        defer glib.free(name);
        self.destination = parent.getChild(name);
        self.begin();
        self.copy();
        self.present();
    }
    fn begin(self: *Operations) void {
        self.busy = true;
        self.fraction = 0;
        self.conflict = false;
        self.cancel = gio.Cancellable.new();
        self.owner.app.as(gio.Application).hold();
    }
    fn copy(self: *Operations) void {
        self.conflict = false;
        self.source.?.copyAsync(self.destination.?, .{ .nofollow_symlinks = true }, 0, self.cancel, copyProgress, self, completed, self);
    }
    fn copyProgress(current: i64, total: i64, data: ?*anyopaque) callconv(.c) void {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        self.fraction = if (total > 0) @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total)) else 0;
        const now = glib.getMonotonicTime();
        if (now - self.last_progress < 100000 and current != total) return;
        self.last_progress = now;
        if (self.progress) |bar| bar.setFraction(self.fraction);
    }
    fn completed(source: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const f: *gio.File = @ptrCast(source.?);
        switch (self.kind) {
            .mkdir => _ = f.makeDirectoryFinish(result, &err),
            .trash => _ = f.trashFinish(result, &err),
            .rename => if (f.setDisplayNameFinish(result, &err)) |renamed| renamed.unref(),
            .copy => _ = f.copyFinish(result, &err),
        }
        if (err) |e| {
            defer e.free();
            if (self.kind == .copy and e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.exists)) != 0) {
                self.conflict = true;
                self.present();
                return;
            }
            self.finish("Operation did not complete");
            self.owner.message("Operation did not complete", e.f_message orelse "Unknown I/O error");
        } else self.finish("Operation complete");
    }
    fn finish(self: *Operations, result: [:0]const u8) void {
        self.busy = false;
        self.conflict = false;
        self.result = result;
        self.closeDialogs();
        self.clearFiles();
        if (self.owner.status_message) |m| a.free(m);
        self.owner.status_message = a.dupeZ(u8, result) catch unreachable;
        self.owner.queueUpdate();
        self.owner.app.as(gio.Application).release();
    }
    pub fn present(self: *Operations) void {
        if (!self.busy) {
            self.owner.message("File operations", self.result);
            return;
        }
        const d = self.newDialog(if (self.conflict) "A file with this name already exists" else "File operations");
        if (self.source) |source| {
            const src = source.getParseName();
            defer glib.free(src);
            const name = u.label(src, "secondary");
            name.setWrap(1);
            name.setWrapMode(.word_char);
            name.setMaxWidthChars(48);
            d.getContentArea().append(name.as(gtk.Widget));
        }
        if (self.destination) |dest| {
            const dst = dest.getParseName();
            defer glib.free(dst);
            const text = u.format("To: {s}", .{dst});
            defer a.free(text);
            const name = u.label(text, null);
            name.setWrap(1);
            name.setWrapMode(.word_char);
            name.setMaxWidthChars(48);
            d.getContentArea().append(name.as(gtk.Widget));
        }
        if (self.conflict) {
            const explanation = u.label("The existing file will be kept. Skip this copy or give the new copy a different name.", "secondary");
            explanation.setWrap(1);
            explanation.setMaxWidthChars(48);
            d.getContentArea().append(explanation.as(gtk.Widget));
            _ = d.addButton("Skip", 0);
            _ = d.addButton("Keep both", 2);
            d.setDefaultResponse(0);
        } else {
            const bar = gtk.ProgressBar.new();
            bar.setFraction(self.fraction);
            self.progress = bar;
            d.getContentArea().append(bar.as(gtk.Widget));
            _ = d.addButton("Cancel operation", 0);
            _ = d.addButton("Keep working", 1);
        }
        _ = gtk.Dialog.signals.response.connect(d, *Operations, jobResponse, self, .{});
        d.as(gtk.Window).present();
    }
    fn jobResponse(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        self.closeDialogs();
        if (self.conflict) {
            if (response == 2) {
                const old = self.destination.?;
                const parent = old.getParent().?;
                defer parent.unref();
                const basename = old.getBasename().?;
                defer glib.free(basename);
                const unique = glib.uuidStringRandom();
                defer glib.free(unique);
                const name = u.format("{s} (copy {s})", .{ basename, std.mem.span(unique)[0..8] });
                defer a.free(name);
                self.destination = parent.getChild(name);
                old.unref();
                self.copy();
                self.present();
            } else self.finish("Copy skipped · Existing file kept");
        } else if (response == 0) self.cancel.?.cancel();
    }
};
