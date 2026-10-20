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
const presentation = @import("../ui/auth/prompt_view.zig");
const power_mod = @import("power.zig");
const theme = @import("../theme/theme.zig");
const pixbuf = @import("gdkpixbuf2");
const io = @import("../config/io.zig");
const crop = @import("../config/crop_policy.zig");
const artwork = @import("../services/artwork.zig");
const model = @import("../config/preferences.zig");
const published = @import("../config/published_appearance.zig");
const log = std.log.scoped(.lock);
const a = std.heap.c_allocator;
const View = struct { window: *gtk.Window, monitor: *gdk.Monitor, panel: *gtk.Box, picture: *gtk.Picture, clockbox: *gtk.Box, clock: *gtk.Label, date: *gtk.Label, message: *gtk.Label, hint: *gtk.Label, entry: *gtk.Entry, button: *gtk.Button, caps: *gtk.Label, viewport: *gtk.Viewport, avatar: *gtk.Image, cluster: *gtk.Box, sleep_button: *gtk.Button, power_button: *gtk.Button, power_pop: *gtk.Popover, power_menu_box: *gtk.Box, power_confirm_box: *gtk.Box, confirm: *gtk.Button, cancel_power: *gtk.Button, reboot: *gtk.Button, off: *gtk.Button, assigned: bool = false, monitor_signal: c_ulong };
/// The lock's spacing rhythm, drop shadows and float geometry, mirroring the
/// finalized greeter. Box spacing is zero; every gap is an explicit margin so
/// hidden rows collapse cleanly. Raw CSS only: colors belong to the session's
/// own theme provider, never to this sheet.
const lock_css = ".pearl-lock .pearl-lock-clockbox {margin-top:72px;} " ++
    ".pearl-lock .pearl-lock-date {font-size:1.3em; font-weight:600; margin-bottom:6px; text-shadow:0 1px 14px rgb(0 0 0 / 30%);} " ++
    ".pearl-lock .pearl-lock-clock {font-size:5.4em; font-weight:700; letter-spacing:-0.02em; text-shadow:0 2px 22px rgb(0 0 0 / 28%);} " ++
    ".pearl-lock .pearl-lock-form {margin:24px;} " ++
    ".pearl-lock .pearl-lock-card {padding:30px 32px 32px; box-shadow:0 16px 52px rgb(0 0 0 / 10%);} " ++
    ".pearl-lock .pearl-lock-card button, .pearl-lock .pearl-lock-card entry {min-height:26px; padding:8px 12px;} " ++
    ".pearl-lock .pearl-avatar-circle {margin-bottom:18px;} " ++
    ".pearl-lock .pearl-title {margin-bottom:10px;} " ++
    ".pearl-lock .pearl-field {margin-bottom:24px;} " ++
    ".pearl-lock .pearl-caps {margin-top:-4px; margin-bottom:14px;} " ++
    ".pearl-lock .pearl-float-slot {min-height:64px;} " ++
    ".pearl-lock .pearl-float-status {color:#fff; text-shadow:0 1px 10px rgb(0 0 0 / 45%); transition:opacity 150ms linear;} " ++
    ".pearl-gtk .pearl-lock-card {background:@theme_bg_color; color:@theme_fg_color; box-shadow:none;} " ++
    ".pearl-reduced *, .pearl-reduced-motion * {transition:none; animation:none;} " ++
    ".pearl-lock.pearl-lock-small .pearl-lock-clockbox {margin-top:36px;} " ++
    ".pearl-lock.pearl-lock-small .pearl-lock-clock {font-size:3em;} " ++
    ".pearl-lock.pearl-lock-small .pearl-lock-card {padding:22px 24px 24px;} " ++
    ".pearl-lock.pearl-lock-small .pearl-avatar-circle {margin-bottom:12px;} " ++
    ".pearl-lock.pearl-lock-small .pearl-title {margin-bottom:8px;} " ++
    ".pearl-lock.pearl-lock-small .pearl-field {margin-bottom:16px;} " ++
    ".pearl-lock.pearl-lock-small .pearl-float-slot {min-height:58px;} ";
const Screen = struct {
    loop: *glib.MainLoop,
    instance: *lock.Instance,
    display: *gdk.Display,
    preferences: @import("../config/service.zig").Service = undefined,
    style: *gtk.CssProvider = undefined,
    styled: bool = false,
    style_container: [8]u8 = @splat(0),
    style_percent: u16 = 0,
    style_light: bool = false,
    power: power_mod.Power = undefined,
    pending_power: ?power_mod.Action = null,
    theme_ready: bool = false,
    present_source: c_uint = 0,
    boot_texture: ?*gdk.Texture = null,
    boot_palette: theme.Palette = undefined,
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
    prompt: @import("../services/policy.zig").Text(1024) = .{},
    sticky_status: bool = false,
    prompted: bool = false,
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
    /// Session theming owns every color; this sheet carries only the frost
    /// alpha and the floating status ink, both of which follow the live
    /// palette and the bar opacity preference.
    fn restyle(self: *Screen) void {
        const prefs = self.preferences.prefs();
        const palette = if (self.preferences.live) |job| job.palette else self.boot_palette;
        const percent: u16 = if (prefs.bar.background_opacity.mode == .custom) @as(u16, prefs.bar.background_opacity.percent) else 0xffff;
        const light = prefs.theme.variant == .light and prefs.theme.mode != .gtk;
        var container: [8]u8 = @splat(0);
        const hex = palette.container[0..@min(palette.container.len, container.len - 1)];
        @memcpy(container[0..hex.len], hex);
        if (self.styled and percent == self.style_percent and light == self.style_light and std.mem.eql(u8, &container, &self.style_container)) return;
        self.styled = true;
        self.style_percent = percent;
        self.style_light = light;
        self.style_container = container;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const frost = if (percent != 0xffff) std.fmt.allocPrint(arena.allocator(), ".pearl-lock .pearl-lock-card, .pearl-lock .pearl-cluster {{background:alpha({s}, {d:.2});}} ", .{ palette.container, @as(f32, @floatFromInt(percent)) / 100 }) catch "" else "";
        const ink = if (light) ".pearl-lock .pearl-float-status {color:#241d33; text-shadow:0 1px 10px rgb(255 255 255 / 55%);} " else "";
        const css = std.fmt.allocPrintSentinel(arena.allocator(), "{s}{s}{s}", .{ lock_css, frost, ink }, 0) catch return;
        self.style.loadFromString(css);
    }
    /// Mapping a view presents its window; the compositor keeps the output blank
    /// until then, so views wait for the session theme and wallpaper to land once.
    fn presentView(self: *Screen, v: *View) void {
        if (v.assigned) return;
        v.assigned = true;
        // Assignment already presents the window. Its internal Wayland roundtrip
        // can remove this output before returning; never present it a second time.
        self.instance.assignWindowToMonitor(v.window, v.monitor);
        if (v.monitor.isValid() == 0) return;
        self.appearance();
        self.updateClock();
        self.update();
        v.window.setFocus(if (self.waiting) v.entry.as(gtk.Widget) else v.button.as(gtk.Widget));
        log.info("event=lock-monitor", .{});
    }
    fn releaseViews(self: *Screen) void {
        self.theme_ready = true;
        if (self.present_source != 0) {
            _ = glib.Source.remove(self.present_source);
            self.present_source = 0;
        }
        for (&self.views) |*slot| if (slot.*) |*v| if (v.monitor.isValid() != 0) self.presentView(v);
    }
    fn presentDeadline(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.present_source = 0;
        self.releaseViews();
        return 0;
    }
    /// Decode the session wallpaper synchronously so the first presented frame
    /// already shows it; the config service job later supplies the same texture.
    fn bootWallpaper(self: *Screen, prefs: model.Preferences) void {
        if (prefs.wallpaper.mode != .cover and prefs.wallpaper.mode != .contain) return;
        if (prefs.wallpaper.path.len == 0) return;
        const pz = a.dupeZ(u8, prefs.wallpaper.path) catch return;
        defer a.free(pz);
        const disk = io.read(a, pz, 16 * 1024 * 1024, null) catch return;
        defer a.free(disk.bytes);
        if (!artwork.dimensions(disk.bytes)) return;
        const storage = glib.Bytes.new(disk.bytes.ptr, disk.bytes.len);
        defer storage.unref();
        const stream = gio.MemoryInputStream.newFromBytes(storage);
        defer stream.unref();
        const image = pixbuf.Pixbuf.newFromStream(stream.as(gio.InputStream), null, null) orelse return;
        defer image.unref();
        const rect = if (crop.find(prefs.wallpaper.crops, prefs.wallpaper.path)) |saved| crop.pixels(saved, image.getWidth(), image.getHeight()) else null;
        const part = if (rect) |pixels| image.newSubpixbuf(pixels.x, pixels.y, pixels.width, pixels.height) else null;
        defer if (part) |sub| sub.unref();
        self.boot_texture = gdk.Texture.newForPixbuf(part orelse image);
    }
    fn appearance(self: *Screen) void {
        self.restyle();
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            self.preferences.style(v.window.as(gtk.Widget), v.panel.as(gtk.Widget));
            const wallpaper = self.preferences.prefs().wallpaper.mode;
            const texture = if (self.preferences.live) |job| job.texture else self.boot_texture;
            v.picture.setPaintable(if (texture != null and (wallpaper == .cover or wallpaper == .contain)) texture.?.as(gdk.Paintable) else null);
            v.picture.setContentFit(if (wallpaper == .contain) .contain else .cover);
            var geometry: gdk.Rectangle = undefined;
            v.monitor.getGeometry(&geometry);
            const short = geometry.f_height < 400;
            v.clockbox.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.avatar.as(gtk.Widget).setVisible(@intFromBool(!short));
            v.hint.as(gtk.Widget).setVisible(@intFromBool(!short));
            if (geometry.f_width < 500 or geometry.f_height < 600) v.window.as(gtk.Widget).addCssClass("pearl-lock-small") else v.window.as(gtk.Widget).removeCssClass("pearl-lock-small");
        };
    }
    fn updateClock(self: *Screen) void {
        self.clock_updates += 1;
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            presentation.updateClock(v.clock, v.date);
        };
    }
    fn update(self: *Screen) void {
        self.ui_updates += 1;
        var views: usize = 0;
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) continue;
            views += 1;
            // The float carries only non-redundant status: failures, passive
            // info and visible (second-factor style) prompts. A secret prompt
            // adds nothing here; the entry placeholder is the only helper text.
            const status: [*:0]const u8 = if (self.message.slice().len > 0) self.message.z() else if (self.auth != null and !self.waiting) "Authenticating…" else "";
            if (!std.mem.eql(u8, std.mem.span(v.message.getText()), std.mem.span(status))) {
                v.message.as(gtk.Accessible).announce(status, .medium);
            }
            w.name(v.entry.as(gtk.Widget), if (self.waiting) self.prompt.z() else "Authentication response");
            v.message.setText(status);
            // The float slot keeps its height; only the ink fades in and out.
            v.message.as(gtk.Widget).setOpacity(if (std.mem.span(status).len > 0) 1 else 0);
            v.entry.setVisibility(@intFromBool(self.echo));
            v.entry.setInputPurpose(if (self.echo) .free_form else .password);
            v.entry.setPlaceholderText(if (self.echo) "Response" else "Password");
            // Keep focus-out delivery enabled while moving focus to Retry.
            // Insensitive GtkText widgets can drop that event and retain IM focus.
            v.entry.as(gtk.Editable).setEditable(@intFromBool(self.waiting));
            v.button.setLabel(if (self.waiting) "Unlock" else if (self.auth != null) "Authenticating…" else "Try again");
            v.button.as(gtk.Widget).setSensitive(@intFromBool(self.waiting or (self.auth == null and self.acquired and glib.getMonotonicTime() >= self.cooldown)));
            v.caps.as(gtk.Widget).setVisible(@intFromBool(self.caps_on));
            const asking = self.pending_power != null;
            v.reboot.as(gtk.Widget).setSensitive(@intFromBool(self.power.reboot and !asking));
            v.off.as(gtk.Widget).setSensitive(@intFromBool(self.power.off and !asking));
            v.sleep_button.as(gtk.Widget).setSensitive(@intFromBool(self.power.sleep and !self.power.pending));
            v.power_button.as(gtk.Widget).setSensitive(@intFromBool((self.power.reboot or self.power.off) and !self.power.pending));
            v.confirm.as(gtk.Widget).setVisible(@intFromBool(asking));
            v.cancel_power.as(gtk.Widget).setVisible(@intFromBool(asking));
            v.power_menu_box.as(gtk.Widget).setVisible(@intFromBool(!asking));
            v.power_confirm_box.as(gtk.Widget).setVisible(@intFromBool(asking));
            if (!self.waiting and self.auth == null and self.acquired) v.window.setFocus(v.button.as(gtk.Widget));
            if (options.test_hooks) {
                std.debug.assert(object.ext.cast(gtk.PasswordEntryBuffer, v.entry.getBuffer()) != null);
                const backend = glib.getenv("GTK_A11Y");
                if (backend != null and std.mem.eql(u8, std.mem.span(backend.?), "test")) {
                    const failure = gtk.testAccessibleCheckProperty(v.entry.as(gtk.Accessible), .label, if (self.waiting) self.prompt.z().ptr else @as([*:0]const u8, "Authentication response"));
                    std.debug.assert(@intFromPtr(failure) == 0);
                }
            }
        };
        const remaining = self.cooldown - glib.getMonotonicTime();
        if (self.cooldown_source == 0 and remaining > 0) {
            self.cooldown_source = glib.timeoutAdd(@intCast(@divTrunc(remaining, 1000) + 1), cooled, self);
        }
        if (options.test_hooks) log.info("event=lock-ui views={d} waiting={} echo={} caps={} auth={} acquired={} updates={d} clocks={d}", .{ views, self.waiting, self.echo, self.caps_on, self.auth != null, self.acquired, self.ui_updates, self.clock_updates });
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
        if (options.test_hooks) log.info("event=lock-caps enabled={}", .{caps});
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
            // The popover is parented to its button, not into the window tree.
            // setParent sank the floating ref into the button, and unparent
            // releases that ref, finalizing the popover; an extra unref here
            // would be a use-after-free.
            v.power_pop.as(gtk.Widget).unparent();
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
        self.prompted = false;
        var exe: [4096]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
        if (n <= 0) {
            self.message.set("Authentication unavailable. Try again.");
            self.sticky_status = false;
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
            self.sticky_status = false;
            self.update();
            return;
        };
        // GSubprocess reaps children even when a cancelled conversation exits later.
        const fd = object.ext.cast(unix.InputStream, p.getStdoutPipe().?).?.getFd();
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        self.auth_source = glibunix.fdAdd(fd, .{ .in = true, .hup = true, .err = true }, authReadable, self);
        self.deadline = glib.timeoutAdd(if (options.test_hooks and glib.getenv("PEARL_TEST_FAST_AUTH") != null) 1500 else 90000, authExpired, self);
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
            self.sticky_status = false;
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
            self.sticky_status = false;
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
            self.sticky_status = false;
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
                const text = self.packet.bytes[0..self.packet.length];
                if (self.packet.kind == 2) {
                    // A visible prompt (second factor, OTP) is itself status.
                    self.message.set(text);
                    self.sticky_status = false;
                } else if (!self.sticky_status) {
                    // A secret prompt adds nothing the placeholder does not say.
                    self.message.set("");
                }
                self.prompt.set(text);
                self.prompted = true;
                self.update();
                for (&self.views) |*slot| if (slot.*) |*v| {
                    if (v.monitor.isValid() != 0) _ = v.entry.as(gtk.Widget).grabFocus();
                };
            },
            3, 4 => {
                self.waiting = false;
                self.echo = false;
                self.clearSecrets();
                self.message.set(self.packet.bytes[0..self.packet.length]);
                self.sticky_status = false;
                self.update();
            },
            100 => {
                const success = self.packet.value == 0;
                self.cancelAuth();
                if (success and self.acquired and self.instance.isLocked() != 0) {
                    self.instance.unlock();
                } else {
                    // A conversation that took a credential re-arms in the same
                    // beat: the entry goes live again with a fresh prompt while
                    // the failure text stays on screen. Prompt-less rejections
                    // keep the manual retry so a deny stack cannot respawn hot.
                    const rearm = self.prompted;
                    self.message.set(if (rearm) "Wrong password." else "Authentication failed. Try again.");
                    self.sticky_status = true;
                    if (options.test_hooks) log.info("event=lock-auth-failed", .{});
                    self.update();
                    if (rearm) self.startAuth() else self.cooldown = glib.getMonotonicTime() + 1000000;
                }
                return 0;
            },
            102 => {
                // PAM never started: an infrastructure fault, not a credential
                // miss. Keep the manual retry path; never respawn in a loop.
                self.cancelAuth();
                self.message.set("Authentication unavailable. Try again.");
                self.sticky_status = false;
                self.cooldown = glib.getMonotonicTime() + 2000000;
                self.update();
                return 0;
            },
            else => {
                self.cancelAuth();
                self.message.set("Authentication unavailable.");
                self.sticky_status = false;
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
        self.sticky_status = false;
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
    fn powerOpened(button: *gtk.Button, self: *Screen) callconv(.c) void {
        if (self.power.pending or self.pending_power != null) return;
        for (&self.views) |*slot| if (slot.*) |*v| if (v.power_button == button) {
            v.power_menu_box.as(gtk.Widget).setVisible(1);
            v.power_confirm_box.as(gtk.Widget).setVisible(0);
            v.power_pop.popup();
            return;
        };
    }
    fn rebooted(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.askPower(.reboot);
    }
    fn off(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.askPower(.off);
    }
    fn askPower(self: *Screen, action: power_mod.Action) void {
        if (self.power.pending or self.pending_power != null) return;
        self.pending_power = action;
        self.update();
    }
    fn confirmed(_: *gtk.Button, self: *Screen) callconv(.c) void {
        const action = self.pending_power orelse return;
        for (&self.views) |*slot| if (slot.*) |*v| v.power_pop.popdown();
        self.pending_power = null;
        if (options.test_hooks) log.info("event=lock-power action={s}", .{@tagName(action)});
        self.power.request(action) catch {
            self.message.set("Power action was denied or is unavailable.");
        };
        self.update();
    }
    fn cancelPower(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.pending_power = null;
        self.update();
    }
    fn sleepRequested(_: *gtk.Button, self: *Screen) callconv(.c) void {
        if (self.power.pending) return;
        if (options.test_hooks) log.info("event=lock-power action=sleep", .{});
        self.power.request(.sleep) catch {
            self.message.set("Power action was denied or is unavailable.");
        };
        self.update();
    }
    fn powerChanged(context: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(context));
        if (self.power.failed) self.message.set("Power action was denied or is unavailable.");
        self.update();
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
        self.sticky_status = false;
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
            log.err("event=lock-output-limit", .{});
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
            self.createView(output);
        }
        return 0;
    }
    fn createView(self: *Screen, output: *gdk.Monitor) void {
        var target: ?*?View = null;
        for (&self.views) |*slot| {
            if (slot.* == null and target == null) target = slot;
        }
        const slot = target orelse {
            self.failed = true;
            log.err("event=lock-output-limit", .{});
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
        // The clock block floats on the wallpaper, outside the scrolled form.
        const clockbox = w.column(0);
        clockbox.as(gtk.Widget).addCssClass("pearl-lock-clockbox");
        clockbox.as(gtk.Widget).setHalign(.center);
        clockbox.as(gtk.Widget).setValign(.start);
        const clock = w.label("", "pearl-lock-clock");
        clock.setXalign(0.5);
        const date = w.label("", "pearl-lock-date");
        date.setXalign(0.5);
        clockbox.append(date.as(gtk.Widget));
        clockbox.append(clock.as(gtk.Widget));
        const column = w.column(0);
        column.as(gtk.Widget).addCssClass("pearl-lock-form");
        column.as(gtk.Widget).setHalign(.center);
        column.as(gtk.Widget).setValign(.center);
        // Invisible twin slots above and below the card: the float zone keeps a
        // constant height, so the card never resizes or re-centers mid-attempt.
        const float_top = w.column(0);
        float_top.as(gtk.Widget).addCssClass("pearl-float-slot");
        column.append(float_top.as(gtk.Widget));
        const panel = w.card();
        panel.setSpacing(0);
        panel.as(gtk.Widget).setSizeRequest(220, -1);
        panel.as(gtk.Widget).addCssClass("pearl-lock-card");
        const avatar = gtk.Image.newFromIconName("avatar-default-symbolic");
        avatar.setPixelSize(28);
        avatar.as(gtk.Widget).addCssClass("pearl-avatar-circle");
        avatar.as(gtk.Widget).setHalign(.center);
        panel.append(avatar.as(gtk.Widget));
        const username = w.label(glib.getRealName(), "pearl-title");
        username.setXalign(0.5);
        panel.append(username.as(gtk.Widget));
        const entry = presentation.secureEntry(1024);
        entry.as(gtk.Widget).addCssClass("pearl-field");
        w.name(entry.as(gtk.Widget), "Authentication response");
        panel.append(entry.as(gtk.Widget));
        const caps = w.label("Caps Lock is on", "pearl-secondary");
        caps.as(gtk.Widget).addCssClass("pearl-caps");
        caps.as(gtk.Widget).setVisible(0);
        panel.append(caps.as(gtk.Widget));
        const button = gtk.Button.newWithLabel("Unlock");
        button.as(gtk.Widget).addCssClass("pearl-primary");
        panel.append(button.as(gtk.Widget));
        column.append(panel.as(gtk.Widget));
        const floatbox = w.column(10);
        floatbox.as(gtk.Widget).addCssClass("pearl-float-slot");
        floatbox.as(gtk.Widget).setMarginTop(4);
        const hint = w.label("Session locked · Esc cancels authentication", "pearl-secondary");
        hint.as(gtk.Widget).addCssClass("pearl-float-status");
        hint.setXalign(0.5);
        floatbox.append(hint.as(gtk.Widget));
        const message = w.label("", "pearl-secondary");
        message.as(gtk.Widget).addCssClass("pearl-float-status");
        message.setMaxWidthChars(44);
        message.setXalign(0.5);
        message.as(gtk.Widget).setOpacity(0);
        floatbox.append(message.as(gtk.Widget));
        column.append(floatbox.as(gtk.Widget));
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.automatic, .automatic);
        const viewport = gtk.Viewport.new(null, null);
        viewport.setScrollToFocus(1);
        viewport.setChild(column.as(gtk.Widget));
        scroll.setChild(viewport.as(gtk.Widget));
        overlay.addOverlay(scroll.as(gtk.Widget));
        overlay.addOverlay(clockbox.as(gtk.Widget));
        // Corner cluster: sleep plus the two-step power popover, mirroring the
        // greeter's controls on every interactive lock surface.
        const cluster = w.row(2);
        cluster.as(gtk.Widget).addCssClass("pearl-cluster");
        cluster.as(gtk.Widget).setHalign(.end);
        cluster.as(gtk.Widget).setValign(.end);
        cluster.as(gtk.Widget).setMarginEnd(24);
        cluster.as(gtk.Widget).setMarginBottom(24);
        const sleep_button = w.iconButton("pearl-sleep-symbolic", "Sleep");
        cluster.append(sleep_button.as(gtk.Widget));
        const power_button = w.iconButton("pearl-power-symbolic", "Restart or power off");
        cluster.append(power_button.as(gtk.Widget));
        const power_pop = gtk.Popover.new();
        power_pop.as(gtk.Widget).setParent(power_button.as(gtk.Widget));
        power_pop.setHasArrow(0);
        power_pop.setPosition(.top);
        const power_menu_box = w.column(4);
        power_menu_box.as(gtk.Widget).setSizeRequest(168, -1);
        const reboot = gtk.Button.newWithLabel("Restart");
        reboot.as(gtk.Widget).addCssClass("pearl-menu-item");
        const off_button = gtk.Button.newWithLabel("Power off");
        off_button.as(gtk.Widget).addCssClass("pearl-menu-item");
        off_button.as(gtk.Widget).addCssClass("pearl-destructive");
        power_menu_box.append(reboot.as(gtk.Widget));
        power_menu_box.append(off_button.as(gtk.Widget));
        const power_confirm_box = w.row(6);
        const confirm = gtk.Button.newWithLabel("Confirm");
        confirm.as(gtk.Widget).addCssClass("pearl-primary");
        confirm.as(gtk.Widget).setHexpand(1);
        const cancel_power = gtk.Button.newWithLabel("Cancel");
        cancel_power.as(gtk.Widget).setHexpand(1);
        power_confirm_box.append(confirm.as(gtk.Widget));
        power_confirm_box.append(cancel_power.as(gtk.Widget));
        power_confirm_box.as(gtk.Widget).setVisible(0);
        const power_content = w.column(6);
        power_content.append(power_menu_box.as(gtk.Widget));
        power_content.append(power_confirm_box.as(gtk.Widget));
        power_pop.setChild(power_content.as(gtk.Widget));
        overlay.addOverlay(cluster.as(gtk.Widget));
        slot.* = .{ .window = window, .monitor = output, .panel = panel, .picture = picture, .clockbox = clockbox, .clock = clock, .date = date, .message = message, .hint = hint, .entry = entry, .button = button, .caps = caps, .viewport = viewport, .avatar = avatar, .cluster = cluster, .sleep_button = sleep_button, .power_button = power_button, .power_pop = power_pop, .power_menu_box = power_menu_box, .power_confirm_box = power_confirm_box, .confirm = confirm, .cancel_power = cancel_power, .reboot = reboot, .off = off_button, .monitor_signal = object.Object.signals.notify.connect(output.as(object.Object), *Screen, monitorChanged, self, .{}) };
        _ = gtk.Button.signals.clicked.connect(sleep_button, *Screen, sleepRequested, self, .{});
        _ = gtk.Button.signals.clicked.connect(power_button, *Screen, powerOpened, self, .{});
        _ = gtk.Button.signals.clicked.connect(reboot, *Screen, rebooted, self, .{});
        _ = gtk.Button.signals.clicked.connect(off_button, *Screen, off, self, .{});
        _ = gtk.Button.signals.clicked.connect(confirm, *Screen, confirmed, self, .{});
        _ = gtk.Button.signals.clicked.connect(cancel_power, *Screen, cancelPower, self, .{});
        _ = gtk.Entry.signals.activate.connect(entry, *Screen, entered, self, .{});
        _ = gtk.Button.signals.clicked.connect(button, *Screen, clicked, self, .{});
        _ = gtk.Window.signals.close_request.connect(window, *Screen, close, self, .{});
        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Screen, key, self, .{});
        window.as(gtk.Widget).addController(controller.as(gtk.EventController));
        // Hold the window back until the session theme and wallpaper have landed
        // once, so the first painted frame is complete; the deadline bounds the
        // wait when the theme job is slow or fails.
        if (self.theme_ready) self.presentView(&slot.*.?) else if (self.present_source == 0) {
            self.present_source = glib.timeoutAdd(2000, presentDeadline, self);
        }
    }
    fn locked(_: *lock.Instance, self: *Screen) callconv(.c) void {
        if (self.failed) return;
        self.acquired = true;
        if (self.ready_fd) {
            _ = std.c.write(3, "L", 1);
            _ = std.c.close(3);
            self.ready_fd = false;
        }
        log.info("event=lock-acquired", .{});
        self.startAuth();
    }
    fn onFailed(_: *lock.Instance, self: *Screen) callconv(.c) void {
        self.failed = true;
        self.loop.quit();
    }
    fn unlocked(_: *lock.Instance, self: *Screen) callconv(.c) void {
        self.acquired = false;
        self.cancelAuth();
        log.info("event=lock-released", .{});
        self.loop.quit();
    }
    fn changed(data: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(data));
        if (!self.theme_ready and self.preferences.live != null) self.releaseViews();
        self.appearance();
        self.update();
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.updateClock();
        self.scheduleClock();
        if (options.test_hooks) log.info("event=lock-clock updates={d} clocks={d}", .{ self.ui_updates, self.clock_updates });
        return 0;
    }
    fn scheduleClock(self: *Screen) void {
        const now = glib.DateTime.newNowLocal();
        defer if (now) |t| t.unref();
        const delay: c_uint = if (now) |t| @intCast(60 - t.getSecond()) else 60;
        _ = glib.timeoutAddSeconds(delay, tick, self);
    }
};
fn loadPreferences() model.Preferences {
    const pz = std.fmt.allocPrintSentinel(a, "{s}/pearl/preferences.json", .{std.mem.span(glib.getUserConfigDir())}, 0) catch return .{};
    defer a.free(pz);
    const disk = io.read(a, pz, 1024 * 1024, null) catch return .{};
    defer a.free(disk.bytes);
    return model.parse(a, disk.bytes) catch .{};
}
pub fn run(ready_fd: bool) !void {
    gtk.init();
    const display = gdk.Display.getDefault() orelse return error.NoDisplay;
    const raw = @embedFile("pearl_resources");
    const bytes = glib.Bytes.newStatic(raw.ptr, raw.len);
    defer bytes.unref();
    const resource = gio.Resource.newFromData(bytes, null) orelse return error.Resources;
    gio.resourcesRegister(resource);
    gtk.IconTheme.getForDisplay(display).addResourcePath("/org/aqueous/Pearl/icons");
    const app = gio.Application.new("org.aqueous.Pearl.Lock", .{ .non_unique = true });
    var screen: Screen = .{ .loop = glib.MainLoop.new(null, 0), .instance = lock.Instance.new(), .display = display, .ready_fd = ready_fd };
    // The shell publishes the palette it is showing; loading it here, and
    // decoding the session wallpaper below, lets the first presented frame
    // match the shell exactly instead of flashing stock colors until the
    // lock's own theme job lands. Without a publication the presentation gate
    // in createView still waits for that job, bounded by a deadline.
    const boot_prefs = loadPreferences();
    var palette_source: [*:0]const u8 = "stock";
    screen.boot_palette = if (boot_prefs.theme.variant == .light) theme.light else theme.dark;
    if (published.read(a)) |value| {
        screen.boot_palette = value;
        palette_source = "published";
    } else |_| {}
    const boot_provider = gtk.CssProvider.new();
    if (theme.cssPalettes(a, @embedFile("lock_style"), screen.boot_palette, screen.boot_palette)) |boot_css| {
        defer a.free(boot_css);
        boot_provider.loadFromString(boot_css);
        gtk.StyleContext.addProviderForDisplay(display, boot_provider.as(gtk.StyleProvider), 599);
    } else |_| {}
    screen.bootWallpaper(boot_prefs);
    const needs_texture = boot_prefs.wallpaper.mode == .cover or boot_prefs.wallpaper.mode == .contain;
    screen.theme_ready = std.mem.eql(u8, std.mem.span(palette_source), "published") and (!needs_texture or screen.boot_texture != null);
    if (options.test_hooks) log.info("event=lock-boot palette={s} textured={}", .{ palette_source, screen.boot_texture != null });
    const base = gtk.CssProvider.new();
    base.loadFromString(presentation.css);
    // Priorities layer: 599 stock fallback sheet, 600 shared authentication
    // sizes, 601 the session's own theme provider (every color), 602 the lock's
    // layout, shadows and frost.
    gtk.StyleContext.addProviderForDisplay(display, base.as(gtk.StyleProvider), 600);
    screen.style = gtk.CssProvider.new();
    gtk.StyleContext.addProviderForDisplay(display, screen.style.as(gtk.StyleProvider), 602);
    screen.preferences = .{ .app = app, .display = display, .context = &screen, .changed = Screen.changed };
    try screen.preferences.start();
    screen.restyle();
    screen.power = .{ .context = &screen, .changed = Screen.powerChanged };
    screen.power.init();
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
