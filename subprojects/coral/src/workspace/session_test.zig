//! Standalone backend tests: zig test src/session_tests.zig -lc
//! Separate from GTK/GIO worker tests because publication tests fork.
const std = @import("std");
const model = @import("session_model.zig");
const fs = @import("session_fs.zig");
const recovery = @import("recovery_model.zig");
const Fixture = @import("manifest_test_support.zig").Fixture;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const bytesEqual = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
extern "c" fn alarm(seconds: c_uint) c_uint;

const sample: model.Value = .{
    .snapshot = .{
        .documents = &.{
            .{ .id = 7, .path = "/work/日本語\xff.txt", .text = "雪😀\r\n\x00\xff", .bom = true, .newline = .crlf, .revision = 42, .saved_etag = "old-etag" },
            .{ .id = 8, .text = "untitled\nΔ", .revision = 9 },
        },
        .groups = &.{.{ .path = "root", .active_view = 10 }},
        .views = &.{.{ .id = 10, .document_id = 7, .group_path = "root", .anchor = 4, .cursor = 0, .excerpt_start = 3, .excerpt_end = 7, .scroll_x = 19.5 }},
        .active_group = "root",
    },
    .workspace = .{ .source = .manifest, .path = "/work/\xff.coral", .roots = &.{
        .{ .path = "/work/\xfe", .name = "日本語" },
        .{ .path = "/offline/root", .name = "not opened by backend" },
    } },
};
const newer: model.Value = .{ .snapshot = .{ .documents = &.{.{ .id = 1, .text = "new explicit checkpoint" }} } };

fn expectSample(value: model.Value) !void {
    const encoded = try model.encode(a, value);
    defer a.free(encoded);
    const wanted = try model.encode(a, sample);
    defer a.free(wanted);
    try bytesEqual(wanted, encoded);
}
fn frame(header: []const u8, payload: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    return std.fmt.allocPrint(a, "{s}{s}\n{s}", .{ header, std.fmt.bytesToHex(hash, .lower), payload });
}
fn wire(json: []const u8, snapshot: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(a, "{s}\n{s}", .{ json, snapshot });
    defer a.free(payload);
    return frame("CORAL-SESSION 1\n", payload);
}

const Home = struct {
    fixture: Fixture,
    state: [:0]u8,
    fn init() !Home {
        var f = try Fixture.init();
        errdefer f.deinit();
        try f.mkdir("state");
        return .{ .fixture = f, .state = try f.path("state") };
    }
    fn path(self: *const Home, suffix: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.state, suffix }, 0);
    }
    fn deinit(self: *Home) void {
        // Only known test entries, never recursive cleanup or symlink traversal.
        for ([_][]const u8{ "coral/sessions/pending", "coral/sessions/current", "coral/sessions", "coral" }) |suffix| {
            const p = self.path(suffix) catch unreachable;
            defer a.free(p);
            _ = std.c.unlink(p);
            _ = std.c.rmdir(p);
        }
        a.free(self.state);
        self.fixture.deinit();
    }
    fn overwrite(self: *Home, bytes: []const u8) !void {
        const p = try self.path("coral/sessions/current");
        defer a.free(p);
        const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true });
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try expect(n > 0);
            offset += @intCast(n);
        }
    }
    fn read(self: *Home) ![]u8 {
        const p = try self.path("coral/sessions/current");
        defer a.free(p);
        const fd = std.c.open(p, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
        try expect(fd >= 0);
        defer _ = std.c.close(fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = std.c.read(fd, &buffer, buffer.len);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            try expect(n >= 0);
            if (n == 0) return out.toOwnedSlice(a);
            try out.appendSlice(a, buffer[0..@intCast(n)]);
            try expect(out.items.len <= model.limits.session_bytes);
        }
    }
};
fn chmod(path: [:0]const u8, mode: std.c.mode_t) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.fchmod(fd, mode));
}

test "explicit session owns and roundtrips binary paths, metadata, excerpts and untitled bytes" {
    const encoded = try model.encode(a, sample);
    defer a.free(encoded);
    try expect(std.mem.startsWith(u8, encoded, "CORAL-SESSION 2\n"));
    try expect(std.mem.indexOf(u8, encoded, "\nCORAL-RECOVERY 2\n") != null);
    try expect(std.mem.indexOf(u8, encoded, sample.workspace.?.path) == null);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try expectSample(decoded.value);
    const owned = try model.Owned.create(sample);
    defer owned.deinit();
    try expectSample(owned.value);
    try expect(owned.value.snapshot.documents[0].text.ptr != sample.snapshot.documents[0].text.ptr);
    try expect(owned.value.workspace.?.path.ptr != sample.workspace.?.path.ptr);
    try expect(owned.value.workspace.?.roots[0].name.ptr != sample.workspace.?.roots[0].name.ptr);
    var folder = sample;
    folder.workspace.?.source = .folder;
    const folder_bytes = try model.encode(a, folder);
    defer a.free(folder_bytes);
    const folder_owned = try model.decode(folder_bytes);
    defer folder_owned.deinit();
    try equal(.folder, folder_owned.value.workspace.?.source);
}

test "v2 preserves desired dock state and v1 migrates to defaults" {
    var value = sample;
    value.layout = .{ .explorer = .right, .search = .left, .source_control = .bottom, .terminal = .right, .agent = .bottom, .explorer_visible = false, .search_visible = true, .source_control_visible = true, .terminal_visible = true, .agent_visible = true, .active = .source_control, .left_size = 455, .right_size = 521, .bottom_size = 309 };
    const encoded = try model.encode(a, value);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(value.layout, decoded.value.layout);
    const owned = try model.Owned.create(value);
    defer owned.deinit();
    try std.testing.expectEqualDeep(value.layout, owned.value.layout);
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    const legacy = try wire("{\"workspace\":null}", snapshot);
    defer a.free(legacy);
    const migrated = try model.decode(legacy);
    defer migrated.deinit();
    try std.testing.expectEqualDeep(model.layout.State{}, migrated.value.layout);
    const upgraded = try model.encode(a, migrated.value);
    defer a.free(upgraded);
    try expect(std.mem.startsWith(u8, upgraded, "CORAL-SESSION 2\n"));
}

test "v2 sessions written before source control decode its fields with defaults" {
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    // Exact descriptor shape persisted before the Source Control dock existed.
    const old_layout = "{\"explorer\":\"right\",\"search\":\"left\",\"explorer_visible\":false,\"search_visible\":true,\"active\":\"search\",\"left_size\":455,\"right_size\":521,\"bottom_size\":309}";
    const payload = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{s}}}\n{s}", .{ old_layout, snapshot });
    defer a.free(payload);
    const encoded = try frame("CORAL-SESSION 2\n", payload);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{
        .explorer = .right,
        .search = .left,
        .source_control = .left,
        .explorer_visible = false,
        .search_visible = true,
        .source_control_visible = false,
        .active = .search,
        .left_size = 455,
        .right_size = 521,
        .bottom_size = 309,
    }, decoded.value.layout);
    // Re-encoding publishes the defaulted fields without changing the old ones.
    const upgraded = try model.encode(a, decoded.value);
    defer a.free(upgraded);
    const reparsed = try model.decode(upgraded);
    defer reparsed.deinit();
    try std.testing.expectEqualDeep(decoded.value.layout, reparsed.value.layout);
    // A descriptor carrying only the new fields keeps every other default.
    const partial = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{{\"source_control\":\"right\",\"source_control_visible\":true,\"active\":\"source_control\"}}}}\n{s}", .{snapshot});
    defer a.free(partial);
    const partial_encoded = try frame("CORAL-SESSION 2\n", partial);
    defer a.free(partial_encoded);
    const partial_decoded = try model.decode(partial_encoded);
    defer partial_decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{ .source_control = .right, .source_control_visible = true, .active = .source_control }, partial_decoded.value.layout);
}

test "v2 sessions written before terminal decode its fields with defaults" {
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    // Exact descriptor shape persisted before the Terminal dock existed.
    const old_layout = "{\"explorer\":\"left\",\"search\":\"bottom\",\"source_control\":\"left\",\"explorer_visible\":true,\"search_visible\":false,\"source_control_visible\":false,\"active\":\"explorer\",\"left_size\":222,\"right_size\":320,\"bottom_size\":240}";
    const payload = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{s}}}\n{s}", .{ old_layout, snapshot });
    defer a.free(payload);
    const encoded = try frame("CORAL-SESSION 2\n", payload);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{}, decoded.value.layout);
    try std.testing.expectEqual(model.layout.Dock.bottom, decoded.value.layout.terminal);
    try std.testing.expectEqual(false, decoded.value.layout.terminal_visible);
    // A descriptor carrying only the terminal fields keeps every other default.
    const partial = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{{\"terminal\":\"right\",\"terminal_visible\":true,\"active\":\"terminal\"}}}}\n{s}", .{snapshot});
    defer a.free(partial);
    const partial_encoded = try frame("CORAL-SESSION 2\n", partial);
    defer a.free(partial_encoded);
    const partial_decoded = try model.decode(partial_encoded);
    defer partial_decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{ .terminal = .right, .terminal_visible = true, .active = .terminal }, partial_decoded.value.layout);
}

test "v2 sessions written before agent decode its fields with defaults" {
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    // Exact descriptor shape persisted before the Agent dock existed.
    const old_layout = "{\"explorer\":\"left\",\"search\":\"bottom\",\"source_control\":\"left\",\"terminal\":\"bottom\",\"explorer_visible\":true,\"search_visible\":false,\"source_control_visible\":false,\"terminal_visible\":false,\"active\":\"explorer\",\"left_size\":222,\"right_size\":320,\"bottom_size\":240}";
    const payload = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{s}}}\n{s}", .{ old_layout, snapshot });
    defer a.free(payload);
    const encoded = try frame("CORAL-SESSION 2\n", payload);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{}, decoded.value.layout);
    try std.testing.expectEqual(model.layout.Dock.right, decoded.value.layout.agent);
    try std.testing.expectEqual(false, decoded.value.layout.agent_visible);
    // A descriptor carrying only the agent fields keeps every other default.
    const partial = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{{\"agent\":\"left\",\"agent_visible\":true,\"active\":\"agent\"}}}}\n{s}", .{snapshot});
    defer a.free(partial);
    const partial_encoded = try frame("CORAL-SESSION 2\n", partial);
    defer a.free(partial_encoded);
    const partial_decoded = try model.decode(partial_encoded);
    defer partial_decoded.deinit();
    try std.testing.expectEqualDeep(model.layout.State{ .agent = .left, .agent_visible = true, .active = .agent }, partial_decoded.value.layout);
}

test "v2 requires valid bounded layout and v1 refuses future layout fields" {
    const snapshot = try recovery.encode(a, newer.snapshot);
    defer a.free(snapshot);
    for ([_][]const u8{
        "{\"workspace\":null}",
        "{\"workspace\":null,\"layout\":null}",
        "{\"workspace\":null,\"layout\":{\"explorer\":\"floating\"}}",
        "{\"workspace\":null,\"layout\":{\"source_control\":\"floating\"}}",
        "{\"workspace\":null,\"layout\":{\"source_control_visible\":\"yes\"}}",
        "{\"workspace\":null,\"layout\":{\"agent\":\"floating\"}}",
        "{\"workspace\":null,\"layout\":{\"agent_visible\":\"yes\"}}",
        "{\"workspace\":null,\"layout\":{\"active\":\"debug\"}}",
        "{\"workspace\":null,\"layout\":{\"trust\":true}}",
        "{\"workspace\":null,\"layout\":{\"left_size\":-1}}",
        "{\"workspace\":null,\"layout\":{},\"layout\":{}}",
    }) |json| {
        const payload = try std.fmt.allocPrint(a, "{s}\n{s}", .{ json, snapshot });
        defer a.free(payload);
        const encoded = try frame("CORAL-SESSION 2\n", payload);
        defer a.free(encoded);
        try expectError(error.CorruptSession, model.decode(encoded));
    }
    const legacy_extra = try wire("{\"workspace\":null,\"layout\":{}}", snapshot);
    defer a.free(legacy_extra);
    try expectError(error.CorruptSession, model.decode(legacy_extra));
    var invalid = newer;
    invalid.layout.left_size = 119;
    try expectError(error.InvalidLayout, model.encode(a, invalid));
    try expectError(error.InvalidLayout, model.Owned.create(invalid));
    const payload = try std.fmt.allocPrint(a, "{{\"workspace\":null,\"layout\":{{\"bottom_size\":1001}}}}\n{s}", .{snapshot});
    defer a.free(payload);
    const encoded = try frame("CORAL-SESSION 2\n", payload);
    defer a.free(encoded);
    try expectError(error.InvalidLayout, model.decode(encoded));
}

test "strict version, checksum, schema, required fields and base64" {
    const encoded = try model.encode(a, sample);
    defer a.free(encoded);
    encoded[encoded.len - 1] ^= 1;
    try expectError(error.CorruptSession, model.decode(encoded));
    encoded["CORAL-SESSION ".len] = '9';
    try expectError(error.UnsupportedVersion, model.decode(encoded));
    try expectError(error.CorruptSession, model.decode("not a session"));
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    for ([_][]const u8{
        "{}",
        "{\"workspace\":null,\"trust\":true}",
        "{\"workspace\":null,\"workspace\":null}",
        "{\"workspace\":{\"source\":\"folder\",\"path\":\"L3g=\",\"roots\":[],\"secret\":\"no\"}}",
        "{\"workspace\":{\"source\":\"other\",\"path\":\"L3g=\",\"roots\":[]}}",
        "{\"workspace\":{\"source\":\"folder\",\"path\":\"!\",\"roots\":[]}}",
        "{\"workspace\":{\"source\":\"folder\",\"path\":\"L3g=\",\"roots\":[{\"path\":\"L3g=\"}]}}",
    }) |json| {
        const bytes = try wire(json, snapshot);
        defer a.free(bytes);
        try expectError(error.CorruptSession, model.decode(bytes));
    }
    // Valid outer checksum cannot hide invalid or future recovery payloads.
    snapshot[snapshot.len - 1] ^= 1;
    const corrupt_inner = try wire("{\"workspace\":null}", snapshot);
    defer a.free(corrupt_inner);
    try expectError(error.CorruptManifest, model.decode(corrupt_inner));
    snapshot["CORAL-RECOVERY ".len] = '9';
    const future_inner = try wire("{\"workspace\":null}", snapshot);
    defer a.free(future_inner);
    try expectError(error.UnsupportedVersion, model.decode(future_inner));
}

test "workspace descriptor dot components roundtrip without lexical normalization" {
    for ([_][]const u8{ "/config/../one", "/root/.", "/root/./child", "/link/../\xff", "/./.." }) |path| {
        inline for (.{ .folder, .manifest }) |source| {
            var value = sample;
            value.workspace = .{ .source = source, .path = path, .roots = &.{.{ .path = path, .name = "lexical root" }} };
            const owned = try model.Owned.create(value);
            defer owned.deinit();
            try bytesEqual(path, owned.value.workspace.?.path);
            try bytesEqual(path, owned.value.workspace.?.roots[0].path);
            const encoded = try model.encode(a, owned.value);
            defer a.free(encoded);
            const decoded = try model.decode(encoded);
            defer decoded.deinit();
            try bytesEqual(path, decoded.value.workspace.?.path);
            try bytesEqual(path, decoded.value.workspace.?.roots[0].path);
        }
    }
}

test "dot components remain invalid in document and session storage paths" {
    for ([_][]const u8{ "/config/../one", "/root/." }) |path| {
        var value = newer;
        value.snapshot.documents = &.{.{ .id = 1, .path = path, .text = "document" }};
        try expectError(error.InvalidPath, model.Owned.create(value));
        try expectError(error.InvalidPath, model.encode(a, value));
    }
    var h = try Home.init();
    defer h.deinit();
    for ([_][]const u8{ ".", "../state" }) |suffix| {
        const path = try h.path(suffix);
        defer a.free(path);
        try expectError(error.InvalidPath, fs.load(path));
        try expectError(error.InvalidPath, fs.save(path, sample));
    }
}

test "root, native path and UTF-8 name limits apply to create encode and decode" {
    var roots: [33]model.Root = @splat(.{ .path = "/x", .name = "x" });
    var value = sample;
    value.workspace.?.roots = &roots;
    try expectError(error.TooLarge, model.Owned.create(value));
    try expectError(error.TooLarge, model.encode(a, value));
    const long = try a.alloc(u8, 4097);
    defer a.free(long);
    @memset(long, 'a');
    long[0] = '/';
    value = sample;
    const valid_snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(valid_snapshot);
    for ([_][]const u8{ "", "relative", "../one", ".", "file:///x", "/x\x00y" }) |path| {
        const base64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(path.len));
        defer a.free(base64);
        _ = std.base64.standard.Encoder.encode(base64, path);
        for ([_]bool{ true, false }) |workspace_path| {
            var invalid = sample;
            if (workspace_path) {
                invalid.workspace.?.path = path;
            } else {
                invalid.workspace.?.roots = &.{.{ .path = path, .name = "valid" }};
            }
            try expectError(error.InvalidPath, model.Owned.create(invalid));
            try expectError(error.InvalidPath, model.encode(a, invalid));
            const json = try std.json.Stringify.valueAlloc(a, .{ .workspace = .{
                .source = "manifest",
                .path = if (workspace_path) base64 else "L3g=",
                .roots = [_]model.Root{.{ .path = if (workspace_path) "L3g=" else base64, .name = "valid" }},
            } }, .{});
            defer a.free(json);
            const bytes = try wire(json, valid_snapshot);
            defer a.free(bytes);
            try expectError(error.InvalidPath, model.decode(bytes));
        }
    }
    value.workspace.?.path = long;
    try expectError(error.TooLarge, model.encode(a, value));
    value.workspace.?.path = "/x";
    value.workspace.?.roots = &.{.{ .path = long, .name = "valid" }};
    try expectError(error.TooLarge, model.Owned.create(value));
    value.workspace.?.roots = &.{.{ .path = "/x", .name = "\xff" }};
    try expectError(error.InvalidWorkspace, model.Owned.create(value));
    value.workspace.?.roots = &.{.{ .path = "/x", .name = long }};
    try expectError(error.TooLarge, model.encode(a, value));
    // Inclusive caps, including worst-case six-byte JSON escaping of names.
    const name = try a.alloc(u8, model.limits.name_bytes);
    defer a.free(name);
    @memset(name, 1);
    for (roots[0..32]) |*root| root.* = .{ .path = long[0..4096], .name = name };
    value.workspace.?.path = long[0..4096];
    value.workspace.?.roots = roots[0..32];
    const encoded = try model.encode(a, value);
    defer a.free(encoded);
    const decoded = try model.decode(encoded);
    defer decoded.deinit();
    try equal(@as(usize, 32), decoded.value.workspace.?.roots.len);
    try bytesEqual(long[0..4096], decoded.value.workspace.?.roots[31].path);
    try bytesEqual(name, decoded.value.workspace.?.roots[31].name);
    const snapshot = try recovery.encode(a, newer.snapshot);
    defer a.free(snapshot);
    const many: [33]model.Root = @splat(.{ .path = "L3g=", .name = "x" });
    const json = try std.json.Stringify.valueAlloc(a, .{ .workspace = .{ .source = "folder", .path = "L3g=", .roots = many } }, .{});
    defer a.free(json);
    const excessive_roots = try wire(json, snapshot);
    defer a.free(excessive_roots);
    try expectError(error.TooLarge, model.decode(excessive_roots));
    const b64path = try a.alloc(u8, std.base64.standard.Encoder.calcSize(long.len));
    defer a.free(b64path);
    _ = std.base64.standard.Encoder.encode(b64path, long);
    const long_json = try std.json.Stringify.valueAlloc(a, .{ .workspace = .{ .source = "folder", .path = b64path, .roots = .{} } }, .{});
    defer a.free(long_json);
    const excessive_path = try wire(long_json, snapshot);
    defer a.free(excessive_path);
    try expectError(error.TooLarge, model.decode(excessive_path));
}

test "malformed selection and excerpt offsets are refused even with valid checksums" {
    var views = [_]recovery.View{sample.snapshot.views[0]};
    var value = sample;
    value.snapshot.views = &views;
    views[0].cursor = 5;
    try expectError(error.InvalidSnapshot, model.Owned.create(value));
    views[0].cursor = 1; // Inside the emoji continuation bytes in the excerpt.
    try expectError(error.InvalidSnapshot, model.encode(a, value));
    // recovery.encode accepts in-bounds selections; session validates boundaries.
    const snapshot = try recovery.encode(a, value.snapshot);
    defer a.free(snapshot);
    const bytes = try wire("{\"workspace\":null}", snapshot);
    defer a.free(bytes);
    try expectError(error.InvalidSnapshot, model.decode(bytes));
    views[0].cursor = 0;
    views[0].excerpt_start = 4;
    try expectError(error.InvalidSnapshot, model.encode(a, value));
    views[0].excerpt_start = 7;
    views[0].excerpt_end = 3;
    try expectError(error.InvalidSnapshot, model.Owned.create(value));
    const bad_json = "{\"documents\":[{\"id\":1,\"path\":null,\"text\":\"eA==\",\"dirty\":true,\"bom\":false,\"newline\":\"lf\",\"revision\":0,\"saved_etag\":null}],\"groups\":[{\"path\":\"root\"}],\"views\":[{\"id\":1,\"document_id\":1,\"group_path\":\"root\",\"cursor\":18446744073709551615}],\"active_group\":null}";
    const bad_recovery = try frame("CORAL-RECOVERY 2\n", bad_json);
    defer a.free(bad_recovery);
    const malformed = try wire("{\"workspace\":null}", bad_recovery);
    defer a.free(malformed);
    try expectError(error.InvalidSnapshot, model.decode(malformed));
}

test "missing load is read-only; save requires existing state home; slots are independent" {
    var h = try Home.init();
    defer h.deinit();
    try expectError(error.NotFound, fs.load(h.state));
    const coral = try h.path("coral");
    defer a.free(coral);
    try expect(std.c.open(coral, .{ .PATH = true, .NOFOLLOW = true }) < 0);
    const missing = try h.path("does-not-exist");
    defer a.free(missing);
    try expectError(error.MissingStateHome, fs.save(missing, sample));
    try expectError(error.NotFound, fs.load(missing));
    try fs.save(h.state, sample);
    const loaded = try fs.load(h.state);
    defer loaded.deinit();
    try expectSample(loaded.value);
    try h.fixture.mkdir("state/coral/recovery");
    try h.fixture.write("state/coral/recovery/evidence", "never touch recovery");
    try fs.save(h.state, newer);
    const after = try fs.load(h.state);
    defer after.deinit();
    try bytesEqual(newer.snapshot.documents[0].text, after.value.snapshot.documents[0].text);
    try expect(after.value.workspace == null);
    // Remove fixture-owned recovery entries before Home removes coral.
    while (h.fixture.entries.items.len > 1) {
        const entry = h.fixture.entries.pop().?;
        defer a.free(entry.path);
        try equal(@as(c_int, 0), if (entry.directory) std.c.rmdir(entry.path) else std.c.unlink(entry.path));
    }
}

test "atomic failures preserve old checkpoint; postrename reports uncertain committed checkpoint" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    for ([_]fs.Fault{ .during_write, .before_rename }) |fault| {
        try expectError(error.InjectedFailure, fs.saveWithHooks(h.state, newer, .{ .fault = fault }));
        const old = try fs.load(h.state);
        defer old.deinit();
        try expectSample(old.value);
    }
    try expectError(error.DurabilityUncertain, fs.saveWithHooks(h.state, newer, .{ .fault = .after_rename }));
    const new = try fs.load(h.state);
    defer new.deinit();
    try bytesEqual(newer.snapshot.documents[0].text, new.value.snapshot.documents[0].text);
}

test "directory flock excludes writers and readers across current renames" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    const dir = try h.path("coral/sessions");
    defer a.free(dir);
    const fd = std.c.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB));
    try expectError(error.Busy, fs.save(h.state, newer));
    try expectError(error.Busy, fs.load(h.state));
    try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.UN));
    try fs.save(h.state, newer);
    try equal(@as(c_int, 0), std.c.flock(fd, std.c.LOCK.SH | std.c.LOCK.NB));
    try expectError(error.Busy, fs.save(h.state, sample));
    const loaded = try fs.load(h.state);
    defer loaded.deinit();
    try bytesEqual(newer.snapshot.documents[0].text, loaded.value.snapshot.documents[0].text);
}

test "corrupt future and oversized current files are preserved on both load and save" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    inline for (.{ .{ "corrupt evidence", error.CorruptSession }, .{ "CORAL-SESSION 99\nfuture evidence", error.UnsupportedVersion } }) |case| {
        try h.overwrite(case[0]);
        try expectError(case[1], fs.load(h.state));
        try expectError(case[1], fs.save(h.state, newer));
        const kept = try h.read();
        defer a.free(kept);
        try bytesEqual(case[0], kept);
    }
    const p = try h.path("coral/sessions/current");
    defer a.free(p);
    const fd = std.c.open(p, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try equal(@as(c_int, 0), std.c.ftruncate(fd, model.limits.session_bytes + 1));
    try expectError(error.TooLarge, fs.load(h.state));
    try expectError(error.TooLarge, fs.save(h.state, newer));
    var st: std.os.linux.Statx = undefined;
    try equal(@as(c_int, 0), std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st));
    try equal(@as(u64, model.limits.session_bytes + 1), st.size);
}

test "private permissions and regular single-link files are required" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    for ([_][]const u8{ "coral", "coral/sessions", "coral/sessions/current" }) |suffix| {
        const p = try h.path(suffix);
        defer a.free(p);
        const is_file = std.mem.endsWith(u8, suffix, "current");
        try chmod(p, if (is_file) 0o640 else 0o750);
        const err = if (is_file) error.UnsafeFile else error.UnsafeDirectory;
        try expectError(err, fs.load(h.state));
        try expectError(err, fs.save(h.state, newer));
        try chmod(p, if (is_file) 0o600 else 0o700);
    }
    try chmod(h.state, 0o777);
    try expectError(error.UnsafeDirectory, fs.load(h.state));
    try expectError(error.UnsafeDirectory, fs.save(h.state, newer));
    try chmod(h.state, 0o700);
    const current = try h.path("coral/sessions/current");
    defer a.free(current);
    const alias = try h.path("hardlink");
    defer a.free(alias);
    try equal(@as(c_int, 0), std.c.link(current, alias));
    defer _ = std.c.unlink(alias);
    try expectError(error.UnsafeFile, fs.load(h.state));
    try expectError(error.UnsafeFile, fs.save(h.state, newer));
}

test "symlinked current, FIFO and directory refuse replacement; pending never follows symlinks" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    try h.fixture.write("outside", "untouched");
    const outside = try h.fixture.path("outside");
    defer a.free(outside);
    const current = try h.path("coral/sessions/current");
    defer a.free(current);
    try equal(@as(c_int, 0), std.c.unlink(current));
    try equal(@as(c_int, 0), std.c.symlink(outside, current));
    try expectError(error.UnsafeFile, fs.load(h.state));
    try expectError(error.UnsafeFile, fs.save(h.state, newer));
    try equal(@as(c_int, 0), std.c.unlink(current));
    try equal(@as(c_int, 0), mkfifo(current, 0o600));
    try expectError(error.UnsafeFile, fs.load(h.state));
    try expectError(error.UnsafeFile, fs.save(h.state, newer));
    try equal(@as(c_int, 0), std.c.unlink(current));
    try equal(@as(c_int, 0), std.c.mkdir(current, 0o700));
    try expectError(error.UnsafeFile, fs.load(h.state));
    try expectError(error.UnsafeFile, fs.save(h.state, newer));
    try equal(@as(c_int, 0), std.c.rmdir(current));
    const pending = try h.path("coral/sessions/pending");
    defer a.free(pending);
    try equal(@as(c_int, 0), std.c.symlink(outside, pending));
    try fs.save(h.state, sample);
    const fd = std.c.open(outside, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [32]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    try equal(@as(isize, "untouched".len), n);
    try bytesEqual("untouched", buf[0..@intCast(n)]);
}

test "state ancestors use search-only descriptors and reject symlinks and unsafe writers" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    try chmod(h.fixture.base, 0o100);
    defer _ = std.c.chmod(h.fixture.base, 0o700);
    // Reopening a traversal ancestor RDONLY would fail for an unprivileged user.
    const loaded = fs.load(h.state) catch |err| {
        try equal(@as(c_int, 0), std.c.chmod(h.fixture.base, 0o700));
        return err;
    };
    loaded.deinit();
    try fs.save(h.state, newer);
    try equal(@as(c_int, 0), std.c.chmod(h.fixture.base, 0o700));
    try h.fixture.symlink(h.state, "alias");
    const alias = try h.fixture.path("alias");
    defer a.free(alias);
    try expectError(error.UnsafeDirectory, fs.load(alias));
    try expectError(error.UnsafeDirectory, fs.save(alias, sample));
    try chmod(h.fixture.base, 0o777);
    try expectError(error.UnsafeDirectory, fs.load(h.state));
    try expectError(error.UnsafeDirectory, fs.save(h.state, sample));
    try chmod(h.fixture.base, 0o700);
}

test "coral and sessions directory symlinks are refused without touching targets" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    try h.fixture.mkdir("outside-dir");
    const target = try h.fixture.path("outside-dir");
    defer a.free(target);
    for ([_][]const u8{ "coral/sessions", "coral" }) |suffix| {
        const original = try h.path(suffix);
        defer a.free(original);
        const moved = try std.fmt.allocPrintSentinel(a, "{s}.held", .{original}, 0);
        defer a.free(moved);
        try equal(@as(c_int, 0), std.c.renameat(std.c.AT.FDCWD, original, std.c.AT.FDCWD, moved));
        defer _ = std.c.renameat(std.c.AT.FDCWD, moved, std.c.AT.FDCWD, original);
        try equal(@as(c_int, 0), std.c.symlink(target, original));
        defer _ = std.c.unlink(original);
        try expectError(error.UnsafeDirectory, fs.load(h.state));
        try expectError(error.UnsafeDirectory, fs.save(h.state, newer));
    }
    const loaded = try fs.load(h.state);
    defer loaded.deinit();
    try expectSample(loaded.value);
}

test "process death releases flock and leaves old or whole new explicit checkpoint" {
    // Standalone/headless only: no application worker pool is running at fork.
    var h = try Home.init();
    defer h.deinit();
    for ([_]fs.Fault{ .during_write, .before_rename, .after_rename }) |fault| {
        try fs.save(h.state, sample);
        const pid = std.c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = alarm(10);
            fs.saveWithHooks(h.state, newer, .{ .fault = fault, .terminate_process = true }) catch std.c._exit(74);
            std.c._exit(75);
        }
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {
            if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
        }
        try equal(@as(c_int, 73 << 8), status);
        const loaded = try fs.load(h.state);
        defer loaded.deinit();
        if (fault == .after_rename) {
            try bytesEqual(newer.snapshot.documents[0].text, loaded.value.snapshot.documents[0].text);
        } else {
            try expectSample(loaded.value);
        }
        // A subsequent explicit save may remove the abandoned pending entry.
        try fs.save(h.state, newer);
    }
}

test "abandoned first save is never promoted by load" {
    var h = try Home.init();
    defer h.deinit();
    const pid = std.c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        _ = alarm(10);
        fs.saveWithHooks(h.state, sample, .{ .fault = .before_rename, .terminate_process = true }) catch std.c._exit(74);
        std.c._exit(75);
    }
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return error.Wait;
    }
    try equal(@as(c_int, 73 << 8), status);
    const pending = try h.path("coral/sessions/pending");
    defer a.free(pending);
    const fd = std.c.open(pending, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
    try expect(fd >= 0);
    defer _ = std.c.close(fd);
    try expectError(error.NotFound, fs.load(h.state));
    try expectError(error.NotFound, fs.load(h.state));
    try fs.save(h.state, newer);
    const loaded = try fs.load(h.state);
    defer loaded.deinit();
    try bytesEqual(newer.snapshot.documents[0].text, loaded.value.snapshot.documents[0].text);
}

test "session cap accommodates full recovery text plus maximum workspace descriptor" {
    const text = try a.alloc(u8, recovery.limits.document_bytes);
    defer a.free(text);
    @memset(text, 'x');
    const path = try a.alloc(u8, model.limits.path_bytes);
    defer a.free(path);
    @memset(path, 'p');
    path[0] = '/';
    const name = try a.alloc(u8, model.limits.name_bytes);
    defer a.free(name);
    @memset(name, 1);
    const roots: [model.limits.roots]model.Root = @splat(.{ .path = path, .name = name });
    const value: model.Value = .{
        .snapshot = .{ .documents = &.{ .{ .id = 1, .text = text }, .{ .id = 2, .text = text } } },
        .workspace = .{ .source = .manifest, .path = path, .roots = &roots },
    };
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, value);
    const loaded = try fs.load(h.state);
    defer loaded.deinit();
    try equal(@as(usize, recovery.limits.text_bytes), loaded.value.snapshot.documents[0].text.len + loaded.value.snapshot.documents[1].text.len);
    try bytesEqual(text, loaded.value.snapshot.documents[1].text);
    try bytesEqual(name, loaded.value.workspace.?.roots[31].name);
    const too_big = try a.alloc(u8, model.limits.session_bytes + 1);
    defer a.free(too_big);
    try expectError(error.TooLarge, model.decode(too_big));
}

test "valid-checksum unsupported schema and malformed offsets are preserved on save" {
    var h = try Home.init();
    defer h.deinit();
    try fs.save(h.state, sample);
    const snapshot = try recovery.encode(a, sample.snapshot);
    defer a.free(snapshot);
    const unknown = try wire("{\"workspace\":null,\"future\":true}", snapshot);
    defer a.free(unknown);
    try h.overwrite(unknown);
    try expectError(error.CorruptSession, fs.load(h.state));
    try expectError(error.CorruptSession, fs.save(h.state, newer));
    const kept = try h.read();
    defer a.free(kept);
    try bytesEqual(unknown, kept);
    var views = [_]recovery.View{sample.snapshot.views[0]};
    views[0].cursor = 1;
    var invalid = sample.snapshot;
    invalid.views = &views;
    const bad_snapshot = try recovery.encode(a, invalid);
    defer a.free(bad_snapshot);
    const bad_offsets = try wire("{\"workspace\":null}", bad_snapshot);
    defer a.free(bad_offsets);
    try h.overwrite(bad_offsets);
    try expectError(error.InvalidSnapshot, fs.load(h.state));
    try expectError(error.InvalidSnapshot, fs.save(h.state, newer));
    const kept_offsets = try h.read();
    defer a.free(kept_offsets);
    try bytesEqual(bad_offsets, kept_offsets);
}
