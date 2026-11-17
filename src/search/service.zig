//! Shell-owned semantic search service. Owns the embedding runtime, the index
//! store, directory watches and one cancellable indexing worker. Launcher
//! queries and indexing run on worker threads; the main thread only
//! configures, starts and reaps. All embedding and ranking is local — no query
//! or passage leaves the device.
//!
//! Automatic indexing is scheduled by search/schedule.zig into idle/low-use
//! windows and runs in bounded bursts; explicit Index now bypasses the gate.
//! Folder removals apply immediately as metadata-only commits.
//!
//! Locking: runtime_lock serializes ensure/embed/stop; the main thread only
//! ever tryLocks it (idle unload). store_lock guards the store pointer; stores
//! are only referenced inside that lock, so retirement can free immediately.
const std = @import("std");
const gio = @import("gio2");
const glib = @import("glib2");
const object = @import("gobject2");
const config = @import("../agent/config.zig");
const registry = @import("../agent/model_registry.zig");
const downloads = @import("../agent/downloads.zig");
const memory = @import("../agent/memory.zig");
const Runtime = @import("../agent/runtime.zig").Runtime;
const embed = @import("../agent/embed.zig");
const store_mod = @import("store.zig");
const indexer = @import("indexer.zig");
const extract = @import("extract.zig");
const schedule = @import("schedule.zig");
const watch = @import("watch.zig");
const a = std.heap.c_allocator;
pub const floor: f32 = 0.30;
pub const max_documents = 4;
pub const idle_seconds: i64 = 120;
pub const min_query = 3;
pub const max_dirty = 4096;
pub const Document = struct { path: [:0]const u8, name: [:0]const u8, detail: [:0]const u8, score: i32 };
pub const State = enum { disabled, setup, ready, indexing, paused, failed };
pub const HostSignals = struct {
    inhibited: bool = false,
    on_battery: bool = false,
    battery_present: bool = false,
    battery_charging: bool = false,
    battery_percent: u8 = 0,
    power_saver: bool = false,
    sleep_pending: bool = false,
    idle_available: bool = false,
};
pub const Status = struct {
    state: State,
    files: u64 = 0,
    chunks: u64 = 0,
    updated_ns: i64 = 0,
    folders: usize = 0,
    model_installed: bool = false,
    pdf_available: bool = false,
    error_code: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    indexed: u64 = 0,
    skipped: u64 = 0,
    pending: []const u8 = "none",
    dirty: u64 = 0,
    window: []const u8 = "waiting",
    defer_reason: []const u8 = "",
    degraded: bool = false,
    background: []const u8 = "idle_low_use",
    automatic: bool = false,
};
const IndexJob = struct {
    arena: std.heap.ArenaAllocator = .init(a),
    service: *Service,
    scope: indexer.Scope,
    deadline_us: i64,
    automatic: bool,
    rebuild: bool,
    dirty: []const []const u8 = &.{},
    failure: ?anyerror = null,
    more: bool = false,
};
pub const Service = struct {
    cfg: config.Config = .{},
    cfg_arena: std.heap.ArenaAllocator = .init(a),
    runtime: Runtime = .{},
    runtime_lock: glib.Mutex = .{ .f_p = null },
    store: ?*store_mod.Store = null,
    store_lock: glib.Mutex = .{ .f_p = null },
    dir: ?[:0]const u8 = null,
    locked: bool = true,
    indexing: bool = false,
    index_cancel: ?*gio.Cancellable = null,
    progress: indexer.Progress = .{},
    query_active: std.atomic.Value(bool) = .init(false),
    last_use: i64 = 0,
    tick_source: c_uint = 0,
    unload_requested: bool = false,
    failure: ?anyerror = null,
    chat_busy: ?*const fn (*anyopaque) bool = null,
    chat_context: ?*anyopaque = null,
    host: ?*const fn (*anyopaque) HostSignals = null,
    host_context: ?*anyopaque = null,
    idle_now: bool = false,
    last_input_us: i64 = 0,
    pending: schedule.Pending = .none,
    dirty: ?std.StringHashMap(void) = null,
    sched: schedule.State = .{},
    defer_reason: schedule.Reason = .nothing_pending,
    last_event_us: i64 = 0,
    last_rescan_us: i64 = 0,
    startup_us: i64 = 0,
    load_sample_us: i64 = 0,
    load_low_prev: bool = false,
    load_low: bool = false,
    current_automatic: bool = false,
    watch: ?*watch.Watch = null,
    subdirs: std.ArrayList([]const u8) = .empty,
    subdir_lock: glib.Mutex = .{ .f_p = null },

    pub fn start(self: *Service) void {
        if (self.dirty == null) self.dirty = .init(a);
        self.startup_us = glib.getMonotonicTime();
        self.last_rescan_us = self.startup_us;
        if (self.tick_source == 0) self.tick_source = glib.timeoutAdd(2000, tick, self);
    }
    pub fn deinit(self: *Service) void {
        self.stopIndexing();
        if (self.tick_source != 0) _ = glib.Source.remove(self.tick_source);
        self.tick_source = 0;
        self.runtime_lock.lock();
        self.runtime.stop();
        self.runtime_lock.unlock();
        self.store_lock.lock();
        if (self.store) |store| store.deinit();
        self.store = null;
        self.store_lock.unlock();
        self.stopWatch();
        for (self.subdirs.items) |path| a.free(path);
        self.subdirs.deinit(a);
        if (self.dirty) |*dirty| {
            var it = dirty.keyIterator();
            while (it.next()) |key| a.free(key.*);
            dirty.deinit();
        }
        if (self.dir) |dir| a.free(dir);
        self.dir = null;
        self.cfg_arena.deinit();
    }
    fn directory(self: *Service) ![:0]const u8 {
        if (self.dir) |dir| return dir;
        self.dir = try std.fmt.allocPrintSentinel(a, "{s}/pearl/search", .{glib.getUserDataDir()}, 0);
        return self.dir.?;
    }
    fn identity(self: *Service) !store_mod.Identity {
        const model = registry.findEmbedding(self.cfg.semantic.model_id) orelse return error.UnknownEmbeddingModel;
        return .{ .model_id = model.id, .model_sha256 = model.sha256 };
    }
    fn modelPath(self: *Service, buffer: *[4096]u8) ?[:0]const u8 {
        const model = registry.findEmbedding(self.cfg.semantic.model_id) orelse return null;
        var fba = std.heap.FixedBufferAllocator.init(buffer);
        return downloads.path(fba.allocator(), model) catch null;
    }
    fn modelInstalled(self: *Service) bool {
        var buffer: [4096]u8 = undefined;
        const path = self.modelPath(&buffer) orelse return false;
        return std.c.access(path, std.c.F_OK) == 0;
    }
    fn indexExists(self: *Service) bool {
        var buffer: [4096]u8 = undefined;
        const dir = self.directory() catch return false;
        const manifest = std.mem.printSentinel(&buffer, "{s}/manifest.json", .{dir}, 0) catch return false;
        return std.c.access(manifest, std.c.F_OK) == 0;
    }
    fn dirtyCount(self: *Service) u64 {
        return if (self.dirty) |dirty| dirty.count() else 0;
    }
    fn clearDirty(self: *Service) void {
        if (self.dirty) |*dirty| {
            var it = dirty.keyIterator();
            while (it.next()) |key| a.free(key.*);
            dirty.clearRetainingCapacity();
        }
    }
    pub fn configure(self: *Service, cfg: config.Config) void {
        const previously_enabled = self.cfg.semantic.enabled;
        const previous_folders = self.cfg.semantic.folders.len;
        const diff = schedule.folderDiff(self.cfg.semantic.folders, cfg.semantic.folders);
        const model_changed = !std.mem.eql(u8, self.cfg.semantic.model_id, cfg.semantic.model_id);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        var added: std.ArrayList([]const u8) = .empty;
        if (diff.added) for (cfg.semantic.folders) |folder| {
            var found = false;
            for (self.cfg.semantic.folders) |old| if (std.mem.eql(u8, old, folder)) {
                found = true;
                break;
            };
            if (!found) added.append(scratch.allocator(), folder) catch {};
        };
        self.cfg_arena.deinit();
        self.cfg_arena = .init(a);
        const alloc = self.cfg_arena.allocator();
        const json = std.json.Stringify.valueAlloc(alloc, cfg, .{}) catch return;
        self.cfg = std.json.parseFromSliceLeaky(config.Config, alloc, json, .{}) catch return;
        if (!self.cfg.semantic.enabled) {
            self.stopIndexing();
            self.requestUnload();
            self.retireStore();
            self.stopWatch();
            self.pending = .none;
            self.clearDirty();
            self.sched = .{};
            self.failure = null;
            return;
        }
        self.ensureWatch();
        if (diff.removed) self.applyFolderRemovals();
        for (added.items) |folder| self.markDirty(folder);
        if (model_changed) {
            self.retireStore();
            self.requestUnload();
            self.pending = .full;
            self.clearDirty();
        }
        if (!previously_enabled) {
            self.last_use = glib.getMonotonicTime();
            self.maybeAutoIndex();
        } else if (previous_folders == 0 and self.cfg.semantic.folders.len > 0) {
            self.maybeAutoIndex();
        }
    }
    pub fn setLocked(self: *Service, locked: bool) void {
        if (self.locked == locked) return;
        self.locked = locked;
        if (locked) {
            self.stopIndexing();
            self.requestUnload();
            self.retireStore();
            self.sched.pass_active = false;
        } else {
            self.maybeAutoIndex();
        }
    }
    /// Compositor maintenance idle notifications (ext-idle-notify). Resuming
    /// cancels a running automatic burst promptly; manual passes are untouched.
    pub fn noteIdle(self: *Service, idle: bool) void {
        self.idle_now = idle;
        if (!idle and self.indexing and self.current_automatic) self.stopIndexing();
    }
    pub fn noteInput(self: *Service) void {
        self.last_input_us = glib.getMonotonicTime();
        if (self.indexing and self.current_automatic) self.stopIndexing();
    }
    fn requestUnload(self: *Service) void {
        self.unload_requested = true;
    }
    fn retireStore(self: *Service) void {
        self.store_lock.lock();
        defer self.store_lock.unlock();
        if (self.store) |old| {
            old.deinit();
            self.store = null;
        }
    }
    fn markDirty(self: *Service, path: []const u8) void {
        self.last_event_us = glib.getMonotonicTime();
        if (self.pending == .full) return;
        if (self.dirty == null) self.dirty = .init(a);
        if (self.dirty.?.count() >= max_dirty) {
            self.pending = .full;
            self.clearDirty();
            return;
        }
        // Watch callbacks borrow their path strings; the map must own keys.
        const owned = a.dupe(u8, path) catch return;
        const gop = self.dirty.?.getOrPut(owned) catch {
            a.free(owned);
            return;
        };
        if (gop.found_existing) a.free(owned);
        self.pending = .incremental;
    }
    fn watchMark(context: *anyopaque, path: []const u8) void {
        const self: *Service = @ptrCast(@alignCast(context));
        self.markDirty(path);
    }
    fn watchPromote(context: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(context));
        self.pending = .full;
        self.clearDirty();
    }
    fn ensureWatch(self: *Service) void {
        if (self.watch == null) {
            const created = a.create(watch.Watch) catch return;
            created.* = watch.Watch.init(self, watchMark, watchPromote);
            self.watch = created;
        }
        self.watch.?.syncRoots(self.cfg.semantic.folders, self.directory() catch "");
    }
    fn stopWatch(self: *Service) void {
        if (self.watch) |w| {
            w.deinit();
            a.destroy(w);
            self.watch = null;
        }
    }
    fn noteDir(context: *anyopaque, path: []const u8) void {
        const self: *Service = @ptrCast(@alignCast(context));
        self.subdir_lock.lock();
        defer self.subdir_lock.unlock();
        if (self.subdirs.items.len >= max_dirty) return;
        const copy = a.dupe(u8, path) catch return;
        self.subdirs.append(a, copy) catch a.free(copy);
    }
    fn drainSubdirs(self: *Service) void {
        self.subdir_lock.lock();
        var list = self.subdirs;
        self.subdirs = .empty;
        self.subdir_lock.unlock();
        defer {
            for (list.items) |path| a.free(path);
            list.deinit(a);
        }
        if (self.watch) |w| for (list.items) |path| w.addDir(path);
    }
    /// Metadata-only removal: no runtime, no embedding, no window. Results
    /// stop showing removed folders promptly.
    fn applyFolderRemovals(self: *Service) void {
        self.store_lock.lock();
        defer self.store_lock.unlock();
        if (self.store == null) {
            self.store = store_mod.Store.load(a, self.directory() catch return, self.identity() catch return) catch null;
        }
        const store = self.store orelse return;
        var it = store.files.keyIterator();
        while (it.next()) |key| {
            if (!indexer.underFolders(self.cfg.semantic.folders, key.*)) store.removeFile(key.*);
        }
        store.commit() catch {};
    }
    fn sampleLoad(self: *Service) void {
        const now = glib.getMonotonicTime();
        if (now - self.load_sample_us < 15 * std.time.us_per_s) return;
        self.load_sample_us = now;
        var buffer: [256]u8 = undefined;
        const bytes = memory.read("/proc/loadavg", &buffer) catch {
            self.load_low = false;
            self.load_low_prev = false;
            return;
        };
        var tokens = std.mem.tokenizeAny(u8, bytes, " \t");
        const token = tokens.next() orelse {
            self.load_low = false;
            self.load_low_prev = false;
            return;
        };
        const load1 = std.fmt.parseFloat(f32, token) catch {
            self.load_low = false;
            self.load_low_prev = false;
            return;
        };
        const cpus: f32 = @floatFromInt(std.Thread.getCpuCount() catch 1);
        const low = load1 < 0.5 * cpus;
        // Two consecutive confirmed samples before a low-use window opens.
        self.load_low = low and self.load_low_prev;
        self.load_low_prev = low;
    }
    fn signals(self: *Service) schedule.Signals {
        const host = if (self.host) |h| h(self.host_context.?) else HostSignals{};
        const now = glib.getMonotonicTime();
        return .{
            .enabled = self.cfg.semantic.enabled,
            .background = self.cfg.semantic.background,
            .locked = self.locked,
            .indexing = self.indexing,
            .chat_busy = if (self.chat_busy) |f| f(self.chat_context.?) else false,
            .sleep_pending = host.sleep_pending,
            .inhibited = host.inhibited,
            .typing = now - self.last_input_us < 5 * std.time.us_per_s,
            .idle = self.idle_now,
            .idle_available = host.idle_available,
            .on_battery = host.on_battery,
            .battery_present = host.battery_present,
            .battery_charging = host.battery_charging,
            .battery_percent = host.battery_percent,
            .power_saver = host.power_saver,
            .load_low = self.load_low,
            .memory_ok = (memory.availableMiB() orelse 0) >= 512,
            .events_quiet = now - self.last_event_us >= schedule.event_debounce_us,
            .now_us = now,
            .startup_us = self.startup_us,
        };
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data.?));
        if (!self.cfg.semantic.enabled) return 1;
        self.sampleLoad();
        self.drainSubdirs();
        const now = glib.getMonotonicTime();
        // Safety net: a stat-only rescan catches anything monitors missed.
        if (self.pending == .none and !self.indexing and self.indexExists() and now - self.last_rescan_us >= schedule.rescan_interval_us) {
            self.pending = .incremental;
        }
        const s = self.signals();
        if (self.indexing and self.current_automatic and schedule.class(s) == null) self.stopIndexing();
        if (!self.indexing) {
            const idle = now - self.last_use > idle_seconds * std.time.us_per_s;
            if (self.unload_requested or idle) {
                if (self.runtime_lock.trylock() != 0) {
                    defer self.runtime_lock.unlock();
                    self.runtime.stop();
                    self.unload_requested = false;
                }
            }
            const decision = schedule.evaluate(s, self.pending, self.sched);
            switch (decision) {
                .wait => |reason| self.defer_reason = reason,
                .start => |burst| self.startAutomatic(burst),
            }
        } else self.defer_reason = .running;
        return 1;
    }
    /// Worker-thread entry for the launcher. Errors are expected states (not
    /// indexed, runtime missing, locked) and stay silent in the launcher.
    pub fn query(self: *Service, alloc: std.mem.Allocator, text: []const u8, cancel: *gio.Cancellable) ![]Document {
        if (!self.cfg.semantic.enabled or self.locked) return error.SemanticUnavailable;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len < min_query) return &.{};
        self.query_active.store(true, .monotonic);
        defer self.query_active.store(false, .monotonic);
        const input = try std.fmt.allocPrint(alloc, "task: search result | query: {s}", .{trimmed});
        self.runtime_lock.lock();
        self.runtime.ensureEmbedding(self.cfg, cancel) catch |err| {
            self.runtime_lock.unlock();
            return err;
        };
        const vector = embed.vector(alloc, &self.runtime, input, cancel) catch |err| {
            self.runtime_lock.unlock();
            return err;
        };
        self.runtime_lock.unlock();
        try embed.reduce(vector, store_mod.dimensions);
        self.store_lock.lock();
        defer self.store_lock.unlock();
        if (self.store == null) {
            self.store = store_mod.Store.load(a, try self.directory(), try self.identity()) catch |err| {
                self.store = null;
                return err;
            };
        }
        const hits = try self.store.?.search(alloc, vector, floor, max_documents);
        self.last_use = glib.getMonotonicTime();
        const documents = try alloc.alloc(Document, hits.len);
        for (hits, 0..) |hit, i| {
            const parent = std.fs.path.basename(std.fs.path.dirname(hit.path) orelse "");
            documents[i] = .{
                .path = try alloc.dupeSentinel(u8, hit.path, 0),
                .name = try alloc.dupeSentinel(u8, std.fs.path.basename(hit.path), 0),
                .detail = try std.fmt.allocPrintSentinel(alloc, "{s} · {s} · {s}", .{ parent, try snippet(alloc, hit.passage), @import("i18n").dtr("pearl", "Enter to open") }, 0),
                .score = band(hit.score),
            };
        }
        return documents;
    }
    /// Explicit user action: immediate, full incremental walk, no idle gate.
    pub fn indexNow(self: *Service) !void {
        self.sched.pass_active = false;
        try self.startPass(.walk, 0, false, false);
    }
    pub fn stopIndexing(self: *Service) void {
        if (self.index_cancel) |cancel| cancel.cancel();
    }
    pub fn deleteIndex(self: *Service) !void {
        if (self.indexing) return error.IndexBusy;
        self.retireStore();
        store_mod.deleteAll(try self.directory());
        self.failure = null;
        self.progress = .{};
        self.pending = .none;
        self.clearDirty();
        self.sched = .{};
        self.last_rescan_us = glib.getMonotonicTime();
    }
    fn startAutomatic(self: *Service, burst: @FieldType(schedule.Decision, "start")) void {
        if (self.cfg.semantic.folders.len == 0) {
            self.defer_reason = .no_folders;
            return;
        }
        if (!self.modelInstalled()) {
            self.defer_reason = .model_missing;
            return;
        }
        const scope: indexer.Scope = if (self.pending != .full and self.dirtyCount() > 0) .dirty else .walk;
        if (scope == .walk) self.last_rescan_us = glib.getMonotonicTime();
        self.startPass(scope, glib.getMonotonicTime() + burst.budget_us, true, self.pending == .full) catch |err| {
            self.failure = err;
            self.sched.pass_active = false;
            self.sched.last_burst_end_us = glib.getMonotonicTime();
            return;
        };
        self.sched.pass_active = true;
    }
    fn startPass(self: *Service, scope: indexer.Scope, deadline_us: i64, automatic: bool, rebuild: bool) !void {
        if (self.indexing) return error.IndexBusy;
        if (!self.cfg.semantic.enabled or self.locked) return error.SemanticUnavailable;
        if (self.cfg.semantic.folders.len == 0) return error.NoSemanticFolders;
        if (!self.modelInstalled()) return error.ModelNotInstalled;
        self.indexing = true;
        self.current_automatic = automatic;
        self.failure = null;
        self.progress = .{};
        self.index_cancel = gio.Cancellable.new();
        if (gio.Application.getDefault()) |app| app.hold();
        const job = try a.create(IndexJob);
        job.* = .{ .service = self, .scope = scope, .deadline_us = deadline_us, .automatic = automatic, .rebuild = rebuild };
        if (scope == .dirty) {
            var list: std.ArrayList([]const u8) = .empty;
            if (self.dirty) |dirty| {
                var it = dirty.keyIterator();
                while (it.next()) |key| {
                    const copy = job.arena.allocator().dupe(u8, key.*) catch continue;
                    list.append(job.arena.allocator(), copy) catch {};
                }
            }
            job.dirty = list.items;
        }
        const task = gio.Task.new(null, self.index_cancel, indexDone, self);
        task.setCheckCancellable(0);
        _ = task.setReturnOnCancel(0);
        task.setTaskData(job, null);
        task.runInThread(indexWork);
        task.unref();
    }
    fn indexWork(task: *gio.Task, _: ?*object.Object, data: ?*anyopaque, cancel: ?*gio.Cancellable) callconv(.c) void {
        const job: *IndexJob = @ptrCast(@alignCast(data.?));
        indexRun(job, cancel.?) catch |err| {
            job.failure = err;
        };
        task.returnPointer(job, null);
    }
    fn indexRun(job: *IndexJob, cancel: *gio.Cancellable) !void {
        const self = job.service;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const dir = try self.directory();
        const ident = try self.identity();
        const store = if (job.rebuild)
            try store_mod.Store.create(a, dir, ident, self.cfg.semantic.folders)
        else
            store_mod.Store.load(a, dir, ident) catch |err| switch (err) {
                error.IndexMissing, error.IndexOutdated, error.IndexCorrupt => try store_mod.Store.create(a, dir, ident, self.cfg.semantic.folders),
                else => return err,
            };
        defer store.deinit();
        self.runtime_lock.lock();
        self.runtime.ensureEmbedding(self.cfg, cancel) catch |err| {
            self.runtime_lock.unlock();
            return err;
        };
        self.runtime_lock.unlock();
        const outcome = try indexer.pass(alloc, self.cfg, store, &self.runtime, &self.progress, cancel, .{
            .runtime_lock = &self.runtime_lock,
            .chat_busy = self.chat_busy,
            .chat_context = self.chat_context,
            .query_active = &self.query_active,
            .scope = job.scope,
            .dirty = job.dirty,
            .deadline_us = job.deadline_us,
            .note_dir = noteDir,
            .note_context = self,
        });
        job.more = outcome == .more;
    }
    fn indexDone(_: ?*object.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data.?));
        const job: *IndexJob = @ptrCast(@alignCast(object.ext.cast(gio.Task, result).?.propagatePointer(null).?));
        defer {
            job.arena.deinit();
            a.destroy(job);
        }
        self.indexing = false;
        if (self.index_cancel) |cancel| cancel.unref();
        self.index_cancel = null;
        const now = glib.getMonotonicTime();
        self.sched.last_burst_end_us = now;
        if (job.failure) |err| {
            self.sched.pass_active = false;
            if (err != error.Cancelled) self.failure = err;
        } else {
            self.failure = null;
            self.last_use = now;
            // Swap in the freshly committed index; the old one retires safely.
            if (self.directory()) |dir| {
                if (self.identity()) |ident| {
                    if (store_mod.Store.load(a, dir, ident)) |fresh| {
                        self.store_lock.lock();
                        if (self.store) |old| old.deinit();
                        self.store = fresh;
                        self.store_lock.unlock();
                    } else |_| {}
                } else |_| {}
            } else |_| {}
            if (job.automatic) {
                self.sched.pass_active = job.more;
                if (!job.more) {
                    if (job.scope == .dirty) {
                        for (job.dirty) |path| {
                            if (self.dirty) |*dirty| {
                                if (dirty.fetchRemove(path)) |kv| a.free(kv.key);
                            }
                        }
                    } else self.clearDirty();
                    self.pending = if (self.dirtyCount() > 0) .incremental else .none;
                }
            } else {
                self.sched.pass_active = false;
                self.clearDirty();
                self.pending = .none;
            }
        }
        if (gio.Application.getDefault()) |app| app.release();
    }
    /// Readiness for the automatic first pass; the scheduler decides when it
    /// actually runs. An existing index is never rebuilt implicitly.
    fn maybeAutoIndex(self: *Service) void {
        if (!shouldAutoIndex(self.cfg.semantic.enabled, self.locked, self.indexing, self.cfg.semantic.folders.len, self.modelInstalled(), self.indexExists())) return;
        self.pending = .incremental;
    }
    pub fn status(self: *Service) Status {
        var result: Status = .{
            .state = .disabled,
            .folders = self.cfg.semantic.folders.len,
            .pdf_available = extract.pdfAvailable(),
            .done = self.progress.done.load(.monotonic),
            .total = self.progress.total.load(.monotonic),
            .indexed = self.progress.indexed.load(.monotonic),
            .skipped = self.progress.skipped.load(.monotonic),
            .pending = @tagName(self.pending),
            .dirty = self.dirtyCount(),
            .window = if (self.indexing) "indexing" else "waiting",
            .defer_reason = @tagName(self.defer_reason),
            .background = @tagName(self.cfg.semantic.background),
            .automatic = self.indexing and self.current_automatic,
        };
        if (!self.cfg.semantic.enabled) return result;
        result.model_installed = self.modelInstalled();
        const host = if (self.host) |h| h(self.host_context.?) else HostSignals{};
        result.degraded = (self.watch != null and self.watch.?.degraded) or !host.idle_available;
        self.store_lock.lock();
        if (self.store) |store| {
            const counts = store.counts();
            result.files = counts.files;
            result.chunks = counts.chunks;
            result.updated_ns = store.updated_ns;
        }
        self.store_lock.unlock();
        result.state = if (self.indexing)
            (if (self.progress.state.load(.monotonic) == @backingInt(indexer.State.paused)) .paused else .indexing)
        else if (self.failure != null)
            .failed
        else if (result.chunks > 0)
            .ready
        else
            .setup;
        if (self.failure) |err| result.error_code = @errorName(err);
        return result;
    }
};
/// Pure decision for the automatic first pass: every consent and readiness
/// input must hold, and an existing index is never rebuilt implicitly.
pub fn shouldAutoIndex(enabled: bool, locked: bool, indexing: bool, folders: usize, model_installed: bool, index_exists: bool) bool {
    return enabled and !locked and !indexing and folders > 0 and model_installed and !index_exists;
}
/// Map cosine similarity into the launcher band below application substring
/// matches (400) and above the implicit Ask Pearl row (-1000).
pub fn band(cosine: f32) i32 {
    const t = std.math.clamp((cosine - floor) / (1 - floor), 0, 1);
    return 120 + @as(i32, @intFromFloat(t * 270));
}
fn snippet(alloc: std.mem.Allocator, passage: []const u8) ![]const u8 {
    const flattened = try alloc.dupe(u8, passage);
    for (flattened) |*ch| {
        if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    const trimmed = std.mem.trim(u8, flattened, " ");
    if (trimmed.len <= 160) return trimmed;
    var end: usize = 160;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}…", .{trimmed[0..end]});
}
test "score band stays below app substring matches and above implicit ask" {
    try std.testing.expectEqual(@as(i32, 120), band(floor));
    try std.testing.expectEqual(@as(i32, 390), band(1));
    try std.testing.expect(band(0.65) > 120 and band(0.65) < 390);
    try std.testing.expectEqual(@as(i32, 120), band(0.1));
    try std.testing.expect(band(0.65) < 400);
}
test "automatic first indexing requires every consent and readiness input" {
    try std.testing.expect(shouldAutoIndex(true, false, false, 1, true, false));
    try std.testing.expect(!shouldAutoIndex(false, false, false, 1, true, false));
    try std.testing.expect(!shouldAutoIndex(true, true, false, 1, true, false));
    try std.testing.expect(!shouldAutoIndex(true, false, true, 1, true, false));
    try std.testing.expect(!shouldAutoIndex(true, false, false, 0, true, false));
    try std.testing.expect(!shouldAutoIndex(true, false, false, 1, false, false));
    try std.testing.expect(!shouldAutoIndex(true, false, false, 1, true, true));
}
test "snippets flatten whitespace and cut on character boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("a b c", try snippet(alloc, "a\nb\tc"));
    var long: std.ArrayList(u8) = .empty;
    for (0..100) |_| try long.appendSlice(alloc, "🐕");
    const cut = try snippet(alloc, long.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));
}
