pub const ext = @import("ext.zig");
const polkitagent = @This();

const std = @import("std");
const compat = @import("compat");
const polkit = @import("polkit1");
const gio = @import("gio2");
const gobject = @import("gobject2");
const glib = @import("glib2");
const gmodule = @import("gmodule2");
/// `polkitagent.Listener` is an abstract base class used for implementing authentication
/// agents. To implement an authentication agent, simply subclass `polkitagent.Listener` and
/// implement the `initiate_authentication` and `initiate_authentication_finish` methods.
///
/// Typically authentication agents use `polkitagent.Session` to
/// authenticate users (via passwords) and communicate back the
/// authentication result to the PolicyKit daemon.
///
/// To register a `polkitagent.Listener` with the PolicyKit daemon, use
/// `polkitagent.Listener.register` or
/// `polkitagent.Listener.registerWithOptions`.
pub const Listener = extern struct {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkitagent.ListenerClass;
    f_parent_instance: gobject.Object,

    pub const virtual_methods = struct {
        /// Called on a registered authentication agent (see
        /// `polkitagent.Listener.register`) when the user owning the session
        /// needs to prove he is one of the identities listed in `identities`.
        ///
        /// When the user is done authenticating (for example by dismissing an
        /// authentication dialog or by successfully entering a password or
        /// otherwise proving the user is one of the identities in
        /// `identities`), `callback` will be invoked. The caller then calls
        /// `polkitagent.Listener.initiateAuthenticationFinish` to get the
        /// result.
        ///
        /// `polkitagent.Listener` derived subclasses imlementing this method
        /// <emphasis>MUST</emphasis> not ignore `cancellable`; callers of this
        /// function can and will use it. Additionally, `callback` must be
        /// invoked in the <link
        /// linkend="g-main-context-push-thread-default">thread-default main
        /// loop</link> of the thread that this method is called from.
        pub const initiate_authentication = struct {
            pub fn call(p_class: anytype, p_listener: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_action_id: [*:0]const u8, p_message: [*:0]const u8, p_icon_name: [*:0]const u8, p_details: *polkit.Details, p_cookie: [*:0]const u8, p_identities: *glib.List, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void {
                return gobject.ext.as(Listener.Class, p_class).f_initiate_authentication.?(gobject.ext.as(Listener, p_listener), p_action_id, p_message, p_icon_name, p_details, p_cookie, p_identities, p_cancellable, p_callback, p_user_data);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_listener: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_action_id: [*:0]const u8, p_message: [*:0]const u8, p_icon_name: [*:0]const u8, p_details: *polkit.Details, p_cookie: [*:0]const u8, p_identities: *glib.List, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) callconv(.c) void) void {
                gobject.ext.as(Listener.Class, p_class).f_initiate_authentication = @ptrCast(p_implementation);
            }
        };

        /// Finishes an authentication request from the PolicyKit daemon, see
        /// `polkitagent.Listener.initiateAuthentication` for details.
        pub const initiate_authentication_finish = struct {
            pub fn call(p_class: anytype, p_listener: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int {
                return gobject.ext.as(Listener.Class, p_class).f_initiate_authentication_finish.?(gobject.ext.as(Listener, p_listener), p_res, p_error);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_listener: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) callconv(.c) c_int) void {
                gobject.ext.as(Listener.Class, p_class).f_initiate_authentication_finish = @ptrCast(p_implementation);
            }
        };
    };

    pub const properties = struct {};

    pub const signals = struct {};

    /// Unregisters `listener`.
    extern fn polkit_agent_listener_unregister(p_registration_handle: ?*anyopaque) void;
    pub const unregister = polkit_agent_listener_unregister;

    /// Called on a registered authentication agent (see
    /// `polkitagent.Listener.register`) when the user owning the session
    /// needs to prove he is one of the identities listed in `identities`.
    ///
    /// When the user is done authenticating (for example by dismissing an
    /// authentication dialog or by successfully entering a password or
    /// otherwise proving the user is one of the identities in
    /// `identities`), `callback` will be invoked. The caller then calls
    /// `polkitagent.Listener.initiateAuthenticationFinish` to get the
    /// result.
    ///
    /// `polkitagent.Listener` derived subclasses imlementing this method
    /// <emphasis>MUST</emphasis> not ignore `cancellable`; callers of this
    /// function can and will use it. Additionally, `callback` must be
    /// invoked in the <link
    /// linkend="g-main-context-push-thread-default">thread-default main
    /// loop</link> of the thread that this method is called from.
    extern fn polkit_agent_listener_initiate_authentication(p_listener: *Listener, p_action_id: [*:0]const u8, p_message: [*:0]const u8, p_icon_name: [*:0]const u8, p_details: *polkit.Details, p_cookie: [*:0]const u8, p_identities: *glib.List, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const initiateAuthentication = polkit_agent_listener_initiate_authentication;

    /// Finishes an authentication request from the PolicyKit daemon, see
    /// `polkitagent.Listener.initiateAuthentication` for details.
    extern fn polkit_agent_listener_initiate_authentication_finish(p_listener: *Listener, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const initiateAuthenticationFinish = polkit_agent_listener_initiate_authentication_finish;

    /// Registers `listener` with the PolicyKit daemon as an authentication
    /// agent for `subject`. This is implemented by registering a D-Bus
    /// object at `object_path` on the unique name assigned by the system
    /// message bus.
    ///
    /// Whenever the PolicyKit daemon needs to authenticate a processes
    /// that is related to `subject`, the methods
    /// `polkitagent.Listener.initiateAuthentication` and
    /// `polkitagent.Listener.initiateAuthenticationFinish` will be
    /// invoked on `listener`.
    ///
    /// Note that registration of an authentication agent can fail; for
    /// example another authentication agent may already be registered for
    /// `subject`.
    ///
    /// Note that the calling thread is blocked until a reply is received.
    extern fn polkit_agent_listener_register(p_listener: *Listener, p_flags: polkitagent.RegisterFlags, p_subject: *polkit.Subject, p_object_path: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*anyopaque;
    pub const register = polkit_agent_listener_register;

    /// Like `polkitagent.Listener.register` but takes options to influence registration. See the
    /// <link linkend="eggdbus-method-org.freedesktop.PolicyKit1.Authority.RegisterAuthenticationAgentWithOptions">`RegisterAuthenticationAgentWithOptions`</link> D-Bus method for details.
    extern fn polkit_agent_listener_register_with_options(p_listener: *Listener, p_flags: polkitagent.RegisterFlags, p_subject: *polkit.Subject, p_object_path: [*:0]const u8, p_options: ?*glib.Variant, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*anyopaque;
    pub const registerWithOptions = polkit_agent_listener_register_with_options;

    extern fn polkit_agent_listener_get_type() usize;
    pub const getGObjectType = polkit_agent_listener_get_type;

    extern fn g_object_ref(p_self: *polkitagent.Listener) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkitagent.Listener) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Listener, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// The `polkitagent.Session` class is an abstraction used for interacting with the
/// native authentication system (for example PAM) for obtaining authorizations.
/// This class is typically used together with instances that are derived from
/// the `polkitagent.Listener` abstract base class.
///
/// To perform the actual authentication, `polkitagent.Session` uses a trusted suid helper.
/// The authentication conversation is done through a pipe. This is transparent; the user
/// only need to handle the
/// `polkitagent.Session.signals.request`,
/// `polkitagent.Session.signals.show`-info,
/// `polkitagent.Session.signals.show`-error and
/// `polkitagent.Session.signals.completed`
/// signals and invoke `polkitagent.Session.response` in response to requests.
///
/// If the user successfully authenticates, the authentication helper will invoke
/// a method on the PolicyKit daemon (see `polkit.Authority.authenticationAgentResponseSync`)
/// with the given `cookie`. Upon receiving a positive response from the PolicyKit daemon (via
/// the authentication helper), the `polkitagent.Session.signals.completed` signal will be emitted
/// with the `gained_authorization` paramter set to `TRUE`.
///
/// If the user is unable to authenticate, the `polkitagent.Session.signals.completed` signal will
/// be emitted with the `gained_authorization` paramter set to `FALSE`.
pub const Session = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkitagent.SessionClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The cookie obtained from the PolicyKit daemon
        pub const cookie = struct {
            pub const name = "cookie";

            pub const Type = ?[*:0]u8;
        };

        /// The identity to authenticate.
        pub const identity = struct {
            pub const name = "identity";

            pub const Type = ?*polkit.Identity;
        };
    };

    pub const signals = struct {
        /// Emitted when the authentication session has been completed or
        /// cancelled. The `gained_authorization` parameter is `TRUE` only if
        /// the user successfully authenticated.
        ///
        /// Upon receiving this signal, the user should free `session` using `gobject.Object.unref`.
        pub const completed = struct {
            pub const name = "completed";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_gained_authorization: c_int, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Session, p_instance))),
                    gobject.signalLookup("completed", Session.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// Emitted when the user is requested to answer a question.
        ///
        /// When the response has been collected from the user, call `polkitagent.Session.response`.
        pub const request = struct {
            pub const name = "request";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_request: [*:0]u8, p_echo_on: c_int, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Session, p_instance))),
                    gobject.signalLookup("request", Session.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// Emitted when there is information related to an error condition to be displayed to the user.
        pub const show_error = struct {
            pub const name = "show-error";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_text: [*:0]u8, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Session, p_instance))),
                    gobject.signalLookup("show-error", Session.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// Emitted when there is information to be displayed to the user.
        pub const show_info = struct {
            pub const name = "show-info";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_text: [*:0]u8, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Session, p_instance))),
                    gobject.signalLookup("show-info", Session.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };
    };

    /// Creates a new authentication session.
    ///
    /// The caller should connect to the
    /// `polkitagent.Session.signals.request`,
    /// `polkitagent.Session.signals.show`-info,
    /// `polkitagent.Session.signals.show`-error and
    /// `polkitagent.Session.signals.completed`
    /// signals and then call `polkitagent.Session.initiate` to initiate the authentication session.
    extern fn polkit_agent_session_new(p_identity: *polkit.Identity, p_cookie: [*:0]const u8) *polkitagent.Session;
    pub const new = polkit_agent_session_new;

    /// Cancels an authentication session. This will make `session` emit the `polkitagent.Session.signals.completed`
    /// signal.
    extern fn polkit_agent_session_cancel(p_session: *Session) void;
    pub const cancel = polkit_agent_session_cancel;

    /// Initiates the authentication session. Before calling this method,
    /// make sure to connect to the various signals. The signals will be
    /// emitted in the <link
    /// linkend="g-main-context-push-thread-default">thread-default main
    /// loop</link> that this method is invoked from.
    ///
    /// Use `polkitagent.Session.cancel` to cancel the session.
    extern fn polkit_agent_session_initiate(p_session: *Session) void;
    pub const initiate = polkit_agent_session_initiate;

    /// Function for providing response to requests received
    /// via the `polkitagent.Session.signals.request` signal.
    extern fn polkit_agent_session_response(p_session: *Session, p_response: [*:0]const u8) void;
    pub const response = polkit_agent_session_response;

    extern fn polkit_agent_session_get_type() usize;
    pub const getGObjectType = polkit_agent_session_get_type;

    extern fn g_object_ref(p_self: *polkitagent.Session) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkitagent.Session) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Session, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// `polkitagent.TextListener` is an `polkitagent.Listener` implementation
/// that interacts with the user using a textual interface.
pub const TextListener = opaque {
    pub const Parent = polkitagent.Listener;
    pub const Implements = [_]type{gio.Initable};
    pub const Class = opaque {
        pub const Instance = TextListener;
    };
    pub const virtual_methods = struct {};

    pub const properties = struct {
        pub const delay = struct {
            pub const name = "delay";

            pub const Type = c_uint;
        };

        pub const use_alternate_buffer = struct {
            pub const name = "use-alternate-buffer";

            pub const Type = c_int;
        };

        pub const use_color = struct {
            pub const name = "use-color";

            pub const Type = c_int;
        };
    };

    pub const signals = struct {
        pub const tty_attrs_changed = struct {
            pub const name = "tty-attrs-changed";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), p_object: c_int, P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(TextListener, p_instance))),
                    gobject.signalLookup("tty-attrs-changed", TextListener.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };
    };

    /// Creates a new `polkitagent.TextListener` for authenticating the user
    /// via an textual interface on the controlling terminal
    /// (e.g. <filename>/dev/tty</filename>). This can fail if e.g. the
    /// current process has no controlling terminal.
    extern fn polkit_agent_text_listener_new(p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkitagent.TextListener;
    pub const new = polkit_agent_text_listener_new;

    extern fn polkit_agent_text_listener_get_type() usize;
    pub const getGObjectType = polkit_agent_text_listener_get_type;

    extern fn g_object_ref(p_self: *polkitagent.TextListener) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkitagent.TextListener) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *TextListener, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// VFuncs that authentication agents needs to implement.
pub const ListenerClass = extern struct {
    pub const Instance = polkitagent.Listener;

    /// The parent class.
    f_parent_class: gobject.ObjectClass,
    /// Handle an authentication request, see `polkitagent.Listener.initiateAuthentication`.
    f_initiate_authentication: ?*const fn (p_listener: *polkitagent.Listener, p_action_id: [*:0]const u8, p_message: [*:0]const u8, p_icon_name: [*:0]const u8, p_details: *polkit.Details, p_cookie: [*:0]const u8, p_identities: *glib.List, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) callconv(.c) void,
    /// Finishes handling an authentication request, see `polkitagent.Listener.initiateAuthenticationFinish`.
    f_initiate_authentication_finish: ?*const fn (p_listener: *polkitagent.Listener, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) callconv(.c) c_int,
    f__polkit_reserved0: ?*const fn () callconv(.c) void,
    f__polkit_reserved1: ?*const fn () callconv(.c) void,
    f__polkit_reserved2: ?*const fn () callconv(.c) void,
    f__polkit_reserved3: ?*const fn () callconv(.c) void,
    f__polkit_reserved4: ?*const fn () callconv(.c) void,
    f__polkit_reserved5: ?*const fn () callconv(.c) void,
    f__polkit_reserved6: ?*const fn () callconv(.c) void,
    f__polkit_reserved7: ?*const fn () callconv(.c) void,

    pub fn as(p_instance: *ListenerClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const SessionClass = opaque {
    pub const Instance = polkitagent.Session;

    pub fn as(p_instance: *SessionClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Flags used in `polkitagent.Listener.register`.
pub const RegisterFlags = packed struct(c_uint) {
    run_in_thread: bool = false,
    _padding1: bool = false,
    _padding2: bool = false,
    _padding3: bool = false,
    _padding4: bool = false,
    _padding5: bool = false,
    _padding6: bool = false,
    _padding7: bool = false,
    _padding8: bool = false,
    _padding9: bool = false,
    _padding10: bool = false,
    _padding11: bool = false,
    _padding12: bool = false,
    _padding13: bool = false,
    _padding14: bool = false,
    _padding15: bool = false,
    _padding16: bool = false,
    _padding17: bool = false,
    _padding18: bool = false,
    _padding19: bool = false,
    _padding20: bool = false,
    _padding21: bool = false,
    _padding22: bool = false,
    _padding23: bool = false,
    _padding24: bool = false,
    _padding25: bool = false,
    _padding26: bool = false,
    _padding27: bool = false,
    _padding28: bool = false,
    _padding29: bool = false,
    _padding30: bool = false,
    _padding31: bool = false,

    pub const flags_none: RegisterFlags = @bitCast(@as(c_uint, 0));
    pub const flags_run_in_thread: RegisterFlags = @bitCast(@as(c_uint, 1));
    extern fn polkit_agent_register_flags_get_type() usize;
    pub const getGObjectType = polkit_agent_register_flags_get_type;

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// (deprecated)
extern fn polkit_agent_register_listener(p_listener: *polkitagent.Listener, p_subject: *polkit.Subject, p_object_path: [*:0]const u8, p_error: ?*?*glib.Error) c_int;
pub const registerListener = polkit_agent_register_listener;

test {
    @setEvalBranchQuota(100_000);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ext);
}
