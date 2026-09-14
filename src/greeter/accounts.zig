//! Optional account labels only. Lookup is never an authentication decision.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
pub const Account = struct { username: []const u8, label: []const u8 };
pub fn load(a: std.mem.Allocator, cancel: *gio.Cancellable) ![]const Account {
    const bus = gio.busGetSync(.system, cancel, null) orelse return &.{};
    defer bus.unref();
    const answer = bus.callSync("org.freedesktop.Accounts", "/org/freedesktop/Accounts", "org.freedesktop.Accounts", "ListCachedUsers", null, null, .{ .no_auto_start = true }, 1000, cancel, null) orelse return &.{};
    defer answer.unref();
    if (!std.mem.eql(u8, std.mem.span(answer.getTypeString()), "(ao)")) return error.InvalidAccounts;
    const list = answer.getChildValue(0);
    defer list.unref();
    if (list.nChildren() > 256) return error.AccountLimit;
    var accounts: std.ArrayList(Account) = .empty;
    const deadline = glib.getMonotonicTime() + 5000000;
    for (0..list.nChildren()) |i| {
        if (cancel.isCancelled() != 0 or glib.getMonotonicTime() > deadline) break;
        const item = list.getChildValue(i);
        defer item.unref();
        const args = [_]*glib.Variant{glib.Variant.newString("org.freedesktop.Accounts.User")};
        const props = bus.callSync("org.freedesktop.Accounts", item.getString(null), "org.freedesktop.DBus.Properties", "GetAll", glib.Variant.newTuple(&args, args.len), null, .{ .no_auto_start = true }, 500, cancel, null) orelse continue;
        defer props.unref();
        if (!std.mem.eql(u8, std.mem.span(props.getTypeString()), "(a{sv})")) continue;
        const dict = props.getChildValue(0);
        defer dict.unref();
        const system = dict.lookupValue("SystemAccount", null);
        if (@intFromPtr(system) == 0) continue;
        defer system.unref();
        if (!std.mem.eql(u8, std.mem.span(system.getTypeString()), "b") or system.getBoolean() != 0) continue;
        const user = dict.lookupValue("UserName", null);
        if (@intFromPtr(user) == 0) continue;
        defer user.unref();
        if (!std.mem.eql(u8, std.mem.span(user.getTypeString()), "s")) continue;
        const name = std.mem.span(user.getString(null));
        if (name.len == 0 or !@import("protocol.zig").validText(name, 256)) continue;
        try accounts.append(a, .{ .username = try a.dupe(u8, name), .label = try a.dupe(u8, name) });
    }
    return accounts.toOwnedSlice(a);
}
