//! Keep the same native controls for each pending permission while snapshots
//! refresh. OpenCode owns the request and its decision.
const std = @import("std");
const u = @import("c.zig");
const c = u.c;
const a = u.a;
const api = @import("opencode.zig");
const i18n = @import("i18n");

const Digest = [32]u8;
const Seen = struct { owner: Digest, request: []u8, generation: u64 };
const Reply = *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void;

pub const State = struct {
    sequence: u64 = 0,
    fetch: u64 = 0,
    seen: std.ArrayList(Seen) = .empty,

    pub fn next(self: *State) u64 {
        self.sequence += 1;
        return self.sequence;
    }
    pub fn deinit(self: *State) void {
        for (self.seen.items) |item| a.free(item.request);
        self.seen.deinit(a);
    }
    pub fn present(self: *State, parent: u.W, window: u.W, server: []const u8, session: []const u8, title: []const u8, cwd: []const u8, rows: []const api.Value, context: *anyopaque, reply: Reply) void {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(server);
        hash.update(&.{0});
        hash.update(session);
        const owner = hash.finalResult();
        for (rows) |item| {
            const request = api.string(item, "id");
            const sender = api.string(item, "sessionID");
            if (request.len == 0 or !std.mem.eql(u8, sender, session)) continue;
            var card = c.gtk_widget_get_first_child(parent);
            while (card) |w| : (card = c.gtk_widget_get_next_sibling(w)) {
                if (std.mem.eql(u8, requestId(w), request)) break;
            }
            const w = card orelse makeCard(parent, request, context, reply);
            c.g_object_set_data(u.cast(c.GObject, w), "listed", @ptrFromInt(1));
            const body = details(item, title, cwd);
            defer a.free(body);
            const label = c.gtk_widget_get_first_child(w).?;
            const text = u.cast(c.GtkLabel, label);
            if (!std.mem.eql(u8, std.mem.span(c.gtk_label_get_text(text)), body)) c.gtk_label_set_text(text, body);
            setAnswerable(w, !pending(w));
            for (self.seen.items) |*known| {
                if (std.mem.eql(u8, &known.owner, &owner) and std.mem.eql(u8, known.request, request)) {
                    known.generation = self.fetch;
                    break;
                }
            } else {
                self.seen.append(a, .{ .owner = owner, .request = a.dupe(u8, request) catch unreachable, .generation = self.fetch }) catch unreachable;
                c.gtk_accessible_announce(u.cast(c.GtkAccessible, window), body, c.GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
            }
        }
        var child = c.gtk_widget_get_first_child(parent);
        while (child) |card| {
            child = c.gtk_widget_get_next_sibling(card);
            if (c.g_object_get_data(u.cast(c.GObject, card), "listed") == null) {
                c.gtk_box_remove(u.cast(c.GtkBox, parent), card);
            } else c.g_object_set_data(u.cast(c.GObject, card), "listed", null);
        }
        var i: usize = 0;
        while (i < self.seen.items.len) {
            const known = self.seen.items[i];
            if (known.generation != self.fetch and std.mem.eql(u8, &known.owner, &owner)) {
                a.free(self.seen.swapRemove(i).request);
            } else i += 1;
        }
    }
};

fn details(item: api.Value, title: []const u8, cwd: []const u8) [:0]u8 {
    var body: std.ArrayList(u8) = .empty;
    body.print(a, "{s} · OpenCode\n{s} · {s}", .{ i18n.dtr("coral", "Permission requested"), title, api.string(item, "action") }) catch unreachable;
    for (api.items(api.get(item, "resources"))) |resource| if (resource == .string) {
        body.print(a, "\n{s}", .{resource.string}) catch unreachable;
    };
    body.print(a, "\n{s} · {s}", .{ i18n.dtr("coral", "Working directory"), cwd }) catch unreachable;
    return body.toOwnedSliceSentinel(a, 0) catch unreachable;
}
pub fn requestId(card: u.W) [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(c.g_object_get_data(u.cast(c.GObject, card), "request").?)));
}
pub fn pending(card: u.W) bool {
    return c.g_object_get_data(u.cast(c.GObject, card), "reply") != null;
}
pub fn setAnswerable(card: u.W, value: bool) void {
    const actions = c.gtk_widget_get_last_child(card).?;
    var child = c.gtk_widget_get_first_child(actions);
    while (child) |button| : (child = c.gtk_widget_get_next_sibling(button)) {
        c.gtk_widget_set_sensitive(button, @intFromBool(value));
    }
}
fn makeCard(parent: u.W, request: []const u8, context: *anyopaque, reply: Reply) u.W {
    const card = u.box(false, 5);
    c.gtk_widget_add_css_class(card, "workspace-permission");
    c.g_object_set_data_full(u.cast(c.GObject, card), "request", c.g_strndup(request.ptr, request.len), &c.g_free);
    const label = u.label("");
    const attributes = c.pango_attr_list_new().?;
    defer c.pango_attr_list_unref(attributes);
    const heading = c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD).?;
    heading.*.end_index = @intCast(i18n.dtr("coral", "Permission requested").len);
    c.pango_attr_list_insert(attributes, heading);
    c.gtk_label_set_attributes(u.cast(c.GtkLabel, label), attributes);
    c.gtk_label_set_wrap(u.cast(c.GtkLabel, label), 1);
    c.gtk_label_set_wrap_mode(u.cast(c.GtkLabel, label), c.PANGO_WRAP_WORD_CHAR);
    c.gtk_label_set_selectable(u.cast(c.GtkLabel, label), 1);
    u.append(card, label);
    const actions = u.box(true, 6);
    u.append(card, actions);
    for ([_][:0]const u8{ i18n.dtr("coral", "Allow once"), i18n.dtr("coral", "Deny") }, 0..) |name, index| {
        const button = u.button(name);
        if (index == 1) c.g_object_set_data(u.cast(c.GObject, button), "deny", @ptrFromInt(1));
        u.connect(button, "clicked", reply, context);
        u.append(actions, button);
    }
    u.append(parent, card);
    return card;
}
