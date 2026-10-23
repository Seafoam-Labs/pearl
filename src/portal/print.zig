const chooser = @import("file_chooser");
const ffi = @import("ffi.zig");
const identity = @import("identity.zig");
const Portal = @import("types.zig").Portal;
const Request = @import("types.zig").Request;
const capabilities = @import("print_worker.zig").capabilities;
const portal_boolean = @import("backend.zig").portal_boolean;
const portal_complete = @import("backend.zig").portal_complete;
const portal_dialog = @import("backend.zig").portal_dialog;
const portal_empty = @import("backend.zig").portal_empty;
const portal_label = @import("backend.zig").portal_label;
const portal_option = @import("backend.zig").portal_option;
const portal_present = @import("backend.zig").portal_present;
const portal_request_ref = @import("backend.zig").portal_request_ref;
const portal_request_unref = @import("backend.zig").portal_request_unref;
const portal_restricted = @import("settings.zig").portal_restricted;
const portal_string = @import("backend.zig").portal_string;

pub const PrintToken = extern struct {
    sender: [*c]u8 = null,
    app: [*c]u8 = null,
    printer: [*c]u8 = null,
    uri: [*c]u8 = null,
    etag: [*c]u8 = null,
    expires: ffi.gint64 = 0,
    settings: ?*ffi.GVariant = null,
    page: ?*ffi.GVariant = null,
};

pub const PrintData = extern struct {
    printers: [*c]ffi.GtkWidget = null,
    copies: [*c]ffi.GtkWidget = null,
    duplex: [*c]ffi.GtkWidget = null,
    color: [*c]ffi.GtkWidget = null,
    ranges: [*c]ffi.GtkWidget = null,
    orientation: [*c]ffi.GtkWidget = null,
    paper: [*c]ffi.GtkWidget = null,
    status: [*c]ffi.GtkWidget = null,
    ids: [*c]ffi.GPtrArray = null,
    page_modes: [*c]ffi.GPtrArray = null,
    page_mode: [*c]ffi.GtkWidget = null,
    output_format: [*c]u8 = null,
    initial: ?*ffi.GVariant = null,
    page: ?*ffi.GVariant = null,
    capabilities: ?*ffi.GVariant = null,
    worker: ?*ffi.GSubprocess = null,
    timeout: ffi.guint = 0,
    fd: c_int = 0,
    token: [*c]PrintToken = null,
}; // /tmp/pearl-zig-migration/print.pre.c:58894:12: warning: TODO goto
// /tmp/pearl-zig-migration/print.pre.c:58887:14: warning: unable to translate function, demoted to extern

pub fn token_free(data: ffi.gpointer) callconv(.c) void {
    const t: [*c]PrintToken = @ptrCast(@alignCast(data));
    ffi.g_free(@ptrCast(@alignCast(t.*.sender)));
    ffi.g_free(@ptrCast(@alignCast(t.*.app)));
    ffi.g_free(@ptrCast(@alignCast(t.*.printer)));
    ffi.g_free(@ptrCast(@alignCast(t.*.uri)));
    ffi.g_free(@ptrCast(@alignCast(t.*.etag)));
    ffi.clear(&t.*.settings, ffi.g_variant_unref);
    ffi.clear(&t.*.page, ffi.g_variant_unref);
    ffi.g_free(@ptrCast(@alignCast(t)));
}

pub fn data_free(data: ffi.gpointer) callconv(.c) void {
    const d: [*c]PrintData = @ptrCast(@alignCast(data));
    if (d.*.timeout != 0) {
        _ = ffi.g_source_remove(d.*.timeout);
    }
    if (d.*.worker != null) {
        ffi.g_subprocess_force_exit(d.*.worker);
        ffi.g_object_unref(@ptrCast(@alignCast(d.*.worker)));
    }
    if (d.*.fd >= 0) {
        _ = ffi.close(d.*.fd);
    }
    ffi.clear(&d.*.ids, ffi.g_ptr_array_unref);
    ffi.clear(&d.*.page_modes, ffi.g_ptr_array_unref);
    ffi.g_free(@ptrCast(@alignCast(d.*.output_format)));
    ffi.clear(&d.*.initial, ffi.g_variant_unref);
    ffi.clear(&d.*.page, ffi.g_variant_unref);
    ffi.clear(&d.*.capabilities, ffi.g_variant_unref);
    if (d.*.token != null) {
        token_free(@ptrCast(@alignCast(d.*.token)));
    }
    ffi.g_free(@ptrCast(@alignCast(d)));
}

pub fn expired(data: ffi.gpointer) callconv(.c) ffi.gboolean {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    d.*.timeout = 0;
    if (d.*.worker != null) {
        ffi.g_subprocess_force_exit(d.*.worker);
    }
    portal_complete(r, 2, null);
    return 0;
}

pub fn stopped(_: [*c]ffi.GCancellable, data: ffi.gpointer) callconv(.c) void {
    const d: [*c]PrintData = @ptrCast(@alignCast(data));
    if (d.*.worker != null) {
        ffi.g_subprocess_force_exit(d.*.worker);
    }
}

pub fn worker(r: [*c]Request, args: [*c]const [*c]const u8, pass_fd: ffi.gboolean) callconv(.c) ?*ffi.GSubprocess {
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    const launcher: ?*ffi.GSubprocessLauncher = ffi.g_subprocess_launcher_new(@bitCast(ffi.G_SUBPROCESS_FLAGS_STDOUT_PIPE | ffi.G_SUBPROCESS_FLAGS_STDERR_SILENCE));
    defer if (launcher != null) ffi.g_object_unref(@ptrCast(launcher));
    if (pass_fd != 0) {
        const fd: c_int = ffi.dup(d.*.fd);
        if (fd < 0) return null;
        ffi.g_subprocess_launcher_take_fd(launcher, fd, 3);
    }
    if (d.*.timeout != 0) {
        _ = ffi.g_source_remove(d.*.timeout);
        d.*.timeout = 0;
    }
    if (d.*.worker != null) {
        ffi.g_subprocess_force_exit(d.*.worker);
    }
    ffi.clear(&d.*.worker, ffi.g_object_unref);
    d.*.worker = ffi.g_subprocess_launcher_spawnv(launcher, args, null);
    if (d.*.worker != null) {
        d.*.timeout = ffi.g_timeout_add_seconds(65, expired, @ptrCast(@alignCast(r)));
    }
    return d.*.worker;
}

pub fn printed(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const ok: ffi.gboolean = ffi.g_subprocess_wait_check_finish(ffi.cast(?*ffi.GSubprocess, source), result, null);
    if (r.*.finished == 0) {
        portal_complete(r, @bitCast(@as(c_int, if (ok != 0) 0 else @as(c_int, 2))), null);
    }
    portal_request_unref(r);
}

pub fn submit(r: [*c]Request) callconv(.c) void {
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    const t: [*c]PrintToken = d.*.token;
    if ((portal_restricted(r.*.portal, "disable-printing") != 0) or ((t.*.uri != null) and (portal_restricted(r.*.portal, "disable-save-to-disk") != 0))) {
        portal_complete(r, 2, null);
        return;
    }
    var b: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&b, ffi.g_variant_type_checked_("a{ss}"));
    const keys: [6][*c]const u8 = [6][*c]const u8{
        "n-copies",
        "duplex",
        "use-color",
        "page-ranges",
        "orientation",
        "paper-format",
    };
    const cups: [6][*c]const u8 = [6][*c]const u8{
        "copies",
        "sides",
        "print-color-mode",
        "page-ranges",
        "orientation-requested",
        "media",
    };
    {
        var i: ffi.guint = 0;
        while (@as(c_ulong, i) < (@sizeOf(@TypeOf(keys)) / @sizeOf(@TypeOf(keys[0])))) : (i +%= 1) {
            var v: [*c]const u8 = portal_string(t.*.settings, keys[i], "");
            if (!(@as(c_int, v.*) != 0)) continue;
            if (i == @as(ffi.guint, 1)) {
                v = if (ffi.strcmp(v, "simplex") == 0) @constCast("one-sided") else if (ffi.strcmp(v, "horizontal") == 0) @constCast("two-sided-short-edge") else @constCast("two-sided-long-edge");
            }
            if (i == @as(ffi.guint, 2)) {
                v = if (ffi.strcmp(v, "true") == 0) @constCast("color") else @constCast("monochrome");
            }
            if (i == @as(ffi.guint, 4)) {
                v = if (ffi.strcmp(v, "landscape") == 0) @constCast("4") else @constCast("3");
            }
            if (i == @as(ffi.guint, 3)) {
                const ranges: [*c]u8 = shift_ranges(v, 1);
                defer if (ranges != null) ffi.g_free(@ptrCast(ranges));
                if (ranges == null) {
                    ffi.g_variant_builder_clear(&b);
                    portal_complete(r, 2, null);
                    return;
                }
                ffi.g_variant_builder_add(&b, "{ss}", cups[i], ranges);
            } else {
                ffi.g_variant_builder_add(&b, "{ss}", cups[i], v);
            }
        }
    }
    const values: ?*ffi.GVariant = ffi.g_variant_ref_sink(ffi.g_variant_builder_end(&b));
    defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
    const options: [*c]u8 = ffi.g_variant_print(values, 1);
    defer if (options != null) ffi.g_free(@ptrCast(options));
    var args_file: [7][*c]const u8 = [7][*c]const u8{
        "/proc/self/exe",
        "--print-worker",
        "file",
        t.*.uri,
        t.*.etag,
        portal_string(t.*.settings, "output-file-format", "pdf"),
        null,
    };
    var args_cups: [8][*c]const u8 = [8][*c]const u8{
        "/proc/self/exe",
        "--print-worker",
        "submit",
        t.*.printer,
        portal_string(t.*.settings, "job-name", "Document"),
        options,
        "1",
        null,
    };
    if (!(worker(r, if (t.*.uri != null) ffi.cast([*c][*c]const u8, &args_file) else ffi.cast([*c][*c]const u8, &args_cups), 1) != null)) {
        portal_complete(r, 2, null);
        return;
    }
    if (r.*.dialog != null) {
        ffi.gtk_widget_set_sensitive(ffi.cast([*c]ffi.GtkWidget, r.*.dialog), 0);
    }
    ffi.g_subprocess_wait_check_async(d.*.worker, r.*.cancel, printed, @ptrCast(@alignCast(portal_request_ref(r))));
}

pub fn ready(r: [*c]Request) callconv(.c) void {
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    const t: [*c]PrintToken = d.*.token;
    if (ffi.strcmp(r.*.method, "Print") == 0) {
        submit(r);
        return;
    }
    if (ffi.g_hash_table_size(r.*.portal.*.print_tokens) >= @as(ffi.guint, 128)) {
        portal_complete(r, 2, null);
        return;
    }
    var token: ffi.guint = undefined;
    while (true) {
        token = ffi.g_random_int();
        if (!(token == 0 or (ffi.g_hash_table_contains(r.*.portal.*.print_tokens, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, token)))) != 0))) break;
    }
    t.*.expires = ffi.g_get_monotonic_time() + @as(ffi.gint64, (@as(c_int, 5) * @as(c_int, 60)) * @as(c_int, 1000000));
    _ = ffi.g_hash_table_insert(r.*.portal.*.print_tokens, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, token))), @ptrCast(@alignCast(t)));
    d.*.token = null;
    var result: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&result, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("token"), ffi.g_variant_new_uint32(token));
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("settings"), t.*.settings);
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("page-setup"), t.*.page);
    portal_complete(r, 0, ffi.g_variant_builder_end(&result));
}

pub fn destination_chosen(dialog: [*c]ffi.GtkDialog, response_1: c_int, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    if (response_1 != ffi.GTK_RESPONSE_ACCEPT) {
        portal_complete(r, 1, null);
        return;
    }
    const file: ?*ffi.GFile = chooser.getFile(dialog);
    defer if (file != null) ffi.g_object_unref(@ptrCast(file));
    if (file == null) {
        portal_complete(r, 2, null);
        return;
    }
    d.*.token.*.uri = ffi.g_file_get_uri(file);
    var settings: ffi.GVariantDict = undefined;
    ffi.g_variant_dict_init(&settings, d.*.token.*.settings);
    ffi.g_variant_dict_insert(&settings, "output-uri", "s", d.*.token.*.uri);
    ffi.g_variant_dict_insert(&settings, "output-file-format", "s", d.*.output_format);
    ffi.g_variant_dict_insert(&settings, "printer", "s", @constCast("Print to File"));
    ffi.g_variant_unref(d.*.token.*.settings);
    d.*.token.*.settings = ffi.g_variant_ref_sink(ffi.g_variant_dict_end(&settings));
    var @"error": [*c]ffi.GError = null;
    defer if (@"error" != null) ffi.g_error_free(@ptrCast(@"error"));
    const info: ?*ffi.GFileInfo = ffi.g_file_query_info(file, "etag::value", ffi.G_FILE_QUERY_INFO_NONE, null, &@"error");
    defer if (info != null) ffi.g_object_unref(@ptrCast(info));
    const etag: [*c]const u8 = @ptrCast(@alignCast(if (info != null) ffi.cast(?*const anyopaque, ffi.g_file_info_get_etag(info)) else ffi.cast(?*const anyopaque, null)));
    if (etag == null and ffi.g_error_matches(@"error", ffi.g_io_error_quark(), ffi.G_IO_ERROR_NOT_FOUND) == 0) {
        portal_complete(r, 2, null);
        return;
    }
    d.*.token.*.etag = if (etag != null) ffi.g_strconcat("etag:", etag, @as(?*anyopaque, null)) else ffi.g_strdup("new");
    ready(r);
}

pub fn response(_: [*c]ffi.GtkDialog, response_id: c_int, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    if (response_id != ffi.GTK_RESPONSE_ACCEPT) {
        portal_complete(r, 1, null);
        return;
    }
    const index_1: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.printers))));
    if (index_1 >= d.*.ids.*.f_len) return;
    const mode: [*c]const u8 = @ptrCast(@alignCast(ffi.items(d.*.page_modes)[ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.page_mode))))]));
    const range: [*c]const u8 = if (ffi.strcmp(mode, "ranges") == 0) ffi.gtk_editable_get_text(ffi.cast(?*ffi.GtkEditable, d.*.ranges)) else ffi.cast([*c]const u8, "");
    const zero_ranges: [*c]u8 = shift_ranges(range, -1);
    defer if (zero_ranges != null) ffi.g_free(@ptrCast(zero_ranges));
    if (zero_ranges == null) {
        ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), @import("i18n").dtr("pearl", "Use ascending page ranges, such as 1-3,5."));
        return;
    }
    const t: [*c]PrintToken = ffi.cast([*c]PrintToken, ffi.g_malloc0_n(1, @sizeOf(PrintToken)));
    d.*.token = t;
    t.*.sender = ffi.g_strdup(r.*.sender);
    t.*.app = ffi.g_strdup(r.*.app_id);
    t.*.printer = ffi.g_strdup(@ptrCast(@alignCast(ffi.items(d.*.ids)[index_1])));
    var settings: ffi.GVariantDict = undefined;
    ffi.g_variant_dict_init(&settings, d.*.initial);
    var copies: [16]u8 = undefined;
    _ = ffi.g_snprintf(@ptrCast(@alignCast(&copies)), @sizeOf(@TypeOf(copies)), "%d", ffi.gtk_spin_button_get_value_as_int(ffi.cast(?*ffi.GtkSpinButton, d.*.copies)));
    const duplex: [3][*c]const u8 = [3][*c]const u8{
        "simplex",
        "vertical",
        "horizontal",
    };
    const papers: [3][*c]const u8 = [3][*c]const u8{
        "iso_a4",
        "na_letter",
        "na_legal",
    };
    const selected_paper: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.paper))));
    var paper_name: [*c]const u8 = if (selected_paper < @as(ffi.guint, 3)) papers[selected_paper] else papers[0];
    var width: f64 = @floatFromInt(@as(c_int, 210));
    var height: f64 = @floatFromInt(@as(c_int, 297));
    var margin_top: f64 = 12.7;
    var margin_bottom: f64 = 12.7;
    var margin_left: f64 = 12.7;
    var margin_right: f64 = 12.7;
    const media: ?*ffi.GVariant = @ptrCast(@alignCast(if (d.*.capabilities != null) ffi.cast(?*anyopaque, portal_option(d.*.capabilities, "papers", "a(sdddddd)")) else null));
    defer if (media != null) ffi.g_variant_unref(@ptrCast(media));
    if ((media != null) and (@as(ffi.gsize, selected_paper) < ffi.g_variant_n_children(media))) {
        ffi.g_variant_get_child(media, selected_paper, "(&sdddddd)", &paper_name, &width, &height, &margin_top, &margin_bottom, &margin_left, &margin_right);
    } else {
        const widths: [3]f64 = [3]f64{
            @floatFromInt(@as(c_int, 210)),
            215.9,
            215.9,
        };
        const heights: [3]f64 = [3]f64{
            @floatFromInt(@as(c_int, 297)),
            279.4,
            355.6,
        };
        if (selected_paper < @as(ffi.guint, 3)) {
            width = widths[selected_paper];
            height = heights[selected_paper];
        }
    }
    ffi.g_variant_dict_insert(&settings, "n-copies", "s", ffi.cast([*c]u8, &copies));
    ffi.g_variant_dict_insert(&settings, "duplex", "s", duplex[ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.duplex))))]);
    ffi.g_variant_dict_insert(&settings, "use-color", "s", if (ffi.gtk_check_button_get_active(ffi.cast([*c]ffi.GtkCheckButton, d.*.color)) != 0) @as([*:0]const u8, "true") else @as([*:0]const u8, "false"));
    ffi.g_variant_dict_insert(&settings, "page-ranges", "s", zero_ranges);
    ffi.g_variant_dict_insert(&settings, "print-pages", "s", mode);
    ffi.g_variant_dict_insert(&settings, "orientation", "s", if (ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.orientation)))) != 0) @as([*:0]const u8, "landscape") else @as([*:0]const u8, "portrait"));
    ffi.g_variant_dict_insert(&settings, "paper-format", "s", paper_name);
    ffi.g_variant_dict_insert(&settings, "printer", "s", t.*.printer);
    t.*.settings = ffi.g_variant_ref_sink(ffi.g_variant_dict_end(&settings));
    var page: ffi.GVariantDict = undefined;
    ffi.g_variant_dict_init(&page, d.*.page);
    ffi.g_variant_dict_insert(&page, "Name", "s", paper_name);
    ffi.g_variant_dict_insert(&page, "DisplayName", "s", paper_name);
    ffi.g_variant_dict_insert(&page, "Width", "d", width);
    ffi.g_variant_dict_insert(&page, "Height", "d", height);
    ffi.g_variant_dict_insert(&page, "Orientation", "s", if (ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.orientation)))) != 0) @as([*:0]const u8, "landscape") else @as([*:0]const u8, "portrait"));
    ffi.g_variant_dict_insert(&page, "MarginTop", "d", margin_top);
    ffi.g_variant_dict_insert(&page, "MarginBottom", "d", margin_bottom);
    ffi.g_variant_dict_insert(&page, "MarginLeft", "d", margin_left);
    ffi.g_variant_dict_insert(&page, "MarginRight", "d", margin_right);
    t.*.page = ffi.g_variant_ref_sink(ffi.g_variant_dict_end(&page));
    if (!(@as(c_int, t.*.printer.*) != 0)) {
        if (portal_restricted(r.*.portal, "disable-save-to-disk") != 0) {
            portal_complete(r, 2, null);
            return;
        }
        _ = ffi.g_signal_handlers_disconnect_matched(@ptrCast(@alignCast(r.*.dialog)), ffi.G_SIGNAL_MATCH_DATA, 0, 0, null, null, @ptrCast(@alignCast(r)));
        ffi.gtk_window_destroy(ffi.cast([*c]ffi.GtkWindow, r.*.dialog));
        ffi.clear(&r.*.dialog, ffi.g_object_unref);
        r.*.dialog = chooser.create("Save printed document", .save);
        _ = ffi.g_object_ref_sink(@ptrCast(@alignCast(r.*.dialog)));
        chooser.setLocalOnly(r.*.dialog, 1);
        const output_name: [*c]u8 = ffi.g_strdup_printf("Document.%s", d.*.output_format);
        defer if (output_name != null) ffi.g_free(@ptrCast(output_name));
        chooser.setName(r.*.dialog, output_name);
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "response", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&destination_chosen)))), @ptrCast(@alignCast(r)), null, 0);
        portal_present(r);
    } else {
        ready(r);
    }
}

pub fn supports(caps: ?*ffi.GVariant, key: [*c]const u8, wanted: [*c]const u8) callconv(.c) ffi.gboolean {
    const values: ?*ffi.GVariant = portal_option(caps, key, "as");
    defer if (values != null) ffi.g_variant_unref(@ptrCast(values));
    if (values == null) return 0;
    var it: ffi.GVariantIter = undefined;
    var value: [*c]const u8 = undefined;
    _ = ffi.g_variant_iter_init(&it, values);
    while (ffi.g_variant_iter_next(&it, "&s", &value) != 0) if (ffi.strcmp(value, wanted) == 0) return 1;
    return 0;
}

pub fn capability_reply(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    var output: [*c]u8 = null;
    defer if (output != null) ffi.g_free(@ptrCast(output));
    const ok: ffi.gboolean = ffi.g_subprocess_communicate_utf8_finish(ffi.cast(?*ffi.GSubprocess, source), result, &output, null, null);
    if (r.*.finished == 0 and (ffi.cast(?*ffi.GSubprocess, source) == d.*.worker)) {
        if (d.*.timeout != 0) {
            _ = ffi.g_source_remove(d.*.timeout);
            d.*.timeout = 0;
        }
        ffi.clear(&d.*.capabilities, ffi.g_variant_unref);
        d.*.capabilities = @ptrCast(@alignCast(if (((ok != 0) and (output != null)) and (ffi.strlen(output) < @as(usize, 262144))) ffi.cast(?*anyopaque, ffi.g_variant_parse(@as(?*const ffi.GVariantType, @ptrCast(@alignCast(@constCast("a{sv}")))), output, null, null, null)) else null));
        const media: ?*ffi.GVariant = @ptrCast(@alignCast(if (d.*.capabilities != null) ffi.cast(?*anyopaque, portal_option(d.*.capabilities, "papers", "a(sdddddd)")) else null));
        defer if (media != null) ffi.g_variant_unref(@ptrCast(media));
        if (media == null or ffi.g_variant_n_children(media) == 0) {
            ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), @import("i18n").dtr("pearl", "Printer capabilities are unavailable. Choose another destination."));
        } else {
            const labels: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
            {
                var i: ffi.guint = 0;
                while (@as(ffi.gsize, i) < ffi.g_variant_n_children(media)) : (i +%= 1) {
                    var name: [*c]const u8 = undefined;
                    ffi.g_variant_get_child(media, i, "(&sdddddd)", &name, @as(?*anyopaque, null), @as(?*anyopaque, null), @as(?*anyopaque, null), @as(?*anyopaque, null), @as(?*anyopaque, null), @as(?*anyopaque, null));
                    ffi.gtk_string_list_append(labels, name);
                }
            }
            ffi.gtk_drop_down_set_model(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.paper))), ffi.G_LIST_MODEL(@ptrCast(@alignCast(labels))));
            ffi.g_object_unref(@ptrCast(@alignCast(labels)));
            ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.paper))), 0);
            var copies: ffi.guint = 1;
            _ = ffi.g_variant_lookup(d.*.capabilities, "copies", "u", &copies);
            ffi.gtk_spin_button_set_range(ffi.cast(?*ffi.GtkSpinButton, d.*.copies), @floatFromInt(1), @floatFromInt(if (@as(ffi.guint, @bitCast(@as(c_int, 1))) > copies) @as(ffi.guint, @bitCast(@as(c_int, 1))) else copies));
            const color: ffi.gboolean = supports(d.*.capabilities, "print-color-mode", "color");
            ffi.gtk_check_button_set_active(ffi.cast([*c]ffi.GtkCheckButton, d.*.color), color);
            ffi.gtk_widget_set_sensitive(d.*.color, color);
            const duplex: ffi.gboolean = @intFromBool((supports(d.*.capabilities, "sides", "two-sided-long-edge") != 0) and (supports(d.*.capabilities, "sides", "two-sided-short-edge") != 0));
            ffi.gtk_widget_set_sensitive(d.*.duplex, duplex);
            if (duplex == 0) {
                ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.duplex))), 0);
            }
            ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), "");
            ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 1);
        }
    }
    portal_request_unref(r);
}

pub fn printer_changed(_: [*c]ffi.GObject, _: [*c]ffi.GParamSpec, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    const selected: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.printers))));
    if (selected >= d.*.ids.*.f_len) return;
    const id: [*c]const u8 = @ptrCast(@alignCast(ffi.items(d.*.ids)[selected]));
    ffi.clear(&d.*.capabilities, ffi.g_variant_unref);
    if (d.*.timeout != 0) {
        _ = ffi.g_source_remove(d.*.timeout);
        d.*.timeout = 0;
    }
    if (d.*.worker != null) {
        ffi.g_subprocess_force_exit(d.*.worker);
        ffi.clear(&d.*.worker, ffi.g_object_unref);
    }
    if (!(@as(c_int, id.*) != 0)) {
        var papers: [4][*c]const u8 = [4][*c]const u8{
            "A4",
            "Letter",
            "Legal",
            null,
        };
        const model: ?*ffi.GtkStringList = ffi.gtk_string_list_new(@ptrCast(@alignCast(&papers)));
        ffi.gtk_drop_down_set_model(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.paper))), ffi.G_LIST_MODEL(@ptrCast(@alignCast(model))));
        ffi.g_object_unref(@ptrCast(@alignCast(model)));
        ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.paper))), 0);
        ffi.gtk_spin_button_set_range(ffi.cast(?*ffi.GtkSpinButton, d.*.copies), @floatFromInt(1), @floatFromInt(@as(c_int, 999)));
        ffi.gtk_widget_set_sensitive(d.*.color, 1);
        ffi.gtk_widget_set_sensitive(d.*.duplex, 1);
        ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), "");
        ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 1);
        return;
    }
    ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 0);
    ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), @import("i18n").dtr("pearl", "Reading printer capabilities\xe2\x80\xa6"));
    var args: [5][*c]const u8 = [5][*c]const u8{
        "/proc/self/exe",
        "--print-worker",
        "capabilities",
        id,
        null,
    };
    if (!(worker(r, @ptrCast(@alignCast(&args)), 0) != null)) {
        portal_complete(r, 2, null);
        return;
    }
    ffi.g_subprocess_communicate_utf8_async(d.*.worker, null, r.*.cancel, capability_reply, @ptrCast(@alignCast(portal_request_ref(r))));
}

pub fn enumerated(source: [*c]ffi.GObject, result: ?*ffi.GAsyncResult, data: ffi.gpointer) callconv(.c) void {
    const r: [*c]Request = @ptrCast(@alignCast(data));
    const d: [*c]PrintData = @ptrCast(@alignCast(r.*.data));
    var output: [*c]u8 = null;
    defer if (output != null) ffi.g_free(@ptrCast(output));
    const ok: ffi.gboolean = ffi.g_subprocess_communicate_utf8_finish(ffi.cast(?*ffi.GSubprocess, source), result, &output, null, null);
    if (r.*.finished == 0) {
        if (d.*.timeout != 0) {
            _ = ffi.g_source_remove(d.*.timeout);
            d.*.timeout = 0;
        }
        const labels: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
        if ((d.*.output_format != null) and !(portal_restricted(r.*.portal, "disable-save-to-disk") != 0)) {
            ffi.gtk_string_list_append(labels, @import("i18n").dtr("pearl", "Print to file\xe2\x80\xa6"));
            ffi.g_ptr_array_add(d.*.ids, @ptrCast(@alignCast(ffi.g_strdup(""))));
        }
        const printers: ?*ffi.GVariant = @ptrCast(@alignCast(if (((ok != 0) and (output != null)) and (ffi.strlen(output) < @as(usize, 65536))) ffi.cast(?*anyopaque, ffi.g_variant_parse(ffi.g_variant_type_checked_("a(ss)"), output, null, null, null)) else null));
        defer if (printers != null) ffi.g_variant_unref(@ptrCast(printers));
        if (printers != null) {
            var it: ffi.GVariantIter = undefined;
            var id: [*c]const u8 = undefined;
            var name: [*c]const u8 = undefined;
            _ = ffi.g_variant_iter_init(&it, printers);
            while ((d.*.ids.*.f_len < @as(ffi.guint, 128)) and (ffi.g_variant_iter_next(&it, "(&s&s)", &id, &name) != 0)) {
                ffi.g_ptr_array_add(d.*.ids, @ptrCast(@alignCast(ffi.g_strdup(id))));
                ffi.gtk_string_list_append(labels, name);
            }
        }
        ffi.gtk_drop_down_set_model(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.printers))), ffi.G_LIST_MODEL(@ptrCast(@alignCast(labels))));
        ffi.g_object_unref(@ptrCast(@alignCast(labels)));
        ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.printers))), 0);
        ffi.gtk_label_set_text(ffi.cast(?*ffi.GtkLabel, d.*.status), if (d.*.ids.*.f_len > @as(ffi.guint, 1)) @constCast("") else @constCast(@import("i18n").dtr("pearl", "No printers found. Check the printer connection and CUPS service.")));
        ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, @intFromBool(d.*.ids.*.f_len > @as(ffi.guint, 0)));
        _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(d.*.printers)), "notify::selected", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&printer_changed)))), @ptrCast(@alignCast(r)), null, 0);
        printer_changed(null, null, @ptrCast(@alignCast(r)));
    }
    portal_request_unref(r);
}

pub fn page_mode_changed(_: [*c]ffi.GObject, _: [*c]ffi.GParamSpec, data: ffi.gpointer) callconv(.c) void {
    const d: [*c]PrintData = @ptrCast(@alignCast(data));
    const index_1: ffi.guint = ffi.gtk_drop_down_get_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.page_mode))));
    ffi.gtk_widget_set_sensitive(d.*.ranges, @intFromBool((index_1 < d.*.page_modes.*.f_len) and ffi.strcmp(@ptrCast(@alignCast(ffi.items(d.*.page_modes)[index_1])), "ranges") == 0));
}

pub fn field(body: [*c]ffi.GtkBox, name: [*c]const u8, widget: [*c]ffi.GtkWidget) callconv(.c) void {
    ffi.gtk_box_append(body, portal_label(name));
    ffi.gtk_box_append(body, widget);
}

pub fn portal_print_clear(p: [*c]Portal) callconv(.c) void {
    if (p.*.print_tokens != null) {
        ffi.g_hash_table_remove_all(p.*.print_tokens);
    }
}

pub fn portal_print_init(p: [*c]Portal) callconv(.c) void {
    p.*.print_tokens = ffi.g_hash_table_new_full(ffi.g_direct_hash, ffi.g_direct_equal, null, token_free);
}

pub fn portal_print_stop(p: [*c]Portal) callconv(.c) void {
    ffi.g_hash_table_unref(p.*.print_tokens);
}

pub fn portal_print(r: [*c]Request, params: ?*ffi.GVariant) callconv(.c) void {
    if (portal_restricted(r.*.portal, "disable-printing") != 0) {
        portal_complete(r, 2, null);
        return;
    }
    const d: [*c]PrintData = ffi.cast([*c]PrintData, ffi.g_malloc0_n(1, @sizeOf(PrintData)));
    d.*.fd = -1;
    r.*.data = @ptrCast(@alignCast(d));
    r.*.destroy_data = data_free;
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.cancel)), "cancelled", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&stopped)))), @ptrCast(@alignCast(d)), null, 0);
    d.*.ids = ffi.g_ptr_array_new_with_free_func(ffi.g_free);
    d.*.page_modes = ffi.g_ptr_array_new_with_free_func(ffi.g_free);
    d.*.output_format = ffi.g_strdup("pdf");
    const formats: ?*ffi.GVariant = portal_option(r.*.options, "supported_output_file_formats", "as");
    defer if (formats != null) ffi.g_variant_unref(@ptrCast(formats));
    if (formats != null) {
        ffi.clear(&d.*.output_format, ffi.g_free);
        var it: ffi.GVariantIter = undefined;
        var format: [*c]const u8 = undefined;
        _ = ffi.g_variant_iter_init(&it, formats);
        while (ffi.g_variant_iter_next(&it, "&s", &format) != 0) {
            if (ffi.strcmp(format, "pdf") == 0) {
                ffi.g_free(@ptrCast(@alignCast(d.*.output_format)));
                d.*.output_format = ffi.g_strdup(format);
                break;
            }
            if ((ffi.strcmp(format, "ps") == 0 or ffi.strcmp(format, "svg") == 0) and d.*.output_format == null) {
                d.*.output_format = ffi.g_strdup(format);
            }
        }
    }
    var it: ffi.GHashTableIter = undefined;
    var value: ffi.gpointer = undefined;
    ffi.g_hash_table_iter_init(&it, r.*.portal.*.print_tokens);
    while (ffi.g_hash_table_iter_next(&it, null, &value) != 0) if (ffi.cast([*c]PrintToken, value).*.expires < ffi.g_get_monotonic_time()) {
        ffi.g_hash_table_iter_remove(&it);
    };
    if (ffi.strcmp(r.*.method, "Print") == 0) {
        var handle: ffi.gint = undefined;
        ffi.g_variant_get_child(params, 4, "h", &handle);
        const fds: [*c]ffi.GUnixFDList = ffi.g_dbus_message_get_unix_fd_list(ffi.g_dbus_method_invocation_get_message(r.*.invocation));
        if (fds != null) {
            d.*.fd = ffi.g_unix_fd_list_get(fds, handle, null);
        }
        var st: ffi.struct_stat = undefined;
        if ((((d.*.fd < 0) or (ffi.fstat(d.*.fd, &st) != 0)) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) or (st.st_size > @as(ffi.__off_t, (@as(c_int, 256) * @as(c_int, 1024)) * @as(c_int, 1024)))) {
            portal_complete(r, 2, null);
            return;
        }
        var token: ffi.guint = 0;
        _ = ffi.g_variant_lookup(r.*.options, "token", "u", &token);
        if (token != 0) {
            const t: [*c]PrintToken = @ptrCast(@alignCast(ffi.g_hash_table_lookup(r.*.portal.*.print_tokens, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, token))))));
            if ((t == null or (ffi.strcmp(t.*.app, r.*.app_id) != 0)) or (ffi.strcmp(t.*.sender, r.*.sender) != 0)) {
                portal_complete(r, 2, null);
                return;
            }
            _ = ffi.g_hash_table_steal(r.*.portal.*.print_tokens, @as(ffi.gpointer, @ptrFromInt(@as(ffi.gulong, token))));
            d.*.token = t;
            submit(r);
            return;
        }
        d.*.initial = ffi.g_variant_ref_sink(portal_empty());
        d.*.page = ffi.g_variant_ref_sink(portal_empty());
    } else {
        d.*.initial = ffi.g_variant_get_child_value(params, 4);
        d.*.page = ffi.g_variant_get_child_value(params, 5);
    }
    var title: [*c]const u8 = undefined;
    ffi.g_variant_get_child(params, 3, "&s", &title);
    _ = portal_dialog(r, if (title.* != 0) title else ffi.cast([*c]const u8, "Print"), "Cancel", portal_string(r.*.options, "accept_label", "Print"));
    const body: [*c]ffi.GtkBox = ffi.cast([*c]ffi.GtkBox, ffi.gtk_dialog_get_content_area(r.*.dialog));
    d.*.printers = ffi.gtk_drop_down_new(null, null);
    field(body, "Printer", d.*.printers);
    d.*.copies = ffi.gtk_spin_button_new_with_range(@floatFromInt(1), @floatFromInt(@as(c_int, 999)), @floatFromInt(1));
    ffi.gtk_spin_button_set_value(ffi.cast(?*ffi.GtkSpinButton, d.*.copies), @floatFromInt(if (1 > ffi.atoi(portal_string(d.*.initial, "n-copies", "1"))) 1 else ffi.atoi(portal_string(d.*.initial, "n-copies", "1"))));
    field(body, "Copies", d.*.copies);
    var duplex: [4][*c]const u8 = [4][*c]const u8{
        "One sided",
        "Two sided \xc2\xb7 long edge",
        "Two sided \xc2\xb7 short edge",
        null,
    };
    d.*.duplex = ffi.gtk_drop_down_new_from_strings(@ptrCast(@alignCast(&duplex)));
    const initial_duplex: [*c]const u8 = portal_string(d.*.initial, "duplex", "simplex");
    ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.duplex))), @bitCast(@as(c_int, if (ffi.strcmp(initial_duplex, "vertical") == 0) 1 else if (ffi.strcmp(initial_duplex, "horizontal") == 0) @as(c_int, 2) else 0)));
    field(body, "Sides", d.*.duplex);
    d.*.color = ffi.gtk_check_button_new_with_label(@import("i18n").dtr("pearl", "Print in color"));
    ffi.gtk_check_button_set_active(ffi.cast([*c]ffi.GtkCheckButton, d.*.color), @intFromBool(ffi.strcmp(portal_string(d.*.initial, "use-color", "true"), "false") != 0));
    ffi.gtk_box_append(body, d.*.color);
    var orientation: [3][*c]const u8 = [3][*c]const u8{
        "Portrait",
        "Landscape",
        null,
    };
    d.*.orientation = ffi.gtk_drop_down_new_from_strings(@ptrCast(@alignCast(&orientation)));
    ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.orientation))), @bitCast(@as(c_int, @intFromBool(ffi.strcmp(portal_string(d.*.initial, "orientation", "portrait"), "landscape") == 0))));
    field(body, "Orientation", d.*.orientation);
    var paper: [4][*c]const u8 = [4][*c]const u8{
        "A4",
        "Letter",
        "Legal",
        null,
    };
    d.*.paper = ffi.gtk_drop_down_new_from_strings(@ptrCast(@alignCast(&paper)));
    field(body, "Paper", d.*.paper);
    d.*.ranges = ffi.gtk_entry_new();
    ffi.gtk_entry_set_placeholder_text(ffi.cast([*c]ffi.GtkEntry, d.*.ranges), @import("i18n").dtr("pearl", "All pages, or 1-3,5"));
    const initial_ranges: [*c]u8 = shift_ranges(portal_string(d.*.initial, "page-ranges", ""), 1);
    defer if (initial_ranges != null) ffi.g_free(@ptrCast(initial_ranges));
    if (initial_ranges != null) {
        ffi.gtk_editable_set_text(ffi.cast(?*ffi.GtkEditable, d.*.ranges), initial_ranges);
    }
    const modes: ?*ffi.GtkStringList = ffi.gtk_string_list_new(null);
    ffi.gtk_string_list_append(modes, @import("i18n").dtr("pearl", "All pages"));
    ffi.g_ptr_array_add(d.*.page_modes, @ptrCast(@alignCast(ffi.g_strdup("all"))));
    ffi.gtk_string_list_append(modes, @import("i18n").dtr("pearl", "Page ranges"));
    ffi.g_ptr_array_add(d.*.page_modes, @ptrCast(@alignCast(ffi.g_strdup("ranges"))));
    if (portal_boolean(r.*.options, "has_current_page", 0) != 0) {
        ffi.gtk_string_list_append(modes, @import("i18n").dtr("pearl", "Current page"));
        ffi.g_ptr_array_add(d.*.page_modes, @ptrCast(@alignCast(ffi.g_strdup("current"))));
    }
    if (portal_boolean(r.*.options, "has_selected_pages", 0) != 0) {
        ffi.gtk_string_list_append(modes, @import("i18n").dtr("pearl", "Selection"));
        ffi.g_ptr_array_add(d.*.page_modes, @ptrCast(@alignCast(ffi.g_strdup("selection"))));
    }
    d.*.page_mode = ffi.gtk_drop_down_new(ffi.G_LIST_MODEL(@ptrCast(@alignCast(modes))), null);
    field(body, "Pages", d.*.page_mode);
    const initial_mode: [*c]const u8 = portal_string(d.*.initial, "print-pages", "all");
    {
        var i: ffi.guint = 0;
        while (i < d.*.page_modes.*.f_len) : (i +%= 1) if (ffi.strcmp(initial_mode, @ptrCast(@alignCast(ffi.items(d.*.page_modes)[i]))) == 0) {
            ffi.gtk_drop_down_set_selected(ffi.GTK_DROP_DOWN(@ptrCast(@alignCast(d.*.page_mode))), i);
        };
    }
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(d.*.page_mode)), "notify::selected", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&page_mode_changed)))), @ptrCast(@alignCast(d)), null, 0);
    page_mode_changed(null, null, @ptrCast(@alignCast(d)));
    field(body, "Page ranges", d.*.ranges);
    d.*.status = portal_label("Finding printers\xe2\x80\xa6");
    ffi.gtk_box_append(body, d.*.status);
    ffi.gtk_dialog_set_response_sensitive(r.*.dialog, ffi.GTK_RESPONSE_ACCEPT, 0);
    _ = ffi.g_signal_connect_data(@ptrCast(@alignCast(r.*.dialog)), "response", @as(ffi.GCallback, @ptrCast(@alignCast(@constCast(&response)))), @ptrCast(@alignCast(r)), null, 0);
    portal_present(r);
    var args: [4][*c]const u8 = [4][*c]const u8{
        "/proc/self/exe",
        "--print-worker",
        "list",
        null,
    };
    if (!(worker(r, @ptrCast(@alignCast(&args)), 0) != null)) {
        portal_complete(r, 2, null);
        return;
    }
    ffi.g_subprocess_communicate_utf8_async(d.*.worker, null, r.*.cancel, enumerated, @ptrCast(@alignCast(portal_request_ref(r))));
}

// Portal ranges are zero based; the print UI and CUPS use one based ranges.
fn shift_ranges(text: [*c]const u8, shift: c_int) [*c]u8 {
    const out = ffi.g_string_new(null);
    var cursor = text;
    var valid = false;
    defer if (!valid) {
        _ = ffi.g_string_free(out, 1);
    };
    while (cursor[0] != 0) {
        var end: [*c]u8 = undefined;
        const first = ffi.g_ascii_strtoull(cursor, &end, 10);
        if (end == cursor or first > 1000000 or (shift < 0 and first == 0)) return null;
        ffi.g_string_append_printf(out, "%u", @as(c_uint, @intCast(@as(i64, @intCast(first)) + shift)));
        cursor = end;
        if (cursor[0] == '-') {
            cursor += 1;
            const last = ffi.g_ascii_strtoull(cursor, &end, 10);
            if (end == cursor or last < first or last > 1000000) return null;
            ffi.g_string_append_printf(out, "-%u", @as(c_uint, @intCast(@as(i64, @intCast(last)) + shift)));
            cursor = end;
        }
        if (cursor[0] == 0) break;
        if (cursor[0] != ',' or cursor[1] == 0) return null;
        _ = ffi.g_string_append_c(out, ',');
        cursor += 1;
    }
    valid = true;
    return ffi.g_string_free(out, 0);
}
