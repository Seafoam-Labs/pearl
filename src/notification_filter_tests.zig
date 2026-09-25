const std = @import("std");
const f = @import("services/notification_filter_policy.zig");
const t = std.testing;
fn evaluate(rules: []const f.Rule, sample: f.Sample) !f.Result {
    var compiled = try f.Compiled.init(t.allocator, .{ .rules = rules });
    defer compiled.deinit();
    return compiled.evaluate(sample.record());
}
test "Unicode NFC, full case folding, literal matching and All/Any" {
    var conditions = [_]f.Condition{
        .{ .field = .app_name, .value = "FIREFOX" },
        .{ .field = .summary, .operator = .contains, .value = "STRASSE CAFÉ" },
    };
    var rule: f.Rule = .{ .id = "one", .name = "Unicode", .conditions = &conditions };
    try t.expectEqual(.block, (try evaluate(&.{rule}, .{ .app_name = "Firefox", .summary = "Straße Cafe\u{301} done" })).decision);
    try t.expectEqual(.normal, (try evaluate(&.{rule}, .{ .app_name = "Other", .summary = "Straße Café" })).decision);
    rule.match = .any;
    try t.expectEqual(.block, (try evaluate(&.{rule}, .{ .app_name = "Other", .summary = "Straße Café" })).decision);
    conditions[1].case_sensitive = true;
    try t.expectEqual(.normal, (try evaluate(&.{rule}, .{ .summary = "Straße Café" })).decision);
}
test "overlap, enabled switches, urgency and absent desktop identity" {
    const history: f.Rule = .{ .id = "history", .name = "History", .action = .history_only, .conditions = &.{.{ .field = .urgency, .value = "critical", .case_sensitive = true }} };
    var block: f.Rule = .{ .id = "block", .name = "Block", .conditions = &.{.{ .field = .desktop_entry, .value = "org.example.App.desktop", .case_sensitive = true }} };
    const sample: f.Sample = .{ .desktop_entry = "org.example.App", .urgency = .critical };
    const result = try evaluate(&.{ history, block }, sample);
    try t.expectEqual(.block, result.decision);
    try t.expectEqual(@as(usize, 2), result.count);
    try t.expectEqual(.block, (try evaluate(&.{ block, history }, sample)).decision);
    try t.expectEqual(.history_only, (try evaluate(&.{ history, block }, .{ .urgency = .critical })).decision);
    block.enabled = false;
    try t.expectEqual(.history_only, (try evaluate(&.{ history, block }, sample)).decision);
    var compiled = try f.Compiled.init(t.allocator, .{ .filters_enabled = false, .rules = &.{history} });
    defer compiled.deinit();
    try t.expectEqual(.normal, (try compiled.evaluate(sample.record())).decision);
    try t.expectEqual(.normal, (try evaluate(&.{history}, .{})).decision);
}
test "tester shares sanitization, truncation and literal markup with ingestion" {
    const rule: f.Rule = .{ .id = "one", .name = "One", .conditions = &.{.{ .field = .summary, .value = "hi <b>字</b>" }} };
    try t.expectEqual(.block, (try evaluate(&.{rule}, .{ .summary = "hi \x1b<b>字</b>\u{202e}" })).decision);
    const tail: f.Rule = .{ .id = "tail", .name = "Tail", .conditions = &.{.{ .field = .body, .value = "tail", .operator = .contains }} };
    try t.expectEqual(.normal, (try evaluate(&.{tail}, .{ .body = "a" ** 2048 ++ "tail" })).decision);
    try t.expectEqualStrings("", (f.Sample{ .desktop_entry = "a" ** 257 }).record().desktop_entry.slice());
}
test "compiled snapshot owns patterns and IDs across caller mutation" {
    var value = "Mail".*;
    var id = "mail".*;
    var compiled = try f.Compiled.init(t.allocator, .{ .rules = &.{.{ .id = &id, .name = "Mail", .conditions = &.{.{ .field = .app_name, .value = &value }} }} });
    defer compiled.deinit();
    @memset(&value, 'x');
    @memset(&id, 'x');
    try t.expectEqual(.block, (try compiled.evaluate((f.Sample{ .app_name = "MAIL" }).record())).decision);
    try t.expectEqualStrings("mail", compiled.config.rules[0].id);
}
