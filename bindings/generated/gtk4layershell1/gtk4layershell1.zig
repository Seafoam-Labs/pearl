pub const ext = @import("ext.zig");
const gtk4layershell = @This();

const std = @import("std");
const compat = @import("compat");
const gtk = @import("gtk4");
const gsk = @import("gsk4");
const graphene = @import("graphene1");
const gobject = @import("gobject2");
const glib = @import("glib2");
const gdk = @import("gdk4");
const cairo = @import("cairo1");
const pangocairo = @import("pangocairo1");
const pango = @import("pango1");
const harfbuzz = @import("harfbuzz0");
const freetype2 = @import("freetype22");
const gio = @import("gio2");
const gmodule = @import("gmodule2");
const gdkpixbuf = @import("gdkpixbuf2");
pub const Edge = enum(c_int) {
    left = 0,
    right = 1,
    top = 2,
    bottom = 3,
    entry_number = 4,
    _,

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const KeyboardMode = enum(c_int) {
    none = 0,
    exclusive = 1,
    on_demand = 2,
    entry_number = 3,
    _,

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const Layer = enum(c_int) {
    background = 0,
    bottom = 1,
    top = 2,
    overlay = 3,
    entry_number = 4,
    _,

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// When auto exclusive zone is enabled, exclusive zone is automatically set to the
/// size of the `window` + relevant margin. To disable auto exclusive zone, just set the
/// exclusive zone to 0 or any other fixed value.
///
/// NOTE: you can control the auto exclusive zone by changing the margin on the non-anchored
/// edge. This behavior is specific to gtk4-layer-shell and not part of the underlying protocol
extern fn gtk_layer_auto_exclusive_zone_enable(p_window: *gtk.Window) void;
pub const autoExclusiveZoneEnable = gtk_layer_auto_exclusive_zone_enable;

extern fn gtk_layer_auto_exclusive_zone_is_enabled(p_window: *gtk.Window) c_int;
pub const autoExclusiveZoneIsEnabled = gtk_layer_auto_exclusive_zone_is_enabled;

extern fn gtk_layer_get_anchor(p_window: *gtk.Window, p_edge: gtk4layershell.Edge) c_int;
pub const getAnchor = gtk_layer_get_anchor;

extern fn gtk_layer_get_exclusive_zone(p_window: *gtk.Window) c_int;
pub const getExclusiveZone = gtk_layer_get_exclusive_zone;

extern fn gtk_layer_get_keyboard_mode(p_window: *gtk.Window) gtk4layershell.KeyboardMode;
pub const getKeyboardMode = gtk_layer_get_keyboard_mode;

extern fn gtk_layer_get_layer(p_window: *gtk.Window) gtk4layershell.Layer;
pub const getLayer = gtk_layer_get_layer;

extern fn gtk_layer_get_major_version() c_uint;
pub const getMajorVersion = gtk_layer_get_major_version;

extern fn gtk_layer_get_margin(p_window: *gtk.Window, p_edge: gtk4layershell.Edge) c_int;
pub const getMargin = gtk_layer_get_margin;

extern fn gtk_layer_get_micro_version() c_uint;
pub const getMicroVersion = gtk_layer_get_micro_version;

extern fn gtk_layer_get_minor_version() c_uint;
pub const getMinorVersion = gtk_layer_get_minor_version;

/// NOTE: To get which monitor the surface is actually on, use
/// `gdk.Display.getMonitorAtSurface`.
extern fn gtk_layer_get_monitor(p_window: *gtk.Window) ?*gdk.Monitor;
pub const getMonitor = gtk_layer_get_monitor;

/// NOTE: this function does not return ownership of the string. Do not free the returned string.
/// Future calls into the library may invalidate the returned string.
extern fn gtk_layer_get_namespace(p_window: *gtk.Window) [*:0]const u8;
pub const getNamespace = gtk_layer_get_namespace;

/// May block for a Wayland roundtrip the first time it's called.
extern fn gtk_layer_get_protocol_version() c_uint;
pub const getProtocolVersion = gtk_layer_get_protocol_version;

extern fn gtk_layer_get_respect_close(p_window: *gtk.Window) c_int;
pub const getRespectClose = gtk_layer_get_respect_close;

extern fn gtk_layer_get_zwlr_layer_surface_v1(p_window: *gtk.Window) ?*anyopaque;
pub const getZwlrLayerSurfaceV1 = gtk_layer_get_zwlr_layer_surface_v1;

/// Set the `window` up to be a layer surface once it is mapped. this must be called before
/// the `window` is realized.
extern fn gtk_layer_init_for_window(p_window: *gtk.Window) void;
pub const initForWindow = gtk_layer_init_for_window;

extern fn gtk_layer_is_layer_window(p_window: *gtk.Window) c_int;
pub const isLayerWindow = gtk_layer_is_layer_window;

/// May block for a Wayland roundtrip the first time it's called.
extern fn gtk_layer_is_supported() c_int;
pub const isSupported = gtk_layer_is_supported;

/// Set whether `window` should be anchored to `edge`.
/// - If two perpendicular edges are anchored, the surface with be anchored to that corner
/// - If two opposite edges are anchored, the window will be stretched across the screen in that direction
///
/// Default is `FALSE` for each `gtk4layershell.Edge`
extern fn gtk_layer_set_anchor(p_window: *gtk.Window, p_edge: gtk4layershell.Edge, p_anchor_to_edge: c_int) void;
pub const setAnchor = gtk_layer_set_anchor;

/// Has no effect unless the surface is anchored to an edge. Requests that the compositor
/// does not place other surfaces within the given exclusive zone of the anchored edge.
/// For example, a panel can request to not be covered by maximized windows. See
/// wlr-layer-shell-unstable-v1.xml for details.
///
/// Default is 0
extern fn gtk_layer_set_exclusive_zone(p_window: *gtk.Window, p_exclusive_zone: c_int) void;
pub const setExclusiveZone = gtk_layer_set_exclusive_zone;

/// Sets if/when `window` should receive keyboard events from the compositor, see
/// GtkLayerShellKeyboardMode for details. To control mouse/touch interactivity use input regions,
/// see [`@"61"`](https://github.com/wmww/gtk4-layer-shell/issues/61) for details.
///
/// Default is `GTK_LAYER_SHELL_KEYBOARD_MODE_NONE`
extern fn gtk_layer_set_keyboard_mode(p_window: *gtk.Window, p_mode: gtk4layershell.KeyboardMode) void;
pub const setKeyboardMode = gtk_layer_set_keyboard_mode;

/// Set the "layer" on which the surface appears(controls if it is over top of or below other surfaces). The layer may
/// be changed on-the-fly in the current version of the layer shell protocol, but on compositors that only support an
/// older version the `window` is remapped so the change can take effect.
///
/// Default is `GTK_LAYER_SHELL_LAYER_TOP`
extern fn gtk_layer_set_layer(p_window: *gtk.Window, p_layer: gtk4layershell.Layer) void;
pub const setLayer = gtk_layer_set_layer;

/// Set the margin for a specific `edge` of a `window`. Effects both surface's distance from
/// the edge and its exclusive zone size(if auto exclusive zone enabled).
///
/// Default is 0 for each `gtk4layershell.Edge`
extern fn gtk_layer_set_margin(p_window: *gtk.Window, p_edge: gtk4layershell.Edge, p_margin_size: c_int) void;
pub const setMargin = gtk_layer_set_margin;

/// Set the output for the window to be placed on, or `NULL` to let the compositor choose.
/// If the window is currently mapped, it will get remapped so the change can take effect.
///
/// Default is `NULL`
extern fn gtk_layer_set_monitor(p_window: *gtk.Window, p_monitor: ?*gdk.Monitor) void;
pub const setMonitor = gtk_layer_set_monitor;

/// Set the "namespace" of the surface.
///
/// No one is quite sure what this is for, but it probably should be something generic
/// ("panel", "osk", etc). The `name_space` string is copied, and caller maintains
/// ownership of original. If the window is currently mapped, it will get remapped so
/// the change can take effect.
///
/// Default is "gtk4-layer-shell" (which will be used if set to `NULL`)
extern fn gtk_layer_set_namespace(p_window: *gtk.Window, p_name_space: ?[*:0]const u8) void;
pub const setNamespace = gtk_layer_set_namespace;

/// Compositors may send the `zwlr_layer_surface_v1.closed` event in some cases (such as
/// when an output is destroyed). Prior to v1.3 this always triggered a GTK `close-request`
/// signal, which would destroy the window if not intercepted by application code. In v1.3+
/// this behavior is disabled by default, and can be turned back on by calling this
/// function with `TRUE`. To handle the `.closed` event without destroying your window
/// turn respect_close on and connect a `close-request` listener that returns `TRUE`.
extern fn gtk_layer_set_respect_close(p_window: *gtk.Window, p_respect_close: c_int) void;
pub const setRespectClose = gtk_layer_set_respect_close;

test {
    @setEvalBranchQuota(100_000);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ext);
}
