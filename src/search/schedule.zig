//! Pure quiet-window policy for automatic semantic indexing. No GTK, no I/O:
//! the service gathers signal snapshots and feeds them in. Automatic work runs
//! primarily when the computer is idle or in low use, in bounded bursts that
//! stop promptly when the user returns; explicit Index now bypasses all of it.
const std = @import("std");
const config = @import("../agent/config.zig");
pub const Pending = enum { none, incremental, full };
pub const Class = enum { idle, low_use };
pub const Reason = enum {
    nothing_pending,
    disabled,
    manual_only,
    locked,
    running,
    chat_busy,
    sleep_pending,
    inhibited,
    power_saver,
    memory,
    login_grace,
    events_active,
    battery,
    not_idle,
    idle_unavailable,
    typing,
    load,
    quiet_interval,
    breather,
    no_folders,
    model_missing,
};
pub const Decision = union(enum) {
    wait: Reason,
    start: struct { class: Class, budget_us: i64 },
};
pub const Signals = struct {
    enabled: bool = false,
    background: config.Background = .idle_low_use,
    locked: bool = true,
    indexing: bool = false,
    chat_busy: bool = false,
    sleep_pending: bool = false,
    inhibited: bool = false,
    typing: bool = false,
    idle: bool = false,
    idle_available: bool = false,
    on_battery: bool = false,
    battery_present: bool = false,
    battery_charging: bool = false,
    battery_percent: u8 = 0,
    power_saver: bool = false,
    load_low: bool = false,
    memory_ok: bool = true,
    events_quiet: bool = true,
    now_us: i64 = 0,
    startup_us: i64 = 0,
};
pub const State = struct {
    /// A logical automatic pass spans bursts; continuations skip the quiet
    /// interval so interrupted work resumes promptly in the next window.
    pass_active: bool = false,
    last_burst_end_us: i64 = 0,
};
pub const maintenance_idle_seconds: u32 = 180;
pub const idle_burst_us: i64 = 120 * std.time.us_per_s;
pub const low_use_burst_us: i64 = 15 * std.time.us_per_s;
pub const quiet_interval_us: i64 = 5 * 60 * std.time.us_per_s;
pub const login_grace_us: i64 = 120 * std.time.us_per_s;
pub const breather_us: i64 = 2 * std.time.us_per_s;
pub const event_debounce_us: i64 = 2 * std.time.us_per_s;
pub const rescan_interval_us: i64 = 6 * 60 * 60 * std.time.us_per_s;
pub const battery_floor: u8 = 50;

fn chargeOk(s: Signals) bool {
    return s.battery_charging or (s.battery_present and s.battery_percent >= battery_floor);
}
/// Window availability ignoring timing/pending — also used to cancel a running
/// automatic burst the moment its window closes.
pub fn class(s: Signals) ?Class {
    if (s.locked or s.chat_busy or s.sleep_pending or s.inhibited or s.power_saver or !s.memory_ok) return null;
    if (s.on_battery) {
        if (!chargeOk(s)) return null;
        return if (s.idle) .idle else null; // No low-use bursts on battery.
    }
    if (s.idle) return .idle;
    if (s.background == .idle_only) return null;
    if (s.typing or !s.load_low) return null;
    return .low_use;
}
pub fn evaluate(s: Signals, pending: Pending, st: State) Decision {
    if (!s.enabled) return .{ .wait = .disabled };
    if (pending == .none) return .{ .wait = .nothing_pending };
    if (s.background == .manual) return .{ .wait = .manual_only };
    if (s.locked) return .{ .wait = .locked };
    if (s.indexing) return .{ .wait = .running };
    if (s.chat_busy) return .{ .wait = .chat_busy };
    if (s.sleep_pending) return .{ .wait = .sleep_pending };
    if (s.inhibited) return .{ .wait = .inhibited };
    if (s.power_saver) return .{ .wait = .power_saver };
    if (!s.memory_ok) return .{ .wait = .memory };
    if (s.now_us - s.startup_us < login_grace_us) return .{ .wait = .login_grace };
    if (!s.events_quiet) return .{ .wait = .events_active };
    const cls = class(s) orelse {
        if (s.on_battery) return .{ .wait = if (chargeOk(s)) .not_idle else .battery };
        if (s.background == .idle_only) return .{ .wait = if (s.idle_available) .not_idle else .idle_unavailable };
        if (s.typing) return .{ .wait = .typing };
        if (!s.load_low) return .{ .wait = .load };
        return .{ .wait = .not_idle };
    };
    if (st.pass_active) {
        if (s.now_us - st.last_burst_end_us < breather_us) return .{ .wait = .breather };
    } else if (st.last_burst_end_us != 0 and s.now_us - st.last_burst_end_us < quiet_interval_us) {
        return .{ .wait = .quiet_interval };
    }
    return .{ .start = .{ .class = cls, .budget_us = if (cls == .idle) idle_burst_us else low_use_burst_us } };
}
pub const Diff = struct { removed: bool = false, added: bool = false };
pub fn folderDiff(old: []const []const u8, new: []const []const u8) Diff {
    var result: Diff = .{};
    for (old) |folder| {
        var found = false;
        for (new) |candidate| if (std.mem.eql(u8, folder, candidate)) {
            found = true;
            break;
        };
        if (!found) result.removed = true;
    }
    for (new) |folder| {
        var found = false;
        for (old) |candidate| if (std.mem.eql(u8, folder, candidate)) {
            found = true;
            break;
        };
        if (!found) result.added = true;
    }
    return result;
}
fn base() Signals {
    return .{ .enabled = true, .locked = false, .idle = true, .idle_available = true, .now_us = 10_000 * std.time.us_per_s, .startup_us = 0 };
}
test "idle windows start bounded bursts and respect every veto" {
    const t = std.testing;
    const start = evaluate(base(), .incremental, .{});
    try t.expect(start == .start);
    try t.expectEqual(Class.idle, start.start.class);
    try t.expectEqual(idle_burst_us, start.start.budget_us);
    inline for (.{ "locked", "chat_busy", "sleep_pending", "inhibited", "power_saver" }) |field| {
        var s = base();
        @field(s, field) = true;
        try t.expect(evaluate(s, .incremental, .{}) == .wait);
    }
    var s = base();
    s.memory_ok = false;
    try t.expectEqual(Reason.memory, evaluate(s, .incremental, .{}).wait);
    s = base();
    s.enabled = false;
    try t.expectEqual(Reason.disabled, evaluate(s, .incremental, .{}).wait);
    try t.expectEqual(Reason.nothing_pending, evaluate(base(), .none, .{}).wait);
    s = base();
    s.background = .manual;
    try t.expectEqual(Reason.manual_only, evaluate(s, .incremental, .{}).wait);
}
test "low-use windows need confirmed load, no typing and AC power" {
    const t = std.testing;
    var s = base();
    s.idle = false;
    s.load_low = true;
    const start = evaluate(s, .incremental, .{});
    try t.expect(start == .start);
    try t.expectEqual(Class.low_use, start.start.class);
    try t.expectEqual(low_use_burst_us, start.start.budget_us);
    s.typing = true;
    try t.expectEqual(Reason.typing, evaluate(s, .incremental, .{}).wait);
    s.typing = false;
    s.load_low = false;
    try t.expectEqual(Reason.load, evaluate(s, .incremental, .{}).wait);
    s.load_low = true;
    s.background = .idle_only;
    try t.expectEqual(Reason.not_idle, evaluate(s, .incremental, .{}).wait);
    s.background = .idle_low_use;
    s.on_battery = true;
    s.battery_present = true;
    s.battery_charging = true;
    try t.expectEqual(Reason.not_idle, evaluate(s, .incremental, .{}).wait);
}
test "battery rules gate idle windows and never allow low-use bursts" {
    const t = std.testing;
    var s = base();
    s.on_battery = true;
    s.battery_present = true;
    s.battery_percent = 40;
    try t.expectEqual(Reason.battery, evaluate(s, .incremental, .{}).wait);
    s.battery_percent = 60;
    try t.expect(evaluate(s, .incremental, .{}) == .start);
    s.battery_percent = 40;
    s.battery_charging = true;
    try t.expect(evaluate(s, .incremental, .{}) == .start);
    s.idle = false;
    s.load_low = true;
    try t.expectEqual(Reason.not_idle, evaluate(s, .incremental, .{}).wait);
}
test "degraded idle source falls back to low-use except in idle-only mode" {
    const t = std.testing;
    var s = base();
    s.idle = false;
    s.idle_available = false;
    s.load_low = true;
    try t.expect(evaluate(s, .incremental, .{}) == .start);
    s.background = .idle_only;
    try t.expectEqual(Reason.idle_unavailable, evaluate(s, .incremental, .{}).wait);
}
test "login grace, event debounce, quiet interval and burst breathers gate starts" {
    const t = std.testing;
    var s = base();
    s.startup_us = s.now_us - 30 * std.time.us_per_s;
    try t.expectEqual(Reason.login_grace, evaluate(s, .incremental, .{}).wait);
    s.startup_us = 0;
    s.events_quiet = false;
    try t.expectEqual(Reason.events_active, evaluate(s, .incremental, .{}).wait);
    s.events_quiet = true;
    const ended: State = .{ .pass_active = false, .last_burst_end_us = s.now_us - 60 * std.time.us_per_s };
    try t.expectEqual(Reason.quiet_interval, evaluate(s, .incremental, ended).wait);
    const active: State = .{ .pass_active = true, .last_burst_end_us = s.now_us - 1 * std.time.us_per_s };
    try t.expectEqual(Reason.breather, evaluate(s, .incremental, active).wait);
    const rested: State = .{ .pass_active = true, .last_burst_end_us = s.now_us - 3 * std.time.us_per_s };
    try t.expect(evaluate(s, .incremental, rested) == .start);
    const old: State = .{ .pass_active = false, .last_burst_end_us = s.now_us - 6 * 60 * std.time.us_per_s };
    try t.expect(evaluate(s, .incremental, old) == .start);
}
test "folder diff detects additions and removals independently" {
    const t = std.testing;
    const a = [_][]const u8{ "/docs", "/notes" };
    const b = [_][]const u8{ "/docs", "/music" };
    const diff = folderDiff(&a, &b);
    try t.expect(diff.removed and diff.added);
    try t.expect(!folderDiff(&a, &a).removed and !folderDiff(&a, &a).added);
    try t.expect(folderDiff(&a, a[0..1]).removed and !folderDiff(&a, a[0..1]).added);
    try t.expect(!folderDiff(a[0..1], &a).removed and folderDiff(a[0..1], &a).added);
}
