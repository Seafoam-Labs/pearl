//! Native ext-session-lock surface owner. Only a successful PAM conversation unlocks.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const unix = @import("giounix2");
const glib = @import("glib2");
const glibunix = @import("glibunix2");
const object = @import("gobject2");
const lock = @import("gtk4sessionlock1");
const w = @import("../ui/components/widgets.zig");
const wire = @import("conversation.zig");
const a = std.heap.c_allocator;
const View = struct { window: *gtk.Window, monitor: *gdk.Monitor, panel: *gtk.Box, picture: *gtk.Picture, clock: *gtk.Label, date: *gtk.Label, message: *gtk.Label, entry: *gtk.Entry, button: *gtk.Button };
const Screen = struct {
    loop: *glib.MainLoop,
    instance: *lock.Instance,
    display: *gdk.Display,
    preferences: @import("../config/service.zig").Service = undefined,
    views: [64]?View = @splat(null),
    acquired: bool = false,
    ready_fd: bool,
    failed: bool = false,
    auth: ?*gio.Subprocess = null,
    auth_source: c_uint = 0,
    deadline: c_uint = 0,
    packet: wire.Packet = .{},
    received: usize = 0,
    waiting: bool = false,
    echo: bool = false,
    message: @import("../services/policy.zig").Text(1024) = .{},
    cooldown: i64 = 0,
    fn update(self: *Screen) void {
        const now = glib.DateTime.newNowLocal();
        defer if (now) |t| t.unref();
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            self.preferences.style(v.window.as(gtk.Widget), v.panel.as(gtk.Widget));
            const wallpaper = self.preferences.prefs().wallpaper.mode;
            const texture = if (self.preferences.live) |job| job.texture else null;
            v.picture.setPaintable(if (texture != null and (wallpaper == .cover or wallpaper == .contain)) texture.?.as(gdk.Paintable) else null);
            v.picture.setContentFit(if (wallpaper == .contain) .contain else .cover);
            v.message.setText(self.message.z());
            v.entry.setVisibility(@intFromBool(self.echo));
            v.entry.setInputPurpose(if (self.echo) .free_form else .password);
            v.entry.setPlaceholderText(if (self.echo) "Response" else "Password");
            v.entry.as(gtk.Widget).setSensitive(@intFromBool(self.waiting));
            v.button.setLabel(if (self.waiting) "Unlock" else if (self.auth != null) "Authenticating…" else "Try again");
            v.button.as(gtk.Widget).setSensitive(@intFromBool(self.waiting or (self.auth == null and self.acquired and glib.getMonotonicTime() >= self.cooldown)));
            if (now) |t| {
                if (t.format("%H:%M")) |s| {
                    v.clock.setText(s);
                    glib.free(s);
                }
                if (t.format("%A, %B %e")) |s| {
                    v.date.setText(s);
                    glib.free(s);
                }
            }
        };
    }
    fn clearSecrets(self: *Screen) void {
        for (&self.views) |*slot| if (slot.*) |*v| v.entry.as(gtk.Editable).setText("");
        self.packet.wipe();
        self.received = 0;
    }
    fn cancelAuth(self: *Screen) void {
        self.waiting = false;
        if (self.auth_source != 0) _ = glib.Source.remove(self.auth_source);
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.auth_source = 0;
        self.deadline = 0;
        if (self.auth) |p| {
            p.forceExit();
            p.unref();
            self.auth = null;
        }
        self.clearSecrets();
    }
    fn startAuth(self: *Screen) void {
        if (!self.acquired or self.auth != null or glib.getMonotonicTime() < self.cooldown) return;
        self.clearSecrets();
        var exe: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
        if (n <= 0) return;
        exe[@intCast(n)] = 0;
        const launcher = gio.SubprocessLauncher.new(.{ .stdin_pipe = true, .stdout_pipe = true, .stderr_silence = true });
        defer launcher.unref();
        const argv = [_:null]?[*:0]const u8{ @ptrCast(&exe), "--pam" };
        var err: ?*glib.Error = null;
        self.auth = launcher.spawnv(@ptrCast(&argv), &err);
        if (err) |e| e.free();
        const p = self.auth orelse {
            self.message.set("Authentication unavailable. Try again.");
            self.update();
            return;
        };
        // GSubprocess reaps children even when a cancelled conversation exits later.
        const fd = object.ext.cast(unix.InputStream, p.getStdoutPipe().?).?.getFd();
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        self.auth_source = glibunix.fdAdd(fd, .{ .in = true, .hup = true, .err = true }, authReadable, self);
        self.deadline = glib.timeoutAdd(90000, authExpired, self);
        self.message.set("Authenticating…");
        self.update();
    }
    fn reply(self: *Screen, entry: *gtk.Entry) void {
        if (!self.waiting) {
            self.startAuth();
            return;
        }
        var packet: wire.Packet = .{ .kind = 101 };
        defer packet.wipe();
        packet.set(std.mem.span(entry.as(gtk.Editable).getText()));
        self.clearSecrets();
        self.waiting = false;
        const fd = object.ext.cast(unix.OutputStream, self.auth.?.getStdinPipe().?).?.getFd();
        if (!wire.write(fd, &packet)) {
            self.cancelAuth();
            self.message.set("Authentication failed. Try again.");
        }
        self.update();
    }
    fn authReadable(fd: c_int, condition: glib.IOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        const bytes = std.mem.asBytes(&self.packet);
        const n = std.c.read(fd, bytes[self.received..].ptr, bytes.len - self.received);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .AGAIN and !condition.hup and !condition.err) return 1;
            self.cancelAuth();
            self.message.set("Authentication failed. Try again.");
            self.cooldown = glib.getMonotonicTime() + 2000000;
            self.update();
            return 0;
        }
        self.received += @intCast(n);
        if (self.received != bytes.len) return 1;
        self.received = 0;
        if (!self.packet.valid()) {
            self.cancelAuth();
            self.message.set("Invalid authentication response.");
            self.update();
            return 0;
        }
        switch (self.packet.kind) {
            1, 2 => {
                self.waiting = true;
                self.echo = self.packet.kind == 2;
                self.message.set(self.packet.bytes[0..self.packet.length]);
                self.update();
                for (&self.views) |*slot| if (slot.*) |*v| {
                    if (v.monitor.isValid() != 0) _ = v.entry.as(gtk.Widget).grabFocus();
                };
            },
            3, 4 => {
                self.message.set(self.packet.bytes[0..self.packet.length]);
                self.update();
            },
            100 => {
                const success = self.packet.value == 0;
                self.cancelAuth();
                if (success and self.acquired and self.instance.isLocked() != 0) {
                    self.instance.unlock();
                } else {
                    self.cooldown = glib.getMonotonicTime() + 2000000;
                    self.message.set("Authentication failed. Try again.");
                    self.update();
                }
                return 0;
            },
            else => {
                self.cancelAuth();
                self.message.set("Authentication unavailable.");
                self.update();
                return 0;
            },
        }
        self.packet.wipe();
        return 1;
    }
    fn authExpired(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        self.cancelAuth();
        self.message.set("Authentication timed out. Try again.");
        self.update();
        return 0;
    }
    fn entered(entry: *gtk.Entry, self: *Screen) callconv(.c) void {
        self.reply(entry);
    }
    fn clicked(button: *gtk.Button, self: *Screen) callconv(.c) void {
        for (&self.views) |*slot| if (slot.*) |*v| if (v.button == button) {
            self.reply(v.entry);
            return;
        };
    }
    fn key(_: *gtk.EventControllerKey, code: c_uint, _: c_uint, _: gdk.ModifierType, self: *Screen) callconv(.c) c_int {
        if (code != 0xff1b) return 0;
        self.cancelAuth();
        self.message.set("Authentication cancelled. The session remains locked.");
        self.update();
        return 1;
    }
    fn close(_: *gtk.Window, _: *Screen) callconv(.c) c_int {
        return 1;
    }
    fn monitor(instance: *lock.Instance, output: *gdk.Monitor, self: *Screen) callconv(.c) void {
        var target: ?*?View = null;
        for (&self.views) |*slot| {
            if (slot.*) |*v| if (v.monitor.isValid() == 0) {
                // Ref-held widgets may outlive the removed output; release only here.
                v.window.unref();
                v.monitor.unref();
                slot.* = null;
            };
            if (slot.* == null and target == null) target = slot;
        }
        const slot = target orelse {
            self.failed = true;
            std.log.err("event=lock-output-limit", .{});
            return;
        };
        const window = gtk.Window.new();
        window.ref();
        output.ref();
        window.setTitle("Pearl · Locked");
        for ([_][*:0]const u8{ "pearl-root", "pearl-shell", "pearl-dark", "pearl-wallpaper", "pearl-lock", "background" }) |c| window.as(gtk.Widget).addCssClass(c);
        const overlay = gtk.Overlay.new();
        window.setChild(overlay.as(gtk.Widget));
        const picture = gtk.Picture.new();
        picture.setCanShrink(1);
        overlay.setChild(picture.as(gtk.Widget));
        const column = w.column(20);
        column.as(gtk.Widget).setHalign(.center);
        column.as(gtk.Widget).setValign(.center);
        column.as(gtk.Widget).setMarginStart(24);
        column.as(gtk.Widget).setMarginEnd(24);
        const clock = w.label("", "pearl-lock-clock");
        clock.setXalign(0.5);
        column.append(clock.as(gtk.Widget));
        const date = w.label("", "pearl-lock-date");
        date.setXalign(0.5);
        column.append(date.as(gtk.Widget));
        const panel = w.card();
        panel.as(gtk.Widget).setSizeRequest(320, -1);
        panel.as(gtk.Widget).addCssClass("pearl-lock-card");
        const avatar = gtk.Image.newFromIconName("avatar-default-symbolic");
        avatar.setPixelSize(48);
        panel.append(avatar.as(gtk.Widget));
        const username = w.label(glib.getRealName(), "pearl-title");
        username.setXalign(0.5);
        panel.append(username.as(gtk.Widget));
        const message = w.label("Locking…", "pearl-secondary");
        message.setWrap(1);
        message.setMaxWidthChars(36);
        panel.append(message.as(gtk.Widget));
        const entry = gtk.Entry.new();
        entry.setVisibility(0);
        entry.setMaxLength(1023);
        entry.setInputPurpose(.password);
        entry.setPlaceholderText("Password");
        w.name(entry.as(gtk.Widget), "Unlock password");
        panel.append(entry.as(gtk.Widget));
        const button = gtk.Button.newWithLabel("Unlock");
        button.as(gtk.Widget).addCssClass("pearl-primary");
        panel.append(button.as(gtk.Widget));
        column.append(panel.as(gtk.Widget));
        const footer = w.label("Session locked", "pearl-secondary");
        footer.setXalign(0.5);
        column.append(footer.as(gtk.Widget));
        overlay.addOverlay(column.as(gtk.Widget));
        slot.* = .{ .window = window, .monitor = output, .panel = panel, .picture = picture, .clock = clock, .date = date, .message = message, .entry = entry, .button = button };
        _ = gtk.Entry.signals.activate.connect(entry, *Screen, entered, self, .{});
        _ = gtk.Button.signals.clicked.connect(button, *Screen, clicked, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *Screen, close, self, .{});
        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Screen, key, self, .{});
        window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        instance.assignWindowToMonitor(window, output);
        window.present();
        self.update();
        std.log.info("event=lock-monitor", .{});
    }
    fn locked(_: *lock.Instance, self: *Screen) callconv(.c) void {
        if (self.failed) return;
        self.acquired = true;
        if (self.ready_fd) {
            _ = std.c.write(3, "L", 1);
            _ = std.c.close(3);
            self.ready_fd = false;
        }
        std.log.info("event=lock-acquired", .{});
        self.startAuth();
    }
    fn onFailed(_: *lock.Instance, self: *Screen) callconv(.c) void {
        self.failed = true;
        self.loop.quit();
    }
    fn unlocked(_: *lock.Instance, self: *Screen) callconv(.c) void {
        self.acquired = false;
        self.cancelAuth();
        std.log.info("event=lock-released", .{});
        self.loop.quit();
    }
    fn changed(data: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(data));
        self.update();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.update();
        return 1;
    }
};
pub fn run(ready_fd: bool) !void {
    gtk.init();
    const display = gdk.Display.getDefault() orelse return error.NoDisplay;
    const raw = @embedFile("pearl_resources");
    const bytes = glib.Bytes.newStatic(raw.ptr, raw.len);
    defer bytes.unref();
    const resource = gio.Resource.newFromData(bytes, null) orelse return error.Resources;
    gio.resourcesRegister(resource);
    const app = gio.Application.new("org.aqueous.Pearl.Lock", .{ .non_unique = true });
    var screen: Screen = .{ .loop = glib.MainLoop.new(null, 0), .instance = lock.Instance.new(), .display = display, .ready_fd = ready_fd };
    const css = gtk.CssProvider.new();
    css.loadFromString(".pearl-lock-clock { font-size: 96px; font-weight: 300; letter-spacing: -4px; } .pearl-lock-date { font-size: 20px; } .pearl-lock-card { padding: 28px; border-radius: 28px; } .pearl-lock entry { min-height: 40px; } .pearl-lock button { min-height: 40px; }");
    gtk.StyleContext.addProviderForDisplay(display, css.as(gtk.StyleProvider), 601);
    screen.preferences = .{ .app = app, .display = display, .context = &screen, .changed = Screen.changed };
    try screen.preferences.start();
    _ = lock.Instance.signals.monitor.connect(screen.instance, *Screen, Screen.monitor, &screen, .{});
    _ = lock.Instance.signals.locked.connect(screen.instance, *Screen, Screen.locked, &screen, .{});
    _ = lock.Instance.signals.failed.connect(screen.instance, *Screen, Screen.onFailed, &screen, .{});
    _ = lock.Instance.signals.unlocked.connect(screen.instance, *Screen, Screen.unlocked, &screen, .{});
    _ = glib.timeoutAddSeconds(1, Screen.tick, &screen);
    _ = screen.instance.lock();
    if (!screen.failed) screen.loop.run();
    // No signal handler or shell IPC can call unlock; process death remains fail-closed.
    std.process.exit(if (screen.failed) 1 else 0);
}
