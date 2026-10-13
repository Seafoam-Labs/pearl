const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
pub const Inhibitors = extern struct {
    portal: [*c]Portal = null,
    holds: ?*ffi.GHashTable = null,
    monitors: ?*ffi.GHashTable = null,
    shell: [*c]u8 = null,
    watch: ffi.guint = 0,
    signal: ffi.guint = 0,
    ready: ffi.gboolean = 0,
    locked: ffi.gboolean = 0,
    state: ffi.guint = 0,
};
const Portal = @import("types.zig").Portal;
const portal_error = @import("backend.zig").portal_error;
const portal_string = @import("backend.zig").portal_string;
const registration = @import("portal_session.zig").registration;
const xml_Request = @import("contracts.zig").xml_Request;
const xml_Session = @import("contracts.zig").xml_Session;

pub const Hold = extern struct {
    refs: ffi.gint = 0,
    service: [*c]Inhibitors = null,
    path: [*c]u8 = null,
    sender: [*c]u8 = null,
    app: [*c]u8 = null,
    reason: [*c]u8 = null,
    shell: [*c]u8 = null,
    flags: ffi.guint = 0,
    cookie: ffi.guint = 0,
    registration: ffi.guint = 0,
    fd: c_int = 0,
    closed: ffi.gboolean = 0,
    call: ?*ffi.GDBusMethodInvocation = null,
    cancel: [*c]ffi.GCancellable = null,
};

pub const Monitor = extern struct {
    service: [*c]Inhibitors = null,
    path: [*c]u8 = null,
    sender: [*c]u8 = null,
    registration: ffi.guint = 0,
    waiting: ffi.gboolean = 0,
};

pub fn hold_ref(h: [*c]Hold) callconv(.c) [*c]Hold {
    h.*.refs += 1;
    return h;
}

pub fn release_cookie(h: [*c]Hold) callconv(.c) void {
    if (h.*.cookie != 0) {
        ffi.g_dbus_connection_call(h.*.service.*.portal.*.bus, h.*.shell, "/org/seafoam/Pearl/Session", "org.seafoam.Pearl.Session.Inhibit", "Release", ffi.g_variant_new("(u)", h.*.cookie), null, ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, null, null, null);
        h.*.cookie = 0;
    }
}

pub fn hold_unref(h: [*c]Hold) callconv(.c) void {
    if ((blk: {
        const ref = &h.*.refs;
        ref.* -= 1;
        break :blk ref.*;
    }) != 0) return;
    release_cookie(h);
    if (h.*.fd >= 0) {
        _ = ffi.close(h.*.fd);
    }
    ffi.clear(&h.*.call, ffi.g_object_unref);
    ffi.g_object_unref(@ptrCast(@alignCast(h.*.cancel)));
    ffi.g_free(@ptrCast(@alignCast(h.*.path)));
    ffi.g_free(@ptrCast(@alignCast(h.*.sender)));
    ffi.g_free(@ptrCast(@alignCast(h.*.app)));
    ffi.g_free(@ptrCast(@alignCast(h.*.reason)));
    ffi.g_free(@ptrCast(@alignCast(h.*.shell)));
    ffi.g_free(@ptrCast(@alignCast(h)));
}

pub fn hold_close(h: [*c]Hold) callconv(.c) void {
    if (h.*.closed != 0) return;
    h.*.closed = 1;
    ffi.g_cancellable_cancel(h.*.cancel);
    release_cookie(h);
    if (h.*.fd >= 0) {
        _ = ffi.close(h.*.fd);
        h.*.fd = -1;
    }
    if (h.*.registration != 0) {
        _ = ffi.g_dbus_connection_unregister_object(h.*.service.*.portal.*.bus, h.*.registration);
    }
    if (h.*.call != null) {
        portal_error(h.*.call, "Cancelled", "Inhibition was cancelled");
        ffi.clear(&h.*.call, ffi.g_object_unref);
    }
    _ = ffi.g_hash_table_remove(h.*.service.*.holds, @ptrCast(@alignCast(h.*.path)));
}

pub fn close_hold(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation, data: ffi.gpointer) callconv(.c) void {
    const h: [*c]Hold = @ptrCast(@alignCast(data));
    if (ffi.strcmp(sender, h.*.sender) != 0) {
        portal_error(call, "NotAllowed", "Hold belongs to another sender");
        return;
    }
    ffi.g_dbus_method_invocation_return_value(call, null);
    hold_close(h);
}

pub const hold_vtable: ffi.GDBusInterfaceVTable = ffi.GDBusInterfaceVTable{
    .method_call = close_hold,
    .get_property = null,
    .set_property = null,
    .padding = @import("std").mem.zeroes([8]ffi.gpointer),
};

pub fn monitor_free(data: ffi.gpointer) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    _ = ffi.g_dbus_connection_unregister_object(m.*.service.*.portal.*.bus, m.*.registration);
    ffi.g_free(@ptrCast(@alignCast(m.*.path)));
    ffi.g_free(@ptrCast(@alignCast(m.*.sender)));
    ffi.g_free(@ptrCast(@alignCast(m)));
}

pub fn close_monitor(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation, data: ffi.gpointer) callconv(.c) void {
    const m: [*c]Monitor = @ptrCast(@alignCast(data));
    if (ffi.strcmp(sender, m.*.sender) != 0) {
        portal_error(call, "NotAllowed", "Monitor belongs to another sender");
        return;
    }
    ffi.g_dbus_method_invocation_return_value(call, null);
    _ = ffi.g_hash_table_remove(m.*.service.*.monitors, @ptrCast(@alignCast(m.*.path)));
}

pub const monitor_vtable: ffi.GDBusInterfaceVTable = ffi.GDBusInterfaceVTable{
    .method_call = close_monitor,
    .get_property = null,
    .set_property = null,
    .padding = @import("std").mem.zeroes([8]ffi.gpointer),
};

pub fn emit_state(m: [*c]Monitor) callconv(.c) void {
    const s: [*c]Inhibitors = m.*.service;
    var b: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&b, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    ffi.g_variant_builder_add(&b, "{sv}", @constCast("screensaver-active"), ffi.g_variant_new_boolean(s.*.locked));
    ffi.g_variant_builder_add(&b, "{sv}", @constCast("session-state"), ffi.g_variant_new_uint32(s.*.state));
    m.*.waiting = @intFromBool(s.*.state == @as(ffi.guint, 2));
    _ = ffi.g_dbus_connection_emit_signal(s.*.portal.*.bus, m.*.sender, "/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Inhibit", "StateChanged", ffi.g_variant_new("(o@a{sv})", m.*.path, ffi.g_variant_builder_end(&b)), null);
}

pub fn state_read(s: [*c]Inhibitors, values: ?*ffi.GVariant) callconv(.c) void {
    var locked: ffi.gboolean = s.*.locked;
    var state: ffi.guint = s.*.state;
    _ = ffi.g_variant_lookup(values, "Locked", "b", &locked);
    _ = ffi.g_variant_lookup(values, "State", "u", &state);
    if ((state < @as(ffi.guint, 1)) or (state > @as(ffi.guint, 3))) return;
    const change: ffi.gboolean = @intFromBool(((locked != s.*.locked) or (state != s.*.state)) or s.*.ready == 0);
    s.*.locked = locked;
    s.*.state = state;
    s.*.ready = 1;
    if (change != 0) {
        var it: ffi.GHashTableIter = undefined;
        var m: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&it, s.*.monitors);
        while (ffi.g_hash_table_iter_next(&it, null, &m) != 0) {
            emit_state(@ptrCast(@alignCast(m)));
        }
    }
}

pub fn shell_signal(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*ffi.GVariant, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(data));
    if ((s.*.shell == null or (ffi.strcmp(sender, s.*.shell) != 0)) or ffi.g_variant_is_of_type(params, ffi.g_variant_type_checked_("(sa{sv}as)")) == 0) return;
    var changed: [*c]const u8 = undefined;
    ffi.g_variant_get_child(params, 0, "&s", &changed);
    if (ffi.strcmp(changed, "org.seafoam.Pearl.Session.Inhibit") != 0) return;
    const values: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 1);
    defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
    state_read(s, values);
}

pub fn appeared(c: ?*ffi.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(data));
    portal_inhibit_clear(s.*.portal);
    ffi.g_free(@ptrCast(@alignCast(s.*.shell)));
    s.*.shell = ffi.g_strdup(owner);
    s.*.ready = 0;
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_sync(c, owner, "/org/seafoam/Pearl/Session", "org.freedesktop.DBus.Properties", "GetAll", ffi.g_variant_new("(s)", @constCast("org.seafoam.Pearl.Session.Inhibit")), ffi.g_variant_type_checked_("(a{sv})"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, null, null);
    defer if (reply != null) ffi.g_variant_unref(@ptrCast(reply));
    if (reply != null) {
        const values: ?*ffi.GVariant = ffi.g_variant_get_child_value(reply, 0);
        defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
        state_read(s, values);
    }
}

pub fn vanished(_: ?*ffi.GDBusConnection, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(data));
    portal_inhibit_clear(s.*.portal);
    ffi.clear(&s.*.shell, ffi.g_free);
    s.*.ready = 0;
}

pub fn acquired(h: [*c]Hold, success: ffi.gboolean) callconv(.c) void {
    if (h.*.closed != 0) return;
    if (success != 0) {
        ffi.g_dbus_method_invocation_return_value(h.*.call, null);
        ffi.clear(&h.*.call, ffi.g_object_unref);
    } else {
        portal_error(h.*.call, "Failed", "Could not acquire all requested session holds");
        ffi.clear(&h.*.call, ffi.g_object_unref);
        hold_close(h);
    }
}

pub fn logind_done(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const h: [*c]Hold = @ptrCast(@alignCast(data));
    var fds: [*c]ffi.GUnixFDList = null;
    defer if (fds != null) ffi.g_object_unref(@ptrCast(fds));
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_with_unix_fd_list_finish(ffi.cast(?*ffi.GDBusConnection, source), &fds, result, null);
    defer if (reply != null) ffi.g_variant_unref(@ptrCast(reply));
    if (((reply != null) and (fds != null)) and h.*.closed == 0) {
        var index_1: ffi.gint = undefined;
        ffi.g_variant_get(reply, "(h)", &index_1);
        h.*.fd = ffi.g_unix_fd_list_get(fds, index_1, null);
    }
    acquired(h, @intFromBool(h.*.fd >= 0));
    hold_unref(h);
}

pub fn shell_acquired(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const h: [*c]Hold = @ptrCast(@alignCast(data));
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_finish(ffi.cast(?*ffi.GDBusConnection, source), result, null);
    defer if (reply != null) ffi.g_variant_unref(@ptrCast(reply));
    if (reply != null) {
        ffi.g_variant_get(reply, "(u)", &h.*.cookie);
    }
    if (h.*.closed != 0) {
        release_cookie(h);
        hold_unref(h);
        return;
    }
    if (h.*.cookie == 0) {
        acquired(h, 0);
        hold_unref(h);
        return;
    }
    if (!((h.*.flags & @as(ffi.guint, 12)) != 0)) {
        acquired(h, 1);
        hold_unref(h);
        return;
    }
    const system_1: ?*ffi.GDBusConnection = ffi.g_bus_get_sync(ffi.G_BUS_TYPE_SYSTEM, h.*.cancel, null);
    defer if (system_1 != null) ffi.g_object_unref(@ptrCast(system_1));
    if (system_1 == null) {
        acquired(h, 0);
        hold_unref(h);
        return;
    }
    const what: [*c]const u8 = if ((h.*.flags & @as(ffi.guint, 12)) == @as(ffi.guint, 12)) @constCast("sleep:idle") else if ((h.*.flags & @as(ffi.guint, 4)) != 0) @constCast("sleep") else @constCast("idle");
    ffi.g_dbus_connection_call_with_unix_fd_list(system_1, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", ffi.g_variant_new("(ssss)", what, h.*.app, h.*.reason, @constCast("block")), ffi.g_variant_type_checked_("(h)"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, null, h.*.cancel, logind_done, @ptrCast(@alignCast(h)));
}

pub fn portal_inhibit_clear(p: [*c]Portal) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(p.*.inhibitors));
    if (s == null) return;
    while (ffi.g_hash_table_size(s.*.holds) != 0) {
        var it: ffi.GHashTableIter = undefined;
        var h: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&it, s.*.holds);
        _ = ffi.g_hash_table_iter_next(&it, null, &h);
        hold_close(@ptrCast(@alignCast(h)));
    }
    var it: ffi.GHashTableIter = undefined;
    var value: ffi.gpointer = undefined;
    ffi.g_hash_table_iter_init(&it, s.*.monitors);
    while (ffi.g_hash_table_iter_next(&it, null, &value) != 0) {
        const m: [*c]Monitor = @ptrCast(@alignCast(value));
        _ = ffi.g_dbus_connection_emit_signal(p.*.bus, m.*.sender, m.*.path, "org.freedesktop.impl.portal.Session", "Closed", null, null);
    }
    ffi.g_hash_table_remove_all(s.*.monitors);
}

pub fn portal_inhibit_init(p: [*c]Portal) callconv(.c) void {
    const s: [*c]Inhibitors = ffi.cast([*c]Inhibitors, ffi.g_malloc0_n(1, @sizeOf(Inhibitors)));
    p.*.inhibitors = @ptrCast(@alignCast(s));
    s.*.portal = p;
    s.*.state = 1;
    s.*.holds = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, null, @ptrCast(@alignCast(@constCast(&hold_unref))));
    s.*.monitors = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, null, monitor_free);
    s.*.signal = ffi.g_dbus_connection_signal_subscribe(p.*.bus, null, "org.freedesktop.DBus.Properties", "PropertiesChanged", "/org/seafoam/Pearl/Session", null, ffi.G_DBUS_SIGNAL_FLAGS_NONE, shell_signal, @ptrCast(@alignCast(s)), null);
    s.*.watch = ffi.g_bus_watch_name_on_connection(p.*.bus, "org.seafoam.Pearl.Session", ffi.G_BUS_NAME_WATCHER_FLAGS_NONE, appeared, vanished, @ptrCast(@alignCast(s)), null);
}

pub fn portal_inhibit_stop(p: [*c]Portal) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(p.*.inhibitors));
    portal_inhibit_clear(p);
    ffi.g_bus_unwatch_name(s.*.watch);
    ffi.g_dbus_connection_signal_unsubscribe(p.*.bus, s.*.signal);
    ffi.g_hash_table_unref(s.*.holds);
    ffi.g_hash_table_unref(s.*.monitors);
    ffi.g_free(@ptrCast(@alignCast(s.*.shell)));
    ffi.g_free(@ptrCast(@alignCast(s)));
    p.*.inhibitors = null;
}

pub fn portal_inhibit(p: [*c]Portal, method: [*c]const u8, params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    const s: [*c]Inhibitors = @ptrCast(@alignCast(p.*.inhibitors));
    const sender: [*c]const u8 = ffi.g_dbus_method_invocation_get_sender(call);
    if (s.*.ready == 0 or s.*.shell == null) {
        portal_error(call, "Failed", "Pearl session coordination is unavailable");
        return;
    }
    if (ffi.strcmp(method, "QueryEndResponse") == 0) {
        var path: [*c]const u8 = undefined;
        ffi.g_variant_get(params, "(&o)", &path);
        const m: [*c]Monitor = @ptrCast(@alignCast(ffi.g_hash_table_lookup(s.*.monitors, @ptrCast(@alignCast(path)))));
        if ((m == null or (ffi.strcmp(m.*.sender, sender) != 0)) or m.*.waiting == 0) {
            portal_error(call, "InvalidArgument", "No pending query for this session");
            return;
        }
        m.*.waiting = 0;
        ffi.g_dbus_method_invocation_return_value(call, null);
        return;
    }
    if (ffi.strcmp(method, "CreateMonitor") == 0) {
        var path: [*c]const u8 = undefined;
        ffi.g_variant_get_child(params, 1, "&o", &path);
        if ((((ffi.strlen(path) > @as(usize, 1024)) or !((ffi.g_str_has_prefix(path, "/org/freedesktop/portal/desktop/session/")) != 0)) or (ffi.g_hash_table_contains(s.*.monitors, @ptrCast(@alignCast(path))) != 0)) or (ffi.g_hash_table_size(s.*.monitors) >= @as(ffi.guint, 128))) {
            ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(u)", @as(c_int, 2)));
            return;
        }
        const m: [*c]Monitor = ffi.cast([*c]Monitor, ffi.g_malloc0_n(1, @sizeOf(Monitor)));
        m.*.service = s;
        m.*.path = ffi.g_strdup(path);
        m.*.sender = ffi.g_strdup(sender);
        const node: [*c]ffi.GDBusNodeInfo = ffi.g_dbus_node_info_new_for_xml(@ptrCast(@alignCast(&xml_Session)), null);
        defer if (node != null) ffi.g_dbus_node_info_unref(@ptrCast(node));
        m.*.registration = ffi.g_dbus_connection_register_object(p.*.bus, path, node.*.f_interfaces.?[0], &monitor_vtable, @ptrCast(@alignCast(m)), null, null);
        if (m.*.registration == 0) {
            ffi.g_free(@ptrCast(@alignCast(m.*.path)));
            ffi.g_free(@ptrCast(@alignCast(m.*.sender)));
            ffi.g_free(@ptrCast(@alignCast(m)));
            ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(u)", @as(c_int, 2)));
            return;
        }
        _ = ffi.g_hash_table_insert(s.*.monitors, @ptrCast(@alignCast(m.*.path)), @ptrCast(@alignCast(m)));
        ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(u)", @as(c_uint, 0)));
        emit_state(m);
        return;
    }
    var path: [*c]const u8 = undefined;
    var app: [*c]const u8 = undefined;
    var flags: ffi.guint = undefined;
    ffi.g_variant_get_child(params, 0, "&o", &path);
    ffi.g_variant_get_child(params, 1, "&s", &app);
    ffi.g_variant_get_child(params, 3, "u", &flags);
    const options: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 4);
    defer if (options != null) ffi.g_variant_unref(@ptrCast(options));
    const reason: [*c]const u8 = portal_string(options, "reason", "Application is busy");
    if ((((((((@as(ffi.guint, @bitCast(@as(c_int, @intFromBool(flags == 0)))) != 0) or ((flags & ~@as(c_uint, 15)) != 0)) or (ffi.strlen(reason) > @as(usize, 4096))) or (ffi.strlen(app) > @as(usize, 255))) or (ffi.strlen(path) > @as(usize, 1024))) or !((ffi.g_str_has_prefix(path, "/org/freedesktop/portal/desktop/request/")) != 0)) or (ffi.g_hash_table_contains(s.*.holds, @ptrCast(@alignCast(path))) != 0)) or (ffi.g_hash_table_size(s.*.holds) >= @as(ffi.guint, 256))) {
        portal_error(call, "InvalidArgument", "Invalid inhibition");
        return;
    }
    const h: [*c]Hold = ffi.cast([*c]Hold, ffi.g_malloc0_n(1, @sizeOf(Hold)));
    h.*.refs = 1;
    h.*.service = s;
    h.*.path = ffi.g_strdup(path);
    h.*.sender = ffi.g_strdup(sender);
    h.*.app = ffi.g_strdup(app);
    h.*.reason = ffi.g_strdup(reason);
    h.*.shell = ffi.g_strdup(s.*.shell);
    h.*.flags = flags;
    h.*.fd = -1;
    h.*.call = @as(@TypeOf(call), @ptrCast(@alignCast(ffi.g_object_ref(@ptrCast(@alignCast(call))))));
    h.*.cancel = ffi.g_cancellable_new();
    const node: [*c]ffi.GDBusNodeInfo = ffi.g_dbus_node_info_new_for_xml(@ptrCast(@alignCast(&xml_Request)), null);
    defer if (node != null) ffi.g_dbus_node_info_unref(@ptrCast(node));
    h.*.registration = ffi.g_dbus_connection_register_object(p.*.bus, path, node.*.f_interfaces.?[0], &hold_vtable, @ptrCast(@alignCast(h)), null, null);
    if (h.*.registration == 0) {
        portal_error(call, "Failed", "Could not export hold");
        hold_unref(h);
        return;
    }
    _ = ffi.g_hash_table_insert(s.*.holds, @ptrCast(@alignCast(h.*.path)), @ptrCast(@alignCast(h)));
    ffi.g_dbus_connection_call(p.*.bus, s.*.shell, "/org/seafoam/Pearl/Session", "org.seafoam.Pearl.Session.Inhibit", "Acquire", ffi.g_variant_new("(sus)", app, flags, reason), ffi.g_variant_type_checked_("(u)"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, null, shell_acquired, @ptrCast(@alignCast(hold_ref(h))));
}
