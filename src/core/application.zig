const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("glibunix2");
const gobject = @import("gobject2");
const options = @import("build_options");
const Mode = @import("startup.zig").Mode;
const Lifecycle = @import("lifecycle.zig").Lifecycle;
const Gallery = @import("../ui/gallery.zig").Gallery;
const SurfaceManager = @import("../ui/surfaces/manager.zig").Manager;
const control = @import("../cli/server.zig");
const control_protocol = @import("../cli/protocol.zig");
const adapter = @import("../aqueous/client.zig");
const theme = @import("../theme/theme.zig");
const log = std.log.scoped(.pearl);

pub const TestHooks = struct { worker_delay_ms: u32 = 0, close_after_ms: u32 = 0 };
const Connection = struct { object: *gobject.Object, id: c_ulong };
const Work = struct { delay_ms: u32 = 0 };

const State = struct {
    app: *gtk.Application,
    builder: *gtk.Builder,
    css: *gtk.CssProvider,
    cancel: *gio.Cancellable,
    display: *gdk.Display,
    main_thread: *glib.Thread,
    mode: Mode,
    hooks: TestHooks,
    life: Lifecycle = .{},
    work: Work = .{},
    ticket: u64 = 0,
    window: ?*gtk.Window = null, // explicit owned ref, separate from GTK's window list
    connections: [8]Connection = undefined,
    connection_count: usize = 0,
    sources: [3]c_uint = .{ 0, 0, 0 },
    watched_objects: usize = 0,
    failed: bool = false,
    gallery: ?Gallery = null,
    aqueous: ?adapter.Client = null,
    surfaces: ?SurfaceManager = null,
    control_server: ?control.Server = null,
    settings_server: ?@import("../settings/server.zig").Server = null,
    session_source: c_uint = 0,
    identity_source: c_uint = 0,
    logout_source: c_uint = 0,
    logout_requested: bool = false,
    logout_ticket: ?u64 = null,
    cleaned: bool = false,
    logout_loop: ?*glib.MainLoop = null,

    fn checkThread(self: *State) void {
        std.debug.assert(glib.Thread.self() == self.main_thread);
    }

    fn watch(self: *State, object: *gobject.Object) void {
        if (!options.test_hooks) return;
        self.watched_objects += 1;
        object.weakRef(finalized, self);
    }

    fn remember(self: *State, object: *gobject.Object, id: c_ulong) void {
        self.connections[self.connection_count] = .{ .object = object, .id = id };
        self.connection_count += 1;
    }

    fn widget(self: *State, comptime T: type, name: [*:0]const u8) *T {
        return gobject.ext.cast(T, self.builder.getObject(name).?).?;
    }

    fn loadPreview(self: *State) void {
        self.checkThread();
        self.ticket = self.life.beginWork() catch return;
        self.widget(gtk.Button, "reload").as(gtk.Widget).setSensitive(0);
        self.widget(gtk.Label, "preview").setText("Loading preview…");
        if (self.gallery) |*gallery| gallery.previewLoading();
        const task = gio.Task.new(self.app.as(gobject.Object), self.cancel, workFinished, self);
        self.watch(task.as(gobject.Object));
        // Completion must follow worker exit, including after cancellation.
        _ = task.setReturnOnCancel(0);
        task.setTaskData(&self.work, null);
        self.app.as(gio.Application).hold();
        task.runInThread(loadResource);
        task.unref();
        log.info("event=work-started generation={d}", .{self.ticket});
    }

    fn stop(self: *State, reason: []const u8) void {
        self.checkThread();
        if (!self.life.stop()) return;
        log.info("event=stopping reason={s} pending={}", .{ reason, self.life.pending });
        if (self.session_source != 0) _ = glib.Source.remove(self.session_source);
        self.session_source = 0;
        if (self.logout_source != 0) _ = glib.Source.remove(self.logout_source);
        self.logout_source = 0;
        if (self.identity_source != 0) _ = glib.Source.remove(self.identity_source);
        self.identity_source = 0;
        if (self.surfaces) |*surfaces| surfaces.settings_observer = null;
        if (self.settings_server) |*server| {
            server.deinit();
            self.settings_server = null;
        }
        if (self.control_server) |*server| {
            server.deinit();
            self.control_server = null;
        }
        if (self.surfaces) |*surfaces| surfaces.deinit();
        if (!self.logout_requested) {
            if (self.aqueous) |*client| client.stop();
        }
        self.cancel.cancel();
        if (self.window) |window| window.destroy();
        // The task's hold keeps the main context alive until completion drains.
        self.app.as(gio.Application).release();
    }
};

fn state(data: ?*anyopaque) *State {
    return @ptrCast(@alignCast(data.?));
}

fn finalized(data: ?*anyopaque, _: *gobject.Object) callconv(.c) void {
    const self = state(data);
    self.watched_objects -= 1;
}

fn closeRequested(_: *gtk.Window, data: *State) callconv(.c) c_int {
    data.stop("window-close");
    return 1;
}

fn closeClicked(_: *gtk.Button, data: *State) callconv(.c) void {
    data.stop("close-button");
}

fn reloadClicked(_: *gtk.Button, data: *State) callconv(.c) void {
    data.loadPreview();
}

fn signalStop(data: ?*anyopaque) callconv(.c) c_int {
    state(data).stop("signal");
    return 1; // owned source IDs remain valid until explicit teardown
}

fn testClose(data: ?*anyopaque) callconv(.c) c_int {
    const self = state(data);
    self.sources[2] = 0;
    // Exercise the actual GTK close-request route, including in-flight work.
    if (self.window) |window| window.close() else self.stop("test-close");
    return 0;
}

fn cssError(_: *gtk.CssProvider, _: *gtk.CssSection, err: *const glib.Error, data: *State) callconv(.c) void {
    data.failed = true;
    log.err("event=css-error message={s}", .{err.f_message orelse "Unknown GTK error"});
}

fn activate(_: *gio.Application, self: *State) callconv(.c) void {
    self.checkThread();
    if (self.life.phase != .idle) return;
    self.life.start();
    self.app.as(gio.Application).hold();
    if (self.mode == .session) {
        activateSession(self) catch |err| {
            self.failed = true;
            log.err("event=session-error error={s}", .{@errorName(err)});
            self.stop("session-error");
        };
        return;
    }
    const window = gtk.ApplicationWindow.new(self.app).as(gtk.Window);
    _ = window.ref();
    self.window = window;
    self.watch(window.as(gobject.Object));
    window.setTitle(if (self.mode == .demo) "Pearl · Demo gallery" else "Pearl");
    window.setDefaultSize(if (self.mode == .demo) 1160 else 680, if (self.mode == .demo) 660 else 480);
    window.as(gtk.Widget).addCssClass("pearl-root");
    window.as(gtk.Widget).addCssClass("pearl-dark");
    window.setChild(self.widget(gtk.Widget, "content"));
    self.widget(gtk.Label, "badge").setText(if (self.mode == .demo) "DEMO · SAMPLE CONTENT" else "AQUEOUS");
    self.widget(gtk.Label, "subtitle").setText(if (self.mode == .demo) "Explore Pearl’s appearance with sample content." else "Your desktop, taking shape.");
    self.widget(gtk.Label, "card_title").setText(if (self.mode == .demo) "A place for your day" else "Welcome to Pearl");
    self.widget(gtk.Label, "preview").setText("Session services are not available yet.");
    self.widget(gtk.Button, "reload").as(gtk.Widget).setVisible(@intFromBool(self.mode == .demo));
    if (self.mode == .demo) {
        self.gallery = @as(Gallery, undefined);
        self.gallery.?.init(window, self.builder) catch |err| {
            self.gallery = null;
            self.failed = true;
            log.err("event=gallery-error error={s}", .{@errorName(err)});
            self.stop("gallery-error");
            return;
        };
        for ([_]*gobject.Object{ self.gallery.?.strings.as(gobject.Object), self.gallery.?.filter.as(gobject.Object), self.gallery.?.factory.as(gobject.Object), self.gallery.?.list.as(gobject.Object) }) |object| self.watch(object);
    }
    self.remember(window.as(gobject.Object), gtk.Window.signals.close_request.connect(window, *State, closeRequested, self, .{}));
    const close = self.widget(gtk.Button, "close");
    const reload = self.widget(gtk.Button, "reload");
    self.remember(close.as(gobject.Object), gtk.Button.signals.clicked.connect(close, *State, closeClicked, self, .{}));
    self.remember(reload.as(gobject.Object), gtk.Button.signals.clicked.connect(reload, *State, reloadClicked, self, .{}));
    window.present();
    if (self.mode == .demo) window.maximize();
    self.loadPreview();
    if (options.test_hooks and self.hooks.close_after_ms > 0)
        self.sources[2] = glib.timeoutAdd(self.hooks.close_after_ms, testClose, self);
    log.info("event=ready mode={s}", .{@tagName(self.mode)});
}

fn activateSession(self: *State) !void {
    const endpoint = std.mem.span(glib.getenv("AQUEOUS_SOCKET").?);
    const runtime = std.mem.span(glib.getenv("XDG_RUNTIME_DIR").?);
    self.aqueous = try adapter.Client.init(endpoint, runtime, self, aqueousChanged);
    self.surfaces = SurfaceManager.init(self.app, self.display, &self.aqueous.?);
    self.surfaces.?.context = self;
    self.surfaces.?.changed = nativeSessionChanged;
    self.surfaces.?.logout = queueLogout;
    try self.surfaces.?.start();
    self.identity_source = glib.timeoutAdd(5000, identityExpired, self);
    self.aqueous.?.start();
    if (options.test_hooks and self.hooks.close_after_ms > 0) self.sources[2] = glib.timeoutAdd(self.hooks.close_after_ms, testClose, self);
    log.info("event=ready mode=session", .{});
}
fn aqueousChanged(context: *anyopaque, event: adapter.Event) void {
    const self: *State = @ptrCast(@alignCast(context));
    self.checkThread();
    if (event == .availability) log.info("event=aqueous-availability state={s}", .{@tagName(event.availability)});
    if (event == .fault and !self.logout_requested) log.warn("event=aqueous-disconnected reason={s}", .{event.fault});
    if (self.logout_requested) {
        if (event == .completion and self.logout_ticket == event.completion.ticket) {
            self.logout_ticket = null;
            self.failed = event.completion.status != .accepted and event.completion.status != .applied;
            log.info("event=logout-result status={s}", .{@tagName(event.completion.status)});
            if (self.logout_loop) |loop| loop.quit();
        }
        return;
    }
    if (self.life.phase == .stopping) return;
    if (event == .completion) {
        if (self.surfaces) |*surfaces| surfaces.completion(event.completion);
    }
    if (self.logout_requested) return;
    if (event == .availability or event == .state) {
        if (self.surfaces) |*surfaces| {
            surfaces.syncClipboardPrivacy();
            surfaces.schedule();
        }
        if (self.session_source == 0) self.session_source = glib.idleAdd(sessionChanged, self);
    }
}
fn nativeSessionChanged(context: *anyopaque) void {
    const self: *State = @ptrCast(@alignCast(context));
    if (!self.logout_requested and self.life.phase != .stopping and self.session_source == 0) self.session_source = glib.idleAdd(sessionChanged, self);
}
fn identityExpired(data: ?*anyopaque) callconv(.c) c_int {
    const self = state(data);
    self.identity_source = 0;
    if (self.surfaces.?.effects.display_session == null) sessionFailed(self, error.UnverifiedWaylandDisplay);
    return 0;
}
fn sessionChanged(data: ?*anyopaque) callconv(.c) c_int {
    const self = state(data);
    self.session_source = 0;
    if (self.logout_requested) return 0;
    const client = &self.aqueous.?;
    if (self.control_server) |*server| {
        if (client.availability != .ready or !std.mem.eql(u8, &server.session, client.model.session)) {
            server.deinit();
            self.control_server = null;
            if (self.surfaces) |*surfaces| surfaces.settings_observer = null;
            if (self.settings_server) |*settings_server| settings_server.deinit();
            self.settings_server = null;
        }
    }
    if (client.availability == .ready and self.control_server == null) {
        const display_session = self.surfaces.?.effects.display_session orelse return 0;
        if (!std.mem.eql(u8, &display_session, client.model.session)) {
            sessionFailed(self, error.SessionDisplayMismatch);
            return 0;
        }
        if (self.identity_source != 0) _ = glib.Source.remove(self.identity_source);
        self.identity_source = 0;
        self.control_server = control.Server.init(std.mem.span(glib.getenv("XDG_RUNTIME_DIR").?), client.model.session, std.mem.span(glib.getenv("WAYLAND_DISPLAY").?), self, controlRequest, controlQuit) catch |err| {
            sessionFailed(self, err);
            return 0;
        };
        self.control_server.?.start() catch |err| {
            sessionFailed(self, err);
            return 0;
        };
        self.settings_server = @import("../settings/server.zig").Server.init(std.mem.span(glib.getenv("XDG_RUNTIME_DIR").?), client.model.session, std.mem.span(glib.getenv("WAYLAND_DISPLAY").?)) catch |err| {
            sessionFailed(self, err);
            return 0;
        };
        self.settings_server.?.appearance_context = self;
        self.settings_server.?.appearance = settingsAppearance;
        self.settings_server.?.backend = .{ .service = &self.surfaces.?.preferences, .aqueous = &self.surfaces.?.aqueous_settings, .context = self, .allowed = settingsAllowed, .live = .{ .audio = &self.surfaces.?.audio, .network = &self.surfaces.?.network, .bluetooth = &self.surfaces.?.bluetooth, .power = &self.surfaces.?.power, .session = &self.surfaces.?.session_services, .lifecycle = &self.surfaces.?.lifecycle, .layout = &self.surfaces.?.layout.?, .layout_context = &self.surfaces.?, .layout_rows = @import("../ui/surfaces/manager.zig").Manager.settingsLayoutRows, .layout_action = @import("../ui/surfaces/manager.zig").Manager.settingsLayoutAction } };
        self.surfaces.?.settings_observer_context = self;
        self.surfaces.?.settings_observer = settingsServicesChanged;
        self.settings_server.?.start() catch |err| {
            sessionFailed(self, err);
            return 0;
        };
        log.info("event=settings-backend-ready session={s}", .{client.model.session});
        log.info("event=control-ready session={s}", .{client.model.session});
    }
    if (self.settings_server) |*server| server.sessionChanged();
    return 0;
}
fn settingsServicesChanged(context: *anyopaque) void {
    const self: *State = @ptrCast(@alignCast(context));
    if (self.settings_server) |*server| {
        server.sessionChanged();
        @import("../settings/server.zig").Server.preferencesChanged(server);
    }
}
fn settingsAllowed(context: *anyopaque) !void {
    const self: *State = @ptrCast(@alignCast(context));
    const client = &self.aqueous.?;
    const native = self.surfaces.?.effects.display_session orelse return error.Unavailable;
    if (client.availability != .ready or !std.mem.eql(u8, &native, client.model.session)) return error.Unavailable;
    const session = client.model.get(.session, "session") orelse return error.Unavailable;
    const gate = self.surfaces.?.lifecycle.gate;
    if (session.locked or gate.locked or gate.requesting or gate.preparing) return error.Locked;
}
fn settingsAppearance(context: *anyopaque) @import("../settings/appearance.zig").Snapshot {
    const self: *State = @ptrCast(@alignCast(context));
    const service = &self.surfaces.?.preferences;
    const p = service.prefs();
    return .{ .revision = service.appearance, .mode = p.theme.mode, .variant = p.theme.variant, .gtk_name = p.theme.gtk_name, .font = p.font, .font_size = p.font_size, .density = p.density, .reduced_motion = p.reduced_motion, .palette = if (service.live) |job| job.palette else @import("../theme/theme.zig").dark };
}
fn sessionFailed(self: *State, err: anyerror) void {
    self.failed = true;
    log.err("event=session-error error={s}", .{@errorName(err)});
    self.stop("session-error");
}
fn controlRequest(context: *anyopaque, request: control_protocol.Request, alloc: std.mem.Allocator) ![]const u8 {
    const self: *State = @ptrCast(@alignCast(context));
    return self.surfaces.?.control(request, alloc);
}
fn queueLogout(context: *anyopaque) void {
    const self: *State = @ptrCast(@alignCast(context));
    if (self.logout_requested) return;
    self.logout_requested = true;
    // Allow the local confirmation reply to flush before stopping its server.
    self.logout_source = glib.timeoutAdd(100, beginLogout, self);
}
fn beginLogout(context: ?*anyopaque) callconv(.c) c_int {
    const self = state(context);
    self.logout_source = 0;
    // Drain GTK and service workers while the compositor is still alive.
    self.stop("aqueous-logout");
    return 0;
}
fn finishLogout(self: *State) void {
    // GtkApplication shutdown still needs its display. Only after its objects
    // have been disposed may we close Wayland and send the terminal IPC command.
    self.display.ref();
    cleanup(self);
    self.display.close();
    self.display.unref();
    const loop = glib.MainLoop.new(null, 0);
    defer loop.unref();
    self.logout_loop = loop;
    defer self.logout_loop = null;
    self.logout_ticket = self.aqueous.?.exitSession() catch {
        self.failed = true;
        log.err("event=logout-result status=unavailable", .{});
        return;
    };
    loop.run();
}
fn controlQuit(context: *anyopaque) void {
    const self: *State = @ptrCast(@alignCast(context));
    self.stop("control-quit");
}

/// No GTK access here. Input remains immutable until the completion is drained.
fn loadResource(task: *gio.Task, _: *gobject.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
    const work: *const Work = @ptrCast(@alignCast(data.?));
    if (options.test_hooks) {
        var remaining = work.delay_ms;
        while (remaining > 0) {
            if (task.returnErrorIfCancelled() != 0) return;
            const chunk = @min(remaining, 10);
            glib.usleep(@as(c_ulong, chunk) * 1000);
            remaining -= chunk;
        }
    }
    if (task.returnErrorIfCancelled() != 0) return;
    var err: ?*glib.Error = null;
    const bytes = gio.resourcesLookupData("/org/aqueous/Pearl/demo.txt", .{}, &err) orelse {
        task.returnError(err.?);
        return;
    };
    defer bytes.unref();
    var length: usize = 0;
    const text = bytes.getData(&length).?;
    std.debug.assert(length <= 4096); // trusted compiled gallery resource
    if (task.returnErrorIfCancelled() != 0) return;
    const owned = glib.strndup(@ptrCast(text), length).?;
    task.returnPointer(@ptrCast(owned), glib.free);
}

fn workFinished(_: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
    const self = state(data);
    self.checkThread();
    const may_update = self.life.complete(self.ticket);
    var err: ?*glib.Error = null;
    const text = gobject.ext.cast(gio.Task, result).?.propagatePointer(&err);
    defer if (text) |owned| glib.free(owned);
    defer if (err) |owned| owned.free();
    if (may_update) {
        self.widget(gtk.Button, "reload").as(gtk.Widget).setSensitive(1);
        self.widget(gtk.Label, "preview").setText(if (text) |value| @ptrCast(value) else "The preview could not be loaded.");
        if (self.gallery) |*gallery| gallery.previewComplete(text != null);
        if (err != null) self.failed = true;
    }
    log.info("event=work-finished applied={} canceled={}", .{ may_update, self.cancel.isCancelled() != 0 });
    self.app.as(gio.Application).release();
}

fn cleanup(self: *State) void {
    if (self.cleaned) return;
    self.cleaned = true;
    for (self.sources) |id| if (id != 0) {
        _ = glib.Source.remove(id);
    };
    for (self.connections[0..self.connection_count]) |connection|
        gobject.signalHandlerDisconnect(connection.object, connection.id);
    if (self.session_source != 0) _ = glib.Source.remove(self.session_source);
    if (self.identity_source != 0) _ = glib.Source.remove(self.identity_source);
    if (self.surfaces) |*surfaces| surfaces.settings_observer = null;
    if (self.settings_server) |*server| server.deinit();
    if (self.control_server) |*server| server.deinit();
    if (self.surfaces) |*surfaces| surfaces.deinit();
    if (self.gallery) |*gallery| gallery.deinit();
    if (self.window) |window| {
        window.destroy();
        window.unref();
    }
    gtk.StyleContext.removeProviderForDisplay(self.display, self.css.as(gtk.StyleProvider));
    self.builder.unref();
    self.css.unref();
    self.cancel.unref();
    self.app.unref();
    if (options.test_hooks) std.debug.assert(self.watched_objects == 0);
    log.info("event=cleanup pending={} watched_objects={d}", .{ self.life.pending, self.watched_objects });
}

pub fn run(mode: Mode, hooks: TestHooks) !u8 {
    const raw = @embedFile("pearl_resources");
    const bytes = glib.Bytes.newStatic(raw.ptr, raw.len);
    defer bytes.unref();
    var err: ?*glib.Error = null;
    const resource = gio.Resource.newFromData(bytes, &err) orelse {
        defer err.?.free();
        log.err("event=resource-error message={s}", .{err.?.f_message orelse "Unknown GTK error"});
        return error.InvalidResources;
    };
    defer resource.unref();
    gio.resourcesRegister(resource);
    defer gio.resourcesUnregister(resource);

    // No named application service or remote activation. Verified uniqueness comes
    // with T04/T05; using an unverified global ID here would cross sessions.
    const app = gtk.Application.new(null, .{ .non_unique = true });
    const builder = gtk.Builder.new();
    const css = gtk.CssProvider.new();
    const cancel = gio.Cancellable.new();
    var self: State = .{
        .app = app,
        .builder = builder,
        .css = css,
        .cancel = cancel,
        .display = gdk.Display.getDefault().?,
        .main_thread = glib.Thread.self(),
        .mode = mode,
        .hooks = hooks,
        .work = .{ .delay_ms = hooks.worker_delay_ms },
    };
    for ([_]*gobject.Object{ app.as(gobject.Object), builder.as(gobject.Object), css.as(gobject.Object), cancel.as(gobject.Object) }) |object| self.watch(object);
    defer if (self.aqueous) |*client| client.deinit();
    defer cleanup(&self);
    if (builder.addFromResource(if (mode == .demo) "/org/aqueous/Pearl/gallery.ui" else "/org/aqueous/Pearl/session.ui", &err) == 0) {
        defer err.?.free();
        log.err("event=resource-error message={s}", .{err.?.f_message orelse "Unknown GTK error"});
        return error.InvalidResources;
    }
    self.remember(css.as(gobject.Object), gtk.CssProvider.signals.parsing_error.connect(css, *State, cssError, &self, .{}));
    const stylesheet = gio.resourcesLookupData("/org/aqueous/Pearl/style.css", .{}, &err) orelse return error.InvalidResources;
    defer stylesheet.unref();
    var stylesheet_length: usize = 0;
    const stylesheet_data: [*]const u8 = @ptrCast(stylesheet.getData(&stylesheet_length).?);
    const generated_css = try theme.css(std.heap.page_allocator, stylesheet_data[0..stylesheet_length]);
    defer std.heap.page_allocator.free(generated_css);
    css.loadFromString(generated_css);
    if (self.failed) return error.InvalidCss;
    gtk.StyleContext.addProviderForDisplay(self.display, css.as(gtk.StyleProvider), 600);
    self.remember(app.as(gobject.Object), gio.Application.signals.activate.connect(app.as(gio.Application), *State, activate, &self, .{}));
    self.sources[0] = unix.signalAdd(2, signalStop, &self);
    self.sources[1] = unix.signalAdd(15, signalStop, &self);
    const status = app.as(gio.Application).run(0, null);
    if (self.life.phase == .stopping) self.life.finish();
    std.debug.assert(!self.life.pending);
    if (self.logout_requested) finishLogout(&self);
    return if (status != 0 or self.failed) 1 else 0;
}
