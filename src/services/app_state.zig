//! Publishes per-application window state to the session D-Bus surface so the
//! Background portal can answer GetAppState. An app with any open window is
//! Running (1), or Active (2) when one of its windows is focused; apps absent
//! from the map are treated as background (no window) by the portal frontend.
//! While the compositor model is not ready we publish nothing, which makes the
//! portal report failure so the frontend monitor skips supervision rather than
//! misclassifying every app as background.
const std = @import("std");
const ffi = @import("../portal/ffi.zig");
const session = @import("../portal/portal_session.zig");
const Client = @import("../aqueous/client.zig").Client;

pub fn publish(client: *const Client) void {
    if (!client.model.ready) {
        session.pearl_session_portal_set_app_state(null);
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = client.model.windows(a, .{}) catch return;
    var states = std.StringHashMap(u32).init(a);
    for (windows) |win| {
        const id = win.app_id orelse continue;
        if (id.len == 0 or id.len > 255) continue;
        const state: u32 = if (win.focused) 2 else 1;
        const slot = states.getOrPut(id) catch continue;
        if (!slot.found_existing or state > slot.value_ptr.*) slot.value_ptr.* = state;
    }
    var builder: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&builder, ffi.g_variant_type_checked_("a{sv}"));
    var it = states.iterator();
    while (it.next()) |entry| {
        const key = a.dupeSentinel(u8, entry.key_ptr.*, 0) catch continue;
        ffi.g_variant_builder_add(&builder, "{sv}", key.ptr, ffi.g_variant_new_uint32(entry.value_ptr.*));
    }
    session.pearl_session_portal_set_app_state(ffi.g_variant_builder_end(&builder));
}
