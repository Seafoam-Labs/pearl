//! Narrow Linux C ABI for the optional GTK4/VTE feasibility fixture.
//! Signatures checked against GTK 4.24 and VTE 0.84 public headers. No C bridge.
//! Production bindings should share Coral's existing GTK module instances.
pub const Object = opaque {};
pub const Callback = *const fn () callconv(.c) void;
pub extern "c" fn gtk_init_check() c_int;
pub extern "c" fn gtk_window_new() *Object;
pub extern "c" fn gtk_window_set_title(*Object, [*:0]const u8) void;
pub extern "c" fn gtk_window_set_default_size(*Object, c_int, c_int) void;
pub extern "c" fn gtk_window_set_child(*Object, ?*Object) void;
pub extern "c" fn gtk_window_present(*Object) void;
pub extern "c" fn gtk_window_destroy(*Object) void;
pub extern "c" fn gtk_widget_set_visible(*Object, c_int) void;
pub extern "c" fn gtk_widget_set_hexpand(*Object, c_int) void;
pub extern "c" fn gtk_widget_set_vexpand(*Object, c_int) void;
pub extern "c" fn gtk_widget_grab_focus(*Object) c_int;
pub extern "c" fn gtk_widget_get_mapped(*Object) c_int;
pub extern "c" fn gtk_widget_get_width(*Object) c_int;
pub extern "c" fn gtk_widget_get_height(*Object) c_int;
pub extern "c" fn gtk_widget_get_display(*Object) *Object;
pub extern "c" fn gtk_box_new(c_int, c_int) *Object;
pub extern "c" fn gtk_box_append(*Object, *Object) void;
pub extern "c" fn gtk_label_new([*:0]const u8) *Object;
pub extern "c" fn gtk_widget_insert_action_group(*Object, [*:0]const u8, ?*Object) void;
pub extern "c" fn gtk_widget_activate_action_variant(*Object, [*:0]const u8, ?*Object) c_int;
pub extern "c" fn g_simple_action_group_new() *Object;
pub extern "c" fn g_simple_action_new([*:0]const u8, ?*const anyopaque) *Object;
pub extern "c" fn g_action_map_add_action(*Object, *Object) void;
pub extern "c" fn gdk_display_get_clipboard(*Object) *Object;
pub extern "c" fn gdk_clipboard_set_text(*Object, [*:0]const u8) void;
pub extern "c" fn g_object_ref_sink(*Object) *Object;
pub extern "c" fn g_object_unref(*Object) void;
pub extern "c" fn g_signal_connect_data(*Object, [*:0]const u8, Callback, ?*anyopaque, ?*const anyopaque, c_uint) c_ulong;
pub extern "c" fn g_main_context_iteration(?*Object, c_int) c_int;
pub extern "c" fn g_usleep(c_ulong) void;
pub extern "c" fn g_thread_new([*:0]const u8, *const fn (?*anyopaque) callconv(.c) ?*anyopaque, ?*anyopaque) *Object;
pub extern "c" fn g_thread_join(*Object) ?*anyopaque;
pub extern "c" fn g_free(?*anyopaque) void;
pub extern "c" fn g_error_free(*Object) void;
pub extern "c" fn vte_get_major_version() c_uint;
pub extern "c" fn vte_get_minor_version() c_uint;
pub extern "c" fn vte_get_micro_version() c_uint;
pub extern "c" fn vte_terminal_new() *Object;
pub extern "c" fn vte_terminal_set_pty(*Object, ?*Object) void;
pub extern "c" fn vte_pty_new_foreign_sync(c_int, ?*Object, *?*Object) ?*Object;
pub extern "c" fn vte_terminal_set_scrollback_lines(*Object, c_long) void;
pub extern "c" fn vte_terminal_set_allow_hyperlink(*Object, c_int) void;
pub extern "c" fn vte_terminal_set_enable_sixel(*Object, c_int) void;
pub extern "c" fn vte_terminal_set_audible_bell(*Object, c_int) void;
pub extern "c" fn vte_terminal_get_text_format(*Object, c_int) ?[*:0]u8;
pub extern "c" fn vte_terminal_get_row_count(*Object) c_long;
pub extern "c" fn vte_terminal_get_column_count(*Object) c_long;
pub extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;

pub fn connect(object: *Object, name: [*:0]const u8, callback: anytype, data: ?*anyopaque) void {
    _ = g_signal_connect_data(object, name, @ptrCast(callback), data, null, 0);
}
