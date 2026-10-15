//! Bing's public RSS search. Parse bounded XML without DTDs or external entities.
const std = @import("std");
const config = @import("config.zig");
const fetch = @import("fetch.zig");
const Source = @import("providers.zig").Source;
const c = @cImport({
    @cInclude("libxml/parser.h");
    @cInclude("libxml/tree.h");
});

pub fn url(a: std.mem.Allocator, p: config.Provider, query: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://www.bing.com/search?format=rss&q={s}&count=5&setlang={s}&adlt={s}", .{ try fetch.encode(a, query), try fetch.encode(a, p.language), if (p.safe_search) "strict" else "off" });
}
fn named(node: c.xmlNodePtr, name: []const u8) bool {
    return node != null and node.*.type == c.XML_ELEMENT_NODE and node.*.name != null and std.mem.eql(u8, std.mem.span(node.*.name), name);
}
fn child(first: c.xmlNodePtr, name: []const u8) c.xmlNodePtr {
    var node = first;
    while (node != null) : (node = node.*.next) if (named(node, name)) return node;
    return null;
}
fn content(a: std.mem.Allocator, item: c.xmlNodePtr, name: []const u8, limit: usize) ![]const u8 {
    const node = child(item.*.children, name);
    if (node == null) return "";
    const value = c.xmlNodeGetContent(node) orelse return "";
    defer c.xmlFree.?(value);
    const bytes = std.mem.trim(u8, std.mem.span(value), " \t\r\n");
    if (bytes.len > limit or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSearchResult;
    return a.dupe(u8, bytes);
}
pub fn parse(a: std.mem.Allocator, provider: []const u8, bytes: []const u8) ![]Source {
    if (bytes.len > 2 * 1024 * 1024) return error.ResponseTooLarge;
    // NOENT, DTDLOAD and HUGE are deliberately absent. libxml's normal depth
    // limits apply; reject all DTDs before reading any item content.
    const doc = c.xmlReadMemory(bytes.ptr, @intCast(bytes.len), null, null, c.XML_PARSE_NONET | c.XML_PARSE_NOERROR | c.XML_PARSE_NOWARNING) orelse return error.InvalidSearchResponse;
    defer c.xmlFreeDoc(doc);
    if (doc.*.intSubset != null or doc.*.extSubset != null) return error.InvalidSearchResponse;
    const root = c.xmlDocGetRootElement(doc);
    if (!named(root, "rss")) return error.InvalidSearchResponse;
    const channel = child(root.*.children, "channel");
    if (channel == null) return error.InvalidSearchResponse;
    var sources: std.ArrayList(Source) = .empty;
    var item = channel.*.children;
    while (item != null and sources.items.len < 5) : (item = item.*.next) {
        if (!named(item, "item")) continue;
        const link = content(a, item, "link", 8192) catch |err| switch (err) {
            error.InvalidSearchResult => continue,
            else => return err,
        };
        fetch.safeUrl(link, false) catch continue;
        const title = content(a, item, "title", 2048) catch |err| switch (err) {
            error.InvalidSearchResult => continue,
            else => return err,
        };
        if (title.len == 0) continue;
        const description = content(a, item, "description", 16384) catch |err| switch (err) {
            error.InvalidSearchResult => continue,
            else => return err,
        };
        const snippet = if (std.mem.indexOfScalar(u8, description, '<') != null)
            std.mem.trim(u8, try @import("extract.zig").html(a, description), " \t\r\n")
        else
            description;
        for (sources.items) |old| {
            if (std.mem.eql(u8, old.url, link)) break;
        } else try sources.append(a, .{ .title = title, .url = link, .snippet = snippet, .provider = provider });
    }
    return sources.toOwnedSlice(a);
}

test "Bing RSS request encodes query and carries language and safe search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("https://www.bing.com/search?format=rss&q=RAM%20%26%20storage&count=5&setlang=en&adlt=strict", try url(arena.allocator(), .{}, "RAM & storage"));
    const custom = try url(arena.allocator(), .{ .language = "de", .safe_search = false }, "Grüße");
    try std.testing.expect(std.mem.endsWith(u8, custom, "&setlang=de&adlt=off"));
}
test "Bing RSS normalizes entities and snippets while rejecting unsafe and duplicate links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = try parse(arena.allocator(), "Bing",
        \\<?xml version="1.0"?><rss version="2.0"><channel><title>Bing search</title>
        \\<item><title>Unsafe</title><link>file:///etc/passwd</link></item>
        \\<item><title>RAM &amp; storage</title><link>https://example.org/?x=1&amp;y=2</link><description><![CDATA[<p>RAM holds <b>working data</b>.</p><script>ignore</script>]]></description></item>
        \\<item><title>Duplicate</title><link>https://example.org/?x=1&amp;y=2</link></item>
        \\<item><title>Storage</title><link>https://example.org/storage</link><description>Saved &amp; retained.</description></item>
        \\</channel></rss>
    );
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("RAM & storage", sources[0].title);
    try std.testing.expectEqualStrings("https://example.org/?x=1&y=2", sources[0].url);
    try std.testing.expect(std.mem.indexOf(u8, sources[0].snippet, "working data") != null);
    try std.testing.expect(std.mem.indexOf(u8, sources[0].snippet, "ignore") == null);
    try std.testing.expectEqualStrings("Saved & retained.", sources[1].snippet);
    try std.testing.expectEqualStrings("Bing", sources[1].provider);
}
test "Bing RSS rejects error pages malformed XML and DTDs but accepts empty feeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "<html><body>Verification required</body></html>",
        "<rss><channel><item></rss>",
        "<!DOCTYPE rss [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><rss><channel><item><title>&secret;</title></item></channel></rss>",
        "<!DOCTYPE rss SYSTEM 'https://example.org/external.dtd'><rss><channel/></rss>",
    }) |bytes| try std.testing.expectError(error.InvalidSearchResponse, parse(arena.allocator(), "Bing", bytes));
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), "Bing", "<rss><channel/></rss>")).len);
}
test "Bing RSS caps results at five" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var xml: std.ArrayList(u8) = .empty;
    try xml.appendSlice(a, "<rss><channel>");
    for (0..8) |i| try xml.appendSlice(a, try std.fmt.allocPrint(a, "<item><title>Result {d}</title><link>https://example.org/{d}</link></item>", .{ i, i }));
    try xml.appendSlice(a, "</channel></rss>");
    try std.testing.expectEqual(@as(usize, 5), (try parse(a, "Bing", xml.items)).len);
}
