const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const unix = @import("glibunix2");
const object = @import("gobject2");
const options = @import("options.zig");
const nav = @import("../desktop/settings_navigation.zig");
const wire = @import("../aqueous/transport.zig");
const Client = @import("client.zig").Client;
const Identity = @import("identity.zig").Identity;
const Instance = @import("instance.zig").Server;
const Window = @import("window.zig").Window;
const Editor = @import("editor.zig").Editor;
const a = std.heap.c_allocator;
const App = struct {
    app: *gtk.Application,
    window: ?*Window = null,
    identity: ?Identity = null,
    client: Client = undefined,
    editor: Editor = undefined,
    aqueous: @import("aqueous_editor.zig").Editor = undefined,
    instance: ?Instance = null,
    forward: wire.Transport = undefined,
    forwarding: bool = false,
    forward_deadline: c_uint = 0,
    forward_retry: c_uint = 0,
    signals: [2]c_uint = @splat(0),
    target: nav.Target,
    activation: ?[]const u8,
    fixture: bool,
    failed: bool = false,
    held: bool = false,
    fn show(self: *App) !void {
        if (self.window == null) {
            self.window = try Window.create(self.app, self, retry, close, self.fixture, &self.editor, &self.aqueous);
            self.window.?.select(self.target, true);
            self.window.?.present(self.activation);
            std.log.info("event=settings-window-created app_id={s}", .{@import("distribution.zig").appId()});
        }
    }
    fn activate(_: *gio.Application, self: *App) callconv(.c) void {
        if (self.held) {
            if (self.window) |win| win.present(null);
            return;
        }
        self.held = true;
        self.app.as(gio.Application).hold();
        self.identity = Identity.init(gdk.Display.getDefault().?, self, nativeChanged) catch null;
        if (self.identity) |*identity| identity.start();
        self.client.begin();
    }
    fn nativeChanged(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.client.nativeChanged(self.identity.?.session);
        self.aqueous.transport.nativeChanged(self.identity.?.session);
    }
    fn event(context: *anyopaque, value: @import("client.zig").Event) void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (value) {
            .verified => self.claim() catch |err| {
                self.client.stop();
                self.failed = true;
                std.log.err("event=settings-instance-error error={s}", .{@errorName(err)});
                self.app.as(gio.Application).quit();
            },
            .connected => |snapshot| {
                self.show() catch {
                    self.failed = true;
                    self.app.as(gio.Application).quit();
                    return;
                };
                self.window.?.connection(true, null);
                self.editor.connected(self.window.?.target);
                if (!self.fixture and !self.aqueous.online and self.aqueous.transport.phase == .idle) self.aqueous.connect(self.identity.?.session);
                if (snapshot) |p| self.window.?.style(p) catch |err| std.log.err("event=settings-style-error error={s}", .{@errorName(err)});
            },
            .reply => |reply| self.editor.reply(reply),
            .changed => self.editor.changed(),
            .locked => |locked| if (!self.fixture) {
                self.editor.locked(locked);
            },
            .failed => |err| {
                if (!self.fixture) self.editor.disconnected();
                self.show() catch {
                    self.failed = true;
                    self.app.as(gio.Application).quit();
                    return;
                };
                self.window.?.connection(false, err);
                std.log.info("event=settings-connection-unavailable error={s}", .{@errorName(err)});
            },
        }
    }
    fn claim(self: *App) !void {
        if (self.instance != null) return;
        self.instance = try Instance.init(self.client.runtime, &self.client.session.?, self.client.display, self, activated);
        self.instance.?.start() catch |err| {
            self.instance.?.deinit();
            self.instance = null;
            if (err != error.AlreadyRunning) return err;
            self.client.stop();
            self.forwarding = true;
            self.forward_deadline = glib.timeoutAdd(5000, forwardExpired, self);
            try self.forwardOpen();
            return;
        };
        std.log.info("event=settings-instance-ready session={s}", .{self.client.session.?});
        try self.show();
    }
    fn forwardOpen(self: *App) !void {
        const path = try @import("activation.zig").endpoint(a, self.client.runtime, &self.client.session.?);
        defer a.free(path);
        @import("client.zig").ownedEndpoint(path) catch |err| {
            if (err == error.Unavailable) {
                self.forward_retry = glib.timeoutAdd(25, retryForward, self);
                return;
            }
            return err;
        };
        try self.forward.open(path);
    }
    fn retryForward(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.forward_retry = 0;
        self.forwardOpen() catch {
            self.failed = true;
            self.app.as(gio.Application).quit();
        };
        return 0;
    }
    fn forwardEvent(context: *anyopaque, value: wire.Event) void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (value) {
            .sent => {},
            .connected => self.sendActivation() catch {
                self.failed = true;
                self.app.as(gio.Application).quit();
            },
            .failed => {
                self.failed = true;
                self.app.as(gio.Application).quit();
            },
            .frame => |bytes| {
                const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch {
                    self.failed = true;
                    self.app.as(gio.Application).quit();
                    return;
                };
                defer parsed.deinit();
                const v = parsed.value;
                const ok = if (v == .object) v.object.get("ok") else null;
                const version = if (v == .object) v.object.get("settings") else null;
                self.failed = ok == null or ok.? != .bool or !ok.?.bool or version == null or version.? != .integer or version.?.integer != 1;
                // Stop before EOF can turn a successful forwarding reply into failure.
                self.forward.close();
                self.app.as(gio.Application).quit();
            },
        }
    }
    fn sendActivation(self: *App) !void {
        std.log.info("event=settings-forward activation_context={}", .{self.activation != null});
        const request: @import("activation.zig").Request = .{ .session = &self.client.session.?, .display = self.client.display, .page = self.target.page, .section = self.target.section, .activation = self.activation };
        const json = try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false });
        defer a.free(json);
        const frame = try std.fmt.allocPrint(a, "{s}\n", .{json});
        defer a.free(frame);
        try self.forward.send(frame);
    }
    fn forwardExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        self.forward_deadline = 0;
        self.failed = true;
        self.app.as(gio.Application).quit();
        return 0;
    }
    fn activated(context: *anyopaque, request: @import("activation.zig").Request, alloc: std.mem.Allocator) ![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        if (request.op == .probe) {
            if (@import("build_options").test_hooks) return if (self.window) |win| win.probe(alloc) else error.Unavailable;
            return error.Unsupported;
        }
        // This endpoint is scoped to native identity even when Pearl is absent.
        const native = self.identity.?.session orelse return error.Unavailable;
        if (!std.mem.eql(u8, &native, request.session)) return error.StaleSession;
        std.log.info("event=settings-activation activation_context={}", .{request.activation != null});
        try self.show();
        if (!self.fixture and self.editor.state.locked) return error.Locked;
        self.window.?.requestSelect(request.target(), true);
        self.window.?.present(request.activation);
        return "{\"accepted\":true}";
    }
    fn editorEvent(context: *anyopaque, event_: @import("editor.zig").Event) void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (event_) {
            .changed => if (self.window) |window| {
                window.editingChanged();
            },
            .selected => |selection| {
                self.target = selection.target;
                if (self.window) |window| window.select(selection.target, selection.external);
            },
            .launch_network_editor => if (self.window) |window| {
                @import("live_view.zig").launchNetworkEditor(window.window) catch |err| {
                    self.editor.error_code.set(@errorName(err));
                    window.editingChanged();
                };
            },
            .close_ready => self.app.as(gio.Application).quit(),
            .close_failed => if (self.window) |window| {
                window.closeFailure();
            },
            .locked => |locked| if (self.window) |window| {
                window.locked(locked);
            },
        }
    }
    fn aqueousEvent(context: *anyopaque, event_: @import("aqueous_editor.zig").Event) void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (event_) {
            .changed => if (self.window) |window| window.aqueousChanged(),
            .close_ready => self.editor.close(),
            .close_failed => if (self.window) |window| window.closeFailure(),
        }
    }
    fn retry(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.client.begin();
    }
    fn close(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.fixture) self.app.as(gio.Application).quit() else self.aqueous.close();
    }
    fn stopped(data: ?*anyopaque) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(data.?));
        close(self);
        return 1;
    }
};
fn env(key: [*:0]const u8) [:0]const u8 {
    return if (glib.getenv(key)) |value| std.mem.span(value) else "";
}
pub fn run(target: nav.Target) !u8 {
    // Consume launcher context once; do not keep it available for child launches.
    const xdg_token = env("XDG_ACTIVATION_TOKEN");
    const raw_token = if (xdg_token.len > 0) xdg_token else env("DESKTOP_STARTUP_ID");
    var token = if (raw_token.len > 0 and raw_token.len <= 4096) try a.dupe(u8, raw_token) else null;
    defer if (token) |v| a.free(v);
    glib.unsetenv("XDG_ACTIVATION_TOKEN");
    glib.unsetenv("DESKTOP_STARTUP_ID");
    if (gtk.initCheck() == 0) return error.DisplayUnavailable;
    // GDK may consume startup notification before application startup. Retrieve
    // its retained context as well as the environment used by direct launches.
    if (token == null) {
        if (object.ext.cast(@import("gdkwayland4").WaylandDisplay, gdk.Display.getDefault().?)) |display_| {
            if (display_.getStartupNotificationId()) |id| {
                const value = std.mem.span(id);
                if (value.len > 0 and value.len <= 4096) token = try a.dupe(u8, value);
            }
        }
    }

    std.log.info("event=settings-launch activation_context={}", .{token != null});
    const raw = @embedFile("pearl_resources");
    const bytes = glib.Bytes.newStatic(raw.ptr, raw.len);
    defer bytes.unref();
    const resource = gio.Resource.newFromData(bytes, null) orelse return error.InvalidResources;
    defer resource.unref();
    gio.resourcesRegister(resource);
    defer gio.resourcesUnregister(resource);
    gtk.IconTheme.getForDisplay(gdk.Display.getDefault().?).addResourcePath("/org/aqueous/Pearl/icons");
    const app = gtk.Application.new(@import("distribution.zig").appId(), .{ .non_unique = true });
    defer app.unref();
    const display = try @import("../cli/protocol.zig").displayPath(a, env("XDG_RUNTIME_DIR"), env("WAYLAND_DISPLAY"));
    defer a.free(display);
    var self: App = .{ .app = app, .target = target, .activation = token, .fixture = @import("build_options").test_hooks and std.mem.eql(u8, env("PEARL_SETTINGS_FIXTURE"), "1") };
    self.client = .{ .context = &self, .notify = App.event, .runtime = env("XDG_RUNTIME_DIR"), .display = display, .aqueous_path = env("AQUEOUS_SOCKET") };
    self.client.init();
    self.editor = .{ .client = &self.client, .context = &self, .notify = App.editorEvent };
    self.aqueous = .{ .context = &self, .notify = App.aqueousEvent };
    self.aqueous.init(&self.client);
    defer self.aqueous.deinit();
    defer self.editor.deinit();
    defer self.client.deinit();
    self.forward = wire.Transport.init(&self, App.forwardEvent);
    self.forward.framer.limit = 8192;
    defer self.forward.deinit();
    defer {
        if (self.forward_deadline != 0) _ = glib.Source.remove(self.forward_deadline);
        if (self.forward_retry != 0) _ = glib.Source.remove(self.forward_retry);
        for (self.signals) |id| if (id != 0) {
            _ = glib.Source.remove(id);
        };
        if (self.instance) |*instance| instance.deinit();
        if (self.identity) |*identity| identity.deinit();
        if (self.window) |win| win.destroy();
        if (self.held) app.as(gio.Application).release();
    }
    _ = gio.Application.signals.activate.connect(app.as(gio.Application), *App, App.activate, &self, .{});
    self.signals = .{ unix.signalAdd(2, App.stopped, &self), unix.signalAdd(15, App.stopped, &self) };
    const result = app.as(gio.Application).run(0, null);
    return if (self.failed) 3 else @intCast(result);
}
