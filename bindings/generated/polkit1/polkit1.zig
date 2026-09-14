pub const ext = @import("ext.zig");
const polkit = @This();

const std = @import("std");
const compat = @import("compat");
const gio = @import("gio2");
const gobject = @import("gobject2");
const glib = @import("glib2");
const gmodule = @import("gmodule2");
/// Object used to encapsulate a registered action.
pub const ActionDescription = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkit.ActionDescriptionClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {};

    pub const signals = struct {};

    /// Gets the action id for `action_description`.
    extern fn polkit_action_description_get_action_id(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getActionId = polkit_action_description_get_action_id;

    /// Get the value of the annotation with `key`.
    extern fn polkit_action_description_get_annotation(p_action_description: *ActionDescription, p_key: [*:0]const u8) ?[*:0]const u8;
    pub const getAnnotation = polkit_action_description_get_annotation;

    /// Gets the keys of annotations defined in `action_description`.
    extern fn polkit_action_description_get_annotation_keys(p_action_description: *ActionDescription) [*]const [*:0]const u8;
    pub const getAnnotationKeys = polkit_action_description_get_annotation_keys;

    /// Gets the description used for `action_description`.
    extern fn polkit_action_description_get_description(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getDescription = polkit_action_description_get_description;

    /// Gets the icon name for `action_description`, if any.
    extern fn polkit_action_description_get_icon_name(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getIconName = polkit_action_description_get_icon_name;

    /// Gets the implicit authorization for `action_description` used for
    /// subjects in active sessions on a local console.
    extern fn polkit_action_description_get_implicit_active(p_action_description: *ActionDescription) polkit.ImplicitAuthorization;
    pub const getImplicitActive = polkit_action_description_get_implicit_active;

    /// Gets the implicit authorization for `action_description` used for
    /// any subject.
    extern fn polkit_action_description_get_implicit_any(p_action_description: *ActionDescription) polkit.ImplicitAuthorization;
    pub const getImplicitAny = polkit_action_description_get_implicit_any;

    /// Gets the implicit authorization for `action_description` used for
    /// subjects in inactive sessions on a local console.
    extern fn polkit_action_description_get_implicit_inactive(p_action_description: *ActionDescription) polkit.ImplicitAuthorization;
    pub const getImplicitInactive = polkit_action_description_get_implicit_inactive;

    /// Gets the message used for `action_description`.
    extern fn polkit_action_description_get_message(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getMessage = polkit_action_description_get_message;

    /// Gets the vendor name for `action_description`, if any.
    extern fn polkit_action_description_get_vendor_name(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getVendorName = polkit_action_description_get_vendor_name;

    /// Gets the vendor URL for `action_description`, if any.
    extern fn polkit_action_description_get_vendor_url(p_action_description: *ActionDescription) [*:0]const u8;
    pub const getVendorUrl = polkit_action_description_get_vendor_url;

    extern fn polkit_action_description_get_type() usize;
    pub const getGObjectType = polkit_action_description_get_type;

    extern fn g_object_ref(p_self: *polkit.ActionDescription) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.ActionDescription) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *ActionDescription, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// `PolkitAuthority` is used for checking whether a given subject is
/// authorized to perform a given action. Typically privileged system
/// daemons or suid helpers will use this when handling requests from
/// untrusted clients.
///
/// User sessions can register an authentication agent with the
/// authority. This is used for requests from untrusted clients where
/// system policy requires that the user needs to acknowledge (through
/// proving he is the user or the administrator) a given action. See
/// `PolkitAgentListener` and `PolkitAgentSession` for details.
pub const Authority = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{ gio.AsyncInitable, gio.Initable };
    pub const Class = polkit.AuthorityClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The features of the currently used Authority backend.
        pub const backend_features = struct {
            pub const name = "backend-features";

            pub const Type = polkit.AuthorityFeatures;
        };

        /// The name of the currently used Authority backend.
        pub const backend_name = struct {
            pub const name = "backend-name";

            pub const Type = ?[*:0]u8;
        };

        pub const backend_version = struct {
            pub const name = "backend-version";

            pub const Type = ?[*:0]u8;
        };

        /// The unique name of the owner of the org.freedesktop.PolicyKit1
        /// D-Bus service or `NULL` if there is no owner. Connect to the
        /// `gobject.Object.signals.notify` signal to track changes to this property.
        pub const owner = struct {
            pub const name = "owner";

            pub const Type = ?[*:0]u8;
        };
    };

    pub const signals = struct {
        /// Emitted when actions and/or authorizations change
        pub const changed = struct {
            pub const name = "changed";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Authority, p_instance))),
                    gobject.signalLookup("changed", Authority.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };

        /// Emitted when sessions change
        pub const sessions_changed = struct {
            pub const name = "sessions-changed";

            pub fn connect(p_instance: anytype, comptime P_Data: type, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data: P_Data, p_options: gobject.ext.ConnectSignalOptions(P_Data)) c_ulong {
                return gobject.signalConnectClosureById(
                    @ptrCast(@alignCast(gobject.ext.as(Authority, p_instance))),
                    gobject.signalLookup("sessions-changed", Authority.getGObjectType()),
                    glib.quarkFromString(p_options.detail orelse null),
                    gobject.CClosure.new(@ptrCast(p_callback), p_data, @ptrCast(p_options.destroyData)),
                    @intFromBool(p_options.after),
                );
            }
        };
    };

    /// (deprecated)
    extern fn polkit_authority_get() *polkit.Authority;
    pub const get = polkit_authority_get;

    /// Asynchronously gets a reference to the authority.
    ///
    /// This is an asynchronous failable function. When the result is
    /// ready, `callback` will be invoked in the <link
    /// linkend="g-main-context-push-thread-default">thread-default main
    /// loop</link> of the thread you are calling this method from and you
    /// can use `polkit.Authority.getFinish` to get the result. See
    /// `polkit.Authority.getSync` for the synchronous version.
    extern fn polkit_authority_get_async(p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const getAsync = polkit_authority_get_async;

    /// Finishes an operation started with `polkit.Authority.getAsync`.
    extern fn polkit_authority_get_finish(p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*polkit.Authority;
    pub const getFinish = polkit_authority_get_finish;

    /// Synchronously gets a reference to the authority.
    ///
    /// This is a synchronous failable function - the calling thread is
    /// blocked until a reply is received. See `polkit.Authority.getAsync`
    /// for the asynchronous version.
    extern fn polkit_authority_get_sync(p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.Authority;
    pub const getSync = polkit_authority_get_sync;

    /// Asynchronously provide response that `identity` successfully authenticated
    /// for the authentication request identified by `cookie`.
    ///
    /// This function is only used by the privileged bits of an authentication agent.
    /// It will fail if the caller is not sufficiently privileged (typically uid 0).
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.authenticationAgentResponseFinish` to get the
    /// result of the operation.
    extern fn polkit_authority_authentication_agent_response(p_authority: *Authority, p_cookie: [*:0]const u8, p_identity: *polkit.Identity, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const authenticationAgentResponse = polkit_authority_authentication_agent_response;

    /// Finishes providing response from an authentication agent.
    extern fn polkit_authority_authentication_agent_response_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const authenticationAgentResponseFinish = polkit_authority_authentication_agent_response_finish;

    /// Provide response that `identity` successfully authenticated for the
    /// authentication request identified by `cookie`. See `polkit.Authority.authenticationAgentResponse`
    /// for limitations on who is allowed is to call this method.
    ///
    /// The calling thread is blocked until a reply is received. See
    /// `polkit.Authority.authenticationAgentResponse` for the
    /// asynchronous version.
    extern fn polkit_authority_authentication_agent_response_sync(p_authority: *Authority, p_cookie: [*:0]const u8, p_identity: *polkit.Identity, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const authenticationAgentResponseSync = polkit_authority_authentication_agent_response_sync;

    /// Asynchronously provide response that `identity` successfully authenticated
    /// for the authentication request identified by `cookie` as requested by `subject`.
    ///
    /// This function is only used by the socket-activated agent helper, running as uiid
    /// 0, and will fail otherwise. The requesting process is identified via `subject`
    /// which will contain a PID FD identifying the process.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.authenticationAgentResponseFinish` to get the
    /// result of the operation.
    extern fn polkit_authority_authentication_agent_response_with_subject(p_authority: *Authority, p_cookie: [*:0]const u8, p_identity: *polkit.Identity, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const authenticationAgentResponseWithSubject = polkit_authority_authentication_agent_response_with_subject;

    /// Provide response that `identity` successfully authenticated for the
    /// authentication request identified by `cookie`. See `polkit.Authority.authenticationAgentResponseWithSubject`
    /// for limitations on who is allowed is to call this method.
    ///
    /// The calling thread is blocked until a reply is received. See
    /// `polkit.Authority.authenticationAgentResponseWithSubject` for the
    /// asynchronous version.
    extern fn polkit_authority_authentication_agent_response_with_subject_sync(p_authority: *Authority, p_cookie: [*:0]const u8, p_identity: *polkit.Identity, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const authenticationAgentResponseWithSubjectSync = polkit_authority_authentication_agent_response_with_subject_sync;

    /// Asynchronously checks if `subject` is authorized to perform the action represented
    /// by `action_id`.
    ///
    /// Note that `POLKIT_CHECK_AUTHORIZATION_FLAGS_ALLOW_USER_INTERACTION`
    /// <emphasis>SHOULD</emphasis> be passed <emphasis>ONLY</emphasis> if
    /// the event that triggered the authorization check is stemming from
    /// an user action, e.g. the user pressing a button or attaching a
    /// device.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.checkAuthorizationFinish` to get the result of
    /// the operation.
    ///
    /// Known keys in `details` include <literal>polkit.message</literal>
    /// and <literal>polkit.gettext_domain</literal> that can be used to
    /// override the message shown to the user. See the documentation for
    /// the <link linkend="eggdbus-method-org.freedesktop.PolicyKit1.Authority.CheckAuthorization">D-Bus method</link> for more details.
    ///
    /// If `details` is non-empty then the request will fail with
    /// `POLKIT_ERROR_FAILED` unless the process doing the check itself is
    /// sufficiently authorized (e.g. running as uid 0).
    extern fn polkit_authority_check_authorization(p_authority: *Authority, p_subject: *polkit.Subject, p_action_id: [*:0]const u8, p_details: ?*polkit.Details, p_flags: polkit.CheckAuthorizationFlags, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const checkAuthorization = polkit_authority_check_authorization;

    /// Finishes checking if a subject is authorized for an action.
    extern fn polkit_authority_check_authorization_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*polkit.AuthorizationResult;
    pub const checkAuthorizationFinish = polkit_authority_check_authorization_finish;

    /// Checks if `subject` is authorized to perform the action represented
    /// by `action_id`.
    ///
    /// Note that `POLKIT_CHECK_AUTHORIZATION_FLAGS_ALLOW_USER_INTERACTION`
    /// <emphasis>SHOULD</emphasis> be passed <emphasis>ONLY</emphasis> if
    /// the event that triggered the authorization check is stemming from
    /// an user action, e.g. the user pressing a button or attaching a
    /// device.
    ///
    /// Note the calling thread is blocked until a reply is received. You
    /// should therefore <emphasis>NEVER</emphasis> do this from a GUI
    /// thread or a daemon service thread when using the
    /// `POLKIT_CHECK_AUTHORIZATION_FLAGS_ALLOW_USER_INTERACTION` flag. This
    /// is because it may potentially take minutes (or even hours) for the
    /// operation to complete because it involves waiting for the user to
    /// authenticate.
    ///
    /// Known keys in `details` include <literal>polkit.message</literal>
    /// and <literal>polkit.gettext_domain</literal> that can be used to
    /// override the message shown to the user. See the documentation for
    /// the <link linkend="eggdbus-method-org.freedesktop.PolicyKit1.Authority.CheckAuthorization">D-Bus method</link> for more details.
    extern fn polkit_authority_check_authorization_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_action_id: [*:0]const u8, p_details: ?*polkit.Details, p_flags: polkit.CheckAuthorizationFlags, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.AuthorizationResult;
    pub const checkAuthorizationSync = polkit_authority_check_authorization_sync;

    /// Asynchronously retrieves all registered actions.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call `polkit.Authority.enumerateActionsFinish`
    /// to get the result of the operation.
    extern fn polkit_authority_enumerate_actions(p_authority: *Authority, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const enumerateActions = polkit_authority_enumerate_actions;

    /// Finishes retrieving all registered actions.
    extern fn polkit_authority_enumerate_actions_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*glib.List;
    pub const enumerateActionsFinish = polkit_authority_enumerate_actions_finish;

    /// Synchronously retrieves all registered actions - the calling thread
    /// is blocked until a reply is received. See
    /// `polkit.Authority.enumerateActions` for the asynchronous version.
    extern fn polkit_authority_enumerate_actions_sync(p_authority: *Authority, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*glib.List;
    pub const enumerateActionsSync = polkit_authority_enumerate_actions_sync;

    /// Asynchronously gets all temporary authorizations for `subject`.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.enumerateTemporaryAuthorizationsFinish` to get
    /// the result of the operation.
    extern fn polkit_authority_enumerate_temporary_authorizations(p_authority: *Authority, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const enumerateTemporaryAuthorizations = polkit_authority_enumerate_temporary_authorizations;

    /// Finishes retrieving all registered actions.
    extern fn polkit_authority_enumerate_temporary_authorizations_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*glib.List;
    pub const enumerateTemporaryAuthorizationsFinish = polkit_authority_enumerate_temporary_authorizations_finish;

    /// Synchronousky gets all temporary authorizations for `subject`.
    ///
    /// The calling thread is blocked until a reply is received. See
    /// `polkit.Authority.enumerateTemporaryAuthorizations` for the
    /// asynchronous version.
    extern fn polkit_authority_enumerate_temporary_authorizations_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*glib.List;
    pub const enumerateTemporaryAuthorizationsSync = polkit_authority_enumerate_temporary_authorizations_sync;

    /// Gets the features supported by the authority backend.
    extern fn polkit_authority_get_backend_features(p_authority: *Authority) polkit.AuthorityFeatures;
    pub const getBackendFeatures = polkit_authority_get_backend_features;

    /// Gets the name of the authority backend.
    extern fn polkit_authority_get_backend_name(p_authority: *Authority) [*:0]const u8;
    pub const getBackendName = polkit_authority_get_backend_name;

    /// Gets the version of the authority backend.
    extern fn polkit_authority_get_backend_version(p_authority: *Authority) [*:0]const u8;
    pub const getBackendVersion = polkit_authority_get_backend_version;

    /// The unique name on the system message bus of the owner of the name
    /// <literal>org.freedesktop.PolicyKit1</literal> or `NULL` if no-one
    /// currently owns the name. You may connect to the `gobject.Object.signals.notify`
    /// signal to track changes to the `PolkitAuthority.properties.owner` property.
    extern fn polkit_authority_get_owner(p_authority: *Authority) ?[*:0]u8;
    pub const getOwner = polkit_authority_get_owner;

    /// Asynchronously registers an authentication agent.
    ///
    /// Note that this should be called by the same effective UID which will be
    /// the real UID using the `PolkitAgentSession` API or otherwise calling
    /// `polkit.Authority.authenticationAgentResponse`.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.registerAuthenticationAgentFinish` to get the
    /// result of the operation.
    extern fn polkit_authority_register_authentication_agent(p_authority: *Authority, p_subject: *polkit.Subject, p_locale: [*:0]const u8, p_object_path: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const registerAuthenticationAgent = polkit_authority_register_authentication_agent;

    /// Finishes registering an authentication agent.
    extern fn polkit_authority_register_authentication_agent_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const registerAuthenticationAgentFinish = polkit_authority_register_authentication_agent_finish;

    /// Registers an authentication agent.
    ///
    /// Note that this should be called by the same effective UID which will be
    /// the real UID using the `PolkitAgentSession` API or otherwise calling
    /// `polkit.Authority.authenticationAgentResponse`.
    ///
    /// The calling thread is blocked
    /// until a reply is received. See
    /// `polkit.Authority.registerAuthenticationAgent` for the
    /// asynchronous version.
    extern fn polkit_authority_register_authentication_agent_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_locale: [*:0]const u8, p_object_path: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const registerAuthenticationAgentSync = polkit_authority_register_authentication_agent_sync;

    /// Asynchronously registers an authentication agent.
    ///
    /// Note that this should be called by the same effective UID which will be
    /// the real UID using the `PolkitAgentSession` API or otherwise calling
    /// `polkit.Authority.authenticationAgentResponse`.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.registerAuthenticationAgentWithOptionsFinish` to get the
    /// result of the operation.
    extern fn polkit_authority_register_authentication_agent_with_options(p_authority: *Authority, p_subject: *polkit.Subject, p_locale: [*:0]const u8, p_object_path: [*:0]const u8, p_options: ?*glib.Variant, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const registerAuthenticationAgentWithOptions = polkit_authority_register_authentication_agent_with_options;

    /// Finishes registering an authentication agent.
    extern fn polkit_authority_register_authentication_agent_with_options_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const registerAuthenticationAgentWithOptionsFinish = polkit_authority_register_authentication_agent_with_options_finish;

    /// Registers an authentication agent.
    ///
    /// Note that this should be called by the same effective UID which will be
    /// the real UID using the `PolkitAgentSession` API or otherwise calling
    /// `polkit.Authority.authenticationAgentResponse`.
    ///
    /// The calling thread is blocked
    /// until a reply is received. See
    /// `polkit.Authority.registerAuthenticationAgentWithOptions` for the
    /// asynchronous version.
    extern fn polkit_authority_register_authentication_agent_with_options_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_locale: [*:0]const u8, p_object_path: [*:0]const u8, p_options: ?*glib.Variant, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const registerAuthenticationAgentWithOptionsSync = polkit_authority_register_authentication_agent_with_options_sync;

    /// Asynchronously revoke a temporary authorization.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.revokeTemporaryAuthorizationByIdFinish` to
    /// get the result of the operation.
    extern fn polkit_authority_revoke_temporary_authorization_by_id(p_authority: *Authority, p_id: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const revokeTemporaryAuthorizationById = polkit_authority_revoke_temporary_authorization_by_id;

    /// Finishes revoking a temporary authorization by id.
    extern fn polkit_authority_revoke_temporary_authorization_by_id_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const revokeTemporaryAuthorizationByIdFinish = polkit_authority_revoke_temporary_authorization_by_id_finish;

    /// Synchronously revokes a temporary authorization.
    ///
    /// The calling thread is blocked until a reply is received. See
    /// `polkit.Authority.revokeTemporaryAuthorizationById` for the
    /// asynchronous version.
    extern fn polkit_authority_revoke_temporary_authorization_by_id_sync(p_authority: *Authority, p_id: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const revokeTemporaryAuthorizationByIdSync = polkit_authority_revoke_temporary_authorization_by_id_sync;

    /// Asynchronously revokes all temporary authorizations for `subject`.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.revokeTemporaryAuthorizationsFinish` to get
    /// the result of the operation.
    extern fn polkit_authority_revoke_temporary_authorizations(p_authority: *Authority, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const revokeTemporaryAuthorizations = polkit_authority_revoke_temporary_authorizations;

    /// Finishes revoking temporary authorizations.
    extern fn polkit_authority_revoke_temporary_authorizations_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const revokeTemporaryAuthorizationsFinish = polkit_authority_revoke_temporary_authorizations_finish;

    /// Synchronously revokes all temporary authorization from `subject`.
    ///
    /// The calling thread is blocked until a reply is received. See
    /// `polkit.Authority.revokeTemporaryAuthorizations` for the
    /// asynchronous version.
    extern fn polkit_authority_revoke_temporary_authorizations_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const revokeTemporaryAuthorizationsSync = polkit_authority_revoke_temporary_authorizations_sync;

    /// Asynchronously unregisters an authentication agent.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.Authority.unregisterAuthenticationAgentFinish` to get
    /// the result of the operation.
    extern fn polkit_authority_unregister_authentication_agent(p_authority: *Authority, p_subject: *polkit.Subject, p_object_path: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const unregisterAuthenticationAgent = polkit_authority_unregister_authentication_agent;

    /// Finishes unregistering an authentication agent.
    extern fn polkit_authority_unregister_authentication_agent_finish(p_authority: *Authority, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const unregisterAuthenticationAgentFinish = polkit_authority_unregister_authentication_agent_finish;

    /// Unregisters an authentication agent. The calling thread is blocked
    /// until a reply is received. See
    /// `polkit.Authority.unregisterAuthenticationAgent` for the
    /// asynchronous version.
    extern fn polkit_authority_unregister_authentication_agent_sync(p_authority: *Authority, p_subject: *polkit.Subject, p_object_path: [*:0]const u8, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const unregisterAuthenticationAgentSync = polkit_authority_unregister_authentication_agent_sync;

    extern fn polkit_authority_get_type() usize;
    pub const getGObjectType = polkit_authority_get_type;

    extern fn g_object_ref(p_self: *polkit.Authority) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.Authority) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Authority, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// This class represents the result you get when checking for an authorization.
pub const AuthorizationResult = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkit.AuthorizationResultClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {};

    pub const signals = struct {};

    /// Creates a new `PolkitAuthorizationResult` object.
    extern fn polkit_authorization_result_new(p_is_authorized: c_int, p_is_challenge: c_int, p_details: ?*polkit.Details) *polkit.AuthorizationResult;
    pub const new = polkit_authorization_result_new;

    /// Gets the details about the result.
    extern fn polkit_authorization_result_get_details(p_result: *AuthorizationResult) ?*polkit.Details;
    pub const getDetails = polkit_authorization_result_get_details;

    /// Gets whether the authentication request was dismissed / canceled by the user.
    ///
    /// This method simply reads the value of the key/value pair in `details` with the
    /// key <literal>polkit.dismissed</literal>.
    extern fn polkit_authorization_result_get_dismissed(p_result: *AuthorizationResult) c_int;
    pub const getDismissed = polkit_authorization_result_get_dismissed;

    /// Gets whether the subject is authorized.
    ///
    /// If the authorization is temporary, use `polkit.AuthorizationResult.getTemporaryAuthorizationId`
    /// to get the opaque identifier for the temporary authorization.
    extern fn polkit_authorization_result_get_is_authorized(p_result: *AuthorizationResult) c_int;
    pub const getIsAuthorized = polkit_authorization_result_get_is_authorized;

    /// Gets whether the subject is authorized if more information is provided.
    extern fn polkit_authorization_result_get_is_challenge(p_result: *AuthorizationResult) c_int;
    pub const getIsChallenge = polkit_authorization_result_get_is_challenge;

    /// Gets whether authorization is retained if obtained via authentication. This can only be the case
    /// if `result` indicates that the subject can obtain authorization after challenge (cf.
    /// `polkit.AuthorizationResult.getIsChallenge`), e.g. when the subject is not already authorized (cf.
    /// `polkit.AuthorizationResult.getIsAuthorized`).
    ///
    /// If the subject is already authorized, use `polkit.AuthorizationResult.getTemporaryAuthorizationId`
    /// to check if the authorization is temporary.
    ///
    /// This method simply reads the value of the key/value pair in `details` with the
    /// key <literal>polkit.retains_authorization_after_challenge</literal>.
    extern fn polkit_authorization_result_get_retains_authorization(p_result: *AuthorizationResult) c_int;
    pub const getRetainsAuthorization = polkit_authorization_result_get_retains_authorization;

    /// Gets the opaque temporary authorization id for `result` if `result` indicates the
    /// subject is authorized and the authorization is temporary rather than one-shot or
    /// permanent.
    ///
    /// You can use this string together with the result from
    /// `polkit.Authority.enumerateTemporaryAuthorizations` to get more details
    /// about the temporary authorization or `polkit.Authority.revokeTemporaryAuthorizationById`
    /// to revoke the temporary authorization.
    ///
    /// If the subject is not authorized, use `polkit.AuthorizationResult.getRetainsAuthorization`
    /// to check if the authorization will be retained if obtained via authentication.
    ///
    /// This method simply reads the value of the key/value pair in `details` with the
    /// key <literal>polkit.temporary_authorization_id</literal>.
    extern fn polkit_authorization_result_get_temporary_authorization_id(p_result: *AuthorizationResult) ?[*:0]const u8;
    pub const getTemporaryAuthorizationId = polkit_authorization_result_get_temporary_authorization_id;

    extern fn polkit_authorization_result_get_type() usize;
    pub const getGObjectType = polkit_authorization_result_get_type;

    extern fn g_object_ref(p_self: *polkit.AuthorizationResult) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.AuthorizationResult) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *AuthorizationResult, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object used for passing details around.
pub const Details = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkit.DetailsClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {};

    pub const signals = struct {};

    /// Creates a new `PolkitDetails` object.
    extern fn polkit_details_new() *polkit.Details;
    pub const new = polkit_details_new;

    /// Gets a list of all keys on `details`.
    extern fn polkit_details_get_keys(p_details: *Details) ?[*][*:0]u8;
    pub const getKeys = polkit_details_get_keys;

    /// Inserts a copy of `key` and `value` on `details`.
    ///
    /// If `value` is `NULL`, the key will be removed.
    extern fn polkit_details_insert(p_details: *Details, p_key: [*:0]const u8, p_value: ?[*:0]const u8) void;
    pub const insert = polkit_details_insert;

    /// Gets the value for `key` on `details`.
    extern fn polkit_details_lookup(p_details: *Details, p_key: [*:0]const u8) ?[*:0]const u8;
    pub const lookup = polkit_details_lookup;

    extern fn polkit_details_get_type() usize;
    pub const getGObjectType = polkit_details_get_type;

    extern fn g_object_ref(p_self: *polkit.Details) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.Details) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Details, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// `PolkitPermission` is a `gio.Permission` implementation. It can be used
/// with e.g. `GtkLockButton`. See the `gio.Permission` documentation for
/// more information.
pub const Permission = opaque {
    pub const Parent = gio.Permission;
    pub const Implements = [_]type{ gio.AsyncInitable, gio.Initable };
    pub const Class = opaque {
        pub const Instance = Permission;
    };
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The action identifier to use for the permission.
        pub const action_id = struct {
            pub const name = "action-id";

            pub const Type = ?[*:0]u8;
        };

        /// The `PolkitSubject` to use for the permission. If not set during
        /// construction, it will be set to match the current process.
        pub const subject = struct {
            pub const name = "subject";

            pub const Type = ?*polkit.Subject;
        };
    };

    pub const signals = struct {};

    /// Creates a `gio.Permission` instance for the PolicyKit action
    /// `action_id`.
    ///
    /// When the operation is finished, `callback` will be invoked. You can
    /// then call `polkit.Permission.newFinish` to get the result of the
    /// operation.
    ///
    /// This is a asynchronous failable constructor. See
    /// `polkit.Permission.newSync` for the synchronous version.
    extern fn polkit_permission_new(p_action_id: [*:0]const u8, p_subject: ?*polkit.Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const new = polkit_permission_new;

    /// Finishes an operation started with `polkit.Permission.new`.
    extern fn polkit_permission_new_finish(p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*polkit.Permission;
    pub const newFinish = polkit_permission_new_finish;

    /// Creates a `gio.Permission` instance for the PolicyKit action
    /// `action_id`.
    ///
    /// This is a synchronous failable constructor. See
    /// `polkit.Permission.new` for the asynchronous version.
    extern fn polkit_permission_new_sync(p_action_id: [*:0]const u8, p_subject: ?*polkit.Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.Permission;
    pub const newSync = polkit_permission_new_sync;

    /// Gets the PolicyKit action identifier used for `permission`.
    extern fn polkit_permission_get_action_id(p_permission: *Permission) [*:0]const u8;
    pub const getActionId = polkit_permission_get_action_id;

    /// Gets the subject used for `permission`.
    extern fn polkit_permission_get_subject(p_permission: *Permission) *polkit.Subject;
    pub const getSubject = polkit_permission_get_subject;

    extern fn polkit_permission_get_type() usize;
    pub const getGObjectType = polkit_permission_get_type;

    extern fn g_object_ref(p_self: *polkit.Permission) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.Permission) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Permission, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object that represents a process owning a unique name on the system bus.
pub const SystemBusName = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{polkit.Subject};
    pub const Class = polkit.SystemBusNameClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The unique name on the system message bus.
        pub const name = struct {
            pub const name = "name";

            pub const Type = ?[*:0]u8;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitSystemBusName` for `name`.
    extern fn polkit_system_bus_name_new(p_name: [*:0]const u8) *polkit.Subject;
    pub const new = polkit_system_bus_name_new;

    /// Gets the unique system bus name for `system_bus_name`.
    extern fn polkit_system_bus_name_get_name(p_system_bus_name: *SystemBusName) [*:0]const u8;
    pub const getName = polkit_system_bus_name_get_name;

    /// Synchronously gets a `PolkitUnixProcess` object for `system_bus_name`
    /// - the calling thread is blocked until a reply is received.
    extern fn polkit_system_bus_name_get_process_sync(p_system_bus_name: *SystemBusName, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.Subject;
    pub const getProcessSync = polkit_system_bus_name_get_process_sync;

    /// Synchronously gets a `PolkitUnixUser` object for `system_bus_name`;
    /// the calling thread is blocked until a reply is received.
    extern fn polkit_system_bus_name_get_user_sync(p_system_bus_name: *SystemBusName, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.UnixUser;
    pub const getUserSync = polkit_system_bus_name_get_user_sync;

    /// Sets the unique system bus name for `system_bus_name`.
    extern fn polkit_system_bus_name_set_name(p_system_bus_name: *SystemBusName, p_name: [*:0]const u8) void;
    pub const setName = polkit_system_bus_name_set_name;

    extern fn polkit_system_bus_name_get_type() usize;
    pub const getGObjectType = polkit_system_bus_name_get_type;

    extern fn g_object_ref(p_self: *polkit.SystemBusName) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.SystemBusName) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *SystemBusName, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Object used to describe a temporary authorization.
pub const TemporaryAuthorization = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{};
    pub const Class = polkit.TemporaryAuthorizationClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {};

    pub const signals = struct {};

    /// Gets the action that `authorization` is for.
    extern fn polkit_temporary_authorization_get_action_id(p_authorization: *TemporaryAuthorization) [*:0]const u8;
    pub const getActionId = polkit_temporary_authorization_get_action_id;

    /// Gets the opaque identifier for `authorization`.
    extern fn polkit_temporary_authorization_get_id(p_authorization: *TemporaryAuthorization) [*:0]const u8;
    pub const getId = polkit_temporary_authorization_get_id;

    /// Gets the subject that `authorization` is for.
    extern fn polkit_temporary_authorization_get_subject(p_authorization: *TemporaryAuthorization) *polkit.Subject;
    pub const getSubject = polkit_temporary_authorization_get_subject;

    /// Gets the time when `authorization` will expire.
    ///
    /// (Note that the PolicyKit daemon is using monotonic time internally
    /// so the returned value may change if system time changes.)
    extern fn polkit_temporary_authorization_get_time_expires(p_authorization: *TemporaryAuthorization) u64;
    pub const getTimeExpires = polkit_temporary_authorization_get_time_expires;

    /// Gets the time when `authorization` was obtained.
    ///
    /// (Note that the PolicyKit daemon is using monotonic time internally
    /// so the returned value may change if system time changes.)
    extern fn polkit_temporary_authorization_get_time_obtained(p_authorization: *TemporaryAuthorization) u64;
    pub const getTimeObtained = polkit_temporary_authorization_get_time_obtained;

    extern fn polkit_temporary_authorization_get_type() usize;
    pub const getGObjectType = polkit_temporary_authorization_get_type;

    extern fn g_object_ref(p_self: *polkit.TemporaryAuthorization) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.TemporaryAuthorization) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *TemporaryAuthorization, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object representing a group identity on a UNIX system.
pub const UnixGroup = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{polkit.Identity};
    pub const Class = polkit.UnixGroupClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The UNIX group id.
        pub const gid = struct {
            pub const name = "gid";

            pub const Type = c_int;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitUnixGroup` object for `gid`.
    extern fn polkit_unix_group_new(p_gid: c_int) *polkit.Identity;
    pub const new = polkit_unix_group_new;

    /// Creates a new `PolkitUnixGroup` object for a group with the group name
    /// `name`.
    extern fn polkit_unix_group_new_for_name(p_name: [*:0]const u8, p_error: ?*?*glib.Error) ?*polkit.Identity;
    pub const newForName = polkit_unix_group_new_for_name;

    /// Gets the UNIX group id for `group`.
    extern fn polkit_unix_group_get_gid(p_group: *UnixGroup) c_int;
    pub const getGid = polkit_unix_group_get_gid;

    /// Sets `gid` for `group`.
    extern fn polkit_unix_group_set_gid(p_group: *UnixGroup, p_gid: c_int) void;
    pub const setGid = polkit_unix_group_set_gid;

    extern fn polkit_unix_group_get_type() usize;
    pub const getGObjectType = polkit_unix_group_get_type;

    extern fn g_object_ref(p_self: *polkit.UnixGroup) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.UnixGroup) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *UnixGroup, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object representing a netgroup identity on a UNIX system.
pub const UnixNetgroup = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{polkit.Identity};
    pub const Class = polkit.UnixNetgroupClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The NIS netgroup name.
        pub const name = struct {
            pub const name = "name";

            pub const Type = ?[*:0]u8;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitUnixNetgroup` object for `name`.
    extern fn polkit_unix_netgroup_new(p_name: [*:0]const u8) *polkit.Identity;
    pub const new = polkit_unix_netgroup_new;

    /// Gets the netgroup name for `group`.
    extern fn polkit_unix_netgroup_get_name(p_group: *UnixNetgroup) [*:0]const u8;
    pub const getName = polkit_unix_netgroup_get_name;

    /// Sets `name` for `group`.
    extern fn polkit_unix_netgroup_set_name(p_group: *UnixNetgroup, p_name: [*:0]const u8) void;
    pub const setName = polkit_unix_netgroup_set_name;

    extern fn polkit_unix_netgroup_get_type() usize;
    pub const getGObjectType = polkit_unix_netgroup_get_type;

    extern fn g_object_ref(p_self: *polkit.UnixNetgroup) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.UnixNetgroup) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *UnixNetgroup, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object for representing a UNIX process. In order to be reliable and
/// race-free, this requires support for PID File Descriptors in the kernel,
/// dbus-daemon/broker and systemd. With this functionality, we can reliably
/// track processes without risking PID reuse and race conditions, and compare
/// them.
///
/// NOTE: If PID FDs are not available, this object will fall back to using
/// PIDs, and this designed is now known broken; a mechanism to exploit a delay
/// in start time in the Linux kernel was identified.  Avoid
/// calling `polkit.Subject.equal` to compare two processes.
///
/// To uniquely identify processes, both the process id and the start
/// time of the process (a monotonic increasing value representing the
/// time since the kernel was started) is used.
///
/// NOTE: This object stores, and provides access to, the real UID of the
/// process.  That value can change over time (with set*uid*(2) and exec*(2)).
/// Checks whether an operation is allowed need to take care to use the UID
/// value as of the time when the operation was made (or, following the `open`
/// privilege check model, when the connection making the operation possible
/// was initiated).  That is usually done by initializing this with
/// `polkit.UnixProcess.newForOwner` with trusted data.
pub const UnixProcess = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{polkit.Subject};
    pub const Class = polkit.UnixProcessClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The start time of the process.
        pub const cgroupid = struct {
            pub const name = "cgroupid";

            pub const Type = u64;
        };

        /// The UNIX process controlling TTY.
        pub const ctty = struct {
            pub const name = "ctty";

            pub const Type = c_uint;
        };

        /// The UNIX group ids of the process.
        pub const gids = struct {
            pub const name = "gids";

            pub const Type = ?[*]*anyopaque;
        };

        /// The UNIX process id.
        pub const pid = struct {
            pub const name = "pid";

            pub const Type = c_int;
        };

        /// The UNIX process id file descriptor.
        pub const pidfd = struct {
            pub const name = "pidfd";

            pub const Type = c_int;
        };

        pub const pidfd_is_safe = struct {
            pub const name = "pidfd-is-safe";

            pub const Type = c_int;
        };

        /// The UNIX process' parent id file descriptor.
        pub const ppidfd = struct {
            pub const name = "ppidfd";

            pub const Type = c_int;
        };

        /// The start time of the process.
        pub const start_time = struct {
            pub const name = "start-time";

            pub const Type = u64;
        };

        /// The UNIX user id of the process or -1 if unknown.
        ///
        /// Note that this is the real user-id, not the effective user-id.
        pub const uid = struct {
            pub const name = "uid";

            pub const Type = c_int;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitUnixProcess` for `pid`.
    ///
    /// The uid and start time of the process will be looked up in using
    /// e.g. the <filename>/proc</filename> filesystem depending on the
    /// platform in use.
    extern fn polkit_unix_process_new(p_pid: c_int) *polkit.Subject;
    pub const new = polkit_unix_process_new;

    /// Creates a new `PolkitUnixProcess` object for `pid`, `start_time` and `uid`.
    extern fn polkit_unix_process_new_for_owner(p_pid: c_int, p_start_time: u64, p_uid: c_int) *polkit.Subject;
    pub const newForOwner = polkit_unix_process_new_for_owner;

    /// Creates a new `PolkitUnixProcess` object for `pid` and `start_time`.
    ///
    /// The uid of the process will be looked up in using e.g. the
    /// <filename>/proc</filename> filesystem depending on the platform in
    /// use.
    extern fn polkit_unix_process_new_full(p_pid: c_int, p_start_time: u64) *polkit.Subject;
    pub const newFull = polkit_unix_process_new_full;

    /// Creates a new `PolkitUnixProcess` object for `pidfd` and `uid`.
    extern fn polkit_unix_process_new_pidfd(p_pidfd: c_int, p_uid: c_int, p_gids: ?*glib.Array) *polkit.Subject;
    pub const newPidfd = polkit_unix_process_new_pidfd;

    /// Gets the cgroupid of `process`.
    extern fn polkit_unix_process_get_cgroupid(p_process: *UnixProcess) u64;
    pub const getCgroupid = polkit_unix_process_get_cgroupid;

    /// Gets the controlling TTY for `process`.
    extern fn polkit_unix_process_get_ctty(p_process: *UnixProcess) c_uint;
    pub const getCtty = polkit_unix_process_get_ctty;

    /// Gets the group ids for `process`. Note that this is the real group-ids,
    /// not the effective group-ids.
    extern fn polkit_unix_process_get_gids(p_process: *UnixProcess) ?*glib.Array;
    pub const getGids = polkit_unix_process_get_gids;

    /// (deprecated)
    extern fn polkit_unix_process_get_owner(p_process: *UnixProcess, p_error: ?*?*glib.Error) c_int;
    pub const getOwner = polkit_unix_process_get_owner;

    /// Gets the process id for `process`.
    extern fn polkit_unix_process_get_pid(p_process: *UnixProcess) c_int;
    pub const getPid = polkit_unix_process_get_pid;

    /// Gets the process id file descriptor for `process`.
    extern fn polkit_unix_process_get_pidfd(p_process: *UnixProcess) c_int;
    pub const getPidfd = polkit_unix_process_get_pidfd;

    /// Checks if the process id file descriptor for `process` is safe
    /// or if it was opened locally and thus vulnerable to reuse.
    extern fn polkit_unix_process_get_pidfd_is_safe(p_process: *UnixProcess) c_int;
    pub const getPidfdIsSafe = polkit_unix_process_get_pidfd_is_safe;

    /// Gets the process' parent id for `process`.
    extern fn polkit_unix_process_get_ppid(p_process: *UnixProcess) c_int;
    pub const getPpid = polkit_unix_process_get_ppid;

    /// Gets the process' parent id file descriptor for `process`.
    extern fn polkit_unix_process_get_ppidfd(p_process: *UnixProcess) c_int;
    pub const getPpidfd = polkit_unix_process_get_ppidfd;

    /// Gets the start time of `process`.
    extern fn polkit_unix_process_get_start_time(p_process: *UnixProcess) u64;
    pub const getStartTime = polkit_unix_process_get_start_time;

    /// Gets the user id for `process`. Note that this is the real user-id,
    /// not the effective user-id.
    ///
    /// NOTE: The UID may change over time, so the returned value may not match the
    /// current state of the underlying process; or the UID may have been set by
    /// `polkit.UnixProcess.newForOwner` or `polkit.UnixProcess.setUid`,
    /// in which case it may not correspond to the actual UID of the referenced
    /// process at all (at any point in time).
    extern fn polkit_unix_process_get_uid(p_process: *UnixProcess) c_int;
    pub const getUid = polkit_unix_process_get_uid;

    /// Sets the (real, not effective) group ids for `process`.
    extern fn polkit_unix_process_set_gids(p_process: *UnixProcess, p_gids: *glib.Array) void;
    pub const setGids = polkit_unix_process_set_gids;

    /// Sets `pid` for `process`.
    extern fn polkit_unix_process_set_pid(p_process: *UnixProcess, p_pid: c_int) void;
    pub const setPid = polkit_unix_process_set_pid;

    /// Sets `pidfd` for `process`.
    extern fn polkit_unix_process_set_pidfd(p_process: *UnixProcess, p_pidfd: c_int) void;
    pub const setPidfd = polkit_unix_process_set_pidfd;

    /// Set the start time of `process`.
    extern fn polkit_unix_process_set_start_time(p_process: *UnixProcess, p_start_time: u64) void;
    pub const setStartTime = polkit_unix_process_set_start_time;

    /// Sets the (real, not effective) user id for `process`.
    extern fn polkit_unix_process_set_uid(p_process: *UnixProcess, p_uid: c_int) void;
    pub const setUid = polkit_unix_process_set_uid;

    extern fn polkit_unix_process_get_type() usize;
    pub const getGObjectType = polkit_unix_process_get_type;

    extern fn g_object_ref(p_self: *polkit.UnixProcess) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.UnixProcess) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *UnixProcess, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object that represents an user session.
///
/// The session id is an opaque string obtained from ConsoleKit.
pub const UnixSession = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{ gio.AsyncInitable, gio.Initable, polkit.Subject };
    pub const Class = polkit.UnixSessionClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The UNIX process id to look up the session.
        pub const pid = struct {
            pub const name = "pid";

            pub const Type = c_int;
        };

        /// The UNIX session id.
        pub const session_id = struct {
            pub const name = "session-id";

            pub const Type = ?[*:0]u8;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitUnixSession` for `session_id`.
    extern fn polkit_unix_session_new(p_session_id: [*:0]const u8) *polkit.Subject;
    pub const new = polkit_unix_session_new;

    /// Asynchronously creates a new `PolkitUnixSession` object for the
    /// process with process id `pid`.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call
    /// `polkit.UnixSession.newForProcessFinish` to get the result of
    /// the operation.
    ///
    /// This method constructs the object asynchronously, for the synchronous and blocking version
    /// use `polkit.UnixSession.newForProcessSync`.
    extern fn polkit_unix_session_new_for_process(p_pid: c_int, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const newForProcess = polkit_unix_session_new_for_process;

    /// Finishes constructing a `PolkitSubject` for a process id.
    extern fn polkit_unix_session_new_for_process_finish(p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) ?*polkit.Subject;
    pub const newForProcessFinish = polkit_unix_session_new_for_process_finish;

    /// Creates a new `PolkitUnixSession` for the process with process id `pid`.
    ///
    /// This is a synchronous call - the calling thread is blocked until a
    /// reply is received. For the asynchronous version, see
    /// `polkit.UnixSession.newForProcess`.
    extern fn polkit_unix_session_new_for_process_sync(p_pid: c_int, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) ?*polkit.Subject;
    pub const newForProcessSync = polkit_unix_session_new_for_process_sync;

    /// Gets the session id for `session`.
    extern fn polkit_unix_session_get_session_id(p_session: *UnixSession) [*:0]const u8;
    pub const getSessionId = polkit_unix_session_get_session_id;

    /// Sets the session id for `session` to `session_id`.
    extern fn polkit_unix_session_set_session_id(p_session: *UnixSession, p_session_id: [*:0]const u8) void;
    pub const setSessionId = polkit_unix_session_set_session_id;

    extern fn polkit_unix_session_get_type() usize;
    pub const getGObjectType = polkit_unix_session_get_type;

    extern fn g_object_ref(p_self: *polkit.UnixSession) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.UnixSession) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *UnixSession, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An object representing a user identity on a UNIX system.
pub const UnixUser = opaque {
    pub const Parent = gobject.Object;
    pub const Implements = [_]type{polkit.Identity};
    pub const Class = polkit.UnixUserClass;
    pub const virtual_methods = struct {};

    pub const properties = struct {
        /// The UNIX user id.
        pub const uid = struct {
            pub const name = "uid";

            pub const Type = c_int;
        };
    };

    pub const signals = struct {};

    /// Creates a new `PolkitUnixUser` object for `uid`.
    extern fn polkit_unix_user_new(p_uid: c_int) *polkit.Identity;
    pub const new = polkit_unix_user_new;

    /// Creates a new `PolkitUnixUser` object for a user with the user name
    /// `name`.
    extern fn polkit_unix_user_new_for_name(p_name: [*:0]const u8, p_error: ?*?*glib.Error) ?*polkit.Identity;
    pub const newForName = polkit_unix_user_new_for_name;

    /// Get the user's name.
    extern fn polkit_unix_user_get_name(p_user: *UnixUser) ?[*:0]const u8;
    pub const getName = polkit_unix_user_get_name;

    /// Gets the UNIX user id for `user`.
    extern fn polkit_unix_user_get_uid(p_user: *UnixUser) c_int;
    pub const getUid = polkit_unix_user_get_uid;

    /// Sets `uid` for `user`.
    extern fn polkit_unix_user_set_uid(p_user: *UnixUser, p_uid: c_int) void;
    pub const setUid = polkit_unix_user_set_uid;

    extern fn polkit_unix_user_get_type() usize;
    pub const getGObjectType = polkit_unix_user_get_type;

    extern fn g_object_ref(p_self: *polkit.UnixUser) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.UnixUser) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *UnixUser, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// `PolkitIdentity` is an abstract type for representing one or more
/// identities.
pub const Identity = opaque {
    pub const Prerequisites = [_]type{gobject.Object};
    pub const Iface = polkit.IdentityIface;
    pub const virtual_methods = struct {
        /// Checks if `a` and `b` are equal, ie. represent the same identity.
        ///
        /// This function can be used in e.g. `glib.HashTable.new`.
        pub const equal = struct {
            pub fn call(p_class: anytype, p_a: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_b: *polkit.Identity) c_int {
                return gobject.ext.as(Identity.Iface, p_class).f_equal.?(gobject.ext.as(Identity, p_a), p_b);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_a: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_b: *polkit.Identity) callconv(.c) c_int) void {
                gobject.ext.as(Identity.Iface, p_class).f_equal = @ptrCast(p_implementation);
            }
        };

        /// Gets a hash code for `identity` that can be used with e.g. `glib.HashTable.new`.
        pub const hash = struct {
            pub fn call(p_class: anytype, p_identity: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) c_uint {
                return gobject.ext.as(Identity.Iface, p_class).f_hash.?(gobject.ext.as(Identity, p_identity));
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_identity: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) callconv(.c) c_uint) void {
                gobject.ext.as(Identity.Iface, p_class).f_hash = @ptrCast(p_implementation);
            }
        };

        /// Serializes `identity` to a string that can be used in
        /// `polkit.identityFromString`.
        pub const to_string = struct {
            pub fn call(p_class: anytype, p_identity: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) [*:0]u8 {
                return gobject.ext.as(Identity.Iface, p_class).f_to_string.?(gobject.ext.as(Identity, p_identity));
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_identity: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) callconv(.c) [*:0]u8) void {
                gobject.ext.as(Identity.Iface, p_class).f_to_string = @ptrCast(p_implementation);
            }
        };
    };

    pub const properties = struct {};

    pub const signals = struct {};

    /// Creates an object from `str` that implements the `PolkitIdentity`
    /// interface.
    extern fn polkit_identity_from_string(p_str: [*:0]const u8, p_error: ?*?*glib.Error) ?*polkit.Identity;
    pub const fromString = polkit_identity_from_string;

    /// Checks if `a` and `b` are equal, ie. represent the same identity.
    ///
    /// This function can be used in e.g. `glib.HashTable.new`.
    extern fn polkit_identity_equal(p_a: *Identity, p_b: *polkit.Identity) c_int;
    pub const equal = polkit_identity_equal;

    /// Gets a hash code for `identity` that can be used with e.g. `glib.HashTable.new`.
    extern fn polkit_identity_hash(p_identity: *Identity) c_uint;
    pub const hash = polkit_identity_hash;

    /// Serializes `identity` to a string that can be used in
    /// `polkit.identityFromString`.
    extern fn polkit_identity_to_string(p_identity: *Identity) [*:0]u8;
    pub const toString = polkit_identity_to_string;

    extern fn polkit_identity_get_type() usize;
    pub const getGObjectType = polkit_identity_get_type;

    extern fn g_object_ref(p_self: *polkit.Identity) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.Identity) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Identity, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// `PolkitSubject` is an abstract type for representing one or more
/// processes.
pub const Subject = opaque {
    pub const Prerequisites = [_]type{gobject.Object};
    pub const Iface = polkit.SubjectIface;
    pub const virtual_methods = struct {
        /// Checks if `a` and `b` are equal, ie. represent the same subject.
        /// However, avoid calling `polkit.Subject.equal` to compare two processes;
        /// for more information see the `PolkitUnixProcess` documentation.
        ///
        /// This function can be used in e.g. `glib.HashTable.new`.
        pub const equal = struct {
            pub fn call(p_class: anytype, p_a: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_b: *polkit.Subject) c_int {
                return gobject.ext.as(Subject.Iface, p_class).f_equal.?(gobject.ext.as(Subject, p_a), p_b);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_a: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_b: *polkit.Subject) callconv(.c) c_int) void {
                gobject.ext.as(Subject.Iface, p_class).f_equal = @ptrCast(p_implementation);
            }
        };

        /// Asynchronously checks if `subject` exists.
        ///
        /// When the operation is finished, `callback` will be invoked in the
        /// <link linkend="g-main-context-push-thread-default">thread-default
        /// main loop</link> of the thread you are calling this method
        /// from. You can then call `polkit.Subject.existsFinish` to get the
        /// result of the operation.
        pub const exists = struct {
            pub fn call(p_class: anytype, p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void {
                return gobject.ext.as(Subject.Iface, p_class).f_exists.?(gobject.ext.as(Subject, p_subject), p_cancellable, p_callback, p_user_data);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) callconv(.c) void) void {
                gobject.ext.as(Subject.Iface, p_class).f_exists = @ptrCast(p_implementation);
            }
        };

        /// Finishes checking whether a subject exists.
        pub const exists_finish = struct {
            pub fn call(p_class: anytype, p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int {
                return gobject.ext.as(Subject.Iface, p_class).f_exists_finish.?(gobject.ext.as(Subject, p_subject), p_res, p_error);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) callconv(.c) c_int) void {
                gobject.ext.as(Subject.Iface, p_class).f_exists_finish = @ptrCast(p_implementation);
            }
        };

        /// Checks if `subject` exists.
        ///
        /// This is a synchronous blocking call - the calling thread is blocked
        /// until a reply is received. See `polkit.Subject.exists` for the
        /// asynchronous version.
        pub const exists_sync = struct {
            pub fn call(p_class: anytype, p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int {
                return gobject.ext.as(Subject.Iface, p_class).f_exists_sync.?(gobject.ext.as(Subject, p_subject), p_cancellable, p_error);
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) callconv(.c) c_int) void {
                gobject.ext.as(Subject.Iface, p_class).f_exists_sync = @ptrCast(p_implementation);
            }
        };

        /// Gets a hash code for `subject` that can be used with e.g. `glib.HashTable.new`.
        pub const hash = struct {
            pub fn call(p_class: anytype, p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) c_uint {
                return gobject.ext.as(Subject.Iface, p_class).f_hash.?(gobject.ext.as(Subject, p_subject));
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) callconv(.c) c_uint) void {
                gobject.ext.as(Subject.Iface, p_class).f_hash = @ptrCast(p_implementation);
            }
        };

        /// Serializes `subject` to a string that can be used in
        /// `polkit.subjectFromString`.
        pub const to_string = struct {
            pub fn call(p_class: anytype, p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) [*:0]u8 {
                return gobject.ext.as(Subject.Iface, p_class).f_to_string.?(gobject.ext.as(Subject, p_subject));
            }

            pub fn implement(p_class: anytype, p_implementation: *const fn (p_subject: *@typeInfo(@TypeOf(p_class)).pointer.child.Instance) callconv(.c) [*:0]u8) void {
                gobject.ext.as(Subject.Iface, p_class).f_to_string = @ptrCast(p_implementation);
            }
        };
    };

    pub const properties = struct {};

    pub const signals = struct {};

    /// Creates an object from `str` that implements the `PolkitSubject`
    /// interface.
    extern fn polkit_subject_from_string(p_str: [*:0]const u8, p_error: ?*?*glib.Error) ?*polkit.Subject;
    pub const fromString = polkit_subject_from_string;

    /// Checks if `a` and `b` are equal, ie. represent the same subject.
    /// However, avoid calling `polkit.Subject.equal` to compare two processes;
    /// for more information see the `PolkitUnixProcess` documentation.
    ///
    /// This function can be used in e.g. `glib.HashTable.new`.
    extern fn polkit_subject_equal(p_a: *Subject, p_b: *polkit.Subject) c_int;
    pub const equal = polkit_subject_equal;

    /// Asynchronously checks if `subject` exists.
    ///
    /// When the operation is finished, `callback` will be invoked in the
    /// <link linkend="g-main-context-push-thread-default">thread-default
    /// main loop</link> of the thread you are calling this method
    /// from. You can then call `polkit.Subject.existsFinish` to get the
    /// result of the operation.
    extern fn polkit_subject_exists(p_subject: *Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) void;
    pub const exists = polkit_subject_exists;

    /// Finishes checking whether a subject exists.
    extern fn polkit_subject_exists_finish(p_subject: *Subject, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) c_int;
    pub const existsFinish = polkit_subject_exists_finish;

    /// Checks if `subject` exists.
    ///
    /// This is a synchronous blocking call - the calling thread is blocked
    /// until a reply is received. See `polkit.Subject.exists` for the
    /// asynchronous version.
    extern fn polkit_subject_exists_sync(p_subject: *Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) c_int;
    pub const existsSync = polkit_subject_exists_sync;

    /// Gets a hash code for `subject` that can be used with e.g. `glib.HashTable.new`.
    extern fn polkit_subject_hash(p_subject: *Subject) c_uint;
    pub const hash = polkit_subject_hash;

    /// Serializes `subject` to a string that can be used in
    /// `polkit.subjectFromString`.
    extern fn polkit_subject_to_string(p_subject: *Subject) [*:0]u8;
    pub const toString = polkit_subject_to_string;

    extern fn polkit_subject_get_type() usize;
    pub const getGObjectType = polkit_subject_get_type;

    extern fn g_object_ref(p_self: *polkit.Subject) void;
    pub const ref = g_object_ref;

    extern fn g_object_unref(p_self: *polkit.Subject) void;
    pub const unref = g_object_unref;

    pub fn as(p_instance: *Subject, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const ActionDescriptionClass = opaque {
    pub const Instance = polkit.ActionDescription;

    pub fn as(p_instance: *ActionDescriptionClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const AuthorityClass = opaque {
    pub const Instance = polkit.Authority;

    pub fn as(p_instance: *AuthorityClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const AuthorizationResultClass = opaque {
    pub const Instance = polkit.AuthorizationResult;

    pub fn as(p_instance: *AuthorizationResultClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const DetailsClass = opaque {
    pub const Instance = polkit.Details;

    pub fn as(p_instance: *DetailsClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An interface for identities.
pub const IdentityIface = extern struct {
    pub const Instance = polkit.Identity;

    /// The parent interface.
    f_parent_iface: gobject.TypeInterface,
    /// Gets a hash value for a `PolkitIdentity`.
    f_hash: ?*const fn (p_identity: *polkit.Identity) callconv(.c) c_uint,
    /// Checks if two `PolkitIdentity`<!-- -->s are equal.
    f_equal: ?*const fn (p_a: *polkit.Identity, p_b: *polkit.Identity) callconv(.c) c_int,
    /// Serializes a `PolkitIdentity` to a string that can be
    /// used in `polkit.identityFromString`.
    f_to_string: ?*const fn (p_identity: *polkit.Identity) callconv(.c) [*:0]u8,

    pub fn as(p_instance: *IdentityIface, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// An interface for subjects.
pub const SubjectIface = extern struct {
    pub const Instance = polkit.Subject;

    /// The parent interface.
    f_parent_iface: gobject.TypeInterface,
    /// Gets a hash value for a `PolkitSubject`.
    f_hash: ?*const fn (p_subject: *polkit.Subject) callconv(.c) c_uint,
    /// Checks if two `PolkitSubject`<!-- -->s are equal.
    f_equal: ?*const fn (p_a: *polkit.Subject, p_b: *polkit.Subject) callconv(.c) c_int,
    /// Serializes a `PolkitSubject` to a string that can be
    /// used in `polkit.subjectFromString`.
    f_to_string: ?*const fn (p_subject: *polkit.Subject) callconv(.c) [*:0]u8,
    /// Asynchronously check if a `PolkitSubject` exists.
    f_exists: ?*const fn (p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_callback: ?gio.AsyncReadyCallback, p_user_data: ?*anyopaque) callconv(.c) void,
    /// Finishes checking if a `PolkitSubject` exists.
    f_exists_finish: ?*const fn (p_subject: *polkit.Subject, p_res: *gio.AsyncResult, p_error: ?*?*glib.Error) callconv(.c) c_int,
    /// Synchronously check if a `PolkitSubject` exists.
    f_exists_sync: ?*const fn (p_subject: *polkit.Subject, p_cancellable: ?*gio.Cancellable, p_error: ?*?*glib.Error) callconv(.c) c_int,

    pub fn as(p_instance: *SubjectIface, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const SystemBusNameClass = opaque {
    pub const Instance = polkit.SystemBusName;

    pub fn as(p_instance: *SystemBusNameClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const TemporaryAuthorizationClass = opaque {
    pub const Instance = polkit.TemporaryAuthorization;

    pub fn as(p_instance: *TemporaryAuthorizationClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const UnixGroupClass = opaque {
    pub const Instance = polkit.UnixGroup;

    pub fn as(p_instance: *UnixGroupClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const UnixNetgroupClass = opaque {
    pub const Instance = polkit.UnixNetgroup;

    pub fn as(p_instance: *UnixNetgroupClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const UnixProcessClass = opaque {
    pub const Instance = polkit.UnixProcess;

    pub fn as(p_instance: *UnixProcessClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const UnixSessionClass = opaque {
    pub const Instance = polkit.UnixSession;

    pub fn as(p_instance: *UnixSessionClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

pub const UnixUserClass = opaque {
    pub const Instance = polkit.UnixUser;

    pub fn as(p_instance: *UnixUserClass, comptime P_T: type) *P_T {
        return gobject.ext.as(P_T, p_instance);
    }

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Possible error when using PolicyKit.
pub const Error = enum(c_int) {
    failed = 0,
    cancelled = 1,
    not_supported = 2,
    not_authorized = 3,
    _,

    extern fn polkit_error_quark() glib.Quark;
    pub const quark = polkit_error_quark;

    extern fn polkit_error_get_type() usize;
    pub const getGObjectType = polkit_error_get_type;

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Possible implicit authorizations.
pub const ImplicitAuthorization = enum(c_int) {
    unknown = -1,
    not_authorized = 0,
    authentication_required = 1,
    administrator_authentication_required = 2,
    authentication_required_retained = 3,
    administrator_authentication_required_retained = 4,
    authorized = 5,
    _,

    extern fn polkit_implicit_authorization_from_string(p_string: [*:0]const u8, p_out_implicit_authorization: *polkit.ImplicitAuthorization) c_int;
    pub const fromString = polkit_implicit_authorization_from_string;

    extern fn polkit_implicit_authorization_to_string(p_implicit_authorization: polkit.ImplicitAuthorization) [*:0]const u8;
    pub const toString = polkit_implicit_authorization_to_string;

    extern fn polkit_implicit_authorization_get_type() usize;
    pub const getGObjectType = polkit_implicit_authorization_get_type;

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Flags describing features supported by the Authority implementation.
pub const AuthorityFeatures = packed struct(c_uint) {
    temporary_authorization: bool = false,
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

    pub const flags_none: AuthorityFeatures = @bitCast(@as(c_uint, 0));
    pub const flags_temporary_authorization: AuthorityFeatures = @bitCast(@as(c_uint, 1));
    extern fn polkit_authority_features_get_type() usize;
    pub const getGObjectType = polkit_authority_features_get_type;

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

/// Possible flags when checking authorizations.
pub const CheckAuthorizationFlags = packed struct(c_uint) {
    allow_user_interaction: bool = false,
    always_check: bool = false,
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

    pub const flags_none: CheckAuthorizationFlags = @bitCast(@as(c_uint, 0));
    pub const flags_allow_user_interaction: CheckAuthorizationFlags = @bitCast(@as(c_uint, 1));
    pub const flags_always_check: CheckAuthorizationFlags = @bitCast(@as(c_uint, 2));
    extern fn polkit_check_authorization_flags_get_type() usize;
    pub const getGObjectType = polkit_check_authorization_flags_get_type;

    test {
        @setEvalBranchQuota(100_000);
        std.testing.refAllDecls(@This());
    }
};

test {
    @setEvalBranchQuota(100_000);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ext);
}
