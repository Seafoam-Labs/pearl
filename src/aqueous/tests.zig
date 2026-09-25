const std = @import("std");
const t = std.testing;
const a = t.allocator;
const c = @import("codec.zig");
const e = @import("entities.zig");
const Model = @import("reducer.zig").Model;
const f = @import("aqueous_fixtures");

fn frame(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, raw, "\n");
}
fn decode(raw: []const u8, op: ?c.Operation) !c.Decoded {
    return c.decode(a, frame(raw), .{}, op);
}
fn model() !Model {
    return Model.init(a, (c.Limits{}).state_bytes);
}
fn install(m: *Model, raw: []const u8) !void {
    var d = try decode(raw, null);
    defer d.deinit();
    try m.apply(d.message.event.batch);
}
fn replace(raw: []const u8, before: []const u8, after: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, raw, before) orelse return error.TestPatternMissing;
    return std.mem.concat(a, u8, &.{ raw[0..at], after, raw[at + before.len ..] });
}
fn rejects(raw: []const u8, expected: anyerror, op: ?c.Operation) !void {
    try t.expectError(expected, decode(raw, op));
}

test "captured server envelopes decode with operation-specific results" {
    const cases = .{
        .{ f.hello, c.Operation.hello },         .{ f.snapshot_response, c.Operation.snapshot },
        .{ f.subscribe, c.Operation.subscribe }, .{ f.ack, c.Operation.ack },
        .{ f.command, c.Operation.command },     .{ f.accepted, c.Operation.command },
        .{ f.icon, c.Operation.window_icon },
    };
    inline for (cases) |case| {
        var d = try decode(case[0], case[1]);
        defer d.deinit();
        try t.expectEqual(case[1], std.meta.activeTag(d.message.response.result));
    }
    var failure = try decode(f.failure, .command);
    defer failure.deinit();
    try t.expectEqualStrings("stale_session", failure.message.failure.code);
    var delta = try decode(f.delta, null);
    defer delta.deinit();
    try t.expectEqualStrings("final 🐟 \"quoted\"", delta.message.event.batch.upsert[0].workspace.name);
    try rejects(f.hello, error.UnexpectedResponse, null);
    try rejects(f.hello, error.MissingField, .ack);
}

test "NDJSON survives every byte split including UTF-8 and escaped quotes" {
    for ([_][]const u8{ f.hello, f.snapshot, f.delta, f.desktop }) |raw| {
        for (0..raw.len + 1) |split| {
            var stream = try c.Framer.init(a, (c.Limits{}).frame_bytes);
            defer stream.deinit();
            const first = try stream.push(raw[0..split]);
            try t.expectEqual(split, first.consumed);
            if (split == raw.len) {
                try t.expectEqualStrings(frame(raw), first.frame.?);
            } else {
                try t.expect(first.frame == null);
                const second = try stream.push(raw[split..]);
                try t.expectEqual(raw.len - split, second.consumed);
                try t.expectEqualStrings(frame(raw), second.frame.?);
            }
            try stream.finish();
        }
    }
    var stream = try c.Framer.init(a, (c.Limits{}).frame_bytes);
    defer stream.deinit();
    for (f.delta, 0..) |_, i| {
        const r = try stream.push(f.delta[i..][0..1]);
        if (i + 1 == f.delta.len) try t.expectEqualStrings(frame(f.delta), r.frame.?) else try t.expect(r.frame == null);
    }
}

test "combined frames leave unread bytes to caller and bound capacity" {
    const combined = try std.mem.concat(a, u8, &.{ f.hello, f.snapshot, f.delta });
    defer a.free(combined);
    var stream = try c.Framer.init(a, frame(f.snapshot).len);
    defer stream.deinit();
    var offset: usize = 0;
    for ([_][]const u8{ f.hello, f.snapshot, f.delta }) |expected| {
        const read = try stream.push(combined[offset..]);
        try t.expectEqualStrings(frame(expected), read.frame.?);
        offset += read.consumed;
        try t.expect(stream.buffer.capacity <= stream.limit);
    }
    try t.expectEqual(combined.len, offset);
    try stream.finish();
}

test "framing limits, malformed UTF-8, truncation and poison/reset" {
    var stream = try c.Framer.init(a, 2);
    defer stream.deinit();
    try t.expectEqualStrings("{}", (try stream.push("{}\n")).frame.?);
    try t.expectError(error.FrameTooLarge, stream.push("123\n"));
    try t.expectError(error.FailedStream, stream.push("{}\n"));
    stream.reset();
    _ = try stream.push("{");
    try t.expectError(error.TruncatedFrame, stream.finish());
    stream.reset();
    try t.expectError(error.EmptyFrame, stream.push("\n"));
    stream.reset();
    try t.expectError(error.InvalidUtf8, stream.push("\xc3\x28\n"));
    try rejects("{\"x\":\"\xff\"}", error.InvalidUtf8, null);
    try rejects("{}\n{}", error.InvalidFraming, null);
    try rejects("{}\r", error.InvalidFraming, null);
    try t.expectError(error.FrameTooLarge, c.decode(a, "{} ", .{ .frame_bytes = 2 }, null));
    try t.expectError(error.InvalidLimits, c.decode(a, "{}", .{ .depth = 17 }, null));
}

test "depth and exact raw batch byte limits include whitespace and escaped keys" {
    const at_limit = "{\"ipc\":1,\"id\":\"1\",\"ok\":false,\"error\":{\"code\":\"x\",\"message\":\"[\\\"{\"}}";
    var d = try c.decode(a, at_limit, .{ .depth = 2 }, null);
    d.deinit();
    try t.expectError(error.TooDeep, c.decode(a, at_limit, .{ .depth = 1 }, null));
    try t.expectError(error.TooDeep, c.decode(a, "[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]", .{}, null));
    const padded = "{\"ipc\":1,\"event\":\"state\",\"delivery\":\"1\",\"b\\u0061tch\":{          }}";
    try t.expectError(error.BatchTooLarge, c.decode(a, padded, .{ .batch_bytes = 11 }, null));
    try t.expectError(error.MissingField, c.decode(a, padded, .{ .batch_bytes = 12 }, null));
    const response = "{\"ipc\":1,\"id\":\"1\",\"ok\":true,\"result\":{\"batch\":{          }}}";
    try t.expectError(error.BatchTooLarge, c.decode(a, response, .{ .batch_bytes = 11 }, .snapshot));
}

test "strict envelopes, versions, required fields, decimal bounds and duplicate JSON keys" {
    const cases = .{
        .{ f.snapshot, "\"ipc\":1", "\"ipc\":2", error.UnsupportedIpc },
        .{ f.snapshot, "\"schema\":1", "\"schema\":2", error.UnsupportedSchema },
        .{ f.snapshot, "\"ipc\":1", "\"ipc\":\"1\"", error.InvalidType },
        .{ f.snapshot, "\"ipc\":1", "\"ipc\":1,\"ipc\":1", error.DuplicateField },
        .{ f.snapshot, "\"event\":\"state\"", "\"event\":\"state\",\"id\":\"1\"", error.InvalidEnvelope },
        .{ f.snapshot, "\"delivery\":\"1\"", "\"delivery\":1", error.InvalidType },
        .{ f.snapshot, "\"delivery\":\"1\"", "\"delivery\":\"18446744073709551616\"", error.InvalidDecimal },
        .{ f.snapshot, "\"number\":3", "\"number\":-1", error.InvalidRange },
        .{ f.snapshot, "\"number\":3", "\"number\":0", error.InvalidRange },
        .{ f.snapshot, "\"number\":3", "\"number\":\"3\"", error.InvalidType },
        .{ f.snapshot, "\"scale\":1", "\"scale\":0", error.InvalidRange },
        .{ f.snapshot, "\"base_sequence\":null,", "", error.MissingField },
        .{ f.snapshot, "\"base_sequence\":null", "\"base_sequence\":\"1\"", error.InvalidBatch },
        .{ f.delta, "\"base_sequence\":\"1\"", "\"base_sequence\":null", error.InvalidBatch },
        .{ f.desktop, "\"class\":null,", "", error.MissingField },
        .{ f.desktop, "\"index\":1", "\"index\":2", error.InvalidRange },
        .{ f.desktop, "\"backend\":\"xdg\"", "\"backend\":\"other\"", error.InvalidEnum },
    };
    inline for (cases) |case| {
        const raw = try replace(case[0], case[1], case[2]);
        defer a.free(raw);
        try rejects(raw, case[3], null);
    }
    try t.expectError(error.InvalidDecimal, e.decimal("-1"));
    try t.expectError(error.InvalidDecimal, e.decimal(""));
    try t.expectError(error.InvalidSession, e.sessionToken("6B94a179d09456846b94a179d0945684"));
    try e.decimal("18446744073709551615");
    try e.decimal("0001");
}

test "unknown additive fields and absent optional capabilities are compatible" {
    const old = try replace(f.hello, ",\"icon_metadata\":true,\"icon_fetch\":true", "");
    defer a.free(old);
    const extra = try replace(old, "\"state\":true", "\"future\":{\"enabled\":true},\"state\":true");
    defer a.free(extra);
    var d = try decode(extra, .hello);
    defer d.deinit();
    const hello = d.message.response.result.hello;
    try t.expect(!hello.capabilities.icon_metadata and !hello.capabilities.icon_fetch and !hello.capabilities.config_reload);
    var larger = hello;
    larger.max_frame_bytes = 999999999;
    larger.max_state_bytes = 1024;
    try t.expectEqual((c.Limits{}).frame_bytes, larger.effectiveLimits().frame_bytes);
    try t.expectEqual(1024, larger.effectiveLimits().state_bytes);
}

test "snapshot owns all seven kinds and derives per-output workspace and window views" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    // install() already freed the decoded frame: these references must be owned.
    try t.expectEqual(25, m.entities.count());
    try t.expectEqualStrings("HEADLESS-2", m.outputByName("HEADLESS-2").?.name);
    const first = try m.workspaces(a, "1");
    defer a.free(first);
    const second = try m.workspaces(a, "2");
    defer a.free(second);
    try t.expectEqual(9, first.len);
    try t.expectEqual(9, second.len);
    try t.expectEqual(1, first[0].number);
    try t.expectEqual(1, second[0].number);
    try t.expectEqualStrings("1", first[0].id);
    try t.expectEqualStrings("10", second[0].id);
    try t.expectEqualStrings("10", m.activeWorkspace("2").?.id);
    const windows = try m.windows(a, .{ .output = "2", .workspace = "12", .purpose = .taskbar });
    defer a.free(windows);
    try t.expectEqual(1, windows.len);
    try t.expectEqualStrings("18446744073709551615", windows[0].id);
    try t.expectEqualStrings("18446744073709551615", windows[0].icon.?.revision);
    try t.expectEqualStrings("Draft 🐟", windows[0].title.?);
    try t.expectEqual(-2, windows[0].outer_geometry.x - windows[0].geometry.x);
    const focus = try m.focus(null);
    try t.expect(focus.window == null);
    try t.expectEqualStrings("1", focus.output.?.id);
    try t.expectEqualStrings("German", focus.keyboard.?.layouts[focus.keyboard.?.index]);
    try t.expect(m.get(.keyboard_device, "9007199254740994") != null);
}

test "captured sequence jump applies; omitted optional icon clears full entity" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    try install(&m, f.delta);
    try t.expectEqualStrings("4", m.sequence);
    try t.expectEqualStrings("final 🐟 \"quoted\"", m.get(.workspace, "12").?.name);
    const without_icon = try replace(f.desktop, ",\"icon\":{\"revision\":\"18446744073709551615\",\"name\":\"text-editor\",\"has_pixels\":true}", "");
    defer a.free(without_icon);
    var d = try decode(without_icon, null);
    defer d.deinit();
    var batch = d.message.event.batch;
    batch.type = .delta;
    batch.base_sequence = "4";
    batch.sequence = "9007199254740993";
    const window = batch.upsert[22];
    try t.expect(window == .window);
    batch.upsert = &.{window};
    try m.apply(batch);
    try t.expect(m.get(.window, window.id()).?.icon == null);
    try t.expectEqualStrings("9007199254740993", m.sequence);
}

test "atomic migration and output removal preserve workspace identities" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    try install(&m, f.output_removal);
    try t.expect(m.get(.output, "2") == null);
    try t.expect(m.outputByName("HEADLESS-1") == null);
    try t.expectEqualStrings("1", m.get(.workspace, "12").?.output);
    try t.expectEqualStrings("1", m.get(.window, "18446744073709551615").?.output.?);
    const workspaces = try m.workspaces(a, "1");
    defer a.free(workspaces);
    try t.expectEqual(18, workspaces.len);
    try t.expectEqualStrings("1", m.activeWorkspace("1").?.id);
}

test "rejected candidate never changes live values or borrowed pointers" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    const original = m.get(.workspace, "12").?;
    var d = try decode(f.delta, null);
    defer d.deinit();
    const valid = d.message.event.batch;
    var bad = valid;
    bad.base_sequence = "0";
    try t.expectError(error.SequenceGap, m.apply(bad));
    bad = valid;
    bad.sequence = "1";
    try t.expectError(error.SequenceRegression, m.apply(bad));
    bad = valid;
    bad.session = "00000000000000000000000000000000";
    try t.expectError(error.SessionChanged, m.apply(bad));
    bad = valid;
    bad.upsert = &.{ valid.upsert[0], valid.upsert[0] };
    try t.expectError(error.DuplicateIdentity, m.apply(bad));
    bad = valid;
    bad.removed = &.{.{ .kind = .workspace, .id = "12" }};
    try t.expectError(error.DuplicateIdentity, m.apply(bad));
    bad = valid;
    bad.removed = &.{ .{ .kind = .output, .id = "2" }, .{ .kind = .output, .id = "2" } };
    try t.expectError(error.DuplicateIdentity, m.apply(bad));
    bad = valid;
    bad.removed = &.{.{ .kind = .window, .id = "gone" }};
    try t.expectError(error.UnknownRemoval, m.apply(bad));
    bad = valid;
    bad.removed = &.{.{ .kind = .output, .id = "2" }};
    try t.expectError(error.DanglingReference, m.apply(bad));
    var changed = valid.upsert[0];
    changed.workspace.output = "gone";
    bad = valid;
    bad.upsert = &.{changed};
    try t.expectError(error.DanglingReference, m.apply(bad));
    try t.expect(original == m.get(.workspace, "12").?);
    try t.expectEqualStrings("3", original.name);
    try t.expectEqualStrings("1", m.sequence);
    try t.expectEqual(25, m.entities.count());
    try t.expect(m.ready);
}

test "state budget rejection is atomic, including accumulation across deltas" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.snapshot);
    m.limit = m.accounted_bytes;
    var d = try decode(f.delta, null);
    defer d.deinit();
    try t.expectError(error.StateTooLarge, m.apply(d.message.event.batch));
    try t.expectEqualStrings("1", m.sequence);
    try t.expectEqualStrings("3", m.get(.workspace, "12").?.name);
    var tiny = try Model.init(a, 1);
    defer tiny.deinit();
    try t.expectError(error.StateTooLarge, install(&tiny, f.snapshot));
    try t.expect(!tiny.ready and tiny.entities.count() == 0);
}

test "new-session snapshot replaces old IDs; invalidation requires a snapshot" {
    var m = try model();
    defer m.deinit();
    var delta = try decode(f.delta, null);
    defer delta.deinit();
    try t.expectError(error.SnapshotRequired, m.apply(delta.message.event.batch));
    try install(&m, f.desktop);
    m.invalidate();
    try t.expect(m.get(.window, "18446744073709551615") == null);
    try t.expectError(error.Unavailable, m.focus(null));
    try t.expectError(error.SnapshotRequired, m.apply(delta.message.event.batch));
    var snapshot = try decode(f.snapshot, null);
    defer snapshot.deinit();
    snapshot.message.event.batch.session = "00000000000000000000000000000000";
    try m.apply(snapshot.message.event.batch);
    try t.expect(m.ready);
    try t.expectEqualStrings("00000000000000000000000000000000", m.session);
    try t.expect(m.get(.window, "18446744073709551615") == null);
    try t.expect(m.get(.keyboard, "9007199254740993") == null);
    m.clear();
    try t.expect(!m.ready and m.entities.count() == 0);
}

test "seat focus follows window and layer transitions and rejects ambiguous defaults" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    var seat = m.get(.seat, "default").?.*;
    seat.window = "18446744073709551615";
    seat.output = "2";
    seat.focus_kind = .window;
    var batch: c.Batch = .{ .session = m.session, .sequence = "2", .base_sequence = "1", .type = .delta, .upsert = &.{.{ .seat = seat }}, .removed = &.{} };
    try m.apply(batch);
    try t.expectEqualStrings("18446744073709551615", (try m.focus("default")).window.?.id);
    // Reborrow after the successful commit freed the previous model arena.
    seat = m.get(.seat, "default").?.*;
    seat.window = null;
    seat.focus_kind = .layer_surface;
    batch.session = m.session;
    batch.base_sequence = "2";
    batch.sequence = "3";
    batch.upsert = &.{.{ .seat = seat }};
    try m.apply(batch);
    const focus = try m.focus(null);
    try t.expect(focus.window == null);
    try t.expectEqualStrings("2", focus.output.?.id);
    var second = focus.seat.*;
    second.id = "second";
    second.keyboard = null;
    var session = m.get(.session, "session").?.*;
    session.default_seat = null;
    batch.session = m.session;
    batch.base_sequence = "3";
    batch.sequence = "4";
    batch.upsert = &.{ .{ .seat = second }, .{ .session = session } };
    try m.apply(batch);
    try t.expectError(error.AmbiguousSeat, m.focus(null));
    try t.expectEqualStrings("default", (try m.focus("default")).seat.id);
    try t.expectError(error.UnknownSeat, m.focus("missing"));
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var m = try Model.init(allocator, (c.Limits{}).state_bytes);
    defer m.deinit();
    var snapshot = try c.decode(allocator, frame(f.desktop), .{}, null);
    defer snapshot.deinit();
    try m.apply(snapshot.message.event.batch);
    const original = m.get(.workspace, "12").?;
    var delta = try c.decode(allocator, frame(f.output_removal), .{}, null);
    defer delta.deinit();
    m.apply(delta.message.event.batch) catch |err| {
        try t.expect(original == m.get(.workspace, "12").?);
        try t.expectEqualStrings("2", original.output);
        try t.expectEqualStrings("1", m.sequence);
        return err;
    };
    try t.expectEqualStrings("1", m.get(.workspace, "12").?.output);
}

test "every allocation failure cleans parsing and candidate state without partial commit" {
    try t.checkAllAllocationFailures(a, allocationScenario, .{});
}

test "truncated and malformed JSON fails cleanly at all frame prefixes" {
    for ([_][]const u8{ frame(f.hello), frame(f.delta) }) |raw| {
        for (0..raw.len) |end| {
            if (decode(raw[0..end], .hello)) |decoded| {
                var owned = decoded;
                owned.deinit();
                return error.AcceptedTruncatedJson;
            } else |_| {}
        }
    }
    for ([_][]const u8{
        "{\"batch\":}",               "{\"batch\":[}",       "{\"result\":{\"batch\":]}}",
        "{\"result\":{\"x\":true,}}", "{\"x\":\"\\ud800\"}", "{\"x\":\"\\udc00\"}",
        "{} trailing",                "{}{}",                "[]",
        "null",                       "{\"x\":\"\x00\"}",
    }) |raw| {
        if (decode(raw, null)) |decoded| {
            var owned = decoded;
            owned.deinit();
            return error.AcceptedMalformedJson;
        } else |_| {}
    }
}

test "large signed geometry, unknown extensions and omitted optional text are preserved correctly" {
    const enlarged = try replace(f.desktop, "\"x\":1298", "\"x\":-4294967296");
    defer a.free(enlarged);
    const extended = try replace(enlarged, "\"layout\":\"floating\"", "\"layout\":\"floating\",\"tag\":\"editor\",\"description\":\"Project\",\"future_flag\":true");
    defer a.free(extended);
    var m = try model();
    defer m.deinit();
    try install(&m, extended);
    const window = m.get(.window, "18446744073709551615").?;
    try t.expectEqual(-4294967296, window.outer_geometry.x);
    try t.expectEqualStrings("editor", window.tag.?);
    try t.expectEqualStrings("Project", window.description.?);
    var d = try decode(f.desktop, null);
    defer d.deinit();
    var batch = d.message.event.batch;
    batch.type = .delta;
    batch.base_sequence = "1";
    batch.sequence = "2";
    batch.upsert = &.{batch.upsert[22]};
    try m.apply(batch);
    try t.expect(m.get(.window, "18446744073709551615").?.tag == null);
    try t.expect(m.get(.window, "18446744073709551615").?.description == null);
}

test "window lists preserve minimized windows and respect independent skip flags" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    var window = m.get(.window, "18446744073709551615").?.*;
    window.minimized = true;
    window.skip_taskbar = true;
    const batch: c.Batch = .{
        .session = m.session,
        .sequence = "2",
        .base_sequence = "1",
        .type = .delta,
        .upsert = &.{.{ .window = window }},
        .removed = &.{},
    };
    try m.apply(batch);
    const taskbar = try m.windows(a, .{ .purpose = .taskbar });
    defer a.free(taskbar);
    const switcher = try m.windows(a, .{ .purpose = .switcher });
    defer a.free(switcher);
    const other_output = try m.windows(a, .{ .output = "1" });
    defer a.free(other_output);
    try t.expectEqual(0, taskbar.len);
    try t.expectEqual(1, switcher.len);
    try t.expect(switcher[0].minimized);
    try t.expectEqual(0, other_output.len);
}

test "invalid snapshot identities and graph references preserve the accepted snapshot" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.snapshot);
    const original = m.get(.output, "1").?;
    var d = try decode(f.snapshot, null);
    defer d.deinit();
    var batch = d.message.event.batch;
    batch.upsert = &.{ batch.upsert[0], batch.upsert[0] };
    try t.expectError(error.DuplicateIdentity, m.apply(batch));
    batch.upsert = &.{};
    try t.expectError(error.MissingSession, m.apply(batch));
    var out = original.*;
    out.id = "other";
    out.active_workspace = null;
    batch.type = .delta;
    batch.base_sequence = "1";
    batch.sequence = "2";
    batch.upsert = &.{.{ .output = out }};
    try t.expectError(error.DuplicateConnector, m.apply(batch));
    out = original.*;
    out.active_workspace = "10";
    batch.upsert = &.{.{ .output = out }};
    try t.expectError(error.InconsistentWorkspace, m.apply(batch));
    var seat = m.get(.seat, "default").?.*;
    seat.keyboard = "absent";
    batch.upsert = &.{.{ .seat = seat }};
    try t.expectError(error.DanglingReference, m.apply(batch));
    try t.expect(original == m.get(.output, "1").?);
    try t.expectEqualStrings("1", m.sequence);
}

test "identity removal splits only the first colon and decimal equality stays exact" {
    const key = try e.Key.parse("window:foreign:identifier");
    try t.expectEqual(e.Kind.window, key.kind);
    try t.expectEqualStrings("foreign:identifier", key.id);
    try t.expectError(error.InvalidIdentity, e.Key.parse("window:"));
    try t.expectError(error.InvalidIdentity, e.Key.parse("unknown:1"));
    var m = try model();
    defer m.deinit();
    try install(&m, f.snapshot);
    var d = try decode(f.delta, null);
    defer d.deinit();
    d.message.event.batch.base_sequence = "01";
    try t.expectError(error.SequenceGap, m.apply(d.message.event.batch));
    d.message.event.batch.base_sequence = "1";
    d.message.event.batch.sequence = "18446744073709551615";
    try m.apply(d.message.event.batch);
    try t.expectEqualStrings("18446744073709551615", m.sequence);
}

test "icon envelope rejects invalid encoding and dimensions" {
    const invalid_data = try replace(f.icon, "iVBOR", "!VBOR");
    defer a.free(invalid_data);
    try rejects(invalid_data, error.InvalidIcon, .window_icon);
    const invalid_size = try replace(f.icon, "\"width\":1", "\"width\":257");
    defer a.free(invalid_size);
    try rejects(invalid_size, error.InvalidRange, .window_icon);
}

const cmd = @import("commands.zig");
test "command policy uses IDs, published per-window capabilities and keyboard ownership" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    var hello = try decode(f.hello, .hello);
    defer hello.deinit();
    var caps = hello.message.response.result.hello.capabilities;
    const window = "18446744073709551615";
    try cmd.validate(.{ .window_activate = .{ .id = window } }, &m, caps);
    try cmd.validate(.{ .window_move_workspace = .{ .id = window, .workspace = "1" } }, &m, caps);
    try t.expectError(error.NotFound, cmd.validate(.{ .window_move_output = .{ .id = window, .output = "HEADLESS-1" } }, &m, caps));
    try t.expectError(error.NotFound, cmd.validate(.{ .window_activate = .{ .id = window, .seat = "missing" } }, &m, caps));
    try t.expectError(error.Invalid, cmd.validate(.{ .workspace_rename = .{ .id = "1", .name = "bad\nname" } }, &m, caps));
    try t.expectError(error.Invalid, cmd.validate(.{ .workspace_rename = .{ .id = "1", .name = "bad\x00name" } }, &m, caps));
    try t.expectError(error.Invalid, cmd.validate(.{ .workspace_rename = .{ .id = "1", .name = "\xff" } }, &m, caps));
    try t.expectError(error.Invalid, cmd.validate(.{ .keyboard_set = .{ .index = 99 } }, &m, caps));
    try t.expectError(error.Unsupported, cmd.validate(.session_reload, &m, caps));
    caps.config_reload = true;
    try cmd.validate(.session_reload, &m, caps);
    caps.keyboard = false;
    try t.expectError(error.Unsupported, cmd.validate(.{ .keyboard_next = .{} }, &m, caps));
    caps.overview = false;
    try t.expectError(error.Unsupported, cmd.validate(.overview_hide, &m, caps));
    const restricted = try replace(f.desktop, "\"can_activate\":true", "\"can_activate\":false");
    defer a.free(restricted);
    try install(&m, restricted);
    try t.expectError(error.Unsupported, cmd.validate(.{ .window_activate = .{ .id = window } }, &m, caps));
    m.invalidate();
    try t.expectError(error.Unavailable, cmd.validate(.session_exit, &m, caps));
}

test "all typed command encodings use strict fields and own caller strings" {
    const cases = .{
        .{ cmd.Action{ .window_activate = .{ .id = "w" } }, "window.activate", "{\"id\":\"w\"}" },
        .{ cmd.Action{ .window_close = .{ .id = "w" } }, "window.close", "{\"id\":\"w\"}" },
        .{ cmd.Action{ .window_minimized = .{ .id = "w", .value = true } }, "window.minimized", "{\"id\":\"w\",\"value\":true}" },
        .{ cmd.Action{ .window_maximized = .{ .id = "w", .value = false } }, "window.maximized", "{\"id\":\"w\",\"value\":false}" },
        .{ cmd.Action{ .window_fullscreen = .{ .id = "w", .value = true } }, "window.fullscreen", "{\"id\":\"w\",\"value\":true}" },
        .{ cmd.Action{ .window_move_workspace = .{ .id = "w", .workspace = "2" } }, "window.move", "{\"id\":\"w\",\"workspace\":\"2\"}" },
        .{ cmd.Action{ .window_move_output = .{ .id = "w", .output = "2" } }, "window.move", "{\"id\":\"w\",\"output\":\"2\"}" },
        .{ cmd.Action{ .workspace_activate = .{ .id = "2", .seat = "s" } }, "workspace.activate", "{\"id\":\"2\",\"seat\":\"s\"}" },
        .{ cmd.Action{ .workspace_rename = .{ .id = "2", .name = "🐟" } }, "workspace.rename", "{\"id\":\"2\",\"name\":\"🐟\"}" },
        .{ cmd.Action{ .keyboard_set = .{ .index = 1, .group = "k" } }, "keyboard.set", "{\"group\":\"k\",\"index\":1}" },
        .{ cmd.Action{ .keyboard_next = .{} }, "keyboard.next", "{}" },
        .{ cmd.Action{ .overview_show = .{ .output = "o" } }, "overview.show", "{\"output\":\"o\"}" },
        .{ cmd.Action.overview_hide, "overview.hide", "{}" },
        .{ cmd.Action{ .overview_toggle = .{ .output = "o" } }, "overview.toggle", "{\"output\":\"o\"}" },
        .{ cmd.Action.session_exit, "session.exit", "{}" },
        .{ cmd.Action.session_reload, "session.reload", "{}" },
    };
    inline for (cases) |case| {
        const expected = try std.fmt.allocPrint(a, "{{\"action\":\"{s}\",\"fields\":{s}}}", .{ case[1], case[2] });
        defer a.free(expected);
        var owned = try cmd.Owned.init(a, case[0], 1);
        defer owned.deinit();
        const encoded = try owned.action.params(a);
        defer a.free(encoded);
        try t.expectEqualStrings(expected, encoded);
    }
    var name = [_]u8{ 'a', 'b' };
    var owned = try cmd.Owned.init(a, .{ .workspace_rename = .{ .id = "1", .name = &name } }, 7);
    defer owned.deinit();
    @memset(&name, 'x');
    try t.expectEqualStrings("ab", owned.action.workspace_rename.name);
}

test "switcher commands require negotiated capability and reject a stale workspace" {
    var m = try model();
    defer m.deinit();
    try install(&m, f.desktop);
    var hello = try decode(f.hello, .hello);
    defer hello.deinit();
    var caps = hello.message.response.result.hello.capabilities;
    const focus = try m.focus(null);
    const output = focus.output.?.id;
    const workspace = m.activeWorkspace(output).?.id;
    const action: cmd.Action = .{ .switcher_next = .{ .output = output, .workspace = workspace, .seat = focus.seat.id, .reduced_motion = true } };
    try t.expectError(error.Unsupported, cmd.validate(action, &m, caps));
    caps.workspace_switcher_v1 = true;
    try cmd.validate(action, &m, caps);
    try t.expectError(error.Unavailable, cmd.validate(.{ .switcher_previous = .{ .output = output, .workspace = "stale" } }, &m, caps));
    try t.expectError(error.NotFound, cmd.validate(.{ .switcher_next = .{ .output = output, .workspace = workspace, .seat = "missing" } }, &m, caps));
    var owned = try cmd.Owned.init(a, action, 9);
    defer owned.deinit();
    try t.expect(owned.action.switcher_next.reduced_motion);
    const encoded = try action.params(a);
    defer a.free(encoded);
    try t.expect(std.mem.indexOf(u8, encoded, "switcher.next") != null);
    m.invalidate();
    try t.expectError(error.Unavailable, cmd.validate(action, &m, caps));
}
