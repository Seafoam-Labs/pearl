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
const log = std.log.scoped(.settings);
const a = std.heap.c_allocator;
pub const View = struct {
    button: *gtk.Button,
    choose: *gtk.Button,
    picker: ?*gtk.FileChooserNative = null,
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
        const choose = w.wrappingButton(if (german) "Bild auswählen und synchronisieren…" else "Choose image and sync…");
        choose.as(gtk.Widget).setHalign(.start);
        w.name(choose.as(gtk.Widget), if (german) "Bild auswählen und synchronisieren" else "Choose image and sync");
        box.append(choose.as(gtk.Widget));
        const status = w.label(if (german) "Kopiert Hintergrund und Design. Erfordert Administrator-Authentifizierung." else "Copies this background and theme. Administrator authentication is required.", "pearl-secondary");
        status.setWrap(1);
        box.append(status.as(gtk.Widget));
        self.* = .{ .button = button, .choose = choose, .status = status, .context = context, .get = get, .german = german };
        if (glib.fileTest(helper(), .{ .is_executable = true }) == 0) {
            button.as(gtk.Widget).setSensitive(0);
            choose.as(gtk.Widget).setSensitive(0);
            status.setText(if (german) "Pearl Greeter installieren, um das Erscheinungsbild zu synchronisieren." else "Install Pearl Greeter to sync its appearance.");
        }
        _ = gtk.Button.signals.clicked.connect(button, *View, clicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(choose, *View, chooseClicked, self, .{});
        return self;
    }
    pub fn destroy(self: *View) void {
        if (self.job) |job| job.owner = null;
        a.destroy(self);
    }
    fn clicked(_: *gtk.Button, self: *View) callconv(.c) void {
        self.start(null);
    }
    fn chooseClicked(_: *gtk.Button, self: *View) callconv(.c) void {
        if (self.job != null or self.picker != null) return;
        const root = self.choose.as(gtk.Widget).getRoot() orelse return;
        const parent = object.ext.cast(gtk.Window, root) orelse return;
        const picker = gtk.FileChooserNative.new(if (self.german) "Hintergrund für den Anmeldebildschirm" else "Login screen background", parent, .open, if (self.german) "Wählen" else "Choose", if (self.german) "Abbrechen" else "Cancel");
        const filter = gtk.FileFilter.new();
        filter.addMimeType("image/png");
        filter.addMimeType("image/jpeg");
        filter.setName(if (self.german) "Bilder" else "Images");
        picker.as(gtk.FileChooser).setFilter(filter);
        self.picker = picker;
        _ = gtk.NativeDialog.signals.response.connect(picker.as(gtk.NativeDialog), *View, picked, self, .{});
        picker.as(gtk.NativeDialog).show();
    }
    fn picked(_: *gtk.NativeDialog, response: c_int, self: *View) callconv(.c) void {
        const picker = self.picker orelse return;
        self.picker = null;
        defer {
            picker.as(gtk.NativeDialog).destroy();
            picker.unref();
        }
        if (response != @intFromEnum(gtk.ResponseType.accept)) return;
        const file = picker.as(gtk.FileChooser).getFile() orelse return;
        defer file.unref();
        const path = file.getPath() orelse return;
        defer glib.free(path);
        self.start(std.mem.span(path));
    }
    fn start(self: *View, override: ?[]const u8) void {
        if (self.job != null) return;
        const job = a.create(Job) catch return;
        job.* = .{ .owner = self, .arena = .init(a), .cancel = gio.Cancellable.new() };
        const alloc = job.arena.allocator();
        if (override) |path| {
            job.override = alloc.dupeZ(u8, path) catch {
                job.destroy();
                return;
            };
        }
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
            if (glib.getenv("GTK_THEME")) |theme_override| {
                job.prefs.theme.gtk_name = alloc.dupe(u8, std.mem.span(theme_override)) catch "";
                job.gtk_dark = false; // The override includes its own optional variant.
            }
        }
        self.job = job;
        self.button.as(gtk.Widget).setSensitive(0);
        self.choose.as(gtk.Widget).setSensitive(0);
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
const socket_path = "/run/pearl/greeter-sync.sock";
const SocketResult = enum { ok, denied, failed, system_theme };
const SocketAddress = extern struct { family: u16, path: [108]u8 };
/// null means no service socket: the caller falls back to pkexec.
fn socketSync(input: [:0]u8) ?SocketResult {
    const fd = std.c.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var addr = SocketAddress{ .family = std.os.linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(SocketAddress));
    if (rc < 0) return null;
    var offset: usize = 0;
    while (offset < input.len) {
        const n = std.c.write(fd, input.ptr + offset, input.len - offset);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return .failed;
        }
        offset += @intCast(n);
    }
    var line: [256]u8 = undefined;
    var used: usize = 0;
    while (used < line.len) {
        var one: [1]u8 = undefined;
        const n = std.c.read(fd, &one, 1);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return .failed;
        }
        if (n == 0 or one[0] == '\n') break;
        line[used] = one[0];
        used += 1;
    }
    const text = std.mem.trim(u8, line[0..used], " \r");
    if (std.mem.eql(u8, text, "ok")) return .ok;
    if (std.mem.eql(u8, text, "denied")) return .denied;
    if (std.mem.eql(u8, text, "SystemThemeRequired")) return .system_theme;
    return .failed;
}
fn readWallpaper(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try alloc.dupeZ(u8, path);
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
    if (fd < 0) return error.ImageUnavailable;
    defer _ = std.c.close(fd);
    var stat: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat) != 0 or !std.c.S.ISREG(stat.mode)) return error.InvalidImage;
    return writer.read(fd, writer.max_image);
}
const Job = struct {
    owner: ?*View,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    prefs: model.Preferences = .{},
    override: ?[:0]u8 = null,
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
        // The greeter's frost matches the bar's custom opacity; automatic stays
        // theme-owned on both sides.
        request.surface_opacity = if (prefs.bar.background_opacity.mode == .custom) prefs.bar.background_opacity.percent else null;
        if (request.gtk_theme) |name| {
            if (self.gtk_dark) request.gtk_theme = try std.fmt.allocPrint(alloc, "{s}:dark", .{name});
        }
        const follow = prefs.matugen.colors.source == .follow_pearl;
        var source = prefs;
        if (!follow) {
            source.theme.source = if (prefs.matugen.colors.source == .seed) .seed else .wallpaper;
            source.theme.seed = prefs.matugen.colors.seed;
        }
        const palette_wanted = request.theme != .gtk and prefs.matugen.enabled and (!follow or prefs.theme.mode == .dynamic);
        const wants_image = self.override != null or prefs.wallpaper.mode == .cover or prefs.wallpaper.mode == .contain;
        const wallpaper_path: []const u8 = self.override orelse prefs.wallpaper.path;
        var wallpaper_bytes: ?[]u8 = null;
        defer if (wallpaper_bytes) |bytes| a.free(bytes);
        if (wants_image or (palette_wanted and source.theme.source == .wallpaper)) {
            wallpaper_bytes = readWallpaper(alloc, wallpaper_path) catch |err| blk: {
                if (wants_image) return err;
                break :blk null;
            };
        }
        if (wants_image) {
            const bytes = wallpaper_bytes orelse return error.ImageUnavailable;
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
        if (palette_wanted) {
            // Reuse the shell's matugen cache; the greeter never runs matugen.
            const cache = try std.fmt.allocPrintSentinel(alloc, "{s}/pearl/matugen", .{std.mem.span(glib.getUserCacheDir())}, 0);
            @import("../config/io.zig").mkdir(cache) catch {};
            var hit = false;
            if (@import("../theme/generator.zig").full(alloc, source, wallpaper_bytes, cache, self.cancel, &hit)) |render| {
                const theme_mod = @import("../theme/theme.zig");
                // Ship only JSON the greeter can expand for both variants.
                if (theme_mod.matugenPalette(alloc, render.json, "dark")) |dark| {
                    if (theme_mod.validate(dark)) |_| {
                        if (theme_mod.matugenPalette(alloc, render.json, "light")) |light| {
                            if (theme_mod.validate(light)) |_| {
                                const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(render.json.len));
                                request.palette = std.base64.standard.Encoder.encode(encoded, render.json);
                                log.info("event=greeter-palette-sent bytes={d}", .{render.json.len});
                            } else |_| log.warn("event=greeter-palette-skip reason=light-contrast", .{});
                        } else |_| log.warn("event=greeter-palette-skip reason=light-parse", .{});
                    } else |_| log.warn("event=greeter-palette-skip reason=dark-contrast", .{});
                } else |_| log.warn("event=greeter-palette-skip reason=dark-parse", .{});
            } else |err| {
                log.warn("event=greeter-palette-skip reason={s}", .{@errorName(err)});
            }
        } else {
            log.info("event=greeter-palette-skip reason={s}", .{if (request.theme == .gtk) "gtk-theme" else if (!prefs.matugen.enabled) "matugen-disabled" else "static-follow"});
        }
        if (self.cancel.isCancelled() != 0) return error.Cancelled;
        const json = try std.json.Stringify.valueAlloc(alloc, request, .{});
        const input = try alloc.dupeZ(u8, json);
        const test_bypass = @import("build_options").test_hooks and glib.getenv("PEARL_TEST_GREETER_SYNC") != null;
        // Prefer the socket-activated root service: it authorizes against the
        // caller's login session, which pkexec cannot resolve when Pearl runs
        // outside a logind session scope.
        if (!test_bypass) {
            if (socketSync(input)) |result| {
                switch (result) {
                    .ok => return,
                    .denied => {
                        self.denied = true;
                        return;
                    },
                    .system_theme => return error.SystemThemeRequired,
                    // A broken or mismatched service (rolling upgrade with an
                    // old helper behind the socket) must not block the pkexec
                    // path that worked before the socket existed.
                    .failed => {},
                }
            }
        }
        var args = [_:null]?[*:0]const u8{ "/usr/bin/pkexec", helper(), "--apply" };
        var start: usize = 0;
        if (test_bypass) start = 1;
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
            owner.choose.as(gtk.Widget).setSensitive(1);
            const message: [:0]const u8 = if (self.denied)
                (if (owner.german) "Synchronisierung nicht autorisiert." else "Sync cancelled or not authorized.")
            else if (self.err) |err| switch (err) {
                error.InvalidImage, error.ImageUnavailable, error.TooLarge => if (owner.german) "Ein lesbares PNG/JPEG wählen (max. 16 MiB und 64 Megapixel)." else "Choose a readable PNG/JPEG (up to 16 MiB and 64 megapixels).",
                error.SystemThemeRequired => if (owner.german) "Das GTK-Design muss systemweit installiert sein." else "Install this GTK theme system-wide before syncing.",
                else => if (owner.german) "Synchronisierung fehlgeschlagen. Greeter-Installation und Authentifizierung prüfen." else "Could not sync. Check that Pearl Greeter is installed and authentication completed.",
            } else if (owner.german) "Synchronisiert. Wird beim nächsten Start des Anmeldebildschirms verwendet." else "Synced. The login screen will use this appearance next time it starts.";
            owner.status.setText(message);
            log.info("event=greeter-appearance-sync success={}", .{self.err == null and !self.denied});
        }
    }
};
