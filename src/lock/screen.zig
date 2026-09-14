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
const options = @import("build_options");
const View = struct { window: *gtk.Window, monitor: *gdk.Monitor, panel: *gtk.Box, picture: *gtk.Picture, clock: *gtk.Label, date: *gtk.Label, message: *gtk.Label, entry: *gtk.Entry, button: *gtk.Button, caps: *gtk.Label, viewport: *gtk.Viewport, avatar: *gtk.Image, footer: *gtk.Label, monitor_signal: c_ulong };
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
    cooldown_source: c_uint = 0,
    clock_updates: usize = 0,
    ui_updates: usize = 0,
    keyboard: ?*gdk.Device = null,
    caps_on: bool = false,
    cancel_requested: bool = false,
    monitor_source: c_uint = 0,
    pending_monitors: [64]*gdk.Monitor = undefined,
    pending_count: usize = 0,
    assigning: bool = false,
    assignment_source: c_uint = 0,
    fn appearance(self: *Screen) void {
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            self.preferences.style(v.window.as(gtk.Widget), v.panel.as(gtk.Widget));
            const wallpaper = self.preferences.prefs().wallpaper.mode;
            const texture = if (self.preferences.live) |job| job.texture else null;
            v.picture.setPaintable(if (texture != null and (wallpaper == .cover or wallpaper == .contain)) texture.?.as(gdk.Paintable) else null);
            v.picture.setContentFit(if (wallpaper == .contain) .contain else .cover);
            var geometry: gdk.Rectangle = undefined;
            v.monitor.getGeometry(&geometry);
            const short = geometry.f_height < 400;
            v.clock.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.date.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.avatar.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.footer.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.panel.setSpacing(if (short) 8 else 16);
            if (geometry.f_width < 500 or geometry.f_height < 600) v.window.as(gtk.Widget).addCssClass("pearl-lock-small") else v.window.as(gtk.Widget).removeCssClass("pearl-lock-small");
        };
    }
    fn updateClock(self: *Screen) void {
        self.clock_updates += 1;
        const now = glib.DateTime.newNowLocal() orelse return;
        defer now.unref();
        const time = now.format("%H:%M") orelse return;
        defer glib.free(time);
        const date = now.format("%A, %B %e") orelse return;
        defer glib.free(date);
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            v.clock.setText(time);
            v.date.setText(date);
        };
    }
    fn update(self: *Screen) void {
        self.ui_updates += 1;
        var views: usize = 0;
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            views += 1;
            if (!std.mem.eql(u8, std.mem.span(v.message.getText()), self.message.slice())) {
                v.message.as(gtk.Accessible).announce(self.message.z(), .medium);
            }
            w.name(v.entry.as(gtk.Widget), if (self.waiting) self.message.z() else "Authentication response");
            v.message.setText(self.message.z());
            v.entry.setVisibility(@intFromBool(self.echo));
            v.entry.setInputPurpose(if (self.echo) .free_form else .password);
            v.entry.setPlaceholderText(if (self.echo) "Response" else "Password");
            // Keep focus-out delivery enabled while moving focus to Retry.
            // Insensitive GtkText widgets can drop that event and retain IM focus.
            v.entry.as(gtk.Editable).setEditable(@intFromBool(self.waiting));
            v.button.setLabel(if (self.waiting) "Unlock" else if (self.auth != null) "Authenticating…" else "Try again");
            v.button.as(gtk.Widget).setSensitive(@intFromBool(self.waiting or (self.auth == null and self.acquired and glib.getMonotonicTime() >= self.cooldown)));
            v.caps.as(gtk.Widget).setVisible(@intFromBool(self.caps_on));
            if (!self.waiting and self.auth == null and self.acquired) v.window.setFocus(v.button.as(gtk.Widget));
            if (options.test_hooks) {
                std.debug.assert(object.ext.cast(gtk.PasswordEntryBuffer, v.entry.getBuffer()) != null);
                const backend = glib.getenv("GTK_A11Y");
                if (backend != null and std.mem.eql(u8, std.mem.span(backend.?), "test")) {
                    const failure = gtk.testAccessibleCheckProperty(v.entry.as(gtk.Accessible), .label, if (self.waiting) self.message.z().ptr else @as([*:0]const u8, "Authentication response"));
                    std.debug.assert(@intFromPtr(failure) == 0);
                }
            }
        };
        const remaining = self.cooldown - glib.getMonotonicTime();
        if (self.cooldown_source == 0 and remaining > 0) {
            self.cooldown_source = glib.timeoutAdd(@intCast(@divTrunc(remaining, 1000) + 1), cooled, self);
        }
        if (options.test_hooks) std.log.info("event=lock-ui views={d} waiting={} echo={} caps={} auth={} acquired={} updates={d} clocks={d}", .{ views, self.waiting, self.echo, self.caps_on, self.auth != null, self.acquired, self.ui_updates, self.clock_updates });
    }
    fn cooled(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.cooldown_source = 0;
        self.update();
        return 0;
    }
    fn keyboardChanged(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        const caps = self.keyboard.?.getCapsLockState() != 0;
        if (caps == self.caps_on) return;
        self.caps_on = caps;
        for (&self.views) |*slot| if (slot.*) |*v| if (v.monitor.isValid() != 0) {
            v.caps.as(gtk.Widget).setVisible(@intFromBool(caps));
            v.caps.as(gtk.Accessible).announce(if (caps) "Caps Lock is on" else "Caps Lock is off", .medium);
        };
        if (options.test_hooks) std.log.info("event=lock-caps enabled={}", .{caps});
    }
    fn monitorChanged(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        // GTK and gtk4-session-lock still use the native window while delivering
        // monitor notifications. Dispose our refs only after that dispatch ends.
        if (self.monitor_source == 0) self.monitor_source = glib.idleAdd(reapMonitors, self);
    }
    fn reapMonitors(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.monitor_source = 0;
        // Drop removed outputs promptly, including their entry buffers and refs.
        for (&self.views) |*slot| if (slot.*) |*v| if (v.monitor.isValid() == 0) {
            v.entry.as(gtk.Editable).setText("");
            object.signalHandlerDisconnect(v.monitor.as(object.Object), v.monitor_signal);
            v.window.unref();
            v.monitor.unref();
            slot.* = null;
        };
        self.appearance();
        return 0;
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
        if (self.cancel_requested or !self.acquired or self.auth != null or glib.getMonotonicTime() < self.cooldown) return;
        self.clearSecrets();
        var exe: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
        if (n <= 0) {
            self.message.set("Authentication unavailable. Try again.");
            self.update();
            return;
        }
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
        self.deadline = glib.timeoutAdd(if (options.test_hooks and glib.getenv("PEARL_TEST_FAST_AUTH") != null) 1500 else 90000, authExpired, self);
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
        if (!packet.set(std.mem.span(entry.as(gtk.Editable).getText()))) {
            self.clearSecrets();
            self.message.set("Response is too long (maximum 1023 UTF-8 bytes). Try again.");
            self.update();
            _ = entry.as(gtk.Widget).grabFocus();
            return;
        }
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
        if (self.cancel_requested) {
            self.auth_source = 0;
            return 0;
        }
        const bytes = std.mem.asBytes(&self.packet);
        const n = std.c.read(fd, bytes[self.received..].ptr, bytes.len - self.received);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) return 1;
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
                for (&self.views) |*slot| if (slot.*) |*v| v.entry.as(gtk.Editable).setText("");
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
        if ((code == 0xff0d or code == 0xff8d) and self.auth == null) {
            self.startAuth();
            return 1;
        }
        if (code != 0xff1b) return 0;
        if (!self.cancel_requested) {
            self.cancel_requested = true;
            self.waiting = false;
            _ = glib.idleAddFull(-100, cancelFromKey, self, null);
        }
        return 1;
    }
    fn cancelFromKey(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.cancelAuth();
        self.cancel_requested = false;
        self.message.set("Authentication cancelled. The session remains locked.");
        self.update();
        return 0;
    }
    fn close(_: *gtk.Window, _: *Screen) callconv(.c) c_int {
        return 1;
    }
    fn monitor(_: *lock.Instance, output: *gdk.Monitor, self: *Screen) callconv(.c) void {
        // assignWindowToMonitor maps GTK and can round-trip Wayland, delivering
        // another monitor signal recursively. Serialize assignments outside the
        // signal so the library never observes a half-initialized lock window.
        var kept: usize = 0;
        for (self.pending_monitors[0..self.pending_count]) |pending| {
            if (pending.isValid() != 0) {
                self.pending_monitors[kept] = pending;
                kept += 1;
            } else pending.unref();
        }
        self.pending_count = kept;
        if (self.pending_count == self.pending_monitors.len) {
            self.failed = true;
            std.log.err("event=lock-output-limit", .{});
            return;
        }
        output.ref();
        self.pending_monitors[self.pending_count] = output;
        self.pending_count += 1;
        if (!self.assigning) {
            if (self.assignment_source != 0) _ = glib.Source.remove(self.assignment_source);
            // Coalesce registry churn before mapping. The compositor keeps new
            // outputs blank while their native lock windows are being prepared.
            self.assignment_source = glib.timeoutAdd(100, assignMonitors, self);
        }
    }
    fn assignMonitors(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.assignment_source = 0;
        self.assigning = true;
        defer self.assigning = false;
        while (self.pending_count != 0) {
            const output = self.pending_monitors[0];
            self.pending_count -= 1;
            std.mem.copyForwards(*gdk.Monitor, self.pending_monitors[0..self.pending_count], self.pending_monitors[1 .. self.pending_count + 1]);
            defer output.unref();
            if (output.isValid() == 0) continue;
            if (self.monitor_source != 0) {
                _ = glib.Source.remove(self.monitor_source);
                _ = reapMonitors(self);
            }
            self.createView(self.instance, output);
        }
        return 0;
    }
    fn createView(self: *Screen, instance: *lock.Instance, output: *gdk.Monitor) void {
        var target: ?*?View = null;
        for (&self.views) |*slot| {
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
        column.as(gtk.Widget).setMarginTop(24);
        column.as(gtk.Widget).setMarginBottom(24);
        const clock = w.label("", "pearl-lock-clock");
        clock.setXalign(0.5);
        column.append(clock.as(gtk.Widget));
        const date = w.label("", "pearl-lock-date");
        date.setXalign(0.5);
        column.append(date.as(gtk.Widget));
        const panel = w.card();
        panel.as(gtk.Widget).setSizeRequest(220, -1);
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
        const buffer = gtk.PasswordEntryBuffer.new();
        entry.setBuffer(buffer.as(gtk.EntryBuffer));
        buffer.unref();
        entry.setVisibility(0);
        // Retain one character beyond the byte limit so a long ASCII paste is
        // rejected on submit instead of authenticating its truncated prefix.
        entry.setMaxLength(1024);
        entry.as(gtk.Editable).setWidthChars(10);
        entry.as(gtk.Editable).setMaxWidthChars(24);
        entry.setInputPurpose(.password);
        entry.setPlaceholderText("Password");
        entry.setInputHints(.{ .private = true, .no_spellcheck = true, .no_emoji = true });
        w.name(entry.as(gtk.Widget), "Authentication response");
        panel.append(entry.as(gtk.Widget));
        const caps = w.label("Caps Lock is on", "pearl-secondary");
        caps.as(gtk.Widget).setVisible(0);
        panel.append(caps.as(gtk.Widget));
        const button = gtk.Button.newWithLabel("Unlock");
        button.as(gtk.Widget).addCssClass("pearl-primary");
        panel.append(button.as(gtk.Widget));
        column.append(panel.as(gtk.Widget));
        const footer = w.label("Session locked · Esc cancels authentication", "pearl-secondary");
        footer.setXalign(0.5);
        column.append(footer.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.automatic, .automatic);
        const viewport = gtk.Viewport.new(null, null);
        viewport.setScrollToFocus(1);
        viewport.setChild(column.as(gtk.Widget));
        scroll.setChild(viewport.as(gtk.Widget));
        overlay.addOverlay(scroll.as(gtk.Widget));
        slot.* = .{ .window = window, .monitor = output, .panel = panel, .picture = picture, .clock = clock, .date = date, .message = message, .entry = entry, .button = button, .caps = caps, .viewport = viewport, .avatar = avatar, .footer = footer, .monitor_signal = object.Object.signals.notify.connect(output.as(object.Object), *Screen, monitorChanged, self, .{}) };
        _ = gtk.Entry.signals.activate.connect(entry, *Screen, entered, self, .{});
        _ = gtk.Button.signals.clicked.connect(button, *Screen, clicked, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *Screen, close, self, .{});
        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Screen, key, self, .{});
        window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        instance.assignWindowToMonitor(window, output);
        // Assignment already presents the window. Its internal Wayland roundtrip
        // can remove this output before returning; never present it a second time.
        if (output.isValid() == 0) return;
        self.appearance();
        self.updateClock();
        self.update();
        window.setFocus(if (self.waiting) entry.as(gtk.Widget) else button.as(gtk.Widget));
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
        self.appearance();
        self.update();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.updateClock();
        self.scheduleClock();
        if (options.test_hooks) std.log.info("event=lock-clock updates={d} clocks={d}", .{ self.ui_updates, self.clock_updates });
        return 0;
    }
    fn scheduleClock(self: *Screen) void {
        const now = glib.DateTime.newNowLocal();
        defer if (now) |t| t.unref();
        const delay: c_uint = if (now) |t| @intCast(60 - t.getSecond()) else 60;
        _ = glib.timeoutAddSeconds(delay, tick, self);
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
    css.loadFromString(".pearl-lock-clock { font-size: 6em; font-weight: 300; letter-spacing: -0.04em; } .pearl-lock-date { font-size: 1.3em; } .pearl-lock-card { padding: 28px; border-radius: 28px; } .pearl-lock-small .pearl-lock-clock { font-size: 3em; } .pearl-lock-small .pearl-lock-card { padding: 16px; } .pearl-lock entry { min-height: 40px; } .pearl-lock button { min-height: 40px; }");
    gtk.StyleContext.addProviderForDisplay(display, css.as(gtk.StyleProvider), 601);
    screen.preferences = .{ .app = app, .display = display, .context = &screen, .changed = Screen.changed };
    try screen.preferences.start();
    _ = lock.Instance.signals.monitor.connect(screen.instance, *Screen, Screen.monitor, &screen, .{});
    _ = lock.Instance.signals.locked.connect(screen.instance, *Screen, Screen.locked, &screen, .{});
    _ = lock.Instance.signals.failed.connect(screen.instance, *Screen, Screen.onFailed, &screen, .{});
    _ = lock.Instance.signals.unlocked.connect(screen.instance, *Screen, Screen.unlocked, &screen, .{});
    if (display.getDefaultSeat()) |seat| if (seat.getKeyboard()) |keyboard| {
        screen.keyboard = keyboard;
        screen.caps_on = keyboard.getCapsLockState() != 0;
        _ = object.Object.signals.notify.connect(keyboard.as(object.Object), *Screen, Screen.keyboardChanged, &screen, .{ .detail = "caps-lock-state" });
    };
    screen.scheduleClock();
    _ = screen.instance.lock();
    if (!screen.failed) screen.loop.run();
    // No signal handler or shell IPC can call unlock; process death remains fail-closed.
    std.process.exit(if (screen.failed) 1 else 0);
}
