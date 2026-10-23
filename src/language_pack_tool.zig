//! Validate compiled catalogs and emit package metadata. No GTK dependency.
const std = @import("std");
const Catalog = @import("i18n/catalog.zig").Catalog;
const format = @import("i18n/format.zig");
const locale = @import("i18n/locale.zig");
const Domain = struct { name: []const u8, contract: u32 = 1, translated: usize, total: usize };
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 6 or (args.len - 6) % 3 != 0) return error.Arguments;
    if (!locale.isCanonical(args[1]) or args[2].len == 0 or args[2].len > 128 or !std.unicode.utf8ValidateSlice(args[2]) or args[4].len == 0 or args[4].len > 64 or (!std.mem.eql(u8, args[3], "ltr") and !std.mem.eql(u8, args[3], "rtl"))) return error.InvalidMetadata;
    for (args[2]) |byte| if (byte < 32 or byte == 127) return error.InvalidMetadata;
    for (args[4]) |byte| if (byte < 32 or byte > 126) return error.InvalidMetadata;
    var domains: std.ArrayList(Domain) = .empty;
    var i: usize = 6;
    while (i < args.len) : (i += 3) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[i + 1], a, .limited(8 * 1024 * 1024));
        const cat = try Catalog.parse(bytes);
        var headers = std.mem.splitScalar(u8, cat.lookup("").?, '\n');
        var language_matches = false;
        while (headers.next()) |line| if (std.mem.startsWith(u8, line, "Language:")) {
            language_matches = std.mem.eql(u8, args[1], std.mem.trim(u8, line[9..], " \t\r"));
        };
        if (!language_matches) return error.CatalogLanguageMismatch;
        const template = try std.Io.Dir.cwd().readFileAlloc(init.io, args[i + 2], a, .limited(8 * 1024 * 1024));
        var keys: std.StringHashMap(void) = .init(a);
        var context: []const u8 = "";
        var lines = std.mem.splitScalar(u8, template, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "msgctxt ")) context = try std.zig.string_literal.parseAlloc(a, line[8..]);
            if (std.mem.startsWith(u8, line, "msgid ")) {
                const id = try std.zig.string_literal.parseAlloc(a, line[6..]);
                if (id.len > 0) try keys.put(if (context.len > 0) try std.fmt.allocPrint(a, "{s}\x04{s}", .{ context, id }) else id, {});
                context = "";
            }
        }
        var translated: usize = 0;
        for (0..cat.count) |entry| {
            const key = try cat.string(cat.originals, entry);
            if (key.len == 0) continue;
            const value = try cat.string(cat.translations, entry);
            if (value.len == 0) continue;
            const identity = key[0..(std.mem.indexOfScalar(u8, key, 0) orelse key.len)];
            if (keys.contains(identity)) translated += 1;
            const source = identity[(if (std.mem.indexOfScalar(u8, identity, 4)) |position| position + 1 else 0)..];
            if (std.mem.indexOfScalar(u8, source, '{') != null and format.compatible(source, source)) {
                var forms = std.mem.splitScalar(u8, value, 0);
                while (forms.next()) |form| if (!format.compatible(source, form)) {
                    std.debug.print("Incompatible placeholders in {s}: {s}\n", .{ args[i], source });
                    return error.InvalidPlaceholders;
                };
            }
        }
        try domains.append(a, .{ .name = args[i], .translated = translated, .total = keys.count() });
    }
    const manifest = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .locale = args[1], .native_name = args[2], .direction = args[3], .revision = args[4], .domains = domains.items }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[5], .data = manifest });
}
