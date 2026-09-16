//! Disposable pre-login layer surfaces; exactly one interactive authentication card.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const layer = @import("gtk4layershell1");
const pixbuf = @import("gdkpixbuf2");
const cfg = @import("config.zig");
const sessions = @import("sessions.zig");
const accounts = @import("accounts.zig");
const trusted = @import("trusted.zig");
const Client = @import("client.zig").Client;
const Power = @import("power.zig").Power;
const presentation = @import("../ui/auth/prompt_view.zig");
const w = @import("../ui/components/widgets.zig");
const options = @import("build_options");
const a = std.heap.c_allocator;
const View = struct { window: *gtk.Window, monitor: *gdk.Monitor, picture: *gtk.Picture, clock: *gtk.Label, date: *gtk.Label, active: bool, scroll: ?*gtk.ScrolledWindow = null, monitor_signal: c_ulong };
const Purpose = enum { refresh, begin, start };
const Job = struct {
    screen: *Screen,
    purpose: Purpose,
    generation: u64,
    cancel: *gio.Cancellable,
    catalog: ?sessions.Catalog = null,
    account_list: []const accounts.Account = &.{},
    image: ?*pixbuf.Pixbuf = null,
    failed: bool = false,
};
const Screen = struct {
    config: cfg.Config,
    loop: *glib.MainLoop,
    display: *gdk.Display,
    client: Client = undefined,
    power: Power = undefined,
    views: [64]?View = @splat(null),
    column: *gtk.Box,
    panel: *gtk.Box,
    username: *gtk.Entry,
    entry: *gtk.Entry,
    chooser: *gtk.DropDown,
    account_chooser: *gtk.DropDown,
    message: *gtk.Label,
    caps: *gtk.Label,
    button: *gtk.Button,
    cancel_button: *gtk.Button,
    refresh_button: *gtk.Button,
    reboot_button: *gtk.Button,
    off_button: *gtk.Button,
    confirm: *gtk.Button,
    cancel_power: *gtk.Button,
    layout_label: *gtk.Label,
    clock: *gtk.Label,
    date: *gtk.Label,
    job_generation: u64 = 0,
    selected_explicitly: bool = false,
    account_names: [256][257:0]u8 = @splat(@splat(0)),
    catalog: ?sessions.Catalog = null,
    texture: ?*gdk.Texture = null,
    reader_process: ?*gio.Subprocess = null,
    job: ?*Job = null,
    selected_id: [257:0]u8 = @splat(0),
    selected_fingerprint: [64]u8 = @splat(0),
    selected_kind: [8:0]u8 = @splat(0),
    selecting: bool = false,
    monitor_source: c_uint = 0,
    tick_source: c_uint = 0,
    keyboard: ?*gdk.Device = null,
    pending_power: ?bool = null,
    confirmed_power: bool = false,
    auth_error: bool = false,
    service_error: bool = false,
    selection_error: bool = false,
    high_contrast: bool = false,
    reduced_motion: bool = true,
    status: u8 = 1,
    fn z(text: []const u8) [:0]u8 {
        return a.dupeZ(u8, text) catch unreachable;
    }
    fn setMessage(self: *Screen, text: [*:0]const u8) void {
        if (!std.mem.eql(u8, std.mem.span(self.message.getText()), std.mem.span(text))) self.message.as(gtk.Accessible).announce(text, .medium);
        self.message.setText(text);
    }
    fn passiveMessage(self: *Screen) void {
        const text = self.client.history.latest() orelse return;
        if (std.mem.eql(u8, std.mem.span(self.message.getText()), text)) return;
        // Coalesce identical statuses only: every changed instruction gets an
        // announcement even when another message follows in the same frame.
        self.setMessage(text);
    }
    fn clear(self: *Screen) void {
        self.entry.as(gtk.Editable).setText("");
    }
    fn changed(context: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(context));
        self.clear();
        const c = &self.client.controller;
        if (options.test_hooks) std.log.info("event=greeter-state state={s}", .{@tagName(c.state)});
        switch (c.state) {
            .idle => {
                self.setMessage(if (self.selection_error) "The selected desktop changed. Refresh and choose it again." else if (self.auth_error) "Authentication failed. Try again." else if (self.service_error) "Login service rejected the request. Try again later." else "Choose your account and desktop.");
                if (self.confirmed_power) self.performPower();
            },
            .connecting => self.setMessage("Authenticating…"),
            .authenticating => {
                if ((c.kind == .info or c.kind == .@"error") and self.client.history.latest() != null) self.passiveMessage() else self.setMessage("Authenticating…");
            },
            .prompt => {
                if (c.needsInput()) self.setMessage(self.client.response.z()) else self.passiveMessage();
                self.entry.setVisibility(@intFromBool(c.kind == .visible));
            },
            .cancelling => self.setMessage("Cancelling authentication…"),
            .authenticated => {
                self.setMessage("Checking selected desktop…");
                self.refresh(.start);
            },
            .starting => self.setMessage("Starting your desktop…"),
            .handoff => {
                // Accepted or uncertain start: never replay; terminate the entire owned host.
                if (self.config.remember_session and self.client.accepted) @import("state.zig").save(std.mem.sliceTo(&self.client.username, 0), std.mem.sliceTo(&self.selected_id, 0)) catch {};
                self.status = 0;
                self.loop.quit();
            },
            .failed => {
                self.auth_error = self.client.response.authentication_error;
                self.service_error = !self.auth_error;
                self.setMessage(if (self.client.response.authentication_error) "Authentication failed. Try again." else "Login service rejected the request.");
                self.client.cancel() catch self.loop.quit();
            },
            .unavailable => {
                self.setMessage("Login service unavailable. Restarting login screen…");
                self.loop.quit();
            },
        }
        self.update();
    }
    fn update(self: *Screen) void {
        const c = &self.client.controller;
        const idle = c.state == .idle and self.job == null and self.pending_power == null and !self.power.pending and !self.power.completed;
        const prompt = c.state == .prompt;
        const secret = c.needsInput();
        self.username.as(gtk.Editable).setEditable(@intFromBool(idle));
        self.chooser.as(gtk.Widget).setSensitive(@intFromBool(idle and self.config.force_session == null));
        self.account_chooser.as(gtk.Widget).setSensitive(@intFromBool(idle));
        self.refresh_button.as(gtk.Widget).setSensitive(@intFromBool(idle));
        self.entry.as(gtk.Widget).setVisible(@intFromBool(secret));
        self.entry.as(gtk.Editable).setEditable(@intFromBool(secret));
        self.entry.setInputPurpose(if (c.kind == .visible) .free_form else .password);
        self.entry.setPlaceholderText(if (c.kind == .visible) "Response" else "Password");
        w.name(self.entry.as(gtk.Widget), if (prompt) self.client.response.z() else "Authentication response");
        self.button.setLabel(if (prompt) "Continue" else "Sign in");
        self.button.as(gtk.Widget).setVisible(@intFromBool(c.state == .idle or secret));
        self.button.as(gtk.Widget).setSensitive(@intFromBool((idle and self.selected_id[0] != 0) or secret));
        self.cancel_button.as(gtk.Widget).setVisible(@intFromBool(c.state != .idle or self.job != null));
        self.cancel_button.as(gtk.Widget).setSensitive(@intFromBool((c.state != .idle or self.job != null) and c.state != .cancelling and !c.start_submitted));
        self.reboot_button.as(gtk.Widget).setSensitive(@intFromBool(self.power.reboot and !c.start_submitted and self.pending_power == null));
        self.off_button.as(gtk.Widget).setSensitive(@intFromBool(self.power.off and !c.start_submitted and self.pending_power == null));
        self.confirm.as(gtk.Widget).setVisible(@intFromBool(self.pending_power != null));
        self.cancel_power.as(gtk.Widget).setVisible(@intFromBool(self.pending_power != null));
        if (secret) _ = self.entry.as(gtk.Widget).grabFocus();
        if (options.test_hooks) {
            std.debug.assert(object.ext.cast(gtk.PasswordEntryBuffer, self.entry.getBuffer()) != null);
            if (c.passiveToken() != null or (c.state == .authenticating and (c.kind == .info or c.kind == .@"error") and self.client.history.latest() != null)) {
                std.debug.assert(self.entry.as(gtk.Widget).getVisible() == 0);
                std.debug.assert(self.button.as(gtk.Widget).getVisible() == 0);
                std.debug.assert(std.mem.span(self.entry.as(gtk.Editable).getText()).len == 0);
                std.debug.assert(std.mem.eql(u8, std.mem.span(self.message.getText()), self.client.history.latest().?));
            }
            if (glib.getenv("GTK_A11Y")) |backend| if (std.mem.eql(u8, std.mem.span(backend), "test")) {
                const fail = gtk.testAccessibleCheckProperty(self.entry.as(gtk.Accessible), .label, if (prompt) self.client.response.z() else @as([*:0]const u8, "Authentication response"));
                std.debug.assert(@intFromPtr(fail) == 0);
            };
        }
    }
    fn selected(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        if (self.selecting or self.client.controller.state != .idle or self.job != null) return;
        self.selected_explicitly = true;
        self.choose(self.chooser.getSelected());
        self.update();
    }
    fn choose(self: *Screen, index: c_uint) void {
        self.selected_id = @splat(0);
        const catalog = if (self.catalog) |*value| value else return;
        if (index >= catalog.entries.items.len) return;
        const e = catalog.entries.items[index];
        if (!e.available) {
            const text = z(e.reason);
            defer a.free(text);
            self.setMessage(text);
            return;
        }
        @memcpy(self.selected_id[0..e.id.len], e.id);
        self.selection_error = false;
        self.selected_fingerprint = e.fingerprint;
        self.selected_kind = @splat(0);
        @memcpy(self.selected_kind[0..e.kind.len], e.kind);
        self.setMessage("Choose your account and desktop.");
    }
    fn selectedAccount(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        if (self.selecting or self.client.controller.state != .idle) return;
        const n = self.account_chooser.getSelected();
        if (n > 0 and n <= 256 and self.account_names[n - 1][0] != 0) self.username.as(gtk.Editable).setText(@ptrCast(&self.account_names[n - 1]));
        _ = self.username.as(gtk.Widget).grabFocus();
    }
    fn submit(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.submitCurrent();
    }
    fn activity(_: *gtk.Editable, self: *Screen) callconv(.c) void {
        self.client.activity();
    }
    fn entered(_: *gtk.Entry, self: *Screen) callconv(.c) void {
        self.submitCurrent();
    }
    fn submitCurrent(self: *Screen) void {
        const c = &self.client.controller;
        if (self.job != null or self.pending_power != null or self.power.pending or self.power.completed) return;
        if (c.state == .idle) {
            const user = std.mem.span(self.username.as(gtk.Editable).getText());
            if (user.len == 0 or !@import("protocol.zig").validText(user, 256)) {
                self.setMessage("Enter a username (maximum 256 UTF-8 bytes).");
                return;
            }
            if (self.selected_id[0] == 0) {
                self.setMessage("Select an available desktop.");
                return;
            }
            if (self.config.remember_session and !self.selected_explicitly and self.catalog != null) {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const remembered = @import("state.zig").remembered(arena.allocator(), user);
                if (self.catalog.?.selected(self.config, remembered)) |wanted| {
                    for (self.catalog.?.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.id, wanted.id)) {
                        self.selecting = true;
                        self.chooser.setSelected(@intCast(i));
                        self.selecting = false;
                        self.choose(@intCast(i));
                        break;
                    };
                }
            }
            self.auth_error = false;
            self.service_error = false;
            self.selection_error = false;
            self.refresh(.begin);
        } else if (c.needsInput()) {
            const answer = std.mem.span(self.entry.as(gtk.Editable).getText());
            self.client.answer(c.prompt_generation, answer) catch {
                self.clear();
                self.setMessage("Response is too long or no longer current.");
            };
        }
    }
    fn cancelled(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.cancelAttempt();
    }
    fn cancelAttempt(self: *Screen) void {
        self.clear();
        self.job_generation +%= 1;
        if (self.job) |job| job.cancel.cancel();
        self.client.cancel() catch {};
    }
    fn refreshed(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.refresh(.refresh);
    }
    fn close(_: *gtk.Window, _: *Screen) callconv(.c) c_int {
        return 1;
    }
    fn key(_: *gtk.EventControllerKey, keyval: c_uint, _: c_uint, _: gdk.ModifierType, self: *Screen) callconv(.c) c_int {
        if (keyval == 0xff1b) {
            self.clear();
            if (self.pending_power != null) {
                self.pending_power = null;
                self.confirmed_power = false;
                self.update();
            } else self.cancelAttempt();
            return 1;
        }
        return 0;
    }
    fn powerChanged(context: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(context));
        if (self.power.completed) {
            self.clear();
            self.loop.quit();
            return;
        }
        if (self.power.failed) self.setMessage("Power action was denied or is unavailable.");
        self.update();
    }
    fn reboot(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.askPower(true);
    }
    fn off(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.askPower(false);
    }
    fn askPower(self: *Screen, restarting: bool) void {
        if (self.client.controller.start_submitted or self.job != null) return;
        self.clear();
        self.pending_power = restarting;
        self.confirm.setLabel(if (restarting) "Confirm restart" else "Confirm power off");
        self.update();
    }
    fn confirmed(_: *gtk.Button, self: *Screen) callconv(.c) void {
        if (self.pending_power == null) return;
        self.confirmed_power = true;
        if (self.client.controller.state == .idle) self.performPower() else self.client.cancel() catch {};
    }
    fn cancelPower(_: *gtk.Button, self: *Screen) callconv(.c) void {
        self.pending_power = null;
        self.confirmed_power = false;
        self.update();
    }
    fn performPower(self: *Screen) void {
        const action = self.pending_power orelse return;
        self.pending_power = null;
        self.confirmed_power = false;
        self.power.request(action) catch self.setMessage("Power action was denied or is unavailable.");
        self.update();
    }
    fn larger(_: *gtk.Button, self: *Screen) callconv(.c) void {
        if (self.column.as(gtk.Widget).hasCssClass("pearl-large") != 0) self.column.as(gtk.Widget).removeCssClass("pearl-large") else self.column.as(gtk.Widget).addCssClass("pearl-large");
    }
    fn reader(_: *gtk.Button, self: *Screen) callconv(.c) void {
        if (!self.config.screen_reader or self.reader_process != null) return;
        const args = [_:null]?[*:0]const u8{"/usr/bin/orca"};
        const child = gio.Subprocess.newv(@ptrCast(&args), .{ .stdout_silence = true, .stderr_silence = true }, null) orelse {
            self.setMessage("Screen reader is unavailable.");
            return;
        };
        self.reader_process = child;
        child.waitAsync(null, readerExited, self);
    }
    fn readerExited(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        if (self.reader_process) |child| {
            _ = child.waitFinish(result, null);
            child.unref();
            self.reader_process = null;
        }
    }
    fn refresh(self: *Screen, purpose: Purpose) void {
        if (self.job != null or (purpose == .refresh and self.client.controller.state != .idle)) return;
        const job = a.create(Job) catch {
            self.setMessage("Unable to load desktops.");
            return;
        };
        job.* = .{ .screen = self, .purpose = purpose, .generation = self.job_generation, .cancel = gio.Cancellable.new() };
        self.job = job;
        self.update();
        const task = gio.Task.new(null, job.cancel, completed, job);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(work);
        task.unref();
    }
    fn locale() []const u8 {
        const names = glib.getLanguageNames();
        const value = std.mem.span(names[0]);
        return value[0..(std.mem.indexOfScalar(u8, value, '.') orelse value.len)];
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const current = cfg.load(a) catch {
            job.failed = true;
            task.returnBoolean(1);
            return;
        };
        defer current.deinit();
        job.catalog = sessions.load(a, current.value, locale()) catch null;
        job.failed = job.catalog == null;
        if (job.purpose == .refresh and job.catalog != null) {
            if (job.screen.config.accounts) job.account_list = accounts.load(job.catalog.?.arena.allocator(), job.cancel) catch &.{};
            if (job.screen.config.wallpaper) |path| job.image = loadImage(path, job.cancel) catch null;
        }
        task.returnBoolean(1);
    }
    fn loadImage(path: []const u8, cancel: *gio.Cancellable) !?*pixbuf.Pixbuf {
        const bytes = try trusted.read(a, path, 16 * 1024 * 1024);
        defer a.free(bytes);
        if (!@import("../services/artwork.zig").dimensions(bytes)) return error.InvalidImage;
        const storage = glib.Bytes.new(bytes.ptr, bytes.len);
        defer storage.unref();
        const stream = gio.MemoryInputStream.newFromBytes(storage);
        defer stream.unref();
        return pixbuf.Pixbuf.newFromStream(stream.as(gio.InputStream), cancel, null);
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data.?));
        const self = job.screen;
        self.job = null;
        defer {
            job.cancel.unref();
            if (job.image) |image| image.unref();
            a.destroy(job);
        }
        if (job.failed) {
            self.setMessage("Desktop configuration is unavailable.");
            if (self.client.controller.state == .authenticated) self.client.cancel() catch {};
            self.update();
            return;
        }
        var next = job.catalog.?;
        if (job.generation != self.job_generation) {
            next.deinit();
            self.update();
            return;
        }
        if (job.purpose != .refresh) {
            defer next.deinit();
            const e = next.find(std.mem.sliceTo(&self.selected_id, 0));
            if (e == null or !e.?.available or !std.mem.eql(u8, &e.?.fingerprint, &self.selected_fingerprint)) {
                self.selection_error = true;
                self.setMessage("The selected desktop changed. Refresh and choose it again.");
                self.selected_id = @splat(0);
                if (self.client.controller.state == .authenticated) self.client.cancel() catch {};
                self.update();
                return;
            }
            if (job.purpose == .begin and self.client.controller.state == .idle) {
                self.client.begin(std.mem.span(self.username.as(gtk.Editable).getText())) catch self.setMessage("Login service unavailable.");
            } else if (job.purpose == .start and self.client.controller.state == .authenticated) {
                const id = std.fmt.allocPrint(a, "PEARL_SESSION_ID={s}", .{std.mem.sliceTo(&self.selected_id, 0)}) catch unreachable;
                defer a.free(id);
                const fp = std.fmt.allocPrint(a, "PEARL_SESSION_FINGERPRINT={s}", .{self.selected_fingerprint}) catch unreachable;
                defer a.free(fp);
                const kind = std.fmt.allocPrint(a, "XDG_SESSION_TYPE={s}", .{std.mem.sliceTo(&self.selected_kind, 0)}) catch unreachable;
                defer a.free(kind);
                const name = std.fs.path.stem(e.?.path);
                const session_desktop = std.fmt.allocPrint(a, "XDG_SESSION_DESKTOP={s}", .{name}) catch unreachable;
                defer a.free(session_desktop);
                const desktop_session = std.fmt.allocPrint(a, "DESKTOP_SESSION={s}", .{name}) catch unreachable;
                defer a.free(desktop_session);
                const desktop_names = std.mem.replaceOwned(u8, a, std.mem.trimEnd(u8, e.?.desktops, ";"), ";", ":") catch unreachable;
                defer a.free(desktop_names);
                const desktop_env = std.fmt.allocPrint(a, "XDG_CURRENT_DESKTOP={s}", .{desktop_names}) catch unreachable;
                defer a.free(desktop_env);
                self.client.start(&.{ id, fp, kind, session_desktop, desktop_session, desktop_env }) catch self.loop.quit();
            }
            self.update();
            return;
        }
        self.selecting = true;
        const model = gtk.StringList.new(null);
        defer model.unref();
        for (next.entries.items) |entry| {
            var duplicates: usize = 0;
            for (next.entries.items) |other| if (std.mem.eql(u8, entry.name, other.name) and std.mem.eql(u8, entry.kind, other.kind)) {
                duplicates += 1;
            };
            const disambiguator = if (duplicates > 1) std.fs.path.stem(entry.path) else "";
            const label = std.fmt.allocPrintSentinel(a, "{s} · {s}{s}{s}{s}", .{ entry.name, if (std.mem.eql(u8, entry.kind, "x11")) "X11" else "Wayland", if (duplicates > 1) " · " else "", disambiguator, if (entry.available) "" else " (unavailable)" }, 0) catch unreachable;
            defer a.free(label);
            model.append(label);
        }
        self.chooser.setModel(model.as(gio.ListModel));
        const previous = next.find(std.mem.sliceTo(&self.selected_id, 0));
        const selected_entry = if (previous != null and previous.?.available) previous else next.selected(self.config, null);
        var index: c_uint = gtk.INVALID_LIST_POSITION;
        if (selected_entry) |selected_value| for (next.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.id, selected_value.id)) {
                index = @intCast(i);
                break;
            }
        };
        self.chooser.setSelected(index);
        const account_model = gtk.StringList.new(null);
        defer account_model.unref();
        account_model.append("Enter username manually");
        self.account_names = @splat(@splat(0));
        for (job.account_list, 0..) |account, i| {
            @memcpy(self.account_names[i][0..account.username.len], account.username);
            const label = z(account.label);
            defer a.free(label);
            account_model.append(label);
        }
        self.account_chooser.setModel(account_model.as(gio.ListModel));
        self.account_chooser.setSelected(0);
        self.account_chooser.as(gtk.Widget).setVisible(@intFromBool(job.account_list.len > 0));
        if (self.catalog) |*old| old.deinit();
        self.catalog = next;
        self.selecting = false;
        self.choose(index);
        if (job.image) |image| {
            if (self.texture) |texture| texture.unref();
            self.texture = gdk.Texture.newForPixbuf(image);
        }
        for (&self.views) |*view| if (view.*) |*v| v.picture.setPaintable(if (self.texture) |texture| texture.as(gdk.Paintable) else null);
        if (self.selected_id[0] == 0) self.setMessage("No usable desktop sessions. Install a session or check its dependencies.");
        self.update();
        if (options.test_hooks) std.log.info("event=greeter-ready sessions={d}", .{self.catalog.?.entries.items.len});
    }
    fn contrastChanged(button: *gtk.CheckButton, self: *Screen) callconv(.c) void {
        self.high_contrast = button.getActive() != 0;
        for (self.views) |slot| if (slot) |v| self.accessibilityStyle(v.window);
        if (options.test_hooks) std.log.info("event=greeter-contrast enabled={}", .{self.high_contrast});
    }
    fn motionChanged(button: *gtk.CheckButton, self: *Screen) callconv(.c) void {
        self.reduced_motion = button.getActive() != 0;
        if (gtk.Settings.getDefault()) |settings| settings.as(object.Object).set("gtk-enable-animations", @as(c_int, @intFromBool(!self.reduced_motion)), "gtk-cursor-blink", @as(c_int, @intFromBool(!self.reduced_motion)), @as(?[*:0]const u8, null));
        for (self.views) |slot| if (slot) |v| self.accessibilityStyle(v.window);
        if (options.test_hooks) std.log.info("event=greeter-reduced-motion enabled={}", .{self.reduced_motion});
    }
    fn accessibilityStyle(self: *Screen, window: *gtk.Window) void {
        const widget = window.as(gtk.Widget);
        if (self.high_contrast) widget.addCssClass("pearl-greeter-contrast") else widget.removeCssClass("pearl-greeter-contrast");
        if (self.reduced_motion) widget.addCssClass("pearl-reduced") else widget.removeCssClass("pearl-reduced");
    }
    fn capsChanged(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        const active = self.keyboard.?.getCapsLockState() != 0;
        self.caps.as(gtk.Widget).setVisible(@intFromBool(active));
        self.caps.as(gtk.Accessible).announce(if (active) "Caps Lock is on" else "Caps Lock is off", .medium);
        // GTK reports the actual active layout label; selection awaits compositor input integration.
        if (self.keyboard.?.getActiveLayoutIndex() >= 0) {
            const label = self.keyboard.?.getLayoutNames();
            if (label) |names| {
                defer glib.strfreev(@ptrCast(names));
                const index: usize = @intCast(self.keyboard.?.getActiveLayoutIndex());
                var n: usize = 0;
                while (n < 64 and @intFromPtr(names[n]) != 0) : (n += 1) {
                    if (n == index) {
                        self.layout_label.setText(names[n]);
                        break;
                    }
                }
            }
        }
    }
    fn monitorChanged(_: *object.Object, _: *object.ParamSpec, self: *Screen) callconv(.c) void {
        self.scheduleMonitors();
    }
    fn listChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Screen) callconv(.c) void {
        self.scheduleMonitors();
    }
    fn scheduleMonitors(self: *Screen) void {
        if (self.monitor_source == 0) self.monitor_source = glib.idleAdd(monitors, self);
    }
    fn monitors(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        self.monitor_source = 0;
        var active = false;
        for (&self.views) |*slot| if (slot.*) |*v| {
            if (v.monitor.isValid() == 0) {
                if (v.active) self.detach(v);
                object.signalHandlerDisconnect(v.monitor.as(object.Object), v.monitor_signal);
                v.window.destroy();
                v.window.unref();
                v.monitor.unref();
                slot.* = null;
            } else if (v.active) active = true;
        };
        const model = self.display.getMonitors();
        const count: usize = @min(model.getNItems(), 64);
        var first: usize = 0;
        if (!active) if (self.config.preferred_output) |wanted| {
            for (0..count) |i| {
                const item = model.getObject(@intCast(i)) orelse continue;
                defer item.unref();
                const monitor = object.ext.cast(gdk.Monitor, item) orelse continue;
                if (monitor.getConnector()) |name| if (std.mem.eql(u8, std.mem.span(name), wanted)) {
                    first = i;
                    break;
                };
            }
        };
        for (0..count) |offset| {
            const i = (first + offset) % count;
            const item = model.getObject(@intCast(i)) orelse continue;
            defer item.unref();
            const monitor = object.ext.cast(gdk.Monitor, item) orelse continue;
            var present = false;
            for (self.views) |slot| if (slot) |v| if (v.monitor == monitor) {
                present = true;
            };
            if (present or monitor.isValid() == 0) continue;
            for (&self.views) |*slot| if (slot.* == null) {
                self.createView(slot, monitor, !active);
                active = true;
                break;
            };
        }
        if (!active) {
            for (&self.views) |*slot| if (slot.*) |*v| {
                self.attach(v);
                active = true;
                break;
            };
        }
        if (!active) self.cancelAttempt();
        for (&self.views) |*slot| if (slot.*) |*v| self.resize(v);
        if (options.test_hooks) std.log.info("event=greeter-outputs interactive={d}", .{@as(u8, if (active) 1 else 0)});
        return 0;
    }
    fn resize(self: *Screen, v: *View) void {
        var geometry: gdk.Rectangle = undefined;
        v.monitor.getGeometry(&geometry);
        const short = geometry.f_height < 500;
        v.clock.as(gtk.Widget).setVisible(@intFromBool(!short and !v.active));
        v.date.as(gtk.Widget).setVisible(@intFromBool(!short and !v.active));
        if (v.active) {
            self.clock.as(gtk.Widget).setVisible(@intFromBool(!short));
            self.date.as(gtk.Widget).setVisible(@intFromBool(!short));
        }
        if (geometry.f_width < 500 or geometry.f_height < 600) v.window.as(gtk.Widget).addCssClass("pearl-lock-small") else v.window.as(gtk.Widget).removeCssClass("pearl-lock-small");
        if (v.active) self.panel.setSpacing(if (short) 8 else 16);
    }
    fn attach(self: *Screen, v: *View) void {
        // The column retains an explicit ref while moving between outputs.
        const overlay = object.ext.cast(gtk.Overlay, v.window.getChild().?).?;
        const scroll = gtk.ScrolledWindow.new();
        scroll.setPolicy(.automatic, .automatic);
        const viewport = gtk.Viewport.new(null, null);
        viewport.setScrollToFocus(1);
        viewport.setChild(self.column.as(gtk.Widget));
        scroll.setChild(viewport.as(gtk.Widget));
        overlay.addOverlay(scroll.as(gtk.Widget));
        v.scroll = scroll;
        v.active = true;
        layer.setKeyboardMode(v.window, .exclusive);
        self.clear();
        self.update();
        if (self.client.controller.state == .idle) _ = self.username.as(gtk.Widget).grabFocus();
    }
    fn detach(self: *Screen, v: *View) void {
        self.clear();
        if (v.scroll) |scroll| {
            if (self.column.as(gtk.Widget).getParent()) |parent| object.ext.cast(gtk.Viewport, parent).?.setChild(null);
            const overlay = object.ext.cast(gtk.Overlay, v.window.getChild().?).?;
            overlay.removeOverlay(scroll.as(gtk.Widget));
            v.scroll = null;
        }
        v.active = false;
        layer.setKeyboardMode(v.window, .none);
    }
    fn move(_: *gtk.Button, self: *Screen) callconv(.c) void {
        var current: ?usize = null;
        var target: ?usize = null;
        for (self.views, 0..) |slot, i| if (slot) |v| {
            if (v.active) current = i;
        };
        const old = current orelse return;
        for (1..65) |offset| {
            const i = (old + offset) % 64;
            if (i != old and self.views[i] != null) {
                target = i;
                break;
            }
        }
        const next = target orelse return;
        self.detach(&self.views[old].?);
        self.attach(&self.views[next].?);
        self.resize(&self.views[old].?);
        self.resize(&self.views[next].?);
    }
    fn createView(self: *Screen, slot: *?View, monitor: *gdk.Monitor, active: bool) void {
        const window = gtk.Window.new();
        window.ref();
        monitor.ref();
        window.setTitle("Pearl · Sign in");
        for ([_][*:0]const u8{ "pearl-root", "pearl-lock", "pearl-wallpaper", "background" }) |class| window.as(gtk.Widget).addCssClass(class);
        window.as(gtk.Widget).addCssClass(if (self.config.theme == .material_light) "pearl-light" else if (self.config.theme == .gtk) "pearl-native" else "pearl-dark");
        self.accessibilityStyle(window);
        layer.initForWindow(window);
        layer.setNamespace(window, "pearl-greeter");
        layer.setLayer(window, .overlay);
        layer.setMonitor(window, monitor);
        layer.setExclusiveZone(window, -1);
        for ([_]layer.Edge{ .top, .bottom, .left, .right }) |edge| layer.setAnchor(window, edge, 1);
        const overlay = gtk.Overlay.new();
        window.setChild(overlay.as(gtk.Widget));
        const picture = gtk.Picture.new();
        picture.setCanShrink(1);
        picture.setContentFit(.cover);
        picture.setPaintable(if (self.texture) |texture| texture.as(gdk.Paintable) else null);
        overlay.setChild(picture.as(gtk.Widget));
        const clock = w.label("", "pearl-lock-clock");
        const date = w.label("", "pearl-lock-date");
        const backdrop = w.column(12);
        backdrop.as(gtk.Widget).setHalign(.center);
        backdrop.as(gtk.Widget).setValign(.start);
        backdrop.as(gtk.Widget).setMarginTop(32);
        clock.setXalign(0.5);
        date.setXalign(0.5);
        backdrop.append(clock.as(gtk.Widget));
        backdrop.append(date.as(gtk.Widget));
        overlay.addOverlay(backdrop.as(gtk.Widget));
        presentation.updateClock(clock, date);
        slot.* = .{ .window = window, .monitor = monitor, .picture = picture, .clock = clock, .date = date, .active = false, .monitor_signal = object.Object.signals.notify.connect(monitor.as(object.Object), *Screen, monitorChanged, self, .{}) };
        if (active) self.attach(&slot.*.?) else layer.setKeyboardMode(window, .none);
        _ = gtk.Window.signals.close_request.connect(window, *Screen, close, self, .{});
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Screen, key, self, .{});
        window.as(gtk.Widget).addController(keys.as(gtk.EventController));
        window.present();
        self.resize(&slot.*.?);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Screen = @ptrCast(@alignCast(data.?));
        for (self.views) |slot| if (slot) |v| presentation.updateClock(v.clock, v.date);
        presentation.updateClock(self.clock, self.date);
        self.scheduleClock();
        return 0;
    }
    fn scheduleClock(self: *Screen) void {
        const now = glib.DateTime.newNowLocal();
        defer if (now) |n| n.unref();
        self.tick_source = glib.timeoutAddSeconds(if (now) |n| @intCast(60 - n.getSecond()) else 60, tick, self);
    }
};
pub fn run() !void {
    const parsed = try cfg.load(a);
    const config = parsed.value;
    const socket = glib.getenv("GREETD_SOCK") orelse return error.MissingGreetdSocket;
    if (!options.test_hooks) {
        const home = glib.getenv("HOME") orelse return error.MissingGreeterHome;
        const fd = try trusted.open(std.mem.span(home), true);
        _ = std.c.close(fd);
        for ([_][*:0]const u8{ "GTK_PATH", "GTK_MODULES", "GTK4_MODULES", "GTK_THEME" }) |key| glib.unsetenv(key);
        _ = glib.setenv("GDK_BACKEND", "wayland", 1);
        _ = glib.setenv("XDG_CONFIG_HOME", "/var/empty/pearl-greeter/.config", 1);
        _ = glib.setenv("XDG_DATA_HOME", "/var/empty/pearl-greeter/.local/share", 1);
        _ = glib.setenv("XDG_DATA_DIRS", "/usr/local/share:/usr/share", 1);
        _ = glib.setenv("XDG_CACHE_HOME", "/var/cache/pearl-greeter", 1);
        _ = glib.setenv("XDG_STATE_HOME", "/var/lib/pearl-greeter", 1);
    }
    if (config.gtk_theme) |theme| {
        const z = try a.dupeZ(u8, theme);
        defer a.free(z);
        _ = glib.setenv("GTK_THEME", z, 1);
    }
    if (config.screen_reader) _ = glib.setenv("GTK_A11Y", "atspi", 1);
    gtk.init();
    const display = gdk.Display.getDefault() orelse return error.NoDisplay;
    if (layer.isSupported() == 0) return error.LayerShellRequired;
    if (config.reduced_motion) if (gtk.Settings.getDefault()) |settings| {
        settings.as(object.Object).set("gtk-enable-animations", @as(c_int, 0), "gtk-cursor-blink", @as(c_int, 0), @as(?[*:0]const u8, null));
    };
    const provider = gtk.CssProvider.new();
    if (config.theme != .gtk) {
        const style = try @import("../theme/theme.zig").css(a, @embedFile("greeter_style"));
        defer a.free(style);
        provider.loadFromString(style);
        gtk.StyleContext.addProviderForDisplay(display, provider.as(gtk.StyleProvider), 600);
    }
    const sizing = gtk.CssProvider.new();
    const css = try std.fmt.allocPrintSentinel(a, "{s} .pearl-root {{font-size:{d}px;}} .pearl-greeter-form {{margin: 24px;}} .pearl-lock-card button, .pearl-lock-card entry {{min-height:26px; padding:8px 12px;}} .pearl-lock-card {{padding:20px;}} .pearl-greeter-form > box > button {{min-height:26px;}} .pearl-lock-small .pearl-greeter-form {{margin-top:24px;}} .pearl-lock .pearl-large {{font-size:24px;}} .pearl-native .pearl-lock-card {{background:@theme_bg_color; color:@theme_fg_color;}} .pearl-lock dropdown {{min-width:0;}} .pearl-reduced * {{transition:none; animation:none;}}", .{ presentation.css, config.font_size }, 0);
    defer a.free(css);
    sizing.loadFromString(css);
    gtk.StyleContext.addProviderForDisplay(display, sizing.as(gtk.StyleProvider), 601);
    const contrast_style = gtk.CssProvider.new();
    contrast_style.loadFromString(".pearl-greeter-contrast, .pearl-greeter-contrast .pearl-greeter-form, .pearl-greeter-contrast .pearl-lock-card {background: #000; background-image: none; color: #fff;} .pearl-greeter-contrast label {color: #fff; opacity: 1;} .pearl-greeter-contrast button, .pearl-greeter-contrast entry, .pearl-greeter-contrast check {background: #000; background-image: none; color: #fff; border: 2px solid #fff; box-shadow: none;} .pearl-greeter-contrast :focus-visible {outline: 3px solid #ffff00; outline-offset: 3px;} .pearl-greeter-contrast :disabled {border-style: dashed; opacity: 0.7;}");
    gtk.StyleContext.addProviderForDisplay(display, contrast_style.as(gtk.StyleProvider), 602);
    const column = w.column(16);
    _ = column.as(object.Object).refSink();
    column.as(gtk.Widget).addCssClass("pearl-greeter-form");
    column.as(gtk.Widget).setHalign(.center);
    column.as(gtk.Widget).setValign(.center);
    const clock = w.label("", "pearl-lock-clock");
    const date = w.label("", "pearl-lock-date");
    clock.setXalign(0.5);
    date.setXalign(0.5);
    column.append(clock.as(gtk.Widget));
    column.append(date.as(gtk.Widget));
    presentation.updateClock(clock, date);
    const panel = w.card();
    panel.setSpacing(12);
    panel.as(gtk.Widget).addCssClass("pearl-lock-card");
    panel.as(gtk.Widget).setSizeRequest(220, -1);
    column.append(panel.as(gtk.Widget));
    const avatar = gtk.Image.newFromIconName("avatar-default-symbolic");
    avatar.setPixelSize(32);
    panel.append(avatar.as(gtk.Widget));
    const title = w.label("Sign in to your desktop", "pearl-title");
    title.setXalign(0.5);
    panel.append(title.as(gtk.Widget));
    const account = gtk.DropDown.new(null, null);
    w.name(account.as(gtk.Widget), "Account");
    panel.append(account.as(gtk.Widget));
    account.as(gtk.Widget).setVisible(0);
    const username = gtk.Entry.new();
    username.setMaxLength(257);
    username.setPlaceholderText("Username");
    w.name(username.as(gtk.Widget), "Username");
    panel.append(username.as(gtk.Widget));
    const chooser = gtk.DropDown.new(null, null);
    const factory = gtk.SignalListItemFactory.new();
    _ = gtk.SignalListItemFactory.signals.setup.connect(factory, ?*anyopaque, sessionSetup, null, .{});
    _ = gtk.SignalListItemFactory.signals.bind.connect(factory, ?*anyopaque, sessionBind, null, .{});
    chooser.setFactory(factory.as(gtk.ListItemFactory));
    chooser.setListFactory(factory.as(gtk.ListItemFactory));
    factory.unref();
    w.name(chooser.as(gtk.Widget), "Desktop session");
    panel.append(chooser.as(gtk.Widget));
    const refresh = w.iconButton("view-refresh-symbolic", "Refresh desktops");
    const session_row = w.row(8);
    chooser.ref();
    panel.remove(chooser.as(gtk.Widget));
    session_row.append(chooser.as(gtk.Widget));
    chooser.unref();
    chooser.as(gtk.Widget).setHexpand(1);
    session_row.append(refresh.as(gtk.Widget));
    panel.append(session_row.as(gtk.Widget));
    const message = w.label("Loading installed desktops…", "pearl-secondary");
    message.setMaxWidthChars(36);
    panel.append(message.as(gtk.Widget));
    const entry = presentation.secureEntry(4097);
    panel.append(entry.as(gtk.Widget));
    const caps = w.label("Caps Lock is on", "pearl-secondary");
    caps.as(gtk.Widget).setVisible(0);
    panel.append(caps.as(gtk.Widget));
    const button = gtk.Button.newWithLabel("Sign in");
    button.as(gtk.Widget).addCssClass("pearl-primary");
    panel.append(button.as(gtk.Widget));
    const cancel = gtk.Button.newWithLabel("Cancel authentication");
    panel.append(cancel.as(gtk.Widget));
    const footer = w.column(8);
    if (config.fingerprint_hint) {
        const hint = w.label("Fingerprint login is available when configured", "pearl-secondary");
        hint.setWrap(1);
        hint.setMaxWidthChars(36);
        footer.append(hint.as(gtk.Widget));
    }
    const controls = w.row(8);
    footer.append(controls.as(gtk.Widget));
    column.append(footer.as(gtk.Widget));
    const layout_label = w.label("Keyboard layout", "pearl-secondary");
    footer.append(layout_label.as(gtk.Widget));
    layout_label.as(gtk.Widget).setTooltipText("Keyboard layout switching is currently unavailable.");
    const bigger = gtk.Button.newWithLabel("Larger text");
    controls.append(bigger.as(gtk.Widget));
    const reader = gtk.Button.newWithLabel("Screen reader");
    reader.as(gtk.Widget).setVisible(@intFromBool(config.screen_reader));
    controls.append(reader.as(gtk.Widget));
    const move = gtk.Button.newWithLabel("Move login card");
    controls.append(move.as(gtk.Widget));
    const contrast = gtk.CheckButton.newWithLabel("High contrast");
    const motion = gtk.CheckButton.newWithLabel("Reduced motion");
    motion.setActive(@intFromBool(config.reduced_motion));
    footer.append(contrast.as(gtk.Widget));
    footer.append(motion.as(gtk.Widget));
    const power_row = w.row(8);
    footer.append(power_row.as(gtk.Widget));
    const reboot = gtk.Button.newWithLabel("Restart");
    const off = gtk.Button.newWithLabel("Power off");
    power_row.append(reboot.as(gtk.Widget));
    power_row.append(off.as(gtk.Widget));
    power_row.as(gtk.Widget).setVisible(@intFromBool(config.power));
    const confirm = gtk.Button.newWithLabel("Confirm");
    const cancel_power = gtk.Button.newWithLabel("Cancel power action");
    footer.append(confirm.as(gtk.Widget));
    footer.append(cancel_power.as(gtk.Widget));
    var self: Screen = .{ .config = config, .loop = glib.MainLoop.new(null, 0), .display = display, .column = column, .panel = panel, .username = username, .entry = entry, .chooser = chooser, .account_chooser = account, .message = message, .caps = caps, .button = button, .cancel_button = cancel, .refresh_button = refresh, .reboot_button = reboot, .off_button = off, .confirm = confirm, .cancel_power = cancel_power, .layout_label = layout_label, .clock = clock, .date = date };
    self.reduced_motion = config.reduced_motion;
    self.client = .{ .path = std.mem.span(socket), .context = &self, .changed = Screen.changed, .timeout_ms = @as(c_uint, config.auth_timeout_seconds) * 1000 };
    self.client.init();
    self.power = .{ .context = &self, .changed = Screen.powerChanged };
    if (config.power) self.power.init();
    _ = gtk.Button.signals.clicked.connect(button, *Screen, Screen.submit, &self, .{});
    _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *Screen, Screen.activity, &self, .{});
    _ = gtk.Entry.signals.activate.connect(entry, *Screen, Screen.entered, &self, .{});
    _ = gtk.Entry.signals.activate.connect(username, *Screen, Screen.entered, &self, .{});
    _ = gtk.Button.signals.clicked.connect(cancel, *Screen, Screen.cancelled, &self, .{});
    _ = gtk.Button.signals.clicked.connect(refresh, *Screen, Screen.refreshed, &self, .{});
    _ = gtk.Button.signals.clicked.connect(reboot, *Screen, Screen.reboot, &self, .{});
    _ = gtk.Button.signals.clicked.connect(off, *Screen, Screen.off, &self, .{});
    _ = gtk.Button.signals.clicked.connect(confirm, *Screen, Screen.confirmed, &self, .{});
    _ = gtk.Button.signals.clicked.connect(cancel_power, *Screen, Screen.cancelPower, &self, .{});
    _ = gtk.Button.signals.clicked.connect(bigger, *Screen, Screen.larger, &self, .{});
    _ = gtk.Button.signals.clicked.connect(reader, *Screen, Screen.reader, &self, .{});
    _ = gtk.Button.signals.clicked.connect(move, *Screen, Screen.move, &self, .{});
    _ = gtk.CheckButton.signals.toggled.connect(contrast, *Screen, Screen.contrastChanged, &self, .{});
    _ = gtk.CheckButton.signals.toggled.connect(motion, *Screen, Screen.motionChanged, &self, .{});
    _ = object.Object.signals.notify.connect(chooser.as(object.Object), *Screen, Screen.selected, &self, .{ .detail = "selected" });
    _ = object.Object.signals.notify.connect(account.as(object.Object), *Screen, Screen.selectedAccount, &self, .{ .detail = "selected" });
    if (display.getDefaultSeat()) |seat| if (seat.getKeyboard()) |keyboard| {
        self.keyboard = keyboard;
        _ = object.Object.signals.notify.connect(keyboard.as(object.Object), *Screen, Screen.capsChanged, &self, .{});
        Screen.capsChanged(keyboard.as(object.Object), undefined, &self);
    };
    _ = gio.ListModel.signals.items_changed.connect(display.getMonitors(), *Screen, Screen.listChanged, &self, .{});
    _ = Screen.monitors(&self);
    self.scheduleClock();
    self.refresh(.refresh);
    self.loop.run();
    self.clear();
    self.client.deinit();
    if (self.reader_process) |child| child.forceExit();
    // Outstanding GLib workers/signals must never outlive this stack or start sessions.
    std.process.exit(self.status);
}

fn sessionSetup(_: *gtk.SignalListItemFactory, item: *object.Object, _: ?*anyopaque) callconv(.c) void {
    const row = object.ext.cast(gtk.ListItem, item).?;
    const label = gtk.Label.new(null);
    label.setEllipsize(.end);
    label.setMaxWidthChars(28);
    label.setXalign(0);
    row.setChild(label.as(gtk.Widget));
}
fn sessionBind(_: *gtk.SignalListItemFactory, item: *object.Object, _: ?*anyopaque) callconv(.c) void {
    const row = object.ext.cast(gtk.ListItem, item).?;
    const value = object.ext.cast(gtk.StringObject, row.getItem().?).?;
    object.ext.cast(gtk.Label, row.getChild().?).?.setText(value.getString());
}
