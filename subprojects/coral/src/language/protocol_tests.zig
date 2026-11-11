//! Standalone: zig test src/language/protocol_tests.zig
const std = @import("std");
const testing = std.testing;
const a = testing.allocator;
const protocol = @import("protocol.zig");
const positions = @import("positions.zig");
const uri = @import("uri.zig");

fn expectMessage(framer: *protocol.Framer, expected: []const u8) !void {
    const message = (try framer.next()) orelse return error.MissingMessage;
    defer framer.allocator.free(message);
    try testing.expectEqualStrings(expected, message);
}

fn expectPoisoned(framer: *protocol.Framer) !void {
    try testing.expectError(error.FramerFailed, framer.feed("Content-Length: 2\r\n\r\n{}"));
    try testing.expectError(error.FramerFailed, framer.next());
    try testing.expectError(error.FramerFailed, framer.finish());
    try testing.expectEqual(@as(usize, 0), framer.retained);
    try testing.expect(framer.body == null);
    try testing.expectEqual(@as(usize, 0), framer.queue.items.len);
}

test "framer: every split including UTF-8 body and delimiter, and owned messages" {
    const body = "{\"message\":\"😀é\\r\\n\"}";
    const frame = try protocol.encodeFrame(a, body);
    defer a.free(frame);
    for (0..frame.len + 1) |split| {
        var framer = protocol.Framer.init(a);
        defer framer.deinit();
        try framer.feed(frame[0..split]);
        if (split < frame.len) try testing.expectEqual(@as(?[]u8, null), try framer.next());
        try framer.feed("");
        try framer.feed(frame[split..]);
        const message = (try framer.next()).?;
        defer a.free(message);
        try framer.feed("Content-Length: 2\r\n\r\n{}");
        try testing.expectEqualStrings(body, message);
        try expectMessage(&framer, "{}");
        try testing.expectEqual(@as(?[]u8, null), try framer.next());
        try framer.finish();
    }
}

test "framer: byte-at-a-time input and coalesced frames with partial next header" {
    const wire = "content-length:\t2 \t\r\nContent-Type: application/vscode-jsonrpc; charset=UTF-8\r\nX-Trace: test\r\n\r\n{}Content-Length: 2\r\n\r\n[]Content-Len";
    var slow = protocol.Framer.init(a);
    defer slow.deinit();
    var fast = protocol.Framer.init(a);
    defer fast.deinit();
    for (wire) |ch| try slow.feed(&.{ch});
    try fast.feed(wire);
    for ([_]*protocol.Framer{ &slow, &fast }) |framer| {
        try expectMessage(framer, "{}");
        try expectMessage(framer, "[]");
        try testing.expectEqual(@as(?[]u8, null), try framer.next());
        try framer.feed("gth: 4\r\n\r\nnull");
        try expectMessage(framer, "null");
        try framer.finish();
    }
}

test "framer: strict Content-Length and header validation, fail closed" {
    const Case = struct { wire: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .wire = "Content-Length: 2\r\ncontent-length: 2\r\n\r\n{}", .err = error.DuplicateContentLength },
        .{ .wire = "Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}", .err = error.DuplicateContentLength },
        .{ .wire = "X: y\r\n\r\n", .err = error.MissingContentLength },
        .{ .wire = "Content-Length: \r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 0\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: -1\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: +2\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 2.0\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 2e0\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 0x2\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 2 0\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 2,2\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 9999999999999999999999999999999\r\n\r\n", .err = error.InvalidContentLength },
        .{ .wire = "Content-Length: 4194305\r\n\r\n", .err = error.MessageTooLarge },
        .{ .wire = " Content-Length: 2\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length : 2\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\n\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\rX", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\r\n\tcontinued\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\x00\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\x7f\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\r\nX: é\r\n\r\n", .err = error.InvalidHeader },
        .{ .wire = "Content-Length: 2\r\nContent-Type: application/json; charset=latin1\r\n\r\n", .err = error.UnsupportedContentType },
        .{ .wire = "Content-Length: 2\r\nContent-Type: application/json\r\nContent-Type: application/json\r\n\r\n", .err = error.InvalidHeader },
    };
    for (cases) |case| {
        var framer = protocol.Framer.init(a);
        defer framer.deinit();
        // An invalid later frame must discard even earlier undelivered messages.
        try framer.feed("Content-Length: 2\r\n\r\n{}");
        try testing.expectError(case.err, framer.feed(case.wire));
        try expectPoisoned(&framer);
    }
}

test "framer: header limit includes delimiter and is enforced during fragmentation" {
    const prefix = "Content-Length: 2\r\nX: ";
    var header: [protocol.max_header_bytes]u8 = undefined;
    @memset(&header, 'a');
    @memcpy(header[0..prefix.len], prefix);
    @memcpy(header[header.len - 4 ..], "\r\n\r\n");
    var good = protocol.Framer.init(a);
    defer good.deinit();
    try good.feed(&header);
    try good.feed("{}");
    try expectMessage(&good, "{}");

    var bad = protocol.Framer.init(a);
    defer bad.deinit();
    try bad.feed(header[0 .. header.len - 4]);
    try testing.expectError(error.HeaderTooLarge, bad.feed("a\r\n\r\n"));
    try expectPoisoned(&bad);
    var unterminated = protocol.Framer.init(a);
    defer unterminated.deinit();
    @memset(&header, 'a');
    try testing.expectError(error.HeaderTooLarge, unterminated.feed(&header));
}

test "framer: maximum body succeeds, aggregate allocation budget and queue count bounded" {
    const body = try a.alloc(u8, protocol.max_message_bytes);
    defer a.free(body);
    @memset(body, 'a');
    body[0] = '"';
    body[body.len - 1] = '"';
    var framer = protocol.Framer.init(a);
    defer framer.deinit();
    try framer.feed("Content-Length: 4194304\r\n\r\n");
    try framer.feed(body[0..12345]);
    try framer.feed(body[12345..]);
    try expectMessage(&framer, body);
    try testing.expectEqual(@as(usize, 0), framer.retained);
    try framer.feed("Content-Length: 2\r\n\r\n{}");
    try testing.expectError(error.PendingLimitExceeded, framer.feed("Content-Length: 4194304\r\n\r\n"));
    try expectPoisoned(&framer);

    var many = protocol.Framer.init(a);
    defer many.deinit();
    for (0..protocol.max_pending_messages) |_| try many.feed("Content-Length: 2\r\n\r\n{}");
    try testing.expectError(error.PendingLimitExceeded, many.feed("Content-Length: 2\r\n\r\n{}"));
    try expectPoisoned(&many);
}

test "framer: no cumulative limit when caller drains; EOF distinguishes incomplete data" {
    var framer = protocol.Framer.init(a);
    defer framer.deinit();
    for (0..protocol.max_pending_messages * 3) |_| {
        try framer.feed("Content-Length: 2\r\n\r\n{}");
        try expectMessage(&framer, "{}");
    }
    try framer.finish();
    for ([_][]const u8{ "Content-Len", "Content-Length: 5\r\n\r\n{}" }) |partial| {
        var truncated = protocol.Framer.init(a);
        defer truncated.deinit();
        try truncated.feed(partial);
        try truncated.feed("");
        try testing.expectError(error.TruncatedFrame, truncated.finish());
        try expectPoisoned(&truncated);
    }
}

test "framer: invalid UTF-8 body is rejected only when assembled" {
    for ([_][]const u8{ "\xff", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82" }) |body| {
        const header = try std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n", .{body.len});
        defer a.free(header);
        var framer = protocol.Framer.init(a);
        defer framer.deinit();
        try framer.feed(header);
        try testing.expectError(error.InvalidUtf8, framer.feed(body));
        try expectPoisoned(&framer);
    }
}

test "JSON: depth limit before DOM allocation, strings and escapes do not affect depth" {
    var nested: [protocol.max_json_depth * 2 + 2]u8 = undefined;
    @memset(nested[0 .. protocol.max_json_depth + 1], '[');
    @memset(nested[protocol.max_json_depth + 1 ..], ']');
    var parsed = try protocol.parseMessage(a, nested[1 .. nested.len - 1]);
    parsed.deinit();
    try testing.expectError(error.JsonTooDeep, protocol.parseMessage(a, &nested));
    const header = try std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n", .{nested.len});
    defer a.free(header);
    var framer = protocol.Framer.init(a);
    defer framer.deinit();
    try framer.feed(header);
    try testing.expectError(error.JsonTooDeep, framer.feed(&nested));
    try expectPoisoned(&framer);
    var quoted = try protocol.parseMessage(a, "{\"x\":\"[[[{{{\\\"\\\\}}}]]]\"}");
    defer quoted.deinit();
    try testing.expectEqualStrings("[[[{{{\"\\}}}]]]", protocol.string(protocol.field(quoted.value, "x").?).?);
    try testing.expectError(error.InvalidJson, protocol.boundedJson("[", 10, 2));
    try testing.expectError(error.InvalidJson, protocol.boundedJson("}", 10, 2));
    try testing.expectError(error.InvalidJson, protocol.boundedJson("\"unterminated", 20, 2));
    try testing.expectError(error.MessageTooLarge, protocol.boundedJson("{}", 1, 2));
}

test "JSON: complete grammar, duplicate keys, helper types and independent string ownership" {
    const bad = [_][]const u8{ "", "[}", "{bad}", "{}{}", "{\"x\":1,\"x\":2}", "{\"x\":{\"y\":1,\"y\":2}}", "\"\\ud800\"", "\"\\udc00\"", "\"raw\nnewline\"" };
    for (bad) |bytes| {
        if (protocol.parseMessage(a, bytes)) |value| {
            value.deinit();
            return error.AcceptedInvalidJson;
        } else |_| {}
    }
    const source = try a.dupe(u8, "{\"text\":\"hello\",\"n\":-7,\"float\":1.5,\"id\":\"abc\"}");
    var parsed = try protocol.parseMessage(a, source);
    defer parsed.deinit();
    a.free(source);
    try testing.expectEqualStrings("hello", protocol.string(protocol.field(parsed.value, "text").?).?);
    try testing.expectEqual(@as(?i64, -7), protocol.integer(protocol.field(parsed.value, "n").?));
    try testing.expectEqual(@as(?i64, null), protocol.integer(protocol.field(parsed.value, "float").?));
    try testing.expect(protocol.string(protocol.field(parsed.value, "n").?) == null);
    try testing.expect(protocol.field(parsed.value, "missing") == null);
    try testing.expect(protocol.field(.null, "missing") == null);
    try testing.expectEqualStrings("abc", (try protocol.responseId(parsed.value)).string);
}

test "JSON-RPC: safe encoders preserve injected quotes and integer/string IDs" {
    const injected = "name\",\"id\":999,\"method\":\"evil\\\n😀";
    const request = try protocol.encodeRequest(a, .{ .string = injected }, injected, .{ .text = injected });
    defer a.free(request);
    var parsed = try protocol.parseMessage(a, request);
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", protocol.string(protocol.field(parsed.value, "jsonrpc").?).?);
    try testing.expectEqualStrings(injected, protocol.string(protocol.field(parsed.value, "method").?).?);
    try testing.expectEqualStrings(injected, (try protocol.responseId(parsed.value)).string);
    try testing.expectEqualStrings(injected, protocol.string(protocol.field(protocol.field(parsed.value, "params").?, "text").?).?);

    const notification = try protocol.encodeNotification(a, "initialized", .{});
    defer a.free(notification);
    var n = try protocol.parseMessage(a, notification);
    defer n.deinit();
    try testing.expect(protocol.field(n.value, "id") == null);

    for ([_]i64{ std.math.minInt(i64), -1, 0, std.math.maxInt(i64) }) |id| {
        const response = try protocol.encodeResponse(a, .{ .integer = id }, .{ .text = injected });
        defer a.free(response);
        var r = try protocol.parseMessage(a, response);
        defer r.deinit();
        try testing.expectEqual(id, (try protocol.responseId(r.value)).integer);
        try testing.expect(protocol.field(r.value, "error") == null);
    }
    const response = try protocol.encodeErrorResponse(a, .{ .string = "id" }, -32602, injected, null);
    defer a.free(response);
    var e = try protocol.parseMessage(a, response);
    defer e.deinit();
    try testing.expectEqualStrings(injected, protocol.string(protocol.field(protocol.field(e.value, "error").?, "message").?).?);
    try testing.expect(protocol.field(e.value, "result") == null);
    try testing.expectError(error.InvalidId, protocol.encodeResponse(a, .{ .string = "\xff" }, null));
    try testing.expectError(error.InvalidUtf8, protocol.encodeNotification(a, "\xff", null));
}

test "JSON-RPC: response IDs are never coerced" {
    for ([_][]const u8{ "{}", "null", "{\"id\":null}", "{\"id\":true}", "{\"id\":{}}", "{\"id\":[]}", "{\"id\":1.5}", "{\"id\":1e0}", "{\"id\":9223372036854775808}" }) |body| {
        var parsed = try protocol.parseMessage(a, body);
        defer parsed.deinit();
        try testing.expectError(error.InvalidId, protocol.responseId(parsed.value));
    }
}

test "positions: emoji, combining marks, and CRLF in all encodings" {
    const text = "a😀é\r\nβ\n";
    const Case = struct { byte: usize, line: u32, columns: [3]u32 };
    const cases = [_]Case{
        .{ .byte = 0, .line = 0, .columns = .{ 0, 0, 0 } },
        .{ .byte = 1, .line = 0, .columns = .{ 1, 1, 1 } },
        .{ .byte = 5, .line = 0, .columns = .{ 5, 3, 2 } },
        .{ .byte = 6, .line = 0, .columns = .{ 6, 4, 3 } },
        .{ .byte = 8, .line = 0, .columns = .{ 8, 5, 4 } },
        .{ .byte = 10, .line = 1, .columns = .{ 0, 0, 0 } },
        .{ .byte = 12, .line = 1, .columns = .{ 2, 1, 1 } },
        .{ .byte = 13, .line = 2, .columns = .{ 0, 0, 0 } },
    };
    for ([_]positions.Encoding{ .utf8, .utf16, .utf32 }, 0..) |encoding, i| {
        for (cases) |case| {
            const pos: positions.Position = .{ .line = case.line, .character = case.columns[i] };
            try testing.expectEqual(case.byte, try positions.byteOffset(text, pos, encoding));
            try testing.expectEqual(pos, try positions.positionAt(text, case.byte, encoding));
        }
        for ([_]usize{ 2, 3, 4, 7, 9, 11 }) |byte| try testing.expectError(error.InvalidBoundary, positions.positionAt(text, byte, encoding));
        try testing.expectError(error.OutOfRange, positions.positionAt(text, text.len + 1, encoding));
        try testing.expectError(error.OutOfRange, positions.byteOffset(text, .{ .line = 3, .character = 0 }, encoding));
        try testing.expectError(error.OutOfRange, positions.byteOffset(text, .{ .line = 0, .character = 100 }, encoding));
    }
    try testing.expectError(error.InvalidBoundary, positions.byteOffset(text, .{ .line = 0, .character = 2 }, .utf16));
    for ([_]u32{ 2, 3, 4, 7 }) |column| try testing.expectError(error.InvalidBoundary, positions.byteOffset(text, .{ .line = 0, .character = column }, .utf8));
}

test "positions: empty lines, bare CR, newline boundaries, range order and invalid text" {
    const zero: positions.Position = .{ .line = 0, .character = 0 };
    try testing.expectEqual(@as(usize, 0), try positions.byteOffset("", zero, .utf16));
    try testing.expectEqual(zero, try positions.positionAt("", 0, .utf8));
    try testing.expectError(error.OutOfRange, positions.byteOffset("", .{ .line = 1, .character = 0 }, .utf32));
    const text = "\r\n\n\rx";
    for ([_]usize{ 0, 2, 3, 4 }, 0..) |byte, line| {
        const pos: positions.Position = .{ .line = @intCast(line), .character = 0 };
        try testing.expectEqual(byte, try positions.byteOffset(text, pos, .utf16));
        try testing.expectEqual(pos, try positions.positionAt(text, byte, .utf16));
    }
    const end: positions.Position = .{ .line = 3, .character = 1 };
    try testing.expectEqual(positions.ByteRange{ .start = 0, .end = 5 }, try positions.byteRange(text, .{ .start = zero, .end = end }, .utf16));
    try testing.expectEqual(positions.ByteRange{ .start = 5, .end = 5 }, try positions.byteRange(text, .{ .start = end, .end = end }, .utf16));
    try testing.expectError(error.ReversedRange, positions.byteRange(text, .{ .start = end, .end = zero }, .utf16));
    try testing.expectError(error.ReversedRange, positions.byteRange("ab", .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 1 } }, .utf8));
    for ([_][]const u8{ "\xff", "a\xc0\xaf", "\xed\xa0\x80", "\xf0\x9f" }) |invalid| {
        try testing.expectError(error.InvalidUtf8, positions.byteOffset(invalid, zero, .utf16));
        try testing.expectError(error.InvalidUtf8, positions.positionAt(invalid, 0, .utf8));
    }
}

test "URI: canonical percent-encoded UTF-8 round trip, literal shell syntax, normalization" {
    const Case = struct { path: []const u8, encoded: []const u8, normalized: []const u8 };
    const cases = [_]Case{
        .{ .path = "/", .encoded = "file:///", .normalized = "/" },
        .{ .path = "/tmp/a b#?%😀é", .encoded = "file:///tmp/a%20b%23%3F%25%F0%9F%98%80e%CC%81", .normalized = "/tmp/a b#?%😀é" },
        .{ .path = "/a//b/./c/../", .encoded = "file:///a/b", .normalized = "/a/b" },
        .{ .path = "/a/..", .encoded = "file:///", .normalized = "/" },
        .{ .path = "/$HOME/$(touch x);'\"`\n", .encoded = "file:///%24HOME/%24%28touch%20x%29%3B%27%22%60%0A", .normalized = "/$HOME/$(touch x);'\"`\n" },
        .{ .path = "/a-._~:b@c", .encoded = "file:///a-._~%3Ab%40c", .normalized = "/a-._~:b@c" },
    };
    for (cases) |case| {
        const encoded = try uri.fromPath(a, case.path);
        defer a.free(encoded);
        try testing.expectEqualStrings(case.encoded, encoded);
        const decoded = try uri.toPath(a, encoded);
        defer a.free(decoded);
        try testing.expectEqualStrings(case.normalized, decoded);
    }
    for ([_][]const u8{ "file:/a/b", "file:///a/b", "FILE://LOCALHOST/a/b", "file:///a/%62", "file:///a/c/%2e%2e/b", "file:////a//b/" }) |input| {
        const path = try uri.toPath(a, input);
        defer a.free(path);
        try testing.expectEqualStrings("/a/b", path);
    }
    const once = try uri.toPath(a, "file:///%252F");
    defer a.free(once);
    try testing.expectEqualStrings("/%2F", once);
}

test "URI: reject remote authority, invalid encoding, NUL, separators and traversal above root" {
    const Case = struct { input: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .input = "https:///tmp/a", .err = error.InvalidScheme },
        .{ .input = "file:relative", .err = error.NotAbsolute },
        .{ .input = "file://", .err = error.NotAbsolute },
        .{ .input = "file://server/a", .err = error.RemoteHost },
        .{ .input = "file://127.0.0.1/a", .err = error.RemoteHost },
        .{ .input = "file://localhost:80/a", .err = error.RemoteHost },
        .{ .input = "file://user@localhost/a", .err = error.RemoteHost },
        .{ .input = "file://local%68ost/a", .err = error.RemoteHost },
        .{ .input = "file:///a?query", .err = error.InvalidUri },
        .{ .input = "file:///a#fragment", .err = error.InvalidUri },
        .{ .input = "file:///a b", .err = error.InvalidUri },
        .{ .input = "file:///é", .err = error.InvalidUri },
        .{ .input = "file:///a\\b", .err = error.InvalidUri },
        .{ .input = "file:///a%", .err = error.InvalidEscape },
        .{ .input = "file:///a%2", .err = error.InvalidEscape },
        .{ .input = "file:///a%gg", .err = error.InvalidEscape },
        .{ .input = "file:///a%2fb", .err = error.EncodedSeparator },
        .{ .input = "file:///a%5Cb", .err = error.EncodedSeparator },
        .{ .input = "file:///a%00b", .err = error.EmbeddedNul },
        .{ .input = "file:///a\x00b", .err = error.EmbeddedNul },
        .{ .input = "file:///%FF", .err = error.InvalidUtf8 },
        .{ .input = "file:///%C0%AF", .err = error.InvalidUtf8 },
        .{ .input = "file:///%ED%A0%80", .err = error.InvalidUtf8 },
        .{ .input = "file:///%F4%90%80%80", .err = error.InvalidUtf8 },
        .{ .input = "file:///../a", .err = error.PathEscapesRoot },
        .{ .input = "file:///%2e%2e/a", .err = error.PathEscapesRoot },
        .{ .input = "file:///a/../../b", .err = error.PathEscapesRoot },
    };
    for (cases) |case| try testing.expectError(case.err, uri.toPath(a, case.input));
    try testing.expectError(error.NotAbsolute, uri.fromPath(a, "relative"));
    try testing.expectError(error.NotAbsolute, uri.fromPath(a, ""));
    try testing.expectError(error.EmbeddedNul, uri.fromPath(a, "/a\x00b"));
    try testing.expectError(error.InvalidUtf8, uri.fromPath(a, "/\xff"));
    try testing.expectError(error.InvalidPath, uri.fromPath(a, "/a\\b"));
    try testing.expectError(error.PathEscapesRoot, uri.fromPath(a, "/../a"));
}

fn allocationRoundTrip(allocator: std.mem.Allocator) !void {
    const body = try protocol.encodeRequest(allocator, .{ .string = "id" }, "example", .{ .text = "😀" });
    defer allocator.free(body);
    const wire = try protocol.encodeFrame(allocator, body);
    defer allocator.free(wire);
    var framer = protocol.Framer.init(allocator);
    defer framer.deinit();
    framer.feed(wire) catch |err| {
        try expectPoisoned(&framer);
        return err;
    };
    const message = (try framer.next()).?;
    defer allocator.free(message);
    var parsed = try protocol.parseMessage(allocator, message);
    defer parsed.deinit();
    const encoded = try uri.fromPath(allocator, "/a b/😀/../c");
    defer allocator.free(encoded);
    const decoded = try uri.toPath(allocator, encoded);
    defer allocator.free(decoded);
    try testing.expectEqualStrings("/a b/c", decoded);
}

test "allocation failures: framing, JSON, encoding and URI clean up every allocation" {
    try testing.checkAllAllocationFailures(a, allocationRoundTrip, .{});
}
