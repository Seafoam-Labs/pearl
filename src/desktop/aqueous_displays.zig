//! Canonical display observation. Never resolve declarations or serialize TOML here.
const std = @import("std");
const gtk = @import("gtk4");
const m = @import("../config/aqueous_model.zig");
const c = @import("../config/aqueous_contract.zig");
const w = @import("../ui/components/widgets.zig");
pub fn render(view: anytype, box: *gtk.Box, snapshot: m.Value) !void {
    const a = view.arena.allocator();
    box.append(w.label("Aqueous owns the preview deadline and rollback. Keep authorizes one durable save. Hardware preview is unavailable in this master build; headless previews can be tested.", "pearl-secondary").as(gtk.Widget));
    const observation = m.get(snapshot, "display_observation");
    view.placement_box = w.column(4);
    box.append(view.placement_box.?.as(gtk.Widget));
    try refreshPlacement(view);
    if (m.get(observation, "outputs") == .null) {
        box.append(w.label("Live display observation unavailable. Refresh after reconnecting to Aqueous.", "pearl-secondary").as(gtk.Widget));
    }
    for (m.list(m.get(observation, "outputs"))) |output| {
        const card = w.card();
        box.append(card.as(gtk.Widget));
        const enabled = m.get(output, "enabled");
        card.append(w.label(view.z(try std.fmt.allocPrint(a, "{s} · {s} · instance {s}", .{ m.str(m.get(output, "connector")), if (enabled == .bool and enabled.bool) "connected, enabled" else "connected, disabled", m.str(m.get(output, "instance")) })), "pearl-title").as(gtk.Widget));
        try view.inventory(card, output, "actual", "Actual mode, geometry and color");
        try view.inventory(card, output, "configured", "Explicit and inherited values, declarations and precedence");
        try view.inventory(card, output, "monitor_identity", "Monitor identity and ambiguous matching");
        try view.inventory(card, output, "modes", "Advertised modes");
        const support = m.get(output, "support");
        if (support == .object) {
            var entries = support.object.iterator();
            while (entries.next()) |e| {
                const s = try c.Support.read(e.value_ptr.*);
                card.append(w.label(view.z(try std.fmt.allocPrint(a, "{s}: store {s}, test {s}, preview {s}{s}{s}", .{ e.key_ptr.*, yes(s.store), yes(s.test_), yes(s.preview), if (s.reason != null) " · " else "", s.reason orelse "" })), "pearl-secondary").as(gtk.Widget));
            }
        }
    }
    // These models include disconnected declarations, profile membership and source order.
    try view.inventory(box, snapshot, "display_model", "All declarations: configured offline displays, profiles, policy and precedence");
    for ([_][2][]const u8{ .{ "Enable / disable", "Enablement" }, .{ "Primary output", "Primary selection" }, .{ "Profiles and fallback", "Profile CRUD and membership" }, .{ "Identity matching", "Connector patterns and monitor identity" }, .{ "HDR / VRR", "HDR, SDR white level, auto HDR and adaptive sync" } }) |item| {
        const row = w.column(4);
        box.append(row.as(gtk.Widget));
        const button = gtk.Button.newWithLabel(view.z(item[0]));
        button.as(gtk.Widget).setSensitive(0);
        row.append(button.as(gtk.Widget));
        row.append(w.label(view.z(try std.fmt.allocPrint(a, "{s}: structured editing requires an Aqueous helper addition. Advanced retains the canonical raw editor; all display saves still require a native lease.", .{item[1]})), "pearl-secondary").as(gtk.Widget));
    }
}
pub fn refreshPlacement(view: anytype) !void {
    const box = view.placement_box orelse return;
    while (box.as(gtk.Widget).getFirstChild()) |child| box.remove(child);
    const observation = m.get(view.client.baseValue(), "display_observation");
    const a = view.arena.allocator();
    const Head = struct { name: []const u8, x: f64, y: f64, width: f64, height: f64 };
    var heads: std.ArrayList(Head) = .empty;
    const draft = try m.parse(a, view.client.draft orelse "{}", m.max_request);
    var left: f64 = std.math.inf(f64);
    var top = left;
    var right: f64 = -left;
    var bottom = right;
    for (m.list(m.get(observation, "outputs"))) |output| {
        const actual = m.get(output, "actual");
        if (!m.equal(m.get(actual, "enabled"), .{ .bool = true })) continue;
        const name = m.str(m.get(output, "connector"));
        var x = number(m.get(actual, "x"), 0);
        var y = number(m.get(actual, "y"), 0);
        var scale = number(m.get(actual, "scale"), 1);
        var transform = m.str(m.get(actual, "transform"));
        for (m.list(m.get(draft, "monitor_changes"))) |change| {
            if (!std.mem.eql(u8, name, m.str(m.get(change, "name")))) continue;
            x = number(m.get(change, "x"), x);
            y = number(m.get(change, "y"), y);
            scale = number(m.get(change, "scale"), scale);
            if (m.get(change, "transform") == .string) transform = m.str(m.get(change, "transform"));
        }
        if (scale < 0.1 or scale > 16 or !std.math.isFinite(scale) or @abs(x) > 10000000 or @abs(y) > 10000000) continue;
        const mode = m.get(actual, "mode");
        var width = number(m.get(mode, "width"), 0) / scale;
        var height = number(m.get(mode, "height"), 0) / scale;
        if (std.mem.endsWith(u8, transform, "90") or std.mem.endsWith(u8, transform, "270")) std.mem.swap(f64, &width, &height);
        if (width <= 0 or height <= 0 or width > 1000000 or height > 1000000) continue;
        try heads.append(a, .{ .name = name, .x = x, .y = y, .width = width, .height = height });
        left = @min(left, x);
        top = @min(top, y);
        right = @max(right, x + width);
        bottom = @max(bottom, y + height);
    }
    if (heads.items.len == 0) return;
    box.append(w.label("Placement preview · current mode sizes; staged position, scale and rotation", "pearl-secondary").as(gtk.Widget));
    const fixed = gtk.Fixed.new();
    fixed.as(gtk.Widget).setSizeRequest(360, 180);
    box.append(fixed.as(gtk.Widget));
    const ratio = @min(340 / @max(1, right - left), 160 / @max(1, bottom - top));
    for (heads.items) |head| {
        const frame = gtk.Frame.new(null);
        frame.as(gtk.Widget).setSizeRequest(@intFromFloat(@max(1, head.width * ratio)), @intFromFloat(@max(1, head.height * ratio)));
        w.name(frame.as(gtk.Widget), view.z(try std.fmt.allocPrint(a, "{s}: {d:.0}, {d:.0}; {d:.0} by {d:.0}", .{ head.name, head.x, head.y, head.width, head.height })));
        // Geometry remains exact even when a tiny preview cannot fit its label.
        fixed.put(frame.as(gtk.Widget), 10 + (head.x - left) * ratio, 10 + (head.y - top) * ratio);
        box.append(w.label(view.z(try std.fmt.allocPrint(a, "{s}: origin {d:.0}, {d:.0} · logical size {d:.0} × {d:.0}", .{ head.name, head.x, head.y, head.width, head.height })), "pearl-secondary").as(gtk.Widget));
    }
}
fn number(v: m.Value, fallback: f64) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => if (std.math.isFinite(v.float)) v.float else fallback,
        else => fallback,
    };
}
fn yes(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
pub fn editable(snapshot: m.Value, connector: []const u8, property: []const u8) bool {
    const observation = m.get(snapshot, "display_observation");
    for (m.list(m.get(observation, "outputs"))) |output| {
        if (!std.mem.eql(u8, connector, m.str(m.get(output, "connector")))) continue;
        const support = c.Support.read(m.get(m.get(output, "support"), property)) catch return false;
        return support.store and support.preview;
    }
    // Offline edits also need a lease; upstream tests all connected heads.
    const outputs = m.list(m.get(observation, "outputs"));
    if (outputs.len == 0) return false;
    for (outputs) |output| {
        const support = c.Support.read(m.get(m.get(output, "support"), property)) catch return false;
        if (!support.preview or !support.store) return false;
    }
    return true;
}
