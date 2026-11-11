const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const f = @import("features.zig");
const Document = @import("../document.zig").Document;
extern fn gtk_source_style_scheme_get_style(scheme: *c.GtkSourceStyleScheme, id: [*:0]const u8) ?*anyopaque;
extern fn gtk_source_style_apply(style: ?*anyopaque, tag: *c.GtkTextTag) void;
const names = [_][:0]const u8{ "coral-language-error", "coral-language-warning", "coral-language-info", "coral-semantic-type", "coral-semantic-function", "coral-semantic-readonly", "coral-semantic-keyword", "coral-semantic-string", "coral-semantic-number", "coral-semantic-comment", "coral-semantic-symbol", "coral-semantic-operator" };
fn themed(d: *Document, index: usize, value: *c.GtkTextTag) *c.GtkTextTag {
    const style_id: [*:0]const u8 = switch (index) {
        3 => "def:type",
        4 => "def:function",
        6 => "def:keyword",
        7 => "def:string",
        8 => "def:number",
        9 => "def:comment",
        10 => "def:identifier",
        11 => "def:operator",
        else => return value,
    };
    if (c.gtk_source_buffer_get_style_scheme(u.cast(c.GtkSourceBuffer, d.buffer))) |scheme| {
        if (gtk_source_style_scheme_get_style(scheme, style_id)) |style| gtk_source_style_apply(style, value);
    }
    return value;
}
fn tag(d: *Document, index: usize) *c.GtkTextTag {
    const table = c.gtk_text_buffer_get_tag_table(d.buffer);
    if (c.gtk_text_tag_table_lookup(table, names[index])) |t| return themed(d, index, t);
    const value = switch (index) {
        0 => c.gtk_text_buffer_create_tag(d.buffer, names[index], "underline", @as(c_int, c.PANGO_UNDERLINE_ERROR), @as(?*anyopaque, null)).?,
        1, 2 => c.gtk_text_buffer_create_tag(d.buffer, names[index], "underline", @as(c_int, c.PANGO_UNDERLINE_SINGLE), @as(?*anyopaque, null)).?,
        3, 4 => c.gtk_text_buffer_create_tag(d.buffer, names[index], "weight", @as(c_int, 600), @as(?*anyopaque, null)).?,
        5, 9 => c.gtk_text_buffer_create_tag(d.buffer, names[index], "style", @as(c_int, c.PANGO_STYLE_ITALIC), @as(?*anyopaque, null)).?,
        else => c.gtk_text_buffer_create_tag(d.buffer, names[index], "weight", @as(c_int, 500), @as(?*anyopaque, null)).?,
    };
    return themed(d, index, value);
}
pub fn clear(d: *Document, semantic_tags: bool) void {
    var start: c.GtkTextIter = undefined;
    var end: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_bounds(d.buffer, &start, &end);
    for (names[if (semantic_tags) @as(usize, 3) else 0..if (semantic_tags) names.len else 3]) |name| {
        if (c.gtk_text_tag_table_lookup(c.gtk_text_buffer_get_tag_table(d.buffer), name)) |t| c.gtk_text_buffer_remove_tag(d.buffer, t, &start, &end);
    }
}
/// Test instrumentation inspects actual applied GTK ranges independently of
/// session caches. The toggle budget bounds even externally modified buffers.
pub const RangeCount = struct { count: usize = 0, kinds: usize = 0, truncated: bool = false };
pub fn appliedRanges(buffer: *c.GtkTextBuffer, semantic_tags: bool) RangeCount {
    var result: RangeCount = .{};
    if (!@import("build_options").test_hooks) return result;
    var budget: usize = 131072;
    for (names[if (semantic_tags) @as(usize, 3) else 0..if (semantic_tags) names.len else 3]) |name| {
        if (c.gtk_text_tag_table_lookup(c.gtk_text_buffer_get_tag_table(buffer), name)) |value| {
            var at: c.GtkTextIter = undefined;
            c.gtk_text_buffer_get_start_iter(buffer, &at);
            var kind_applied = c.gtk_text_iter_has_tag(&at, value) != 0;
            if (kind_applied) result.count += 1;
            while (c.gtk_text_iter_forward_to_tag_toggle(&at, value) != 0) {
                if (budget == 0) {
                    result.kinds += @intFromBool(kind_applied);
                    result.truncated = true;
                    return result;
                }
                budget -= 1;
                if (c.gtk_text_iter_has_tag(&at, value) != 0) {
                    result.count += 1;
                    kind_applied = true;
                }
            }
            result.kinds += @intFromBool(kind_applied);
        }
    }
    return result;
}
pub fn iter(d: *Document, text: []const u8, byte: usize) !c.GtkTextIter {
    if (byte > text.len) return error.OutOfRange;
    const count = try std.unicode.utf8CountCodepoints(text[0..byte]);
    var result: c.GtkTextIter = undefined;
    c.gtk_text_buffer_get_iter_at_offset(d.buffer, &result, @intCast(count));
    return result;
}
fn apply(d: *Document, text: []const u8, range: f.ByteRange, index: usize) !void {
    var start = try iter(d, text, range.start);
    var end = try iter(d, text, range.end);
    c.gtk_text_buffer_apply_tag(d.buffer, tag(d, index), &start, &end);
}
pub fn diagnostics(d: *Document, text: []const u8, items: []const f.Diagnostic) !void {
    clear(d, false);
    for (items) |item| try apply(d, text, item.range, switch (item.severity) {
        .err => 0,
        .warning => 1,
        else => 2,
    });
}
pub fn semantic(d: *Document, text: []const u8, tokens: []const f.SemanticToken, legend: f.Legend) !void {
    clear(d, true);
    for (tokens) |token| {
        const kind = legend.token_types[token.token_type];
        const index: usize = if (std.mem.eql(u8, kind, "type") or std.mem.eql(u8, kind, "struct") or std.mem.eql(u8, kind, "enum") or std.mem.eql(u8, kind, "class") or std.mem.eql(u8, kind, "interface") or std.mem.eql(u8, kind, "typeParameter")) 3 else if (std.mem.eql(u8, kind, "function") or std.mem.eql(u8, kind, "method") or std.mem.eql(u8, kind, "macro")) 4 else if (std.mem.eql(u8, kind, "keyword") or std.mem.eql(u8, kind, "modifier") or std.mem.eql(u8, kind, "keywordLiteral")) 6 else if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "regexp") or std.mem.eql(u8, kind, "escapeSequence")) 7 else if (std.mem.eql(u8, kind, "number")) 8 else if (std.mem.eql(u8, kind, "comment")) 9 else if (std.mem.eql(u8, kind, "operator")) 11 else 10;
        try apply(d, text, token.range, index);
        for (legend.token_modifiers, 0..) |modifier, i| if (std.mem.eql(u8, modifier, "readonly") and token.modifiers & (@as(u32, 1) << @intCast(i)) != 0) {
            try apply(d, text, token.range, 5);
        };
    }
}
