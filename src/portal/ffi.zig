//! External library ABI only. Portal behavior lives in the sibling Zig modules.
//! GTK/GIO/GLib object layouts come from Pearl's existing generated bindings.
pub const GCallback = ?*const fn () callconv(.c) void;

pub const GFile = @import("gio2").File;

pub const GListModel = @import("gio2").ListModel;

pub const GObject = @import("gobject2").Object;

pub const GTK_FILE_CHOOSER_ACTION_OPEN: c_int = 0;

pub const GTK_FILE_CHOOSER_ACTION_SAVE: c_int = 1;

pub const GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER: c_int = 2;

pub const GTK_RESPONSE_ACCEPT: c_int = -3;

pub const GType = gsize;

pub const GVariant = @import("glib2").Variant;

pub const GVariantBuilder = @import("glib2").VariantBuilder;

pub const GVariantIter = @import("glib2").VariantIter;

pub const GVariantType = @import("glib2").VariantType;

pub const GtkDialog = @import("gtk4").Dialog;

pub const GtkFileChooserAction = c_uint;

pub const GtkFileFilter = @import("gtk4").FileFilter;

pub extern fn g_file_get_path(file: ?*GFile) [*c]u8;

pub extern fn g_file_get_uri(file: ?*GFile) [*c]u8;

pub extern fn g_file_new_for_path(path: [*c]const u8) ?*GFile;

pub extern fn g_free(mem: gpointer) void;

pub extern fn g_list_model_get_item(list: ?*GListModel, position: guint) gpointer;

pub extern fn g_list_model_get_n_items(list: ?*GListModel) guint;

pub extern fn g_memdup2(mem: gconstpointer, byte_size: gsize) gpointer;

pub extern fn g_object_get_data(object: [*c]GObject, key: [*c]const gchar) gpointer;

pub extern fn g_object_ref_sink(object: gpointer) gpointer;

pub extern fn g_object_set_data_full(object: [*c]GObject, key: [*c]const gchar, data: gpointer, destroy: GDestroyNotify) void;

pub extern fn g_object_unref(object: gpointer) void;

pub extern fn g_path_is_absolute(file_name: [*c]const gchar) gboolean;

pub extern fn g_signal_connect_data(instance: gpointer, detailed_signal: [*c]const gchar, c_handler: GCallback, data: gpointer, destroy_data: GClosureNotify, connect_flags: GConnectFlags) gulong;

pub extern fn g_strdup_printf(format: [*c]const gchar, ...) [*c]gchar;

pub extern fn g_type_check_instance_cast(instance: [*c]GTypeInstance, iface_type: GType) [*c]GTypeInstance;

pub extern fn g_variant_builder_add(builder: [*c]GVariantBuilder, format_string: [*c]const gchar, ...) void;

pub extern fn g_variant_builder_clear(builder: [*c]GVariantBuilder) void;

pub extern fn g_variant_builder_end(builder: [*c]GVariantBuilder) ?*GVariant;

pub extern fn g_variant_builder_init(builder: [*c]GVariantBuilder, @"type": ?*const GVariantType) void;

pub extern fn g_variant_equal(one: gconstpointer, two: gconstpointer) gboolean;

pub extern fn g_variant_get(value: ?*GVariant, format_string: [*c]const gchar, ...) void;

pub extern fn g_variant_get_child(value: ?*GVariant, index_: gsize, format_string: [*c]const gchar, ...) void;

pub extern fn g_variant_get_child_value(value: ?*GVariant, index_: gsize) ?*GVariant;

pub extern fn g_variant_get_fixed_array(value: ?*GVariant, n_elements: [*c]gsize, element_size: gsize) gconstpointer;

pub extern fn g_variant_iter_init(iter: [*c]GVariantIter, value: ?*GVariant) gsize;

pub extern fn g_variant_n_children(value: ?*GVariant) gsize;

pub extern fn g_variant_ref(value: ?*GVariant) ?*GVariant;

pub extern fn g_variant_type_checked_(type_string: [*c]const gchar) ?*const GVariantType;

pub extern fn g_variant_unref(value: ?*GVariant) void;

pub const gboolean = gint;

pub const gpointer = ?*anyopaque;

pub const gsize = c_ulong;

pub extern fn gtk_file_filter_add_mime_type(filter: ?*GtkFileFilter, mime_type: [*c]const u8) void;

pub extern fn gtk_file_filter_add_pattern(filter: ?*GtkFileFilter, pattern: [*c]const u8) void;

pub extern fn gtk_file_filter_new() ?*GtkFileFilter;

pub extern fn gtk_file_filter_set_name(filter: ?*GtkFileFilter, name: [*c]const u8) void;

pub const guint = c_uint;

pub extern fn open(__file: [*c]const u8, __oflag: c_int, ...) c_int;

pub const GAsyncResult = @import("gio2").AsyncResult;

pub const GCancellable = @import("gio2").Cancellable;

pub const GDBusConnection = @import("gio2").DBusConnection;

pub const GDBusInterfaceVTable = struct__GDBusInterfaceVTable;

pub const GDBusMethodInvocation = @import("gio2").DBusMethodInvocation;

pub const GDBusNodeInfo = @import("gio2").DBusNodeInfo;

pub const GHashTable = @import("glib2").HashTable;

pub const GHashTableIter = @import("glib2").HashTableIter;

pub const GUnixFDList = @import("gio2").UnixFDList;

pub const G_BUS_NAME_WATCHER_FLAGS_NONE: c_int = 0;

pub const G_BUS_TYPE_SYSTEM: c_int = 1;

pub const G_DBUS_CALL_FLAGS_NO_AUTO_START: c_int = 1;

pub const G_DBUS_SIGNAL_FLAGS_NONE: c_int = 0;

pub extern fn close(__fd: c_int) c_int;

pub extern fn g_bus_get_sync(bus_type: GBusType, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*GDBusConnection;

pub extern fn g_bus_unwatch_name(watcher_id: guint) void;

pub extern fn g_bus_watch_name_on_connection(connection: ?*GDBusConnection, name: [*c]const gchar, flags: GBusNameWatcherFlags, name_appeared_handler: GBusNameAppearedCallback, name_vanished_handler: GBusNameVanishedCallback, user_data: gpointer, user_data_free_func: GDestroyNotify) guint;

pub extern fn g_cancellable_cancel(cancellable: [*c]GCancellable) void;

pub extern fn g_cancellable_new() [*c]GCancellable;

pub extern fn g_dbus_connection_call(connection: ?*GDBusConnection, bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, reply_type: ?*const GVariantType, flags: GDBusCallFlags, timeout_msec: gint, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_dbus_connection_call_finish(connection: ?*GDBusConnection, res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_dbus_connection_call_sync(connection: ?*GDBusConnection, bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, reply_type: ?*const GVariantType, flags: GDBusCallFlags, timeout_msec: gint, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_dbus_connection_call_with_unix_fd_list(connection: ?*GDBusConnection, bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, reply_type: ?*const GVariantType, flags: GDBusCallFlags, timeout_msec: gint, fd_list: [*c]GUnixFDList, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_dbus_connection_call_with_unix_fd_list_finish(connection: ?*GDBusConnection, out_fd_list: [*c][*c]GUnixFDList, res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_dbus_connection_emit_signal(connection: ?*GDBusConnection, destination_bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, signal_name: [*c]const gchar, parameters: ?*GVariant, @"error": [*c][*c]GError) gboolean;

pub extern fn g_dbus_connection_register_object(connection: ?*GDBusConnection, object_path: [*c]const gchar, interface_info: [*c]GDBusInterfaceInfo, vtable: [*c]const GDBusInterfaceVTable, user_data: gpointer, user_data_free_func: GDestroyNotify, @"error": [*c][*c]GError) guint;

pub extern fn g_dbus_connection_signal_subscribe(connection: ?*GDBusConnection, sender: [*c]const gchar, interface_name: [*c]const gchar, member: [*c]const gchar, object_path: [*c]const gchar, arg0: [*c]const gchar, flags: GDBusSignalFlags, callback: GDBusSignalCallback, user_data: gpointer, user_data_free_func: GDestroyNotify) guint;

pub extern fn g_dbus_connection_signal_unsubscribe(connection: ?*GDBusConnection, subscription_id: guint) void;

pub extern fn g_dbus_connection_unregister_object(connection: ?*GDBusConnection, registration_id: guint) gboolean;

pub extern fn g_dbus_method_invocation_get_sender(invocation: ?*GDBusMethodInvocation) [*c]const gchar;

pub extern fn g_dbus_method_invocation_return_value(invocation: ?*GDBusMethodInvocation, parameters: ?*GVariant) void;

pub extern fn g_dbus_node_info_new_for_xml(xml_data: [*c]const gchar, @"error": [*c][*c]GError) [*c]GDBusNodeInfo;

pub extern fn g_dbus_node_info_unref(info: [*c]GDBusNodeInfo) void;

pub extern fn g_hash_table_insert(hash_table: ?*GHashTable, key: gpointer, value: gpointer) gboolean;

pub extern fn g_hash_table_iter_init(iter: [*c]GHashTableIter, hash_table: ?*GHashTable) void;

pub extern fn g_hash_table_iter_next(iter: [*c]GHashTableIter, key: [*c]gpointer, value: [*c]gpointer) gboolean;

pub extern fn g_hash_table_lookup(hash_table: ?*GHashTable, key: gconstpointer) gpointer;

pub extern fn g_hash_table_new_full(hash_func: GHashFunc, key_equal_func: GEqualFunc, key_destroy_func: GDestroyNotify, value_destroy_func: GDestroyNotify) ?*GHashTable;

pub extern fn g_hash_table_remove(hash_table: ?*GHashTable, key: gconstpointer) gboolean;

pub extern fn g_hash_table_remove_all(hash_table: ?*GHashTable) void;

pub extern fn g_hash_table_unref(hash_table: ?*GHashTable) void;

pub extern fn g_malloc0_n(n_blocks: gsize, n_block_bytes: gsize) gpointer;

pub extern fn g_object_ref(object: gpointer) gpointer;

pub extern fn g_str_equal(v1: gconstpointer, v2: gconstpointer) gboolean;

pub extern fn g_str_has_prefix(str: [*c]const gchar, prefix: [*c]const gchar) gboolean;

pub extern fn g_str_hash(v: gconstpointer) guint;

pub extern fn g_unix_fd_list_get(list: [*c]GUnixFDList, index_: c_int, @"error": [*c][*c]GError) c_int;

pub extern fn g_variant_lookup(dictionary: ?*GVariant, key: [*c]const gchar, format_string: [*c]const gchar, ...) gboolean;

pub extern fn g_variant_new(format_string: [*c]const gchar, ...) ?*GVariant;

pub extern fn g_variant_new_boolean(value: gboolean) ?*GVariant;

pub extern fn g_variant_new_uint32(value: guint32) ?*GVariant;

pub const gconstpointer = ?*const anyopaque;

pub const gint = c_int;

pub extern fn memcmp(__s1: ?*const anyopaque, __s2: ?*const anyopaque, __n: usize) c_int;

pub const GAppInfo = @import("gio2").AppInfo;

pub const GBytesIcon = @import("gio2").BytesIcon;

pub fn GDK_PAINTABLE(arg_ptr: gpointer) callconv(.c) ?*GdkPaintable {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GdkPaintable, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), gdk_paintable_get_type())))))));
}

pub const GDesktopAppInfo = struct__GDesktopAppInfo;

pub const GFileIcon = @import("gio2").FileIcon;

pub const GFileInfo = @import("gio2").FileInfo;

pub const GIcon = @import("gio2").Icon;

pub const GParamSpec = @import("gobject2").ParamSpec;

pub const GPtrArray = @import("glib2").PtrArray;

pub const GTK_CONTENT_FIT_CONTAIN: c_int = 1;

pub fn GTK_DROP_DOWN(arg_ptr: gpointer) callconv(.c) ?*GtkDropDown {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GtkDropDown, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), gtk_drop_down_get_type())))))));
}

pub fn GTK_PICTURE(arg_ptr: gpointer) callconv(.c) ?*GtkPicture {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GtkPicture, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), gtk_picture_get_type())))))));
}

pub const GTypeInstance = @import("gobject2").TypeInstance;

pub const GUri = @import("glib2").Uri;

pub const G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS: c_int = 1;

pub fn G_LIST_MODEL(arg_ptr: gpointer) callconv(.c) ?*GListModel {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GListModel, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), g_list_model_get_type())))))));
}

pub const G_URI_FLAGS_NONE: c_int = 0;

pub const GdkTexture = @import("gdk4").Texture;

pub const GtkBox = @import("gtk4").Box;

pub const GtkButton = @import("gtk4").Button;

pub const GtkCheckButton = @import("gtk4").CheckButton;

pub const GtkEditable = @import("gtk4").Editable;

pub const GtkImage = @import("gtk4").Image;

pub const GtkLabel = @import("gtk4").Label;

pub const GtkStringList = @import("gtk4").StringList;

pub const GtkWidget = @import("gtk4").Widget;

pub const GtkWindow = @import("gtk4").Window;

pub extern fn g_app_info_get_display_name(appinfo: ?*GAppInfo) [*c]const u8;

pub extern fn g_app_info_should_show(appinfo: ?*GAppInfo) gboolean;

pub extern fn g_bus_get(bus_type: GBusType, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_bus_get_finish(res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GDBusConnection;

pub extern fn g_bytes_get_data(bytes: ?*GBytes, size: [*c]gsize) gconstpointer;

pub extern fn g_bytes_icon_get_bytes(icon: ?*GBytesIcon) ?*GBytes;

pub extern fn g_bytes_icon_get_type() GType;

pub extern fn g_desktop_app_info_new(desktop_id: [*c]const u8) ?*GDesktopAppInfo;

pub extern fn g_file_icon_get_file(icon: ?*GFileIcon) ?*GFile;

pub extern fn g_file_icon_get_type() GType;

pub extern fn g_file_icon_new(file: ?*GFile) ?*GIcon;

pub extern fn g_file_info_set_attribute_object(info: ?*GFileInfo, attribute: [*c]const u8, attr_value: [*c]GObject) void;

pub extern fn g_file_is_native(file: ?*GFile) gboolean;

pub extern fn g_file_open_tmp(tmpl: [*c]const gchar, name_used: [*c][*c]gchar, @"error": [*c][*c]GError) gint;

pub extern fn g_file_query_info_async(file: ?*GFile, attributes: [*c]const u8, flags: GFileQueryInfoFlags, io_priority: c_int, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_file_query_info_finish(file: ?*GFile, res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GFileInfo;

pub extern fn g_get_real_name() [*c]const gchar;

pub extern fn g_get_user_name() [*c]const gchar;

pub extern fn g_icon_deserialize(value: ?*GVariant) ?*GIcon;

pub extern fn g_icon_serialize(icon: ?*GIcon) ?*GVariant;

pub extern fn g_ptr_array_add(array: [*c]GPtrArray, data: gpointer) void;

pub extern fn g_ptr_array_new_with_free_func(element_free_func: GDestroyNotify) [*c]GPtrArray;

pub extern fn g_ptr_array_set_size(array: [*c]GPtrArray, length: gint) void;

pub extern fn g_ptr_array_unref(array: [*c]GPtrArray) void;

pub fn g_steal_pointer(arg_pp: gpointer) callconv(.c) gpointer {
    var pp = arg_pp;
    _ = &pp;
    var ptr: [*c]gpointer = @ptrCast(@alignCast(pp));
    _ = &ptr;
    var ref: gpointer = undefined;
    _ = &ref;
    ref = ptr.*;
    ptr.* = null;
    return ref;
}

pub extern fn g_str_has_suffix(str: [*c]const gchar, suffix: [*c]const gchar) gboolean;

pub extern fn g_strconcat(string1: [*c]const gchar, ...) [*c]gchar;

pub extern fn g_strfreev(str_array: [*c][*c]gchar) void;

pub extern fn g_themed_icon_get_type() GType;

pub extern fn g_type_check_instance_is_a(instance: [*c]GTypeInstance, iface_type: GType) gboolean;

pub extern fn g_unlink(filename: [*c]const gchar) c_int;

pub extern fn g_uri_get_scheme(uri: ?*GUri) [*c]const gchar;

pub extern fn g_uri_parse(uri_string: [*c]const gchar, flags: GUriFlags, @"error": [*c][*c]GError) ?*GUri;

pub extern fn g_uri_unref(uri: ?*GUri) void;

pub extern fn g_variant_get_variant(value: ?*GVariant) ?*GVariant;

pub extern fn g_variant_new_string(string: [*c]const gchar) ?*GVariant;

pub extern fn g_variant_new_variant(value: ?*GVariant) ?*GVariant;

pub extern fn g_variant_ref_sink(value: ?*GVariant) ?*GVariant;

pub extern fn getuid() __uid_t;

pub extern fn gtk_box_append(box: [*c]GtkBox, child: [*c]GtkWidget) void;

pub extern fn gtk_box_prepend(box: [*c]GtkBox, child: [*c]GtkWidget) void;

pub extern fn gtk_button_new_with_label(label: [*c]const u8) [*c]GtkWidget;

pub extern fn gtk_check_button_get_active(self: [*c]GtkCheckButton) gboolean;

pub extern fn gtk_check_button_new_with_label(label: [*c]const u8) [*c]GtkWidget;

pub extern fn gtk_check_button_set_active(self: [*c]GtkCheckButton, setting: gboolean) void;

pub extern fn gtk_dialog_get_content_area(dialog: [*c]GtkDialog) [*c]GtkWidget;

pub extern fn gtk_dialog_set_response_sensitive(dialog: [*c]GtkDialog, response_id: c_int, setting: gboolean) void;

pub extern fn gtk_drop_down_get_selected(self: ?*GtkDropDown) guint;

pub extern fn gtk_drop_down_new(model: ?*GListModel, expression: ?*GtkExpression) [*c]GtkWidget;

pub extern fn gtk_drop_down_set_enable_search(self: ?*GtkDropDown, enable_search: gboolean) void;

pub extern fn gtk_drop_down_set_model(self: ?*GtkDropDown, model: ?*GListModel) void;

pub extern fn gtk_drop_down_set_selected(self: ?*GtkDropDown, position: guint) void;

pub extern fn gtk_editable_get_text(editable: ?*GtkEditable) [*c]const u8;

pub extern fn gtk_editable_set_editable(editable: ?*GtkEditable, is_editable: gboolean) void;

pub extern fn gtk_editable_set_text(editable: ?*GtkEditable, text: [*c]const u8) void;

pub extern fn gtk_entry_new() [*c]GtkWidget;

pub extern fn gtk_image_new() [*c]GtkWidget;

pub extern fn gtk_image_new_from_icon_name(icon_name: [*c]const u8) [*c]GtkWidget;

pub extern fn gtk_image_set_from_gicon(image: ?*GtkImage, icon: ?*GIcon) void;

pub extern fn gtk_image_set_pixel_size(image: ?*GtkImage, pixel_size: c_int) void;

pub extern fn gtk_label_set_text(self: ?*GtkLabel, str: [*c]const u8) void;

pub extern fn gtk_picture_new() [*c]GtkWidget;

pub extern fn gtk_picture_set_content_fit(self: ?*GtkPicture, content_fit: GtkContentFit) void;

pub extern fn gtk_picture_set_paintable(self: ?*GtkPicture, paintable: ?*GdkPaintable) void;

pub extern fn gtk_string_list_append(self: ?*GtkStringList, string: [*c]const u8) void;

pub extern fn gtk_string_list_new(strings: [*c]const [*c]const u8) ?*GtkStringList;

pub extern fn gtk_widget_set_size_request(widget: [*c]GtkWidget, width: c_int, height: c_int) void;

pub extern fn gtk_widget_set_visible(widget: [*c]GtkWidget, visible: gboolean) void;

pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;

pub const GAppLaunchContext = @import("gio2").AppLaunchContext;

pub const GBytes = @import("glib2").Bytes;

pub const GError = @import("glib2").Error;

pub const G_DBUS_CALL_FLAGS_NONE: c_int = 0;

pub const G_FILE_SET_CONTENTS_CONSISTENT: c_int = 1;

pub const __mode_t = c_uint;

pub const __off_t = c_long;

pub const fstat = platform.fstat;

pub extern fn g_app_info_launch(appinfo: ?*GAppInfo, files: [*c]GList, context: [*c]GAppLaunchContext, @"error": [*c][*c]GError) gboolean;

pub extern fn g_app_launch_context_new() [*c]GAppLaunchContext;

pub extern fn g_app_launch_context_setenv(context: [*c]GAppLaunchContext, variable: [*c]const u8, value: [*c]const u8) void;

pub extern fn g_build_filename(first_element: [*c]const gchar, ...) [*c]gchar;

pub extern fn g_bytes_new_take(data: gpointer, size: gsize) ?*GBytes;

pub extern fn g_bytes_unref(bytes: ?*GBytes) void;

pub extern fn g_dbus_connection_get_guid(connection: ?*GDBusConnection) [*c]const gchar;

pub extern fn g_dbus_is_name(string: [*c]const gchar) gboolean;

pub extern fn g_dbus_message_get_unix_fd_list(message: ?*GDBusMessage) [*c]GUnixFDList;

pub extern fn g_dbus_method_invocation_get_message(invocation: ?*GDBusMethodInvocation) ?*GDBusMessage;

pub extern fn g_error_free(@"error": [*c]GError) void;

pub extern fn g_file_set_contents_full(filename: [*c]const gchar, contents: [*c]const gchar, length: gssize, flags: GFileSetContentsFlags, mode: c_int, @"error": [*c][*c]GError) gboolean;

pub extern fn g_filename_from_uri(uri: [*c]const gchar, hostname: [*c][*c]gchar, @"error": [*c][*c]GError) [*c]gchar;

pub extern fn g_getenv(variable: [*c]const gchar) [*c]const gchar;

pub extern fn g_hash_table_iter_remove(iter: [*c]GHashTableIter) void;

pub extern fn g_hash_table_replace(hash_table: ?*GHashTable, key: gpointer, value: gpointer) gboolean;

pub extern fn g_malloc(n_bytes: gsize) gpointer;

pub extern fn g_mkdir_with_parents(pathname: [*c]const gchar, mode: gint) gint;

pub extern fn g_strcmp0(str1: [*c]const u8, str2: [*c]const u8) c_int;

pub extern fn g_variant_builder_add_value(builder: [*c]GVariantBuilder, value: ?*GVariant) void;

pub extern fn g_variant_get_data(value: ?*GVariant) gconstpointer;

pub extern fn g_variant_get_handle(value: ?*GVariant) gint32;

pub extern fn g_variant_get_size(value: ?*GVariant) gsize;

pub extern fn g_variant_get_string(value: ?*GVariant, length: [*c]gsize) [*c]const gchar;

pub extern fn g_variant_is_normal_form(value: ?*GVariant) gboolean;

pub extern fn g_variant_is_object_path(string: [*c]const gchar) gboolean;

pub extern fn g_variant_lookup_value(dictionary: ?*GVariant, key: [*c]const gchar, expected_type: ?*const GVariantType) ?*GVariant;

pub extern fn g_variant_new_from_bytes(@"type": ?*const GVariantType, bytes: ?*GBytes, trusted: gboolean) ?*GVariant;

pub extern fn getpid() __pid_t;

pub const guint8 = u8;

pub const lstat = platform.lstat;

pub extern fn memfd_create(__name: [*c]const u8, __flags: c_uint) c_int;

pub extern fn read(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize) isize;

pub const struct_stat = platform.struct_stat;

pub const GFileMonitor = @import("gio2").FileMonitor;

pub const GFileMonitorEvent = c_uint;

pub const GKeyFile = @import("glib2").KeyFile;

pub const GSettings = @import("gio2").Settings;

pub const GSettingsSchema = @import("gio2").SettingsSchema;

pub const GSettingsSchemaSource = @import("gio2").SettingsSchemaSource;

pub const GStatBuf = struct_stat;

pub const GStrv = [*c][*c]gchar;

pub const G_DBUS_ERROR_UNKNOWN_PROPERTY: c_int = 43;

pub const G_FILE_MONITOR_WATCH_MOVES: c_int = 8;

pub const G_KEY_FILE_NONE: c_int = 0;

pub const GdkDisplay = @import("gdk4").Display;

pub const GtkCssProvider = @import("gtk4").CssProvider;

pub const GtkStyleProvider = @import("gtk4").StyleProvider;

pub extern fn __errno_location() [*c]c_int;

pub const __uid_t = c_uint;

pub extern fn g_dbus_error_quark() GQuark;

pub extern fn g_file_monitor_file(file: ?*GFile, flags: GFileMonitorFlags, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) [*c]GFileMonitor;

pub extern fn g_key_file_get_boolean(key_file: ?*GKeyFile, group_name: [*c]const gchar, key: [*c]const gchar, @"error": [*c][*c]GError) gboolean;

pub extern fn g_key_file_get_keys(key_file: ?*GKeyFile, group_name: [*c]const gchar, length: [*c]gsize, @"error": [*c][*c]GError) [*c][*c]gchar;

pub extern fn g_key_file_load_from_file(key_file: ?*GKeyFile, file: [*c]const gchar, flags: GKeyFileFlags, @"error": [*c][*c]GError) gboolean;

pub extern fn g_key_file_new() ?*GKeyFile;

pub extern fn g_key_file_set_boolean(key_file: ?*GKeyFile, group_name: [*c]const gchar, key: [*c]const gchar, value: gboolean) void;

pub extern fn g_key_file_unref(key_file: ?*GKeyFile) void;

pub extern fn g_object_set(object: gpointer, first_property_name: [*c]const gchar, ...) void;

pub extern fn g_object_set_data(object: [*c]GObject, key: [*c]const gchar, data: gpointer) void;

pub extern fn g_printerr(format: [*c]const gchar, ...) void;

pub extern fn g_set_error_literal(err: [*c][*c]GError, domain: GQuark, code: gint, message: [*c]const gchar) void;

pub extern fn g_settings_get_boolean(settings: [*c]GSettings, key: [*c]const gchar) gboolean;

pub extern fn g_settings_get_value(settings: [*c]GSettings, key: [*c]const gchar) ?*GVariant;

pub extern fn g_signal_handler_disconnect(instance: gpointer, handler_id: gulong) void;

pub extern fn g_settings_new_full(schema: ?*GSettingsSchema, backend: ?*GSettingsBackend, path: [*c]const gchar) [*c]GSettings;

pub extern fn g_settings_schema_has_key(schema: ?*GSettingsSchema, name: [*c]const gchar) gboolean;

pub extern fn g_settings_schema_source_get_default() ?*GSettingsSchemaSource;

pub extern fn g_settings_schema_source_lookup(source: ?*GSettingsSchemaSource, schema_id: [*c]const gchar, recursive: gboolean) ?*GSettingsSchema;

pub extern fn g_settings_schema_unref(schema: ?*GSettingsSchema) void;

pub extern fn g_variant_get_boolean(value: ?*GVariant) gboolean;

pub extern fn g_variant_new_strv(strv: [*c]const [*c]const gchar, length: gssize) ?*GVariant;

pub extern fn gdk_display_get_default() ?*GdkDisplay;

pub const glong = c_long;

pub extern fn gtk_css_provider_load_from_string(css_provider: [*c]GtkCssProvider, string: [*c]const u8) void;

pub extern fn gtk_css_provider_new() [*c]GtkCssProvider;

pub extern fn gtk_settings_get_default() ?*GtkSettings;

pub extern fn gtk_settings_get_for_display(display: ?*GdkDisplay) ?*GtkSettings;

pub extern fn gtk_style_context_add_provider_for_display(display: ?*GdkDisplay, provider: ?*GtkStyleProvider, priority: guint) void;

pub extern fn gtk_style_context_remove_provider_for_display(display: ?*GdkDisplay, provider: ?*GtkStyleProvider) void;

pub const stat = platform.stat;

pub extern fn strncmp(__s1: [*c]const u8, __s2: [*c]const u8, __n: usize) c_int;

pub const GSubprocess = @import("gio2").Subprocess;

pub const GSubprocessLauncher = @import("gio2").SubprocessLauncher;

pub const GVariantDict = @import("glib2").VariantDict;

pub const G_FILE_QUERY_INFO_NONE: c_int = 0;

pub const G_IO_ERROR_NOT_FOUND: c_int = 1;

pub const G_SIGNAL_MATCH_DATA: c_int = 16;

pub const G_SUBPROCESS_FLAGS_STDERR_SILENCE: c_int = 32;

pub const G_SUBPROCESS_FLAGS_STDOUT_PIPE: c_int = 4;

pub const GtkEntry = @import("gtk4").Entry;

pub const GtkSpinButton = @import("gtk4").SpinButton;

pub extern fn atoi(__nptr: [*c]const u8) c_int;

pub extern fn dup(__fd: c_int) c_int;

pub extern fn g_direct_equal(v1: gconstpointer, v2: gconstpointer) gboolean;

pub extern fn g_direct_hash(v: gconstpointer) guint;

pub extern fn g_error_matches(@"error": [*c]const GError, domain: GQuark, code: gint) gboolean;

pub extern fn g_file_info_get_etag(info: ?*GFileInfo) [*c]const u8;

pub extern fn g_file_query_info(file: ?*GFile, attributes: [*c]const u8, flags: GFileQueryInfoFlags, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*GFileInfo;

pub extern fn g_get_monotonic_time() gint64;

pub extern fn g_hash_table_steal(hash_table: ?*GHashTable, key: gconstpointer) gboolean;

pub extern fn g_io_error_quark() GQuark;

pub extern fn g_random_int() guint32;

pub extern fn g_signal_handlers_disconnect_matched(instance: gpointer, mask: GSignalMatchType, signal_id: guint, detail: GQuark, closure: ?*GClosure, func: gpointer, data: gpointer) guint;

pub extern fn g_snprintf(string: [*c]gchar, n: gulong, format: [*c]const gchar, ...) gint;

pub extern fn g_source_remove(tag: guint) gboolean;

pub extern fn g_subprocess_communicate_utf8_async(subprocess: ?*GSubprocess, stdin_buf: [*c]const u8, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_subprocess_communicate_utf8_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, stdout_buf: [*c][*c]u8, stderr_buf: [*c][*c]u8, @"error": [*c][*c]GError) gboolean;

pub extern fn g_subprocess_force_exit(subprocess: ?*GSubprocess) void;

pub extern fn g_subprocess_launcher_new(flags: GSubprocessFlags) ?*GSubprocessLauncher;

pub extern fn g_subprocess_launcher_spawnv(self: ?*GSubprocessLauncher, argv: [*c]const [*c]const gchar, @"error": [*c][*c]GError) ?*GSubprocess;

pub extern fn g_subprocess_launcher_take_fd(self: ?*GSubprocessLauncher, source_fd: gint, target_fd: gint) void;

pub extern fn g_subprocess_wait_check_async(subprocess: ?*GSubprocess, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_subprocess_wait_check_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, @"error": [*c][*c]GError) gboolean;

pub extern fn g_timeout_add_seconds(interval: guint, function: GSourceFunc, data: gpointer) guint;

pub extern fn g_variant_dict_end(dict: [*c]GVariantDict) ?*GVariant;

pub extern fn g_variant_dict_init(dict: [*c]GVariantDict, from_asv: ?*GVariant) void;

pub extern fn g_variant_dict_insert(dict: [*c]GVariantDict, key: [*c]const gchar, format_string: [*c]const gchar, ...) void;

pub extern fn g_variant_parse(@"type": ?*const GVariantType, text: [*c]const gchar, limit: [*c]const gchar, endptr: [*c][*c]const gchar, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_variant_print(value: ?*GVariant, type_annotate: gboolean) [*c]gchar;

pub const gchar = u8;

pub const gint64 = c_long;

pub extern fn gtk_drop_down_new_from_strings(strings: [*c]const [*c]const u8) [*c]GtkWidget;

pub extern fn gtk_entry_set_placeholder_text(entry: [*c]GtkEntry, text: [*c]const u8) void;

pub extern fn gtk_spin_button_get_value_as_int(spin_button: ?*GtkSpinButton) c_int;

pub extern fn gtk_spin_button_new_with_range(min: f64, max: f64, step: f64) [*c]GtkWidget;

pub extern fn gtk_spin_button_set_range(spin_button: ?*GtkSpinButton, min: f64, max: f64) void;

pub extern fn gtk_spin_button_set_value(spin_button: ?*GtkSpinButton, value: f64) void;

pub extern fn gtk_widget_set_sensitive(widget: [*c]GtkWidget, sensitive: gboolean) void;

pub extern fn gtk_window_destroy(window: [*c]GtkWindow) void;

pub const gulong = c_ulong;

pub const GFileOutputStream = @import("gio2").FileOutputStream;

pub const GInputStream = @import("gio2").InputStream;

pub const GOutputStream = @import("gio2").OutputStream;

pub const G_FILE_CREATE_NONE: c_int = 0;

pub const G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET: c_int = 2;

pub const IPP_TAG_RANGE: c_int = 51;

pub const RLIMIT_AS: c_int = 9;

pub extern fn alarm(__seconds: c_uint) c_uint;

pub extern fn cupsAddOption(name: [*c]const u8, value: [*c]const u8, num_options: c_int, options: [*c][*c]cups_option_t) c_int;

pub extern fn cupsConnectDest(dest: [*c]cups_dest_t, flags: c_uint, msec: c_int, cancel: [*c]c_int, resource: [*c]u8, resourcesize: usize, cb: cups_dest_cb_t, user_data: ?*anyopaque) ?*http_t;

pub extern fn cupsCopyDestInfo(http: ?*http_t, dest: [*c]cups_dest_t) ?*cups_dinfo_t;

pub extern fn cupsEnumDests(flags: c_uint, msec: c_int, cancel: [*c]c_int, @"type": cups_ptype_t, mask: cups_ptype_t, cb: cups_dest_cb_t, user_data: ?*anyopaque) c_int;

pub extern fn cupsFindDestSupported(http: ?*http_t, dest: [*c]cups_dest_t, dinfo: ?*cups_dinfo_t, option: [*c]const u8) ?*ipp_attribute_t;

pub extern fn cupsFreeDestInfo(dinfo: ?*cups_dinfo_t) void;

pub extern fn cupsFreeDests(num_dests: c_int, dests: [*c]cups_dest_t) void;

pub extern fn cupsFreeOptions(num_options: c_int, options: [*c]cups_option_t) void;

pub extern fn cupsGetDestMediaByIndex(http: ?*http_t, dest: [*c]cups_dest_t, dinfo: ?*cups_dinfo_t, n: c_int, flags: c_uint, size: [*c]cups_size_t) c_int;

pub extern fn cupsGetDestMediaCount(http: ?*http_t, dest: [*c]cups_dest_t, dinfo: ?*cups_dinfo_t, flags: c_uint) c_int;

pub extern fn cupsGetNamedDest(http: ?*http_t, name: [*c]const u8, instance: [*c]const u8) [*c]cups_dest_t;

pub extern fn cupsGetOption(name: [*c]const u8, num_options: c_int, options: [*c]cups_option_t) [*c]const u8;

pub extern fn cupsPrintFile(name: [*c]const u8, filename: [*c]const u8, title: [*c]const u8, num_options: c_int, options: [*c]cups_option_t) c_int;

pub const cups_dest_t = struct_cups_dest_s;

pub const cups_dinfo_t = struct__cups_dinfo_s;

pub const cups_option_t = struct_cups_option_s;

pub const cups_size_t = struct_cups_size_s;

pub extern fn g_content_type_guess(filename: [*c]const gchar, data: [*c]const guchar, data_size: gsize, result_uncertain: [*c]gboolean) [*c]gchar;

pub extern fn g_file_create(file: ?*GFile, flags: GFileCreateFlags, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) [*c]GFileOutputStream;

pub extern fn g_file_new_for_uri(uri: [*c]const u8) ?*GFile;

pub extern fn g_file_replace(file: ?*GFile, etag: [*c]const u8, make_backup: gboolean, flags: GFileCreateFlags, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) [*c]GFileOutputStream;

pub extern fn g_output_stream_splice(stream: [*c]GOutputStream, source: [*c]GInputStream, flags: GOutputStreamSpliceFlags, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) gssize;

pub extern fn g_print(format: [*c]const gchar, ...) void;

pub extern fn g_unix_input_stream_new(fd: gint, close_fd: gboolean) [*c]GInputStream;

pub extern fn g_utf8_validate(str: [*c]const gchar, max_len: gssize, end: [*c][*c]const gchar) gboolean;

pub const gssize = c_long;

pub extern fn httpClose(http: ?*http_t) void;

pub const http_t = struct__http_s;

pub extern fn ippGetCount(attr: ?*ipp_attribute_t) c_int;

pub extern fn ippGetRange(attr: ?*ipp_attribute_t, element: c_int, upper: [*c]c_int) c_int;

pub extern fn ippGetString(attr: ?*ipp_attribute_t, element: c_int, language: [*c][*c]const u8) [*c]const u8;

pub extern fn ippGetValueTag(attr: ?*ipp_attribute_t) ipp_tag_t;

pub const ipp_attribute_t = struct__ipp_attribute_s;

pub extern fn lseek(__fd: c_int, __offset: __off_t, __whence: c_int) __off_t;

pub extern fn mallopt(__param: c_int, __val: c_int) c_int;

pub extern fn pread(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize, __offset: __off_t) isize;

pub const setrlimit = platform.setrlimit;

pub const struct_rlimit = platform.struct_rlimit;

pub const GList = @import("glib2").List;

pub const GString = @import("glib2").String;

pub const G_SUBPROCESS_FLAGS_STDOUT_SILENCE: c_int = 8;

pub extern fn g_app_info_equal(appinfo1: ?*GAppInfo, appinfo2: ?*GAppInfo) gboolean;

pub extern fn g_app_info_get_all_for_type(content_type: [*c]const u8) [*c]GList;

pub extern fn g_app_info_get_default_for_uri_scheme(uri_scheme: [*c]const u8) ?*GAppInfo;

pub extern fn g_app_info_get_executable(appinfo: ?*GAppInfo) [*c]const u8;

pub extern fn g_app_info_launch_uris_async(appinfo: ?*GAppInfo, uris: [*c]GList, context: [*c]GAppLaunchContext, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_app_info_launch_uris_finish(appinfo: ?*GAppInfo, result: ?*GAsyncResult, @"error": [*c][*c]GError) gboolean;

pub extern fn g_list_free_full(list: [*c]GList, free_func: GDestroyNotify) void;

pub extern fn g_path_get_basename(file_name: [*c]const gchar) [*c]gchar;

pub fn g_set_object(arg_object_ptr: [*c][*c]GObject, arg_new_object: [*c]GObject) callconv(.c) gboolean {
    var object_ptr = arg_object_ptr;
    _ = &object_ptr;
    var new_object = arg_new_object;
    _ = &new_object;
    var old_object: [*c]GObject = object_ptr.*;
    _ = &old_object;
    if (old_object == new_object) return @as(c_int, 0);
    if (@as(?*anyopaque, @ptrCast(@alignCast(new_object))) != @as(?*anyopaque, null)) {
        _ = g_object_ref(@ptrCast(@alignCast(new_object)));
    }
    object_ptr.* = new_object;
    if (@as(?*anyopaque, @ptrCast(@alignCast(old_object))) != @as(?*anyopaque, null)) {
        g_object_unref(@ptrCast(@alignCast(old_object)));
    }
    return @intFromBool(!(@as(c_int, 0) != 0));
}

pub extern fn g_string_append_printf(string: [*c]GString, format: [*c]const gchar, ...) void;

pub extern fn g_string_free(string: [*c]GString, free_segment: gboolean) [*c]gchar;

pub extern fn g_string_new(init: [*c]const gchar) [*c]GString;

pub extern fn g_subprocess_launcher_setenv(self: ?*GSubprocessLauncher, variable: [*c]const gchar, value: [*c]const gchar, overwrite: gboolean) void;

pub extern fn g_subprocess_launcher_unsetenv(self: ?*GSubprocessLauncher, variable: [*c]const gchar) void;

pub extern fn g_uri_escape_string(unescaped: [*c]const u8, reserved_chars_allowed: [*c]const u8, allow_utf8: gboolean) [*c]u8;

pub fn GDK_IS_TOPLEVEL(arg_ptr: gpointer) callconv(.c) gboolean {
    var ptr = arg_ptr;
    _ = &ptr;
    return blk: {
        var _inst: [*c]GTypeInstance = @ptrCast(@alignCast(ptr));
        _ = &_inst;
        var _t: GType = gdk_toplevel_get_type();
        _ = &_t;
        var _r: gboolean = undefined;
        _ = &_r;
        if (!(_inst != null)) {
            _r = @as(c_int, 0);
        } else if ((_inst.*.f_g_class != null) and (_inst.*.f_g_class.?.f_g_type == _t)) {
            _r = @intFromBool(!(@as(c_int, 0) != 0));
        } else {
            _r = g_type_check_instance_is_a(_inst, _t);
        }
        break :blk _r;
    };
}

pub fn GDK_TOPLEVEL(arg_ptr: gpointer) callconv(.c) ?*GdkToplevel {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GdkToplevel, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), gdk_toplevel_get_type())))))));
}

pub fn GTK_NATIVE(arg_ptr: gpointer) callconv(.c) ?*GtkNative {
    var ptr = arg_ptr;
    _ = &ptr;
    return @as(?*GtkNative, @ptrCast(@alignCast(@as(?*anyopaque, @ptrCast(@alignCast(g_type_check_instance_cast(@ptrCast(@alignCast(ptr)), gtk_native_get_type())))))));
}

pub const GTK_PHASE_CAPTURE: c_int = 1;

pub const GTK_RESPONSE_CANCEL: c_int = -6;

pub const G_BUS_TYPE_SESSION: c_int = 2;

pub const G_DBUS_ERROR_ACCESS_DENIED: c_int = 9;

pub const GdkModifierType = c_uint;

pub const GdkSurface = @import("gdk4").Surface;

pub const GdkToplevel = @import("gdk4").Toplevel;

pub const GtkEventController = @import("gtk4").EventController;

pub const GtkEventControllerKey = @import("gtk4").EventControllerKey;

pub const GtkPopover = @import("gtk4").Popover;

pub extern fn g_dbus_connection_set_exit_on_close(connection: ?*GDBusConnection, exit_on_close: gboolean) void;

pub extern fn g_dbus_method_invocation_return_dbus_error(invocation: ?*GDBusMethodInvocation, error_name: [*c]const gchar, error_message: [*c]const gchar) void;

pub extern fn g_main_context_find_source_by_id(context: ?*GMainContext, source_id: guint) [*c]GSource;

pub extern fn g_main_loop_new(context: ?*GMainContext, is_running: gboolean) ?*GMainLoop;

pub extern fn g_main_loop_quit(loop: ?*GMainLoop) void;

pub extern fn g_main_loop_run(loop: ?*GMainLoop) void;

pub extern fn g_main_loop_unref(loop: ?*GMainLoop) void;

pub extern fn g_unix_signal_add(signum: gint, handler: GSourceFunc, user_data: gpointer) guint;

pub extern fn g_variant_new_array(child_type: ?*const GVariantType, children: [*c]const ?*GVariant, n_children: gsize) ?*GVariant;

pub extern fn gdk_set_allowed_backends(backends: [*c]const u8) void;

pub extern fn gdk_toplevel_set_startup_id(toplevel: ?*GdkToplevel, startup_id: [*c]const u8) void;

pub extern fn gdk_wayland_toplevel_get_type() GType;

pub extern fn gdk_wayland_toplevel_set_transient_for_exported(toplevel: ?*GdkToplevel, parent_handle_str: [*c]const u8) gboolean;

pub extern fn gtk_box_set_spacing(box: [*c]GtkBox, spacing: c_int) void;

pub extern fn gtk_dialog_add_button(dialog: [*c]GtkDialog, button_text: [*c]const u8, response_id: c_int) [*c]GtkWidget;

pub extern fn gtk_dialog_new() [*c]GtkWidget;

pub extern fn gtk_dialog_set_default_response(dialog: [*c]GtkDialog, response_id: c_int) void;

pub extern fn gtk_event_controller_key_new() ?*GtkEventController;

pub extern fn gtk_event_controller_set_propagation_phase(controller: ?*GtkEventController, phase: GtkPropagationPhase) void;

pub extern fn gtk_init_check() gboolean;

pub extern fn gtk_label_new(str: [*c]const u8) [*c]GtkWidget;

pub extern fn gtk_label_set_max_width_chars(self: ?*GtkLabel, n_chars: c_int) void;

pub extern fn gtk_label_set_wrap(self: ?*GtkLabel, wrap: gboolean) void;

pub extern fn gtk_label_set_xalign(self: ?*GtkLabel, xalign: f32) void;

pub extern fn gtk_native_get_surface(self: ?*GtkNative) ?*GdkSurface;

pub extern fn gtk_popover_get_type() GType;

pub extern fn gtk_popover_popdown(popover: [*c]GtkPopover) void;

pub extern fn gtk_widget_add_controller(widget: [*c]GtkWidget, controller: ?*GtkEventController) void;

pub extern fn gtk_widget_add_css_class(widget: [*c]GtkWidget, css_class: [*c]const u8) void;

pub extern fn gtk_widget_get_ancestor(widget: [*c]GtkWidget, widget_type: GType) [*c]GtkWidget;

pub extern fn gtk_widget_realize(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_set_margin_bottom(widget: [*c]GtkWidget, margin: c_int) void;

pub extern fn gtk_widget_set_margin_end(widget: [*c]GtkWidget, margin: c_int) void;

pub extern fn gtk_widget_set_margin_start(widget: [*c]GtkWidget, margin: c_int) void;

pub extern fn gtk_widget_set_margin_top(widget: [*c]GtkWidget, margin: c_int) void;

pub extern fn gtk_window_get_focus(window: [*c]GtkWindow) [*c]GtkWidget;

pub extern fn gtk_window_present(window: [*c]GtkWindow) void;

pub extern fn gtk_window_set_default_size(window: [*c]GtkWindow, width: c_int, height: c_int) void;

pub extern fn gtk_window_set_focus(window: [*c]GtkWindow, focus: [*c]GtkWidget) void;

pub extern fn gtk_window_set_modal(window: [*c]GtkWindow, modal: gboolean) void;

pub extern fn gtk_window_set_title(window: [*c]GtkWindow, title: [*c]const u8) void;

pub const G_BUS_NAME_OWNER_FLAGS_NONE: c_int = 0;

pub const G_DBUS_ERROR_INVALID_ARGS: c_int = 16;

pub extern fn g_bus_own_name_on_connection(connection: ?*GDBusConnection, name: [*c]const gchar, flags: GBusNameOwnerFlags, name_acquired_handler: GBusNameAcquiredCallback, name_lost_handler: GBusNameLostCallback, user_data: gpointer, user_data_free_func: GDestroyNotify) guint;

pub extern fn g_bus_unown_name(owner_id: guint) void;

pub extern fn g_dbus_method_invocation_return_error(invocation: ?*GDBusMethodInvocation, domain: GQuark, code: gint, format: [*c]const gchar, ...) void;

pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;

pub const GDestroyNotify = ?*const fn (data: gpointer) callconv(.c) void;

pub const GMainLoop = @import("glib2").MainLoop;

pub const GConnectFlags = c_uint;

pub const GClosureNotify = ?*const fn (data: gpointer, closure: ?*GClosure) callconv(.c) void;

pub const struct__GDBusInterfaceVTable = extern struct {
    method_call: GDBusInterfaceMethodCallFunc = null,
    get_property: GDBusInterfaceGetPropertyFunc = null,
    set_property: GDBusInterfaceSetPropertyFunc = null,
    padding: [8]gpointer = @import("std").mem.zeroes([8]gpointer),
};

pub const GBusType = c_int;

pub const GBusNameWatcherFlags = c_uint;

pub const GBusNameVanishedCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GBusNameAppearedCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, name_owner: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GDBusCallFlags = c_uint;

pub const GAsyncReadyCallback = ?*const fn (source_object: [*c]GObject, res: ?*GAsyncResult, data: gpointer) callconv(.c) void;

pub const GDBusInterfaceInfo = @import("gio2").DBusInterfaceInfo;

pub const GDBusSignalCallback = ?*const fn (connection: ?*GDBusConnection, sender_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, signal_name: [*c]const gchar, parameters: ?*GVariant, user_data: gpointer) callconv(.c) void;

pub const GDBusSignalFlags = c_uint;

pub const GHashFunc = ?*const fn (key: gconstpointer) callconv(.c) guint;

pub const GEqualFunc = ?*const fn (a: gconstpointer, b: gconstpointer) callconv(.c) gboolean;

pub extern fn g_strdup(str: [*c]const gchar) [*c]gchar;

pub const guint32 = c_uint;

pub const GdkPaintable = @import("gdk4").Paintable;

pub extern fn gdk_paintable_get_type() GType;

pub const struct__GDesktopAppInfo = opaque {};

pub const GtkDropDown = @import("gtk4").DropDown;

pub extern fn gtk_drop_down_get_type() GType;

pub extern fn gtk_picture_get_type() GType;

pub const GtkPicture = @import("gtk4").Picture;

pub extern fn g_list_model_get_type() GType;

pub const GFileQueryInfoFlags = c_uint;

pub const GUriFlags = c_uint;

pub const GtkExpression = @import("gtk4").Expression;

pub const GtkContentFit = c_uint;

pub const GDBusMessage = @import("gio2").DBusMessage;

pub const GFileSetContentsFlags = c_uint;

pub const gint32 = c_int;

pub const __pid_t = c_int;

pub const GQuark = guint32;

pub const GFileMonitorFlags = c_uint;

pub const GKeyFileFlags = c_uint;

pub const GSettingsBackend = @import("gio2").SettingsBackend;

pub const GtkSettings = @import("gtk4").Settings;

pub const GClosure = @import("gobject2").Closure;

pub const GSignalMatchType = c_uint;

pub const GSubprocessFlags = c_uint;

pub const GSourceFunc = ?*const fn (user_data: gpointer) callconv(.c) gboolean;

pub const cups_dest_cb_t = ?*const fn (user_data: ?*anyopaque, flags: c_uint, dest: [*c]cups_dest_t) callconv(.c) c_int;

pub const cups_ptype_t = c_uint;

pub const struct_cups_dest_s = extern struct {
    name: [*c]u8 = null,
    instance: [*c]u8 = null,
    is_default: c_int = 0,
    num_options: c_int = 0,
    options: [*c]cups_option_t = null,
};

pub const struct__cups_dinfo_s = opaque {};

pub const struct_cups_option_s = extern struct {
    name: [*c]u8 = null,
    value: [*c]u8 = null,
};

pub const struct_cups_size_s = extern struct {
    media: [128]u8 = @import("std").mem.zeroes([128]u8),
    width: c_int = 0,
    length: c_int = 0,
    bottom: c_int = 0,
    left: c_int = 0,
    right: c_int = 0,
    top: c_int = 0,
};

pub const guchar = u8;

pub const GFileCreateFlags = c_uint;

pub const GOutputStreamSpliceFlags = c_uint;

pub const struct__http_s = opaque {};

pub const ipp_tag_t = enum_ipp_tag_e;

pub const struct__ipp_attribute_s = opaque {};

pub extern fn g_string_append_len(string: [*c]GString, val: [*c]const gchar, len: gssize) [*c]GString;

pub extern fn gdk_toplevel_get_type() GType;

pub const GtkNative = @import("gtk4").Native;

pub extern fn gtk_native_get_type() GType;

pub const GSource = @import("glib2").Source;

pub const GMainContext = @import("glib2").MainContext;

pub const GtkPropagationPhase = c_uint;

pub const GBusNameOwnerFlags = c_uint;

pub const GBusNameAcquiredCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GBusNameLostCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GDBusInterfaceGetPropertyFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, property_name: [*c]const gchar, @"error": [*c][*c]GError, user_data: gpointer) callconv(.c) ?*GVariant;

pub const GDBusInterfaceMethodCallFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, invocation: ?*GDBusMethodInvocation, user_data: gpointer) callconv(.c) void;

pub const GDBusInterfaceSetPropertyFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, property_name: [*c]const gchar, value: ?*GVariant, @"error": [*c][*c]GError, user_data: gpointer) callconv(.c) gboolean;

pub const enum_ipp_tag_e = c_int;

pub extern fn g_hash_table_contains(hash_table: ?*GHashTable, key: gconstpointer) gboolean;

pub extern fn strcmp(__s1: [*c]const u8, __s2: [*c]const u8) c_int;

pub extern fn strchr(__s: [*c]const u8, __c: c_int) [*c]u8;

pub extern fn strlen(__s: [*c]const u8) usize;

pub extern fn g_variant_is_of_type(value: ?*GVariant, @"type": ?*const GVariantType) gboolean;

pub extern fn fcntl(__fd: c_int, __cmd: c_int, ...) c_int;

pub extern fn g_hash_table_size(hash_table: ?*GHashTable) guint;

pub extern fn g_variant_iter_next(iter: [*c]GVariantIter, format_string: [*c]const gchar, ...) gboolean;

pub extern fn g_malloc0(usize) ?*anyopaque;

pub extern fn g_ascii_strtoull([*c]const u8, [*c][*c]u8, c_uint) u64;

pub extern fn g_string_append_c([*c]GString, u8) [*c]GString;

pub extern fn g_hash_table_add(?*GHashTable, ?*anyopaque) c_int;

pub extern fn g_variant_new_byte(u8) ?*GVariant;

pub fn cast(comptime T: type, value: anytype) T {
    if (@TypeOf(value) == @TypeOf(null)) return null;
    return @ptrCast(@alignCast(@constCast(value)));
}

/// Drop an owned reference and clear its slot before callbacks can run.
pub fn clear(slot: anytype, destroy: anytype) void {
    const value = slot.*;
    slot.* = null;
    if (value != null) destroy(@ptrCast(@alignCast(value)));
}

pub fn items(array: [*c]GPtrArray) []?*anyopaque {
    if (array.*.f_len == 0) return &.{};
    const data: [*]?*anyopaque = @ptrCast(@alignCast(array.*.f_pdata));
    return data[0..array.*.f_len];
}

// Obtain platform-dependent libc layouts from the target's headers.

const platform = @import("pearl_libc");
