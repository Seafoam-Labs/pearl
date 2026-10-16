const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Portal = @import("types.zig").Portal;
const portal_error = @import("backend.zig").portal_error;

pub var active: [*c]Portal = null;

pub var style: [*c]ffi.GtkCssProvider = null;

pub var pending_css: [*c]u8 = null;

const interface_namespace = "org.gnome.desktop.interface";
const theme_keys = .{
    .{ "gtk-theme", "s" },
    .{ "icon-theme", "s" },
    .{ "cursor-theme", "s" },
    .{ "cursor-size", "i" },
};

// GSettings is the source for theme selection only. Pearl owns appearance,
// font and motion; never feed these changes through GTK or generated CSS.
fn interface_changed(settings: [*c]ffi.GSettings, key: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    inline for (theme_keys) |entry| {
        if (ffi.strcmp(key, entry[0]) == 0) {
            const value = ffi.g_settings_get_value(settings, key);
            defer ffi.g_variant_unref(value);
            if (ffi.g_variant_is_of_type(value, ffi.g_variant_type_checked_(entry[1])) != 0) {
                // get_value returns a full reference; setting retains its own.
                setting(p, interface_namespace, key, value);
            }
            return;
        }
    }
}

fn interface_init(p: [*c]Portal) void {
    const source = ffi.g_settings_schema_source_get_default() orelse return;
    const schema = ffi.g_settings_schema_source_lookup(source, interface_namespace, 1) orelse return;
    defer ffi.g_settings_schema_unref(schema);
    p.*.interface_settings = ffi.g_settings_new_full(schema, null, null);
    // Connect before reading: GSettings only signals keys read after connecting.
    p.*.interface_settings_changed = ffi.g_signal_connect_data(
        p.*.interface_settings,
        "changed",
        @ptrCast(&interface_changed),
        p,
        null,
        0,
    );
    inline for (theme_keys) |entry| {
        if (ffi.g_settings_schema_has_key(schema, entry[0]) != 0) {
            interface_changed(p.*.interface_settings, entry[0], p);
        }
    }
}

pub fn portal_style_display(display: ?*ffi.GdkDisplay) callconv(.c) void {
    if ((style != null) and !(ffi.g_object_get_data(ffi.cast([*c]ffi.GObject, display), "pearl-portal-style") != null)) {
        ffi.gtk_style_context_add_provider_for_display(display, ffi.cast(?*ffi.GtkStyleProvider, style), 600);
        ffi.g_object_set_data(ffi.cast([*c]ffi.GObject, display), "pearl-portal-style", @as(ffi.gpointer, @ptrFromInt(@as(usize, @intCast(@as(ffi.glong, 1))))));
    }
    if (active != null) {
        const font: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_hash_table_lookup(active.*.settings, @ptrCast(@alignCast(@constCast("org.gnome.desktop.interface/font-name"))))));
        const motion: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_hash_table_lookup(active.*.settings, @ptrCast(@alignCast(@constCast("org.gnome.desktop.interface/enable-animations"))))));
        if ((font != null) and (motion != null)) {
            ffi.g_object_set(@ptrCast(@alignCast(ffi.gtk_settings_get_for_display(display))), "gtk-font-name", ffi.g_variant_get_string(font, null), @constCast("gtk-enable-animations"), ffi.g_variant_get_boolean(motion), @as(?*anyopaque, null));
        }
    }
}

pub var keys: [8][*c]const u8 = [8][*c]const u8{
    "disable-printing",
    "disable-save-to-disk",
    "disable-application-handlers",
    "disable-location",
    "disable-camera",
    "disable-microphone",
    "disable-sound-output",
    null,
};

pub fn setting(p: [*c]Portal, space: [*c]const u8, key: [*c]const u8, arg_value: ?*ffi.GVariant) callconv(.c) void {
    var value = arg_value;
    const id: [*c]u8 = ffi.g_strconcat(space, @constCast("/"), key, @as(?*anyopaque, null));
    defer if (id != null) ffi.g_free(@ptrCast(id));
    value = ffi.g_variant_ref_sink(value);
    const old: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_hash_table_lookup(p.*.settings, @ptrCast(@alignCast(id)))));
    const changed: ffi.gboolean = @intFromBool(old == null or ffi.g_variant_equal(@ptrCast(@alignCast(old)), @ptrCast(@alignCast(value))) == 0);
    if (changed != 0) {
        _ = ffi.g_hash_table_replace(p.*.settings, @ptrCast(@alignCast(ffi.g_strdup(id))), @ptrCast(@alignCast(value)));
        _ = ffi.g_dbus_connection_emit_signal(p.*.bus, null, "/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Settings", "SettingChanged", ffi.g_variant_new("(ssv)", space, key, value), null);
    } else {
        ffi.g_variant_unref(value);
    }
}

pub fn known(key: [*c]const u8) callconv(.c) ffi.gboolean {
    {
        var i: ffi.guint = 0;
        while (keys[i] != null) : (i +%= 1) if (ffi.strcmp(key, keys[i]) == 0) return 1;
    }
    return 0;
}

pub fn emit_policy(p: [*c]Portal) callconv(.c) void {
    var changes: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&changes, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    {
        var i: ffi.guint = 0;
        while (keys[i] != null) : (i +%= 1) {
            ffi.g_variant_builder_add(&changes, "{sv}", keys[i], ffi.g_variant_new_boolean(portal_restricted(p, keys[i])));
        }
    }
    _ = ffi.g_dbus_connection_emit_signal(p.*.bus, null, "/org/freedesktop/portal/desktop", "org.freedesktop.DBus.Properties", "PropertiesChanged", ffi.g_variant_new("(s@a{sv}@as)", @constCast("org.freedesktop.impl.portal.Lockdown"), ffi.g_variant_builder_end(&changes), ffi.g_variant_new_strv(null, 0)), null);
}

pub fn read_policy(p: [*c]Portal, initial: ffi.gboolean) callconv(.c) void {
    const path: [*c]const u8 = identity.policy_path;
    var st: ffi.GStatBuf = undefined;
    var next: ?*ffi.GKeyFile = ffi.g_key_file_new();
    var @"error": [*c]ffi.GError = null;
    defer if (@"error" != null) ffi.g_error_free(@ptrCast(@"error"));
    const absent: ffi.gboolean = @intFromBool((ffi.stat(path, &st) != 0) and (ffi.__errno_location().* == @as(c_int, 2)));
    var valid: ffi.gboolean = @intFromBool((absent != 0) or ((((((ffi.stat(path, &st) == 0) and ((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) and (st.st_uid == @as(ffi.__uid_t, 0))) and !((st.st_mode & @as(ffi.__mode_t, 18)) != 0)) and (st.st_size <= @as(ffi.__off_t, 65536))) and (ffi.g_key_file_load_from_file(next, path, ffi.G_KEY_FILE_NONE, &@"error") != 0)));
    if ((valid != 0) and absent == 0) {
        var count: ffi.gsize = undefined;
        const present: ffi.GStrv = ffi.g_key_file_get_keys(next, "Restrictions", &count, &@"error");
        defer if (present != null) ffi.g_strfreev(@ptrCast(present));
        if (present == null) {
            valid = 0;
        }
        {
            var i: ffi.gsize = 0;
            while ((present != null) and (i < count)) : (i +%= 1) {
                if (!(known(present[i]) != 0)) {
                    valid = 0;
                    break;
                }
                _ = ffi.g_key_file_get_boolean(next, "Restrictions", present[i], &@"error");
                if (@"error" != null) {
                    valid = 0;
                    break;
                }
            }
        }
    }
    if (valid == 0) {
        ffi.g_key_file_unref(next);
        if (initial == 0) {
            ffi.g_printerr("Portal policy update rejected; retaining last valid restrictions\n");
            return;
        }
        next = ffi.g_key_file_new();
        {
            var i: ffi.guint = 0;
            while (keys[i] != null) : (i +%= 1) {
                ffi.g_key_file_set_boolean(next, "Restrictions", keys[i], 1);
            }
        }
        ffi.g_printerr("Portal policy invalid at startup; restricting operations until corrected\n");
    }
    ffi.clear(&p.*.policy, ffi.g_key_file_unref);
    p.*.policy = next;
    emit_policy(p);
}

pub fn policy_changed(_: [*c]ffi.GFileMonitor, _: ?*ffi.GFile, _: ?*ffi.GFile, _: ffi.GFileMonitorEvent, data: ffi.gpointer) callconv(.c) void {
    read_policy(@ptrCast(@alignCast(data)), 0);
}

pub fn managed_changed(_: [*c]ffi.GSettings, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    emit_policy(@ptrCast(@alignCast(data)));
}

pub fn namespace_matches(patterns: ?*ffi.GVariant, space: [*c]const u8) callconv(.c) ffi.gboolean {
    if (ffi.g_variant_n_children(patterns) == 0) return 1;
    var iter: ffi.GVariantIter = undefined;
    var pattern: [*c]const u8 = undefined;
    _ = ffi.g_variant_iter_init(&iter, patterns);
    while (ffi.g_variant_iter_next(&iter, "&s", &pattern) != 0) {
        if (!(@as(c_int, pattern.*) != 0) or ffi.strcmp(pattern, space) == 0) return 1;
        const n: ffi.gsize = ffi.strlen(pattern);
        if ((((n >= @as(ffi.gsize, 2)) and (@as(c_int, pattern[n -% @as(ffi.gsize, 1)]) == @as(c_int, '*'))) and (@as(c_int, pattern[n -% @as(ffi.gsize, 2)]) == @as(c_int, '.'))) and ffi.strncmp(pattern, space, n -% @as(ffi.gsize, 1)) == 0) return 1;
    }
    return 0;
}

pub fn portal_appearance(scheme: ffi.guint, r: f64, g: f64, b: f64, reduced: ffi.gboolean, font: [*c]const u8, css: [*c]const u8) callconv(.c) void {
    if (active == null) return;
    setting(active, "org.freedesktop.appearance", "color-scheme", ffi.g_variant_new_uint32(scheme));
    setting(active, "org.freedesktop.appearance", "accent-color", ffi.g_variant_new("(ddd)", r, g, b));
    setting(active, "org.freedesktop.appearance", "contrast", ffi.g_variant_new_uint32(0));
    setting(active, "org.freedesktop.appearance", "reduced-motion", ffi.g_variant_new_uint32(@bitCast(@as(c_int, if (reduced != 0) 1 else 0))));
    setting(active, "org.gnome.desktop.interface", "color-scheme", ffi.g_variant_new_string(if (scheme == @as(ffi.guint, 1)) @constCast("prefer-dark") else @constCast("prefer-light")));
    setting(active, "org.gnome.desktop.interface", "font-name", ffi.g_variant_new_string(font));
    setting(active, "org.gnome.desktop.interface", "enable-animations", ffi.g_variant_new_boolean(@intFromBool(reduced == 0)));
    ffi.g_free(@ptrCast(@alignCast(pending_css)));
    pending_css = ffi.g_strdup(css);
    if (ffi.gdk_display_get_default() != null) {
        if (style == null) {
            style = ffi.gtk_css_provider_new();
        }
        ffi.gtk_css_provider_load_from_string(style, pending_css);
        portal_style_display(ffi.gdk_display_get_default());
        ffi.g_object_set(@ptrCast(@alignCast(ffi.gtk_settings_get_default())), "gtk-enable-animations", @as(c_int, @intFromBool(reduced == 0)), @constCast("gtk-font-name"), font, @as(?*anyopaque, null));
    }
}

pub fn portal_restricted(p: [*c]Portal, key: [*c]const u8) callconv(.c) ffi.gboolean {
    var restricted: ffi.gboolean = ffi.g_key_file_get_boolean(p.*.policy, "Restrictions", key, null);
    if (p.*.managed_policy != null) {
        const source: ?*ffi.GSettingsSchemaSource = ffi.g_settings_schema_source_get_default();
        const schema: ?*ffi.GSettingsSchema = ffi.g_settings_schema_source_lookup(source, "org.gnome.desktop.lockdown", 1);
        defer if (schema != null) ffi.g_settings_schema_unref(@ptrCast(schema));
        if ((schema != null) and (ffi.g_settings_schema_has_key(schema, key) != 0)) {
            restricted |= ffi.g_settings_get_boolean(p.*.managed_policy, key);
        }
    }
    return restricted;
}

pub fn portal_settings_property(p: [*c]Portal, name: [*c]const u8, @"error": [*c][*c]ffi.GError) callconv(.c) ?*ffi.GVariant {
    if (known(name) != 0) return ffi.g_variant_new_boolean(portal_restricted(p, name));
    ffi.g_set_error_literal(@"error", ffi.g_dbus_error_quark(), ffi.G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown restriction");
    return null;
}

pub fn portal_settings_init(p: [*c]Portal) callconv(.c) void {
    active = p;
    p.*.settings = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, ffi.g_free, @ptrCast(@alignCast(@constCast(&ffi.g_variant_unref))));
    portal_appearance(1, @as(f64, 208.0) / @as(f64, 255.0), @as(f64, 188.0) / @as(f64, 255.0), @floatFromInt(1), 0, "Sans 14", "");
    interface_init(p);
    read_policy(p, 1);
    const file: ?*ffi.GFile = ffi.g_file_new_for_path(identity.policy_path);
    defer if (file != null) ffi.g_object_unref(@ptrCast(file));
    p.*.policy_monitor = ffi.g_file_monitor_file(file, ffi.G_FILE_MONITOR_WATCH_MOVES, null, null);
    if (p.*.policy_monitor != null) {
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(p.*.policy_monitor)), "changed", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&policy_changed)))), @ptrCast(@alignCast(p)), null, 0);
    }
    const source: ?*ffi.GSettingsSchemaSource = ffi.g_settings_schema_source_get_default();
    const schema: ?*ffi.GSettingsSchema = @ptrCast(@alignCast(if (source != null) ffi.cast(?*anyopaque, ffi.g_settings_schema_source_lookup(source, "org.gnome.desktop.lockdown", 1)) else null));
    defer if (schema != null) ffi.g_settings_schema_unref(@ptrCast(schema));
    if (schema != null) {
        p.*.managed_policy = ffi.g_settings_new_full(schema, null, null);
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(p.*.managed_policy)), "changed", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&managed_changed)))), @ptrCast(@alignCast(p)), null, 0);
    }
}

pub fn portal_settings_stop(p: [*c]Portal) callconv(.c) void {
    active = null;
    if (p.*.interface_settings_changed != 0) {
        ffi.g_signal_handler_disconnect(p.*.interface_settings, p.*.interface_settings_changed);
        p.*.interface_settings_changed = 0;
    }
    ffi.clear(&p.*.interface_settings, ffi.g_object_unref);
    if ((style != null) and (ffi.gdk_display_get_default() != null)) {
        ffi.gtk_style_context_remove_provider_for_display(ffi.gdk_display_get_default(), ffi.cast(?*ffi.GtkStyleProvider, style));
    }
    ffi.clear(&style, ffi.g_object_unref);
    ffi.clear(&pending_css, ffi.g_free);
    ffi.clear(&p.*.policy_monitor, ffi.g_object_unref);
    ffi.clear(&p.*.managed_policy, ffi.g_object_unref);
    ffi.clear(&p.*.policy, ffi.g_key_file_unref);
    ffi.clear(&p.*.settings, ffi.g_hash_table_unref);
}

pub fn portal_settings_call(p: [*c]Portal, method: [*c]const u8, params: ?*ffi.GVariant, call: ?*ffi.GDBusMethodInvocation) callconv(.c) void {
    if (ffi.strcmp(method, "Read") == 0) {
        var space: [*c]const u8 = undefined;
        var key: [*c]const u8 = undefined;
        ffi.g_variant_get(params, "(&s&s)", &space, &key);
        const id: [*c]u8 = ffi.g_strconcat(space, @constCast("/"), key, @as(?*anyopaque, null));
        defer if (id != null) ffi.g_free(@ptrCast(id));
        const v: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_hash_table_lookup(p.*.settings, @ptrCast(@alignCast(id)))));
        if (v != null) {
            ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(v)", v));
        } else {
            portal_error(call, "NotFound", "Unknown setting");
        }
        return;
    }
    const patterns: ?*ffi.GVariant = ffi.g_variant_get_child_value(params, 0);
    defer if (patterns != null) ffi.g_variant_unref(@ptrCast(patterns));
    var result: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&result, ffi.g_variant_type_checked_("a{sa{sv}}"));
    const spaces: [3][*c]const u8 = [3][*c]const u8{
        "org.freedesktop.appearance",
        "org.gnome.desktop.interface",
        null,
    };
    {
        var i: ffi.guint = 0;
        while (spaces[i] != null) : (i +%= 1) if (namespace_matches(patterns, spaces[i]) != 0) {
            var values: ffi.GVariantBuilder = undefined;
            ffi.g_variant_builder_init(&values, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
            var iter: ffi.GHashTableIter = undefined;
            var key: ffi.gpointer = undefined;
            var value: ffi.gpointer = undefined;
            ffi.g_hash_table_iter_init(&iter, p.*.settings);
            while (ffi.g_hash_table_iter_next(&iter, &key, &value) != 0) {
                const sep: [*c]const u8 = ffi.strchr(@ptrCast(@alignCast(key)), '/');
                if (((sep != null) and (@as(ffi.gsize, @bitCast(@as(c_long, @divExact(@as(c_long, @bitCast(@intFromPtr(sep) -% @intFromPtr(ffi.cast([*c]u8, key)))), @sizeOf(u8))))) == ffi.strlen(spaces[i]))) and ffi.strncmp(@ptrCast(@alignCast(key)), spaces[i], ffi.strlen(spaces[i])) == 0) {
                    ffi.g_variant_builder_add(&values, "{sv}", sep + @as(usize, @bitCast(@as(isize, @intCast(1)))), ffi.cast(?*ffi.GVariant, value));
                }
            }
            ffi.g_variant_builder_add(&result, "{s@a{sv}}", spaces[i], ffi.g_variant_builder_end(&values));
        };
    }
    ffi.g_dbus_method_invocation_return_value(call, ffi.g_variant_new("(@a{sa{sv}})", ffi.g_variant_builder_end(&result)));
}
