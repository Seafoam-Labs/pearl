//! libxml2 parses bounded HTML without loading external resources or scripts.
const std = @import("std");
const c = @cImport({
    @cInclude("libxml/HTMLparser.h");
    @cInclude("libxml/tree.h");
});
pub fn html(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len > 2 * 1024 * 1024) return error.ResponseTooLarge;
    const doc = c.htmlReadMemory(bytes.ptr, @intCast(bytes.len), null, "UTF-8", c.HTML_PARSE_NONET | c.HTML_PARSE_NOERROR | c.HTML_PARSE_NOWARNING | c.HTML_PARSE_RECOVER) orelse return error.InvalidPage;
    defer c.xmlFreeDoc(doc);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try visit(a, c.xmlDocGetRootElement(doc), &out, 0);
    return out.toOwnedSlice(a);
}
fn visit(a: std.mem.Allocator, first: c.xmlNodePtr, out: *std.ArrayList(u8), depth: usize) !void {
    if (depth > 128) return;
    var node = first;
    while (node != null and out.items.len < 256 * 1024) : (node = node.*.next) {
        const name = if (node.*.name != null) std.mem.span(node.*.name) else "";
        for ([_][]const u8{ "script", "style", "nav", "footer", "header", "noscript", "form", "svg" }) |skip| {
            if (std.ascii.eqlIgnoreCase(name, skip)) break;
        } else {
            if (node.*.type == c.XML_TEXT_NODE and node.*.content != null) {
                for (std.mem.span(node.*.content)) |ch| {
                    if (out.items.len >= 256 * 1024) break;
                    if (std.ascii.isWhitespace(ch)) {
                        if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(a, ' ');
                    } else if (ch >= 32) try out.append(a, ch);
                }
                if (out.items.len < 256 * 1024) try out.append(a, ' ');
            } else try visit(a, node.*.children, out, depth + 1);
        }
    }
}
test "page extraction drops scripts and navigation" {
    const a = std.testing.allocator;
    const result = try html(a, "<html><nav>menu</nav><script>secret</script><p>Useful <b>answer</b></p></html>");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Useful") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret") == null);
}
