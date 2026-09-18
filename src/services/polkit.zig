//! A real Authority-registered agent. Authentication uses libpolkit-agent only.
const std = @import("std");
const db = @import("dbus_peer.zig");
const gio = db.gio;
const glib = db.glib;
const gtk = @import("gtk4");
const object = @import("gobject2");
const polkit = @import("polkit1");
const agent = @import("polkitagent1");
const layer = @import("gtk4layershell1");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const authority_iface = "org.freedesktop.PolicyKit1.Authority";
const agent_path = "/org/aqueous/Pearl/AuthenticationAgent";
const Connection = struct { emitter: *object.Object, signal: c_ulong };
pub const Agent = struct {
    activity_broker: ?*@import("../platform/wayland/input_activity.zig").Broker = null,
    activity_token: @import("../platform/wayland/input_activity.zig").Token = .{},
    app: *gio.Application,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    peer: db.Peer = undefined,
    session_id: db.Text(128) = .{},
    allowed: bool = false,
    registered: bool = false,
    registering: bool = false,
    registration: c_uint = 0,
    info: ?*gio.DBusNodeInfo = null,
    generation: u64 = 0,
    request: ?*gio.DBusMethodInvocation = null,
    cookie: db.Text(1024) = .{},
    identities: [8]?*polkit.Identity = @splat(null),
    identity_count: usize = 0,
    conversation: ?*agent.Session = null,
    session_signals: [4]c_ulong = @splat(0),
    window: ?*gtk.Window = null,
    panel: ?*gtk.Box = null,
    entry: ?*gtk.Entry = null,
    prompt: ?*gtk.Label = null,
    selector: ?*gtk.DropDown = null,
    waiting: bool = false,
    connections: [8]Connection = undefined,
    connection_count: usize = 0,
    timeout: c_uint = 0,
    err: ?[]const u8 = null,
    pub fn start(self: *Agent) void {
        var core_limit: std.c.rlimit = .{ .cur = 0, .max = 0 };
        _ = std.c.setrlimit(.CORE, &core_limit);
        self.peer = .{ .app = self.app, .context = self, .changed = ownerChanged, .name = "org.freedesktop.PolicyKit1", .root = authority_path, .managed = false };
        self.peer.start();
    }
    pub fn stop(self: *Agent) void {
        self.unregister();
        self.peer.stop();
    }
    pub fn setSession(self: *Agent, session_id: []const u8, allowed: bool) void {
        if (!std.mem.eql(u8, session_id, self.session_id.slice())) {
            self.unregister();
            self.generation += 1;
            self.err = null;
            self.session_id.set(session_id);
        }
        self.allowed = allowed;
        if (!allowed) self.cancel();
        self.register();
    }
    fn subject(self: *Agent) *glib.Variant {
        return db.tuple(&.{ db.str("unix-session"), db.array("{sv}", &.{db.entry("session-id", db.str(self.session_id.z()))}) });
    }
    fn unregister(self: *Agent) void {
        self.cancel();
        if (self.registered and self.peer.owner.len != 0 and self.peer.connection() != null) {
            self.peer.connection().?.call(self.peer.owner.z(), authority_path, authority_iface, "UnregisterAuthenticationAgent", db.tuple(&.{ self.subject(), db.str(agent_path) }), null, .{ .no_auto_start = true }, 1500, null, null, null);
        }
        self.registered = false;
        self.registering = false;
        if (self.registration != 0) {
            if (self.peer.connection()) |c| _ = c.unregisterObject(self.registration);
            self.registration = 0;
        }
        if (self.info) |i| i.unref();
        self.info = null;
    }
    fn ownerChanged(data: *anyopaque, _: bool) void {
        const self: *Agent = @ptrCast(@alignCast(data));
        self.unregister();
        self.generation += 1;
        self.err = null;
        self.register();
        self.changed(self.context);
    }
    fn register(self: *Agent) void {
        if (self.err != null or !self.peer.running or self.peer.owner.len == 0 or self.session_id.len == 0 or self.registered or self.registering) return;
        if (self.registration == 0) {
            self.info = gio.DBusNodeInfo.newForXml(@embedFile("polkit_agent.xml"), null) orelse return;
            self.registration = self.peer.connection().?.registerObject(agent_path, self.info.?.f_interfaces.?[0].?, &vtable, self, noDestroy, null);
            if (self.registration == 0) {
                self.info.?.unref();
                self.info = null;
                self.err = "Authentication endpoint unavailable.";
                return;
            }
        }
        self.registering = true;
        self.peer.call(self.generation, authority_path, authority_iface, "RegisterAuthenticationAgent", db.tuple(&.{ self.subject(), db.str("C.UTF-8"), db.str(agent_path) }), "()", 5000, registrationDone) catch {
            self.registering = false;
            self.err = "Polkit authority unavailable.";
        };
    }
    fn registrationDone(data: *anyopaque, generation: u64, result: ?*glib.Variant, _: ?[]const u8) void {
        const self: *Agent = @ptrCast(@alignCast(data));
        if (generation != self.generation) return;
        // A conflict stays unavailable until an owner/session change. Never replace an agent.
        self.registering = false;
        self.registered = result != null;
        self.err = if (result == null) "Polkit registration failed; another session agent may be registered." else null;
        self.changed(self.context);
    }
    fn noDestroy(_: ?*anyopaque) callconv(.c) void {}
    const vtable: gio.DBusInterfaceVTable = .{ .f_method_call = method, .f_get_property = null, .f_set_property = null, .f_padding = @splat(undefined) };
    fn method(_: *gio.DBusConnection, sender: ?[*:0]const u8, _: [*:0]const u8, _: ?[*:0]const u8, name: [*:0]const u8, params: *glib.Variant, invocation: *gio.DBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self: *Agent = @ptrCast(@alignCast(data.?));
        if (sender == null or self.peer.owner.len == 0 or !std.mem.eql(u8, std.mem.span(sender.?), self.peer.owner.slice())) {
            invocation.returnDbusError("org.freedesktop.DBus.Error.AccessDenied", "Only the registered authority may authenticate");
            return;
        }
        if (std.mem.eql(u8, std.mem.span(name), "CancelAuthentication")) {
            const cookie = params.getChildValue(0);
            defer cookie.unref();
            if (std.mem.eql(u8, std.mem.span(cookie.getString(null)), self.cookie.slice())) self.cancel();
            invocation.returnValue(null);
            return;
        }
        if (!self.registered or !self.allowed or self.request != null or !db.is(params, "(sssa{ss}sa(sa{sv}))")) {
            invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Cancelled", "Authentication unavailable or busy");
            return;
        }
        self.begin(params, invocation) catch {
            self.cancel();
            invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Failed", "Unsupported authentication request");
        };
    }
    fn begin(self: *Agent, params: *glib.Variant, invocation: *gio.DBusMethodInvocation) !void {
        if (params.getSize() > 16384) return error.InvalidRequest;
        const cookie = params.getChildValue(4);
        defer cookie.unref();
        const cookie_text = std.mem.span(cookie.getString(null));
        if (cookie_text.len == 0 or cookie_text.len >= 1024) return error.InvalidCookie;
        const identities = params.getChildValue(5);
        defer identities.unref();
        if (identities.nChildren() == 0 or identities.nChildren() > 8) return error.InvalidIdentity;
        errdefer self.clearIdentities();
        var labels: [8][128:0]u8 = undefined;
        var label_ptrs: [9:null]?[*:0]const u8 = @splat(null);
        for (0..identities.nChildren()) |i| {
            const value = identities.getChildValue(i);
            defer value.unref();
            const kind = value.getChildValue(0);
            defer kind.unref();
            const details = value.getChildValue(1);
            defer details.unref();
            // PAM authenticates a concrete user. Reject non-user identities explicitly.
            if (!std.mem.eql(u8, std.mem.span(kind.getString(null)), "unix-user")) return error.UnsupportedIdentity;
            const uid_value = db.lookup(details, "uid", "u") orelse return error.InvalidIdentity;
            defer uid_value.unref();
            const uid = uid_value.getUint32();
            if (uid > std.math.maxInt(c_int)) return error.InvalidIdentity;
            for (self.identities[0..self.identity_count]) |previous| if (object.ext.cast(polkit.UnixUser, previous.?).?.getUid() == uid) return error.DuplicateIdentity;
            const identity = polkit.UnixUser.new(@intCast(uid));
            self.identities[i] = identity;
            self.identity_count += 1;
            const user = object.ext.cast(polkit.UnixUser, identity).?;
            const label = try std.fmt.bufPrintZ(&labels[i], "{s} (UID {d})", .{ user.getName() orelse "User", uid });
            label_ptrs[i] = label.ptr;
        }
        self.cookie.set(cookie_text);
        const window = gtk.Window.new();
        window.ref();
        self.window = window;
        window.setTitle("Pearl · Authentication");
        for ([_][*:0]const u8{ "pearl-root", "pearl-shell", "pearl-dark" }) |c| window.as(gtk.Widget).addCssClass(c);
        layer.initForWindow(window);
        layer.setNamespace(window, "pearl:authentication");
        layer.setLayer(window, .overlay);
        layer.setKeyboardMode(window, .exclusive);
        const panel = w.card();
        self.panel = panel;
        panel.as(gtk.Widget).setSizeRequest(400, -1);
        window.setChild(panel.as(gtk.Widget));
        panel.append(w.label("Authentication required", "pearl-title").as(gtk.Widget));
        const message = params.getChildValue(1);
        defer message.unref();
        var safe_message: db.Text(1024) = .{};
        safe_message.set(std.mem.span(message.getString(null)));
        const summary = w.label(safe_message.z(), null);
        summary.setWrap(1);
        summary.setMaxWidthChars(44);
        panel.append(summary.as(gtk.Widget));
        const action = params.getChildValue(0);
        defer action.unref();
        var safe_action: db.Text(256) = .{};
        safe_action.set(std.mem.span(action.getString(null)));
        const action_label = w.label(safe_action.z(), "pearl-secondary");
        action_label.setWrap(1);
        action_label.setMaxWidthChars(44);
        panel.append(action_label.as(gtk.Widget));
        const selector = gtk.DropDown.newFromStrings(@ptrCast(&label_ptrs));
        self.selector = selector;
        panel.append(selector.as(gtk.Widget));
        self.prompt = w.label("Choose an identity, then authenticate.", "pearl-secondary");
        self.prompt.?.setWrap(1);
        self.prompt.?.setMaxWidthChars(44);
        panel.append(self.prompt.?.as(gtk.Widget));
        const entry = gtk.Entry.new();
        self.entry = entry;
        entry.setVisibility(0);
        entry.setInputPurpose(.password);
        entry.setMaxLength(1023);
        entry.as(gtk.Widget).setSensitive(0);
        w.name(entry.as(gtk.Widget), "Authentication response");
        panel.append(entry.as(gtk.Widget));
        const actions = w.row(12);
        const cancel_button = gtk.Button.newWithLabel("Cancel");
        const submit_button = gtk.Button.newWithLabel("Authenticate");
        actions.append(cancel_button.as(gtk.Widget));
        actions.append(submit_button.as(gtk.Widget));
        panel.append(actions.as(gtk.Widget));
        self.remember(cancel_button.as(object.Object), gtk.Button.signals.clicked.connect(cancel_button, *Agent, cancelled, self, .{}));
        self.remember(submit_button.as(object.Object), gtk.Button.signals.clicked.connect(submit_button, *Agent, submitted, self, .{}));
        self.remember(entry.as(object.Object), gtk.Entry.signals.activate.connect(entry, *Agent, entered, self, .{}));
        self.remember(selector.as(object.Object), object.Object.signals.notify.connect(selector.as(object.Object), *Agent, selected, self, .{ .detail = "selected" }));
        self.remember(window.as(object.Object), gtk.Window.signals.close_request.connect(window, *Agent, closed, self, .{}));
        const controller = gtk.EventControllerKey.new();
        self.remember(controller.as(object.Object), gtk.EventControllerKey.signals.key_pressed.connect(controller, *Agent, key, self, .{}));
        window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        invocation.ref();
        self.request = invocation;
        self.timeout = glib.timeoutAddSeconds(120, expired, self);
        self.activity_token.begin(self.activity_broker, self, activityReady);
        self.changed(self.context);
    }
    fn activityReady(context: *anyopaque) void {
        const self: *Agent = @ptrCast(@alignCast(context));
        if (self.request == null or !self.allowed or !self.registered) {
            self.cancel();
            return;
        }
        if (self.window) |window| {
            window.present();
            if (@import("build_options").test_hooks) std.log.info("event=activity-auth-presented", .{});
        }
    }
    fn remember(self: *Agent, emitter: *object.Object, signal_id: c_ulong) void {
        _ = emitter.ref();
        self.connections[self.connection_count] = .{ .emitter = emitter, .signal = signal_id };
        self.connection_count += 1;
    }
    fn stopConversation(self: *Agent) void {
        self.waiting = false;
        if (self.entry) |entry| entry.as(gtk.Editable).setText("");
        if (self.conversation) |session| {
            self.conversation = null;
            for (self.session_signals) |s| object.signalHandlerDisconnect(session.as(object.Object), s);
            session.cancel();
            session.unref();
        }
    }
    fn clearIdentities(self: *Agent) void {
        for (&self.identities) |*id| {
            if (id.*) |v| v.as(object.Object).unref();
            id.* = null;
        }
        self.identity_count = 0;
    }
    pub fn cancel(self: *Agent) void {
        self.activity_token.cancel();
        if (self.request == null and self.window == null and self.conversation == null) return;
        if (self.request) |invocation| {
            self.request = null;
            invocation.returnDbusError("org.freedesktop.PolicyKit1.Error.Cancelled", "Authentication cancelled");
            invocation.unref();
        }
        self.cleanup();
    }
    fn cleanup(self: *Agent) void {
        self.stopConversation();
        if (self.timeout != 0) _ = glib.Source.remove(self.timeout);
        self.timeout = 0;
        for (self.connections[0..self.connection_count]) |c| object.signalHandlerDisconnect(c.emitter, c.signal);
        for (self.connections[0..self.connection_count]) |c| c.emitter.unref();
        self.connection_count = 0;
        if (self.window) |window| {
            window.destroy();
            window.unref();
        }
        self.window = null;
        self.panel = null;
        self.entry = null;
        self.prompt = null;
        self.selector = null;
        self.clearIdentities();
        std.crypto.secureZero(u8, &self.cookie.bytes);
        self.cookie = .{};
        self.changed(self.context);
    }
    fn submit(self: *Agent) void {
        if (self.activity_token.callback != null) return;
        if (!self.allowed or self.request == null) {
            self.cancel();
            return;
        }
        if (self.waiting) {
            var response: [1024:0]u8 = @splat(0);
            defer std.crypto.secureZero(u8, &response);
            const text = std.mem.span(self.entry.?.as(gtk.Editable).getText());
            @memcpy(response[0..@min(text.len, 1023)], text[0..@min(text.len, 1023)]);
            self.entry.?.as(gtk.Editable).setText("");
            self.entry.?.as(gtk.Widget).setSensitive(0);
            self.waiting = false;
            self.conversation.?.response(&response);
            return;
        }
        if (self.conversation != null) return;
        const index = self.selector.?.getSelected();
        if (index >= self.identity_count) return;
        const session = agent.Session.new(self.identities[index].?, self.cookie.z());
        self.conversation = session;
        self.session_signals = .{ agent.Session.signals.request.connect(session, *Agent, requested, self, .{}), agent.Session.signals.show_info.connect(session, *Agent, conversationInfo, self, .{}), agent.Session.signals.show_error.connect(session, *Agent, conversationInfo, self, .{}), agent.Session.signals.completed.connect(session, *Agent, completed, self, .{}) };
        session.initiate();
    }
    fn requested(_: *agent.Session, text: [*:0]u8, echo: c_int, self: *Agent) callconv(.c) void {
        if (!self.allowed or self.request == null) {
            self.cancel();
            return;
        }
        var bounded: db.Text(1024) = .{};
        bounded.set(std.mem.span(text));
        self.prompt.?.setText(bounded.z());
        self.waiting = true;
        self.entry.?.setVisibility(echo);
        self.entry.?.as(gtk.Widget).setSensitive(1);
        _ = self.entry.?.as(gtk.Widget).grabFocus();
    }
    fn conversationInfo(_: *agent.Session, text: [*:0]u8, self: *Agent) callconv(.c) void {
        var bounded: db.Text(1024) = .{};
        bounded.set(std.mem.span(text));
        if (self.prompt) |p| p.setText(bounded.z());
    }
    fn completed(session: *agent.Session, _: c_int, self: *Agent) callconv(.c) void {
        self.activity_token.cancel();
        for (self.session_signals) |s| object.signalHandlerDisconnect(session.as(object.Object), s);
        self.conversation = null;
        session.unref();
        // The authority receives proof from its trusted helper; this reply grants nothing.
        if (self.request) |invocation| {
            self.request = null;
            invocation.returnValue(null);
            invocation.unref();
        }
        self.cleanup();
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, self: *Agent) callconv(.c) void {
        self.stopConversation();
        if (self.entry) |e| e.as(gtk.Widget).setSensitive(0);
        if (self.prompt) |p| p.setText("Identity changed. Authenticate to continue.");
    }
    fn submitted(_: *gtk.Button, self: *Agent) callconv(.c) void {
        self.submit();
    }
    fn entered(_: *gtk.Entry, self: *Agent) callconv(.c) void {
        self.submit();
    }
    fn cancelled(_: *gtk.Button, self: *Agent) callconv(.c) void {
        self.cancel();
    }
    fn closed(_: *gtk.Window, self: *Agent) callconv(.c) c_int {
        self.cancel();
        return 1;
    }
    fn key(_: *gtk.EventControllerKey, code: c_uint, _: c_uint, _: @import("gdk4").ModifierType, self: *Agent) callconv(.c) c_int {
        if (code != 0xff1b) return 0;
        self.cancel();
        return 1;
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Agent = @ptrCast(@alignCast(data.?));
        self.timeout = 0;
        self.cancel();
        return 0;
    }
};
