const chooser = @import("file_chooser");
const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Portal = @import("types.zig").Portal;
const Request = @import("types.zig").Request;
const portal_app_name = @import("backend.zig").portal_app_name;
const portal_boolean = @import("backend.zig").portal_boolean;
const portal_complete = @import("backend.zig").portal_complete;
const portal_option = @import("backend.zig").portal_option;
const portal_present = @import("backend.zig").portal_present;
const portal_string = @import("backend.zig").portal_string;

pub fn bytes_path(value: ?*ffi.GVariant, path: [*c][*c]u8) callconv(.c) ffi.gboolean {
    var n: ffi.gsize = 0;
    const bytes: [*c]const u8 = @ptrCast(@alignCast(ffi.g_variant_get_fixed_array(value, &n, 1)));
    if ((((n == 0 or (n > @as(ffi.gsize, 4096))) or (@as(c_int, bytes[n -% @as(ffi.gsize, 1)]) != 0)) or (ffi.strlen(bytes) != (n -% @as(ffi.gsize, 1)))) or ffi.g_path_is_absolute(bytes) == 0) return 0;
    path.* = @ptrCast(@alignCast(ffi.g_memdup2(@ptrCast(@alignCast(bytes)), n)));
    return 1;
}

pub fn make_filter(value: ?*ffi.GVariant) callconv(.c) ?*ffi.GtkFileFilter {
    var name: [*c]const u8 = undefined;
    var rules: ?*ffi.GVariant = undefined;
    ffi.g_variant_get(value, "(&s@a(us))", &name, &rules);
    const owned: ?*ffi.GVariant = rules;
    defer if (owned != null) ffi.g_variant_unref(@ptrCast(owned));
    if ((ffi.strlen(name) > @as(usize, 512)) or (ffi.g_variant_n_children(rules) > @as(ffi.gsize, 128))) return null;
    const filter: ?*ffi.GtkFileFilter = ffi.gtk_file_filter_new();
    ffi.gtk_file_filter_set_name(filter, name);
    var iter: ffi.GVariantIter = undefined;
    _ = ffi.g_variant_iter_init(&iter, rules);
    var @"type": ffi.guint = undefined;
    var pattern: [*c]const u8 = undefined;
    while (ffi.g_variant_iter_next(&iter, "(u&s)", &@"type", &pattern) != 0) {
        if ((ffi.strlen(pattern) > @as(usize, 1024)) or (@"type" > @as(ffi.guint, 1))) {
            ffi.g_object_unref(@ptrCast(@alignCast(filter)));
            return null;
        }
        if (@"type" == @as(ffi.guint, 0)) {
            ffi.gtk_file_filter_add_pattern(filter, pattern);
        } else {
            ffi.gtk_file_filter_add_mime_type(filter, pattern);
        }
    }
    ffi.g_object_set_data_full(ffi.cast([*c]ffi.GObject, filter), "portal-filter", @ptrCast(@alignCast(ffi.g_variant_ref(value))), @ptrCast(@alignCast(@constCast(&ffi.g_variant_unref))));
    return filter;
}

pub fn response(dialog: [*c]ffi.GtkDialog, code: c_int, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    if (code != ffi.GTK_RESPONSE_ACCEPT) {
        portal_complete(r, 1, null);
        return;
    }
    if ((ffi.strcmp(r.*.method, "OpenFile") != 0) and (portal_restricted(r.*.portal, "disable-save-to-disk") != 0)) {
        portal_complete(r, 2, null);
        return;
    }
    const files: ?*ffi.GListModel = chooser.getFiles(dialog);
    defer if (files != null) ffi.g_object_unref(@ptrCast(files));
    if (files == null) {
        portal_complete(r, 2, null);
        return;
    }
    var uris: ffi.GVariantBuilder = undefined;
    var result: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&uris, ffi.g_variant_type_checked_("as"));
    ffi.g_variant_builder_init(&result, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    {
        var i: ffi.guint = 0;
        while (i < ffi.g_list_model_get_n_items(files)) : (i +%= 1) {
            const file: ?*ffi.GFile = @ptrCast(@alignCast(ffi.g_list_model_get_item(files, i)));
            defer if (file != null) ffi.g_object_unref(@ptrCast(file));
            const path: [*c]u8 = ffi.g_file_get_path(file);
            defer if (path != null) ffi.g_free(@ptrCast(path));
            if (path == null) {
                ffi.g_variant_builder_clear(&uris);
                ffi.g_variant_builder_clear(&result);
                portal_complete(r, 2, null);
                return;
            }
            const local: ?*ffi.GFile = ffi.g_file_new_for_path(path);
            defer if (local != null) ffi.g_object_unref(@ptrCast(local));
            const uri: [*c]u8 = ffi.g_file_get_uri(local);
            defer if (uri != null) ffi.g_free(@ptrCast(uri));
            ffi.g_variant_builder_add(&uris, "s", uri);
        }
    }
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("uris"), ffi.g_variant_builder_end(&uris));
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("choices"), chooser.getChoices(dialog));
    const filter: ?*ffi.GtkFileFilter = chooser.getFilter(dialog);
    if (filter != null) {
        const original: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_object_get_data(ffi.cast([*c]ffi.GObject, filter), "portal-filter")));
        if (original != null) {
            ffi.g_variant_builder_add(&result, "{sv}", @constCast("current_filter"), original);
        }
    }
    portal_complete(r, 0, ffi.g_variant_builder_end(&result));
}

const portal_restricted = @import("settings.zig").portal_restricted;

pub fn portal_files(r: [*c]Request, params: ?*ffi.GVariant) callconv(.c) void {
    const open: ffi.gboolean = @intFromBool(ffi.strcmp(r.*.method, "OpenFile") == 0);
    const batch: ffi.gboolean = @intFromBool(ffi.strcmp(r.*.method, "SaveFiles") == 0);
    if (open == 0 and (portal_restricted(r.*.portal, "disable-save-to-disk") != 0)) {
        portal_complete(r, 2, null);
        return;
    }
    var title: [*c]const u8 = undefined;
    ffi.g_variant_get_child(params, 3, "&s", &title);
    if (ffi.strlen(title) > @as(usize, 4096)) {
        portal_complete(r, 2, null);
        return;
    }
    const action: ffi.GtkFileChooserAction = @bitCast(if (open != 0) if (portal_boolean(r.*.options, "directory", 0) != 0) ffi.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER else ffi.GTK_FILE_CHOOSER_ACTION_OPEN else if (batch != 0) ffi.GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER else ffi.GTK_FILE_CHOOSER_ACTION_SAVE);
    r.*.dialog = chooser.create(title, @enumFromInt(action));
    _ = ffi.g_object_ref_sink(@ptrCast(@alignCast(r.*.dialog)));
    const state_key: [*c]u8 = ffi.g_strdup_printf("portal/%s/%s", r.*.app_id, r.*.method);
    defer if (state_key != null) ffi.g_free(@ptrCast(state_key));
    chooser.setStateKey(r.*.dialog, state_key);
    chooser.setMultiple(r.*.dialog, @intFromBool((open != 0) and (portal_boolean(r.*.options, "multiple", 0) != 0)));
    const name: [*c]u8 = portal_app_name(r.*.app_id);
    defer if (name != null) ffi.g_free(@ptrCast(name));
    const caller: [*c]u8 = ffi.g_strdup_printf("Requested by %s", name);
    defer if (caller != null) ffi.g_free(@ptrCast(caller));
    chooser.setCaller(r.*.dialog, caller);
    chooser.setAcceptLabel(r.*.dialog, portal_string(r.*.options, "accept_label", if (open != 0) @constCast("Open") else @constCast("Save")));
    chooser.setName(r.*.dialog, portal_string(r.*.options, "current_name", "Untitled"));
    const filters: ?*ffi.GVariant = portal_option(r.*.options, "filters", "a(sa(us))");
    defer if (filters != null) ffi.g_variant_unref(@ptrCast(filters));
    const current: ?*ffi.GVariant = portal_option(r.*.options, "current_filter", "(sa(us))");
    defer if (current != null) ffi.g_variant_unref(@ptrCast(current));
    var selected: ffi.gboolean = 0;
    if (filters != null) {
        if (ffi.g_variant_n_children(filters) > @as(ffi.gsize, 64)) {
            portal_complete(r, 2, null);
            return;
        }
        {
            var i: ffi.guint = 0;
            while (@as(ffi.gsize, i) < ffi.g_variant_n_children(filters)) : (i +%= 1) {
                const raw: ?*ffi.GVariant = ffi.g_variant_get_child_value(filters, i);
                defer if (raw != null) ffi.g_variant_unref(@ptrCast(raw));
                const f: ?*ffi.GtkFileFilter = make_filter(raw);
                defer if (f != null) ffi.g_object_unref(@ptrCast(f));
                if (f == null) {
                    portal_complete(r, 2, null);
                    return;
                }
                chooser.addFilter(r.*.dialog, f.?);
                if ((current != null) and (ffi.g_variant_equal(@ptrCast(@alignCast(current)), @ptrCast(@alignCast(raw))) != 0)) {
                    chooser.setFilter(r.*.dialog, f.?);
                    selected = 1;
                }
            }
        }
    }
    if ((current != null) and selected == 0) {
        const f: ?*ffi.GtkFileFilter = make_filter(current);
        defer if (f != null) ffi.g_object_unref(@ptrCast(f));
        if (f == null) {
            portal_complete(r, 2, null);
            return;
        }
        chooser.addFilter(r.*.dialog, f.?);
        chooser.setFilter(r.*.dialog, f.?);
    }
    const folder: ?*ffi.GVariant = portal_option(r.*.options, "current_folder", "ay");
    defer if (folder != null) ffi.g_variant_unref(@ptrCast(folder));
    if (folder != null) {
        var path: [*c]u8 = null;
        defer if (path != null) ffi.g_free(@ptrCast(path));
        if (!(bytes_path(folder, &path) != 0)) {
            portal_complete(r, 2, null);
            return;
        }
        const file: ?*ffi.GFile = ffi.g_file_new_for_path(path);
        defer if (file != null) ffi.g_object_unref(@ptrCast(file));
        chooser.setFolder(r.*.dialog, file.?);
    }
    const current_file: ?*ffi.GVariant = portal_option(r.*.options, "current_file", "ay");
    defer if (current_file != null) ffi.g_variant_unref(@ptrCast(current_file));
    if (current_file != null) {
        var path: [*c]u8 = null;
        defer if (path != null) ffi.g_free(@ptrCast(path));
        if (!(bytes_path(current_file, &path) != 0)) {
            portal_complete(r, 2, null);
            return;
        }
        const file: ?*ffi.GFile = ffi.g_file_new_for_path(path);
        defer if (file != null) ffi.g_object_unref(@ptrCast(file));
        chooser.setFile(r.*.dialog, file.?);
    }
    const choices: ?*ffi.GVariant = portal_option(r.*.options, "choices", "a(ssa(ss)s)");
    defer if (choices != null) ffi.g_variant_unref(@ptrCast(choices));
    if ((choices != null) and chooser.setChoices(r.*.dialog, choices.?, null) == 0) {
        portal_complete(r, 2, null);
        return;
    }
    if (batch != 0) {
        const names: ?*ffi.GVariant = portal_option(r.*.options, "files", "aay");
        defer if (names != null) ffi.g_variant_unref(@ptrCast(names));
        if (names == null or chooser.setBatch(r.*.dialog, names.?, null) == 0) {
            portal_complete(r, 2, null);
            return;
        }
    }
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "response", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&response)))), @ptrCast(@alignCast(r)), null, 0);
    portal_present(r);
}
