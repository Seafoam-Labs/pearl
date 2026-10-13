const ffi = @import("ffi.zig");
const identity = @import("identity.zig");

pub var bus: ?*ffi.GDBusConnection = null;

pub const SessionHold = extern struct {
    flags: ffi.guint = 0,
    app: [*c]u8 = null,
    reason: [*c]u8 = null,
};

pub fn hold_free(data: ffi.gpointer) callconv(.c) void {
    const h: [*c]SessionHold = @ptrCast(@alignCast(data));
    ffi.g_free(@ptrCast(@alignCast(h.*.app)));
    ffi.g_free(@ptrCast(@alignCast(h.*.reason)));
    ffi.g_free(@ptrCast(@alignCast(h)));
}

pub var holds: ?*ffi.GHashTable = null;

pub var owner: [*c]u8 = null;

pub var watch: ffi.guint = 0;

pub var registration: ffi.guint = 0;

pub var name_id: ffi.guint = 0;

pub var end_timer: ffi.guint = 0;

pub var next_cookie: ffi.guint = 0;

pub var state: ffi.guint = 1;

pub var locked: ffi.gboolean = 0;

pub var changed: ?*const fn (?*anyopaque) callconv(.c) void = null;

pub var context: ?*anyopaque = null;

pub var end_callback: ?*const fn (?*anyopaque, ffi.gboolean) callconv(.c) void = null;

pub const xml: [420:0]u8 = "<node><interface name='org.seafoam.Pearl.Session.Inhibit'><method name='Acquire'><arg type='s' direction='in'/><arg type='u' direction='in'/><arg type='s' direction='in'/><arg type='u' direction='out'/></method><method name='Release'><arg type='u' direction='in'/></method><method name='QueryEndResponse'/><property name='Locked' type='b' access='read'/><property name='State' type='u' access='read'/></interface></node>".*;

pub fn pearl_session_portal_holds() callconv(.c) ffi.guint {
    var flags: ffi.guint = 0;
    if (holds != null) {
        var it: ffi.GHashTableIter = undefined;
        var value: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&it, holds);
        while (ffi.g_hash_table_iter_next(&it, null, &value) != 0) {
            flags |= ffi.cast([*c]SessionHold, value).*.flags;
        }
    }
    return flags;
}

pub fn pearl_session_portal_reason() callconv(.c) [*c]u8 {
    if (holds != null) {
        var it: ffi.GHashTableIter = undefined;
        var value: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&it, holds);
        while (ffi.g_hash_table_iter_next(&it, null, &value) != 0) {
            const h: [*c]SessionHold = @ptrCast(@alignCast(value));
            if ((h.*.flags & @as(ffi.guint, 1)) != 0) return ffi.g_strdup_printf("%s is preventing logout: %s", if (h.*.app.* != 0) h.*.app else @as([*c]const u8, "An application"), h.*.reason);
        }
    }
    return ffi.g_strdup("An application is preventing logout.");
}

pub fn publish() callconv(.c) void {
    if (bus == null) return;
    var b: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&b, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    ffi.g_variant_builder_add(&b, "{sv}", @constCast("Locked"), ffi.g_variant_new_boolean(locked));
    ffi.g_variant_builder_add(&b, "{sv}", @constCast("State"), ffi.g_variant_new_uint32(state));
    _ = ffi.g_dbus_connection_emit_signal(bus, null, "/org/seafoam/Pearl/Session", "org.freedesktop.DBus.Properties", "PropertiesChanged", ffi.g_variant_new("(s@a{sv}@as)", @constCast("org.seafoam.Pearl.Session.Inhibit"), ffi.g_variant_builder_end(&b), ffi.g_variant_new_strv(null, 0)), null);
}

pub fn pearl_session_portal_update(value: ffi.gboolean) callconv(.c) void {
    if (locked != value) {
        locked = value;
        publish();
    }
}

pub fn call(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, member: [*c]const u8, params: ?*ffi.GVariant, inv: ?*ffi.GDBusMethodInvocation, _: ffi.gpointer) callconv(.c) void {
    if (owner == null or (ffi.strcmp(sender, owner) != 0)) {
        ffi.g_dbus_method_invocation_return_error(inv, ffi.g_dbus_error_quark(), ffi.G_DBUS_ERROR_ACCESS_DENIED, "Only Pearl's current portal backend may coordinate inhibitors");
        return;
    }
    if (ffi.strcmp(member, "Acquire") == 0) {
        var app: [*c]const u8 = undefined;
        var reason: [*c]const u8 = undefined;
        var flags: ffi.guint = undefined;
        ffi.g_variant_get(params, "(&su&s)", &app, &flags, &reason);
        if ((((((@as(ffi.guint, @bitCast(@as(c_int, @intFromBool(flags == 0)))) != 0) or ((flags & ~@as(c_uint, 15)) != 0)) or (ffi.strlen(app) > @as(usize, 255))) or (ffi.strlen(reason) > @as(usize, 4096))) or (ffi.g_hash_table_size(holds) >= @as(ffi.guint, 256))) or (state == @as(ffi.guint, 3))) {
            ffi.g_dbus_method_invocation_return_error(inv, ffi.g_dbus_error_quark(), ffi.G_DBUS_ERROR_INVALID_ARGS, "Invalid or unavailable hold");
            return;
        }
        while (true) {
            next_cookie +%= 1;
            if (!(next_cookie == 0 or (ffi.g_hash_table_contains(holds, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, next_cookie)))) != 0))) break;
        }
        const hold: [*c]SessionHold = ffi.cast([*c]SessionHold, ffi.g_malloc0_n(1, @sizeOf(SessionHold)));
        hold.*.flags = flags;
        hold.*.app = ffi.g_strdup(app);
        hold.*.reason = ffi.g_strdup(reason);
        _ = ffi.g_hash_table_insert(holds, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, next_cookie))), @ptrCast(@alignCast(hold)));
        if (changed != null) {
            changed.?(context);
        }
        ffi.g_dbus_method_invocation_return_value(inv, ffi.g_variant_new("(u)", next_cookie));
    } else if (ffi.strcmp(member, "Release") == 0) {
        var cookie: ffi.guint = undefined;
        ffi.g_variant_get(params, "(u)", &cookie);
        _ = ffi.g_hash_table_remove(holds, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, cookie))));
        if (changed != null) {
            changed.?(context);
        }
        ffi.g_dbus_method_invocation_return_value(inv, null);
    } else {
        ffi.g_dbus_method_invocation_return_value(inv, null);
    }
}

pub fn property(_: ?*ffi.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, name: [*c]const u8, _: [*c][*c]ffi.GError, _: ffi.gpointer) callconv(.c) ?*ffi.GVariant {
    return if (ffi.strcmp(name, "Locked") == 0) ffi.g_variant_new_boolean(locked) else ffi.g_variant_new_uint32(state);
}

pub const vtable: ffi.GDBusInterfaceVTable = ffi.GDBusInterfaceVTable{
    .method_call = call,
    .get_property = property,
    .set_property = null,
    .padding = @import("std").mem.zeroes([8]ffi.gpointer),
};

pub fn appeared(_: ?*ffi.GDBusConnection, _: [*c]const u8, unique: [*c]const u8, _: ffi.gpointer) callconv(.c) void {
    ffi.g_free(@ptrCast(@alignCast(owner)));
    owner = ffi.g_strdup(unique);
    ffi.g_hash_table_remove_all(holds);
    if (changed != null) {
        changed.?(context);
    }
}

pub fn vanished(_: ?*ffi.GDBusConnection, _: [*c]const u8, _: ffi.gpointer) callconv(.c) void {
    ffi.clear(&owner, ffi.g_free);
    ffi.g_hash_table_remove_all(holds);
    if (changed != null) {
        changed.?(context);
    }
}

pub fn pearl_session_portal_start(callback: ?*const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) callconv(.c) void {
    if (bus != null) return;
    changed = callback;
    context = data;
    holds = ffi.g_hash_table_new_full(ffi.g_direct_hash, ffi.g_direct_equal, null, hold_free);
    state = 1;
    bus = ffi.g_bus_get_sync(ffi.G_BUS_TYPE_SESSION, null, null);
    if (bus == null) return;
    const node: [*c]ffi.GDBusNodeInfo = ffi.g_dbus_node_info_new_for_xml(@ptrCast(@alignCast(&xml)), null);
    defer if (node != null) ffi.g_dbus_node_info_unref(@ptrCast(node));
    registration = ffi.g_dbus_connection_register_object(bus, "/org/seafoam/Pearl/Session", node.*.f_interfaces.?[0], &vtable, null, null, null);
    if (registration != 0) {
        name_id = ffi.g_bus_own_name_on_connection(bus, "org.seafoam.Pearl.Session", ffi.G_BUS_NAME_OWNER_FLAGS_NONE, null, null, null, null);
    }
    watch = ffi.g_bus_watch_name_on_connection(bus, identity.bus_name, ffi.G_BUS_NAME_WATCHER_FLAGS_NONE, appeared, vanished, null, null);
}

pub fn finish_end(_: ffi.gpointer) callconv(.c) ffi.gboolean {
    end_timer = 0;
    const allowed: ffi.gboolean = @intFromBool(!((pearl_session_portal_holds() & @as(ffi.guint, 1)) != 0));
    state = @bitCast(@as(c_int, if (allowed != 0) @as(c_int, 3) else 1));
    publish();
    const callback: ?*const fn (?*anyopaque, ffi.gboolean) callconv(.c) void = end_callback;
    end_callback = null;
    if (callback != null) {
        callback.?(context, allowed);
    }
    return 0;
}

pub fn pearl_session_portal_begin_end(callback: ?*const fn (?*anyopaque, ffi.gboolean) callconv(.c) void) callconv(.c) void {
    if (end_timer != 0) return;
    end_callback = callback;
    state = 2;
    publish();
    end_timer = ffi.g_timeout_add(1000, finish_end, null);
}

pub fn pearl_session_portal_abort_end() callconv(.c) void {
    state = 1;
    publish();
}

pub fn pearl_session_portal_stop() callconv(.c) void {
    if (end_timer != 0) {
        _ = ffi.g_source_remove(end_timer);
    }
    end_timer = 0;
    end_callback = null;
    changed = null;
    context = null;
    if (watch != 0) {
        ffi.g_bus_unwatch_name(watch);
    }
    watch = 0;
    if (name_id != 0) {
        ffi.g_bus_unown_name(name_id);
    }
    name_id = 0;
    if (registration != 0) {
        _ = ffi.g_dbus_connection_unregister_object(bus, registration);
    }
    registration = 0;
    ffi.clear(&bus, ffi.g_object_unref);
    ffi.clear(&holds, ffi.g_hash_table_unref);
    ffi.clear(&owner, ffi.g_free);
}
