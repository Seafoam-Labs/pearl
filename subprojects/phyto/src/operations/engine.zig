//! Worker-only file operations. No GTK calls; all operands are owned GFiles.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const a = std.heap.c_allocator;
pub const Kind = enum { copy, move, trash, delete, mkdir, document, link, restore, empty_trash };
pub const Failure = error{ Io, Cancelled, Conflict, InvalidTarget, Changed, Unsupported, Limit };
const attrs = "standard::*,unix::mode,time::modified,time::modified-usec,etag::value,id::file,trash::*";
pub const Pair = struct {
    source: *gio.File,
    destination: ?*gio.File = null,
    expected: ?[32]u8 = null,
    completed: bool = false,
    undone: bool = false,
    original_index: usize = 0,
    skipped: bool = false,
    fingerprint: ?[32]u8 = null,
    pub fn deinit(self: *Pair) void {
        self.source.unref();
        if (self.destination) |f| f.unref();
    }
};
pub const Job = struct {
    kind: Kind,
    pairs: std.ArrayList(Pair) = .empty,
    cancel: *gio.Cancellable,
    index: usize = 0,
    error_message: ?[:0]u8 = null,
    failures: std.ArrayList(u8) = .empty,
    conflict: bool = false,
    cancelled: bool = false,
    undo: bool = false,
    redo: bool = false,
    cut: bool = false,
    clipboard_serial: u64 = 0,
    bytes: std.atomic.Value(u64) = .init(0),
    nodes: usize = 0,
    pub fn create(kind: Kind) *Job {
        const j = a.create(Job) catch unreachable;
        j.* = .{ .kind = kind, .cancel = gio.Cancellable.new() };
        return j;
    }
    pub fn add(self: *Job, source: *gio.File, dest: ?*gio.File) void {
        source.ref();
        if (dest) |d| d.ref();
        self.pairs.append(a, .{ .source = source, .destination = dest }) catch unreachable;
    }
    pub fn destroy(self: *Job) void {
        for (self.pairs.items) |*p| p.deinit();
        self.pairs.deinit(a);
        if (self.error_message) |m| a.free(m);
        self.failures.deinit(a);
        self.cancel.unref();
        a.destroy(self);
    }
    fn setError(self: *Job, msg: []const u8) void {
        if (self.error_message) |old| a.free(old);
        self.error_message = a.dupeZ(u8, msg) catch unreachable;
    }
    fn io(self: *Job, err: ?*glib.Error) Failure {
        if (err) |e| {
            defer e.free();
            self.setError(std.mem.span(e.f_message orelse "I/O error"));
            if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.exists)) != 0) return error.Conflict;
            if (e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.cancelled)) != 0) return error.Cancelled;
        }
        return error.Io;
    }
    fn check(self: *Job, depth: usize) Failure!void {
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        self.nodes += 1;
        if (depth > 128 or self.nodes > 1_000_000) return error.Limit;
    }
    pub fn run(self: *Job) void {
        self.conflict = false;
        while (self.index < self.pairs.items.len) : (self.index += 1) {
            const p = &self.pairs.items[self.index];
            self.perform(p) catch |err| {
                if (err == error.Conflict) {
                    self.conflict = true;
                    return;
                }
                if (err == error.Cancelled) {
                    self.cancelled = true;
                    return;
                }
                const uri = p.source.getParseName();
                defer glib.free(uri);
                const line = std.fmt.allocPrint(a, "{s}: {s}\n", .{ uri, self.error_message orelse @errorName(err) }) catch unreachable;
                defer a.free(line);
                self.failures.appendSlice(a, line) catch unreachable;
                continue;
            };
            p.completed = true;
            if (p.destination) |dest| p.fingerprint = self.digest(dest) catch null;
        }
    }
    fn perform(self: *Job, p: *Pair) Failure!void {
        if (self.error_message) |m| {
            a.free(m);
            self.error_message = null;
        }
        try self.check(0);
        if (p.expected) |expected| {
            const actual = try self.digest(p.source);
            if (!std.mem.eql(u8, &actual, &expected)) {
                self.setError("The item changed after the original operation. It was left untouched.");
                return error.Changed;
            }
        }
        if (self.kind == .restore and p.destination == null) {
            var e: ?*glib.Error = null;
            const info = p.source.queryInfo("trash::orig-path", .{}, self.cancel, &e) orelse return self.io(e);
            defer info.unref();
            const path = info.getAttributeByteString("trash::orig-path") orelse {
                self.setError("Original location is unavailable. Use Restore to… instead.");
                return error.Unsupported;
            };
            p.destination = gio.File.newForPath(path);
        }
        if (p.destination) |dest| {
            if (dest.equal(p.source) != 0 or dest.hasPrefix(p.source) != 0) {
                if (self.kind != .mkdir and self.kind != .document) {
                    self.setError("A folder cannot be copied or moved into itself.");
                    return error.InvalidTarget;
                }
            }
            // Also reject local aliases through a symlinked destination parent.
            if (self.kind == .copy or self.kind == .move) try self.checkLocalTarget(p.source, dest);
        }
        var err: ?*glib.Error = null;
        switch (self.kind) {
            .copy => try self.copyTree(p.source, p.destination.?, 0),
            .move, .restore => try self.moveTree(p.source, p.destination.?),
            .trash => if (p.source.trash(self.cancel, &err) == 0) {
                return self.io(err);
            },
            .empty_trash => {
                const entries = p.source.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const info = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer info.unref();
                    const f = p.source.getChild(info.getName());
                    defer f.unref();
                    try self.removeTree(f, 0, self.cancel);
                }
            },
            .delete => try self.removeTree(p.source, 0, self.cancel),
            .mkdir => if (p.destination.?.makeDirectory(self.cancel, &err) == 0) {
                return self.io(err);
            },
            .document => {
                const stream = p.destination.?.create(.{}, self.cancel, &err) orelse return self.io(err);
                defer stream.unref();
                if (stream.as(gio.OutputStream).close(self.cancel, &err) == 0) return self.io(err);
            },
            .link => {
                const path = p.source.getPath() orelse return error.Unsupported;
                defer glib.free(path);
                if (p.destination.?.makeSymbolicLink(path, self.cancel, &err) == 0) return self.io(err);
            },
        }
    }
    fn checkLocalTarget(self: *Job, src: *gio.File, dest: *gio.File) Failure!void {
        var err: ?*glib.Error = null;
        const info = src.queryInfo("standard::type", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        if (info.getFileType() != .directory) return;
        const src_path = src.getPath() orelse return;
        defer glib.free(src_path);
        const parent = dest.getParent() orelse return error.InvalidTarget;
        defer parent.unref();
        const parent_path = parent.getPath() orelse return;
        defer glib.free(parent_path);
        const real_src = realpath(src_path, null) orelse return;
        defer std.c.free(real_src);
        const real_parent = realpath(parent_path, null) orelse return;
        defer std.c.free(real_parent);
        const s = std.mem.span(real_src);
        const d = std.mem.span(real_parent);
        if (std.mem.eql(u8, s, d) or (std.mem.startsWith(u8, d, s) and d.len > s.len and d[s.len] == '/')) return error.InvalidTarget;
    }
    pub fn copyTree(self: *Job, src: *gio.File, dst: *gio.File, depth: usize) Failure!void {
        try self.check(depth);
        var err: ?*glib.Error = null;
        const info = src.queryInfo(attrs, .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        switch (info.getFileType()) {
            .directory => {
                if (dst.makeDirectory(self.cancel, &err) == 0) return self.io(err);
                errdefer self.removeTree(dst, 0, null) catch {};
                const entries = src.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const child = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer child.unref();
                    const from = src.getChild(child.getName());
                    defer from.unref();
                    const to = dst.getChild(child.getName());
                    defer to.unref();
                    try self.copyTree(from, to, depth + 1);
                }
                // Copy permissions/timestamps after children so read-only source directories work.
                try self.copyMetadata(info, dst);
            },
            .symbolic_link => {
                const target = info.getSymlinkTarget() orelse return error.Unsupported;
                if (dst.makeSymbolicLink(target, self.cancel, &err) == 0) return self.io(err);
            },
            .regular => {
                const input = src.read(self.cancel, &err) orelse return self.io(err);
                defer input.unref();
                const output = dst.create(.{ .private = true }, self.cancel, &err) orelse return self.io(err);
                defer output.unref();
                errdefer {
                    _ = output.as(gio.OutputStream).close(null, null);
                    _ = dst.delete(null, null);
                }
                var buffer: [128 * 1024]u8 = undefined;
                while (true) {
                    const n = input.as(gio.InputStream).read(&buffer, buffer.len, self.cancel, &err);
                    if (n < 0) return self.io(err);
                    if (n == 0) break;
                    if (output.as(gio.OutputStream).writeAll(&buffer, @intCast(n), null, self.cancel, &err) == 0) return self.io(err);
                    _ = self.bytes.fetchAdd(@intCast(n), .monotonic);
                }
                if (output.as(gio.OutputStream).close(self.cancel, &err) == 0) return self.io(err);
                try self.copyMetadata(info, dst);
            },
            else => return error.Unsupported,
        }
    }
    fn copyMetadata(self: *Job, source: *gio.FileInfo, dest: *gio.File) Failure!void {
        const attributes = gio.FileInfo.new();
        defer attributes.unref();
        if (source.hasAttribute("unix::mode") != 0) attributes.setAttributeUint32("unix::mode", source.getAttributeUint32("unix::mode") & 0o777);
        if (source.hasAttribute("time::modified") != 0) attributes.setAttributeUint64("time::modified", source.getAttributeUint64("time::modified"));
        if (source.hasAttribute("time::modified-usec") != 0) attributes.setAttributeUint32("time::modified-usec", source.getAttributeUint32("time::modified-usec"));
        var err: ?*glib.Error = null;
        if (dest.setAttributesFromInfo(attributes, .{ .nofollow_symlinks = true }, self.cancel, &err) == 0) return self.io(err);
    }
    pub fn removeTree(self: *Job, file: *gio.File, depth: usize, cancel: ?*gio.Cancellable) Failure!void {
        if (depth > 128) return error.Limit;
        var err: ?*glib.Error = null;
        const info = file.queryInfo("standard::type", .{ .nofollow_symlinks = true }, cancel, &err) orelse return self.io(err);
        defer info.unref();
        if (info.getFileType() == .directory) {
            const entries = file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, cancel, &err) orelse return self.io(err);
            defer entries.unref();
            while (true) {
                const child = entries.nextFile(cancel, &err) orelse {
                    if (err != null) return self.io(err);
                    break;
                };
                defer child.unref();
                const f = file.getChild(child.getName());
                defer f.unref();
                try self.removeTree(f, depth + 1, cancel);
            }
        }
        if (file.delete(cancel, &err) == 0) return self.io(err);
    }
    fn moveTree(self: *Job, src: *gio.File, dst: *gio.File) Failure!void {
        var err: ?*glib.Error = null;
        if (src.move(dst, .{ .nofollow_symlinks = true, .no_fallback_for_move = true }, self.cancel, null, null, &err) != 0) return;
        if (err) |e| {
            const fallback = e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.not_supported)) != 0 or e.matches(gio.ioErrorQuark(), @intFromEnum(gio.IOErrorEnum.would_recurse)) != 0;
            if (!fallback) return self.io(err);
            e.free();
            err = null;
        }
        const before = try self.contentDigest(src);
        try self.copyTree(src, dst, 0);
        // Source changes and cancellation leave the original intact. Keep the copy visible.
        const after = try self.contentDigest(src);
        const copied = try self.contentDigest(dst);
        if (!std.mem.eql(u8, &before, &after) or !std.mem.eql(u8, &after, &copied)) return error.Changed;
        try self.check(0);
        // Commit phase is non-cancellable: destination is complete and verified.
        try self.removeTree(src, 0, null);
    }
    pub fn digest(self: *Job, file: *gio.File) Failure![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashTree(file, &hash, 0, true);
        return hash.finalResult();
    }
    fn contentDigest(self: *Job, file: *gio.File) Failure![32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashTree(file, &hash, 0, false);
        return hash.finalResult();
    }
    fn hashTree(self: *Job, file: *gio.File, hash: *std.crypto.hash.sha2.Sha256, depth: usize, metadata: bool) Failure!void {
        try self.check(depth);
        var err: ?*glib.Error = null;
        const info = file.queryInfo(attrs, .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
        defer info.unref();
        hash.update(&.{@intCast(@intFromEnum(info.getFileType()))});
        // Undo also checks identity, mode and timestamp; transfer verification compares contents.
        if (metadata) {
            const mode = info.getAttributeUint32("unix::mode");
            const seconds = info.getAttributeUint64("time::modified");
            const micros = info.getAttributeUint32("time::modified-usec");
            hash.update(std.mem.asBytes(&mode));
            hash.update(std.mem.asBytes(&seconds));
            hash.update(std.mem.asBytes(&micros));
            hash.update(std.mem.span(info.getAttributeString("id::file") orelse ""));
            hash.update(&.{0});
        }
        if (info.getFileType() == .regular) {
            const size = info.getSize();
            hash.update(std.mem.asBytes(&size));
        }
        switch (info.getFileType()) {
            .directory => {
                var names: std.ArrayList([:0]u8) = .empty;
                defer {
                    for (names.items) |n| a.free(n);
                    names.deinit(a);
                }
                const entries = file.enumerateChildren("standard::name", .{ .nofollow_symlinks = true }, self.cancel, &err) orelse return self.io(err);
                defer entries.unref();
                while (true) {
                    const child = entries.nextFile(self.cancel, &err) orelse {
                        if (err != null) return self.io(err);
                        break;
                    };
                    defer child.unref();
                    if (names.items.len >= 100_000) return error.Limit;
                    names.append(a, a.dupeZ(u8, std.mem.span(child.getName())) catch unreachable) catch unreachable;
                }
                std.mem.sort([:0]u8, names.items, {}, struct {
                    fn less(_: void, x: [:0]u8, y: [:0]u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.less);
                for (names.items) |n| {
                    hash.update(n);
                    hash.update(&.{0});
                    const child = file.getChild(n);
                    defer child.unref();
                    try self.hashTree(child, hash, depth + 1, metadata);
                }
            },
            .symbolic_link => hash.update(std.mem.span(info.getSymlinkTarget() orelse "")),
            .regular => {
                const input = file.read(self.cancel, &err) orelse return self.io(err);
                defer input.unref();
                var buf: [64 * 1024]u8 = undefined;
                while (true) {
                    const n = input.as(gio.InputStream).read(&buf, buf.len, self.cancel, &err);
                    if (n < 0) return self.io(err);
                    if (n == 0) break;
                    hash.update(buf[0..@intCast(n)]);
                }
            },
            else => return error.Unsupported,
        }
        hash.update(&.{0xff});
    }
    pub fn keepBoth(self: *Job) void {
        const p = &self.pairs.items[self.index];
        const old = p.destination orelse return;
        const parent = old.getParent() orelse return;
        defer parent.unref();
        const basename = old.getBasename() orelse return;
        defer glib.free(basename);
        const id = glib.uuidStringRandom();
        defer glib.free(id);
        const name = std.fmt.allocPrintSentinel(a, "{s} (copy {s})", .{ basename, std.mem.span(id)[0..8] }, 0) catch unreachable;
        defer a.free(name);
        p.destination = parent.getChild(name);
        old.unref();
    }
};
extern "c" fn realpath([*:0]const u8, ?[*]u8) ?[*:0]u8;

const Fixture = struct {
    root: *gio.File,
    path: [*:0]u8,
    fn init() Fixture {
        const path = glib.Dir.makeTmp("phyto-engine-XXXXXX", null) orelse unreachable;
        return .{ .root = gio.File.newForPath(path), .path = path };
    }
    fn deinit(self: *Fixture) void {
        const cleaner = Job.create(.delete);
        defer cleaner.destroy();
        cleaner.removeTree(self.root, 0, null) catch {};
        self.root.unref();
        glib.free(self.path);
    }
    fn child(self: *Fixture, name: [*:0]const u8) *gio.File {
        return self.root.getChild(name);
    }
};
fn writeFixture(file: *gio.File, value: []const u8) void {
    std.debug.assert(file.replaceContents(value.ptr, value.len, null, 0, .{}, null, null, null) != 0);
}
test "recursive copy preserves bytes, symlink identity and existing destinations" {
    var f = Fixture.init();
    defer f.deinit();
    const source = f.child("source");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const nested = source.getChild("nested");
    defer nested.unref();
    try std.testing.expect(nested.makeDirectory(null, null) != 0);
    const content = nested.getChild("spaces ü\n-file");
    defer content.unref();
    writeFixture(content, "untouched source bytes");
    const link = source.getChild("loop");
    defer link.unref();
    try std.testing.expect(link.makeSymbolicLink(".", null, null) != 0);
    const dest = f.child("copy");
    defer dest.unref();
    const job = Job.create(.copy);
    defer job.destroy();
    job.add(source, dest);
    job.run();
    if (!job.pairs.items[0].completed) std.debug.print("Copy failure: {s} conflict={any}\n", .{ job.failures.items, job.conflict });
    try std.testing.expect(job.pairs.items[0].completed);
    const before = try job.contentDigest(source);
    const after = try job.contentDigest(dest);
    try std.testing.expectEqualSlices(u8, &before, &after);
    const again = Job.create(.copy);
    defer again.destroy();
    again.add(source, dest);
    again.run();
    try std.testing.expect(again.conflict);
    const unchanged = try job.contentDigest(dest);
    try std.testing.expectEqualSlices(u8, &before, &unchanged);
}
test "cancelled batches and invalid descendant targets retain sources" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("src");
    defer src.unref();
    writeFixture(src, "keep");
    const dest = f.child("dest");
    defer dest.unref();
    const cancelled = Job.create(.move);
    defer cancelled.destroy();
    cancelled.add(src, dest);
    cancelled.cancel.cancel();
    cancelled.run();
    try std.testing.expect(cancelled.cancelled);
    try std.testing.expect(src.queryExists(null) != 0);
    try std.testing.expect(dest.queryExists(null) == 0);
    const folder = f.child("folder");
    defer folder.unref();
    _ = folder.makeDirectory(null, null);
    const child = folder.getChild("inside");
    defer child.unref();
    const invalid = Job.create(.copy);
    defer invalid.destroy();
    invalid.add(folder, child);
    invalid.run();
    try std.testing.expect(invalid.failures.items.len > 0);
    try std.testing.expect(child.queryExists(null) == 0);
}
test "undo fingerprint rejects externally changed files and batch failures do not lose siblings" {
    var f = Fixture.init();
    defer f.deinit();
    const src = f.child("src");
    defer src.unref();
    writeFixture(src, "original");
    const dest = f.child("dest");
    defer dest.unref();
    const j = Job.create(.copy);
    defer j.destroy();
    j.add(src, dest);
    j.run();
    if (!j.pairs.items[0].completed) std.debug.print("Copy failure: {s} conflict={any}\n", .{ j.failures.items, j.conflict });
    const undo = Job.create(.delete);
    defer undo.destroy();
    undo.add(dest, null);
    undo.pairs.items[0].expected = j.pairs.items[0].fingerprint;
    writeFixture(dest, "new external content");
    undo.run();
    try std.testing.expect(!undo.pairs.items[0].completed);
    try std.testing.expect(dest.queryExists(null) != 0);
    const absent = f.child("absent");
    defer absent.unref();
    const one = f.child("one");
    defer one.unref();
    const two = f.child("two");
    defer two.unref();
    const batch = Job.create(.copy);
    defer batch.destroy();
    batch.add(absent, one);
    batch.add(src, two);
    batch.run();
    try std.testing.expect(batch.failures.items.len > 0);
    try std.testing.expect(batch.pairs.items[1].completed);
    try std.testing.expect(src.queryExists(null) != 0);
}

test "cross-filesystem moves verify a complete directory before source removal" {
    // /tmp and the project filesystem are distinct in the native qualification environment.
    var f = Fixture.init();
    defer f.deinit();
    const cwd = glib.getCurrentDir();
    defer glib.free(cwd);
    const id = glib.uuidStringRandom();
    defer glib.free(id);
    const path = std.fmt.allocPrintSentinel(a, "{s}/.phyto-engine-{s}", .{ cwd, id }, 0) catch unreachable;
    defer a.free(path);
    const destination = gio.File.newForPath(path);
    defer destination.unref();
    const cleaner = Job.create(.delete);
    defer {
        cleaner.removeTree(destination, 0, null) catch {};
        cleaner.destroy();
    }
    const source = f.child("move-directory");
    defer source.unref();
    try std.testing.expect(source.makeDirectory(null, null) != 0);
    const item = source.getChild("bytes");
    defer item.unref();
    writeFixture(item, "different filesystem content");
    const link = source.getChild("link");
    defer link.unref();
    try std.testing.expect(link.makeSymbolicLink("bytes", null, null) != 0);
    const move = Job.create(.move);
    defer move.destroy();
    const expected = try move.contentDigest(source);
    move.add(source, destination);
    move.run();
    try std.testing.expect(move.pairs.items[0].completed);
    try std.testing.expect(source.queryExists(null) == 0);
    const actual = try move.contentDigest(destination);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
