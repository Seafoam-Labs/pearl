pub const ext = @import("ext.zig");
const gtk4sessionlock = @This();

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
/// An instance of the object used to control locking the screen.
/// Multiple instances can exist at once, but only one can be locked at a time.
pub const Instance = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = gtk4sessionlock.InstanceClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {};

    pub const signals = struct {
        /// The ::failed signal is fired when the lock could not be acquired.
        pub const failed = struct {
            pub const name = "failed";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Instance, p_instance))),
                    gobject.signalLookup("failed", Instance.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// The ::locked signal is fired when the screen is successfully locked.
        pub const locked = struct {
            pub const name = "locked";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Instance, p_instance))),
                    gobject.signalLookup("locked", Instance.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// The ::monitor signal is fired once for each monitor that exists when a lock is started, and then whenever a new
        /// monitor is detected during the lock. You generally want to call `gtk4sessionlock.Instance.assignWindowToMonitor`
        /// once in the handler for this signal with a newly created window and the given monitor.
        ///
        /// This API does not directly tell you when a monitor is removed (GTK APIs can be used for that), however the window you
        /// send to `gtk4sessionlock.Instance.assignWindowToMonitor` will be automatically unmapped and dereferenced when its
        /// monitor is removed or the screen is unlocked.
        pub const monitor = struct {
            pub const name = "monitor";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_monitor: *gdk.Monitor, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Instance, p_instance))),
                    gobject.signalLookup("monitor", Instance.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// The ::unlocked signal is fired when the session is unlocked, which may have been caused by a call to
        /// `gtk4sessionlock.Instance.unlock` or by the compositor.
        pub const unlocked = struct {
            pub const name = "unlocked";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Instance, p_instance))),
                    gobject.signalLookup("unlocked", Instance.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };
    };

    extern fn gtk_session_lock_instance_new() *gtk4sessionlock.Instance;
    pub const new = gtk_session_lock_instance_new;

    /// This must be called with a different unrealized window once for each monitor immediately after calling
    /// `gtk_session_lock_lock`. Hiding a window that is active on a monitor or not letting a window be resized by the
    /// library is not allowed (may result in a Wayland protocol error). The window will be unmapped and `gtk.Window.destroy`
    /// called on it when the current lock ends.
    extern fn gtk_session_lock_instance_assign_window_to_monitor(p_self: *Instance, p_window: *gtk.Window, p_monitor: *gdk.Monitor) void;
    pub const assignWindowToMonitor = gtk_session_lock_instance_assign_window_to_monitor;

    /// Returns if this instance currently holds a lock.
    extern fn gtk_session_lock_instance_is_locked(p_self: *Instance) c_int;
    pub const isLocked = gtk_session_lock_instance_is_locked;

    /// Lock the screen. This should be called before assigning any windows to monitors. If this function fails the ::failed
    /// signal is emitted, if it succeeds the ::locked signal is emitted. The ::failed signal may be emitted before the
    /// function returns (for example, if another `gtk4sessionlock.Instance` holds a lock) or later (if another process holds a
    /// lock). The only case where neither signal is triggered is if the instance is already locked.
    extern fn gtk_session_lock_instance_lock(p_self: *Instance) c_int;
    pub const lock = gtk_session_lock_instance_lock;

    /// If the screen is locked by this instance unlocks it and fires ::unlocked. Otherwise has no effect
    extern fn gtk_session_lock_instance_unlock(p_self: *Instance) void;
    pub const unlock = gtk_session_lock_instance_unlock;

    extern fn gtk_session_lock_instance_get_type() usize;
    pub const getGObjectType = gtk_session_lock_instance_get_type;

    extern fn g_object_ref(p_self: *gtk4sessionlock.Instance) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *gtk4sessionlock.Instance) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Instance, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const InstanceClass = extern struct {
    pub const Instance = gtk4sessionlock.Instance;

    f_parent_class: gobject.ObjectClass,

    pub fn as(p_instance: *InstanceClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// May block for a Wayland roundtrip the first time it's called.
extern fn gtk_session_lock_is_supported() c_int;
pub const isSupported = gtk_session_lock_is_supported;

test {
    @setEvalBranchQuota(100_000);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ext);
}
