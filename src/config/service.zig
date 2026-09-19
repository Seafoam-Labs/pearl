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
const qt = @import("../theme/qt.zig");
const qt_integration = @import("qt_integration.zig");
const generator = @import("../theme/generator.zig");
const a = std.heap.c_allocator;
pub const Job = struct {
    service: *Service,
    arena: std.heap.ArenaAllocator,
    cancel: *gio.Cancellable,
    stage: enum { prepare, recover, persist, integrate } = .prepare,
    requested: ?[]const u8 = null,
    draft_revision: ?u64 = null,
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
    custom: @import("../theme/resolve.zig").Resolved = .{},
    asset_provider: @import("../theme/assets.zig").Provider = .{},
    dynamic_json: ?[]const u8 = null,
    application_snapshot: @import("../theme/theme_provider.zig").Snapshot = .{},
    application_result: @import("../theme/matugen_profiles.zig").Status = .{},
    application_error: ?anyerror = null,
    failure: ?anyerror = null,
    warning: ?anyerror = null,
    export_error: ?anyerror = null,
    qt_result: qt.Status = .{},
    qt_review_only: bool = false,
    qt_review: ?qt_integration.Review = null,
    qt_reviewed: ?[64]u8 = null,
    cache_hit: bool = false,
    recovered: bool = false,
    obsolete: bool = false,
    unchanged: bool = false,
    skip_unchanged: bool = false,
    fn destroy(self: *Job) void {
        if (self.qt_review) |review_| a.free(review_.text);
        if (self.image) |p| p.unref();
        if (self.texture) |p| p.unref();
        if (self.provider) |p| p.unref();
        if (self.native_provider) |p| p.unref();
        self.asset_provider.deinit();
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
    observer_context: ?*anyopaque = null,
    observer: ?*const fn (*anyopaque) void = null,
    completed_job: u64 = 0,
    completed_error: ?anyerror = null,
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
    qt_status: qt.Status = .{},
    application_status: @import("../theme/matugen_profiles.zig").Status = .{},
    application_job_serial: u64 = 0,
    integration_allowed: bool = false,
    shell_appearance: bool = false,
    qt_review_text: @import("../services/policy.zig").Text(16385) = .{},
    qt_review_digest: ?[64]u8 = null,
    jobs: u64 = 0,
    theme_jobs: @import("../theme/jobs.zig").Manager = .{},
    theme_discovery: @import("../theme/discovery.zig").Discovery = .{},
    draft: @import("draft.zig").Draft = .{},
    pub fn notify(self: *Service) void {
        self.changed(self.context);
        if (self.observer) |observer| observer(self.observer_context.?);
    }
    pub fn keepDraft(self: *Service, json: []const u8, expected: u64, revision: u64) !u64 {
        const current = try std.json.Stringify.valueAlloc(a, self.prefs(), .{});
        defer a.free(current);
        const serial = try self.draft.keep(a, json, expected, revision, self.revision, current);
        self.notify();
        return serial;
    }
    pub fn discardDraft(self: *Service, expected: u64) !void {
        try self.draft.discard(a, expected);
        self.notify();
    }
    pub fn mergeDraft(self: *Service, expected: u64) !void {
        if (self.job != null or self.pending_reload) return error.Busy;
        const current = try std.json.Stringify.valueAlloc(a, self.prefs(), .{});
        defer a.free(current);
        try self.draft.merge(a, expected, self.revision, current);
        self.notify();
    }
    pub fn applyDraft(self: *Service, expected: u64, revision: u64) !void {
        try self.draft.check(expected);
        if (self.draft.base_revision != revision) return error.Conflict;
        try self.apply(self.draft.text orelse return error.NoDraft, revision);
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
        self.theme_jobs.context = self;
        self.theme_jobs.finished = themeJobFinished;
        if (self.shell_appearance) try self.theme_discovery.start(self.app, self, themeCatalogChanged);
        self.reload();
    }
    pub fn stop(self: *Service) void {
        if (!self.running) return;
        self.running = false;
        self.theme_jobs.stop();
        if (self.theme_discovery.active) self.theme_discovery.stop();
        self.draft.deinit(a);
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
            if (self.job != j) j.destroy();
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
    fn themeCatalogChanged(context: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(context));
        if (self.running) self.notify();
    }
    fn themeJobFinished(context: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(context));
        if (!self.running) return;
        self.updateApplicationJob();
        if (self.theme_jobs.error_code == null) switch (self.theme_jobs.last_action) {
            .catalog, .install, .import_archive, .remove, .rollback => self.theme_discovery.request(),
            else => {},
        };
    }
    pub fn retryQt(self: *Service, revision: u64, review_only: bool, reviewed: ?[64]u8) !void {
        if (!self.running or !self.integration_allowed) return error.Unavailable;
        if (self.job != null or self.pending_reload) return error.Busy;
        if (self.cancelApplicationActionBusy()) return error.Busy;
        if (revision != self.revision) return error.Conflict;
        const j = self.live orelse return error.Unavailable;
        if (j.recovered) return error.Unavailable;
        j.cancel.unref();
        j.cancel = gio.Cancellable.new();
        j.qt_review_only = review_only;
        j.qt_reviewed = reviewed;
        j.qt_review = null;
        j.stage = .integrate;
        self.job = j;
        self.qt_status.busy = true;
        self.deadline = glib.timeoutAdd(15000, timedOut, self);
        self.dispatch(j);
        self.notify();
    }
    pub fn reload(self: *Service) void {
        self.queueReload(true);
    }
    fn queueReload(self: *Service, force: bool) void {
        if (!self.running) return;
        self.cancelApplicationAction();
        self.force_reload = self.force_reload or force;
        self.pending_reload = true;
        if (self.job) |j| if (j.requested == null and j.stage != .integrate) {
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
                self.notify();
            };
        }
        return 0;
    }
    pub fn apply(self: *Service, json: []const u8, revision: u64) !void {
        if (!self.running or self.job != null or self.pending_reload) return error.Busy;
        if (self.cancelApplicationActionBusy()) return error.Busy;
        if (revision != self.revision) return error.Conflict;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        _ = try model.parse(arena.allocator(), json);
        try self.launch(json);
    }
    fn cancelApplicationActionBusy(self: *Service) bool {
        if (self.theme_jobs.job) |job| if (job.request.action == .application_install or job.request.action == .application_retry or job.request.action == .application_review) {
            job.cancel.cancel();
            return true;
        };
        return false;
    }
    fn cancelApplicationAction(self: *Service) void {
        _ = self.cancelApplicationActionBusy();
    }
    pub fn updateApplicationJob(self: *Service) void {
        if (self.theme_jobs.job != null or self.theme_jobs.error_code != null or self.application_job_serial == self.theme_jobs.serial or self.theme_jobs.application_revision != self.revision) return;
        const bytes = self.theme_jobs.result orelse return;
        const job = self.live orelse return;
        const alloc = job.arena.allocator();
        if (self.theme_jobs.last_action == .application_retry) {
            const Result = struct { application_status: @import("../theme/matugen_profiles.zig").Status };
            const result = @import("../theme/package_model.zig").parse(Result, alloc, bytes, 120000) catch return;
            self.application_status = result.application_status;
            self.application_status.desired_revision = self.revision;
            var successful = true;
            for (self.application_status.targets) |target| switch (target.state) {
                .failed, .conflict, .unavailable, .unsupported => successful = false,
                else => {},
            };
            if (successful) self.application_status.applied_revision = self.revision;
        } else if (self.theme_jobs.last_action == .application_install) {
            self.application_status.targets[@intFromEnum(@import("../theme/matugen_profiles.zig").Application.starship)].state = .applied;
        } else return;
        self.application_job_serial = self.theme_jobs.serial;
        self.notify();
    }
    fn launch(self: *Service, requested: ?[]const u8) !void {
        const j = try a.create(Job);
        j.* = .{ .service = self, .arena = std.heap.ArenaAllocator.init(a), .cancel = gio.Cancellable.new(), .expected = self.observed, .skip_unchanged = !self.force_reload };
        errdefer j.destroy();
        if (requested) |json| {
            j.requested = try j.arena.allocator().dupe(u8, json);
            if (self.draft.text) |draft| {
                if (std.mem.eql(u8, draft, json)) j.draft_revision = self.draft.revision;
            }
        }
        self.job = j;
        self.jobs += 1;
        self.force_reload = false;
        self.deadline = glib.timeoutAdd(15000, timedOut, self);
        self.dispatch(j);
        self.notify();
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
                j.prefs.theme.package_id = "";
                j.prefs.theme.style_id = "";
                j.prefs.wallpaper.mode = .solid;
                prepareAppearance(j) catch |err| {
                    j.failure = err;
                };
            } else recover(j, j.warning.?) catch |err| {
                j.failure = err;
            };
        } else if (j.stage == .integrate) {
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            if (j.qt_review_only) {
                j.qt_review = qt_integration.review(scratch.allocator(), std.mem.span(glib.getUserConfigDir()), j.cancel) catch |err| {
                    j.qt_result.environment = .{ .state = .failed, .error_code = @errorName(err) };
                    task.returnBoolean(1);
                    return;
                };
                if (j.qt_review) |*review_| review_.text = a.dupe(u8, review_.text) catch {
                    j.qt_review = null;
                    j.qt_result.environment = .{ .state = .failed, .error_code = "OutOfMemory" };
                    task.returnBoolean(1);
                    return;
                };
            } else j.qt_result = qt_integration.reconcile(scratch.allocator(), std.mem.span(glib.getUserConfigDir()), j.prefs, j.palette, j.cancel, j.qt_reviewed) catch |err| .{
                .qt5 = .{ .state = .failed, .error_code = @errorName(err) },
                .qt6 = .{ .state = .failed, .error_code = @errorName(err) },
            };
            if (!j.qt_review_only) {
                const application_result = @import("../theme/application_profiles.zig").reconcile(scratch.allocator(), std.mem.span(glib.getUserConfigDir()), j.prefs.matugen.enabled, j.application_snapshot, j.cancel) catch |err| blk: {
                    var failed: @import("../theme/matugen_profiles.zig").Status = .{};
                    for (&failed.targets) |*target| target.* = .{ .state = .failed, .error_code = @errorName(err) };
                    break :blk failed;
                };
                // Rendering buffers belong to this worker iteration, not the
                // long-lived appearance arena (Qt retry can reuse this Job).
                const new_status = std.json.Stringify.valueAlloc(scratch.allocator(), application_result, .{}) catch null;
                const old_status = std.json.Stringify.valueAlloc(scratch.allocator(), j.application_result, .{}) catch null;
                if (new_status != null and (old_status == null or !std.mem.eql(u8, new_status.?, old_status.?))) {
                    j.application_result = @import("../theme/package_model.zig").parse(@import("../theme/matugen_profiles.zig").Status, j.arena.allocator(), new_status.?, 65536) catch .{ .targets = @splat(.{ .state = .failed, .error_code = "ApplicationStatusUnavailable" }) };
                }
                if (new_status == null) j.application_result = .{ .targets = @splat(.{ .state = .failed, .error_code = "ApplicationStatusUnavailable" }) };
                if (j.application_error) |err| for (&j.application_result.targets) |*target| {
                    target.* = .{ .state = .unavailable, .error_code = @errorName(err) };
                };
            }
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
            j.prefs.theme.package_id = "";
            j.prefs.theme.style_id = "";
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
        if (p.theme.mode != .gtk and (p.theme.mode == .package or p.theme.package_id.len > 0 or p.theme.style_id.len > 0)) {
            const custom = @import("../theme/resolve.zig");
            const snapshot = try std.fmt.allocPrintSentinel(alloc, "{s}/theme-snapshots/{s}.json", .{ j.service.dir, p.theme.snapshot_digest }, 0);
            // A restart reuses the committed appearance, even after package updates.
            const saved = if (j.requested == null and p.theme.snapshot_digest.len == 64) io.read(alloc, snapshot, 16384, j.cancel) catch null else null;
            if (saved != null and !saved.?.missing) {
                if (!std.mem.eql(u8, &io.digest(saved.?.bytes), p.theme.snapshot_digest)) return error.ThemeSnapshotCorrupt;
                j.custom = try modelParseCustom(alloc, saved.?.bytes);
                j.custom.blobs = try @import("../theme/asset_store.zig").load(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}/theme-assets", .{self.dir}, 0), j.custom.images);
            } else {
                if (j.requested == null and p.theme.snapshot_digest.len == 64) return error.ThemeSnapshotMissing;
                j.custom = try custom.resolve(alloc, p.theme, try @import("../theme/catalog.zig").scan(alloc), j.requested != null);
            }
            if (j.custom.palette) |value| j.palette = value;
        } else j.custom = .{};
        if (p.theme.mode == .dynamic) {
            const previous = self.live;
            const same_source = if (previous) |live| j.requested != null and live.prefs.theme.mode == .dynamic and
                p.theme.variant == live.prefs.theme.variant and p.theme.source == live.prefs.theme.source and
                std.mem.eql(u8, p.theme.seed, live.prefs.theme.seed) and std.mem.eql(u8, p.wallpaper.path, live.prefs.wallpaper.path) else false;
            // Wallpaper content may have changed in place: only seed palettes can
            // bypass the generator/cache adapter based on preference equality alone.
            if (same_source and p.theme.source == .seed) {
                inline for (@typeInfo(theme.Palette).@"struct".fields) |field|
                    @field(j.palette, field.name) = try alloc.dupe(u8, @field(previous.?.palette, field.name));
                j.cache_hit = true;
                if (previous.?.dynamic_json) |json| j.dynamic_json = try alloc.dupe(u8, json);
            } else {
                const generated = try generator.full(alloc, p, image_bytes, self.cache_dir, j.cancel, &j.cache_hit);
                j.palette = generated.palette;
                j.dynamic_json = generated.json;
            }
        }
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
        const token_template = try @import("../theme/style.zig").tokenCss(alloc, j.custom.tokens, p.reduced_motion);
        const tokens = try theme.scopedCss(alloc, token_template, "pearl-custom", j.palette);
        // Authentication surfaces keep built-in layout and receive colors only.
        const extra = if (self.shell_appearance) try theme.scopedCss(alloc, j.custom.css, "pearl-custom", j.palette) else "";
        j.css = try std.fmt.allocPrintSentinel(alloc, "{s}\n{s}\n{s}\n{s}{s}", .{ bytes, if (self.shell_appearance) tokens else "", extra, font, wallpaper }, 0);
        if (j.custom.digest.len > 0) {
            const snapshot_bytes = try std.json.Stringify.valueAlloc(alloc, j.custom, .{});
            j.prefs.theme.snapshot_digest = try alloc.dupe(u8, &io.digest(snapshot_bytes));
        } else j.prefs.theme.snapshot_digest = "";
        if (self.shell_appearance and p.matugen.enabled) {
            j.application_snapshot = if (j.requested == null and p.matugen.snapshot_digest.len > 0)
                @import("../theme/application_profiles.zig").load(alloc, self.dir, p.matugen.snapshot_digest) catch |err| blk: {
                    j.application_error = err;
                    break :blk .{};
                }
            else
                @import("../theme/theme_provider.zig").capture(alloc, p, j.dynamic_json, j.cancel, try std.fmt.allocPrintSentinel(alloc, "{s}/applications", .{self.cache_dir}, 0)) catch |err| blk: {
                    j.application_error = err;
                    break :blk .{};
                };
            if (j.application_error) |err| j.application_snapshot.error_code = @errorName(err);
            j.prefs.matugen.snapshot_digest = try alloc.dupe(u8, &io.digest(try std.json.Stringify.valueAlloc(alloc, j.application_snapshot, .{})));
        } else if (!p.matugen.enabled) j.prefs.matugen.snapshot_digest = "";
        j.json = try std.json.Stringify.valueAlloc(alloc, j.prefs, .{ .whitespace = .indent_2 });
        if (j.cancel.isCancelled() != 0) return error.Cancelled;
    }
    fn persist(j: *Job) !void {
        const self = j.service;
        if (!j.recovered and self.shell_appearance and j.prefs.matugen.enabled) {
            _ = try @import("../theme/application_profiles.zig").save(j.arena.allocator(), self.dir, j.application_snapshot);
        }
        if (!j.recovered and j.custom.digest.len > 0) {
            const alloc = j.arena.allocator();
            const directory = try std.fmt.allocPrintSentinel(alloc, "{s}/theme-snapshots", .{self.dir}, 0);
            try io.mkdir(directory);
            try @import("../theme/asset_store.zig").save(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}/theme-assets", .{self.dir}, 0), j.custom.blobs);
            try @import("../theme/snapshots.zig").write(alloc, directory, j.prefs.theme.snapshot_digest, try std.json.Stringify.valueAlloc(alloc, j.custom, .{}));
        }
        if (j.requested != null) try io.replace(self.path, j.json, j.disk.?, j.cancel);
        if (j.requested == null and j.cancel.isCancelled() != 0) return error.Cancelled;
        if (!j.recovered) io.atomic(self.good_path, j.json, false) catch |err| {
            j.warning = err;
        };
        if (j.recovered) return;
        if (j.warning == null) {
            const alloc = j.arena.allocator();
            const directory = try std.fmt.allocPrintSentinel(alloc, "{s}/theme-snapshots", .{self.dir}, 0);
            @import("../theme/snapshots.zig").prune(alloc, directory, j.prefs.theme.snapshot_digest, if (self.live) |old| old.prefs.theme.snapshot_digest else "") catch {};
            @import("../theme/asset_store.zig").prune(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}/theme-assets", .{self.dir}, 0), directory) catch {};
            if (self.shell_appearance) @import("../theme/application_profiles.zig").prune(alloc, self.dir, j.prefs.matugen.snapshot_digest, if (self.live) |old| old.prefs.matugen.snapshot_digest else "") catch {};
        }
        // Export failure is independent: it must never undo a successful shell save.
        exports(j) catch |err| {
            j.export_error = err;
        };
    }
    fn completed(_: ?*object.Object, _: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(data.?));
        const self = j.service;
        defer self.app.release();
        if (j.stage == .integrate) {
            self.job = null;
            if (self.deadline != 0) _ = glib.Source.remove(self.deadline);
            self.deadline = 0;
            if (!self.running) {
                j.destroy();
                self.freePaths();
                return;
            }
            if (j.qt_review_only) {
                self.qt_status.busy = false;
                self.qt_review_digest = null;
                if (j.qt_review) |review_| {
                    self.qt_review_digest = review_.digest;
                    self.qt_review_text.set(review_.text);
                    a.free(review_.text);
                    j.qt_review = null;
                } else self.qt_review_text.set(j.qt_result.environment.error_code orelse "Qt review failed");
                self.notify();
                if (self.pending_reload and self.debounce == 0) self.debounce = glib.timeoutAdd(180, debounced, self);
                return;
            }
            self.application_status = j.application_result;
            self.application_status.desired_revision = self.revision;
            var application_success = true;
            for (self.application_status.targets) |target| if (target.state == .failed or target.state == .conflict or target.state == .unavailable or target.state == .unsupported) {
                application_success = false;
            };
            if (application_success) self.application_status.applied_revision = self.revision;
            self.qt_review_digest = null;
            self.qt_review_text.set("");
            const previously_applied = self.qt_status.applied_revision;
            self.qt_status = j.qt_result;
            self.qt_status.applied_revision = previously_applied;
            self.qt_status.desired_revision = self.revision;
            const states = [_]qt.Target{ j.qt_result.qt5, j.qt_result.qt6, j.qt_result.engine, j.qt_result.darkly, j.qt_result.kde, j.qt_result.environment };
            var success = true;
            for (states) |target| if (target.state != .applied and target.state != .disabled) {
                success = false;
            };
            if (success) self.qt_status.applied_revision = self.revision;
            self.notify();
            if (self.pending_reload and self.debounce == 0) self.debounce = glib.timeoutAdd(180, debounced, self);
            return;
        }
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
        if (j.requested != null) {
            self.completed_job = self.jobs;
            self.completed_error = j.failure;
        }
        if (!j.obsolete and !j.unchanged) {
            if (j.disk) |disk| if (!std.mem.eql(u8, &self.observed, &disk.hash)) {
                self.observed = disk.hash;
                self.revision += 1;
            };
            self.err = j.failure orelse j.warning;
            if (j.failure == null) {
                if (j.draft_revision) |expected| {
                    // Completion can clear only the exact draft captured by Apply.
                    self.draft.discard(a, expected) catch {};
                }
                self.removeLive();
                self.application_status = .{ .desired_revision = self.revision };
                self.live = j;
                self.appearance += 1;
                if (j.requested != null) {
                    self.observed = io.digest(j.json);
                    self.revision += 1;
                }
                gtk.StyleContext.addProviderForDisplay(self.display, j.provider.?.as(gtk.StyleProvider), 601);
                if (j.native_provider) |p| gtk.StyleContext.addProviderForDisplay(self.display, p.as(gtk.StyleProvider), 599);
                self.export_error = j.export_error;
                if (!j.recovered and self.integration_allowed) {
                    j.stage = .integrate;
                    self.job = j;
                    self.qt_status.busy = true;
                    self.qt_status.desired_revision = self.revision;
                    self.deadline = glib.timeoutAdd(15000, timedOut, self);
                    self.dispatch(j);
                }
                std.log.info("event=preferences-applied revision={d} mode={s} cache={}", .{ self.revision, @tagName(j.prefs.theme.mode), j.cache_hit });
            } else {
                std.log.info("event=preferences-error detail={s}", .{@errorName(j.failure.?)});
                j.destroy();
            }
        } else j.destroy();
        self.notify();
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
        return std.json.Stringify.valueAlloc(alloc, .{ .revision = self.revision, .appearance = self.appearance, .busy = self.job != null or self.pending_reload, .jobs = self.jobs, .err = if (self.err) |e| @errorName(e) else null, .qt = self.qt_status, .export_error = if (self.export_error) |e| @errorName(e) else null, .cache_hit = if (self.live) |j| j.cache_hit else false, .recovered = if (self.live) |j| j.recovered else false, .draft_dirty = self.draft.text != null, .draft_revision = if (self.draft.text != null) @as(?u64, self.draft.base_revision) else null, .draft_serial = self.draft.revision, .path = self.path, .preferences_truncated = encoded.len > 5500, .preferences = if (encoded.len <= 5500) @as(?model.Preferences, self.prefs()) else null }, .{});
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
    j.asset_provider.deinit();
    if (j.service.shell_appearance) j.asset_provider = try @import("../theme/assets.zig").Provider.init(j.custom.blobs);
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

fn modelParseCustom(alloc: std.mem.Allocator, bytes: []const u8) !@import("../theme/resolve.zig").Resolved {
    const result = try @import("../theme/package_model.zig").parse(@import("../theme/resolve.zig").Resolved, alloc, bytes, 16384);
    if (result.palette_api != 1 or (result.style_api != 1 and result.style_api != 2)) return error.UnsupportedThemeSnapshot;
    try @import("../theme/assets.zig").bounds(result.images);
    if (result.palette) |p| try theme.validate(p);
    try result.tokens.validate();
    if (result.css.len > 3072) return error.ThemeCssTooLarge;
    return result;
}
