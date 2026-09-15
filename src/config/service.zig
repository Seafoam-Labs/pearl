//! One coalesced worker prepares immutable settings/appearance, then commits them.
//! GTK providers are validated on the main thread before saving or swapping.
const std = @import("std");
const gtk = @import("gtk4");
const gdk = @import("gdk4");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const pixbuf = @import("gdkpixbuf2");
const model = @import("preferences.zig");
const io = @import("io.zig");
const theme = @import("../theme/theme.zig");
const generator = @import("../theme/generator.zig");
const a = std.heap.c_allocator;
pub const Job = struct {
    service: *Service,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    stage: enum { prepare, recover, persist } = .prepare,
    requested: ?[]const u8 = null,
    expected: [64]u8,
    disk: ?io.Read = null,
    prefs: model.Preferences = .{},
    json: []const u8 = "{}",
    css: [:0]const u8 = "",
    image: ?*pixbuf.Pixbuf = null,
    texture: ?*gdk.Texture = null,
    provider: ?*gtk.CssProvider = null,
    native_provider: ?*gtk.CssProvider = null,
    native_name: [:0]const u8 = "",
    palette: theme.Palette = theme.dark,
    failure: ?anyerror = null,
    warning: ?anyerror = null,
    export_error: ?anyerror = null,
    cache_hit: bool = false,
    recovered: bool = false,
    obsolete: bool = false,
    unchanged: bool = false,
    skip_unchanged: bool = false,
    fn destroy(self: *Job) void {
        if (self.image) |p| p.unref();
        if (self.texture) |p| p.unref();
        if (self.provider) |p| p.unref();
        if (self.native_provider) |p| p.unref();
        self.cancel.unref();
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Service = struct {
    app: *gio.Application,
    display: *gdk.Display,
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    validate: ?*const fn (*anyopaque, model.Preferences) anyerror!void = null,
    dir: [:0]u8 = undefined,
    cache_dir: [:0]u8 = undefined,
    path: [:0]u8 = undefined,
    good_path: [:0]u8 = undefined,
    monitor: ?*gio.FileMonitor = null,
    live: ?*Job = null,
    job: ?*Job = null,
    running: bool = false,
    pending_reload: bool = false,
    force_reload: bool = false,
    debounce: c_uint = 0,
    deadline: c_uint = 0,
    revision: u64 = 0,
    appearance: u64 = 0,
    observed: [64]u8 = io.digest("missing"),
    err: ?anyerror = null,
    export_error: ?anyerror = null,
    jobs: u64 = 0,
    draft: ?[]u8 = null,
    draft_base: ?[]u8 = null,
    draft_revision: u64 = 0,
    pub fn keepDraft(self: *Service, json: []const u8, revision: u64) void {
        const copy = a.dupe(u8, json) catch return;
        if (self.draft_base == null) self.draft_base = std.json.Stringify.valueAlloc(a, self.prefs(), .{}) catch null;
        if (self.draft) |old| a.free(old);
        self.draft = copy;
        self.draft_revision = revision;
    }
    pub fn discardDraft(self: *Service) void {
        if (self.draft) |old| a.free(old);
        self.draft = null;
        if (self.draft_base) |old| a.free(old);
        self.draft_base = null;
    }
    pub fn mergeDraft(self: *Service) !void {
        if (self.job != null or self.pending_reload) return error.Busy;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const current = try std.json.Stringify.valueAlloc(alloc, self.prefs(), .{});
        const merged = try @import("merge.zig").json(alloc, self.draft_base orelse return error.NoDraft, self.draft orelse return error.NoDraft, current);
        const next = try a.dupe(u8, merged);
        errdefer a.free(next);
        const base = try a.dupe(u8, current);
        self.discardDraft();
        self.draft = next;
        self.draft_base = base;
        self.draft_revision = self.revision;
    }

    pub fn prefs(self: *const Service) model.Preferences {
        return if (self.live) |v| v.prefs else .{};
    }
    pub fn start(self: *Service) !void {
        self.dir = try std.fmt.allocPrintSentinel(a, "{s}/pearl", .{std.mem.span(glib.getUserConfigDir())}, 0);
        errdefer a.free(self.dir);
        self.cache_dir = try std.fmt.allocPrintSentinel(a, "{s}/pearl/themes", .{std.mem.span(glib.getUserCacheDir())}, 0);
        errdefer a.free(self.cache_dir);
        self.path = try std.fmt.allocPrintSentinel(a, "{s}/preferences.json", .{self.dir}, 0);
        errdefer a.free(self.path);
        self.good_path = try std.fmt.allocPrintSentinel(a, "{s}/last-good.json", .{self.dir}, 0);
        errdefer a.free(self.good_path);
        try io.mkdir(self.dir);
        try io.mkdir(self.cache_dir);
        const file = gio.File.newForPath(self.dir);
        defer file.unref();
        self.monitor = file.monitorDirectory(.{ .watch_moves = true }, null, null) orelse return error.MonitorUnavailable;
        if (self.monitor) |m| _ = gio.FileMonitor.signals.changed.connect(m, *Service, fileChanged, self, .{});
        self.running = true;
        self.reload();
    }
    pub fn stop(self: *Service) void {
        if (!self.running) return;
        self.running = false;
        self.discardDraft();
        if (self.monitor) |m| {
            _ = m.cancel();
            m.unref();
            self.monitor = null;
        }
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        self.debounce = 0;
        if (self.job) |j| {
            j.obsolete = true;
            j.cancel.cancel();
        }
        if (self.live) |j| {
            self.removeProviders(j);
            j.destroy();
            self.live = null;
        }
        // Active workers keep paths alive until their application hold drains.
        if (self.job == null) self.freePaths();
    }
    fn freePaths(self: *Service) void {
        a.free(self.dir);
        a.free(self.path);
        a.free(self.good_path);
        a.free(self.cache_dir);
    }
    pub fn reload(self: *Service) void {
        self.queueReload(true);
    }
    fn queueReload(self: *Service, force: bool) void {
        if (!self.running) return;
        self.force_reload = self.force_reload or force;
        self.pending_reload = true;
        if (self.job) |j| if (j.requested == null) {
            j.obsolete = true;
            j.cancel.cancel();
        };
        if (self.debounce != 0) _ = glib.Source.remove(self.debounce);
        self.debounce = glib.timeoutAdd(180, debounced, self);
    }
    fn debounced(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.debounce = 0;
        if (self.job == null and self.pending_reload) {
            self.pending_reload = false;
            self.launch(null) catch |err| {
                self.err = err;
                self.changed(self.context);
            };
        }
        return 0;
    }
    pub fn apply(self: *Service, json: []const u8, revision: u64) !void {
        if (!self.running or self.job != null or self.pending_reload) return error.Busy;
        if (revision != self.revision) return error.Conflict;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        _ = try model.parse(arena.allocator(), json);
        try self.launch(json);
    }
    fn launch(self: *Service, requested: ?[]const u8) !void {
        const j = try a.create(Job);
        j.* = .{ .service = self, .arena = std.heap.ArenaAllocator.init(a), .cancel = gio.Cancellable.new(), .expected = self.observed, .skip_unchanged = !self.force_reload };
        errdefer j.destroy();
        if (requested) |json| j.requested = try j.arena.allocator().dupe(u8, json);
        self.job = j;
        self.jobs += 1;
        self.force_reload = false;
        self.deadline = glib.timeoutAdd(15000, timedOut, self);
        self.dispatch(j);
        self.changed(self.context);
    }
    fn dispatch(self: *Service, j: *Job) void {
        self.app.hold();
        const task = gio.Task.new(null, j.cancel, completed, j);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(j, null);
        task.runInThread(work);
        task.unref();
    }
    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        self.deadline = 0;
        if (self.job) |j| j.cancel.cancel();
        return 0;
    }
    fn fileChanged(_: *gio.FileMonitor, file: *gio.File, other: ?*gio.File, _: gio.FileMonitorEvent, self: *Service) callconv(.c) void {
        const name = file.getBasename();
        defer if (name) |v| glib.free(v);
        const next = if (other) |o| o.getBasename() else null;
        defer if (next) |v| glib.free(v);
        if ((if (name) |v| std.mem.eql(u8, std.mem.span(v), "preferences.json") else false) or (if (next) |v| std.mem.eql(u8, std.mem.span(v), "preferences.json") else false)) self.queueReload(false);
    }
    fn work(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, _: ?*gio.Cancellable) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        if (j.stage == .prepare) prepare(j) catch |err| {
            if (j.service.appearance == 0 and j.requested == null and j.cancel.isCancelled() == 0) {
                recover(j, err) catch |failure| {
                    j.failure = failure;
                };
            } else j.failure = err;
        } else if (j.stage == .recover) {
            if (j.recovered) {
                if (j.image) |image| {
                    image.unref();
                    j.image = null;
                }
                j.native_name = "";
                j.prefs.theme.mode = .static;
                j.prefs.wallpaper.mode = .solid;
                prepareAppearance(j) catch |err| {
                    j.failure = err;
                };
            } else recover(j, j.warning.?) catch |err| {
                j.failure = err;
            };
        } else persist(j) catch |err| {
            j.failure = err;
        };
        task.returnBoolean(1);
    }
    fn recover(j: *Job, failure: anyerror) !void {
        const alloc = j.arena.allocator();
        if (j.image) |image| {
            image.unref();
            j.image = null;
        }
        j.native_name = "";
        const good = io.read(alloc, j.service.good_path, model.max_bytes, j.cancel) catch null;
        j.prefs = if (good) |file| model.parse(alloc, if (file.missing) "{}" else file.bytes) catch .{} else .{};
        j.recovered = true;
        j.warning = failure;
        prepareAppearance(j) catch {
            if (j.image) |image| {
                image.unref();
                j.image = null;
            }
            j.native_name = "";
            // A last-good file may refer to a removed font/theme/image too.
            // Keep it on disk; show a static fallback with an explicit error.
            j.prefs.theme.mode = .static;
            j.prefs.wallpaper.mode = .solid;
            try prepareAppearance(j);
        };
    }
    fn prepare(j: *Job) !void {
        const alloc = j.arena.allocator();
        const self = j.service;
        j.disk = io.read(alloc, self.path, model.max_bytes, j.cancel) catch |err| blk: {
            if (j.requested != null) return err;
            j.warning = err;
            break :blk null;
        };
        if (j.requested == null and self.appearance != 0 and j.skip_unchanged) if (j.disk) |disk| if (std.mem.eql(u8, &disk.hash, &j.expected)) {
            j.unchanged = true;
            return;
        };
        if (j.requested != null) {
            if (j.disk == null or !std.mem.eql(u8, &j.disk.?.hash, &j.expected)) return error.Conflict;
            j.prefs = try model.parse(alloc, j.requested.?);
        } else {
            j.prefs = (if (j.disk) |disk| model.parse(alloc, if (disk.missing) "{}" else disk.bytes) else error.InvalidFile) catch |err| blk: {
                j.warning = err;
                if (self.appearance != 0) return err;
                const good = try io.read(alloc, self.good_path, model.max_bytes, j.cancel);
                j.recovered = true;
                break :blk try model.parse(alloc, if (good.missing) "{}" else good.bytes);
            };
        }
        try prepareAppearance(j);
    }
    fn prepareAppearance(j: *Job) !void {
        const alloc = j.arena.allocator();
        const self = j.service;
        j.json = try std.json.Stringify.valueAlloc(alloc, j.prefs, .{ .whitespace = .indent_2 });
        var image_bytes: ?[]const u8 = null;
        const p = j.prefs;
        if (p.wallpaper.mode == .cover or p.wallpaper.mode == .contain or (p.theme.mode == .dynamic and p.theme.source == .wallpaper)) {
            const path = try alloc.dupeZ(u8, p.wallpaper.path);
            const image = try io.read(alloc, path, null, j.cancel);
            if (image.missing or (!std.mem.startsWith(u8, image.bytes, "\x89PNG\r\n\x1a\n") and !std.mem.startsWith(u8, image.bytes, "\xff\xd8\xff"))) return error.InvalidImage;
            image_bytes = image.bytes;
            const bytes = glib.Bytes.new(image.bytes.ptr, image.bytes.len);
            defer bytes.unref();
            const stream = gio.MemoryInputStream.newFromBytes(bytes);
            defer stream.unref();
            j.image = pixbuf.Pixbuf.newFromStream(stream.as(gio.InputStream), j.cancel, null) orelse return error.ImageDecodeFailed;
        }
        j.palette = if (p.theme.variant == .dark) theme.dark else theme.light;
        if (p.theme.mode == .dynamic) j.palette = try generator.palette(alloc, p, image_bytes, self.cache_dir, j.cancel, &j.cache_hit);
        if (p.theme.mode == .gtk and p.theme.gtk_name.len > 0) {
            j.native_name = try alloc.dupeZ(u8, p.theme.gtk_name);
            try installedTheme(alloc, j.native_name);
        }
        const bytes = blk: {
            const resource = gio.resourcesLookupData(if (p.theme.mode == .gtk) "/org/aqueous/Pearl/gtk-theme.css" else "/org/aqueous/Pearl/style.css", .{}, null) orelse return error.MissingResource;
            defer resource.unref();
            var n: usize = 0;
            const raw = resource.getData(&n).?;
            if (p.theme.mode == .gtk) break :blk try alloc.dupeZ(u8, @as([*]const u8, @ptrCast(raw))[0..n]);
            break :blk try theme.scopedCss(alloc, @as([*]const u8, @ptrCast(raw))[0..n], "pearl-custom", j.palette);
        };
        const font = if (p.font.len > 0) try std.fmt.allocPrint(alloc, ".pearl-root.pearl-shell {{ font-family: \"{s}\", sans-serif; font-size: {d}px; }}\n", .{ p.font, p.font_size }) else if (p.theme.mode != .gtk or p.font_size != 14) try std.fmt.allocPrint(alloc, ".pearl-root.pearl-shell {{ font-size: {d}px; }}\n", .{p.font_size}) else "";
        const wallpaper = if (p.wallpaper.mode == .gradient) "" else try std.fmt.allocPrint(alloc, ".pearl-root.pearl-shell.pearl-wallpaper {{ background: {s}; }}\n", .{p.wallpaper.color});
        j.css = try std.fmt.allocPrintSentinel(alloc, "{s}\n{s}{s}", .{ bytes, font, wallpaper }, 0);
        if (j.cancel.isCancelled() != 0) return error.Cancelled;
    }
    fn persist(j: *Job) !void {
        const self = j.service;
        if (j.requested != null) try io.replace(self.path, j.json, j.disk.?, j.cancel);
        if (j.requested == null and j.cancel.isCancelled() != 0) return error.Cancelled;
        if (!j.recovered) io.atomic(self.good_path, j.json, false) catch |err| {
            j.warning = err;
        };
        if (j.recovered) return;
        // Export failure is independent: it must never undo a successful shell save.
        exports(j) catch |err| {
            j.export_error = err;
        };
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        const self = j.service;
        defer self.app.release();
        if (self.running and !j.obsolete and j.failure == null and !j.unchanged and j.stage != .persist) {
            validateProviders(j) catch |err| {
                j.failure = err;
            };
            if (j.failure != null and self.appearance == 0 and j.requested == null and j.cancel.isCancelled() == 0 and (!j.recovered or j.prefs.theme.mode == .gtk)) {
                // CSS is parsed on the GTK thread. Give this failure the same
                // last-good recovery path as worker-side validation failures.
                if (j.provider) |provider| {
                    provider.unref();
                    j.provider = null;
                }
                if (j.native_provider) |provider| {
                    provider.unref();
                    j.native_provider = null;
                }
                if (j.texture) |texture| {
                    texture.unref();
                    j.texture = null;
                }
                j.warning = j.failure;
                j.failure = null;
                j.stage = .recover;
                self.dispatch(j);
                return;
            }
            if (j.failure == null) {
                j.stage = .persist;
                self.dispatch(j);
                return;
            }
        }
        self.job = null;
        if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
        self.deadline = 0;
        if (!self.running) {
            j.destroy();
            self.freePaths();
            return;
        }
        if (!j.obsolete and !j.unchanged) {
            if (j.disk) |disk| if (!std.mem.eql(u8, &self.observed, &disk.hash)) {
                self.observed = disk.hash;
                self.revision += 1;
            };
            self.err = j.failure orelse j.warning;
            if (j.failure == null) {
                if (j.requested) |requested| if (self.draft) |draft| if (std.mem.eql(u8, requested, draft)) self.discardDraft();
                self.removeLive();
                self.live = j;
                self.appearance += 1;
                if (j.requested != null) {
                    self.observed = io.digest(j.json);
                    self.revision += 1;
                }
                gtk.StyleContext.addProviderForDisplay(self.display, j.provider.?.as(gtk.StyleProvider), 601);
                if (j.native_provider) |p| gtk.StyleContext.addProviderForDisplay(self.display, p.as(gtk.StyleProvider), 599);
                self.export_error = j.export_error;
                std.log.info("event=preferences-applied revision={d} mode={s} cache={}", .{ self.revision, @tagName(j.prefs.theme.mode), j.cache_hit });
            } else {
                std.log.info("event=preferences-error detail={s}", .{@errorName(j.failure.?)});
                j.destroy();
            }
        } else j.destroy();
        self.changed(self.context);
        if (self.pending_reload and self.debounce == 0) self.debounce = glib.timeoutAdd(180, debounced, self);
    }
    fn removeProviders(self: *Service, j: *Job) void {
        if (j.provider) |p| gtk.StyleContext.removeProviderForDisplay(self.display, p.as(gtk.StyleProvider));
        if (j.native_provider) |p| gtk.StyleContext.removeProviderForDisplay(self.display, p.as(gtk.StyleProvider));
    }
    fn removeLive(self: *Service) void {
        if (self.live) |j| {
            self.removeProviders(j);
            j.destroy();
            self.live = null;
        }
    }
    pub fn status(self: *Service, alloc: std.mem.Allocator) ![]const u8 {
        const encoded = try std.json.Stringify.valueAlloc(alloc, self.prefs(), .{});
        return std.json.Stringify.valueAlloc(alloc, .{ .revision = self.revision, .appearance = self.appearance, .busy = self.job != null or self.pending_reload, .jobs = self.jobs, .err = if (self.err) |e| @errorName(e) else null, .export_error = if (self.export_error) |e| @errorName(e) else null, .cache_hit = if (self.live) |j| j.cache_hit else false, .recovered = if (self.live) |j| j.recovered else false, .draft_dirty = self.draft != null, .draft_revision = if (self.draft != null) @as(?u64, self.draft_revision) else null, .path = self.path, .preferences_truncated = encoded.len > 5500, .preferences = if (encoded.len <= 5500) @as(?model.Preferences, self.prefs()) else null }, .{});
    }
    pub fn style(self: *Service, widget: *gtk.Widget, panel: *gtk.Widget) void {
        const p = self.prefs();
        for ([_][*:0]const u8{ "pearl-dark", "pearl-light", "pearl-custom", "pearl-gtk", "pearl-compact", "pearl-reduced-motion" }) |class| widget.removeCssClass(class);
        widget.addCssClass(if (self.live == null) "pearl-dark" else if (p.theme.mode == .gtk) "pearl-gtk" else "pearl-custom");
        if (p.density == .compact) widget.addCssClass("pearl-compact");
        if (p.reduced_motion) widget.addCssClass("pearl-reduced-motion");
        if (p.theme.mode == .gtk) panel.addCssClass("background") else panel.removeCssClass("background");
    }
};
fn cssError(_: *gtk.CssProvider, _: *gtk.CssSection, err: *glib.Error, failed: *bool) callconv(.c) void {
    // Deprecated CSS warnings in otherwise usable third party themes aren't errors.
    if (err.f_domain == gtk.cssParserErrorQuark()) failed.* = true;
}
fn validateProviders(j: *Job) !void {
    if (j.service.validate) |validate| try validate(j.service.context, j.prefs);
    if (j.image) |image| j.texture = gdk.Texture.newForPixbuf(image);
    var failed = false;
    j.provider = gtk.CssProvider.new();
    const id = gtk.CssProvider.signals.parsing_error.connect(j.provider.?, *bool, cssError, &failed, .{});
    j.provider.?.loadFromString(j.css);
    object.signalHandlerDisconnect(j.provider.?.as(object.Object), id);
    if (failed) return error.InvalidCss;
    if (j.native_name.len > 0) {
        j.native_provider = gtk.CssProvider.new();
        const signal = gtk.CssProvider.signals.parsing_error.connect(j.native_provider.?, *bool, cssError, &failed, .{});
        j.native_provider.?.loadNamed(j.native_name, if (j.prefs.theme.variant == .dark) "dark" else null);
        object.signalHandlerDisconnect(j.native_provider.?.as(object.Object), signal);
        if (failed) return error.InvalidGtkTheme;
    }
}
fn installedTheme(alloc: std.mem.Allocator, name: [:0]const u8) !void {
    if (std.mem.eql(u8, name, "Adwaita") or std.mem.eql(u8, name, "HighContrast")) return;
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/themes", .{std.mem.span(glib.getUserDataDir())}));
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.themes", .{std.mem.span(glib.getHomeDir())}));
    const dirs: [*:null]const ?[*:0]const u8 = @ptrCast(glib.getSystemDataDirs());
    var i: usize = 0;
    while (dirs[i]) |dir| : (i += 1) try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/themes", .{std.mem.span(dir)}));
    for (roots.items) |root| {
        var minor: u32 = gtk.getMinorVersion();
        while (true) {
            const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}/gtk-4.{d}/gtk.css", .{ root, name, minor }, 0);
            if (glib.fileTest(path, .{ .is_regular = true }) != 0) return;
            if (minor == 0) break;
            minor -= 1;
        }
    }
    return error.GtkThemeNotInstalled;
}
fn exports(j: *Job) !void {
    if (j.prefs.exports.len == 0) return;
    if (j.prefs.theme.mode == .gtk) return error.GtkThemeHasNoMaterialPalette;
    const alloc = j.arena.allocator();
    const dir = try std.fmt.allocPrintSentinel(alloc, "{s}/exports", .{j.service.dir}, 0);
    try io.mkdir(dir);
    for (j.prefs.exports) |e| {
        if (j.cancel.isCancelled() != 0) return error.Cancelled;
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, e.name }, 0);
        const marker = try std.fmt.allocPrintSentinel(alloc, "{s}/.{s}.pearl-owner", .{ dir, e.name }, 0);
        const old = try io.read(alloc, path, 65536, j.cancel);
        const owner = try io.read(alloc, marker, 64, j.cancel);
        // A digest sidecar grants ownership of precisely the last exported bytes.
        if (!old.missing and (owner.missing or !std.mem.eql(u8, owner.bytes, &old.hash))) return error.ExportOwnershipConflict;
        var text = e.template;
        inline for (@typeInfo(theme.Palette).@"struct".fields) |field| text = try std.mem.replaceOwned(u8, alloc, text, "{{" ++ field.name ++ "}}", @field(j.palette, field.name));
        if (std.mem.indexOf(u8, text, "{{") != null) return error.UnknownExportToken;
        if (std.mem.eql(u8, text, old.bytes) and !old.missing) continue;
        if (!old.missing) {
            const backup = try std.fmt.allocPrintSentinel(alloc, "{s}.bak", .{path}, 0);
            // Never replace an existing backup that might belong to the user.
            io.atomic(backup, old.bytes, true) catch |err| {
                if (err != error.Conflict) return err;
            };
        }
        try io.replace(path, text, old, j.cancel);
        try io.atomic(marker, &io.digest(text), false);
    }
}
