//! Background portal backend. Running-app window state is sourced from the
//! Pearl session (org.seafoam.Pearl.Session.Background); unsolicited background
//! activity is confirmed with a native dialog that defaults to keeping the app
//! running, and autostart files are managed for frontends that still delegate
//! EnableAutostart. Newer frontends write the autostart file themselves and only
//! need GetAppState/NotifyBackground, but the interface must exist for the
//! public org.freedesktop.portal.Background portal to be exported at all.
const std = @import("std");
const ffi = @import("ffi.zig");
const backend = @import("backend.zig");
const Portal = @import("types.zig").Portal;
const Request = @import("types.zig").Request;

const portal_error = backend.portal_error;
const portal_complete = backend.portal_complete;
const portal_dialog = backend.portal_dialog;
const portal_present = backend.portal_present;
const portal_label = backend.portal_label;
const portal_app_name = backend.portal_app_name;
const portal_request_unref = backend.portal_request_unref;

pub const Background = extern struct {
    portal: [*c]Portal = null,
    shell: [*c]u8 = null,
    watch: ffi.guint = 0,
    signal: ffi.guint = 0,
};

fn shell_changed(_: ?*ffi.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*ffi.GVariant, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(data));
    const p = s.*.portal;
    if (p == null or p.*.bus == null) return;
    _ = ffi.g_dbus_connection_emit_signal(p.*.bus, null, "/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Background", "RunningApplicationsChanged", null, null);
}

fn appeared(_: ?*ffi.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(data));
    ffi.g_free(@ptrCast(@alignCast(s.*.shell)));
    s.*.shell = ffi.g_strdup(owner);
}

fn vanished(_: ?*ffi.GDBusConnection, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(data));
    ffi.clear(&s.*.shell, ffi.g_free);
}

pub fn portal_background_init(p: [*c]Portal) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(ffi.g_malloc0_n(1, @sizeOf(Background))));
    p.*.background = @ptrCast(@alignCast(s));
    s.*.portal = p;
    s.*.signal = ffi.g_dbus_connection_signal_subscribe(p.*.bus, null, "org.seafoam.Pearl.Session.Background", "RunningApplicationsChanged", "/org/seafoam/Pearl/Session", null, ffi.G_DBUS_SIGNAL_FLAGS_NONE, shell_changed, @ptrCast(@alignCast(s)), null);
    s.*.watch = ffi.g_bus_watch_name_on_connection(p.*.bus, "org.seafoam.Pearl.Session", ffi.G_BUS_NAME_WATCHER_FLAGS_NONE, appeared, vanished, @ptrCast(@alignCast(s)), null);
}

pub fn portal_background_stop(p: [*c]Portal) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(p.*.background));
    if (s == null) return;
    if (s.*.watch != 0) ffi.g_bus_unwatch_name(s.*.watch);
    if (s.*.signal != 0) ffi.g_dbus_connection_signal_unsubscribe(p.*.bus, s.*.signal);
    ffi.g_free(@ptrCast(@alignCast(s.*.shell)));
    ffi.g_free(@ptrCast(@alignCast(s)));
    p.*.background = null;
}

pub fn portal_background(p: [*c]Portal, member: [*c]const u8, params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    if (ffi.strcmp(member, "GetAppState") == 0) {
        get_app_state(p, call);
    } else if (ffi.strcmp(member, "NotifyBackground") == 0) {
        notify_background(p, params, call);
    } else if (ffi.strcmp(member, "EnableAutostart") == 0) {
        enable_autostart(params, call);
    } else {
        portal_error(call, "InvalidArgument", "Unknown background method");
    }
}

/// Without a live Pearl session there is no window list; report failure so the
/// frontend's background monitor skips supervision rather than guessing.
fn get_app_state(p: [*c]Portal, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    const s: [*c]Background = @ptrCast(@alignCast(p.*.background));
    if (s == null or s.*.shell == null) {
        portal_error(call, "Failed", "Could not get window list");
        return;
    }
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_sync(p.*.bus, s.*.shell, "/org/seafoam/Pearl/Session", "org.seafoam.Pearl.Session.Background", "GetAppState", null, ffi.g_variant_type_checked_("(a{sv})"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 1000, null, null);
    if (reply == null) {
        portal_error(call, "Failed", "Could not get window list");
        return;
    }
    ffi.g_dbus_method_invocation_return_value(call, reply);
}

fn notify_response(_: [*c]ffi.GtkDialog, response: ffi.gint, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    if (r.*.finished != 0) return;
    const result: ffi.guint32 = if (response == ffi.GTK_RESPONSE_ACCEPT) 1 else if (response == ffi.GTK_RESPONSE_CANCEL) 0 else 2;
    var b: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&b, ffi.g_variant_type_checked_("a{sv}"));
    ffi.g_variant_builder_add(&b, "{sv}", @constCast("result"), ffi.g_variant_new_uint32(result));
    portal_complete(r, 0, ffi.g_variant_builder_end(&b));
}

fn notify_background(p: [*c]Portal, params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    var handle: [*c]const u8 = undefined;
    var app: [*c]const u8 = undefined;
    var name: [*c]const u8 = undefined;
    ffi.g_variant_get(params, "(&o&s&s)", &handle, &app, &name);
    if (((((ffi.strlen(handle) > @as(usize, 1024)) or (ffi.strlen(app) > @as(usize, 255))) or (ffi.strlen(name) > @as(usize, 255))) or (ffi.g_str_has_prefix(handle, "/org/freedesktop/portal/desktop/") == 0)) or (ffi.g_hash_table_contains(p.*.requests, @ptrCast(@alignCast(handle))) != 0)) {
        portal_error(call, "InvalidArgument", "Invalid background notification");
        return;
    }
    if (ffi.g_hash_table_size(p.*.requests) >= @as(ffi.guint, 8)) {
        portal_error(call, "Failed", "Too many active dialogs");
        return;
    }
    if (ffi.gtk_init_check() == 0) {
        portal_error(call, "Failed", "No graphical display is available");
        return;
    }
    const r: [*c]Request = @ptrCast(@alignCast(ffi.g_malloc0_n(1, @sizeOf(Request))));
    r.*.refs = 1;
    r.*.portal = p;
    r.*.handle = ffi.g_strdup(handle);
    r.*.sender = ffi.g_strdup(ffi.g_dbus_method_invocation_get_sender(call));
    r.*.app_id = ffi.g_strdup(app);
    r.*.parent = ffi.g_strdup("");
    r.*.method = ffi.g_strdup("NotifyBackground");
    r.*.invocation = @ptrCast(@alignCast(ffi.g_object_ref(@ptrCast(@alignCast(call)))));
    r.*.cancel = ffi.g_cancellable_new();
    r.*.options = ffi.g_variant_ref_sink(backend.portal_empty());
    r.*.registration = ffi.g_dbus_connection_register_object(p.*.bus, handle, backend.request_node.*.f_interfaces.?[0], &backend.request_vtable, @ptrCast(@alignCast(r)), null, null);
    if (r.*.registration == 0) {
        portal_error(call, "Failed", "Could not register request");
        portal_request_unref(r);
        return;
    }
    _ = ffi.g_hash_table_insert(p.*.requests, @ptrCast(@alignCast(r.*.handle)), @ptrCast(@alignCast(r)));
    const title = ffi.g_strdup_printf("%s is running in the background", name);
    defer ffi.g_free(@ptrCast(@alignCast(title)));
    const dialog = portal_dialog(r, title, "Force quit", "Allow");
    const body = portal_label("This might be for a legitimate reason, but the application has not provided one.\n\nNote that forcing an application to quit might cause data loss.");
    ffi.gtk_box_append(@ptrCast(@alignCast(ffi.gtk_dialog_get_content_area(dialog))), body);
    // Dismissing the dialog (close/Escape/Request.Close) keeps the app running;
    // only an explicit "Force quit" forbids it. Make "Allow" the default action.
    const allow = ffi.gtk_dialog_get_widget_for_response(dialog, ffi.GTK_RESPONSE_ACCEPT);
    ffi.gtk_dialog_set_default_response(dialog, ffi.GTK_RESPONSE_ACCEPT);
    ffi.gtk_window_set_focus(@ptrCast(@alignCast(dialog)), allow);
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(dialog)), "response", @ptrCast(@alignCast(&notify_response)), @ptrCast(@alignCast(r)), null, 0);
    portal_present(r);
}

fn valid_app_id(app: [*c]const u8) bool {
    const span = std.mem.span(app);
    if (span.len == 0 or span.len > 255 or span[0] == '.') return false;
    if (std.mem.indexOf(u8, span, "..") != null) return false;
    for (span) |ch| if (ch == '/' or ch == '\\' or ch < 32 or ch == 127) return false;
    return true;
}

/// Deprecated in new frontends (they write the autostart file themselves), but
/// implemented for older frontends that still delegate it.
fn enable_autostart(params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    var app: [*c]const u8 = undefined;
    var enable: ffi.gboolean = undefined;
    var flags: ffi.guint = undefined;
    ffi.g_variant_get_child(params, 0, "&s", &app);
    ffi.g_variant_get_child(params, 1, "b", &enable);
    ffi.g_variant_get_child(params, 3, "u", &flags);
    if (!valid_app_id(app)) {
        portal_error(call, "InvalidArgument", "Invalid application id");
        return;
    }
    const dir = ffi.g_build_filename(ffi.g_get_user_config_dir(), "autostart", @as([*c]const u8, null));
    defer ffi.g_free(@ptrCast(@alignCast(dir)));
    const file = ffi.g_strdup_printf("%s.desktop", app);
    defer ffi.g_free(@ptrCast(@alignCast(file)));
    const path = ffi.g_build_filename(dir, file, @as([*c]const u8, null));
    defer ffi.g_free(@ptrCast(@alignCast(path)));
    if (enable == 0) {
        _ = ffi.g_unlink(path);
        ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(b)", @as(ffi.gboolean, 1)));
        return;
    }
    if (ffi.g_mkdir_with_parents(dir, 0o755) != 0) {
        ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(b)", @as(ffi.gboolean, 0)));
        return;
    }
    const commandline = ffi.g_variant_get_child_value(params, 2);
    defer if (commandline != null) ffi.g_variant_unref(@ptrCast(commandline));
    const exec = ffi.g_string_new("");
    const count = ffi.g_variant_n_children(commandline);
    var i: ffi.gsize = 0;
    while (i < count) : (i += 1) {
        var arg: [*c]const u8 = undefined;
        ffi.g_variant_get_child(commandline, i, "&s", &arg);
        if (i != 0) _ = ffi.g_string_append_c(exec, ' ');
        _ = ffi.g_string_append_len(exec, arg, @intCast(ffi.strlen(arg)));
    }
    const exec_str = ffi.g_string_free(exec, 0);
    defer ffi.g_free(@ptrCast(@alignCast(exec_str)));
    const name = portal_app_name(app);
    defer ffi.g_free(@ptrCast(@alignCast(name)));
    const activatable: [*c]const u8 = if ((flags & @as(ffi.guint, 1)) != 0) "DBusActivatable=true\n" else "";
    const text = ffi.g_strdup_printf("[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nX-Flatpak=%s\n%s", name, exec_str, app, activatable);
    defer ffi.g_free(@ptrCast(@alignCast(text)));
    const ok = ffi.g_file_set_contents_full(path, text, @intCast(ffi.strlen(text)), 0, 0o644, null);
    ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(b)", @as(ffi.gboolean, @intFromBool(ok != 0))));
}
