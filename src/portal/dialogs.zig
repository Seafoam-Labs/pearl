const previews = @import("previews").api;
const chooser = @import("file_chooser");
const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Portal = @import("types.zig").Portal;
const Request = @import("types.zig").Request;
const portal_boolean = @import("backend.zig").portal_boolean;
const portal_complete = @import("backend.zig").portal_complete;
const portal_dialog = @import("backend.zig").portal_dialog;
const portal_label = @import("backend.zig").portal_label;
const portal_option = @import("backend.zig").portal_option;
const portal_present = @import("backend.zig").portal_present;
const portal_request_ref = @import("backend.zig").portal_request_ref;
const portal_request_unref = @import("backend.zig").portal_request_unref;
const portal_restricted = @import("settings.zig").portal_restricted;
const portal_string = @import("backend.zig").portal_string;

pub const DialogChoice = extern struct {
    id: [*c]u8 = null,
    widget: [*c]ffi.GtkWidget = null,
    values: [*c][*c]u8 = null,
};

pub const DialogData = extern struct {
    entry: [*c]ffi.GtkWidget = null,
    apps: [*c]ffi.GtkWidget = null,
    search: [*c]ffi.GtkWidget = null,
    picture: [*c]ffi.GtkWidget = null,
    profile: [*c]ffi.GtkWidget = null,
    ids: [*c]ffi.GPtrArray = null,
    choices: [*c]ffi.GPtrArray = null,
    icon: ?*ffi.GVariant = null,
    name: [*c]u8 = null,
    user: [*c]u8 = null,
    image: [*c]u8 = null,
    pending_image: [*c]u8 = null,
    preview: ?*anyopaque = null,
    temporary_icon: [*c]u8 = null,
    icon_valid: ffi.gboolean = 0,
    icon_generation: ffi.guint = 0,
};

pub const IconQuery = extern struct {
    request: [*c]Request = null,
    generation: ffi.guint = 0,
};

pub fn choice_free(data: ffi.gpointer) callconv(.c) void {
    const c: [*c]DialogChoice = @ptrCast(@alignCast(data));
    ffi.g_free(@ptrCast(@alignCast(c.*.id)));
    ffi.g_strfreev(c.*.values);
    ffi.g_free(@ptrCast(@alignCast(c)));
}

pub fn data_free(data: ffi.gpointer) callconv(.c) void {
    const d: [*c]DialogData = @ptrCast(@alignCast(data));
    ffi.clear(&d.*.ids, ffi.g_ptr_array_unref);
    ffi.clear(&d.*.choices, ffi.g_ptr_array_unref);
    ffi.clear(&d.*.icon, ffi.g_variant_unref);
    previews.pearl_preview_unwatch(@ptrCast(@alignCast(d.*.preview)));
    ffi.g_free(@ptrCast(@alignCast(d.*.name)));
    ffi.g_free(@ptrCast(@alignCast(d.*.user)));
    ffi.g_free(@ptrCast(@alignCast(d.*.image)));
    ffi.g_free(@ptrCast(@alignCast(d.*.pending_image)));
    if (d.*.temporary_icon != null) {
        _ = ffi.g_unlink(d.*.temporary_icon);
        ffi.g_free(@ptrCast(@alignCast(d.*.temporary_icon)));
    }
    ffi.g_free(@ptrCast(@alignCast(d)));
}

pub fn add_choices(r: [*c]Request, raw: ?*ffi.GVariant) callconv(.c) ffi.gboolean {
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
    if (ffi.g_variant_n_children(raw) > @as(ffi.gsize, 32)) return 0;
    var iter: ffi.GVariantIter = undefined;
    _ = ffi.g_variant_iter_init(&iter, raw);
    var id: [*c]const u8 = undefined;
    var title: [*c]const u8 = undefined;
    var selected: [*c]const u8 = undefined;
    var options: ?*ffi.GVariant = undefined;
    while (ffi.g_variant_iter_next(&iter, "(&s&s@a(ss)&s)", &id, &title, &options, &selected) != 0) {
        const owned: ?*ffi.GVariant = options;
        defer if (owned != null) ffi.g_variant_unref(@ptrCast(owned));
        if ((!(@as(c_int, id.*) != 0) or (ffi.strlen(title) > @as(usize, 512))) or (ffi.g_variant_n_children(options) > @as(ffi.gsize, 128))) return 0;
        {
            var i: ffi.guint = 0;
            while (i < d.*.choices.*.f_len) : (i +%= 1) if (ffi.strcmp(ffi.cast([*c]DialogChoice, ffi.items(d.*.choices)[i]).*.id, id) == 0) return 0;
        }
        const c: [*c]DialogChoice = ffi.cast([*c]DialogChoice, ffi.g_malloc0_n(1, @sizeOf(DialogChoice)));
        c.*.id = ffi.g_strdup(id);
        ffi.g_ptr_array_add(d.*.choices, @ptrCast(@alignCast(c)));
        const n: ffi.guint = @truncate(ffi.g_variant_n_children(options));
        if (n == 0) {
            if ((ffi.strcmp(selected, "true") != 0) and (ffi.strcmp(selected, "false") != 0)) return 0;
            c.*.widget = ffi.gtk_check_button_new_with_label(title);
            ffi.gtk_check_button_set_active(ffi.cast([*c]ffi.GtkCheckButton, c.*.widget), @intFromBool(ffi.strcmp(selected, "true") == 0));
        } else {
            const labels: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
            c.*.values = ffi.cast([*c][*c]u8, ffi.g_malloc0_n(n +% @as(ffi.guint, 1), @sizeOf([*c]u8)));
            var index_1: ffi.guint = @as(c_uint, 4294967295);
            {
                var i: ffi.guint = 0;
                while (i < n) : (i +%= 1) {
                    var value: [*c]const u8 = undefined;
                    var caption: [*c]const u8 = undefined;
                    ffi.g_variant_get_child(options, i, "(&s&s)", &value, &caption);
                    c.*.values[i] = ffi.g_strdup(value);
                    ffi.gtk_string_list_append(labels, caption);
                    if (ffi.strcmp(value, selected) == 0) {
                        index_1 = i;
                    }
                }
            }
            if ((index_1 == @as(c_uint, 4294967295)) and (@as(c_int, selected.*) != 0)) {
                ffi.g_object_unref(@ptrCast(@alignCast(labels)));
                return 0;
            }
            c.*.widget = ffi.gtk_drop_down_new(ffi.G_LIST_MODEL(@ptrCast(@alignCast(labels))), null);
            ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(c.*.widget))), if (index_1 == @as(c_uint, 4294967295)) @as(ffi.guint, 0) else index_1);
            ffi.gtk_box_append(body, portal_label(title));
        }
        ffi.gtk_box_append(body, c.*.widget);
    }
    return 1;
}

pub fn get_choices(d: [*c]DialogData) callconv(.c) ?*ffi.GVariant {
    var b: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&b, ffi.g_variant_type_checked_("a(ss)"));
    {
        var i: ffi.guint = 0;
        while (i < d.*.choices.*.f_len) : (i +%= 1) {
            const c: [*c]DialogChoice = @ptrCast(@alignCast(ffi.items(d.*.choices)[i]));
            const value: [*c]const u8 = if (c.*.values != null) c.*.values[ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(c.*.widget))))] else if (ffi.gtk_check_button_get_active(ffi.cast([*c]ffi.GtkCheckButton, c.*.widget)) != 0) @constCast("true") else @constCast("false");
            ffi.g_variant_builder_add(&b, "(ss)", c.*.id, value);
        }
    }
    return ffi.g_variant_builder_end(&b);
}

pub fn name_changed(entry: ?*ffi.GtkEditable, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const name: [*c]const u8 = ffi.gtk_editable_get_text(entry);
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, @intFromBool(((@as(c_int, name.*) != 0) and (ffi.strlen(name) <= @as(usize, 255))) and (d.*.icon_valid != 0)));
}

pub fn app_selection(_: [*c]ffi.GObject, _: [*c]ffi.GParamSpec, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, @intFromBool(ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps)))) < d.*.ids.*.f_len));
}

pub fn responded(_: [*c]ffi.GtkDialog, code: c_int, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    if (code != ffi.GTK_RESPONSE_ACCEPT) {
        portal_complete(r, 1, null);
        return;
    }
    var result: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&result, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    if (ffi.strcmp(r.*.method, "ChooseApplication") == 0) {
        if (portal_restricted(r.*.portal, "disable-application-handlers") != 0) {
            ffi.g_variant_builder_clear(&result);
            portal_complete(r, 2, null);
            return;
        }
        const index_1: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps))));
        if (index_1 >= d.*.ids.*.f_len) {
            ffi.g_variant_builder_clear(&result);
            portal_complete(r, 2, null);
            return;
        }
        const id: [*c]const u8 = @ptrCast(@alignCast(ffi.items(d.*.ids)[index_1]));
        const desktop: [*c]u8 = if ((ffi.g_str_has_suffix(id, ".desktop")) != 0) ffi.g_strdup(id) else ffi.g_strconcat(id, @constCast(".desktop"), @as(?*anyopaque, null));
        defer if (desktop != null) ffi.g_free(@ptrCast(desktop));
        const app: ?*ffi.GDesktopAppInfo = ffi.g_desktop_app_info_new(desktop);
        defer if (app != null) ffi.g_object_unref(@ptrCast(app));
        if (app == null) {
            ffi.g_variant_builder_clear(&result);
            portal_complete(r, 2, null);
            return;
        }
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("choice"), ffi.g_variant_new_string(id));
        const token: [*c]const u8 = portal_string(r.*.options, "activation_token", "");
        if (@as(c_int, token.*) != 0) {
            ffi.g_variant_builder_add(&result, "{sv}", @constCast("activation_token"), ffi.g_variant_new_string(token));
        }
    } else if (ffi.strcmp(r.*.method, "AccessDialog") == 0) {
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("choices"), get_choices(d));
    } else if (ffi.strcmp(r.*.method, "GetUserInformation") == 0) {
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("id"), ffi.g_variant_new_string(d.*.user));
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("name"), ffi.g_variant_new_string(d.*.name));
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("image"), ffi.g_variant_new_string(if (d.*.image != null) d.*.image else @constCast("")));
    } else if (ffi.strcmp(r.*.method, "PrepareInstall") == 0) {
        const name: [*c]const u8 = ffi.gtk_editable_get_text(ffi.cast(?*ffi.GtkEditable, d.*.entry));
        if (((d.*.icon_valid == 0 or !(@as(c_int, name.*) != 0)) or (ffi.strlen(name) > @as(usize, 255))) or (portal_restricted(r.*.portal, "disable-application-handlers") != 0)) {
            ffi.g_variant_builder_clear(&result);
            portal_complete(r, 2, null);
            return;
        }
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("name"), ffi.g_variant_new_string(name));
        ffi.g_variant_builder_add(&result, "{sv}", @constCast("icon"), ffi.g_variant_new_variant(d.*.icon));
    }
    portal_complete(r, 0, ffi.g_variant_builder_end(&result));
    return;
}

pub fn account_preview(texture: ?*ffi.GdkTexture, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    if (r.*.finished != 0) return;
    if (texture != null) {
        ffi.gtk_picture_set_paintable(ffi.GTK_PICTURE(@ptrCast(@alignCast(d.*.picture))), ffi.GDK_PAINTABLE(@ptrCast(@alignCast(texture))));
        ffi.g_free(@ptrCast(@alignCast(d.*.image)));
        d.*.image = @as(@TypeOf((&d.*.pending_image).*), @ptrCast(@alignCast(ffi.g_steal_pointer(@ptrCast(@alignCast(&d.*.pending_image))))));
    } else ffi.clear(&d.*.image, ffi.g_free);
}

pub fn avatar_info(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    const info: ?*ffi.GFileInfo = ffi.g_file_query_info_finish(ffi.cast(?*ffi.GFile, source), result, null);
    defer if (info != null) ffi.g_object_unref(@ptrCast(info));
    if (r.*.finished == 0 and (info != null)) {
        ffi.g_file_info_set_attribute_object(info, "standard::file", source);
        d.*.preview = previews.pearl_preview_watch(info.?, 256, @ptrCast(&account_preview), @ptrCast(@alignCast(r)));
        if (d.*.preview == null) ffi.clear(&d.*.image, ffi.g_free);
    }
    portal_request_unref(r);
}

pub fn account_data(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_finish(ffi.cast(?*ffi.GDBusConnection, source), result, null);
    defer if (reply != null) ffi.g_variant_unref(@ptrCast(reply));
    if (r.*.finished == 0) {
        if (reply != null) {
            const values: ?*ffi.GVariant = ffi.g_variant_get_child_value(reply, 0);
            defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
            const name: [*c]u8 = ffi.g_strdup(portal_string(values, "RealName", d.*.name));
            ffi.g_free(@ptrCast(@alignCast(d.*.name)));
            d.*.name = name;
            ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.profile), d.*.name);
            const icon: [*c]const u8 = portal_string(values, "IconFile", "");
            if (ffi.g_path_is_absolute(icon) != 0) {
                const file: ?*ffi.GFile = ffi.g_file_new_for_path(icon);
                defer if (file != null) ffi.g_object_unref(@ptrCast(file));
                d.*.pending_image = ffi.g_file_get_uri(file);
                ffi.g_file_query_info_async(file, "standard::*,access::can-read,time::modified,time::modified-usec", ffi.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, 0, r.*.cancel, avatar_info, @ptrCast(@alignCast(portal_request_ref(r))));
            }
        }
        ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 1);
    }
    portal_request_unref(r);
}

pub fn account_bus(_: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const bus: ?*ffi.GDBusConnection = ffi.g_bus_get_finish(result, null);
    defer if (bus != null) ffi.g_object_unref(@ptrCast(bus));
    if (r.*.finished == 0) {
        if (bus != null) {
            const path: [*c]u8 = ffi.g_strdup_printf("/org/freedesktop/Accounts/User%u", ffi.getuid());
            defer if (path != null) ffi.g_free(@ptrCast(path));
            ffi.g_dbus_connection_call(bus, "org.freedesktop.Accounts", path, "org.freedesktop.DBus.Properties", "GetAll", ffi.g_variant_new("(s)", @constCast("org.freedesktop.Accounts.User")), ffi.g_variant_type_checked_("(a{sv})"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, r.*.cancel, account_data, @ptrCast(@alignCast(portal_request_ref(r))));
        } else {
            ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 1);
        }
    }
    portal_request_unref(r);
}

pub fn launcher_preview(texture: ?*ffi.GdkTexture, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    if (r.*.finished != 0) return;
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    d.*.icon_valid = @intFromBool(ffi.cast(?*anyopaque, texture) != null);
    if (texture != null) {
        ffi.gtk_picture_set_paintable(ffi.GTK_PICTURE(@ptrCast(@alignCast(d.*.picture))), ffi.GDK_PAINTABLE(@ptrCast(@alignCast(texture))));
    }
    name_changed(ffi.cast(?*ffi.GtkEditable, d.*.entry), @ptrCast(@alignCast(r)));
}

pub fn launcher_info(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const query: [*c]IconQuery = @ptrCast(@alignCast(data));
    const r: [*c]Request = query.*.request;
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    const info: ?*ffi.GFileInfo = ffi.g_file_query_info_finish(ffi.cast(?*ffi.GFile, source), result, null);
    defer if (info != null) ffi.g_object_unref(@ptrCast(info));
    if ((r.*.finished == 0 and (info != null)) and (d.*.icon_generation == query.*.generation)) {
        ffi.g_file_info_set_attribute_object(info, "standard::file", source);
        d.*.preview = previews.pearl_preview_watch(info.?, 256, @ptrCast(&launcher_preview), @ptrCast(@alignCast(r)));
    }
    portal_request_unref(r);
    ffi.g_free(@ptrCast(@alignCast(query)));
}

pub fn launcher_icon(r: [*c]Request, icon: ?*ffi.GIcon) callconv(.c) ffi.gboolean {
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    d.*.icon_generation +%= 1;
    previews.pearl_preview_unwatch(@ptrCast(@alignCast(d.*.preview)));
    d.*.preview = null;
    d.*.icon_valid = 0;
    ffi.gtk_picture_set_paintable(ffi.GTK_PICTURE(@ptrCast(@alignCast(d.*.picture))), null);
    ffi.gtk_widget_set_visible(d.*.profile, blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(icon));
        const _t: ffi.GType = ffi.g_themed_icon_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    });
    ffi.gtk_widget_set_visible(d.*.picture, @intFromBool(!((blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(icon));
        const _t: ffi.GType = ffi.g_themed_icon_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    }) != 0)));
    if ((blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(icon));
        const _t: ffi.GType = ffi.g_themed_icon_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    }) != 0) {
        ffi.gtk_image_set_from_gicon(ffi.cast(?*ffi.GtkImage, d.*.profile), icon);
        d.*.icon_valid = 1;
        return 1;
    }
    var file: ?*ffi.GFile = null;
    defer if (file != null) ffi.g_object_unref(@ptrCast(file));
    if ((blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(icon));
        const _t: ffi.GType = ffi.g_file_icon_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    }) != 0) {
        file = @as(@TypeOf(ffi.g_file_icon_get_file(ffi.cast(?*ffi.GFileIcon, icon))), @ptrCast(@alignCast(ffi.g_object_ref(@ptrCast(@alignCast(ffi.g_file_icon_get_file(ffi.cast(?*ffi.GFileIcon, icon))))))));
    } else if ((blk: {
        const _inst: [*c]ffi.GTypeInstance = @ptrCast(@alignCast(icon));
        const _t: ffi.GType = ffi.g_bytes_icon_get_type();
        var _r: ffi.gboolean = undefined;
        if (_inst == null) {
            _r = 0;
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = 1;
        } else {
            _r = ffi.g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    }) != 0) {
        var length: ffi.gsize = undefined;
        const bytes: [*c]const u8 = @ptrCast(@alignCast(ffi.g_bytes_get_data(ffi.g_bytes_icon_get_bytes(ffi.cast(?*ffi.GBytesIcon, icon)), &length)));
        if (length == 0 or (length > @as(ffi.gsize, @bitCast(@as(c_long, (@as(c_int, 4) * @as(c_int, 1024)) * @as(c_int, 1024)))))) return 0;
        if (d.*.temporary_icon != null) {
            _ = ffi.g_unlink(d.*.temporary_icon);
            ffi.clear(&d.*.temporary_icon, ffi.g_free);
        }
        const fd: c_int = ffi.g_file_open_tmp("pearl-launcher-XXXXXX", &d.*.temporary_icon, null);
        if (fd < 0) return 0;
        var offset: ffi.gsize = 0;
        while (offset < length) {
            const n: isize = ffi.write(fd, @ptrCast(@alignCast(bytes + offset)), length -% offset);
            if (n <= @as(isize, 0)) {
                _ = ffi.close(fd);
                return 0;
            }
            offset +%= @bitCast(@as(c_long, n));
        }
        _ = ffi.close(fd);
        file = ffi.g_file_new_for_path(d.*.temporary_icon);
    }
    if (file == null or ffi.g_file_is_native(file) == 0) return 0;
    const query: [*c]IconQuery = ffi.cast([*c]IconQuery, ffi.g_malloc0_n(1, @sizeOf(IconQuery)));
    query.*.request = portal_request_ref(r);
    query.*.generation = d.*.icon_generation;
    ffi.g_file_query_info_async(file, "standard::*,access::can-read,time::modified,time::modified-usec", ffi.G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, 0, r.*.cancel, launcher_info, @ptrCast(@alignCast(query)));
    return 1;
}

pub fn icon_chosen(_: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    const files: ?*ffi.GListModel = chooser.openFinish(result.?, null);
    defer if (files != null) ffi.g_object_unref(@ptrCast(files));
    if ((@as(ffi.guint, @bitCast(@as(c_int, @intFromBool(r.*.finished == 0 and (files != null))))) != 0) and (ffi.g_list_model_get_n_items(files) != 0)) {
        const file: ?*ffi.GFile = @ptrCast(@alignCast(ffi.g_list_model_get_item(files, 0)));
        defer if (file != null) ffi.g_object_unref(@ptrCast(file));
        const icon: ?*ffi.GIcon = ffi.g_file_icon_new(file);
        defer if (icon != null) ffi.g_object_unref(@ptrCast(icon));
        if (launcher_icon(r, icon) != 0) {
            ffi.clear(&d.*.icon, ffi.g_variant_unref);
            d.*.icon = ffi.g_variant_ref_sink(ffi.g_icon_serialize(icon));
        }
        name_changed(ffi.cast(?*ffi.GtkEditable, d.*.entry), @ptrCast(@alignCast(r)));
    }
    portal_request_unref(r);
}

pub fn change_icon(_: [*c]ffi.GtkButton, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    chooser.openAsync(ffi.cast([*c]ffi.GtkWindow, r.*.dialog), 0, @ptrCast(&icon_chosen), @ptrCast(@alignCast(portal_request_ref(r))));
}

pub fn portal_update_choices(r: [*c]Request, choices: ?*ffi.GVariant) callconv(.c) void {
    const d: [*c]DialogData = @ptrCast(@alignCast(r.*.data));
    var previous: [*c]u8 = null;
    defer if (previous != null) ffi.g_free(@ptrCast(previous));
    const selected: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps))));
    if (selected < d.*.ids.*.f_len) {
        previous = ffi.g_strdup(@ptrCast(@alignCast(ffi.items(d.*.ids)[selected])));
    }
    ffi.g_ptr_array_set_size(d.*.ids, 0);
    const labels: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
    var chosen: ffi.guint = @as(c_uint, 4294967295);
    const last: [*c]const u8 = if (previous != null) ffi.cast([*c]const u8, previous) else portal_string(r.*.options, "last_choice", "");
    var iter: ffi.GVariantIter = undefined;
    var id: [*c]const u8 = undefined;
    _ = ffi.g_variant_iter_init(&iter, choices);
    while (ffi.g_variant_iter_next(&iter, "&s", &id) != 0) {
        if (((d.*.ids.*.f_len >= @as(ffi.guint, 256)) or (ffi.cast([*c]const u8, ffi.strchr(id, '/')) != null)) or (ffi.strlen(id) > @as(usize, 255))) continue;
        const desktop: [*c]u8 = if ((ffi.g_str_has_suffix(id, ".desktop")) != 0) ffi.g_strdup(id) else ffi.g_strconcat(id, @constCast(".desktop"), @as(?*anyopaque, null));
        defer if (desktop != null) ffi.g_free(@ptrCast(desktop));
        const app: ?*ffi.GDesktopAppInfo = ffi.g_desktop_app_info_new(desktop);
        defer if (app != null) ffi.g_object_unref(@ptrCast(app));
        if (app == null or ffi.g_app_info_should_show(ffi.cast(?*ffi.GAppInfo, app)) == 0) continue;
        if (ffi.strcmp(id, last) == 0) {
            chosen = d.*.ids.*.f_len;
        }
        ffi.g_ptr_array_add(d.*.ids, @ptrCast(@alignCast(ffi.g_strdup(id))));
        ffi.gtk_string_list_append(labels, ffi.g_app_info_get_display_name(ffi.cast(?*ffi.GAppInfo, app)));
    }
    ffi.gtk_drop_down_set_model(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps))), ffi.G_LIST_MODEL(@ptrCast(@alignCast(labels))));
    ffi.g_object_unref(@ptrCast(@alignCast(labels)));
    ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps))), if ((@as(ffi.guint, @bitCast(@as(c_int, @intFromBool(chosen == @as(c_uint, 4294967295))))) != 0) and (d.*.ids.*.f_len != 0)) @as(ffi.guint, 0) else chosen);
    app_selection(null, null, @ptrCast(@alignCast(r)));
}

pub fn portal_dialogs(r: [*c]Request, params: ?*ffi.GVariant) callconv(.c) void {
    const d: [*c]DialogData = ffi.cast([*c]DialogData, ffi.g_malloc0_n(1, @sizeOf(DialogData)));
    d.*.ids = ffi.g_ptr_array_new_with_free_func(ffi.g_free);
    d.*.choices = ffi.g_ptr_array_new_with_free_func(choice_free);
    r.*.data = @ptrCast(@alignCast(d));
    r.*.destroy_data = data_free;
    if (ffi.strcmp(r.*.method, "AccessDialog") == 0) {
        var title: [*c]const u8 = undefined;
        var subtitle: [*c]const u8 = undefined;
        var text: [*c]const u8 = undefined;
        ffi.g_variant_get_child(params, 3, "&s", &title);
        ffi.g_variant_get_child(params, 4, "&s", &subtitle);
        ffi.g_variant_get_child(params, 5, "&s", &text);
        _ = portal_dialog(r, title, portal_string(r.*.options, "deny_label", "Deny"), portal_string(r.*.options, "grant_label", "Allow"));
        const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
        ffi.gtk_box_append(body, portal_label(subtitle));
        ffi.gtk_box_append(body, portal_label(text));
        const icon: [*c]const u8 = portal_string(r.*.options, "icon", "");
        if (((@as(c_int, icon.*) != 0) and (ffi.strlen(icon) < @as(usize, 256))) and !(ffi.cast([*c]const u8, ffi.strchr(icon, '/')) != null)) {
            ffi.gtk_box_prepend(body, ffi.gtk_image_new_from_icon_name(icon));
        }
        const choices: ?*ffi.GVariant = portal_option(r.*.options, "choices", "a(ssa(ss)s)");
        defer if (choices != null) ffi.g_variant_unref(@ptrCast(choices));
        if ((choices != null) and !(add_choices(r, choices) != 0)) {
            portal_complete(r, 2, null);
            return;
        }
    } else if (ffi.strcmp(r.*.method, "ChooseApplication") == 0) {
        if (portal_restricted(r.*.portal, "disable-application-handlers") != 0) {
            portal_complete(r, 2, null);
            return;
        }
        _ = portal_dialog(r, "Choose an application", "Cancel", "Open");
        const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
        ffi.gtk_box_append(body, portal_label(portal_string(r.*.options, "filename", "Choose an installed application to open this item.")));
        d.*.apps = ffi.gtk_drop_down_new(null, null);
        ffi.gtk_drop_down_set_enable_search(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.apps))), 1);
        ffi.gtk_box_append(body, d.*.apps);
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(d.*.apps)), "notify::selected", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&app_selection)))), @ptrCast(@alignCast(r)), null, 0);
        const choices: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 3);
        defer if (choices != null) ffi.g_variant_unref(@ptrCast(choices));
        portal_update_choices(r, choices);
    } else if (ffi.strcmp(r.*.method, "GetUserInformation") == 0) {
        _ = portal_dialog(r, "Share your profile?", "Cancel", "Share profile");
        const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
        ffi.gtk_box_append(body, portal_label(portal_string(r.*.options, "reason", "Share your profile name and picture with this application.")));
        d.*.user = ffi.g_strdup(ffi.g_get_user_name());
        d.*.name = ffi.g_strdup(ffi.g_get_real_name());
        d.*.profile = portal_label(d.*.name);
        d.*.picture = ffi.gtk_picture_new();
        ffi.gtk_widget_set_size_request(d.*.picture, 96, 96);
        ffi.gtk_picture_set_content_fit(ffi.GTK_PICTURE(@ptrCast(@alignCast(d.*.picture))), ffi.GTK_CONTENT_FIT_CONTAIN);
        ffi.gtk_box_append(body, d.*.picture);
        ffi.gtk_box_append(body, d.*.profile);
        ffi.gtk_box_append(body, portal_label(d.*.user));
        ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 0);
        ffi.g_bus_get(ffi.G_BUS_TYPE_SYSTEM, r.*.cancel, account_bus, @ptrCast(@alignCast(portal_request_ref(r))));
    } else if (ffi.strcmp(r.*.method, "PrepareInstall") == 0) {
        if (portal_restricted(r.*.portal, "disable-application-handlers") != 0) {
            portal_complete(r, 2, null);
            return;
        }
        var @"type": ffi.guint = 1;
        _ = ffi.g_variant_lookup(r.*.options, "launcher_type", "u", &@"type");
        if ((@"type" != @as(ffi.guint, 1)) and (@"type" != @as(ffi.guint, 2))) {
            portal_complete(r, 2, null);
            return;
        }
        const wrapped: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 4);
        defer if (wrapped != null) ffi.g_variant_unref(@ptrCast(wrapped));
        d.*.icon = ffi.g_variant_get_variant(wrapped);
        const icon: ?*ffi.GIcon = ffi.g_icon_deserialize(d.*.icon);
        defer if (icon != null) ffi.g_object_unref(@ptrCast(icon));
        if (icon == null) {
            portal_complete(r, 2, null);
            return;
        }
        var name: [*c]const u8 = undefined;
        ffi.g_variant_get_child(params, 3, "&s", &name);
        _ = portal_dialog(r, "Add application", "Cancel", "Add application");
        const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
        d.*.profile = ffi.gtk_image_new();
        ffi.gtk_image_set_pixel_size(ffi.cast(?*ffi.GtkImage, d.*.profile), 64);
        ffi.gtk_box_append(body, d.*.profile);
        d.*.picture = ffi.gtk_picture_new();
        ffi.gtk_widget_set_size_request(d.*.picture, 96, 96);
        ffi.gtk_picture_set_content_fit(ffi.GTK_PICTURE(@ptrCast(@alignCast(d.*.picture))), ffi.GTK_CONTENT_FIT_CONTAIN);
        ffi.gtk_box_append(body, d.*.picture);
        if (portal_boolean(r.*.options, "editable_icon", 1) != 0) {
            const button: [*c]ffi.GtkWidget = ffi.gtk_button_new_with_label(@import("i18n").dtr("pearl", "Choose icon\xe2\x80\xa6"));
            ffi.gtk_box_append(body, button);
            _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(button)), "clicked", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&change_icon)))), @ptrCast(@alignCast(r)), null, 0);
        }
        d.*.entry = ffi.gtk_entry_new();
        ffi.gtk_editable_set_text(ffi.cast(?*ffi.GtkEditable, d.*.entry), name);
        ffi.gtk_editable_set_editable(ffi.cast(?*ffi.GtkEditable, d.*.entry), portal_boolean(r.*.options, "editable_name", 1));
        ffi.gtk_box_append(body, d.*.entry);
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(d.*.entry)), "changed", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&name_changed)))), @ptrCast(@alignCast(r)), null, 0);
        if (!(launcher_icon(r, icon) != 0)) {
            portal_complete(r, 2, null);
            return;
        }
        name_changed(ffi.cast(?*ffi.GtkEditable, d.*.entry), @ptrCast(@alignCast(r)));
        if (@"type" == @as(ffi.guint, 2)) {
            const target: [*c]const u8 = portal_string(r.*.options, "target", "");
            const uri: ?*ffi.GUri = ffi.g_uri_parse(target, ffi.G_URI_FLAGS_NONE, null);
            defer if (uri != null) ffi.g_uri_unref(@ptrCast(uri));
            if (uri == null or !(ffi.g_uri_get_scheme(uri) != null)) {
                portal_complete(r, 2, null);
                return;
            }
            ffi.gtk_box_append(body, portal_label(target));
        }
    } else {
        portal_complete(r, 2, null);
        return;
    }
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "response", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&responded)))), @ptrCast(@alignCast(r)), null, 0);
    portal_present(r);
}
