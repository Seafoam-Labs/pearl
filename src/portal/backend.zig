const chooser = @import("file_chooser");
const identity = @import("identity.zig");
const ffi = @import("ffi.zig");
const Portal = @import("types.zig").Portal;
const Request = @import("types.zig").Request;
const pearl_print_worker = @import("print_worker.zig").pearl_print_worker;
const portal_dialogs = @import("dialogs.zig").portal_dialogs;
const portal_email = @import("email.zig").portal_email;
const portal_files = @import("file_chooser.zig").portal_files;
const portal_inhibit = @import("inhibit.zig").portal_inhibit;
const portal_inhibit_clear = @import("inhibit.zig").portal_inhibit_clear;
const portal_inhibit_init = @import("inhibit.zig").portal_inhibit_init;
const portal_inhibit_stop = @import("inhibit.zig").portal_inhibit_stop;
const portal_notification = @import("notification.zig").portal_notification;
const portal_notifications_init = @import("notification.zig").portal_notifications_init;
const portal_notifications_stop = @import("notification.zig").portal_notifications_stop;
const portal_print = @import("print.zig").portal_print;
const portal_print_clear = @import("print.zig").portal_print_clear;
const portal_print_init = @import("print.zig").portal_print_init;
const portal_print_stop = @import("print.zig").portal_print_stop;
const portal_settings_call = @import("settings.zig").portal_settings_call;
const portal_settings_init = @import("settings.zig").portal_settings_init;
const portal_settings_property = @import("settings.zig").portal_settings_property;
const portal_settings_stop = @import("settings.zig").portal_settings_stop;
const portal_update_choices = @import("dialogs.zig").portal_update_choices;
const xml_Access = @import("contracts.zig").xml_Access;
const xml_Account = @import("contracts.zig").xml_Account;
const xml_AppChooser = @import("contracts.zig").xml_AppChooser;
const xml_DynamicLauncher = @import("contracts.zig").xml_DynamicLauncher;
const xml_Email = @import("contracts.zig").xml_Email;
const xml_FileChooser = @import("contracts.zig").xml_FileChooser;
const xml_Inhibit = @import("contracts.zig").xml_Inhibit;
const xml_Lockdown = @import("contracts.zig").xml_Lockdown;
const xml_Notification = @import("contracts.zig").xml_Notification;
const xml_Print = @import("contracts.zig").xml_Print;
const xml_Request = @import("contracts.zig").xml_Request;
const xml_Settings = @import("contracts.zig").xml_Settings;

pub var request_node: [*c]ffi.GDBusNodeInfo = null;

const pearl_portal_appearance_start = @import("appearance.zig").start;

const pearl_portal_appearance_stop = @import("appearance.zig").stop;

const implemented = [_][*:0]const u8{
    "FileChooser",
    "AppChooser",
    "Access",
    "Account",
    "DynamicLauncher",
    "Settings",
    "Lockdown",
    "Email",
    "Notification",
    "Print",
    "Inhibit",
};

pub fn close_request(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    if (ffi.strcmp(sender, r.*.sender) != 0) {
        portal_error(call, "NotAllowed", "Request belongs to another sender");
        return;
    }
    ffi.g_dbus_method_invocation_return_value(call, null);
    portal_complete(r, 1, null);
}

pub const request_vtable: ffi.GDBusInterfaceVTable = ffi.GDBusInterfaceVTable{
    .method_call = close_request,
    .get_property = null,
    .set_property = null,
    .padding = @import("std").mem.zeroes([8]ffi.gpointer),
};

pub fn close_window(_: [*c]ffi.GtkWindow, data: ffi.gpointer) callconv(.c) ffi.gboolean {
    portal_complete(@ptrCast(@alignCast(data)), 1, null);
    return 1;
}

pub fn escape(_: ?*ffi.GtkEventControllerKey, key: ffi.guint, _: ffi.guint, _: ffi.GdkModifierType, data: ffi.gpointer) callconv(.c) ffi.gboolean {
    if (key != @as(ffi.guint, 65307)) return 0;
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const focus: [*c]ffi.GtkWidget = ffi.gtk_window_get_focus(ffi.cast([*c]ffi.GtkWindow, r.*.dialog));
    const popup: [*c]ffi.GtkWidget = @ptrCast(@alignCast(if (focus != null) ffi.cast(?*anyopaque, ffi.gtk_widget_get_ancestor(focus, ffi.gtk_popover_get_type())) else null));
    if (popup != null) {
        ffi.gtk_popover_popdown(ffi.cast([*c]ffi.GtkPopover, popup));
        return 1;
    }
    portal_complete(@ptrCast(@alignCast(data)), 1, null);
    return 1;
}

pub fn method(_: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, iface: [*c]const u8, member: [*c]const u8, params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    if (!(portal_authorized(p, sender) != 0)) {
        portal_error(call, "NotAllowed", "Only the current desktop portal frontend may call this backend");
        return;
    }
    if (ffi.g_variant_get_size(params) > @as(ffi.gsize, @bitCast(@as(c_long, @as(c_int, 1024) * @as(c_int, 1024))))) {
        portal_error(call, "InvalidArgument", "Request exceeds resource limits");
        return;
    }
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Settings") == 0) {
        portal_settings_call(p, member, params, call);
        return;
    }
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Inhibit") == 0) {
        portal_inhibit(p, member, params, call);
        return;
    }
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Notification") == 0) {
        portal_notification(p, member, params, call);
        return;
    }
    if (ffi.strcmp(member, "RequestInstallToken") == 0) {
        ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(u)", @as(c_int, 2)));
        return;
    }
    if (ffi.strcmp(member, "UpdateChoices") == 0) {
        var handle: [*c]const u8 = undefined;
        ffi.g_variant_get_child(params, 0, "&o", &handle);
        const r: [*c]Request = @ptrCast(@alignCast(ffi.g_hash_table_lookup(p.*.requests, @ptrCast(@alignCast(handle)))));
        if ((r == null or (ffi.strcmp(r.*.sender, sender) != 0)) or (ffi.strcmp(r.*.method, "ChooseApplication") != 0)) {
            portal_error(call, "InvalidArgument", "Unknown application-choice request");
            return;
        }
        const choices: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 1);
        defer if (choices != null) ffi.g_variant_unref(@ptrCast(choices));
        portal_update_choices(r, choices);
        ffi.g_dbus_method_invocation_return_value(call, null);
        return;
    }
    const n: ffi.guint = @truncate(ffi.g_variant_n_children(params));
    const r: [*c]Request = portal_request(p, call, params, member, n -% @as(ffi.guint, 1));
    if (r == null) return;
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.FileChooser") == 0) {
        portal_files(r, params);
    } else if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Email") == 0) {
        portal_email(r);
    } else if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Print") == 0) {
        portal_print(r, params);
    } else {
        portal_dialogs(r, params);
    }
}

pub fn property(_: ?*ffi.GDBusConnection, _: [*c]const u8, _: [*c]const u8, iface: [*c]const u8, name: [*c]const u8, @"error": [*c][*c]ffi.GError, data: ffi.gpointer) callconv(.c) ?*ffi.GVariant {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Lockdown") == 0) return portal_settings_property(p, name, @"error");
    if (ffi.strcmp(name, "SupportedLauncherTypes") == 0) return ffi.g_variant_new_uint32(3);
    if (ffi.strcmp(name, "SupportedOptions") == 0) return portal_empty();
    if (ffi.strcmp(iface, "org.freedesktop.impl.portal.Notification") == 0 and ffi.strcmp(name, "version") == 0) return ffi.g_variant_new_uint32(2);
    if (ffi.strcmp(name, "version") == 0) return ffi.g_variant_new_uint32(1);
    ffi.g_set_error_literal(@"error", ffi.g_dbus_error_quark(), ffi.G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property");
    return null;
}

pub fn set_property(_: ?*ffi.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*ffi.GVariant, @"error": [*c][*c]ffi.GError, _: ffi.gpointer) callconv(.c) ffi.gboolean {
    ffi.g_set_error_literal(@"error", ffi.g_dbus_error_quark(), ffi.G_DBUS_ERROR_ACCESS_DENIED, "Desktop restrictions are administrator-owned");
    return 0;
}

pub const vtable: ffi.GDBusInterfaceVTable = ffi.GDBusInterfaceVTable{
    .method_call = method,
    .get_property = property,
    .set_property = set_property,
    .padding = @import("std").mem.zeroes([8]ffi.gpointer),
};

pub fn cancel_all(p: [*c]Portal) callconv(.c) void {
    portal_print_clear(p);
    portal_inhibit_clear(p);
    while (ffi.g_hash_table_size(p.*.requests) != 0) {
        var iter: ffi.GHashTableIter = undefined;
        var r: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&iter, p.*.requests);
        _ = ffi.g_hash_table_iter_next(&iter, null, &r);
        portal_complete(@ptrCast(@alignCast(r)), 1, null);
    }
}

pub fn appeared(_: ?*ffi.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    if (ffi.g_strcmp0(p.*.owner, owner) != 0) {
        cancel_all(p);
        ffi.g_free(@ptrCast(@alignCast(p.*.owner)));
        p.*.owner = ffi.g_strdup(owner);
    }
}

pub fn vanished(_: ?*ffi.GDBusConnection, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    ffi.clear(&p.*.owner, ffi.g_free);
    cancel_all(p);
}

pub fn stop(data: ffi.gpointer) callconv(.c) ffi.gboolean {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    p.*.stopping = 1;
    cancel_all(p);
    ffi.g_main_loop_quit(p.*.loop);
    return 0;
}

pub fn disconnected(_: ?*ffi.GDBusConnection, _: ffi.gboolean, _: [*c]ffi.GError, data: ffi.gpointer) callconv(.c) void {
    _ = stop(data);
}

pub fn run(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if ((argc == @as(c_int, 2)) and ffi.strcmp(argv[1], "--identity") == 0) {
        ffi.g_print("%s\n", @constCast(identity.bus_name));
        return 0;
    }
    if ((argc >= @as(c_int, 3)) and ffi.strcmp(argv[1], "--print-worker") == 0) return pearl_print_worker(argc, argv);
    if ((argc == @as(c_int, 2)) and ffi.strcmp(argv[1], "--interfaces") == 0) {
        {
            var i: ffi.guint = 0;
            while (i < implemented.len) : (i +%= 1) {
                ffi.g_print("org.freedesktop.impl.portal.%s\n", implemented[i]);
            }
        }
        return 0;
    }
    if (argc != 1) {
        ffi.g_printerr("Usage: xdg-desktop-portal-pearl [--interfaces]\n");
        return 2;
    }
    // A portal backend must not wait for its own public Settings portal.
    @import("gtk4").disablePortals();
    ffi.gdk_set_allowed_backends("wayland");
    var p: Portal = .{};
    var @"error": [*c]ffi.GError = null;
    defer if (@"error" != null) ffi.g_error_free(@ptrCast(@"error"));
    p.loop = ffi.g_main_loop_new(null, 0);
    p.requests = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, null, @ptrCast(@alignCast(@constCast(&portal_request_unref))));
    p.bus = ffi.g_bus_get_sync(ffi.G_BUS_TYPE_SESSION, null, &@"error");
    if (p.bus == null) {
        ffi.g_printerr("Portal session bus unavailable\n");
        return 1;
    }
    ffi.g_dbus_connection_set_exit_on_close(p.bus, 0);
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(p.bus)), "closed", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&disconnected)))), @ptrCast(@alignCast(&p)), null, 0);
    request_node = ffi.g_dbus_node_info_new_for_xml(@ptrCast(@alignCast(&xml_Request)), null);
    const xmls: [11][*c]const u8 = [11][*c]const u8{
        @ptrCast(@alignCast(&xml_FileChooser)),
        @ptrCast(@alignCast(&xml_AppChooser)),
        @ptrCast(@alignCast(&xml_Access)),
        @ptrCast(@alignCast(&xml_Account)),
        @ptrCast(@alignCast(&xml_DynamicLauncher)),
        @ptrCast(@alignCast(&xml_Settings)),
        @ptrCast(@alignCast(&xml_Lockdown)),
        @ptrCast(@alignCast(&xml_Email)),
        @ptrCast(@alignCast(&xml_Notification)),
        @ptrCast(@alignCast(&xml_Print)),
        @ptrCast(@alignCast(&xml_Inhibit)),
    };
    var ids = @as([xmls.len]ffi.guint, @splat(0));
    portal_print_init(&p);
    portal_inhibit_init(&p);
    portal_settings_init(&p);
    portal_notifications_init(&p);
    pearl_portal_appearance_start();
    {
        var i: ffi.guint = 0;
        while (@as(c_ulong, i) < xmls.len) : (i +%= 1) {
            const node: [*c]ffi.GDBusNodeInfo = ffi.g_dbus_node_info_new_for_xml(xmls[i], &@"error");
            defer if (node != null) ffi.g_dbus_node_info_unref(@ptrCast(node));
            if (node == null) {
                ffi.g_printerr("Invalid pinned portal contract\n");
                return 1;
            }
            ids[i] = ffi.g_dbus_connection_register_object(p.bus, "/org/freedesktop/portal/desktop", node.*.f_interfaces.?[0], &vtable, @ptrCast(@alignCast(&p)), null, &@"error");
            if (!(ids[i] != 0)) {
                ffi.g_printerr("Portal interface registration failed\n");
                return 1;
            }
        }
    }
    p.owner_watch = ffi.g_bus_watch_name_on_connection(p.bus, "org.freedesktop.portal.Desktop", ffi.G_BUS_NAME_WATCHER_FLAGS_NONE, appeared, vanished, @ptrCast(@alignCast(&p)), null);
    const claim: ?*ffi.GVariant = ffi.g_dbus_connection_call_sync(p.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", ffi.g_variant_new("(su)", @constCast(identity.bus_name), @as(c_uint, 4)), ffi.g_variant_type_checked_("(u)"), ffi.G_DBUS_CALL_FLAGS_NONE, 5000, null, &@"error");
    defer if (claim != null) ffi.g_variant_unref(@ptrCast(claim));
    var status: ffi.guint = 0;
    if (claim != null) {
        ffi.g_variant_get(claim, "(u)", &status);
    }
    if (status != @as(ffi.guint, 1)) {
        ffi.g_printerr("Pearl portal name is already owned or unavailable\n");
        return 1;
    }
    const term: ffi.guint = ffi.g_unix_signal_add(15, stop, @ptrCast(@alignCast(&p)));
    const interrupt: ffi.guint = ffi.g_unix_signal_add(2, stop, @ptrCast(@alignCast(&p)));
    ffi.g_print("Pearl portal ready\n");
    ffi.g_main_loop_run(p.loop);
    if (ffi.g_main_context_find_source_by_id(null, term) != null) {
        _ = ffi.g_source_remove(term);
    }
    if (ffi.g_main_context_find_source_by_id(null, interrupt) != null) {
        _ = ffi.g_source_remove(interrupt);
    }
    ffi.g_bus_unwatch_name(p.owner_watch);
    pearl_portal_appearance_stop();
    portal_settings_stop(&p);
    portal_print_stop(&p);
    portal_inhibit_stop(&p);
    portal_notifications_stop(&p);
    {
        var i: ffi.guint = 0;
        while (@as(c_ulong, i) < ids.len) : (i +%= 1) {
            _ = ffi.g_dbus_connection_unregister_object(p.bus, ids[i]);
        }
    }
    ffi.g_dbus_node_info_unref(request_node);
    ffi.g_hash_table_unref(p.requests);
    ffi.g_free(@ptrCast(@alignCast(p.owner)));
    ffi.g_object_unref(@ptrCast(@alignCast(p.bus)));
    ffi.g_main_loop_unref(p.loop);
    return 0;
}

pub fn portal_empty() callconv(.c) ?*ffi.GVariant {
    return ffi.g_variant_new_array(ffi.g_variant_type_checked_("{sv}"), null, 0);
}

pub fn portal_error(call: ?*ffi.GDBusMethodInvocation, code: [*c]const u8, message: [*c]const u8) callconv(.c) void {
    const name: [*c]u8 = ffi.g_strconcat("org.freedesktop.portal.Error.", code, @as(?*anyopaque, null));
    defer if (name != null) ffi.g_free(@ptrCast(name));
    ffi.g_dbus_method_invocation_return_dbus_error(call, name, message);
}

pub fn portal_option(options: ?*ffi.GVariant, key: [*c]const u8, @"type": [*c]const u8) callconv(.c) ?*ffi.GVariant {
    return ffi.g_variant_lookup_value(options, key, ffi.g_variant_type_checked_(@"type"));
}

pub fn portal_string(options: ?*ffi.GVariant, key: [*c]const u8, fallback: [*c]const u8) callconv(.c) [*c]const u8 {
    var value: [*c]const u8 = undefined;
    return if (ffi.g_variant_lookup(options, key, "&s", &value) != 0) value else fallback;
}

pub fn portal_boolean(options: ?*ffi.GVariant, key: [*c]const u8, fallback: ffi.gboolean) callconv(.c) ffi.gboolean {
    var v: ffi.gboolean = undefined;
    return if (ffi.g_variant_lookup(options, key, "b", &v) != 0) v else fallback;
}

pub fn portal_authorized(p: [*c]Portal, sender: [*c]const u8) callconv(.c) ffi.gboolean {
    return @intFromBool(((sender != null) and (p.*.owner != null)) and ffi.strcmp(sender, p.*.owner) == 0);
}

pub fn portal_app_name(id: [*c]const u8) callconv(.c) [*c]u8 {
    if (id == null or !(@as(c_int, id.*) != 0)) return ffi.g_strdup("Application");
    if ((ffi.cast([*c]const u8, ffi.strchr(id, '/')) != null) or (ffi.strlen(id) > @as(usize, 255))) return ffi.g_strdup("Application");
    const desktop: [*c]u8 = if ((ffi.g_str_has_suffix(id, ".desktop")) != 0) ffi.g_strdup(id) else ffi.g_strconcat(id, @constCast(".desktop"), @as(?*anyopaque, null));
    defer if (desktop != null) ffi.g_free(@ptrCast(desktop));
    const app: ?*ffi.GDesktopAppInfo = ffi.g_desktop_app_info_new(desktop);
    defer if (app != null) ffi.g_object_unref(@ptrCast(app));
    return ffi.g_strdup(if (app != null) ffi.g_app_info_get_display_name(ffi.cast(?*ffi.GAppInfo, app)) else ffi.cast([*c]const u8, "Application"));
}

pub fn portal_label(text: [*c]const u8) callconv(.c) [*c]ffi.GtkWidget {
    const label: [*c]ffi.GtkWidget = ffi.gtk_label_new(text);
    ffi.gtk_label_set_wrap(ffi.cast(?*ffi.GtkLabel, label), 1);
    ffi.gtk_label_set_xalign(ffi.cast(?*ffi.GtkLabel, label), @floatFromInt(0));
    ffi.gtk_label_set_max_width_chars(ffi.cast(?*ffi.GtkLabel, label), 65);
    return label;
}

pub fn portal_request_ref(r: [*c]Request) callconv(.c) [*c]Request {
    r.*.refs += 1;
    return r;
}

pub fn portal_request_unref(r: [*c]Request) callconv(.c) void {
    if ((blk: {
        const ref = &r.*.refs;
        ref.* -= 1;
        break :blk ref.*;
    }) != 0) return;
    if (r.*.destroy_data != null) {
        r.*.destroy_data.?(r.*.data);
    }
    ffi.clear(&r.*.invocation, ffi.g_object_unref);
    ffi.clear(&r.*.cancel, ffi.g_object_unref);
    ffi.clear(&r.*.options, ffi.g_variant_unref);
    ffi.g_free(@ptrCast(@alignCast(r.*.handle)));
    ffi.g_free(@ptrCast(@alignCast(r.*.sender)));
    ffi.g_free(@ptrCast(@alignCast(r.*.app_id)));
    ffi.g_free(@ptrCast(@alignCast(r.*.parent)));
    ffi.g_free(@ptrCast(@alignCast(r.*.method)));
    ffi.g_free(@ptrCast(@alignCast(r)));
}

pub fn portal_complete(r: [*c]Request, response: ffi.guint, results: ?*ffi.GVariant) callconv(.c) void {
    if (r.*.finished != 0) {
        if (results != null) {
            ffi.g_variant_unref(ffi.g_variant_ref_sink(results));
        }
        return;
    }
    r.*.finished = 1;
    ffi.g_cancellable_cancel(r.*.cancel);
    if (r.*.dialog != null) {
        _ = ffi.g_signal_handlers_disconnect_matched(@ptrCast(@alignCast(r.*.dialog)), ffi.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(@alignCast(r)));
        ffi.gtk_window_destroy(ffi.cast([*c]ffi.GtkWindow, r.*.dialog));
        ffi.clear(&r.*.dialog, ffi.g_object_unref);
    }
    if (r.*.registration != 0) {
        _ = ffi.g_dbus_connection_unregister_object(r.*.portal.*.bus, r.*.registration);
        r.*.registration = 0;
    }
    if (r.*.invocation != null) {
        ffi.g_dbus_method_invocation_return_value(r.*.invocation, ffi.g_variant_new("(u@a{sv})", response, if (results != null) results else portal_empty()));
        ffi.clear(&r.*.invocation, ffi.g_object_unref);
    }
    _ = ffi.g_hash_table_remove(r.*.portal.*.requests, @ptrCast(@alignCast(r.*.handle)));
}

pub fn portal_request(p: [*c]Portal, call: ?*ffi.GDBusMethodInvocation, params: ?*ffi.GVariant, method_1: [*c]const u8, options_index: ffi.guint) callconv(.c) [*c]Request {
    var handle: [*c]const u8 = undefined;
    var app: [*c]const u8 = undefined;
    var parent: [*c]const u8 = undefined;
    ffi.g_variant_get_child(params, 0, "&o", &handle);
    ffi.g_variant_get_child(params, 1, "&s", &app);
    ffi.g_variant_get_child(params, 2, "&s", &parent);
    if (((((ffi.strlen(handle) > @as(usize, 1024)) or (ffi.strlen(app) > @as(usize, 255))) or (ffi.strlen(parent) > @as(usize, 4096))) or !((ffi.g_str_has_prefix(handle, "/org/freedesktop/portal/desktop/request/")) != 0)) or (ffi.g_hash_table_contains(p.*.requests, @ptrCast(@alignCast(handle))) != 0)) {
        portal_error(call, "InvalidArgument", "Invalid or duplicate request handle");
        return null;
    }
    if (ffi.g_hash_table_size(p.*.requests) >= @as(ffi.guint, 8)) {
        portal_error(call, "Failed", "Too many active dialogs");
        return null;
    }
    var iter: ffi.GHashTableIter = undefined;
    var value: ffi.gpointer = undefined;
    ffi.g_hash_table_iter_init(&iter, p.*.requests);
    while (ffi.g_hash_table_iter_next(&iter, null, &value) != 0) {
        const old: [*c]Request = @ptrCast(@alignCast(value));
        if (((@as(c_int, parent.*) != 0) and ffi.strcmp(old.*.app_id, app) == 0) and ffi.strcmp(old.*.parent, parent) == 0) {
            portal_error(call, "Failed", "This application already has an active dialog for that window");
            return null;
        }
    }
    if (ffi.gtk_init_check() == 0) {
        portal_error(call, "Failed", "No graphical display is available");
        return null;
    }
    @import("gtk4").Widget.setDefaultDirection(if (@import("i18n").rtl()) .rtl else .ltr);
    const r: [*c]Request = ffi.cast([*c]Request, ffi.g_malloc0_n(1, @sizeOf(Request)));
    r.*.refs = 1;
    r.*.portal = p;
    r.*.handle = ffi.g_strdup(handle);
    r.*.sender = ffi.g_strdup(ffi.g_dbus_method_invocation_get_sender(call));
    r.*.app_id = ffi.g_strdup(app);
    r.*.parent = ffi.g_strdup(parent);
    r.*.method = ffi.g_strdup(method_1);
    r.*.invocation = @as(@TypeOf(call), @ptrCast(@alignCast(ffi.g_object_ref(@ptrCast(@alignCast(call))))));
    r.*.cancel = ffi.g_cancellable_new();
    r.*.options = ffi.g_variant_get_child_value(params, options_index);
    var @"error": [*c]ffi.GError = null;
    defer if (@"error" != null) ffi.g_error_free(@ptrCast(@"error"));
    r.*.registration = ffi.g_dbus_connection_register_object(p.*.bus, handle, request_node.*.f_interfaces.?[0], &request_vtable, @ptrCast(@alignCast(r)), null, &@"error");
    if (r.*.registration == 0) {
        portal_error(call, "Failed", "Could not register request");
        portal_request_unref(r);
        return null;
    }
    _ = ffi.g_hash_table_insert(p.*.requests, @ptrCast(@alignCast(r.*.handle)), @ptrCast(@alignCast(r)));
    return r;
}

pub fn portal_present(r: [*c]Request) callconv(.c) void {
    ffi.gtk_window_set_modal(ffi.cast([*c]ffi.GtkWindow, r.*.dialog), portal_boolean(r.*.options, "modal", 1));
    ffi.gtk_widget_realize(ffi.cast([*c]ffi.GtkWidget, r.*.dialog));
    const surface: ?*ffi.GdkSurface = ffi.gtk_native_get_surface(ffi.GTK_NATIVE(@ptrCast(@alignCast(r.*.dialog))));
    if (((ffi.g_str_has_prefix(r.*.parent, "wayland:")) != 0) and ((blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(surface));
        const _t: ffi.GType = ffi.gdk_wayland_toplevel_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    }) != 0)) {
        _ = ffi.gdk_wayland_toplevel_set_transient_for_exported(ffi.GDK_TOPLEVEL(@ptrCast(@alignCast(surface))), r.*.parent + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, 8))))));
    }
    const token: [*c]const u8 = portal_string(r.*.options, "activation_token", "");
    if ((@as(c_int, token.*) != 0) and (ffi.GDK_IS_TOPLEVEL(@ptrCast(@alignCast(surface))) != 0)) {
        ffi.gdk_toplevel_set_startup_id(ffi.GDK_TOPLEVEL(@ptrCast(@alignCast(surface))), token);
    }
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "close-request", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&close_window)))), @ptrCast(@alignCast(r)), null, 0);
    const keys: ?*ffi.GtkEventController = ffi.gtk_event_controller_key_new();
    ffi.gtk_event_controller_set_propagation_phase(keys, ffi.GTK_PHASE_CAPTURE);
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(keys)), "key-pressed", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&escape)))), @ptrCast(@alignCast(r)), null, 0);
    ffi.gtk_widget_add_controller(ffi.cast([*c]ffi.GtkWidget, r.*.dialog), keys);
    ffi.gtk_window_present(ffi.cast([*c]ffi.GtkWindow, r.*.dialog));
}

pub fn portal_dialog(r: [*c]Request, title: [*c]const u8, negative: [*c]const u8, positive: [*c]const u8) callconv(.c) [*c]ffi.GtkDialog {
    r.*.dialog = ffi.cast([*c]ffi.GtkDialog, ffi.gtk_dialog_new());
    _ = ffi.g_object_ref_sink(@ptrCast(@alignCast(r.*.dialog)));
    ffi.gtk_window_set_title(ffi.cast([*c]ffi.GtkWindow, r.*.dialog), title);
    ffi.gtk_window_set_default_size(ffi.cast([*c]ffi.GtkWindow, r.*.dialog), 560, -1);
    ffi.gtk_widget_add_css_class(ffi.cast([*c]ffi.GtkWidget, r.*.dialog), "pearl-portal");
    chooser.pearl_file_style(ffi.cast([*c]ffi.GtkWindow, r.*.dialog));
    const body: [*c]ffi.GtkWidget = ffi.gtk_dialog_get_content_area(r.*.dialog);
    ffi.gtk_box_set_spacing(ffi.cast([*c]ffi.GtkBox, body), 16);
    ffi.gtk_widget_set_margin_start(body, 24);
    ffi.gtk_widget_set_margin_end(body, 24);
    ffi.gtk_widget_set_margin_top(body, 24);
    ffi.gtk_widget_set_margin_bottom(body, 24);
    const name: [*c]u8 = portal_app_name(r.*.app_id);
    defer if (name != null) ffi.g_free(@ptrCast(name));
    const caller: [*c]u8 = ffi.g_strdup_printf("Requested by %s", name);
    defer if (caller != null) ffi.g_free(@ptrCast(caller));
    const caller_identity: [*c]ffi.GtkWidget = portal_label(caller);
    ffi.gtk_widget_add_css_class(caller_identity, "dim-label");
    ffi.gtk_box_append(ffi.cast([*c]ffi.GtkBox, body), caller_identity);
    const cancel: [*c]ffi.GtkWidget = ffi.gtk_dialog_add_button(r.*.dialog, negative, ffi.GTK_RESPONSE_CANCEL);
    if (positive != null) {
        const yes: [*c]ffi.GtkWidget = ffi.gtk_dialog_add_button(r.*.dialog, positive, ffi.GTK_RESPONSE_ACCEPT);
        ffi.gtk_widget_add_css_class(yes, "suggested-action");
    }
    ffi.gtk_window_set_focus(ffi.cast([*c]ffi.GtkWindow, r.*.dialog), cancel);
    ffi.gtk_dialog_set_default_response(r.*.dialog, ffi.GTK_RESPONSE_CANCEL);
    return r.*.dialog;
}
