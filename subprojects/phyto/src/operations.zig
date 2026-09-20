//! Main-thread dialogs and worker jobs. Every operation owns its original targets.
const std = @import("std");
const u = @import("ui.zig");
const gtk = u.gtk;
const gio = u.gio;
const glib = u.glib;
const object = u.object;
const a = u.a;
const Window = @import("window.zig").Window;
const Context = @import("context.zig").Context;
pub const engine = @import("operations/engine.zig");
pub const Operations = struct {
    owner: *Window,
    busy: bool = false,
    conflict: bool = false,
    dialog: ?*gtk.Dialog = null,
    entry: ?*gtk.Entry = null,
    error_label: ?*gtk.Label = null,
    progress_text: ?*gtk.Label = null,
    timer: c_uint = 0,
    active: ?*engine.Job = null,
    pending: ?Context = null,
    naming: enum { folder, document, rename, bookmark } = .folder,
    confirm_kind: engine.Kind = .trash,
    undo_stack: std.ArrayList(*engine.Job) = .empty,
    redo_stack: std.ArrayList(*engine.Job) = .empty,
    journal_origin: ?*engine.Job = null,
    result: [:0]u8,
    pub fn init(owner: *Window) Operations {
        return .{ .owner = owner, .result = a.dupeZ(u8, "No file operations are running.") catch unreachable };
    }
    pub fn deinit(self: *Operations) void {
        self.closeDialogs();
        self.clearPending();
        for (self.undo_stack.items) |j| j.destroy();
        self.undo_stack.deinit(a);
        for (self.redo_stack.items) |j| j.destroy();
        self.redo_stack.deinit(a);
        a.free(self.result);
    }
    fn clearPending(self: *Operations) void {
        if (self.pending) |*c| c.deinit();
        self.pending = null;
    }
    pub fn closeDialogs(self: *Operations) void {
        if (self.dialog) |d| d.as(gtk.Window).destroy();
        self.dialog = null;
        self.entry = null;
        self.error_label = null;
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
        d.as(gtk.Widget).addCssClass(if (self.owner.options.native) "native" else if (self.owner.options.light) "light" else "dark");
        d.getContentArea().as(gtk.Widget).addCssClass("dialog-body");
        return d;
    }
    pub fn nameDialog(self: *Operations, rename: bool) void {
        var c = Context.capture(self.owner.current());
        defer c.deinit();
        self.name(&c, if (rename) .rename else .folder);
    }
    pub fn name(self: *Operations, c: *const Context, kind: @FieldType(Operations, "naming")) void {
        if (self.busy) {
            self.present();
            return;
        }
        if (kind == .rename and c.items.items.len != 1) return;
        self.clearPending();
        self.pending = c.clone();
        self.naming = kind;
        const title: [:0]const u8 = switch (kind) {
            .folder => "New folder",
            .document => "New document",
            .rename => "Rename item",
            .bookmark => "Rename bookmark",
        };
        const d = self.newDialog(title);
        const e = gtk.Entry.new();
        self.entry = e;
        u.name(e.as(gtk.Widget), "Name");
        if (kind == .rename or kind == .bookmark) {
            const name_ = c.target().getBasename();
            if (name_) |n| {
                e.as(gtk.Editable).setText(n);
                glib.free(n);
            }
        }
        e.setActivatesDefault(1);
        d.getContentArea().append(e.as(gtk.Widget));
        const err = u.label("", "error");
        err.setWrap(1);
        self.error_label = err;
        d.getContentArea().append(err.as(gtk.Widget));
        _ = d.addButton("Cancel", 0);
        _ = d.addButton(if (kind == .rename or kind == .bookmark) "Rename" else "Create", 1);
        d.setDefaultResponse(1);
        _ = gtk.Dialog.signals.response.connect(d, *Operations, nameResponse, self, .{});
        d.as(gtk.Window).present();
        _ = e.as(gtk.Widget).grabFocus();
    }
    fn nameResponse(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        if (response != 1) {
            self.closeDialogs();
            self.clearPending();
            return;
        }
        const raw = self.entry.?.as(gtk.Editable).getText();
        if (!@import("core/model.zig").validName(std.mem.span(raw))) {
            self.error_label.?.setText("Enter a name without /; . and .. are not allowed.");
            return;
        }
        const name_ = a.dupeZ(u8, std.mem.span(raw)) catch unreachable;
        defer a.free(name_);
        const c = &self.pending.?;
        if (self.naming == .bookmark) {
            self.owner.preferences.renameBookmark(c.target(), name_);
            self.owner.refreshPlaces();
            self.closeDialogs();
            self.clearPending();
            return;
        }
        const rename = self.naming == .rename;
        const parent = if (rename) c.target().getParent() orelse return else blk: {
            c.directory.ref();
            break :blk c.directory;
        };
        defer parent.unref();
        var err: ?*glib.Error = null;
        const dest = parent.getChildForDisplayName(name_, &err) orelse {
            if (err) |e| {
                self.error_label.?.setText(e.f_message orelse "Invalid filename");
                e.free();
            }
            return;
        };
        defer dest.unref();
        const j = engine.Job.create(if (rename) .move else if (self.naming == .document) .document else .mkdir);
        j.add(if (rename) c.target() else dest, dest);
        self.closeDialogs();
        self.clearPending();
        self.start(j);
    }
    pub fn trashDialog(self: *Operations) void {
        var c = Context.capture(self.owner.current());
        defer c.deinit();
        self.confirm(&c, .trash);
    }
    pub fn confirm(self: *Operations, c: *const Context, kind: engine.Kind) void {
        if (self.busy) {
            self.present();
            return;
        }
        if (c.items.items.len == 0 and kind != .empty_trash) return;
        self.clearPending();
        self.pending = c.clone();
        self.confirm_kind = kind;
        const title: [:0]const u8 = switch (kind) {
            .trash => "Move to Trash?",
            .empty_trash => "Empty Trash?",
            else => "Delete permanently?",
        };
        const d = self.newDialog(title);
        var description: std.ArrayList(u8) = .empty;
        defer description.deinit(a);
        description.appendSlice(a, if (kind == .trash) "Items that cannot be trashed will stay in place.\n\n" else "This cannot be undone.\n\n") catch unreachable;
        if (kind == .empty_trash) description.appendSlice(a, "All items currently in Trash will be permanently deleted.") catch unreachable;
        for (c.items.items[0..@min(c.items.items.len, 8)]) |item| {
            const path = item.file.getParseName();
            defer glib.free(path);
            description.appendSlice(a, std.mem.span(path)) catch unreachable;
            description.append(a, '\n') catch unreachable;
        }
        if (c.items.items.len > 8) {
            const count = u.format("… and {d} more items", .{c.items.items.len - 8});
            defer a.free(count);
            description.appendSlice(a, count) catch unreachable;
        }
        description.append(a, 0) catch unreachable;
        const label = u.label(@ptrCast(description.items.ptr), null);
        label.setWrap(1);
        label.setWrapMode(.word_char);
        label.setMaxWidthChars(50);
        d.getContentArea().append(label.as(gtk.Widget));
        _ = d.addButton("Cancel", 0);
        const ok = d.addButton(if (kind == .trash) "Move to Trash" else "Delete permanently", 1);
        if (kind != .trash) ok.addCssClass("destructive-action");
        d.setDefaultResponse(0);
        _ = gtk.Dialog.signals.response.connect(d, *Operations, confirmed, self, .{});
        d.as(gtk.Window).present();
    }
    fn confirmed(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        self.closeDialogs();
        if (response == 1) {
            const j = engine.Job.create(self.confirm_kind);
            const c = &self.pending.?;
            if (self.confirm_kind == .empty_trash) j.add(c.directory, null) else for (c.items.items) |item| j.add(item.file, null);
            self.clearPending();
            self.start(j);
        } else self.clearPending();
    }
    pub fn transfer(self: *Operations, c: *const Context, destination: ?*gio.File, kind: engine.Kind) void {
        const j = engine.Job.create(kind);
        for (c.items.items) |item| {
            var dest: ?*gio.File = null;
            if (destination) |parent| {
                const original = if (kind == .restore) (if (item.info) |i| i.getAttributeByteString("trash::orig-path") else null) else null;
                const basename = if (original) |path| glib.pathGetBasename(path) else item.file.getBasename() orelse continue;
                defer glib.free(basename);
                dest = parent.getChild(basename);
            }
            defer if (dest) |d| d.unref();
            j.add(item.file, dest);
        }
        self.start(j);
    }
    pub fn duplicate(self: *Operations, c: *const Context, link: bool) void {
        const j = engine.Job.create(if (link) .link else .copy);
        for (c.items.items) |item| {
            const parent = item.file.getParent() orelse continue;
            defer parent.unref();
            const base = item.file.getBasename() orelse continue;
            defer glib.free(base);
            const id = glib.uuidStringRandom();
            defer glib.free(id);
            const name_ = u.format("{s} ({s} {s})", .{ base, if (link) "link" else "copy", std.mem.span(id)[0..8] });
            defer a.free(name_);
            const dest = parent.getChild(name_);
            defer dest.unref();
            j.add(item.file, dest);
        }
        self.start(j);
    }
    pub fn copySelection(self: *Operations) void {
        var c = Context.capture(self.owner.current());
        defer c.deinit();
        self.copy(&c, false);
    }
    pub fn copy(self: *Operations, c: *const Context, cut: bool) void {
        var files: std.ArrayList(*gio.File) = .empty;
        defer files.deinit(a);
        for (c.items.items) |item| files.append(a, item.file) catch unreachable;
        self.owner.clipboard.write(files.items, cut);
        self.owner.setStatus(if (cut) "Cut · Choose a destination and Paste" else "Copied · Choose a destination and Paste");
    }
    pub fn paste(self: *Operations) void {
        const dir = gio.File.newForUri(self.owner.current().uri);
        defer dir.unref();
        self.pasteInto(dir);
    }
    pub fn pasteInto(self: *Operations, dir: *gio.File) void {
        const cb = &self.owner.clipboard;
        if (!cb.available()) return;
        const j = engine.Job.create(if (cb.cut) .move else .copy);
        j.cut = cb.cut;
        j.clipboard_serial = cb.serial;
        for (cb.files.items) |f| {
            const basename = f.getBasename() orelse continue;
            defer glib.free(basename);
            const dest = dir.getChild(basename);
            defer dest.unref();
            j.add(f, dest);
        }
        self.start(j);
    }
    pub fn start(self: *Operations, j: *engine.Job) void {
        if (self.busy) {
            j.destroy();
            self.present();
            return;
        }
        if (j.pairs.items.len == 0) {
            j.destroy();
            return;
        }
        self.active = j;
        self.busy = true;
        self.conflict = false;
        self.owner.context.close();
        self.owner.app.as(gio.Application).hold();
        self.owner.queueUpdate();
        self.timer = glib.timeoutAdd(250, tick, self);
        self.run();
    }
    fn run(self: *Operations) void {
        const j = self.active.?;
        const task = gio.Task.new(null, null, completed, self);
        defer task.unref();
        task.setTaskData(j, null);
        task.runInThread(worker);
    }
    fn worker(task: *gio.Task, _: *object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const j: *engine.Job = @ptrCast(@alignCast(data.?));
        j.run();
        task.returnBoolean(1);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        if (!self.busy) return 0;
        if (self.progress_text) |label| {
            const size = glib.formatSize(self.active.?.bytes.load(.monotonic));
            defer glib.free(size);
            label.setText(size);
        }
        return 1;
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        const j = self.active.?;
        if (j.conflict) {
            self.conflict = true;
            self.present();
            return;
        }
        self.finish();
    }
    fn finish(self: *Operations) void {
        const j = self.active.?;
        self.busy = false;
        self.conflict = false;
        self.active = null;
        if (self.timer != 0) {
            _ = glib.Source.remove(self.timer);
            self.timer = 0;
        }
        self.closeDialogs();
        var successful: usize = 0;
        var skipped: usize = 0;
        for (j.pairs.items) |p| {
            if (p.completed) successful += 1;
            if (p.skipped) skipped += 1;
        }
        a.free(self.result);
        self.result = u.format("{d} completed · {d} skipped{s}{s}", .{ successful, skipped, if (j.cancelled) " · Cancelled" else "", if (j.failures.items.len != 0) " · Some items failed" else "" });
        self.owner.setStatus(self.result);
        self.owner.clipboard.remaining(j);
        var relocated = false;
        if (j.kind == .move or j.kind == .restore) for (j.pairs.items) |p| {
            if (p.completed and p.destination != null) relocated = self.owner.preferences.relocated(p.source, p.destination.?) or relocated;
        };
        if (relocated) self.owner.refreshPlaces();
        if (j.failures.items.len > 0) {
            const msg = a.dupeZ(u8, j.failures.items) catch unreachable;
            defer a.free(msg);
            self.owner.message("Some items did not complete", msg);
        }
        if (self.journal_origin) |origin| {
            for (j.pairs.items) |p| if (p.completed) {
                const old = &origin.pairs.items[p.original_index];
                old.undone = j.undo;
                if (j.redo or j.kind == .move) old.fingerprint = p.fingerprint;
            };
            var all = true;
            for (origin.pairs.items) |p| if (p.completed and p.fingerprint != null and p.undone != j.undo) {
                all = false;
            };
            if (all) {
                if (j.undo) {
                    _ = self.undo_stack.pop();
                    self.redo_stack.append(a, origin) catch unreachable;
                } else {
                    _ = self.redo_stack.pop();
                    self.undo_stack.append(a, origin) catch unreachable;
                }
            }
            self.journal_origin = null;
            j.destroy();
        } else {
            if (successful > 0) {
                for (self.redo_stack.items) |old| old.destroy();
                self.redo_stack.clearRetainingCapacity();
            }
            const reversible = switch (j.kind) {
                .copy, .move, .mkdir, .document, .link => successful > 0,
                else => false,
            };
            if (reversible) {
                if (self.undo_stack.items.len >= 32) self.undo_stack.orderedRemove(0).destroy();
                self.undo_stack.append(a, j) catch unreachable;
            } else j.destroy();
        }
        self.owner.queueUpdate();
        self.owner.app.as(gio.Application).release();
    }
    pub fn undo(self: *Operations, redo: bool) void {
        if (self.busy) return;
        const stack = if (redo) &self.redo_stack else &self.undo_stack;
        if (stack.items.len == 0) return;
        const origin = stack.items[stack.items.len - 1];
        const job = engine.Job.create(if (redo) origin.kind else if (origin.kind == .move) .move else .delete);
        job.undo = !redo;
        job.redo = redo;
        var n = origin.pairs.items.len;
        while (n > 0) {
            n -= 1;
            const p = origin.pairs.items[n];
            if (!p.completed or p.fingerprint == null or p.undone != redo) continue;
            if (redo) job.add(p.source, p.destination) else job.add(p.destination.?, if (origin.kind == .move) p.source else null);
            const added = &job.pairs.items[job.pairs.items.len - 1];
            added.original_index = n;
            if (!redo or origin.kind == .move) added.expected = p.fingerprint;
        }
        if (job.pairs.items.len == 0) {
            job.destroy();
            return;
        }
        self.journal_origin = origin;
        self.start(job);
    }
    pub fn present(self: *Operations) void {
        if (!self.busy) {
            self.owner.message("File operations", self.result);
            return;
        }
        const j = self.active.?;
        const d = self.newDialog(if (self.conflict) "A file with this name already exists" else "File operations");
        if (self.conflict) {
            const p = j.pairs.items[j.index];
            const path = if (p.destination) |dest| dest.getParseName() else p.source.getParseName();
            defer glib.free(path);
            const label = u.label(path, null);
            label.setWrap(1);
            label.setWrapMode(.word_char);
            label.setMaxWidthChars(50);
            d.getContentArea().append(label.as(gtk.Widget));
            d.getContentArea().append(u.label("The existing item will be kept.", "secondary").as(gtk.Widget));
            _ = d.addButton("Cancel operation", -1);
            _ = d.addButton("Skip", 0);
            if (!j.undo and !j.redo) _ = d.addButton("Keep both", 2);
            d.setDefaultResponse(0);
        } else {
            const label = u.label("Working…", "secondary");
            self.progress_text = label;
            d.getContentArea().append(label.as(gtk.Widget));
            _ = d.addButton("Cancel operation", 0);
            _ = d.addButton("Keep working", 1);
        }
        _ = gtk.Dialog.signals.response.connect(d, *Operations, jobResponse, self, .{});
        d.as(gtk.Window).present();
        if (self.conflict) if (d.getWidgetForResponse(0)) |skip| {
            _ = skip.grabFocus();
        };
    }
    fn jobResponse(_: *gtk.Dialog, response: c_int, self: *Operations) callconv(.c) void {
        self.closeDialogs();
        const j = self.active orelse return;
        if (self.conflict) {
            if (response == 2) j.keepBoth() else if (response == 0) {
                j.pairs.items[j.index].skipped = true;
                j.index += 1;
            } else {
                j.cancelled = true;
                self.finish();
                return;
            }
            self.conflict = false;
            self.run();
        } else if (response != 1) j.cancel.cancel();
    }
};
