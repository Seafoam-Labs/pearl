//! Private, display-independent helper. No GTK initialization or shell commands.
const std = @import("std");
const glib = @import("glib2");
const gio = @import("gio2");
const pix = @import("gdkpixbuf2");
const policy = @import("core/preview.zig");
const a = std.heap.c_allocator;
extern "c" fn alarm(c_uint) c_uint;
extern "c" fn umask(c_uint) c_uint;

fn output(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(1, bytes.ptr + offset, bytes.len - offset);
        if (n <= 0) std.process.exit(1);
        offset += @intCast(n);
    }
}
fn unavailable(message: []const u8) void {
    output(&policy.header(.unavailable, 0, 0));
    output(message);
}
fn fmt(comptime format: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, format, args, 0) catch std.process.exit(1);
}
fn stat(fd: c_int, st: *std.os.linux.Statx) c_int {
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, std.os.linux.STATX.BASIC_STATS, st) != 0) return -1;
    return if (st.mask.TYPE and st.mask.MTIME and st.mask.CTIME and st.mask.SIZE and st.mask.INO) 0 else -1;
}
fn same(l: std.os.linux.Statx, r: std.os.linux.Statx) bool {
    return l.ino == r.ino and l.dev_major == r.dev_major and l.dev_minor == r.dev_minor and l.size == r.size and l.mtime.sec == r.mtime.sec and l.mtime.nsec == r.mtime.nsec and l.ctime.sec == r.ctime.sec and l.ctime.nsec == r.ctime.nsec;
}
fn unchanged(fd: c_int, path: [*:0]const u8, before: std.os.linux.Statx) bool {
    var opened: std.os.linux.Statx = undefined;
    var named: std.os.linux.Statx = undefined;
    return stat(fd, &opened) == 0 and same(before, opened) and
        std.c.statx(std.os.linux.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, std.os.linux.STATX.BASIC_STATS, &named) == 0 and
        same(before, named);
}
const Decoder = struct {
    edge: c_int,
    rejected: bool = false,
    fn size(loader: *pix.PixbufLoader, w: c_int, h: c_int, self: *Decoder) callconv(.c) void {
        if (w <= 0 or h <= 0 or @as(i64, w) * h > 64_000_000) {
            self.rejected = true;
            loader.setSize(1, 1);
            return;
        }
        const longest = @max(w, h);
        if (longest > self.edge) loader.setSize(@intCast(@max(1, @divTrunc(@as(i64, w) * self.edge, longest))), @intCast(@max(1, @divTrunc(@as(i64, h) * self.edge, longest))));
    }
};
var corrupt_input: bool = false;
fn decode(fd: c_int, kind: [*:0]const u8, edge: u32, limit: usize) ?*pix.Pixbuf {
    var decode_error: ?*glib.Error = null;
    defer if (decode_error) |e| {
        corrupt_input = e.matches(pix.PixbufError.quark(), @intFromEnum(pix.PixbufError.corrupt_image)) != 0;
        glib.printerr("Preview decoder: %s\n", e.f_message orelse "failed");
        e.free();
    };
    const loader = pix.PixbufLoader.newWithType(kind, &decode_error) orelse return null;
    defer loader.unref();
    var sizing = Decoder{ .edge = @intCast(edge) };
    _ = pix.PixbufLoader.signals.size_prepared.connect(loader, *Decoder, Decoder.size, &sizing, .{});
    var bytes: [16384]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = std.c.read(fd, &bytes, bytes.len);
        if (n < 0) {
            _ = loader.close(null);
            return null;
        }
        if (n == 0) break;
        total += @intCast(n);
        if (total > limit or loader.write(&bytes, @intCast(n), &decode_error) == 0 or sizing.rejected) {
            _ = loader.close(null);
            return null;
        }
    }
    if (loader.close(&decode_error) == 0) return null;
    const decoded = loader.getPixbuf() orelse return null;
    return decoded.applyEmbeddedOrientation();
}
fn imageOutput(p: *pix.Pixbuf) void {
    const w: usize = @intCast(p.getWidth());
    const h: usize = @intCast(p.getHeight());
    if (w == 0 or h == 0 or w > policy.max_edge or h > policy.max_edge) return unavailable("Image exceeds preview limits.");
    const channels: usize = @intCast(p.getNChannels());
    if ((channels != 3 and channels != 4) or p.getBitsPerSample() != 8) return unavailable("Unsupported image layout.");
    output(&policy.header(.image, @intCast(w), @intCast(h)));
    const pixels = p.getPixels();
    const stride: usize = @intCast(p.getRowstride());
    var row: [policy.max_edge * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            @memcpy(row[x * 4 ..][0..3], pixels[y * stride + x * channels ..][0..3]);
            row[x * 4 + 3] = if (channels == 4) pixels[y * stride + x * channels + 3] else 255;
        }
        output(row[0 .. w * 4]);
    }
}
fn signature(bytes: []const u8) ?[:0]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "webp";
    return null;
}
fn validOption(p: *pix.Pixbuf, key: [*:0]const u8, value: []const u8) bool {
    return if (p.getOption(key)) |v| std.mem.eql(u8, std.mem.span(v), value) else false;
}

fn save(p: *pix.Pixbuf, cache_root: [:0]const u8, class: []const u8, uri: [*:0]const u8, mtime: [:0]const u8, source_size: [:0]const u8, nanos: [:0]const u8) void {
    var png: [*]u8 = undefined;
    var len: usize = 0;
    var save_error: ?*glib.Error = null;
    defer if (save_error) |e| {
        glib.printerr("Preview cache: %s\n", e.f_message orelse "failed");
        e.free();
    };
    if (p.saveToBuffer(&png, &len, "png", @ptrCast(&save_error), @as([*:0]const u8, "tEXt::Thumb::URI"), uri, @as([*:0]const u8, "tEXt::Thumb::MTime"), mtime.ptr, @as([*:0]const u8, "tEXt::Thumb::Size"), source_size.ptr, @as([*:0]const u8, "tEXt::Phyto::MTimeNS"), nanos.ptr, @as([*:0]const u8, "tEXt::Software"), @as([*:0]const u8, "Phyto"), @as(?[*:0]const u8, null)) != 0) {
        defer glib.free(png);
        const relative = fmt("{s}/{s}.png", .{ class, policy.cacheName(std.mem.span(uri)) });
        defer a.free(relative);
        @import("platform/thumbnail_cache.zig").save(cache_root, relative, png[0..len]);
    }
}
fn failureCache(path: [:0]const u8, uri: [*:0]const u8, mtime: []const u8, size: []const u8, nanos: []const u8) bool {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (stat(fd, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG or st.size > 16384) return false;
    const p = decode(fd, "png", 1, 16384) orelse return false;
    defer p.unref();
    return validOption(p, "tEXt::Thumb::URI", std.mem.span(uri)) and validOption(p, "tEXt::Thumb::MTime", mtime) and validOption(p, "tEXt::Thumb::Size", size) and validOption(p, "tEXt::Phyto::MTimeNS", nanos);
}

// args: URI, edge, encoded limit, text allowed, cache allowed, expected seconds,
// expected microseconds, expected size. Values are passed as argv, never a shell.
pub fn run(args: []const [:0]const u8) void {
    if (args.len != 8) std.process.exit(2);
    // This helper accepts native files only; avoid session GVfs activation.
    _ = glib.setenv("GIO_USE_VFS", "local", 1);
    if (std.c.setrlimit(.AS, &.{ .cur = 512 * 1024 * 1024, .max = 512 * 1024 * 1024 }) != 0) std.process.exit(2);
    _ = std.c.setrlimit(.CORE, &.{ .cur = 0, .max = 0 });
    _ = alarm(10);
    _ = umask(0o077);
    if (@import("build_options").test_hooks) if (glib.getenv("PHYTO_TEST_PREVIEW_DELAY_MS")) |delay| {
        const ms = std.fmt.parseInt(u32, std.mem.span(delay), 10) catch 0;
        glib.usleep(@as(c_ulong, @min(ms, 15000)) * 1000);
    };
    const edge = std.fmt.parseInt(u32, args[1], 10) catch return;
    if (edge == 0 or edge > policy.max_edge) return;
    const limit = @min(policy.source_limit, std.fmt.parseInt(usize, args[2], 10) catch return);
    const file = gio.File.newForUri(args[0]);
    defer file.unref();
    const path = file.getPath() orelse return unavailable("Preview is available for local files only.");
    defer glib.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return unavailable("File is unreadable or has been removed.");
    defer _ = std.c.close(fd);
    var before: std.os.linux.Statx = undefined;
    if (stat(fd, &before) != 0 or before.mode & std.c.S.IFMT != std.c.S.IFREG) return unavailable("Only regular files can be previewed.");
    const seconds = std.fmt.parseInt(i64, args[5], 10) catch return;
    const usec = std.fmt.parseInt(i64, args[6], 10) catch return;
    const size = std.fmt.parseInt(i64, args[7], 10) catch return;
    if (before.size != size or before.mtime.sec != seconds or @divTrunc(before.mtime.nsec, 1000) != usec) return unavailable("File changed; select it again or refresh.");
    if (file.queryFilesystemInfo("filesystem::remote", null, null)) |fs| {
        defer fs.unref();
        if (fs.getAttributeBoolean("filesystem::remote") != 0) return unavailable("Previews on remote filesystems are disabled.");
    }
    var prefix: [16]u8 = undefined;
    const prefix_len = std.c.read(fd, &prefix, prefix.len);
    if (prefix_len < 0) return unavailable("File could not be read.");
    _ = std.c.lseek(fd, 0, 0);
    const format = signature(prefix[0..@intCast(prefix_len)]);
    if (format == null) {
        if (!std.mem.eql(u8, args[3], "1")) return unavailable("No preview is available for this file type.");
        var text: [policy.text_limit + 1]u8 = undefined;
        var used: usize = 0;
        while (used < text.len) {
            const n = std.c.read(fd, text[used..].ptr, text.len - used);
            if (n < 0) return unavailable("Text could not be read.");
            if (n == 0) break;
            used += @intCast(n);
        }
        var truncated = used > policy.text_limit;
        used = @min(used, policy.text_limit);
        if (truncated) { // Drop only an incomplete UTF-8 tail, not invalid content.
            var trim: usize = 0;
            while (trim < 3 and used > 0 and !std.unicode.utf8ValidateSlice(text[0..used])) : (trim += 1) used -= 1;
        }
        if (!std.unicode.utf8ValidateSlice(text[0..used])) return unavailable("Text preview requires UTF-8 content.");
        var lines: usize = 0;
        for (text[0..used], 0..) |ch, i| {
            if (ch < 32 and ch != '\n' and ch != '\r' and ch != '\t') return unavailable("Binary content cannot be previewed as text.");
            if (ch == '\n') lines += 1;
            if (lines >= 500) {
                used = i + 1;
                truncated = true;
                break;
            }
        }
        if (!unchanged(fd, path, before)) return unavailable("File changed while reading.");
        output(&policy.header(.text, 0, 0));
        output(text[0..used]);
        if (truncated) output("\n… Preview truncated (64 KiB / 500 lines).\n");
        return;
    }
    if (before.size < 0 or before.size > limit) return unavailable("Image exceeds the configured file-size limit.");
    const uri = file.getUri();
    defer glib.free(uri);
    const mtime = fmt("{d}", .{before.mtime.sec});
    defer a.free(mtime);
    const source_size = fmt("{d}", .{before.size});
    defer a.free(source_size);
    const nanos = fmt("{d}", .{before.mtime.nsec});
    defer a.free(nanos);
    const cache_root = fmt("{s}/thumbnails", .{glib.getUserCacheDir()});
    defer a.free(cache_root);
    const cache_enabled = std.mem.eql(u8, args[4], "1") and edge <= 1024 and !std.mem.startsWith(u8, std.mem.span(path), cache_root);
    const class = if (edge <= 128) "normal" else if (edge <= 256) "large" else if (edge <= 512) "x-large" else "xx-large";
    const dir = fmt("{s}/{s}", .{ cache_root, class });
    defer a.free(dir);
    const cached = fmt("{s}/{s}.png", .{ dir, policy.cacheName(std.mem.span(uri)) });
    defer a.free(cached);
    if (cache_enabled) {
        const cache_fd = std.c.open(cached, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        if (cache_fd >= 0) {
            defer _ = std.c.close(cache_fd);
            var st: std.os.linux.Statx = undefined;
            if (stat(cache_fd, &st) == 0 and st.mode & std.c.S.IFMT == std.c.S.IFREG and st.size <= 8 * 1024 * 1024) {
                if (decode(cache_fd, "png", edge, 8 * 1024 * 1024)) |p| {
                    defer p.unref();
                    const valid_size = if (p.getOption("tEXt::Thumb::Size") != null) validOption(p, "tEXt::Thumb::Size", source_size) else true;
                    const valid_nanos = if (p.getOption("tEXt::Phyto::MTimeNS") != null) validOption(p, "tEXt::Phyto::MTimeNS", nanos) else true;
                    if (validOption(p, "tEXt::Thumb::URI", std.mem.span(uri)) and validOption(p, "tEXt::Thumb::MTime", mtime) and valid_size and valid_nanos and unchanged(fd, path, before)) return imageOutput(p);
                }
            }
        }
    }
    const failed_path = fmt("{s}/fail/phyto-1/{s}.png", .{ cache_root, policy.cacheName(std.mem.span(uri)) });
    defer a.free(failed_path);
    if (cache_enabled and failureCache(failed_path, uri, mtime, source_size, nanos)) return unavailable("This version of the image could not be decoded.");
    corrupt_input = false;
    const p = decode(fd, format.?, edge, limit) orelse {
        if (corrupt_input and cache_enabled and unchanged(fd, path, before)) {
            if (pix.Pixbuf.new(.rgb, 1, 8, 1, 1)) |failure| {
                defer failure.unref();
                failure.fill(0);
                save(failure, cache_root, "fail/phyto-1", uri, mtime, source_size, nanos);
            }
        }
        return unavailable("Image is damaged or its decoder is unavailable.");
    };
    defer p.unref();
    if (!unchanged(fd, path, before)) return unavailable("File changed while decoding.");
    if (cache_enabled) save(p, cache_root, class, uri, mtime, source_size, nanos);
    imageOutput(p);
}
