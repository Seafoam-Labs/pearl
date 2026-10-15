const std = @import("std");
const gio = @import("gio2");
const config = @import("config.zig");
const fetch = @import("fetch.zig");
pub const Source = struct { id: u32 = 0, title: []const u8, url: []const u8, snippet: []const u8, provider: []const u8, text: []const u8 = "" };
pub fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn string(value: std.json.Value, key: []const u8) []const u8 {
    const v = field(value, key) orelse return "";
    return if (v == .string) v.string else "";
}
pub fn parse(a: std.mem.Allocator, kind: config.ProviderKind, provider: []const u8, bytes: []const u8) ![]Source {
    if (kind == .bing) return @import("bing.zig").parse(a, provider, bytes);
    try @import("../config/preferences.zig").boundedJson(bytes, 2 * 1024 * 1024, 24);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const results = switch (kind) {
        .google, .searxng => field(value, "results"),
        .google_legacy => field(value, "items"),
        .brave => if (field(value, "web")) |web| field(web, "results") else null,
        .bing => unreachable,
    } orelse return &.{};
    if (results != .array) return error.InvalidSearchResponse;
    var sources: std.ArrayList(Source) = .empty;
    for (results.array.items) |result| {
        if (sources.items.len == 5) break;
        const url = string(result, if (kind == .google_legacy) "link" else "url");
        fetch.safeUrl(url, false) catch continue;
        const title = string(result, "title");
        const snippet = string(result, switch (kind) {
            .google, .searxng => "content",
            .brave => "description",
            .google_legacy => "snippet",
            .bing => unreachable,
        });
        if (title.len > 2048 or snippet.len > 16384) continue;
        try sources.append(a, .{ .title = title, .url = url, .snippet = snippet, .provider = provider });
    }
    return sources.toOwnedSlice(a);
}
pub fn search(a: std.mem.Allocator, p: config.Provider, query: []const u8, cancel: *gio.Cancellable) ![]Source {
    try p.validate();
    if (query.len == 0 or query.len > 600 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidSearchQuery;
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var count: usize = 0;
    while (words.next() != null) count += 1;
    if (count > 75) return error.InvalidSearchQuery;
    const q = try fetch.encode(a, query);
    const lang = try fetch.encode(a, p.language);
    var headers: std.ArrayList([]const u8) = .empty;
    var secret: ?[]const u8 = null;
    defer if (secret) |s| std.crypto.secureZero(u8, @constCast(s));
    const url = switch (p.kind) {
        .bing => try @import("bing.zig").url(a, p, query),
        .google, .searxng => blk: {
            if (p.endpoint.len == 0) return error.SearchEndpointRequired;
            break :blk try std.fmt.allocPrint(a, "{s}/search?q={s}&format=json&language={s}&safesearch={d}{s}", .{ std.mem.trimEnd(u8, p.endpoint, "/"), q, lang, @as(u8, if (p.safe_search) 1 else 0), if (p.kind == .google) "&engines=google" else "" });
        },
        .brave => blk: {
            secret = try @import("credentials.zig").lookup(a, p.id);
            try headers.append(a, try std.fmt.allocPrint(a, "X-Subscription-Token: {s}", .{secret.?}));
            break :blk try std.fmt.allocPrint(a, "https://api.search.brave.com/res/v1/web/search?q={s}&count=5&search_lang={s}&safesearch={s}", .{ q, lang, if (p.safe_search) "moderate" else "off" });
        },
        .google_legacy => blk: {
            if (p.engine_id.len == 0) return error.SearchEngineIdRequired;
            secret = try @import("credentials.zig").lookup(a, p.id);
            break :blk try std.fmt.allocPrint(a, "https://customsearch.googleapis.com/customsearch/v1?q={s}&cx={s}&key={s}&num=5&safe={s}", .{ q, try fetch.encode(a, p.engine_id), try fetch.encode(a, secret.?), if (p.safe_search) "active" else "off" });
        },
    };
    defer if (p.kind == .google_legacy) std.crypto.secureZero(u8, @constCast(url));
    const response = try fetch.request(a, .{ .url = url, .headers = headers.items, .private_endpoint = p.kind == .google or p.kind == .searxng, .redirects = false }, cancel);
    if (response.status == 401 or response.status == 403) return error.SearchNotAuthorized;
    if (response.status == 429) return error.SearchQuotaExceeded;
    if (response.status != 200) return error.SearchUnavailable;
    return parse(a, p.kind, p.name, response.bytes);
}
test "search adapters normalize sources and discard unsafe result links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const results = try parse(arena.allocator(), .google, "Google", "{\"results\":[{\"title\":\"bad\",\"url\":\"file:///etc/passwd\"},{\"title\":\"RAM\",\"url\":\"https://example.org\",\"content\":\"Memory\"}]}");
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("RAM", results[0].title);
}
