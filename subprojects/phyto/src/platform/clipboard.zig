const std = @import("std");
const u = @import("../ui.zig");
const gdk = @import("gdk4");
const gio = u.gio;
const glib = u.glib;
const a = u.a;
const Window = @import("../window.zig").Window;
pub const Clipboard = struct {
    owner: *Window,
    native: *gdk.Clipboard,
    signal: c_ulong = 0,
    serial: u64 = 0,
    files: std.ArrayList(*gio.File) = .empty,
    cut: bool = false,
    loading: bool = false,
    stopped: bool = false,
    cancel: ?*gio.Cancellable = null,
    pub fn init(owner: *Window) Clipboard {
        return .{ .owner = owner, .native = gdk.Display.getDefault().?.getClipboard() };
    }
    pub fn start(self: *Clipboard) void {
        self.signal = gdk.Clipboard.signals.changed.connect(self.native, *Clipboard, changed, self, .{});
        self.reload();
    }
    pub fn stop(self: *Clipboard) void {
        if (self.stopped) return;
        self.stopped = true;
        if (self.signal != 0) u.object.signalHandlerDisconnect(self.native.as(u.object.Object), self.signal);
        if (self.cancel) |c| c.cancel();
    }
    pub fn deinit(self: *Clipboard) void {
        self.stop();
        self.clear();
        if (self.cancel) |c| c.unref();
    }
    fn clear(self: *Clipboard) void {
        for (self.files.items) |f| f.unref();
        self.files.clearAndFree(a);
        self.cut = false;
    }
    pub fn available(self: *Clipboard) bool {
        return !self.loading and self.files.items.len > 0;
    }
    fn changed(_: *gdk.Clipboard, self: *Clipboard) callconv(.c) void {
        self.reload();
    }
    fn reload(self: *Clipboard) void {
        if (self.stopped) return;
        self.serial +%= 1;
        self.clear();
        if (self.cancel) |c| {
            c.cancel();
            c.unref();
        }
        self.cancel = gio.Cancellable.new();
        const formats = self.native.getFormats();
        if (formats.containMimeType("x-special/gnome-copied-files") == 0 and formats.containMimeType("text/uri-list") == 0) {
            self.loading = false;
            self.owner.queueUpdate();
            return;
        }
        self.loading = true;
        const r = a.create(Read) catch unreachable;
        self.cancel.?.ref();
        r.* = .{ .owner = self, .serial = self.serial, .cancel = self.cancel.? };
        self.owner.app.as(gio.Application).hold();
        const types = [_:null]?[*:0]const u8{ "x-special/gnome-copied-files", "text/uri-list" };
        self.native.readAsync(@ptrCast(@constCast(&types)), 0, r.cancel, ready, r);
    }
    const Read = struct { owner: *Clipboard, serial: u64, cancel: *gio.Cancellable, stream: ?*gio.InputStream = null, special: bool = false, bytes: std.ArrayList(u8) = .empty };
    fn done(r: *Read, success: bool) void {
        const self = r.owner;
        if (!self.stopped and r.serial == self.serial) {
            self.loading = false;
            if (success) self.parse(r.bytes.items, r.special);
            self.owner.queueUpdate();
        }
        if (r.stream) |s| s.unref();
        r.cancel.unref();
        r.bytes.deinit(a);
        self.owner.app.as(gio.Application).release();
        a.destroy(r);
    }
    fn ready(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        var mime: [*:0]const u8 = "";
        r.stream = r.owner.native.readFinish(result, &mime, &err);
        if (err) |e| e.free();
        if (r.stream == null) {
            done(r, false);
            return;
        }
        r.special = std.mem.eql(u8, std.mem.span(mime), "x-special/gnome-copied-files");
        r.stream.?.readBytesAsync(65536, 0, r.cancel, chunk, r);
    }
    fn chunk(_: ?*u.object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const r: *Read = @ptrCast(@alignCast(data.?));
        var err: ?*glib.Error = null;
        const bytes = r.stream.?.readBytesFinish(result, &err);
        if (err) |e| e.free();
        const b = bytes orelse {
            done(r, false);
            return;
        };
        defer b.unref();
        var n: usize = 0;
        const ptr = b.getData(&n);
        if (n == 0) {
            done(r, true);
            return;
        }
        if (r.bytes.items.len + n > 4 * 1024 * 1024) {
            done(r, false);
            return;
        }
        const p: [*]const u8 = @ptrCast(ptr.?);
        r.bytes.appendSlice(a, p[0..n]) catch unreachable;
        r.stream.?.readBytesAsync(65536, 0, r.cancel, chunk, r);
    }
    fn parse(self: *Clipboard, payload: []const u8, special: bool) void {
        var lines = std.mem.splitScalar(u8, payload, '\n');
        if (special) {
            const verb = std.mem.trim(u8, lines.next() orelse return, "\r");
            if (!std.mem.eql(u8, verb, "copy") and !std.mem.eql(u8, verb, "cut")) return;
            self.cut = std.mem.eql(u8, verb, "cut");
        }
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (self.files.items.len >= 4096 or std.mem.indexOfScalar(u8, line, 0) != null or std.mem.indexOfScalar(u8, line, ':') == null) {
                self.clear();
                return;
            }
            const uri = a.dupeZ(u8, line) catch unreachable;
            defer a.free(uri);
            const f = gio.File.newForUri(uri);
            var duplicate = false;
            for (self.files.items) |old| {
                if (old.equal(f) != 0) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) f.unref() else self.files.append(a, f) catch unreachable;
        }
    }
    pub fn write(self: *Clipboard, files: []const *gio.File, cut: bool) void {
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(a);
        var special: std.ArrayList(u8) = .empty;
        defer special.deinit(a);
        special.appendSlice(a, if (cut) "cut\n" else "copy\n") catch unreachable;
        for (files) |f| {
            const uri = f.getUri();
            defer glib.free(uri);
            plain.appendSlice(a, std.mem.span(uri)) catch unreachable;
            plain.appendSlice(a, "\r\n") catch unreachable;
            special.appendSlice(a, std.mem.span(uri)) catch unreachable;
            special.append(a, '\n') catch unreachable;
        }
        const pbytes = glib.Bytes.new(plain.items.ptr, plain.items.len);
        defer pbytes.unref();
        const sbytes = glib.Bytes.new(special.items.ptr, special.items.len);
        defer sbytes.unref();
        var providers = [_]*gdk.ContentProvider{ gdk.ContentProvider.newForBytes("x-special/gnome-copied-files", sbytes), gdk.ContentProvider.newForBytes("text/uri-list", pbytes) };
        const provider = gdk.ContentProvider.newUnion(&providers, providers.len);
        defer provider.unref();
        _ = self.native.setContent(provider);
        // The changed signal initiates a real clipboard read, including our own payload.
    }
    pub fn remaining(self: *Clipboard, job: *@import("../operations/engine.zig").Job) void {
        if (!job.cut or self.serial != job.clipboard_serial) return;
        var rest: std.ArrayList(*gio.File) = .empty;
        defer rest.deinit(a);
        for (job.pairs.items) |p| if (!p.completed) {
            rest.append(a, p.source) catch unreachable;
        };
        self.write(rest.items, true);
    }
};
