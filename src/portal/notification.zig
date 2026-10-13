const portal_option = @import("backend.zig").portal_option;
const portal_app_name = @import("backend.zig").portal_app_name;
const portal_string = @import("backend.zig").portal_string;
const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Portal = @import("types.zig").Portal;
const portal_authorized = @import("backend.zig").portal_authorized;
const portal_error = @import("backend.zig").portal_error;

pub const Notice = extern struct {
    app: [*c]u8 = null,
    id: [*c]u8 = null,
    owner: [*c]u8 = null,
    token: [*c]u8 = null,
    native_id: ffi.guint = 0,
    actions: ?*ffi.GHashTable = null,
};

pub const NoticeJob = extern struct {
    portal: [*c]Portal = null,
    call: ?*ffi.GDBusMethodInvocation = null,
    key: [*c]u8 = null,
    owner: [*c]u8 = null,
    notice: [*c]Notice = null,
    icon_fd: c_int = 0,
    remove: ffi.gboolean = 0,
};

pub fn state_path(p: [*c]Portal) callconv(.c) [*c]u8 {
    const runtime: [*c]const u8 = ffi.g_getenv("XDG_RUNTIME_DIR");
    if (runtime == null or ffi.g_path_is_absolute(runtime) == 0) return null;
    const directory: [*c]u8 = ffi.g_build_filename(runtime, @constCast(identity.state_name), @as(?*anyopaque, null));
    defer if (directory != null) ffi.g_free(@ptrCast(directory));
    var st: ffi.struct_stat = undefined;
    if ((@as(ffi.__mode_t, @bitCast(@as(c_int, @intFromBool((((ffi.g_mkdir_with_parents(directory, 448) != 0) or (ffi.lstat(directory, &st) != 0)) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 16384)))))) or (st.st_uid != ffi.getuid()))))) != 0) or ((st.st_mode & @as(ffi.__mode_t, 63)) != 0)) return null;
    const name: [*c]u8 = ffi.g_strconcat(ffi.g_dbus_connection_get_guid(p.*.bus), @constCast(".notifications"), @as(?*anyopaque, null));
    defer if (name != null) ffi.g_free(@ptrCast(name));
    return ffi.g_build_filename(directory, name, @as(?*anyopaque, null));
}

pub fn save_state(p: [*c]Portal) callconv(.c) void {
    const path: [*c]u8 = state_path(p);
    defer if (path != null) ffi.g_free(@ptrCast(path));
    if (path == null) return;
    if (p.*.notification_owner == null or ffi.g_hash_table_size(p.*.notifications) == 0) {
        _ = ffi.g_unlink(path);
        return;
    }
    var entries: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&entries, ffi.g_variant_type_checked_("a(ssua{s(sav)})"));
    var iter: ffi.GHashTableIter = undefined;
    var value: ffi.gpointer = undefined;
    ffi.g_hash_table_iter_init(&iter, p.*.notifications);
    while (ffi.g_hash_table_iter_next(&iter, null, &value) != 0) {
        const n: [*c]Notice = @ptrCast(@alignCast(value));
        var actions: ffi.GVariantBuilder = undefined;
        ffi.g_variant_builder_init(&actions, ffi.g_variant_type_checked_("a{s(sav)}"));
        var ai: ffi.GHashTableIter = undefined;
        var key: ffi.gpointer = undefined;
        var stored: ffi.gpointer = undefined;
        ffi.g_hash_table_iter_init(&ai, n.*.actions);
        while (ffi.g_hash_table_iter_next(&ai, &key, &stored) != 0) {
            ffi.g_variant_builder_add(&actions, "{s@(sav)}", ffi.cast([*c]u8, key), ffi.g_variant_ref(@ptrCast(@alignCast(stored))));
        }
        ffi.g_variant_builder_add(&entries, "(ssu@a{s(sav)})", n.*.app, n.*.id, n.*.native_id, ffi.g_variant_builder_end(&actions));
    }
    const state: ?*ffi.GVariant = ffi.g_variant_ref_sink(ffi.g_variant_new("(ss@a(ssua{s(sav)}))", ffi.g_dbus_connection_get_guid(p.*.bus), p.*.notification_owner, ffi.g_variant_builder_end(&entries)));
    defer if (state != null) ffi.g_variant_unref(@ptrCast(state));
    if (ffi.g_variant_get_size(state) <= @as(ffi.gsize, @bitCast(@as(c_long, (@as(c_int, 8) * @as(c_int, 1024)) * @as(c_int, 1024))))) {
        _ = ffi.g_file_set_contents_full(path, @ptrCast(@alignCast(ffi.g_variant_get_data(state))), @bitCast(@as(c_ulong, @truncate(ffi.g_variant_get_size(state)))), ffi.G_FILE_SET_CONTENTS_CONSISTENT, 384, null);
    }
}

pub fn load_state(p: [*c]Portal) callconv(.c) void {
    const path: [*c]u8 = state_path(p);
    defer if (path != null) ffi.g_free(@ptrCast(path));
    if (path == null) return;
    const fd: c_int = ffi.open(path, ((0 | @as(c_int, 524288)) | @as(c_int, 131072)) | @as(c_int, 2048));
    if (fd < 0) return;
    var st: ffi.struct_stat = undefined;
    if ((((@as(ffi.__mode_t, @bitCast(@as(c_int, @intFromBool(((ffi.fstat(fd, &st) != 0) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) or (st.st_uid != ffi.getuid()))))) != 0) or ((st.st_mode & @as(ffi.__mode_t, 63)) != 0)) or (st.st_size < @as(ffi.__off_t, 1))) or (st.st_size > @as(ffi.__off_t, (@as(c_int, 8) * @as(c_int, 1024)) * @as(c_int, 1024)))) {
        _ = ffi.close(fd);
        return;
    }
    var contents: [*c]u8 = @ptrCast(@alignCast(ffi.g_malloc(@bitCast(@as(c_long, st.st_size)))));
    defer if (contents != null) ffi.g_free(@ptrCast(contents));
    var used: ffi.gsize = 0;
    while (used < @as(ffi.gsize, @bitCast(@as(c_long, st.st_size)))) {
        const count: isize = ffi.read(fd, @ptrCast(@alignCast(contents + used)), @as(ffi.gsize, @bitCast(@as(c_long, st.st_size))) -% used);
        if (count <= @as(isize, 0)) break;
        used +%= @bitCast(@as(c_long, count));
    }
    _ = ffi.close(fd);
    if (used != @as(ffi.gsize, @bitCast(@as(c_long, st.st_size)))) return;
    const bytes: ?*ffi.GBytes = ffi.g_bytes_new_take(@ptrCast(@alignCast(@as(@TypeOf((&contents).*), @ptrCast(@alignCast(ffi.g_steal_pointer(@ptrCast(@alignCast(&contents)))))))), used);
    defer if (bytes != null) ffi.g_bytes_unref(@ptrCast(bytes));
    const state: ?*ffi.GVariant = ffi.g_variant_ref_sink(ffi.g_variant_new_from_bytes(ffi.g_variant_type_checked_("(ssa(ssua{s(sav)}))"), bytes, 0));
    defer if (state != null) ffi.g_variant_unref(@ptrCast(state));
    if (ffi.g_variant_is_normal_form(state) == 0) return;
    var guid: [*c]const u8 = undefined;
    var owner: [*c]const u8 = undefined;
    var array: ?*ffi.GVariant = undefined;
    ffi.g_variant_get(state, "(&s&s@a(ssua{s(sav)}))", &guid, &owner, &array);
    const entries: ?*ffi.GVariant = array;
    defer if (entries != null) ffi.g_variant_unref(@ptrCast(entries));
    if (((ffi.strcmp(guid, ffi.g_dbus_connection_get_guid(p.*.bus)) != 0) or (ffi.g_strcmp0(owner, p.*.notification_owner) != 0)) or (ffi.g_variant_n_children(entries) > @as(ffi.gsize, 256))) return;
    {
        var i: ffi.guint = 0;
        while (@as(ffi.gsize, i) < ffi.g_variant_n_children(entries)) : (i +%= 1) {
            const item: ?*ffi.GVariant = ffi.g_variant_get_child_value(entries, i);
            defer if (item != null) ffi.g_variant_unref(@ptrCast(item));
            var app: [*c]const u8 = undefined;
            var id: [*c]const u8 = undefined;
            var native_id: ffi.guint = undefined;
            var actions: ?*ffi.GVariant = undefined;
            ffi.g_variant_get(item, "(&s&su@a{s(sav)})", &app, &id, &native_id, &actions);
            const owned_actions: ?*ffi.GVariant = actions;
            defer if (owned_actions != null) ffi.g_variant_unref(@ptrCast(owned_actions));
            if ((((((ffi.strlen(app) > @as(usize, 255)) or (ffi.strlen(id) > @as(usize, 1024))) or (ffi.cast([*c]const u8, ffi.strchr(app, '\n')) != null)) or (ffi.cast([*c]const u8, ffi.strchr(id, '\n')) != null)) or native_id == 0) or (ffi.g_variant_n_children(actions) > @as(ffi.gsize, 8))) continue;
            const n: [*c]Notice = ffi.cast([*c]Notice, ffi.g_malloc0_n(1, @sizeOf(Notice)));
            n.*.app = ffi.g_strdup(app);
            n.*.id = ffi.g_strdup(id);
            n.*.owner = ffi.g_strdup(owner);
            n.*.native_id = native_id;
            n.*.actions = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, ffi.g_free, @ptrCast(@alignCast(@constCast(&ffi.g_variant_unref))));
            var iter: ffi.GVariantIter = undefined;
            var key: [*c]const u8 = undefined;
            var stored: ?*ffi.GVariant = undefined;
            _ = ffi.g_variant_iter_init(&iter, actions);
            while (ffi.g_variant_iter_next(&iter, "{&s@(sav)}", &key, &stored) != 0) {
                _ = ffi.g_hash_table_insert(n.*.actions, @ptrCast(@alignCast(ffi.g_strdup(key))), @ptrCast(@alignCast(stored)));
            }
            _ = ffi.g_hash_table_insert(p.*.notifications, @ptrCast(@alignCast(ffi.g_strdup_printf("%s\n%s", app, id))), @ptrCast(@alignCast(n)));
        }
    }
}

pub fn notice_free(data: ffi.gpointer) callconv(.c) void {
    const n: [*c]Notice = @ptrCast(@alignCast(data));
    ffi.g_free(@ptrCast(@alignCast(n.*.app)));
    ffi.g_free(@ptrCast(@alignCast(n.*.id)));
    ffi.g_free(@ptrCast(@alignCast(n.*.owner)));
    ffi.g_free(@ptrCast(@alignCast(n.*.token)));
    ffi.g_hash_table_unref(n.*.actions);
    ffi.g_free(@ptrCast(@alignCast(n)));
}

pub fn job_free(job: [*c]NoticeJob) callconv(.c) void {
    if (job.*.icon_fd >= 0) {
        _ = ffi.close(job.*.icon_fd);
    }
    ffi.clear(&job.*.call, ffi.g_object_unref);
    if (job.*.notice != null) {
        notice_free(@ptrCast(@alignCast(job.*.notice)));
    }
    _ = ffi.g_hash_table_remove(job.*.portal.*.notification_busy, @ptrCast(@alignCast(job.*.key)));
    ffi.g_free(@ptrCast(@alignCast(job.*.key)));
    ffi.g_free(@ptrCast(@alignCast(job.*.owner)));
    ffi.g_free(@ptrCast(@alignCast(job)));
}

pub fn sent(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const job: [*c]NoticeJob = @ptrCast(@alignCast(data));
    const p: [*c]Portal = job.*.portal;
    var @"error": [*c]ffi.GError = null;
    defer if (@"error" != null) ffi.g_error_free(@ptrCast(@"error"));
    const reply: ?*ffi.GVariant = ffi.g_dbus_connection_call_finish(ffi.cast(?*ffi.GDBusConnection, source), result, &@"error");
    defer if (reply != null) ffi.g_variant_unref(@ptrCast(reply));
    if ((reply == null or (ffi.g_strcmp0(job.*.owner, p.*.notification_owner) != 0)) or !(portal_authorized(p, ffi.g_dbus_method_invocation_get_sender(job.*.call)) != 0)) {
        portal_error(job.*.call, "Failed", "Notification service is unavailable or changed ownership");
        job_free(job);
        return;
    }
    if (job.*.remove != 0) {
        _ = ffi.g_hash_table_remove(p.*.notifications, @ptrCast(@alignCast(job.*.key)));
    } else {
        ffi.g_variant_get(reply, "(u)", &job.*.notice.*.native_id);
        _ = ffi.g_hash_table_replace(p.*.notifications, @ptrCast(@alignCast(ffi.g_strdup(job.*.key))), @ptrCast(@alignCast(job.*.notice)));
        job.*.notice = null;
    }
    save_state(p);
    ffi.g_dbus_method_invocation_return_value(job.*.call, null);
    job_free(job);
}

pub fn action(n: [*c]Notice, out: [*c]ffi.GVariantBuilder, key: [*c]const u8, label: [*c]const u8, name: [*c]const u8, target: ?*ffi.GVariant) callconv(.c) ffi.gboolean {
    if ((((!(@as(c_int, name.*) != 0) and (ffi.strcmp(key, "default") != 0)) or (ffi.strlen(name) > @as(usize, 1024))) or (ffi.strlen(label) > @as(usize, 160))) or ((target != null) and (ffi.g_variant_get_size(target) > @as(ffi.gsize, 1024)))) return 0;
    var args: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&args, ffi.g_variant_type_checked_("av"));
    if (target != null) {
        ffi.g_variant_builder_add(&args, "v", target);
    }
    _ = ffi.g_hash_table_insert(n.*.actions, @ptrCast(@alignCast(ffi.g_strdup(key))), @ptrCast(@alignCast(ffi.g_variant_ref_sink(ffi.g_variant_new("(s@av)", name, ffi.g_variant_builder_end(&args))))));
    ffi.g_variant_builder_add(out, "s", key);
    ffi.g_variant_builder_add(out, "s", label);
    return 1;
}

pub fn icon_name(call: ?*ffi.GDBusMethodInvocation, notification: ?*ffi.GVariant, fd: [*c]c_int) callconv(.c) [*c]u8 {
    var icon: ?*ffi.GVariant = ffi.g_variant_lookup_value(notification, "icon", null);
    defer if (icon != null) ffi.g_variant_unref(@ptrCast(icon));
    if (icon == null) return ffi.g_strdup("");
    while (ffi.g_variant_is_of_type(icon, ffi.cast(?*const ffi.GVariantType, "v")) != 0) {
        const child: ?*ffi.GVariant = ffi.g_variant_get_variant(icon);
        ffi.g_variant_unref(icon);
        icon = child;
    }
    if (ffi.g_variant_is_of_type(icon, ffi.cast(?*const ffi.GVariantType, "s")) != 0) {
        const name: [*c]const u8 = ffi.g_variant_get_string(icon, null);
        return @ptrCast(@alignCast(if (!(ffi.cast([*c]const u8, ffi.strchr(name, '/')) != null)) ffi.cast(?*anyopaque, ffi.g_strdup(name)) else null));
    }
    if (ffi.g_variant_is_of_type(icon, ffi.g_variant_type_checked_("(sv)")) == 0) return null;
    var kind: [*c]const u8 = undefined;
    var value: ?*ffi.GVariant = undefined;
    ffi.g_variant_get(icon, "(&sv)", &kind, &value);
    const owned: ?*ffi.GVariant = value;
    defer if (owned != null) ffi.g_variant_unref(@ptrCast(owned));
    if ((@as(ffi.gsize, @bitCast(@as(c_long, @intFromBool(ffi.strcmp(kind, "themed") == 0 and (ffi.g_variant_is_of_type(value, ffi.g_variant_type_checked_("as")) != 0))))) != 0) and (ffi.g_variant_n_children(value) != 0)) {
        var name: [*c]const u8 = undefined;
        ffi.g_variant_get_child(value, 0, "&s", &name);
        return @ptrCast(@alignCast(if (!(ffi.cast([*c]const u8, ffi.strchr(name, '/')) != null)) ffi.cast(?*anyopaque, ffi.g_strdup(name)) else null));
    }
    if (ffi.strcmp(kind, "bytes") == 0 and (ffi.g_variant_is_of_type(value, ffi.cast(?*const ffi.GVariantType, "ay")) != 0)) {
        var size: ffi.gsize = undefined;
        const bytes: [*c]const ffi.guint8 = @ptrCast(@alignCast(ffi.g_variant_get_fixed_array(value, &size, 1)));
        if (size == 0 or (size > @as(ffi.gsize, @bitCast(@as(c_long, (@as(c_int, 4) * @as(c_int, 1024)) * @as(c_int, 1024)))))) return null;
        const descriptor: c_int = ffi.memfd_create("pearl-notification-icon", @as(c_uint, 1) | @as(c_uint, 2));
        if (descriptor < 0) return null;
        if ((ffi.write(descriptor, @ptrCast(@alignCast(bytes)), size) != @as(isize, @bitCast(@as(c_ulong, @truncate(size))))) or (ffi.fcntl(descriptor, 1033, ((@as(c_int, 8) | @as(c_int, 4)) | @as(c_int, 2)) | 1) < 0)) {
            _ = ffi.close(descriptor);
            return null;
        }
        fd.* = descriptor;
        return ffi.g_strdup_printf("/proc/%u/fd/%d", @as(ffi.guint, @bitCast(@as(c_int, ffi.getpid()))), descriptor);
    }
    if (ffi.strcmp(kind, "file") == 0 and (ffi.g_variant_is_of_type(value, ffi.cast(?*const ffi.GVariantType, "s")) != 0)) {
        const path: [*c]u8 = ffi.g_filename_from_uri(ffi.g_variant_get_string(value, null), null, null);
        defer if (path != null) ffi.g_free(@ptrCast(path));
        if (path == null) return null;
        const descriptor: c_int = ffi.open(path, ((0 | @as(c_int, 524288)) | @as(c_int, 131072)) | @as(c_int, 2048));
        var st: ffi.struct_stat = undefined;
        if (descriptor < 0) return null;
        if ((((ffi.fstat(descriptor, &st) != 0) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) or (st.st_size <= @as(ffi.__off_t, 0))) or (st.st_size > @as(ffi.__off_t, (@as(c_int, 4) * @as(c_int, 1024)) * @as(c_int, 1024)))) {
            _ = ffi.close(descriptor);
            return null;
        }
        fd.* = descriptor;
        return ffi.g_strdup_printf("/proc/%u/fd/%d", @as(ffi.guint, @bitCast(@as(c_int, ffi.getpid()))), descriptor);
    }
    if (ffi.strcmp(kind, "file-descriptor") == 0 and (ffi.g_variant_is_of_type(value, ffi.cast(?*const ffi.GVariantType, "h")) != 0)) {
        const fds: [*c]ffi.GUnixFDList = ffi.g_dbus_message_get_unix_fd_list(ffi.g_dbus_method_invocation_get_message(call));
        if (fds == null) return null;
        const descriptor: c_int = ffi.g_unix_fd_list_get(fds, ffi.g_variant_get_handle(value), null);
        if (descriptor < 0) return null;
        var st: ffi.struct_stat = undefined;
        const seals: c_int = ffi.fcntl(descriptor, 1034);
        if ((((((ffi.fstat(descriptor, &st) != 0) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) or (st.st_size <= @as(ffi.__off_t, 0))) or (st.st_size > @as(ffi.__off_t, (@as(c_int, 4) * @as(c_int, 1024)) * @as(c_int, 1024)))) or (seals < 0)) or !((seals & @as(c_int, 8)) != 0)) {
            _ = ffi.close(descriptor);
            return null;
        }
        fd.* = descriptor;
        return ffi.g_strdup_printf("/proc/%u/fd/%d", @as(ffi.guint, @bitCast(@as(c_int, ffi.getpid()))), descriptor);
    }
    return null;
}

pub fn signal_received(bus: ?*ffi.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, member: [*c]const u8, params: ?*ffi.GVariant, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    if (ffi.g_strcmp0(sender, p.*.notification_owner) != 0) return;
    if (((ffi.strcmp(member, "NotificationClosed") == 0 and ffi.g_variant_is_of_type(params, ffi.g_variant_type_checked_("(uu)")) == 0) or ((ffi.strcmp(member, "ActionInvoked") == 0 or ffi.strcmp(member, "ActivationToken") == 0) and ffi.g_variant_is_of_type(params, ffi.g_variant_type_checked_("(us)")) == 0)) or (((ffi.strcmp(member, "NotificationClosed") != 0) and (ffi.strcmp(member, "ActionInvoked") != 0)) and (ffi.strcmp(member, "ActivationToken") != 0))) return;
    var id: ffi.guint = undefined;
    ffi.g_variant_get_child(params, 0, "u", &id);
    var iter: ffi.GHashTableIter = undefined;
    var value: ffi.gpointer = undefined;
    ffi.g_hash_table_iter_init(&iter, p.*.notifications);
    while (ffi.g_hash_table_iter_next(&iter, null, &value) != 0) {
        const n: [*c]Notice = @ptrCast(@alignCast(value));
        if (n.*.native_id != id) continue;
        if (ffi.strcmp(member, "NotificationClosed") == 0) {
            ffi.g_hash_table_iter_remove(&iter);
            save_state(p);
            return;
        }
        var key: [*c]const u8 = undefined;
        ffi.g_variant_get_child(params, 1, "&s", &key);
        if (ffi.strcmp(member, "ActivationToken") == 0) {
            ffi.g_free(@ptrCast(@alignCast(n.*.token)));
            n.*.token = ffi.g_strdup(key);
            return;
        }
        if (ffi.strcmp(member, "ActionInvoked") != 0) return;
        const stored: ?*ffi.GVariant = @ptrCast(@alignCast(ffi.g_hash_table_lookup(n.*.actions, @ptrCast(@alignCast(key)))));
        if (stored == null) return;
        var name: [*c]const u8 = undefined;
        var arguments: ?*ffi.GVariant = undefined;
        ffi.g_variant_get(stored, "(&s@av)", &name, &arguments);
        const args: ?*ffi.GVariant = arguments;
        defer if (args != null) ffi.g_variant_unref(@ptrCast(args));
        var platform: ffi.GVariantBuilder = undefined;
        ffi.g_variant_builder_init(&platform, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
        if (n.*.token != null) {
            ffi.g_variant_builder_add(&platform, "{sv}", @constCast("activation-token"), ffi.g_variant_new_string(n.*.token));
        }
        if (!(@as(c_int, name.*) != 0)) {
            const desktop: [*c]u8 = ffi.g_strconcat(n.*.app, @constCast(".desktop"), @as(?*anyopaque, null));
            defer if (desktop != null) ffi.g_free(@ptrCast(desktop));
            const app: ?*ffi.GDesktopAppInfo = ffi.g_desktop_app_info_new(desktop);
            defer if (app != null) ffi.g_object_unref(@ptrCast(app));
            const context: [*c]ffi.GAppLaunchContext = ffi.g_app_launch_context_new();
            defer if (context != null) ffi.g_object_unref(@ptrCast(context));
            if (n.*.token != null) {
                ffi.g_app_launch_context_setenv(context, "XDG_ACTIVATION_TOKEN", n.*.token);
            }
            if (app != null) {
                _ = ffi.g_app_info_launch(ffi.cast(?*ffi.GAppInfo, app), null, context, null);
            }
            ffi.g_variant_builder_clear(&platform);
        } else if (((ffi.g_str_has_prefix(name, "app.")) != 0) and (ffi.g_dbus_is_name(n.*.app) != 0)) {
            const object_path: [*c]u8 = ffi.g_strdup_printf("/%s", n.*.app);
            defer if (object_path != null) ffi.g_free(@ptrCast(object_path));
            {
                var c: [*c]u8 = object_path;
                while (@as(c_int, c.*) != 0) : (c += 1) {
                    if (@as(c_int, c.*) == @as(c_int, '.')) {
                        c.* = '/';
                    } else if (@as(c_int, c.*) == @as(c_int, '-')) {
                        c.* = '_';
                    }
                }
            }
            if (ffi.g_variant_is_object_path(object_path) != 0) {
                ffi.g_dbus_connection_call(bus, n.*.app, object_path, "org.freedesktop.Application", "ActivateAction", ffi.g_variant_new("(s@av@a{sv})", name + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, 4))))), ffi.g_variant_ref(args), ffi.g_variant_builder_end(&platform)), null, ffi.G_DBUS_CALL_FLAGS_NONE, 5000, null, null, null);
            } else {
                ffi.g_variant_builder_clear(&platform);
            }
        } else {
            var parameters: ffi.GVariantBuilder = undefined;
            ffi.g_variant_builder_init(&parameters, ffi.g_variant_type_checked_("av"));
            {
                var i: ffi.guint = 0;
                while (@as(ffi.gsize, i) < ffi.g_variant_n_children(args)) : (i +%= 1) {
                    const item: ?*ffi.GVariant = ffi.g_variant_get_child_value(args, i);
                    defer if (item != null) ffi.g_variant_unref(@ptrCast(item));
                    ffi.g_variant_builder_add_value(&parameters, item);
                }
            }
            ffi.g_variant_builder_add(&parameters, "v", ffi.g_variant_builder_end(&platform));
            _ = ffi.g_dbus_connection_emit_signal(bus, p.*.owner, "/org/freedesktop/portal/desktop", "org.freedesktop.impl.portal.Notification", "ActionInvoked", ffi.g_variant_new("(sss@av)", n.*.app, n.*.id, name, ffi.g_variant_builder_end(&parameters)), null);
        }
        ffi.clear(&n.*.token, ffi.g_free);
        return;
    }
}

pub fn owner_ready(_: ?*ffi.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    ffi.g_hash_table_remove_all(p.*.notifications);
    ffi.g_free(@ptrCast(@alignCast(p.*.notification_owner)));
    p.*.notification_owner = ffi.g_strdup(owner);
    load_state(p);
    save_state(p);
}

pub fn owner_gone(_: ?*ffi.GDBusConnection, _: [*c]const u8, data: ffi.gpointer) callconv(.c) void {
    const p: [*c]Portal = @ptrCast(@alignCast(data));
    ffi.clear(&p.*.notification_owner, ffi.g_free);
    ffi.g_hash_table_remove_all(p.*.notifications);
    save_state(p);
}

pub fn portal_notifications_init(p: [*c]Portal) callconv(.c) void {
    p.*.notifications = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, ffi.g_free, notice_free);
    p.*.notification_busy = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, ffi.g_free, null);
    p.*.notification_watch = ffi.g_bus_watch_name_on_connection(p.*.bus, "org.freedesktop.Notifications", ffi.G_BUS_NAME_WATCHER_FLAGS_NONE, owner_ready, owner_gone, @ptrCast(@alignCast(p)), null);
    p.*.notification_signal = ffi.g_dbus_connection_signal_subscribe(p.*.bus, null, "org.freedesktop.Notifications", null, "/org/freedesktop/Notifications", null, ffi.G_DBUS_SIGNAL_FLAGS_NONE, signal_received, @ptrCast(@alignCast(p)), null);
}

pub fn portal_notifications_stop(p: [*c]Portal) callconv(.c) void {
    ffi.g_bus_unwatch_name(p.*.notification_watch);
    ffi.g_dbus_connection_signal_unsubscribe(p.*.bus, p.*.notification_signal);
    ffi.clear(&p.*.notification_owner, ffi.g_free);
    ffi.g_hash_table_unref(p.*.notifications);
    ffi.g_hash_table_unref(p.*.notification_busy);
}

pub fn portal_notification(p: [*c]Portal, member: [*c]const u8, params: ?*ffi.GVariant, invocation: ?*ffi.GDBusMethodInvocation) void {
    var app: [*c]const u8 = undefined;
    var id: [*c]const u8 = undefined;
    ffi.g_variant_get_child(params, 0, "&s", &app);
    ffi.g_variant_get_child(params, 1, "&s", &id);
    if (ffi.strlen(app) > 255 or ffi.strlen(id) > 1024 or ffi.strchr(app, '\n') != null or ffi.strchr(id, '\n') != null) {
        portal_error(invocation, "InvalidArgument", "Invalid notification identity");
        return;
    }
    const key = ffi.g_strdup_printf("%s\n%s", app, id);
    defer ffi.g_free(key);
    if (p.*.notification_owner == null) {
        portal_error(invocation, "Failed", "Pearl notification service is unavailable");
        return;
    }
    if (ffi.g_hash_table_contains(p.*.notification_busy, key) != 0) {
        portal_error(invocation, "Failed", "A notification update is already pending");
        return;
    }
    const old: [*c]Notice = @ptrCast(@alignCast(ffi.g_hash_table_lookup(p.*.notifications, key)));
    const remove = ffi.strcmp(member, "RemoveNotification") == 0;
    if (remove and old == null) {
        ffi.g_dbus_method_invocation_return_value(invocation, null);
        return;
    }
    if (!remove and old == null and ffi.g_hash_table_size(p.*.notifications) + ffi.g_hash_table_size(p.*.notification_busy) >= 256) {
        portal_error(invocation, "Failed", "Notification capacity reached");
        return;
    }
    const job: [*c]NoticeJob = @ptrCast(@alignCast(ffi.g_malloc0(@sizeOf(NoticeJob))));
    job.* = .{ .portal = p, .call = @ptrCast(ffi.g_object_ref(invocation)), .key = ffi.g_strdup(key), .owner = ffi.g_strdup(p.*.notification_owner), .icon_fd = -1, .remove = @intFromBool(remove) };
    _ = ffi.g_hash_table_add(p.*.notification_busy, ffi.g_strdup(key));
    if (remove) {
        ffi.g_dbus_connection_call(p.*.bus, job.*.owner, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "CloseNotification", ffi.g_variant_new("(u)", old.*.native_id), null, ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, null, sent, job);
        return;
    }
    const values = ffi.g_variant_get_child_value(params, 2);
    defer ffi.g_variant_unref(values);
    if (ffi.g_variant_get_size(values) > 1024 * 1024) {
        portal_error(invocation, "InvalidArgument", "Notification exceeds resource limits");
        job_free(job);
        return;
    }
    const n: [*c]Notice = @ptrCast(@alignCast(ffi.g_malloc0(@sizeOf(Notice))));
    job.*.notice = n;
    n.* = .{ .app = ffi.g_strdup(app), .id = ffi.g_strdup(id), .owner = ffi.g_strdup(p.*.notification_owner), .actions = ffi.g_hash_table_new_full(ffi.g_str_hash, ffi.g_str_equal, ffi.g_free, @ptrCast(&ffi.g_variant_unref)) };
    const icon = icon_name(invocation, values, &job.*.icon_fd);
    defer ffi.g_free(icon);
    if (icon == null) {
        portal_error(invocation, "InvalidArgument", "Invalid notification icon");
        job_free(job);
        return;
    }
    var actions: ffi.GVariantBuilder = undefined;
    var hints: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&actions, ffi.g_variant_type_checked_("as"));
    ffi.g_variant_builder_init(&hints, ffi.g_variant_type_checked_("a{sv}"));
    var dispatched = false;
    defer if (!dispatched) {
        ffi.g_variant_builder_clear(&actions);
        ffi.g_variant_builder_clear(&hints);
        portal_error(invocation, "InvalidArgument", "Invalid notification actions");
        job_free(job);
    };
    const default_target = ffi.g_variant_lookup_value(values, "default-action-target", null);
    defer if (default_target != null) ffi.g_variant_unref(default_target);
    const display = portal_app_name(app);
    defer ffi.g_free(display);
    const buttons = portal_option(values, "buttons", "aa{sv}");
    defer if (buttons != null) ffi.g_variant_unref(buttons);
    if (action(n, &actions, "default", "Open", portal_string(values, "default-action", ""), default_target) == 0) return;
    if (buttons != null) {
        if (ffi.g_variant_n_children(buttons) > 7) return;
        var i: c_uint = 0;
        while (i < ffi.g_variant_n_children(buttons)) : (i += 1) {
            const button = ffi.g_variant_get_child_value(buttons, i);
            defer ffi.g_variant_unref(button);
            const target = ffi.g_variant_lookup_value(button, "target", null);
            defer if (target != null) ffi.g_variant_unref(target);
            const caption = portal_string(button, "label", "");
            if (caption[0] == 0) continue;
            const action_key = ffi.g_strdup_printf("button-%u", i);
            defer ffi.g_free(action_key);
            if (action(n, &actions, action_key, caption, portal_string(button, "action", ""), target) == 0) return;
        }
    }
    const priority = portal_string(values, "priority", "normal");
    const urgency: u8 = if (ffi.strcmp(priority, "low") == 0) 0 else if (ffi.strcmp(priority, "urgent") == 0) 2 else 1;
    ffi.g_variant_builder_add(&hints, "{sv}", @as([*:0]const u8, "desktop-entry"), ffi.g_variant_new_string(app));
    ffi.g_variant_builder_add(&hints, "{sv}", @as([*:0]const u8, "urgency"), ffi.g_variant_new_byte(urgency));
    const category = portal_string(values, "category", "");
    if (category[0] != 0) ffi.g_variant_builder_add(&hints, "{sv}", @as([*:0]const u8, "category"), ffi.g_variant_new_string(category));
    ffi.g_dbus_connection_call(p.*.bus, job.*.owner, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", ffi.g_variant_new("(susss@as@a{sv}i)", display, @as(c_uint, if (old != null) old.*.native_id else 0), icon, portal_string(values, "title", ""), portal_string(values, "body", ""), ffi.g_variant_builder_end(&actions), ffi.g_variant_builder_end(&hints), @as(c_int, -1)), ffi.g_variant_type_checked_("(u)"), ffi.G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, null, sent, job);
    dispatched = true;
}
