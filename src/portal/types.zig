const ffi = @import("ffi.zig");

pub const struct_Portal = extern struct {
    bus: ?*ffi.GDBusConnection = null,
    loop: ?*ffi.GMainLoop = null,
    owner: [*c]u8 = null,
    requests: ?*ffi.GHashTable = null,
    print_tokens: ?*ffi.GHashTable = null,
    inhibitors: ffi.gpointer = null,
    settings: ?*ffi.GHashTable = null,
    policy: ?*ffi.GKeyFile = null,
    policy_monitor: [*c]ffi.GFileMonitor = null,
    managed_policy: [*c]ffi.GSettings = null,
    interface_settings: [*c]ffi.GSettings = null,
    interface_settings_changed: ffi.gulong = 0,
    owner_watch: ffi.guint = 0,
    stopping: ffi.gboolean = 0,
    notifications: ?*ffi.GHashTable = null,
    notification_busy: ?*ffi.GHashTable = null,
    notification_owner: [*c]u8 = null,
    notification_watch: ffi.guint = 0,
    notification_signal: ffi.guint = 0,
};

pub const Portal = struct_Portal;

pub const struct_Request = extern struct {
    refs: ffi.gint = 0,
    portal: [*c]Portal = null,
    handle: [*c]u8 = null,
    sender: [*c]u8 = null,
    app_id: [*c]u8 = null,
    parent: [*c]u8 = null,
    method: [*c]u8 = null,
    invocation: ?*ffi.GDBusMethodInvocation = null,
    cancel: [*c]ffi.GCancellable = null,
    dialog: [*c]ffi.GtkDialog = null,
    options: ?*ffi.GVariant = null,
    registration: ffi.guint = 0,
    finished: ffi.gboolean = 0,
    data: ffi.gpointer = null,
    destroy_data: ffi.GDestroyNotify = null,
};

pub const Request = struct_Request;
