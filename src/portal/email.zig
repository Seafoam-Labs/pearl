const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Request = @import("types.zig").Request;
const portal_complete = @import("backend.zig").portal_complete;
const portal_dialog = @import("backend.zig").portal_dialog;
const portal_label = @import("backend.zig").portal_label;
const portal_option = @import("backend.zig").portal_option;
const portal_present = @import("backend.zig").portal_present;
const portal_request_ref = @import("backend.zig").portal_request_ref;
const portal_request_unref = @import("backend.zig").portal_request_unref;
const portal_restricted = @import("settings.zig").portal_restricted;
const portal_string = @import("backend.zig").portal_string;

pub const Mail = extern struct {
    request: [*c]Request = null,
    app: ?*ffi.GAppInfo = null,
    apps: [*c]ffi.GPtrArray = null,
    select: [*c]ffi.GtkWidget = null,
    process: ?*ffi.GSubprocess = null,
    uri: [*c]u8 = null,
};

pub fn mail_cancelled(_: [*c]ffi.GCancellable, data: ffi.gpointer) callconv(.c) void {
    const m: [*c]Mail = @ptrCast(@alignCast(data));
    if (m.*.process != null) {
        ffi.g_subprocess_force_exit(m.*.process);
    }
}

pub fn mail_free(data: ffi.gpointer) callconv(.c) void {
    const m: [*c]Mail = @ptrCast(@alignCast(data));
    if (m.*.process != null) {
        ffi.g_subprocess_force_exit(m.*.process);
    }
    ffi.clear(&m.*.process, ffi.g_object_unref);
    ffi.clear(&m.*.app, ffi.g_object_unref);
    ffi.clear(&m.*.apps, ffi.g_ptr_array_unref);
    ffi.g_free(@ptrCast(@alignCast(m.*.uri)));
    ffi.g_free(@ptrCast(@alignCast(m)));
}

pub fn field(uri: [*c]ffi.GString, name: [*c]const u8, value: [*c]const u8) callconv(.c) void {
    const escaped: [*c]u8 = ffi.g_uri_escape_string(value, null, 0);
    defer if (escaped != null) ffi.g_free(@ptrCast(escaped));
    ffi.g_string_append_printf(uri, "%s%s=%s", if (ffi.strchr(uri.*.f_str, '?') != null) @constCast("&") else @constCast("?"), name, escaped);
}

pub fn array_fields(uri: [*c]ffi.GString, options: ?*ffi.GVariant, key: [*c]const u8) callconv(.c) ffi.gboolean {
    const values: ?*ffi.GVariant = portal_option(options, key, "as");
    defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
    if (values == null) return 1;
    if (ffi.g_variant_n_children(values) > @as(ffi.gsize, 128)) return 0;
    const combined: [*c]ffi.GString = ffi.g_string_new(null);
    var iter: ffi.GVariantIter = undefined;
    var value: [*c]const u8 = undefined;
    _ = ffi.g_variant_iter_init(&iter, values);
    while (ffi.g_variant_iter_next(&iter, "&s", &value) != 0) {
        if (((ffi.strlen(value) > @as(usize, 4096)) or (ffi.cast([*c]const u8, ffi.strchr(value, '\n')) != null)) or (ffi.cast([*c]const u8, ffi.strchr(value, '\r')) != null)) {
            _ = ffi.g_string_free(combined, 1);
            return 0;
        }
        if (combined.*.f_len != 0) {
            _ = ffi.g_string_append_c(combined, ',');
        }
        _ = ffi.g_string_append_len(combined, value, -1);
    }
    if (combined.*.f_len != 0) {
        field(uri, if (ffi.strcmp(key, "addresses") == 0) ffi.cast([*c]const u8, "to") else key, combined.*.f_str);
    }
    _ = ffi.g_string_free(combined, 1);
    return 1;
}

pub fn launch_done(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const ok: ffi.gboolean = ffi.g_app_info_launch_uris_finish(ffi.cast(?*ffi.GAppInfo, source), result, null);
    if (r.*.finished == 0) {
        portal_complete(r, @bitCast(@as(c_int, if (ok != 0) 0 else @as(c_int, 2))), null);
    }
    portal_request_unref(r);
}

pub fn helper_done(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const ok: ffi.gboolean = ffi.g_subprocess_wait_check_finish(ffi.cast(?*ffi.GSubprocess, source), result, null);
    if (r.*.finished == 0) {
        const m: [*c]Mail = @ptrCast(@alignCast(r.*.data));
        ffi.clear(&m.*.process, ffi.g_object_unref);
        portal_complete(r, @bitCast(@as(c_int, if (ok != 0) 0 else @as(c_int, 2))), null);
    }
    portal_request_unref(r);
}

pub fn compose(r: [*c]Request) callconv(.c) void {
    const m: [*c]Mail = @ptrCast(@alignCast(r.*.data));
    if (portal_restricted(r.*.portal, "disable-application-handlers") != 0) {
        portal_complete(r, 2, null);
        return;
    }
    const attachments: ?*ffi.GVariant = portal_option(r.*.options, "attachments", "as");
    defer if (attachments != null) ffi.g_variant_unref(@ptrCast(attachments));
    const executable: [*c]const u8 = ffi.g_app_info_get_executable(m.*.app);
    const base: [*c]u8 = @ptrCast(@alignCast(if (executable != null) ffi.cast(?*anyopaque, ffi.g_path_get_basename(executable)) else null));
    defer if (base != null) ffi.g_free(@ptrCast(base));
    const thunderbird: ffi.gboolean = @intFromBool((base != null) and (ffi.strcmp(base, "thunderbird") == 0 or ffi.strcmp(base, "icedove") == 0));
    const attachment_uri: ffi.gboolean = @intFromBool((base != null) and ((ffi.strcmp(base, "evolution") == 0 or ffi.strcmp(base, "kmail") == 0) or ffi.strcmp(base, "kmail2") == 0));
    if ((attachments != null) and (ffi.g_variant_n_children(attachments) != 0)) {
        if ((ffi.g_variant_n_children(attachments) > @as(ffi.gsize, 128)) or (thunderbird == 0 and attachment_uri == 0)) {
            portal_complete(r, 2, null);
            return;
        }
        if (thunderbird != 0) {
            const def: ?*ffi.GAppInfo = ffi.g_app_info_get_default_for_uri_scheme("mailto");
            defer if (def != null) ffi.g_object_unref(@ptrCast(def));
            if (def == null or ffi.g_app_info_equal(def, m.*.app) == 0) {
                portal_complete(r, 2, null);
                return;
            }
            const argv: [*c]ffi.GPtrArray = ffi.g_ptr_array_new_with_free_func(ffi.g_free);
            ffi.g_ptr_array_add(argv, @ptrCast(@alignCast(ffi.g_strdup("/usr/bin/xdg-email"))));
            ffi.g_ptr_array_add(argv, @ptrCast(@alignCast(ffi.g_strdup("--utf8"))));
            var iter: ffi.GVariantIter = undefined;
            var uri: [*c]const u8 = undefined;
            _ = ffi.g_variant_iter_init(&iter, attachments);
            while (ffi.g_variant_iter_next(&iter, "&s", &uri) != 0) {
                const file: ?*ffi.GFile = ffi.g_file_new_for_uri(uri);
                defer if (file != null) ffi.g_object_unref(@ptrCast(file));
                const path: [*c]u8 = ffi.g_file_get_path(file);
                if ((((path == null or (ffi.strchr(path, '\n') != null)) or (ffi.strchr(path, '\r') != null)) or (ffi.strchr(path, '\'') != null)) or (ffi.strchr(path, ',') != null)) {
                    ffi.g_free(@ptrCast(@alignCast(path)));
                    ffi.g_ptr_array_unref(argv);
                    portal_complete(r, 2, null);
                    return;
                }
                ffi.g_ptr_array_add(argv, @ptrCast(@alignCast(ffi.g_strdup("--attach"))));
                ffi.g_ptr_array_add(argv, @ptrCast(@alignCast(path)));
            }
            ffi.g_ptr_array_add(argv, @ptrCast(@alignCast(ffi.g_strdup(m.*.uri))));
            ffi.g_ptr_array_add(argv, null);
            const launcher: ?*ffi.GSubprocessLauncher = ffi.g_subprocess_launcher_new(@bitCast(ffi.G_SUBPROCESS_FLAGS_STDOUT_SILENCE | ffi.G_SUBPROCESS_FLAGS_STDERR_SILENCE));
            defer if (launcher != null) ffi.g_object_unref(@ptrCast(launcher));
            ffi.g_subprocess_launcher_unsetenv(launcher, "MAILER");
            ffi.g_subprocess_launcher_setenv(launcher, "XDG_CURRENT_DESKTOP", "Aqueous", 1);
            const token: [*c]const u8 = portal_string(r.*.options, "activation_token", "");
            if (@as(c_int, token.*) != 0) {
                ffi.g_subprocess_launcher_setenv(launcher, "XDG_ACTIVATION_TOKEN", token, 1);
            }
            m.*.process = ffi.g_subprocess_launcher_spawnv(launcher, @ptrCast(@alignCast(argv.*.f_pdata)), null);
            ffi.g_ptr_array_unref(argv);
            if (m.*.process == null) {
                portal_complete(r, 2, null);
                return;
            }
            ffi.g_subprocess_wait_check_async(m.*.process, r.*.cancel, helper_done, @ptrCast(@alignCast(portal_request_ref(r))));
            return;
        }
        const uri: [*c]ffi.GString = ffi.g_string_new(m.*.uri);
        var iter: ffi.GVariantIter = undefined;
        var attachment: [*c]const u8 = undefined;
        _ = ffi.g_variant_iter_init(&iter, attachments);
        while (ffi.g_variant_iter_next(&iter, "&s", &attachment) != 0) {
            const file: ?*ffi.GFile = ffi.g_file_new_for_uri(attachment);
            defer if (file != null) ffi.g_object_unref(@ptrCast(file));
            const path: [*c]u8 = ffi.g_file_get_path(file);
            defer if (path != null) ffi.g_free(@ptrCast(path));
            if (path == null) {
                _ = ffi.g_string_free(uri, 1);
                portal_complete(r, 2, null);
                return;
            }
            field(uri, "attach", path);
        }
        ffi.g_free(@ptrCast(@alignCast(m.*.uri)));
        m.*.uri = ffi.g_string_free(uri, 0);
    }
    const context: [*c]ffi.GAppLaunchContext = ffi.g_app_launch_context_new();
    defer if (context != null) ffi.g_object_unref(@ptrCast(context));
    const token: [*c]const u8 = portal_string(r.*.options, "activation_token", "");
    if (@as(c_int, token.*) != 0) {
        ffi.g_app_launch_context_setenv(context, "XDG_ACTIVATION_TOKEN", token);
    }
    var item: ffi.GList = ffi.GList{
        .f_data = @ptrCast(@alignCast(m.*.uri)),
        .f_next = null,
        .f_prev = null,
    };
    ffi.g_app_info_launch_uris_async(m.*.app, &item, context, r.*.cancel, launch_done, @ptrCast(@alignCast(portal_request_ref(r))));
}

pub fn selected(_: [*c]ffi.GtkDialog, response: c_int, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const m: [*c]Mail = @ptrCast(@alignCast(r.*.data));
    if (response != ffi.GTK_RESPONSE_ACCEPT) {
        portal_complete(r, 1, null);
        return;
    }
    const index_1: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(m.*.select))));
    if (index_1 >= m.*.apps.*.f_len) {
        portal_complete(r, 2, null);
        return;
    }
    _ = ffi.g_set_object(@ptrCast(&m.*.app), ffi.cast([*c]ffi.GObject, ffi.items(m.*.apps)[index_1]));
    ffi.gtk_widget_set_sensitive(ffi.cast([*c]ffi.GtkWidget, r.*.dialog), 0);
    compose(r);
}

pub fn portal_email(r: [*c]Request) callconv(.c) void {
    const m: [*c]Mail = ffi.cast([*c]Mail, ffi.g_malloc0_n(1, @sizeOf(Mail)));
    m.*.request = r;
    r.*.data = @ptrCast(@alignCast(m));
    r.*.destroy_data = mail_free;
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.cancel)), "cancelled", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&mail_cancelled)))), @ptrCast(@alignCast(m)), null, 0);
    const uri: [*c]ffi.GString = ffi.g_string_new("mailto:");
    const address: [*c]const u8 = portal_string(r.*.options, "address", "");
    if ((ffi.cast([*c]const u8, ffi.strchr(address, '\r')) != null) or (ffi.cast([*c]const u8, ffi.strchr(address, '\n')) != null)) {
        _ = ffi.g_string_free(uri, 1);
        portal_complete(r, 2, null);
        return;
    }
    if (@as(c_int, address.*) != 0) {
        field(uri, "to", address);
    }
    if ((!(array_fields(uri, r.*.options, "addresses") != 0) or !(array_fields(uri, r.*.options, "cc") != 0)) or !(array_fields(uri, r.*.options, "bcc") != 0)) {
        _ = ffi.g_string_free(uri, 1);
        portal_complete(r, 2, null);
        return;
    }
    {
        var i: ffi.guint = 0;
        while (i < @as(ffi.guint, 2)) : (i +%= 1) {
            const key: [*c]const u8 = if (i != 0) @constCast("body") else @constCast("subject");
            const value: [*c]const u8 = portal_string(r.*.options, key, "");
            if (@as(c_int, value.*) != 0) {
                field(uri, key, value);
            }
        }
    }
    m.*.uri = ffi.g_string_free(uri, 0);
    m.*.app = ffi.g_app_info_get_default_for_uri_scheme("mailto");
    if (m.*.app != null) {
        compose(r);
        return;
    }
    _ = portal_dialog(r, "Choose an email application", "Cancel", "Open composer");
    const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
    ffi.gtk_box_append(body, portal_label("Review and send your message in the selected application's composer."));
    m.*.apps = ffi.g_ptr_array_new_with_free_func(ffi.g_object_unref);
    const names: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
    const apps: [*c]ffi.GList = ffi.g_app_info_get_all_for_type("x-scheme-handler/mailto");
    {
        var l: [*c]ffi.GList = apps;
        while (l != null) : (l = l.*.f_next) if (ffi.g_app_info_should_show(@ptrCast(@alignCast(l.*.f_data))) != 0) {
            ffi.g_ptr_array_add(m.*.apps, ffi.g_object_ref(l.*.f_data));
            ffi.gtk_string_list_append(names, ffi.g_app_info_get_display_name(@ptrCast(@alignCast(l.*.f_data))));
        };
    }
    ffi.g_list_free_full(apps, ffi.g_object_unref);
    m.*.select = ffi.gtk_drop_down_new(ffi.G_LIST_MODEL(@ptrCast(@alignCast(names))), null);
    ffi.gtk_box_append(body, m.*.select);
    if (m.*.apps.*.f_len == 0) {
        ffi.gtk_box_append(body, portal_label("No email application is installed. Install a mail application and try again."));
        ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 0);
    }
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "response", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&selected)))), @ptrCast(@alignCast(r)), null, 0);
    portal_present(r);
}
