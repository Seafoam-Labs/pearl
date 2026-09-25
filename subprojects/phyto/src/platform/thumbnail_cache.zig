//! Helper-only bounded disk cache ownership journal. Never prune foreign entries.
const std = @import("std");
const glib = @import("glib2");
const a = std.heap.c_allocator;
const budget = 256 * 1024 * 1024;
fn format(comptime f: []const u8, args: anytype) [:0]u8 {
    return std.fmt.allocPrintSentinel(a, f, args, 0) catch unreachable;
}
fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}
fn safeName(name: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return false;
    const class = name[0..slash];
    if (!std.mem.eql(u8, class, "normal") and !std.mem.eql(u8, class, "large") and !std.mem.eql(u8, class, "x-large") and !std.mem.eql(u8, class, "xx-large") and !std.mem.eql(u8, class, "fail/phyto-1")) return false;
    const tail = name[slash + 1 ..];
    if (tail.len != 36 or !std.mem.endsWith(u8, tail, ".png")) return false;
    for (tail[0..32]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}
fn read(path: [*:0]const u8, max: usize) ?[]u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var st: std.os.linux.Statx = undefined;
    if (std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, std.os.linux.STATX.BASIC_STATS, &st) != 0 or st.mode & std.c.S.IFMT != std.c.S.IFREG or st.size > max) return null;
    const bytes = a.alloc(u8, @intCast(st.size)) catch return null;
    var used: usize = 0;
    while (used < bytes.len) {
        const n = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
        if (n <= 0) {
            a.free(bytes);
            return null;
        }
        used += @intCast(n);
    }
    return bytes;
}
pub fn save(root: [:0]const u8, relative: [:0]const u8, png: []const u8) void {
    if (!safeName(relative) or png.len > 8 * 1024 * 1024) return;
    const ledger_dir = format("{s}/phyto", .{glib.getUserCacheDir()});
    defer a.free(ledger_dir);
    if (glib.mkdirWithParents(ledger_dir, 0o700) != 0) return;
    const lock_path = format("{s}/thumbnail-cache.lock", .{ledger_dir});
    defer a.free(lock_path);
    const lock = std.c.open(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (lock < 0) return;
    defer _ = std.c.close(lock);
    // A busy cache is optional; never delay preview delivery waiting for it.
    if (std.c.flock(lock, 2 | 4) != 0) return;
    defer _ = std.c.flock(lock, 8);
    const ledger_path = format("{s}/thumbnail-cache.ini", .{ledger_dir});
    defer a.free(ledger_path);
    const ledger = glib.KeyFile.new();
    defer ledger.unref();
    if (read(ledger_path, 2 * 1024 * 1024)) |data| {
        defer a.free(data);
        const terminated = a.dupeZ(u8, data) catch return;
        defer a.free(terminated);
        _ = ledger.loadFromData(terminated, data.len, .{}, null);
    }
    const keys = ledger.getKeys("Sizes", null, null);
    defer if (keys) |k| glib.strfreev(k);
    var total: u64 = 0;
    var count: usize = 0;
    if (keys) |k| for (std.mem.span(k)) |name| {
        total +|= ledger.getUint64("Sizes", name.?, null);
        count += 1;
    };
    // Keep at most 4096 ownership receipts as well as the byte budget.
    if (keys) |k| for (std.mem.span(k)) |name| {
        if (total +| png.len <= budget and count < 4096) break;
        const size = ledger.getUint64("Sizes", name.?, null);
        total -|= size;
        count -= 1;
        if (safeName(std.mem.span(name.?))) {
            const path = format("{s}/{s}", .{ root, name.? });
            defer a.free(path);
            if (ledger.getString("Hashes", name.?, null)) |hash| {
                defer glib.free(hash);
                if (read(path, 8 * 1024 * 1024)) |content| {
                    defer a.free(content);
                    if (std.mem.eql(u8, &digest(content), std.mem.span(hash))) _ = std.c.unlink(path);
                }
            }
        }
        _ = ledger.removeKey("Sizes", name.?, null);
        _ = ledger.removeKey("Hashes", name.?, null);
    };
    const path = format("{s}/{s}", .{ root, relative });
    defer a.free(path);
    const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
    const parent = a.dupeZ(u8, path[0..slash]) catch return;
    defer a.free(parent);
    if (glib.mkdirWithParents(parent, 0o700) != 0) return;
    ledger.setUint64("Sizes", relative, png.len);
    const hash = format("{s}", .{digest(png)});
    defer a.free(hash);
    ledger.setString("Hashes", relative, hash);
    var n: usize = 0;
    if (ledger.toData(&n, null)) |data| {
        defer glib.free(data);
        // Persist the receipt first: a failed image write may overcount, but
        // a failed journal write must never leave an untracked cache entry.
        if (glib.fileSetContentsFull(ledger_path, data, @intCast(n), .{ .consistent = true }, 0o600, null) != 0)
            _ = glib.fileSetContentsFull(path, png.ptr, @intCast(png.len), .{ .consistent = true }, 0o600, null);
    }
}
