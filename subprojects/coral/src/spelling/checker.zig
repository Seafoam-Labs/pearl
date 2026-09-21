//! Enchant is confined to one worker. Jobs contain only owned immutable text;
//! results are consumed by the GTK thread and validated by document/revision.
const std = @import("std");
const u = @import("../c.zig");
const c = u.c;
const a = u.a;
extern fn coral_word_breaks(text: [*]const u8, bytes: c_int, breaks: [*]u8, count: c_int) void;
pub const Range = struct { start: c_int, end: c_int };
pub const Token = struct { bytes_start: usize, bytes_end: usize, start: c_int, end: c_int };
pub const Job = struct {
    kind: enum { list, check, suggest, add, stop },
    id: u64 = 0,
    revision: u64 = 0,
    generation: u64 = 0,
    priority: bool = false,
    offset: c_int = 0,
    end: c_int = 0,
    text: [:0]u8,
    language: [:0]u8,
    words: std.ArrayList([:0]u8) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    available: bool = false,
    failed: bool = false,
    pub fn create(kind: @FieldType(Job, "kind"), text: []const u8, lang: []const u8) *Job {
        const j = a.create(Job) catch unreachable;
        j.* = .{ .kind = kind, .text = u.z(text), .language = u.z(lang) };
        return j;
    }
    pub fn destroy(j: *Job) void {
        a.free(j.text);
        a.free(j.language);
        for (j.words.items) |w| a.free(w);
        j.words.deinit(a);
        j.ranges.deinit(a);
        a.destroy(j);
    }
};
pub const Worker = struct {
    incoming: *c.GAsyncQueue,
    outgoing: *c.GAsyncQueue,
    thread: ?*c.GThread = null,
    pub fn start() *Worker {
        const w = a.create(Worker) catch unreachable;
        w.* = .{ .incoming = c.g_async_queue_new().?, .outgoing = c.g_async_queue_new().? };
        w.thread = c.g_thread_new("coral-spelling", run, w);
        return w;
    }
    pub fn submit(w: *Worker, j: *Job) void {
        c.g_async_queue_push(w.incoming, j);
    }
    pub fn take(w: *Worker) ?*Job {
        const p = c.g_async_queue_try_pop(w.outgoing) orelse return null;
        return u.cast(Job, p);
    }
    pub fn stop(w: *Worker) void {
        // The queue is bounded by one checking request per live document.
        w.submit(Job.create(.stop, "", ""));
        if (w.thread) |t| _ = c.g_thread_join(t);
        while (w.take()) |j| j.destroy();
        c.g_async_queue_unref(w.incoming);
        c.g_async_queue_unref(w.outgoing);
        a.destroy(w);
    }
};
fn collect(tag: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
    const j = u.cast(Job, data.?);
    const s = std.mem.span(tag);
    for (j.words.items) |existing| if (std.mem.eql(u8, s, existing)) return;
    j.words.append(a, u.z(s)) catch unreachable;
}
fn run(data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const w = u.cast(Worker, data.?);
    const broker = c.enchant_broker_init();
    defer if (broker != null) c.enchant_broker_free(broker);
    var dict: ?*c.EnchantDict = null;
    var language: [:0]u8 = u.z("");
    defer a.free(language);
    defer if (dict) |d| c.enchant_broker_free_dict(broker, d);
    while (true) {
        const j = u.cast(Job, c.g_async_queue_pop(w.incoming).?);
        if (j.kind == .stop) {
            j.destroy();
            break;
        }
        if (j.kind == .list) {
            if (broker != null) c.enchant_broker_list_dicts(broker, collect, j);
            c.g_async_queue_push(w.outgoing, j);
            continue;
        }
        if (!std.mem.eql(u8, language, j.language)) {
            if (dict) |d| c.enchant_broker_free_dict(broker, d);
            dict = null;
            a.free(language);
            language = u.z(j.language);
            if (broker != null and language.len > 0) dict = c.enchant_broker_request_dict(broker, language);
        }
        j.available = dict != null;
        if (dict) |d| switch (j.kind) {
            .check => {
                const tokens = tokenize(a, j.text) catch unreachable;
                defer a.free(tokens);
                for (tokens) |token| {
                    const word = j.text[token.bytes_start..token.bytes_end];
                    const result = c.enchant_dict_check(d, word.ptr, @intCast(word.len));
                    if (result < 0) {
                        j.failed = true;
                        break;
                    }
                    if (result > 0) j.ranges.append(a, .{ .start = j.offset + token.start, .end = j.offset + token.end }) catch unreachable;
                }
            },
            .suggest => {
                var count: usize = 0;
                const list = c.enchant_dict_suggest(d, j.text, @intCast(j.text.len), &count);
                if (list != null) {
                    for (0..@min(count, 5)) |i| j.words.append(a, u.z(std.mem.span(list[i]))) catch unreachable;
                    c.enchant_dict_free_string_list(d, list);
                }
            },
            .add => {
                c.enchant_dict_add(d, j.text, @intCast(j.text.len));
                j.failed = c.enchant_dict_get_error(d) != null;
            },
            else => {},
        };
        c.g_async_queue_push(w.outgoing, j);
    }
    return null;
}
fn letter(ch: u32) bool {
    return c.g_unichar_isalpha(ch) != 0 or c.g_unichar_ismark(ch) != 0;
}
/// Unicode character offsets are kept distinct from UTF-8 byte positions.
/// Whitespace-delimited URLs, emails and identifiers with digits are excluded.
pub fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]Token {
    const count = try std.unicode.utf8CountCodepoints(text);
    const breaks = try allocator.alloc(u8, count + 1);
    defer allocator.free(breaks);
    coral_word_breaks(text.ptr, @intCast(text.len), breaks.ptr, @intCast(count + 1));
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var chars: c_int = 0;
    while (i < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const ch = std.unicode.utf8Decode(text[i..@min(i + width, text.len)]) catch 0;
        if (!letter(ch)) {
            i += width;
            chars += 1;
            continue;
        }
        const start = i;
        const char_start = chars;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            const code = std.unicode.utf8Decode(text[i..@min(i + n, text.len)]) catch 0;
            if (!letter(code) and code != '\'' and code != 0x2019) break;
            const after_apostrophe = i > start and (text[i - 1] == '\'' or (i >= 3 and std.mem.eql(u8, text[i - 3 .. i], "’")));
            if (chars > char_start and breaks[@intCast(chars)] & 2 != 0 and code != '\'' and code != 0x2019 and !after_apostrophe) break;
            i += n;
            chars += 1;
        }
        var end = i;
        var char_end = chars;
        while (end > start and (text[end - 1] == '\'' or (end >= 3 and std.mem.eql(u8, text[end - 3 .. end], "’")))) {
            end -= if (text[end - 1] == '\'') @as(usize, 1) else 3;
            char_end -= 1;
        }
        var lo = start;
        while (lo > 0 and !std.ascii.isWhitespace(text[lo - 1])) lo -= 1;
        var hi = i;
        while (hi < text.len and !std.ascii.isWhitespace(text[hi])) hi += 1;
        const context = text[lo..hi];
        var skip = std.mem.indexOf(u8, context, "://") != null or std.mem.indexOfScalar(u8, context, '@') != null or std.mem.indexOfScalar(u8, context, '_') != null;
        for (context) |b| {
            if (std.ascii.isDigit(b)) skip = true;
        }
        if (!skip and end > start and end - start <= 128) try out.append(allocator, .{ .bytes_start = start, .bytes_end = end, .start = char_start, .end = char_end });
    }
    return out.toOwnedSlice(allocator);
}
test "Unicode spelling tokens retain byte and character ranges" {
    const text = "🌱 café cafe\u{301} don't l’esprit 123 https://example.com user@example.org snake_case word2";
    const tokens = try tokenize(std.testing.allocator, text);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("café", text[tokens[0].bytes_start..tokens[0].bytes_end]);
    try std.testing.expectEqual(@as(c_int, 2), tokens[0].start);
    try std.testing.expectEqualStrings("don't", text[tokens[2].bytes_start..tokens[2].bytes_end]);
}
