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
const io_priority = @import("platform/io_priority.zig");
const notify = @import("platform/notifications.zig");
const log = std.log.scoped(.platform);
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
    reporter: notify.Reporter,
    pub fn init(owner: *Window) Operations {
        return .{
            .owner = owner,
            .result = a.dupeSentinel(u8, "No file operations are running.", 0) catch unreachable,
            .reporter = notify.Reporter.init(@ptrCast(&owner.operations), notifyAction),
        };
    }
    pub fn deinit(self: *Operations) void {
        self.reporter.deinit();
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
        d.as(gtk.Widget).addCssClass(@import("appearance.zig").themeClass());
        d.getContentArea().as(gtk.Widget).addCssClass("dialog-body");
        if (@import("build_options").test_hooks) {
            // Same inspection hook as the connection editor, so the native suite
            // can read and click the collision choices while the dialog is modal.
            const keys = gtk.EventControllerKey.new();
            _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Window, Window.keyPressed, self.owner, .{});
            d.as(gtk.Widget).addController(keys.as(gtk.EventController));
        }
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
            self.error_label.?.setText(@import("i18n").dtr("phyto", "Enter a name without /; . and .. are not allowed."));
            return;
        }
        const name_ = a.dupeSentinel(u8, std.mem.span(raw), 0) catch unreachable;
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
        j.self_duplicate = true;
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
        j.self_duplicate = true;
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
        var summary_buf: [512]u8 = undefined;
        if (reportable(j)) self.reporter.begin(summaryFor(j, &summary_buf), "Starting…", -1);
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
        // Yield storage bandwidth to interactive I/O while the transfer runs, then
        // leave the shared pool thread's priority as it was (issue #124).
        const saved = io_priority.lower();
        defer io_priority.restore(saved);
        j.run();
        task.returnBoolean(1);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        if (!self.busy) return 0;
        const j = self.active.?;
        if (self.progress_text) |label| {
            const size = glib.formatSize(j.bytes.load(.monotonic));
            defer glib.free(size);
            label.setText(size);
        }
        var summary_buf: [512]u8 = undefined;
        var body_buf: [160]u8 = undefined;
        // While a collision pauses the batch, the card keeps the "waiting for a
        // decision" body the conflict handler sent; ticks must not overwrite it.
        if (!self.conflict) self.reporter.update(summaryFor(j, &summary_buf), progressBody(j, &body_buf), progressFor(j), false);
        return 1;
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Operations = @ptrCast(@alignCast(data.?));
        const j = self.active.?;
        if (j.conflict) {
            self.conflict = true;
            var summary_buf: [512]u8 = undefined;
            self.reporter.update(summaryFor(j, &summary_buf), "Waiting for a decision…", progressFor(j), true);
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
        var replaced: usize = 0;
        for (j.pairs.items) |p| {
            if (p.completed) successful += 1;
            if (p.skipped) skipped += 1;
            if (p.replaced) replaced += 1;
        }
        // One batch-level line at the operation boundary. The payload carries
        // only the kind, the category and aggregate counts, so a large copy
        // cannot flood the journal and no path or content reaches it.
        const result = engine.outcome(j.cancelled, successful, skipped, j.failed);
        var payload: [128]u8 = undefined;
        const text = engine.eventPayload(&payload, j.kind, result, successful, skipped, j.failed);
        switch (result) {
            .partial, .failed => log.warn("event=operation-finished {s}", .{text}),
            .cancelled, .conflict => log.info("event=operation-finished {s}", .{text}),
            .ok => log.debug("event=operation-finished {s}", .{text}),
        }
        a.free(self.result);
        // A replaced item is recoverable from Trash, not from undo: undo removes
        // the new item, so the receipt says where the previous one went.
        const replaced_note: [:0]const u8 = if (replaced > 0) u.format(" · {d} replaced (previous items are in Trash)", .{replaced}) else "";
        defer if (replaced > 0) a.free(replaced_note);
        self.result = u.format("{d} completed · {d} skipped{s}{s}{s}", .{ successful, skipped, replaced_note, if (j.cancelled) " · Cancelled" else "", if (j.failures.items.len != 0) " · Some items failed" else "" });
        self.owner.setStatus(self.result);
        var final_buf: [512]u8 = undefined;
        const transferred = j.bytes.load(.monotonic);
        if (transferred > 0) {
            const size = glib.formatSize(transferred);
            defer glib.free(size);
            const body = u.format("{s} · {s}", .{ self.result, std.mem.span(size) });
            defer a.free(body);
            self.reporter.complete(finalSummary(j, result, &final_buf), body);
        } else self.reporter.complete(finalSummary(j, result, &final_buf), self.result);
        self.owner.clipboard.remaining(j);
        var relocated = false;
        if (j.kind == .move or j.kind == .restore) for (j.pairs.items) |p| {
            if (p.completed and p.destination != null) relocated = self.owner.preferences.relocated(p.source, p.destination.?) or relocated;
        };
        if (relocated) self.owner.refreshPlaces();
        if (j.failures.items.len > 0) {
            const msg = a.dupeSentinel(u8, j.failures.items, 0) catch unreachable;
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
        const d = self.newDialog(if (self.conflict) @import("i18n").dtr("phyto", "A file with this name already exists") else @import("i18n").dtr("phyto", "File operations"));
        if (self.conflict) {
            const p = j.pairs.items[j.index.load(.monotonic)];
            const path = if (p.destination) |dest| dest.getParseName() else p.source.getParseName();
            defer glib.free(path);
            const label = u.label(path, null);
            label.setWrap(1);
            label.setWrapMode(.word_char);
            label.setMaxWidthChars(50);
            d.getContentArea().append(label.as(gtk.Widget));
            d.getContentArea().append(u.label(@import("i18n").dtr("phyto", "The existing item will be kept."), "secondary").as(gtk.Widget));
            // Replace is a transfer decision, never an undo/redo repair, and it
            // needs a Trash the existing item can actually go to.
            const transfer_kind = !j.undo and !j.redo and (j.kind == .copy or j.kind == .move or j.kind == .restore);
            const replaceable = transfer_kind and (!j.conflict_info.known or j.conflict_info.can_trash);
            if (replaceable) {
                const note = if (j.conflict_info.directory)
                    @import("i18n").dtr("phyto", "Replace moves the existing folder and everything in it to Trash first.")
                else
                    @import("i18n").dtr("phyto", "Replace moves the existing item to Trash first, so you can restore it.");
                d.getContentArea().append(u.label(note, "secondary").as(gtk.Widget));
            } else if (transfer_kind) {
                d.getContentArea().append(u.label(@import("i18n").dtr("phyto", "Replace is unavailable because the existing item cannot be moved to Trash here."), "secondary").as(gtk.Widget));
            }
            _ = d.addButton("Cancel operation", -1);
            _ = d.addButton("Skip", 0);
            if (replaceable) d.addButton("Replace", 3).addCssClass("destructive-action");
            if (!j.undo and !j.redo) _ = d.addButton("Keep both", 2);
            d.setDefaultResponse(0);
        } else {
            const label = u.label(@import("i18n").dtr("phyto", "Working…"), "secondary");
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
            if (response == 2) j.keepBoth() else if (response == 3) j.replace() else if (response == 0) {
                j.pairs.items[j.index.load(.monotonic)].skipped = true;
                j.index.store(j.index.load(.monotonic) + 1, .monotonic);
            } else {
                j.cancelled = true;
                self.finish();
                return;
            }
            self.conflict = false;
            self.run();
        } else if (response != 1) j.cancel.cancel();
    }
    /// Notification action route: Cancel stops the batch exactly like the
    /// dialog button; the reserved card click presents the originating window.
    fn notifyAction(context: *anyopaque, id: u32, key: []const u8) void {
        const self: *Operations = @ptrCast(@alignCast(context));
        if (id == 0 or id != self.reporter.id) return;
        if (std.mem.eql(u8, key, "cancel")) {
            const j = self.active orelse return;
            if (self.conflict) {
                self.conflict = false;
                j.cancelled = true;
                self.closeDialogs();
                self.finish();
            } else j.cancel.cancel();
        } else if (std.mem.eql(u8, key, "default")) {
            self.owner.window.present();
        }
    }
};

/// Phase 1 reports transfers only: copy/move/restore batches and their
/// undo/redo. Trash/delete coverage is a later phase; other kinds stay inert.
fn reportable(j: *engine.Job) bool {
    return j.undo or j.redo or j.kind == .copy or j.kind == .move or j.kind == .restore;
}

/// User-facing batch label. Single items name the file; batches count top-level
/// items. Undo/redo batches say so, matching the journal's vocabulary.
fn summaryFor(j: *engine.Job, buf: []u8) []const u8 {    const gerund = switch (j.kind) {
        .copy => "Copying",
        .move => "Moving",
        .restore => "Restoring",
        else => "Working on",
    };
    const noun = switch (j.kind) {
        .copy => "copy",
        .move => "move",
        .restore => "restore",
        else => "operation",
    };
    const n = j.pairs.items.len;
    var name_buf: [256]u8 = undefined;
    const name: []const u8 = if (n == 1) blk: {
        const base = j.pairs.items[0].source.getBasename() orelse break :blk "item";
        defer glib.free(base);
        break :blk std.fmt.bufPrint(&name_buf, "{s}", .{std.mem.span(base)}) catch "item";
    } else "";
    if (j.undo or j.redo) {
        const verb = if (j.undo) "Undoing" else "Redoing";
        return if (n == 1)
            std.fmt.bufPrint(buf, "{s} {s} of {s}", .{ verb, noun, name }) catch "Working…"
        else
            std.fmt.bufPrint(buf, "{s} {s} of {d} items", .{ verb, noun, n }) catch "Working…";
    }
    return if (n == 1)
        std.fmt.bufPrint(buf, "{s} {s}", .{ gerund, name }) catch "Working…"
    else
        std.fmt.bufPrint(buf, "{s} {d} items", .{ gerund, n }) catch "Working…";
}

/// The bar's fraction: bytes over a measured single-file total, completed
/// top-level items for a batch, indeterminate when neither is known.
fn progressFor(j: *engine.Job) ?f64 {
    const total = j.total_bytes.load(.monotonic);
    if (total != std.math.maxInt(u64)) {
        if (total == 0) return 1;
        const bytes = j.bytes.load(.monotonic);
        return @min(1, @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(total)));
    }
    const n = j.pairs.items.len;
    if (n > 1) {
        const done = j.index.load(.monotonic);
        return @min(1, @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(n)));
    }
    return -1;
}

/// Live byte count, plus the top-level item position for batches.
fn progressBody(j: *engine.Job, buf: []u8) []const u8 {
    const size = glib.formatSize(j.bytes.load(.monotonic));
    defer glib.free(size);
    const n = j.pairs.items.len;
    if (n > 1) {
        const item = @min(n, j.index.load(.monotonic) + 1);
        return std.fmt.bufPrint(buf, "{s} · item {d} of {d}", .{ std.mem.span(size), item, n }) catch "Working…";
    }
    return std.fmt.bufPrint(buf, "{s}", .{std.mem.span(size)}) catch "Working…";
}

fn finalSummary(j: *engine.Job, result: engine.Outcome, buf: []u8) []const u8 {
    const state = switch (result) {
        .ok => "complete",
        .cancelled => "cancelled",
        else => "finished with errors",
    };
    if (j.undo) return std.fmt.bufPrint(buf, "Undo {s}", .{state}) catch "Undo finished";
    if (j.redo) return std.fmt.bufPrint(buf, "Redo {s}", .{state}) catch "Redo finished";
    if (result == .partial or result == .failed) return "Some items failed";
    const noun = switch (j.kind) {
        .copy => "Copy",
        .move => "Move",
        .restore => "Restore",
        else => "Operation",
    };
    return std.fmt.bufPrint(buf, "{s} {s}", .{ noun, state }) catch "Operation finished";
}
