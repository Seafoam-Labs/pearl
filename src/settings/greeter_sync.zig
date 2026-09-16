//! Shared native sync button for the standalone application and settings flyout.
const std = @import("std");
const gtk = @import("gtk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const model = @import("../config/preferences.zig");
const writer = @import("../greeter/appearance_sync.zig");
const w = @import("../ui/components/widgets.zig");
const a = std.heap.c_allocator;
pub const View = struct {
    button: *gtk.Button,
    status: *gtk.Label,
    context: *anyopaque,
    get: *const fn (*anyopaque, std.mem.Allocator) anyerror!model.Preferences,
    job: ?*Job = null,
    german: bool,
    pub fn create(host: *gtk.Box, context: *anyopaque, get: @FieldType(View, "get"), german: bool) !*View {
        const self = try a.create(View);
        const box = w.column(8);
        box.as(gtk.Widget).setMarginTop(12);
        box.as(gtk.Widget).setMarginBottom(12);
        host.append(box.as(gtk.Widget));
        box.append(w.label(if (german) "Anmeldebildschirm" else "Login screen", "pearl-title").as(gtk.Widget));
        const button = w.wrappingButton(if (german) "Mit Greeter synchronisieren" else "Sync to greeter");
        button.as(gtk.Widget).setHalign(.start);
        w.name(button.as(gtk.Widget), if (german) "Mit Greeter synchronisieren" else "Sync to greeter");
        box.append(button.as(gtk.Widget));
        const status = w.label(if (german) "Kopiert Hintergrund und Design. Erfordert Administrator-Authentifizierung." else "Copies this background and theme. Administrator authentication is required.", "pearl-secondary");
        status.setWrap(1);
        box.append(status.as(gtk.Widget));
        self.* = .{ .button = button, .status = status, .context = context, .get = get, .german = german };
        if (glib.fileTest(helper(), .{ .is_executable = true }) == 0) {
            button.as(gtk.Widget).setSensitive(0);
            status.setText(if (german) "Pearl Greeter installieren, um das Erscheinungsbild zu synchronisieren." else "Install Pearl Greeter to sync its appearance.");
        }
        _ = gtk.Button.signals.clicked.connect(button, *View, clicked, self, .{});
        return self;
    }
    pub fn destroy(self: *View) void {
        if (self.job) |job| job.owner = null;
        a.destroy(self);
    }
    fn clicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.job != null) return;
        const job = a.create(Job) catch return;
        job.* = .{ .owner = self, .arena = .init(a), .cancel = gio.Cancellable.new() };
        const alloc = job.arena.allocator();
        job.prefs = self.get(self.context, alloc) catch {
            self.status.setText(if (self.german) "Bitte zuerst die ungültigen Einstellungen korrigieren." else "Correct the invalid appearance settings before syncing.");
            job.destroy();
            return;
        };
        job.prefs.validate() catch {
            self.status.setText(if (self.german) "Bitte zuerst die ungültigen Einstellungen korrigieren." else "Correct the invalid appearance settings before syncing.");
            job.destroy();
            return;
        };
        job.gtk_dark = job.prefs.theme.variant == .dark;
        // Resolve an empty GTK selection in the user's GTK context, before elevation.
        if (job.prefs.theme.mode == .gtk and job.prefs.theme.gtk_name.len == 0) {
            if (gtk.Settings.getDefault()) |settings| {
                var name: ?[*:0]u8 = null;
                var dark: c_int = 0;
                settings.as(object.Object).get("gtk-theme-name", &name, "gtk-application-prefer-dark-theme", &dark, @as(?[*:0]const u8, null));
                job.gtk_dark = dark != 0;
                if (name) |value| {
                    defer glib.free(value);
                    job.prefs.theme.gtk_name = alloc.dupe(u8, std.mem.span(value)) catch "";
                }
            }
            if (glib.getenv("GTK_THEME")) |override| {
                job.prefs.theme.gtk_name = alloc.dupe(u8, std.mem.span(override)) catch "";
                job.gtk_dark = false; // The override includes its own optional variant.
            }
        }
        self.job = job;
        self.button.as(gtk.Widget).setSensitive(0);
        self.status.setText(if (self.german) "Erscheinungsbild wird synchronisiert…" else "Syncing appearance…");
        job.timer = glib.timeoutAdd(180000, Job.timedOut, job);
        const task = gio.Task.new(null, job.cancel, Job.completed, job);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(Job.work);
        task.unref();
    }
};
fn helper() [*:0]const u8 {
    if (@import("build_options").test_hooks) if (glib.getenv("PEARL_TEST_GREETER_SYNC")) |value| return value;
    return "/usr/lib/pearl/pearl-greeter-sync";
}
const Job = struct {
    owner: ?*View,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    prefs: model.Preferences = .{},
    timer: c_uint = 0,
    err: ?anyerror = null,
    denied: bool = false,
    gtk_dark: bool = false,
    fn destroy(self: *Job) void {
        if (self.timer != 0) _ = glib.Source.remove(self.timer);
        self.cancel.unref();
        self.arena.deinit();
        a.destroy(self);
    }
    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.timer = 0;
        self.cancel.cancel();
        return 0;
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        self.run() catch |err| {
            self.err = err;
        };
        task.returnBoolean(1);
    }
    fn run(self: *Job) !void {
        const alloc = self.arena.allocator();
        const prefs = self.prefs;
        var request: writer.Request = .{
            .theme = if (prefs.theme.mode == .gtk) .gtk else if (prefs.theme.variant == .light) .material_light else .material_dark,
            .gtk_theme = if (prefs.theme.mode == .gtk and prefs.theme.gtk_name.len != 0) prefs.theme.gtk_name else null,
            .wallpaper_fit = if (prefs.wallpaper.mode == .contain) .contain else .cover,
            .wallpaper_color = if (prefs.wallpaper.mode == .gradient) null else prefs.wallpaper.color,
        };
        if (request.gtk_theme) |name| {
            if (self.gtk_dark) request.gtk_theme = try std.fmt.allocPrint(alloc, "{s}:dark", .{name});
        }
        if (prefs.wallpaper.mode == .cover or prefs.wallpaper.mode == .contain) {
            const path = try alloc.dupeZ(u8, prefs.wallpaper.path);
            const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
            if (fd < 0) return error.ImageUnavailable;
            defer _ = std.c.close(fd);
            var stat: std.os.linux.Statx = undefined;
            if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !std.c.S.ISREG(stat.mode)) return error.InvalidImage;
            const bytes = try writer.read(fd, writer.max_image);
            defer a.free(bytes);
            if (!@import("../services/artwork.zig").dimensionsWithin(bytes, 16384, 64 * 1024 * 1024)) return error.InvalidImage;
            const storage = glib.Bytes.new(bytes.ptr, bytes.len);
            defer storage.unref();
            const stream = gio.MemoryInputStream.newFromBytes(storage);
            defer stream.unref();
            const image = pixbuf.Pixbuf.newFromStreamAtScale(stream.as(gio.InputStream), 3840, 2160, 1, self.cancel, null) orelse return error.InvalidImage;
            defer image.unref();
            var png: [*]u8 = undefined;
            var png_len: usize = 0;
            if (image.saveToBufferv(&png, &png_len, "png", null, null, null) == 0) return error.InvalidImage;
            defer glib.free(png);
            if (png_len > writer.max_image) return error.TooLarge;
            const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(png_len));
            request.image = std.base64.standard.Encoder.encode(encoded, png[0..png_len]);
        }
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        const json = try std.json.Stringify.valueAlloc(alloc, request, .{});
        const input = try alloc.dupeZ(u8, json);
        var args = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", helper(), "--apply" };
        var start: usize = 0;
        if (@import("build_options").test_hooks and glib.getenv("PEARL_TEST_GREETER_SYNC") != null) start = 1;
        const process = gio.Subprocess.newv(@ptrCast(args[start..].ptr), .{ .stdin_pipe = true, .stdout_silence = true, .stderr_pipe = true }, null) orelse return error.HelperUnavailable;
        defer process.unref();
        var stderr: [*:0]u8 = undefined;
        if (process.communicateUtf8(input, self.cancel, null, &stderr, null) == 0) {
            process.forceExit();
            return error.Cancelled;
        }
        defer glib.free(stderr);
        if (process.getIfExited() == 0) return error.SyncFailed;
        const code = process.getExitStatus();
        if (code == 126 or code == 127) {
            self.denied = true;
            return;
        }
        if (code != 0) {
            if (std.mem.indexOf(u8, std.mem.span(stderr), "SystemThemeRequired") != null) return error.SystemThemeRequired;
            return error.SyncFailed;
        }
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data.?));
        defer self.destroy();
        if (self.owner) |owner| {
            owner.job = null;
            owner.button.as(gtk.Widget).setSensitive(1);
            const message: [:0]const u8 = if (self.denied)
                (if (owner.german) "Synchronisierung nicht autorisiert." else "Sync cancelled or not authorized.")
            else if (self.err) |err| switch (err) {
                error.InvalidImage, error.ImageUnavailable, error.TooLarge => if (owner.german) "Ein lesbares PNG/JPEG wählen (max. 16 MiB und 64 Megapixel)." else "Choose a readable PNG/JPEG (up to 16 MiB and 64 megapixels).",
                error.SystemThemeRequired => if (owner.german) "Das GTK-Design muss systemweit installiert sein." else "Install this GTK theme system-wide before syncing.",
                else => if (owner.german) "Synchronisierung fehlgeschlagen. Greeter-Installation und Authentifizierung prüfen." else "Could not sync. Check that Pearl Greeter is installed and authentication completed.",
            } else if (owner.german) "Synchronisiert. Wird beim nächsten Start des Anmeldebildschirms verwendet." else "Synced. The login screen will use this appearance next time it starts.";
            owner.status.setText(message);
            std.log.info("event=greeter-appearance-sync success={}", .{self.err == null and !self.denied});
        }
    }
};
