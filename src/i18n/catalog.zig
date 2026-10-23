//! Validated GNU MO catalogs. Catalog storage is owned by the caller.
const std = @import("std");
const plural = @import("plural.zig");
pub const max_bytes = 8 * 1024 * 1024;
pub const Catalog = struct {
    bytes: []const u8,
    endian: std.builtin.Endian,
    count: usize,
    originals: usize,
    translations: usize,
    forms: u8 = 2,
    expression: []const u8 = "n != 1",
    fn word(self: Catalog, offset: usize) !u32 {
        if (offset > self.bytes.len or self.bytes.len - offset < 4) return error.InvalidCatalog;
        return std.mem.readInt(u32, self.bytes[offset..][0..4], self.endian);
    }
    pub fn string(self: Catalog, table: usize, index: usize) ![:0]const u8 {
        const len: usize = try self.word(table + index * 8);
        const offset: usize = try self.word(table + index * 8 + 4);
        if (offset >= self.bytes.len or len >= self.bytes.len - offset or self.bytes[offset + len] != 0) return error.InvalidCatalog;
        return self.bytes[offset..][0..len :0];
    }
    pub fn parse(bytes: []const u8) !Catalog {
        if (bytes.len < 28 or bytes.len > max_bytes) return error.InvalidCatalog;
        const magic = std.mem.readInt(u32, bytes[0..4], .little);
        var self: Catalog = .{ .bytes = bytes, .endian = switch (magic) {
            0x950412de => .little,
            0xde120495 => .big,
            else => return error.InvalidCatalog,
        }, .count = 0, .originals = 0, .translations = 0 };
        if (try self.word(4) != 0) return error.InvalidCatalog;
        self.count = try self.word(8);
        self.originals = try self.word(12);
        self.translations = try self.word(16);
        if (self.count > 65536 or self.originals > bytes.len or self.translations > bytes.len or self.count * 8 > bytes.len - self.originals or self.count * 8 > bytes.len - self.translations) return error.InvalidCatalog;
        var previous: []const u8 = "";
        for (0..self.count) |i| {
            const key = try self.string(self.originals, i);
            const value = try self.string(self.translations, i);
            if (!std.unicode.utf8ValidateSlice(key) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidCatalog;
            const singular = key[0..(std.mem.indexOfScalar(u8, key, 0) orelse key.len)];
            if (i > 0 and std.mem.order(u8, previous, singular) != .lt) return error.InvalidCatalog;
            previous = singular;
        }
        const header = self.lookup("") orelse return error.InvalidCatalog;
        if (std.mem.indexOf(u8, header, "charset=UTF-8") == null) return error.InvalidCatalog;
        if (std.mem.indexOf(u8, header, "Plural-Forms:")) |start| {
            const line = header[start..(std.mem.indexOfScalarPos(u8, header, start, '\n') orelse header.len)];
            const f = std.mem.indexOf(u8, line, "nplurals=") orelse return error.InvalidCatalog;
            const end = std.mem.indexOfScalarPos(u8, line, f, ';') orelse return error.InvalidCatalog;
            self.forms = std.fmt.parseInt(u8, std.mem.trim(u8, line[f + 9 .. end], " "), 10) catch return error.InvalidCatalog;
            if (self.forms == 0 or self.forms > 16) return error.InvalidCatalog;
            const p = std.mem.indexOf(u8, line, "plural=") orelse return error.InvalidCatalog;
            self.expression = std.mem.trim(u8, line[p + 7 ..], " ;\r");
            _ = try plural.evaluate(self.expression, 1);
        }
        return self;
    }
    pub fn lookup(self: Catalog, key: []const u8) ?[:0]const u8 {
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const candidate = self.string(self.originals, mid) catch return null;
            const singular = candidate[0..(std.mem.indexOfScalar(u8, candidate, 0) orelse candidate.len)];
            switch (std.mem.order(u8, key, singular)) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return self.string(self.translations, mid) catch null,
            }
        }
        return null;
    }
    pub fn translate(self: Catalog, key: []const u8, count: ?u64) ?[:0]const u8 {
        const value = self.lookup(key) orelse return null;
        const index = if (count) |n| plural.evaluate(self.expression, n) catch return null else 0;
        if (index >= self.forms) return null;
        var parts = std.mem.splitScalar(u8, value, 0);
        var i: u64 = 0;
        while (parts.next()) |part| : (i += 1) if (i == index) return if (part.len == 0) null else value[@intFromPtr(part.ptr) - @intFromPtr(value.ptr) ..][0..part.len :0];
        return null;
    }
};
test "reject truncated and invalid catalog tables" {
    try std.testing.expectError(error.InvalidCatalog, Catalog.parse("not a catalog"));
    var bytes: [28]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0x950412de, .little);
    std.mem.writeInt(u32, bytes[8..12], 0xffffffff, .little);
    try std.testing.expectError(error.InvalidCatalog, Catalog.parse(&bytes));
}

test "both byte orders lookup and corrupted offsets lengths and UTF-8" {
    const header = "Content-Type: text/plain; charset=UTF-8\n";
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var bytes: [256]u8 = @splat(0);
        const words = [_]u32{ 0x950412de, 0, 2, 28, 44, 0, 0, 0, 60, 8, 61, header.len, 70, 13, 70 + header.len + 1 };
        for (words, 0..) |word, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, endian);
        @memcpy(bytes[61..69], "Settings");
        @memcpy(bytes[70..][0..header.len], header);
        @memcpy(bytes[70 + header.len + 1 ..][0..13], "Einstellungen");
        const parsed = try Catalog.parse(&bytes);
        try std.testing.expectEqualStrings("Einstellungen", parsed.translate("Settings", null).?);
        try std.testing.expect(parsed.translate("Unknown", null) == null);
        for ([_]usize{ 12, 16, 28, 32, 36, 40, 44, 48, 52, 56 }) |offset| {
            var bad = bytes;
            std.mem.writeInt(u32, bad[offset..][0..4], 0xffffffff, endian);
            try std.testing.expectError(error.InvalidCatalog, Catalog.parse(&bad));
        }
        bytes[61] = 0xff;
        try std.testing.expectError(error.InvalidCatalog, Catalog.parse(&bytes));
    }
}
